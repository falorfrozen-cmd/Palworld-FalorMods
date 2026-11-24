-- CoopPlus
-- Share unlocked fast travel points between members of the same guild.
--
-- Runs on the HOST only (the server owns every player's record data).
-- For a point that some guild member has unlocked and another hasn't, the
-- server runs the point's own unlock interaction for that player
-- (APalLevelObjectUnlockableFastTravelPoint:OnTriggerInteract, type UnlockFastTravel),
-- so the game records, saves and replicates it the normal way.
--
-- SAFETY: AutoSync is OFF until the manual test has worked.
--   F10 = test: share exactly ONE missing point with ONE player, log before/after.
-- After a successful test set AutoSync = true.

local CFG = {
    TestKey = Key.F10,
    AutoSync = false,       -- turn on after the F10 test worked
    ScanSeconds = 15,
    MaxUnlocksPerScan = 2,  -- spread unlocks out (each may show a notification)
}

local TAG = "[CoopPlus] "
local function log(m) print(TAG .. tostring(m) .. "\n") end
local INDICATOR_UNLOCK_FAST_TRAVEL = 26

local function valid(o)
    if not o then return false end
    local ok, v = pcall(function() return o:IsValid() end)
    return ok and v
end
local function gid(g)
    local ok, s = pcall(function() return string.format("%08X%08X%08X%08X", g.A, g.B, g.C, g.D) end)
    return ok and s or nil
end
local function nameStr(n)
    local ok, s = pcall(function() return n:ToString() end)
    return ok and s or nil
end

local failed = {}   -- "player|point" -> true : unlock attempt had no effect, don't retry

-- Gather every connected player: name, pawn, guild id, unlocked set
local function collectPlayers()
    local list = {}
    for _, pc in ipairs(FindAllOf("PalPlayerController") or {}) do
        if valid(pc) then
            local ps, pawn
            pcall(function() ps = pc.PlayerState end)
            pcall(function() pawn = pc.Pawn end)
            if valid(ps) and valid(pawn) then
                local p = { pc = pc, ps = ps, pawn = pawn, unlocked = {} }
                pcall(function() p.name = ps:GetPlayerName():ToString() end)
                p.name = p.name or "?"
                pcall(function() p.guild = gid(ps.GuildBelongTo.ID) end)
                pcall(function()
                    ps.RecordData.FastTravelPointUnlockFlag.Items:ForEach(function(_, e)
                        local it = e:get()
                        if it.Value then
                            local k = nameStr(it.Key)
                            if k then p.unlocked[k] = true end
                        end
                    end)
                end)
                list[#list + 1] = p
            end
        end
    end
    return list
end

local function countKeys(t) local n = 0 for _ in pairs(t) do n = n + 1 end return n end

-- returns list of { player, pointId } that are missing for guild mates
local function missingPairs(players)
    local union = {}   -- guild -> set
    for _, p in ipairs(players) do
        if p.guild then
            union[p.guild] = union[p.guild] or {}
            for k in pairs(p.unlocked) do union[p.guild][k] = true end
        end
    end
    local pairs_ = {}
    for _, p in ipairs(players) do
        if p.guild then
            for k in pairs(union[p.guild]) do
                if not p.unlocked[k] and not failed[p.name .. "|" .. k] then
                    pairs_[#pairs_ + 1] = { player = p, point = k }
                end
            end
        end
    end
    return pairs_
end

local function pointActors()
    local map = {}
    for _, a in ipairs(FindAllOf("PalLevelObjectUnlockableFastTravelPoint") or {}) do
        if valid(a) then
            local id = nameStr(a.FastTravelPointID)
            if id then map[id] = a end
        end
    end
    return map
end

local function isServer()
    for _, pc in ipairs(FindAllOf("PalPlayerController") or {}) do
        local okL, l = pcall(function() return pc:IsLocalController() end)
        if okL and l then
            local okA, a = pcall(function() return pc:HasAuthority() end)
            return okA and a
        end
    end
    return false
end

local pending = {}  -- attempts to verify on the next scan

local function verifyPending(players)
    local byName = {}
    for _, p in ipairs(players) do byName[p.name] = p end
    for i = #pending, 1, -1 do
        local a = pending[i]
        local p = byName[a.player]
        if p then
            if p.unlocked[a.point] then
                log(string.format("OK: %s now has %s", a.player, a.point))
            else
                failed[a.player .. "|" .. a.point] = true
                log(string.format("NO EFFECT: %s still lacks %s (unlock path did not work, will not retry)", a.player, a.point))
            end
        end
        table.remove(pending, i)
    end
end

local function shareSome(limit, reason)
    if not isServer() then log("not the host - CoopPlus only works on the host") return end
    local players = collectPlayers()
    verifyPending(players)
    for _, p in ipairs(players) do
        log(string.format("%s: guild=%s unlocked=%d", p.name, tostring(p.guild and p.guild:sub(1, 8)), countKeys(p.unlocked)))
    end
    local todo = missingPairs(players)
    if #todo == 0 then log("nothing to share (" .. reason .. ")") return end
    local actors = pointActors()
    local done = 0
    for _, t in ipairs(todo) do
        if done >= limit then break end
        local actor = actors[t.point]
        if actor then
            local ok, err = pcall(function()
                actor:OnTriggerInteract(t.player.pawn, INDICATOR_UNLOCK_FAST_TRAVEL)
            end)
            log(string.format("[%s] unlock %s for %s -> call %s%s", reason, t.point, t.player.name,
                ok and "ok" or "failed", ok and "" or (": " .. tostring(err))))
            if ok then
                pending[#pending + 1] = { player = t.player.name, point = t.point }
            else
                failed[t.player.name .. "|" .. t.point] = true
            end
            done = done + 1
        end
    end
    if done == 0 then
        log(string.format("%d point(s) to share, but none of them is loaded near any player right now", #todo))
    end
end

-- F10: manual single test
RegisterKeyBind(CFG.TestKey, function()
    ExecuteInGameThread(function()
        local ok, err = pcall(shareSome, 1, "F10 test")
        if not ok then log("error: " .. tostring(err)) end
        -- verify a few seconds later
        ExecuteWithDelay(4000, function()
            ExecuteInGameThread(function()
                local ok2, err2 = pcall(function() verifyPending(collectPlayers()) end)
                if not ok2 then log("verify error: " .. tostring(err2)) end
            end)
        end)
    end)
end)

if CFG.AutoSync then
    LoopAsync(CFG.ScanSeconds * 1000, function()
        ExecuteInGameThread(function()
            local ok, err = pcall(shareSome, CFG.MaxUnlocksPerScan, "auto")
            if not ok then log("error: " .. tostring(err)) end
        end)
        return false
    end)
end

log("Loaded (AutoSync=" .. tostring(CFG.AutoSync) .. ", F10 = test share one point)")
