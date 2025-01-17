local Knit = require(game.ReplicatedStorage.Knit)

local DataStoreService = require(game.ReplicatedStorage.Packages.DataStoreService)
local LocalizationService = game:GetService("LocalizationService")

local GraphDataStore = DataStoreService:GetDataStore("GraphDataStore")

local DebugOut = require(game.ReplicatedStorage.Shared.DebugOut)

local PermissionsService
local RateLimitService

local Scores
local Global

local ScoreService = Knit.CreateService({
    Name = "ScoreService",
    Client = {}
})

function ScoreService:KnitStart()
    PermissionsService = Knit.GetService("PermissionsService")
    RateLimitService = Knit.GetService("RateLimitService")

    local ParseServerService = Knit.GetService("ParseServerService")
    local ParseServer = ParseServerService:GetParse()

    Scores = ParseServer.Objects.class("Plays")
    Global = ParseServer.Objects.class("Global")
end

function ScoreService:_GetGraphKey(userId, songMD5Hash)
    return string.format("Graph(%s%s)", userId, songMD5Hash)
end

function ScoreService:GetPlayerScores(userId, limit)
    local succeeded, documents = Scores
        :query()
        :where({
            UserId = userId
        })
        :order("-Rating")
        :limit(limit)
        :execute()
        :await()

    if succeeded then
        return documents, succeeded
    else
        warn(documents)
        return {}, succeeded
    end
end

