-- UnlockAllWaypoints logic (re-read live by main.lua every 2 s).
--
-- VERIFIED 2026-11-17 on the host:
--  * 174 statues (APalLevelObjectUnlockableFastTravelPoint; towers are the
--    subclass BP_LevelObject_UnlockMapPoint_C). Per-player unlock flags:
--    PlayerState.RecordData.FastTravelPointUnlockFlag.Items { Key, Value },
--    Key = the statue's LevelObjectInstanceId as 32 hex digits.
--  * The game accepts statue:OnTriggerInteract(playerBody, 26) only when the
--    statue's interact box is close to the player (box 200 below: OK,
--    500 below: refused). The box is 100 above a normal statue's origin and
--    2470 above a tower's origin.
--  * INSTANT METHOD: move the statue so its interact box sits 150 below the
--    player, interact, move it back - all in one call (one frame). The flag
--    is set at once, the statue returns to its exact place, it is never
--    drawn at the player, and the player does not move.
--    FTPoint33 and WatchTower_1 unlocked this way.
--  * NEVER call NetworkPlayerComponent:RequestInteractLevelObject_ToServer
--    from Lua (TScriptInterface parameter) - it crashed the game.
--  * Old method kept only as a fallback for a friend's own game: the TOUR
--    (teleport the player to each statue). Works, but takes minutes.

local M = { version = "2" }
local TAG = "[UnlockAllWaypoints] "
local function log(m) print(TAG .. tostring(m) .. "\n") end
M.say = function(msg) log(msg) end   -- main.lua replaces this with chat output

M.modsDir = "Mods"
pcall(function()
    -- this chunk is loaded with the name "@wp_logic.lua", so ask the loader's own file instead
    local i = 2
    while true do
        local info = debug.getinfo(i, "S")
        if not info then break end
        local d = (info.source or ""):gsub("^@", ""):match("^(.*)[/\\]UnlockAllWaypoints[/\\]Scripts[/\\]")
        if d then M.modsDir = d; break end
        i = i + 1
    end
end)

local UNLOCK_FAST_TRAVEL = 26  -- EPalInteractiveObjectIndicatorType::UnlockFastTravel
local BOX_BELOW = 150           -- interact box this far below the player
local PER_TICK = 5              -- statues per 0.5 s tick

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

local function vec(v) return string.format("%.0f %.0f %.0f", v.X, v.Y, v.Z) end

---------------------------------------------------------------------------
-- settings (pushed by main.lua)
---------------------------------------------------------------------------
M.cfg = { enabled = true, auto = true, friends = true }
function M.setSettings(v)
    if type(v) ~= "table" then return end
    if v.enabled ~= nil then M.cfg.enabled = v.enabled end
    if v.auto ~= nil then M.cfg.auto = v.auto end
    if v.include_friends ~= nil then M.cfg.friends = v.include_friends end
end

---------------------------------------------------------------------------
-- players / statues / flags
---------------------------------------------------------------------------
-- PERFORMANCE (measured 2026-11-18): FindAllOf / FindFirstOf walk every object
-- in the game: ~30 ms EACH (StaticFindObject ~15 ms). Reading the game state's
-- PlayerArray takes 0.015 ms. So nothing that runs on a timer may call them;
-- the game state is found once and kept.
_G.WP_GS = _G.WP_GS or { gs = nil, at = -100 }
-- a new world's game state appeared: forget the old one
if not _G.WP_GS_NOTIFY then
    _G.WP_GS_NOTIFY = pcall(NotifyOnNewObject, "/Script/Engine.GameStateBase", function()
        local c = _G.WP_GS
        if c then c.gs = nil; c.at = -100 end
    end)
end
local function gameState()
    local c = _G.WP_GS
    if valid(c.gs) then return c.gs end
    local now = os.clock()
    if now - c.at < 10 then return nil end   -- look again at most every 10 s
    c.at = now
    local gs = FindFirstOf("PalGameStateInGame")
    c.gs = valid(gs) and gs or nil
    return c.gs
