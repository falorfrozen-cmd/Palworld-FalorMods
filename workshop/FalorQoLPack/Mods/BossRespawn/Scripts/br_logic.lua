-- BossRespawn logic (live-reloaded by main.lua; no game restart needed)
--
-- What the game does (read from the running game 2026-11-18):
--  * FIELD BOSSES (Alpha Pals on the map): when one is defeated or caught, its
--    spawner name is put into NPCManager.RespawnDisableFlag (name -> true) and
--    the spawner stays empty while that flag is set. The table that places the
--    spawners (DT_PalSpawnerPlacement) has cooldown 0 for all 72 of them, so
--    there is no per-boss timer in the game data.
--  * FIXED DUNGEONS (the 18 entrances that are always in the same place): the
--    entrance has RespawnCoolTimeMinutesAfterBossDefeated = 60 and the dungeon
--    remembers RespawnBossTimeAt (game time, 10,000,000 ticks per game second).
--  * RANDOM DUNGEONS (170 marker points): each has RespawnInterval = 60 min
--    (time until a new dungeon appears there after the old one is gone).
--
-- What this mod does (world host only):
--  * counts play time for every defeated field boss and clears its flag after
--    the chosen number of minutes
--  * counts play time for every fixed dungeon whose boss is dead and moves the
--    dungeon's own respawn time so it fires after the chosen number of minutes
--  * writes the chosen minutes into the entrances and the random-dungeon points
--
-- Timers count only while the world is running and are kept in br_state.txt.

local M = { version = "3" }
local WORLD_GRACE = 20      -- seconds to wait after the host appears in a freshly started world
local TAG = "[BossRespawn] "
local function log(m) print(TAG .. tostring(m) .. "\n") end

local function valid(o)
    if not o then return false end
    local ok, v = pcall(function() return o:IsValid() end)
    return ok and v
end

-- kept across live reloads; the loader overwrites it from the settings page
_G.BR_CFG = _G.BR_CFG or { enabled = true, field_minutes = 30, dungeon_minutes = 30 }
M.cfg = _G.BR_CFG
local CFG = M.cfg
local VANILLA_DUNGEON_MIN = 60
local DEFAULT_RATE = 45 * 10000000     -- game ticks per real second (measured: 45 game s per s by day)

-- state that must survive a live reload
_G.BR_STATE = _G.BR_STATE or { boss = {}, dungeon = {}, lastAt = nil, lastTicks = nil, rate = DEFAULT_RATE,
    dirty = false, savedAt = 0, loaded = false, applied = nil }
local S = _G.BR_STATE
_G.BR_CACHE = _G.BR_CACHE or { gs = nil, gsAt = -100, util = nil, mgr = nil, ds = nil, dsAt = -100, fixed = nil, fixedAt = -1000, world = 0 }
local C = _G.BR_CACHE
if not _G.BR_NOTIFY then
    -- new world: forget everything that belonged to the old one (only flags here)
    _G.BR_NOTIFY = pcall(NotifyOnNewObject, "/Script/Engine.GameStateBase", function()
        local c = _G.BR_CACHE
        c.gs = nil; c.gsAt = -100; c.mgr = nil; c.ds = nil; c.dsAt = -100; c.fixed = nil; c.world = c.world + 1
    end)
end

function M.setSettings(v)
    if type(v) ~= "table" then return end
    if v.enabled ~= nil then CFG.enabled = v.enabled end
    if type(v.field_minutes) == "number" then CFG.field_minutes = v.field_minutes end
    if type(v.dungeon_minutes) == "number" then CFG.dungeon_minutes = v.dungeon_minutes end
end

---------------------------------------------------------------------------
-- cheap access (nothing here searches the whole game on a timer)
---------------------------------------------------------------------------
local function gameState()
    if valid(C.gs) then return C.gs end
    local now = os.clock()
    if now - C.gsAt < 10 then return nil end
    C.gsAt = now
    local gs = FindFirstOf("PalGameStateInGame")
    C.gs = valid(gs) and gs or nil
    return C.gs
end