function ScoreService:CalculateRating(userId)
    local scores = self:GetPlayerScores(userId)

    local rating = 0;
    local maxNumOfScores = math.min(#scores, 25);

    for i = 1, maxNumOfScores do
        if i > 10 then
            rating = rating + scores[i].Rating * 1.5
        else
            rating = rating + scores[i].Rating;
        end
    end

    return math.floor((100 * rating) / 30) / 100
end

function ScoreService:CalculateAverageAccuracy(userId)
    local scores = self:GetPlayerScores(userId)

    local accuracy = 0

    for _, score in ipairs(scores) do
        accuracy += score.Accuracy
    end

    return accuracy / #scores
end

function ScoreService:RefreshProfile(player)
    local succeeded, slots = Global
            :query()
            :where({
                UserId = player.UserId
            })
            :execute()
            :await()

    if succeeded then
        local slot = slots[1]

        if slot then
            Global
                :update(slot.objectId, {
                    TotalMapsPlayed = {
                        __op = "Increment",
                        amount = 1
                    },
                    Rating = ScoreService:CalculateRating(player.UserId),
                    Accuracy = ScoreService:CalculateAverageAccuracy(player.UserId),
                    PlayerName = player.DisplayName,
                    UserId = player.UserId
                })
                :andThen(function(document)
                    DebugOut:puts("Global leaderboard slot successfully updated!")
                end)
            else
                Global
                    :create({
                        TotalMapsPlayed = 1,
                        Rating = ScoreService:CalculateRating(player.UserId),
                        Accuracy = ScoreService:CalculateAverageAccuracy(player.UserId),
                        PlayerName = player.DisplayName,
                        CountryRegion = LocalizationService:GetCountryRegionForPlayerAsync(player),
                        Allowed = true,
                        UserId = player.UserId
                    })
                    :andThen(function(document)
                        DebugOut:puts("Global leaderboard slot successfully created!")
                    end)
        end
    end
end

function ScoreService.Client:SubmitScore(player, songMD5Hash, rating, score, marvelouses, perfects, greats, goods, bads, misses, accuracy, maxChain, mean, rate)
    if RateLimitService:CanProcessRequestWithRateLimit(player, "SubmitScore", 1) then
        local succeeded, documents = Scores
            :query()
            :where({
                SongMD5Hash = songMD5Hash,
                UserId = player.UserId
            })
            :execute()
            :await()

        if succeeded then
            local oldScore = documents[1]

            if not oldScore then
                succeeded = Scores:create({
                    UserId = player.UserId,
                    PlayerName = player.DisplayName,
                    Rating = rating,
                    Score = score,
                    Marvelouses = marvelouses,
                    Perfects = perfects,
                    Greats = greats,
                    Goods = goods,
                    Bads = bads,
                    Misses = misses,
                    Mean = mean,
                    Accuracy = accuracy,
                    Rate = rate,
                    MaxChain = maxChain,
                    SongMD5Hash = songMD5Hash,
                    Allowed = true
                })
                :await()
                ScoreService:RefreshProfile(player)
                return succeeded
            end

            local overwrite = false

            if oldScore.Rating == 0 and rating == 0 then
                overwrite = score > oldScore.Score
            else
                overwrite = rating > oldScore.Rating
            end

            if overwrite then
                Scores:update(oldScore.objectId, {
                    PlayerName = player.DisplayName,
                    Rating = rating,
                    Score = score,
                    Marvelouses = marvelouses,
                    Perfects = perfects,
                    Greats = greats,
                    Goods = goods,
                    Bads = bads,
                    Misses = misses,
                    Mean = mean,
                    Accuracy = accuracy,
                    Rate = rate
                }):await()
            end

            ScoreService:RefreshProfile(player)
        else
            return false
        end
        
        return succeeded
    end
end

function ScoreService.Client:SubmitGraph(player, songMD5Hash, graph)
    if RateLimitService:CanProcessRequestWithRateLimit(player, "SubmitGraph", 1) then
        local key = ScoreService:_GetGraphKey(player.UserId, songMD5Hash)

        GraphDataStore:SetAsync(key, graph)
    end
end

function ScoreService.Client:GetGraph(player, userId, songMD5Hash)
    if RateLimitService:CanProcessRequestWithRateLimit(player, "GetGraph", 2) then
        local key = ScoreService:_GetGraphKey(userId, songMD5Hash)
        return GraphDataStore:GetAsync(key)
    end
    
    return {}
end

function ScoreService.Client:GetScores(player, songMD5Hash, limit)
    if RateLimitService:CanProcessRequestWithRateLimit(player, "GetScores", 2) then
        local succeeded, documents = Scores
            :query()
            :where({
                SongMD5Hash = songMD5Hash,
                Allowed = true
            })
            :limit(limit)
            :order("-Rating")
            :execute()
            :await()

        if succeeded then
            return documents, succeeded
        else
            warn(documents)
            return {}, succeeded
        end
    end

    return {}, false
end

function ScoreService.Client:GetRank(player)
    if RateLimitService:CanProcessRequestWithRateLimit(player, "GetRank", 2) then
        local succeeded, ranks = Global
            :query()
            :where({
                Allowed = true
            })
            :order("-Rating")
            :execute()
            :await()

        if not succeeded then
            warn(ranks)
            return
        end
        
        for rank = 1, #ranks do
            local profile = ranks[rank]

            if profile.UserId == player.UserId then
                return rank
            end
        end

        return -1
    end

    return -2
end

function ScoreService.Client:GetProfile(player)
    if RateLimitService:CanProcessRequestWithRateLimit(player, "GetProfile", 2) then
        local succeeded, profiles = Global
            :query()
            :where({
                UserId = player.UserId
            })
            :order("-Rating")
            :execute()
            :await()

        if not succeeded then
            warn(profiles)
            return
        end

        local profile = profiles[1]

        if profile then
            return profile
        end

        return {}
    end

    return {}
end

function ScoreService.Client:GetGlobalLeaderboard(player)
    if RateLimitService:CanProcessRequestWithRateLimit(player, "GetGlobalLeaderboard", 3) then
        local succeeded, ranks = Global
            :query()
            :where({
                Allowed = true
            })
            :order("-Rating")
            :limit(50)
            :execute()
            :await()

        if succeeded then
            return ranks
        end

        warn(ranks)
        return {}
    end

    return {}
end

function ScoreService.Client:GetPlayerScores(player, userId)
    if RateLimitService:CanProcessRequestWithRateLimit(player, "GetPlayerScores", 2) then
        return ScoreService:GetPlayerScores(userId or player.UserId)
    end
end

function ScoreService.Client:DeleteScore(moderator, objectId)
    if RateLimitService:CanProcessRequestWithRateLimit(moderator, "DeleteScore", 4) then
        if PermissionsService:HasModPermissions(moderator) then
            local succeeded, result = Scores:delete(objectId)
                :await()
            
            if not succeeded then
                warn(result)
            end
        end
    end
end

return ScoreService