end

function M.players()
    local out = {}
    local gs = gameState()
    if not gs then return out end
    local arr = gs.PlayerArray
    for i = 1, #arr do
        local ps = arr[i]
        pcall(function()
            if not valid(ps) then return end
            local pc = ps:GetPlayerController()
            if not valid(pc) then return end
            local rd = ps.RecordData
            if not valid(rd) then return end
            local isLocal = pc:IsLocalController()
            local name = "?"
            pcall(function() name = str(ps:GetPlayerName()) end)
            out[#out + 1] = { pc = pc, ps = ps, rd = rd, name = name, isLocal = isLocal, key = rd:GetFullName() }
        end)
    end
    return out
end

local function localPlayer()
    for _, p in ipairs(M.players()) do if p.isLocal then return p end end
    return nil
end

-- only the world host can decide for other players
function M.isHost()
    local p = localPlayer()
    if not p then return false end
    local ok, auth = pcall(function() return p.pc:HasAuthority() end)
    return ok and auth or false
end

-- the player's body (while riding, pc.Pawn is the pal)
local function body(p)
    local b = nil
    pcall(function() if p.pc:IsRiding() then b = p.pc:GetRiderCharacter() end end)
    if not valid(b) then pcall(function() b = p.pc.Pawn end) end
    return valid(b) and b or nil
end

function M.flags(rd)
    local set, n = {}, 0
    rd.FastTravelPointUnlockFlag.Items:ForEach(function(i, e)
        local it = e:get()
        set[str(it.Key)] = it.Value
        n = n + 1
    end)
    return set, n
end

local function hexId(a)
    local ok, s = pcall(function()
        local g = a.LevelObjectInstanceId
        return string.format("%08X%08X%08X%08X", g.A & 0xFFFFFFFF, g.B & 0xFFFFFFFF, g.C & 0xFFFFFFFF, g.D & 0xFFFFFFFF)
    end)
    return ok and s or nil
end

-- FindAllOf costs ~30 ms, so it is only used when somebody really has
-- something locked (see runTick: flag count vs. the remembered statue count)
_G.WP_STATUES = _G.WP_STATUES or { count = nil }
local function statues()
    local all = FindAllOf("PalLevelObjectUnlockableFastTravelPoint") or {}
    if #all > 0 then _G.WP_STATUES.count = #all end
    return all
end

-- cheap: number of unlock flags this player has
local function flagCount(rd)
    local n = 0
    pcall(function() n = #rd.FastTravelPointUnlockFlag.Items end)
    return n
end

local function findStatue(id)
    for _, a in ipairs(statues()) do
        if valid(a) and str(a.FastTravelPointID) == id then return a end
    end
    return nil
end

function M.lockedFor(p)
    local set = M.flags(p.rd)
    local out = {}
    for _, a in ipairs(statues()) do
        if valid(a) then
            local h = hexId(a)
            if h and set[h] ~= true then out[#out + 1] = a end
        end
    end
    return out
end

---------------------------------------------------------------------------
-- instant unlock of one statue for one player (see header)
---------------------------------------------------------------------------
function M.instant(p, b, a)
    local h = hexId(a)
    if not h then return false, "no id" end
    local me, t = b:K2_GetActorLocation(), a:K2_GetActorLocation()
    local off = { X = 0, Y = 0, Z = 100 }
    pcall(function()
        local bl = a.BP_InteractableBox:K2_GetComponentLocation()
        off = { X = bl.X - t.X, Y = bl.Y - t.Y, Z = bl.Z - t.Z }
    end)
    local root = a.RootComponent
    local mob = tonumber(root.Mobility)
    local rot = { Pitch = 0, Yaw = 0, Roll = 0 }
    pcall(function() local r = a:K2_GetActorRotation(); rot = { Pitch = r.Pitch, Yaw = r.Yaw, Roll = r.Roll } end)
    if mob ~= 2 then root:SetMobility(2) end
    local moved = a:K2_TeleportTo({ X = me.X - off.X, Y = me.Y - off.Y, Z = me.Z - off.Z - BOX_BELOW }, rot)
    local okI = pcall(function()
        a.EnableRequestUnlock = true
        a:OnTriggerInteract(b, UNLOCK_FAST_TRAVEL)
    end)
    local got = false
    pcall(function() got = (M.flags(p.rd)[h] == true) end)
    -- always put it back, whatever happened
    local back = a:K2_TeleportTo({ X = t.X, Y = t.Y, Z = t.Z }, rot)
    if mob ~= 2 then pcall(function() root:SetMobility(mob) end) end
    local n = a:K2_GetActorLocation()
    local exact = math.abs(n.X - t.X) < 1 and math.abs(n.Y - t.Y) < 1 and math.abs(n.Z - t.Z) < 1
    if not exact then log(string.format("WARNING %s not back in place: %s (was %s)", str(a.FastTravelPointID), vec(n), vec(t))) end
    return got, string.format("moved=%s interact=%s back=%s exact=%s", tostring(moved), tostring(okI), tostring(back), tostring(exact))
end

---------------------------------------------------------------------------
-- fallback: tour (teleport the local player to each statue)
---------------------------------------------------------------------------
_G.WP_RUN = _G.WP_RUN or nil

local function teleport(p, x, y, z)
    p.ps.SyncTeleportComp:SyncTeleport({ Location = { X = x, Y = y, Z = z }, Rotation = { X = 0, Y = 0, Z = 0, W = 1 },
        bIsFadeInSkip = false, bIsFadeOutSkip = false, bIsPlaySyncTeleportStartSE = false })
end

local function tourActive()
    return _G.WP_RUN ~= nil and _G.WP_RUN.phase ~= "done"
end

function M.tourStart()
    if tourActive() then return end
    local p = localPlayer()
    if not p then return end
    local b = body(p)
    if not b then return end
    local me = b:K2_GetActorLocation()
    local ids = {}
    for _, a in ipairs(M.lockedFor(p)) do ids[#ids + 1] = str(a.FastTravelPointID) end
    if #ids == 0 then M.say("All waypoints are already unlocked"); return end
    _G.WP_RUN = { ids = ids, idx = 1, phase = "go", ok = 0, fail = 0, failed = {},
                  home = { X = me.X, Y = me.Y, Z = me.Z }, t = os.time() }
    M.say(string.format("Visiting %d waypoints - you will be moved around for a few minutes, then brought back. Don't move.", #ids))
end

local function tourTick()
    local R = _G.WP_RUN
    local p = localPlayer()
    if not p then return end
    local b = body(p)
    if not b then return end
    local now = os.time()
    if R.idx > #R.ids then
        teleport(p, R.home.X, R.home.Y, R.home.Z)
        local _, n = M.flags(p.rd)
        M.say(string.format("Waypoints done: %d unlocked, %d failed (%d total now). Back to start.", R.ok, R.fail, n))
        if #R.failed > 0 then log("failed: " .. table.concat(R.failed, " ")) end
        R.phase = "done"
        return
    end
    local id = R.ids[R.idx]
    local a = findStatue(id)
    local function nextOne(good)
        if good then R.ok = R.ok + 1 else R.fail = R.fail + 1; R.failed[#R.failed + 1] = id end
        R.idx = R.idx + 1
        R.phase = "go"
        if R.idx % 10 == 0 then M.say(string.format("Waypoints: %d / %d", R.idx - 1, #R.ids)) end
    end
    if not a then nextOne(false); return end
    local h = hexId(a)
    if R.phase == "go" then
        if M.flags(p.rd)[h] == true then nextOne(true); return end
        local bl = a:K2_GetActorLocation()
        pcall(function() bl = a.BP_InteractableBox:K2_GetComponentLocation() end)
        teleport(p, bl.X + 250, bl.Y, bl.Z + 50)
        R.phase = "wait"; R.t = now
    elseif R.phase == "wait" then
        local busy = false
        pcall(function() busy = p.ps.SyncTeleportComp:IsTeleporting() end)
        local me = b:K2_GetActorLocation()
        local bl = a:K2_GetActorLocation()
        pcall(function() bl = a.BP_InteractableBox:K2_GetComponentLocation() end)
        local d = math.sqrt((me.X - bl.X) ^ 2 + (me.Y - bl.Y) ^ 2 + (me.Z - bl.Z) ^ 2)
        if not busy and d < 450 then
            pcall(function() a.EnableRequestUnlock = true; a:OnTriggerInteract(b, UNLOCK_FAST_TRAVEL) end)
            R.phase = "check"; R.t = now
        elseif now - R.t > 20 then
            log(string.format("%s: could not get close (dist %.0f), skipped", id, d))
            nextOne(false)
        end
    elseif R.phase == "check" then
        if M.flags(p.rd)[h] == true then
            nextOne(true)
        elseif now - R.t > 6 then
            log(id .. ": interact did not unlock, skipped")
            nextOne(false)
        end
    end
end

---------------------------------------------------------------------------
-- main loop: instant unlock for the local player, and on the host also for
-- friends. Automatic (setting) or on request (key).
---------------------------------------------------------------------------
_G.WP_STATE = _G.WP_STATE or {}
local S = _G.WP_STATE
S.fail = S.fail or {}          -- player key -> { hex -> attempts }
S.seen = S.seen or {}          -- player key -> os.time() first seen with a body
S.count = S.count or {}        -- player key -> unlocked in the current batch
S.bad = S.bad or {}            -- player key -> true: instant method refused for this player
S.nextScan = S.nextScan or 0
S.manual = S.manual or false

-- key press / "start" command
function M.start()
    if tourActive() then M.say("Already running"); return end
    local p = localPlayer()
    if not p then return end
    if S.bad[p.key] then
        -- instant method does not work on this side (a friend's own game): use the tour
        M.tourStart()
        return
    end
    S.manual = true
    S.manualFound = 0
    S.nextScan = 0
    S.fail = {}
    log("manual run requested")
end

function M.stop()
    if tourActive() then
        local R = _G.WP_RUN
        R.idx = #R.ids + 1
        R.phase = "go"
        M.say("Stopped, going back")
    end
    S.manual = false
end

-- F11 in main.lua
function M.toggle()
    if tourActive() then M.stop() else M.start() end
end

function M.runTick()
    if tourActive() then tourTick(); return end
    if not M.cfg.enabled then return end
    if not (S.manual or M.cfg.auto) then return end
    local now = os.time()
    if now < S.nextScan then return end
    local host = M.isHost()
    local worked, pending = false, false
    for _, p in ipairs(M.players()) do
        if (p.isLocal or (host and M.cfg.friends)) and not S.bad[p.key] then
            local b = body(p)
            if b then
                S.seen[p.key] = S.seen[p.key] or now
                local total = _G.WP_STATUES.count
                if total and flagCount(p.rd) >= total and (S.count[p.key] or 0) == 0 then
                    -- everything already unlocked for this player: nothing to search for
                elseif now - S.seen[p.key] >= 8 then   -- let the world settle after joining
                    local fails = S.fail[p.key] or {}
                    S.fail[p.key] = fails
                    local todo = {}
                    for _, a in ipairs(M.lockedFor(p)) do
                        if (fails[hexId(a)] or 0) < 2 then todo[#todo + 1] = a end
                    end
                    local n = math.min(PER_TICK, #todo)
                    for i = 1, n do
                        local a = todo[i]
                        local okC, got = pcall(M.instant, p, b, a)
                        got = okC and got
                        if got then
                            S.count[p.key] = (S.count[p.key] or 0) + 1
                            worked = true
                        else
                            local h = hexId(a)
                            fails[h] = (fails[h] or 0) + 1
                            if (S.count[p.key] or 0) == 0 and fails[h] >= 2 and not S.triedOK then
                                -- the very first statue was refused twice: this method does not
                                -- work for this player from this machine
                                S.bad[p.key] = true
                                if p.isLocal then
                                    log("instant unlock refused here (not the host?). Press the key to use the tour instead.")
                                else
                                    log("instant unlock refused for " .. p.name .. " from the host; they can press the key in their own game")
                                end
                                break
                            end
                        end
                    end
                    if (S.count[p.key] or 0) > 0 then S.triedOK = true end
                    if #todo > n then
                        pending = true
                    elseif (S.count[p.key] or 0) > 0 then
                        local _, total = M.flags(p.rd)
                        local left = 0
                        for _, a in ipairs(M.lockedFor(p)) do left = left + 1 end
                        M.say(string.format("%s: %d waypoints unlocked (%d total%s)", p.name, S.count[p.key], total,
                            left > 0 and (", " .. left .. " refused") or ""))
                        S.manualFound = (S.manualFound or 0) + S.count[p.key]
                        S.count[p.key] = 0
                    end
                else
                    pending = true
                end
            end
        end
    end
    if pending or worked then
        S.nextScan = 0                 -- keep going next tick
    else
        if S.manual then
            if (S.manualFound or 0) == 0 then M.say("All waypoints are already unlocked") end
            S.manual = false
        end
        S.nextScan = now + 10          -- idle: look again in 10 s (new players, new characters)
    end
end

---------------------------------------------------------------------------
-- test commands (Scripts/wp_cmd.txt): start, stop, tour, status <id>,
-- locked, instant <id>, comp <id>
---------------------------------------------------------------------------
function M.command(sub, arg)
    if sub == "start" then M.start()
    elseif sub == "stop" then M.stop()
    elseif sub == "tour" then M.tourStart()
    elseif sub == "perf" then
        -- read-only timing of the ways to find players / objects
        local function ms(n, f) local t = os.clock(); for i = 1, n do f() end; return (os.clock() - t) * 1000 / n end
        local a = ms(5, function() return FindAllOf("PalPlayerController") end)
        local b = ms(5, function() return FindFirstOf("PalGameStateInGame") end)
        local c = ms(3, function() return FindAllOf("PalLevelObjectUnlockableFastTravelPoint") end)
        local gs = FindFirstOf("PalGameStateInGame")
        local nPlayers, nCtrl = 0, 0
        local d = ms(200, function()
            nPlayers, nCtrl = 0, 0
            local arr = gs.PlayerArray
            for i = 1, #arr do
                local ps = arr[i]
                if valid(ps) then
                    nPlayers = nPlayers + 1
                    local pc = ps:GetPlayerController()
                    if valid(pc) then nCtrl = nCtrl + 1 end
                end
            end
        end)
        local path = gs:GetFullName():match("^%S+%s+(.*)$")
        local found = false
        local e = ms(3, function() local o = StaticFindObject(path); found = valid(o) end)
        log(string.format("PERF FindAllOf(controller)=%.1f ms  FindFirstOf(gamestate)=%.1f ms  FindAllOf(statues)=%.1f ms  PlayerArray walk=%.3f ms (%d players, %d controllers)  StaticFindObject=%.3f ms (found=%s)",
            a, b, c, d, nPlayers, nCtrl, e, tostring(found)))
    elseif sub == "verify" then
        -- read-only check of two other mods after a restart (one search per
        -- class, only when this command is typed):
        --  * FastBreeding: BreedRequiredRealTime on every farm object
        --  * SpeedBoost: the local pawn's speeds now vs. its class defaults
        for _, cls in ipairs({ "PalMapObjectBreedFarmModel", "PalMapObjectBreedFarmParameterComponent",
            "PalMapObjectMultiHatchingEggWithBreedModel", "PalMapObjectMultiHatchingEggWithBreedParameterComponent" }) do
            local vals, n = {}, 0
            for _, o in ipairs(FindAllOf(cls) or {}) do
                if valid(o) then
                    pcall(function()
                        local t = o.BreedRequiredRealTime
                        if type(t) == "number" then n = n + 1; vals[string.format("%.2f", t)] = (vals[string.format("%.2f", t)] or 0) + 1 end
                    end)
                end
            end
            local parts = {}
            for v, c in pairs(vals) do parts[#parts + 1] = c .. " x " .. v .. " s" end
            log("VERIFY breed " .. cls .. ": " .. n .. " objects: " .. table.concat(parts, ", "))
        end
        local p = localPlayer(); if not p then log("VERIFY no local player"); return end
        local pawn = p.pc.Pawn
        if not valid(pawn) then log("VERIFY no pawn"); return end
        local mc = pawn:GetPalCharacterMovementComponent()
        if not valid(mc) then log("VERIFY no movement component"); return end
        local dmc = nil
        local cls = pawn:GetClass()
        if valid(cls) then
            local cdo = cls:GetCDO()
            if valid(cdo) then
                local c = cdo.CharacterMovement
                if valid(c) then dmc = c end
            end
        end
        local parts = {}
        for _, f in ipairs({ "SlowWalkSpeed_Default", "WalkSpeed_Default", "RunSpeed_Default", "SprintMaxSpeed", "RideSprintSpeed_Default", "FlySpeed_Default", "FlySprintSpeed_Default" }) do
            pcall(function()
                local now = mc[f]
                local def = dmc and dmc[f] or nil
                parts[#parts + 1] = string.format("%s %s -> %.0f", f, def and string.format("%.0f", def) or "?", now)
            end)
        end
        local riding = false
        pcall(function() riding = p.pc:IsRiding() end)
        log("VERIFY speed pawn=" .. str(pawn:GetFName()) .. " riding=" .. tostring(riding) .. " (class default -> now): " .. table.concat(parts, ", "))
    elseif sub == "run" then
        -- run a Lua file under Mods/ once, in the game thread (live experiments
        -- without a restart), e.g. "run UnlockAllWaypoints/Scripts/dbg.lua".
        -- The file gets one table: { log, valid, str, localPlayer, M }.
        local f = io.open(M.modsDir .. "/" .. arg, "rb")
        if not f then log("RUN cannot open " .. arg); return end
        local code = f:read("a"); f:close()
        local chunk, err = load(code, "@" .. arg)
        if not chunk then log("RUN " .. arg .. ": ERROR " .. tostring(err)); return end
        local ok, e = pcall(chunk, { log = log, valid = valid, str = str, localPlayer = localPlayer, M = M })
        log("RUN " .. arg .. (ok and ": done" or (": FAILED " .. tostring(e))))
    elseif sub == "pstate" then
        -- read-only: what state is the local player's character in?
        local p = localPlayer(); if not p then log("PSTATE no local player"); return end
        local b = body(p); if not b then log("PSTATE no body"); return end
        local function g(f) local r = "?"; pcall(function() r = tostring(f()) end); return r end
        local util = StaticFindObject("/Script/Pal.Default__PalUtility")
        local l = b:K2_GetActorLocation()
        log("PSTATE body=" .. str(b:GetFName()) .. " loc=" .. vec(l)
            .. " riding=" .. g(function() return p.pc:IsRiding() end)
            .. " pawn=" .. g(function() return str(p.pc.Pawn:GetFName()) end)
            .. " teleporting=" .. g(function() return p.ps.SyncTeleportComp:IsTeleporting() end))
        log("PSTATE moveMode=" .. g(function() return b.CharacterMovement.MovementMode end)
            .. " custom=" .. g(function() return b.CharacterMovement.CustomMovementMode end)
            .. " vel=" .. g(function() local v = b:GetVelocity(); return vec(v) end)
            .. " dead=" .. g(function() return util:IsDead(b) end)
            .. " dying=" .. g(function() return util:IsDyingPlayer(b) end)
            .. " hp=" .. g(function() return b.CharacterParameterComponent:GetHP().Value end))
        -- CRASH 2026-11-17 23:36: GetCurrentAction() returned a null object (no
        -- action after respawn) and calling :GetClass() on it crashed the game
        -- (pcall does not catch that). ALWAYS check valid() before calling a
        -- method on an object that came back from the game.
        local actName = "none"
        local ac = b.ActionComponent
        if valid(ac) then
            local cur = ac.CurrentAction
            if valid(cur) then actName = g(function() return str(cur:GetFName()) end) end
        end
        log("PSTATE action=" .. actName)
    elseif sub == "pdeath" then
        -- read-only: death penalty mode and whether the game-over screen exists
        local p = localPlayer(); if not p then return end
        local function g(f) local r = "?"; pcall(function() r = tostring(f()) end); return r end
        local ws = FindAllOf("PalUIGameOver") or {}
        local parts = {}
        for _, w in ipairs(ws) do
            parts[#parts + 1] = str(w:GetFName()) .. " inViewport=" .. g(function() return w:IsInViewport() end)
                .. " visible=" .. g(function() return w:IsVisible() end)
        end
        log("PDEATH penaltyMode=" .. g(function() return p.ps:GetDeathPenaltyModeForGameOverUI() end)
            .. " gameOverWidgets=" .. #ws .. " " .. table.concat(parts, "; "))
    elseif sub == "respawn" then
        -- the same request the game-over screen's Respawn button sends
        local p = localPlayer(); if not p then return end
        local ok, e = pcall(function() p.ps:RequestRespawn() end)
        log("RESPAWN requested ok=" .. tostring(ok) .. " " .. tostring(e or ""))
    elseif sub == "syntax" then
        -- compile-only check of a Lua file under Mods/ (nothing is run), e.g. "syntax UnlockAllWaypoints/Scripts/main.lua"
        local src = debug.getinfo(1, "S").source or ""
        local f = io.open(M.modsDir .. "/" .. arg, "rb")
        if not f then log("SYNTAX cannot open " .. arg); return end
        local code = f:read("a"); f:close()
        local chunk, err = load(code, "@" .. arg)
        log("SYNTAX " .. arg .. ": " .. (chunk and "OK" or ("ERROR " .. tostring(err))))
    elseif sub == "locked" then
        for _, p in ipairs(M.players()) do
            local ids = {}
            for _, a in ipairs(M.lockedFor(p)) do ids[#ids + 1] = str(a.FastTravelPointID) end
            local _, n = M.flags(p.rd)
            log("LOCKED " .. p.name .. " local=" .. tostring(p.isLocal) .. " flags=" .. n .. " locked=" .. #ids .. ": " .. table.concat(ids, " "))
        end
    elseif sub == "instant" then
        local p = localPlayer(); if not p then return end
        local a = findStatue(arg); if not a then log("INSTANT no actor " .. arg); return end
        local got, info = M.instant(p, body(p), a)
        local _, n = M.flags(p.rd)
        log(string.format("INSTANT %s unlocked=%s %s flags=%d", arg, tostring(got), info, n))
    elseif sub == "status" then
        for _, p in ipairs(M.players()) do
            local set, n = M.flags(p.rd)
            local parts = {}
            for _, a in ipairs(statues()) do
                if str(a.FastTravelPointID) == arg then
                    local u = "?"
                    pcall(function() u = tostring(a:IsUnlocked()) end)
                    parts[#parts + 1] = string.format("%s flag=%s actorUnlocked=%s enableReq=%s at %s",
                        arg, tostring(set[hexId(a)]), u, tostring(a.EnableRequestUnlock), vec(a:K2_GetActorLocation()))
                end
            end
            log("STATUS " .. p.name .. " flags=" .. n .. " " .. table.concat(parts, "; "))
        end
    elseif sub == "comp" then
        local a = findStatue(arg); if not a then log("COMP no actor " .. arg); return end
        local t = a:K2_GetActorLocation()
        local bl = a.BP_InteractableBox:K2_GetComponentLocation()
        log(string.format("COMP %s class=%s origin=%s box d=(%.0f %.0f %.0f) mobility=%s", arg, str(a:GetClass():GetFName()),
            vec(t), bl.X - t.X, bl.Y - t.Y, bl.Z - t.Z, tostring(a.RootComponent.Mobility)))
    else
        log("unknown command: " .. tostring(sub))
    end
end

-- GUEST (only until the next game start): BossRespawn is a new mod, and new
-- mods load only when the game starts. Until then its logic file runs inside
-- this mod so it can be tested in the running game. Stands down by itself as
-- soon as the real BossRespawn mod is loaded.
_G.WP_GUEST = _G.WP_GUEST or { n = 0 }
local function guest()
    local G = _G.WP_GUEST
    G.n = G.n + 1
    if G.n % 2 ~= 0 then return end          -- once per second
    if G.standDown == nil or G.n % 20 == 0 then
        local loaded = false
        pcall(function() loaded = ModRef:GetSharedVariable("BossRespawn.Loaded") == true end)
        G.standDown = loaded
    end
    if G.standDown then return end
    local dir = M.modsDir .. "/BossRespawn/Scripts"
    if G.n % 4 == 0 then                     -- every 2 s: new version of the file? a command?
        local f = io.open(dir .. "/br_logic.lua", "rb")
        if f then
            local src = f:read("a"); f:close()
            if src and src ~= "" and src ~= G.src then
                G.src = src
                local chunk, err = load(src, "@br_logic.lua")
                if not chunk then
                    log("guest br_logic.lua has an error: " .. tostring(err))
                else
                    local ok, mod = pcall(chunk)
                    if ok and type(mod) == "table" then
                        G.L = mod
                        mod.dir = dir
                        log("guest BossRespawn logic loaded - version " .. tostring(mod.version))
                    else
                        log("guest br_logic.lua failed to start: " .. tostring(mod))
                    end
                end
            end
        end
        local p = dir .. "/br_cmd.txt"
        local f2 = io.open(p, "rb")
        if f2 then
            local txt = f2:read("a") or ""
            f2:close()
            if not txt:match("^%s*$") then
                local w = io.open(p, "wb"); if w then w:close() end
                if G.L and G.L.command then
                    local ok, e = pcall(G.L.command, txt)
                    if not ok then log("guest command error: " .. tostring(e)) end
                end
            end
        end
    end
    if G.L and G.L.tick then
        local ok, e = pcall(G.L.tick)
        if not ok then log("guest tick error: " .. tostring(e)) end
    end
end

-- timing: how long does runTick take? (summary line every 30 s)
do
    _G.WP_PERF = _G.WP_PERF or { n = 0, total = 0, max = 0, since = os.clock() }
    local P = _G.WP_PERF
    local inner = M.runTick
    M.runTick = function(...)
        local t0 = os.clock()
        local r = inner(...)
        local okG, eG = pcall(guest)
        if not okG then log("guest error: " .. tostring(eG)) end
        local ms = (os.clock() - t0) * 1000
        P.n = P.n + 1; P.total = P.total + ms
        if ms > P.max then P.max = ms end
        local now = os.clock()
        if now - P.since >= 30 then
            -- watchdog: only speak up when a tick was slow enough to feel
            if P.max >= 10 then print(string.format("[UnlockAllWaypoints] SLOW %d ticks in %.0f s, avg %.2f ms, max %.0f ms\n", P.n, now - P.since, P.total / P.n, P.max)) end
            P.n, P.total, P.max, P.since = 0, 0, 0, now
        end
        return r
    end
end

return M