-- the local controller, and whether this machine is the world host
local function localHost()
    local gs = gameState()
    if not gs then return nil end
    local arr = gs.PlayerArray
    for i = 1, #arr do
        local ps = arr[i]
        if valid(ps) then
            local pc = ps:GetPlayerController()
            if valid(pc) and pc:IsLocalController() then
                if pc:HasAuthority() then return pc end
                return nil
            end
        end
    end
    return nil
end

local function util()
    if valid(C.util) then return C.util end
    local u = StaticFindObject("/Script/Pal.Default__PalUtility")
    C.util = valid(u) and u or nil
    return C.util
end

local function npcManager(pc)
    if valid(C.mgr) then return C.mgr end
    local u = util()
    if not u then return nil end
    local m = u:GetNPCManager(pc)
    C.mgr = valid(m) and m or nil
    return C.mgr
end

local function dungeonSystem()
    if valid(C.ds) then return C.ds end
    local now = os.clock()
    if now - C.dsAt < 30 then return nil end
    C.dsAt = now
    local d = FindFirstOf("PalDungeonWorldSubsystem")
    C.ds = valid(d) and d or nil
    return C.ds
end

-- "day 77 03:42" from game ticks
local function gameClock(ticks)
    local s = ticks // 10000000
    return string.format("day %d %02d:%02d", s // 86400, (s % 86400) // 3600, (s % 3600) // 60)
end

local function guidKey(g)
    return string.format("%08X%08X%08X%08X", g.A & 0xffffffff, g.B & 0xffffffff, g.C & 0xffffffff, g.D & 0xffffffff)
end

-- the fixed dungeons (18): collected once per world (they are always loaded).
-- Collecting walks all 148 dungeon instances (~20 ms), so it is repeated only
-- when an entry became invalid, or every 30 s while the list is still empty.
-- (Until 2026-11-18 it was repeated every 5 minutes: a 15-27 ms tick each time.)
local function fixedDungeons()
    local now = os.clock()
    if C.fixed and (#C.fixed > 0 or now - C.fixedAt < 30) then
        local ok = true
        for _, e in ipairs(C.fixed) do if not valid(e.m) then ok = false; break end end
        if ok then return C.fixed end
    end
    local ds = dungeonSystem()
    if not ds then return {} end
    local list = {}
    pcall(function()
        ds.InstanceModelMap:ForEach(function(k, v)
            local m = v:get()
            if valid(m) and m:IsA("/Script/Pal.PalDungeonInstanceModelFixedDungeon") then
                list[#list + 1] = { m = m, key = guidKey(m.DungeonInstanceId) }
            end
        end)
    end)
    C.fixed = list
    C.fixedAt = now
    return list
end

---------------------------------------------------------------------------
-- saved timers: one line per entry, "boss<TAB>name<TAB>seconds" / "dungeon<TAB>id<TAB>seconds"
---------------------------------------------------------------------------
local function stateFile()
    local dir = M.dir or _G.BR_DIR     -- set by the loader
    if dir then return dir .. "/br_state.txt" end
    return nil
end

function M.load()
    S.loaded = true
    local p = stateFile()
    if not p then return end
    local f = io.open(p, "rb")
    if not f then return end
    local n = 0
    for line in f:lines() do
        local kind, key, sec = line:match("^(%a+)\t([^\t]+)\t([%d%.]+)")
        sec = tonumber(sec)
        if kind == "boss" and sec then S.boss[key] = S.boss[key] or { elapsed = sec }; n = n + 1 end
        if kind == "dungeon" and sec then S.dungeon[key] = S.dungeon[key] or { elapsed = sec }; n = n + 1 end
    end
    f:close()
    if n > 0 then log("restored " .. n .. " running timer(s)") end
end

function M.save()
    S.dirty = false
    S.savedAt = os.clock()
    local p = stateFile()
    if not p then return end
    local f = io.open(p, "wb")
    if not f then return end
    for k, e in pairs(S.boss) do f:write(string.format("boss\t%s\t%.0f\n", k, e.elapsed)) end
    for k, e in pairs(S.dungeon) do f:write(string.format("dungeon\t%s\t%.0f\n", k, e.elapsed)) end
    f:close()
end

---------------------------------------------------------------------------
-- field bosses
---------------------------------------------------------------------------
local function fieldTick(pc, dt, nowTicks)
    local mgr = npcManager(pc)
    if not mgr then return end
    local need = CFG.field_minutes * 60
    local seen = {}
    mgr.RespawnDisableFlag:ForEach(function(k, v)
        if v:get() ~= true then return end
        local name = k:get():ToString()
        seen[name] = true
        local e = S.boss[name]
        if not e then
            e = { elapsed = 0 }
            S.boss[name] = e
            S.dirty = true
            log(string.format("field boss defeated: %s - can appear again in %d min (game time %s)", name, CFG.field_minutes, gameClock(nowTicks)))
        end
        e.elapsed = e.elapsed + dt
        if e.elapsed >= need then
            v:set(false)
            S.boss[name] = nil
            S.dirty = true
            S.released = (S.released or 0) + 1
            log("field boss can appear again: " .. name)
        end
    end)
    -- the game cleared a flag by itself (or another world was loaded)
    for name in pairs(S.boss) do
        if not seen[name] then
            S.dirty = true
            log(string.format("field boss flag gone (cleared by the game) after %.1f min: %s (game time %s)", S.boss[name].elapsed / 60, name, gameClock(nowTicks)))
            S.boss[name] = nil
        end
    end
end

---------------------------------------------------------------------------
-- fixed dungeons
---------------------------------------------------------------------------
local function int(x) return math.tointeger(math.floor(x)) or 0 end

-- prevCool: the minutes the entrances had until this very tick (only given on
-- the tick that changed them). A boss found dead for the first time on that
-- tick died under the OLD minutes, so its age is worked out with those.
local function dungeonTick(dt, nowTicks, prevCool)
    local need = CFG.dungeon_minutes * 60
    local total = (prevCool or S.coolWritten or VANILLA_DUNGEON_MIN) * 60
    local seen = {}
    for _, d in ipairs(fixedDungeons()) do
        local m = d.m
        if valid(m) and tonumber(m.BossState) == 1 then   -- EPalDungeonInstanceBossState::Dead
            seen[d.key] = true
            local at = m.RespawnBossTimeAt.Ticks
            local e = S.dungeon[d.key]
            if not e then
                -- first time seen: the game's own timer tells how long ago the boss died
                local left = (at - nowTicks) / S.rate
                e = { elapsed = math.max(0, math.min(total, total - left)) }
                S.dungeon[d.key] = e
                S.dirty = true
                log(string.format("dungeon boss dead (lv %s): %.0f min passed, returns after %d min", tostring(m.Level), e.elapsed / 60, CFG.dungeon_minutes))
            end
            e.elapsed = e.elapsed + dt
            local left = need - e.elapsed
            if left <= 0 then
                if not e.fired then
                    e.fired = os.clock()
                    m.RespawnBossTimeAt.Ticks = int(nowTicks - 10000000)
                    log(string.format("dungeon boss (lv %s): time is up, respawn time set to now", tostring(m.Level)))
                elseif os.clock() - e.fired > 120 and not e.warned then
                    e.warned = true
                    log(string.format("WARNING dungeon boss (lv %s) did not come back within 2 min after its time was up", tostring(m.Level)))
                end
            else
                local target = nowTicks + left * S.rate
                if math.abs(at - target) > 30 * S.rate then
                    m.RespawnBossTimeAt.Ticks = int(target)
                end
            end
        end
    end
    for key, e in pairs(S.dungeon) do
        if not seen[key] then
            S.dungeon[key] = nil
            S.dirty = true
            if e.fired then log("dungeon boss is back") end
        end
    end
end

-- write the chosen minutes into the entrances and random-dungeon points
-- (once per world and whenever the setting changes: this is the only search)
local function applyStatic()
    local minutes = CFG.enabled and CFG.dungeon_minutes or VANILLA_DUNGEON_MIN
    local want = C.world .. ":" .. minutes
    if S.applied == want then return end
    local ds = dungeonSystem()
    if not ds then return end
    S.applied = want
    local nEnt, prev = 0, nil
    for _, e in ipairs(FindAllOf("PalDungeonFixedEntrance") or {}) do
        if valid(e) then
            if not prev then prev = e.RespawnCoolTimeMinutesAfterBossDefeated end
            e.RespawnCoolTimeMinutesAfterBossDefeated = minutes
            nEnt = nEnt + 1
        end
    end
    S.coolWritten = minutes
    local nMark = 0
    pcall(function()
        ds.MarkerPointDataMap:ForEach(function(k, v)
            local sp = v:get().SpawnParameter
            -- one point has interval 0 (always there): left alone
            if sp.RespawnInterval > 0 and sp.RespawnInterval ~= minutes then
                sp.RespawnInterval = minutes
                nMark = nMark + 1
            end
        end)
    end)
    log(string.format("dungeons: %d min written to %d fixed entrances (was %s) and %d random-dungeon points", minutes, nEnt, tostring(prev), nMark))
    return prev
end

---------------------------------------------------------------------------
-- tick (called every second by the loader; real work every 5 s)
---------------------------------------------------------------------------
function M.tick()
    local now = os.clock()
    if S.lastRun and now - S.lastRun < 5 then return end
    S.lastRun = now
    if not S.loaded then M.load() end
    local pc = localHost()
    if not pc then S.lastAt = nil; S.lastTicks = nil; return end
    -- A world that has just started is still loading its dungeons and
    -- spawners. Touch nothing for the first 20 s after the host shows up in
    -- it (2026-11-20: the game crashed inside a Lua -> game call in the very
    -- tick in which the world began play).
    if C.graceWorld ~= C.world then C.graceWorld = C.world; C.graceAt = now end
    if now - (C.graceAt or now) < WORLD_GRACE then S.lastAt = nil; S.lastTicks = nil; return end
    local gs = gameState()
    if not gs then return end
    local nowTicks = gs.WorldTime.Ticks
    -- play time since the last tick (pauses and long hitches are not counted twice)
    local dt = 0
    if S.lastAt then
        local raw = now - S.lastAt
        dt = math.max(0, math.min(raw, 15))
        if S.lastTicks and raw >= 2 and raw <= 15 then
            local r = (nowTicks - S.lastTicks) / raw
            if r > 20 * 10000000 and r < 100 * 10000000 then S.rate = S.rate * 0.8 + r * 0.2 end
        end
    end
    S.lastAt = now
    S.lastTicks = nowTicks

    local prevCool = applyStatic()
    if CFG.enabled then
        local ok1, e1 = pcall(fieldTick, pc, dt, nowTicks)
        if not ok1 then log("field boss error: " .. tostring(e1)) end
        local ok2, e2 = pcall(dungeonTick, dt, nowTicks, prevCool)
        if not ok2 then log("dungeon error: " .. tostring(e2)) end
    end
    if S.dirty or (now - S.savedAt > 30 and (next(S.boss) or next(S.dungeon))) then M.save() end
end

---------------------------------------------------------------------------
-- commands (br_cmd.txt): status | set field N | set dungeon N | now
---------------------------------------------------------------------------
function M.command(line)
    local a, b, c = line:match("^%s*(%S+)%s*(%S*)%s*(%S*)")
    if a == "status" then
        log(string.format("STATUS on=%s field=%d min dungeon=%d min rate=%.1f game s per s", tostring(CFG.enabled), CFG.field_minutes, CFG.dungeon_minutes, S.rate / 10000000))
        for k, e in pairs(S.boss) do log(string.format("STATUS field boss %s: %.1f of %d min", k, e.elapsed / 60, CFG.field_minutes)) end
        for k, e in pairs(S.dungeon) do log(string.format("STATUS dungeon %s: %.1f of %d min%s", k, e.elapsed / 60, CFG.dungeon_minutes, e.fired and " (time up)" or "")) end
    elseif a == "set" and tonumber(c) then
        -- for tests; with the settings page loaded the page value comes back within 2 s
        if b == "field" then CFG.field_minutes = tonumber(c) elseif b == "dungeon" then CFG.dungeon_minutes = tonumber(c) end
        log(string.format("SET field=%d min dungeon=%d min", CFG.field_minutes, CFG.dungeon_minutes))
        S.lastRun = nil
    elseif a == "now" then
        for _, e in pairs(S.boss) do e.elapsed = 1e9 end
        for _, e in pairs(S.dungeon) do e.elapsed = 1e9 end
        S.lastRun = nil
        log("NOW all running timers set to finished")
    else
        log("unknown command: " .. tostring(line))
    end
end

return M
