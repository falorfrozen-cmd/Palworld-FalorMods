-- TechUnlockAll logic (re-read live by the loader, also callable from the
-- GlobalBaseStorage test channel: "tech probe" / "tech unlock host" ...).
-- Runs on the world host only: technology unlocks live on the server in each
-- player's UPalTechnologyData.UnlockedTechnologyNameArray and replicate to
-- that player's game.

local M = { version = "1" }
local TAG = "[TechUnlockAll] "
local function log(m) print(TAG .. tostring(m) .. "\n") end

local function valid(o)
    if not o then return false end
    local ok, v = pcall(function() return o:IsValid() end)
    return ok and v
end

local function str(x)
    if x == nil then return "nil" end
    if type(x) == "string" then return x end
    local ok, s = pcall(function() return x:ToString() end)
    return ok and s or tostring(x)
end

-- PERFORMANCE (measured 2026-11-18): FindAllOf / FindFirstOf walk every object
-- in the game: ~30 ms EACH (StaticFindObject ~15 ms). Reading the game state's
-- PlayerArray takes 0.015 ms. So nothing that runs on a timer may call them;
-- the game state is found once and kept.
_G.TU_GS = _G.TU_GS or { gs = nil, at = -100 }
-- a new world's game state appeared: forget the old one
if not _G.TU_GS_NOTIFY then
    _G.TU_GS_NOTIFY = pcall(NotifyOnNewObject, "/Script/Engine.GameStateBase", function()
        local c = _G.TU_GS
        if c then c.gs = nil; c.at = -100 end
    end)
end
local function gameState()
    local c = _G.TU_GS
    if valid(c.gs) then return c.gs end
    local now = os.clock()
    if now - c.at < 10 then return nil end   -- look again at most every 10 s
    c.at = now
    local gs = FindFirstOf("PalGameStateInGame")
    c.gs = valid(gs) and gs or nil
    return c.gs
end

-- every player state on this machine: { ps, td, name, isLocal, host }
function M.players()
    local out = {}
    local gs = gameState()
    if not gs then return out end
    local arr = gs.PlayerArray
    for i = 1, #arr do
        local ps = arr[i]
        pcall(function()
            if not valid(ps) then return end
            local td = ps.TechnologyData
            if not valid(td) then return end
            local isLocal, host = false, false
            local pc = ps:GetPlayerController()
            if valid(pc) then
                isLocal = pc:IsLocalController()
                if isLocal then host = pc:HasAuthority() end
            end
            local name = "?"
            pcall(function() name = str(ps:GetPlayerName()) end)
            out[#out + 1] = { ps = ps, td = td, name = name, isLocal = isLocal, host = host }
        end)
    end
    return out
end

-- all technology rows: list of { name, boss, lv }
function M.allTech(td)
    local list = {}
    local dt = td.technologyDataSet.recipeUnlockDataTable
    if not valid(dt) then return list end
    dt:ForEachRow(function(rn, row)
        list[#list + 1] = { name = str(rn), boss = row.IsBossTechnology == true, lv = tonumber(row.LevelCap) or 0 }
    end)
    return list
end

function M.unlockedSet(td)
    local set, n = {}, 0
    td.UnlockedTechnologyNameArray:ForEach(function(i, e)
        set[str(e:get())] = true
        n = n + 1
    end)
    return set, n
end

function M.missing(p)
    local all = M.allTech(p.td)
    local set, n = M.unlockedSet(p.td)
    local miss = {}
    for _, t in ipairs(all) do
        if not set[t.name] then
            local denied = false
            pcall(function() denied = p.td:IsDeniedTechnology(FName(t.name)) end)
            if not denied then miss[#miss + 1] = t end
        end
    end
    return miss, #all, n
end

function M.probe()
    local ps = M.players()
    log("PROBE players=" .. #ps)
    for _, p in ipairs(ps) do
        local miss, total, n = M.missing(p)
        local boss = 0
        for _, t in ipairs(miss) do if t.boss then boss = boss + 1 end end
        local pts, bpts = "?", "?"
        pcall(function() pts = tostring(p.td:GetTechnologyPoints()) end)
        pcall(function() bpts = tostring(p.td:GetBossTechnologyPoints()) end)
        log(string.format("PROBE %s local=%s points=%s ancient=%s unlocked=%d tableRows=%d missing=%d (ancient %d)",
            p.name, tostring(p.isLocal), pts, bpts, n, total, #miss, boss))
        for i = 1, math.min(5, #miss) do
            local t = miss[i]
            local u = "?"
            pcall(function() u = tostring(p.td:IsUnlockRecipeTechnology(FName(t.name))) end)
            log(string.format("PROBE   missing %s lv=%d ancient=%s isUnlocked=%s", t.name, t.lv, tostring(t.boss), u))
        end
    end
end

-- who: "host" (local player) or "all"
function M.unlock(who)
    local done = 0
    for _, p in ipairs(M.players()) do
        if who == "all" or (who == "host" and p.isLocal) then
            local miss = M.missing(p)
            local arr = p.td.UnlockedTechnologyNameArray
            local before = #arr
            for _, t in ipairs(miss) do
                arr[#arr + 1] = FName(t.name)
            end
            local after = #arr
            pcall(function() p.td:OnRep_UnlockedTechnologyNameArray() end)
            local okCount = 0
            for _, t in ipairs(miss) do
                local u = false
                pcall(function() u = p.td:IsUnlockRecipeTechnology(FName(t.name)) end)
                if u then okCount = okCount + 1 end
            end
            log(string.format("UNLOCK %s: array %d -> %d, %d of %d now report unlocked",
                p.name, before, after, okCount, #miss))
            done = done + 1
        end
    end
    if done == 0 then log("UNLOCK nobody matched '" .. tostring(who) .. "'") end
    return done
end

-- read-only: full lists (unlocked + missing with level / tier / requirement)
function M.dump()
    for _, p in ipairs(M.players()) do
        local set = M.unlockedSet(p.td)
        local u = {}
        for k in pairs(set) do u[#u + 1] = k end
        table.sort(u)
        log("DUMP " .. p.name .. " unlocked: " .. table.concat(u, ","))
        local dt = p.td.technologyDataSet.recipeUnlockDataTable
        local lines = {}
        dt:ForEachRow(function(rn, row)
            local n = str(rn)
            if not set[n] then
                lines[#lines + 1] = string.format("%s(lv%d,t%d,c%d%s%s%s)", n, tonumber(row.LevelCap) or -1,
                    tonumber(row.Tier) or -1, tonumber(row.Cost) or -1,
                    row.IsBossTechnology and ",A" or "",
                    str(row.RequireTechnology) ~= "None" and (",req=" .. str(row.RequireTechnology)) or "",
                    tonumber(row.RequireDefeatTowerBoss) ~= 0 and (",tb=" .. tostring(row.RequireDefeatTowerBoss)) or "")
            end
        end)
        for i = 1, #lines, 25 do
            log("DUMP missing " .. table.concat(lines, " ", i, math.min(#lines, i + 24)))
        end
    end
end

-- read-only: do the build objects / craft recipes of some techs count as unlocked?
function M.check(names)
    for _, p in ipairs(M.players()) do
        local dt = p.td.technologyDataSet.recipeUnlockDataTable
        dt:ForEachRow(function(rn, row)
            local n = str(rn)
            if names[n] then
                local parts = {}
                row.UnlockBuildObjects:ForEach(function(i, e)
                    local b = str(e:get()); local u = "?"
                    pcall(function() u = tostring(p.td:IsUnlockBuildObject(FName(b))) end)
                    parts[#parts + 1] = "build " .. b .. "=" .. u
                end)
                row.UnlockItemRecipes:ForEach(function(i, e)
                    local r = str(e:get()); local u = "?"
                    pcall(function() u = tostring(p.td:IsUnlockCraftRecipe(FName(r))) end)
                    parts[#parts + 1] = "recipe " .. r .. "=" .. u
                end)
                log("CHECK " .. p.name .. " " .. n .. ": " .. table.concat(parts, ", "))
            end
        end)
    end
end

---------------------------------------------------------------------------
-- automatic mode (called by main.lua every 10 s on the world host)
---------------------------------------------------------------------------
M.cfg = { enabled = true, friends = true }
function M.setSettings(v)
    if type(v) ~= "table" then return end
    if v.enabled ~= nil then M.cfg.enabled = v.enabled end
    if v.include_friends ~= nil then M.cfg.friends = v.include_friends end
end

-- only the world host decides unlocks (a friend's own game cannot)
function M.isHost(list)
    for _, p in ipairs(list or M.players()) do
        if p.isLocal then return p.host == true end
    end
    return false
end

_G.TU_STATE = _G.TU_STATE or { rows = nil, logged = {} }
local S = _G.TU_STATE

function M.tick()
    if not M.cfg.enabled then return end
    local list = M.players()
    if not M.isHost(list) then return end
    for _, p in ipairs(list) do
        if p.isLocal or M.cfg.friends then
            -- cheap check first: unlocked count vs table rows
            if not S.rows then
                local n = 0
                pcall(function() p.td.technologyDataSet.recipeUnlockDataTable:ForEachRow(function() n = n + 1 end) end)
                if n > 0 then S.rows = n end
            end
            local have = 0
            pcall(function() have = #p.td.UnlockedTechnologyNameArray end)
            if S.rows and have < S.rows then
                local miss = M.missing(p)
                if #miss > 0 then
                    M.unlock_one(p, miss)
                end
            end
        end
    end
end

function M.unlock_one(p, miss)
    local arr = p.td.UnlockedTechnologyNameArray
    local before = #arr
    for _, t in ipairs(miss) do arr[#arr + 1] = FName(t.name) end
    pcall(function() p.td:OnRep_UnlockedTechnologyNameArray() end)
    local okCount = 0
    for _, t in ipairs(miss) do
        local u = false
        pcall(function() u = p.td:IsUnlockRecipeTechnology(FName(t.name)) end)
        if u then okCount = okCount + 1 end
    end
    log(string.format("%s: unlocked %d technologies (%d -> %d, %d confirmed)",
        p.name, #miss, before, #arr, okCount))
end

function M.command(sub, arg)
    if sub == "check" then
        M.check({ Arrow = true, Signboard = true, WingGlider = true, AncientWorkBench = true, Battle_RangeWeapon_Bow1 = true, AdditionalInventory_001 = true, Workbench = true })
    elseif sub == "tick" then
        log("TICK isHost=" .. tostring(M.isHost()) .. " rows=" .. tostring(S.rows))
        M.tick()
        log("TICK done rows=" .. tostring(S.rows))
    elseif sub == "probe" then M.probe()
    elseif sub == "dump" then M.dump()
    elseif sub == "unlock" then M.unlock(arg ~= "" and arg or "host")
    else log("unknown tech command: " .. tostring(sub)) end
end

-- timing: how long does tick take? (summary line every 30 s)
do
    _G.TU_PERF = _G.TU_PERF or { n = 0, total = 0, max = 0, since = os.clock() }
    local P = _G.TU_PERF
    local inner = M.tick
    M.tick = function(...)
        local t0 = os.clock()
        local r = inner(...)
        local ms = (os.clock() - t0) * 1000
        P.n = P.n + 1; P.total = P.total + ms
        if ms > P.max then P.max = ms end
        local now = os.clock()
        if now - P.since >= 30 then
            -- watchdog: only speak up when a tick was slow enough to feel
            if P.max >= 10 then print(string.format("[TechUnlockAll] SLOW %d ticks in %.0f s, avg %.2f ms, max %.0f ms\n", P.n, now - P.since, P.total / P.n, P.max)) end
            P.n, P.total, P.max, P.since = 0, 0, 0, now
        end
        return r
    end
end

return M
