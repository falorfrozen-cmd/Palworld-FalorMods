-- SpeedBoost
-- Player move/swim speed and mount ground/swim/fly speed x2.
--
-- How (verified in game):
--  * WalkSpeedMultiplierMap only SLOWS (the game uses the minimum value), so
--    ground speed is boosted by scaling the movement component's base speeds
--    (WalkSpeed_Default, RunSpeed_Default, SprintMaxSpeed, RideSprintSpeed_Default...).
--  * SwimSpeedMultiplierMap multiplies, so swim uses SetSwimSpeedMultiplier.
--  * Fly: FlySpeed_Default / FlySprintSpeed_Default are scaled.
-- Originals are remembered per component, so values never compound, and a
-- mount is restored to normal when you get off.
-- Host + every friend should have this mod (server and owning client must agree).
-- Performance: players come from the game state's PlayerArray (cheap), not
-- from FindAllOf (which costs ~30 ms per call).

local CFG = {
    PlayerMove = 2.0,
    PlayerSwim = 2.0,
    MountMove  = 2.0,
    MountSwim  = 2.0,
    MountFly   = 2.0,
    -- Host only: don't snap friends back (fixes stutter/rubber-banding while
    -- sprinting with boosted speed). Only affects other players' movement.
    TrustFriendMovement = true,
    Debug      = false,
}

local TAG = "[SpeedBoost] "
local function log(m) print(TAG .. tostring(m) .. "\n") end
local KEY = FName("SpeedBoostMod")

---------------------------------------------------------------------------
-- Settings page: Esc > Mod Options > Speed Boost (optional Workshop framework
-- "Mod Options Framework"). Changes apply live (within 0.25 s).
---------------------------------------------------------------------------
CFG.Enabled = true
local options = nil
local generation = 0
local settingsChanged = false
local function applySettings(v)
    if type(v) ~= "table" then return end
    if v.enabled ~= nil then CFG.Enabled = v.enabled end
    if v.player_move then CFG.PlayerMove = v.player_move end
    if v.player_swim then CFG.PlayerSwim = v.player_swim end
    if v.mount_move then CFG.MountMove = v.mount_move end
    if v.mount_swim then CFG.MountSwim = v.mount_swim end
    if v.mount_fly then CFG.MountFly = v.mount_fly end
    settingsChanged = true
    log(string.format("settings: on=%s player x%.1f swim x%.1f, mount x%.1f swim x%.1f fly x%.1f",
        tostring(CFG.Enabled), CFG.PlayerMove, CFG.PlayerSwim, CFG.MountMove, CFG.MountSwim, CFG.MountFly))
end
local function mult(key, label, tr, def)
    return { key = key, type = "number", label = label, labels = { tr = tr }, default = def, minimum = 1.0, maximum = 10.0, step = 0.1 }
end
local okReq, sdk = pcall(require, "PalModOptionsClient")
if okReq and sdk then
    options = sdk
    pcall(sdk.register_when_ready, {
        id = "BizimModlar.SpeedBoost",
        mod_folder = "SpeedBoost",
        title = "Speed Boost",
        titles = { tr = "Hız" },
        description = "Player and mount speed multipliers. 1.0 = normal speed. Every player should use the same values, otherwise the game pulls the speed back.",
        descriptions = { tr = "Oyuncu ve binek hız çarpanları. 1.0 = normal hız. Arkadaşında da aynı değerler olmalı, yoksa oyun hızı geri çeker." },
        version = 2,
        apply_mode = "event",
        options = {
            { key = "enabled", type = "boolean", label = "Enabled", labels = { tr = "Mod açık" }, default = true },
            { key = "player_section", type = "section", label = "Player", labels = { tr = "Oyuncu" } },
            mult("player_move", "Walk / run", "Yürüme / koşma", 2.0),
            mult("player_swim", "Swim", "Yüzme", 2.0),
            { key = "mount_section", type = "section", label = "Mount", labels = { tr = "Binek" } },
            mult("mount_move", "Ground", "Kara", 2.0),
            mult("mount_swim", "Swim", "Yüzme", 2.0),
            mult("mount_fly", "Fly", "Uçma", 2.0),
        },
    }, function(settings, err)
        if settings ~= nil then
            applySettings(settings)
            generation = sdk.generation()
            log("settings page ready (Esc > Mod Options)")
        else
            log("Mod Options unavailable, using defaults: " .. tostring(err))
        end
    end)
end
local function syncOptions()
    if not options then return end
    pcall(function()
        generation = select(1, options.sync(generation, function(values) applySettings(values) end))
    end)
end

local PLAYER_FIELDS = { "SlowWalkSpeed_Default", "WalkSpeed_Default", "RunSpeed_Default", "SprintMaxSpeed" }
local MOUNT_FIELDS  = { "SlowWalkSpeed_Default", "WalkSpeed_Default", "RunSpeed_Default", "RideSprintSpeed_Default", "SprintMaxSpeed" }
-- OverrideFlySpeed/OverrideFlySprintSpeed: when the game fills these (> 0) they
-- replace the *_Default fly speeds, which made the old x2 have no effect.
-- applyScaled skips fields that are 0, so unused overrides stay untouched.
local FLY_FIELDS    = { "FlySpeed_Default", "FlySprintSpeed_Default", "OverrideFlySpeed", "OverrideFlySprintSpeed" }

local controllers = {}
local players = {}   -- comp full name -> state (seen as a player this session)
local mounts = {}    -- comp full name -> state (currently ridden)
local compState = {} -- comp full name -> ONE shared state (orig values), used by both
                     -- paths so a component can never get two different "originals"

local function stateFor(comp, key)
    local st = compState[key]
    if not st then
        st = { comp = comp }
        compState[key] = st
    end
    return st
end

local function valid(o)
    if not o then return false end
    local ok, v = pcall(function() return o:IsValid() end)
    return ok and v
end

local function moveComp(char)
    local ok, comp = pcall(function() return char:GetPalCharacterMovementComponent() end)
    if ok and valid(comp) then return comp end
    return nil
end

-- Scale fields to orig*mult.
-- The original value is learned ONCE (first time we see the component, before
-- we touch it) and never re-learned. Re-learning caused a feedback loop on
-- mounts: the game derives some speeds from others (e.g. ride sprint from run
-- speed), the mod treated the already-boosted result as a new original and
-- doubled it again -> 2x, 4x, 8x, 16x, 32x...
-- Now the value is always forced to exactly orig*mult, so it can never stack.
local function applyScaled(comp, st, fields, mult)
    st.orig = st.orig or {}
    for _, f in ipairs(fields) do
        pcall(function()
            local cur = comp[f]
            if type(cur) ~= "number" or cur <= 0 then return end
            if st.orig[f] == nil then st.orig[f] = cur end
            local want = st.orig[f] * mult
            if math.abs(cur - want) > 0.01 then comp[f] = want end
        end)
    end
end

-- Log the real fly numbers (vanilla -> now, plus measured speed) a few times per
-- ride, so the effect can be checked from UE4SS.log without anyone measuring.
local function logFly(comp, st)
    st.flyLogs = (st.flyLogs or 0) + 1
    if st.flyLogs ~= 2 and st.flyLogs ~= 40 and st.flyLogs ~= 120 then return end
    local parts = {}
    for _, f in ipairs({ "FlySpeed_Default", "FlySprintSpeed_Default", "OverrideFlySpeed", "OverrideFlySprintSpeed", "MaxFlySpeed" }) do
        pcall(function()
            local o = st.orig and st.orig[f]
            parts[#parts + 1] = string.format("%s %s->%.0f", f, o and string.format("%.0f", o) or "-", comp[f])
        end)
    end
    pcall(function()
        local v = comp.Velocity
        parts[#parts + 1] = string.format("speedNow %.0f", math.sqrt(v.X * v.X + v.Y * v.Y + v.Z * v.Z))
    end)
    pcall(function() parts[#parts + 1] = "dash " .. tostring(comp.IsFlyDashMode) end)
    log("FLY " .. table.concat(parts, ", "))
end

local function restoreScaled(comp, st)
    if not st.orig then return end
    for f, v in pairs(st.orig) do pcall(function() comp[f] = v end) end
end

local isServer = false

-- PERFORMANCE (measured 2026-11-18): FindAllOf / FindFirstOf walk every object
-- in the game, ~30 ms EACH = a visible stutter when done on a timer. Reading
-- the game state's PlayerArray takes 0.015 ms. So the game state is found
-- once, kept, and dropped when a new world's game state appears.
local gsCache, gsLookedAt = nil, -100
pcall(NotifyOnNewObject, "/Script/Engine.GameStateBase", function() gsCache = nil; gsLookedAt = -100 end)
local function gameState()
    if valid(gsCache) then return gsCache end
    local now = os.clock()
    if now - gsLookedAt < 10 then return nil end   -- look again at most every 10 s
    gsLookedAt = now
    local gs = FindFirstOf("PalGameStateInGame")
    gsCache = valid(gs) and gs or nil
    return gsCache
end
local function allControllers()
    local out = {}
    local gs = gameState()
    if not gs then return out end
    local arr = gs.PlayerArray
    for i = 1, #arr do
        local ps = arr[i]
        if valid(ps) then
            local pc = ps:GetPlayerController()
            if valid(pc) then out[#out + 1] = pc end
        end
    end
    return out
end

local function scan()
    controllers = {}
    isServer = false
    for _, pc in ipairs(allControllers()) do
        if valid(pc) then
            controllers[#controllers + 1] = pc
            local okL, isLocal = pcall(function() return pc:IsLocalController() end)
            if okL and isLocal then
                local okA, auth = pcall(function() return pc:HasAuthority() end)
                isServer = okA and auth or false
            end
        end
    end
end

-- Host only: stop the server from snapping remote players back when their
-- (boosted) speed briefly differs from the server copy. Standard Unreal flags.
local function setTrustClient(comp, on)
    pcall(function() comp.bIgnoreClientMovementErrorChecksAndCorrection = on end)
    pcall(function() comp.bServerAcceptClientAuthoritativePosition = on end)
end

-- Verified in game 2026-11-17 (host log): while a player rides, the
-- controller's Pawn IS the ridden pal (e.g. BP_Suzaku_BOSS_C) and its movement
-- component carries the real ride speeds (Suzaku FlySpeed_Default 850 = the
-- speed it actually flew at). GetRiderCharacter() is only the player body
-- sitting on it - the old version boosted that body, so flying was never x2.
-- Also verified: a friend could NOT take off on a flying mount while the host
-- had "trust client" on that pal; with normal server corrections he flew
-- (mode 5, climbing) at once.
local function tick()
    local seenPlayers, seenMounts = {}, {}
    for _, pc in ipairs(controllers) do
        if valid(pc) then
            local remote = false
            if CFG.TrustFriendMovement and isServer then
                local okL, isLocal = pcall(function() return pc:IsLocalController() end)
                remote = okL and not isLocal
            end
            local okR, riding = pcall(function() return pc:IsRiding() end)
            riding = okR and riding or false
            local okP, pawn = pcall(function() return pc.Pawn end)
            local comp = (okP and valid(pawn)) and moveComp(pawn) or nil
            if comp then
                local key = comp:GetFullName()
                local st = stateFor(comp, key)
                if riding then
                    -- the ridden pal
                    mounts[key] = st
                    seenMounts[key] = true
                    applyScaled(comp, st, MOUNT_FIELDS, CFG.MountMove)
                    local okF, flying = pcall(function() return pc:IsRidingFlyPal() end)
                    local isFly = okF and flying or false
                    if isFly then
                        applyScaled(comp, st, FLY_FIELDS, CFG.MountFly)
                        logFly(comp, st)
                    end
                    if remote then
                        if isFly and st.trusted then
                            setTrustClient(comp, false)
                            st.trusted = false
                        elseif not isFly and not st.trusted then
                            setTrustClient(comp, true)
                            st.trusted = true
                        end
                    end
                    if not st.swimSet then
                        pcall(function() comp:SetSwimSpeedMultiplier(KEY, CFG.MountSwim) end)
                        st.swimSet = true
                    end
                else
                    -- player on foot
                    players[key] = st
                    seenPlayers[key] = true
                    applyScaled(comp, st, PLAYER_FIELDS, CFG.PlayerMove)
                    if remote and not st.trusted then
                        setTrustClient(comp, true)
                        st.trusted = true
                        log("Friend movement trusted (no more snap-back)")
                    end
                    if not st.swimSet then
                        pcall(function() comp:SetSwimSpeedMultiplier(KEY, CFG.PlayerSwim) end)
                        pcall(function() comp:SetWalkSpeedMultiplier(KEY, 1.0) end) -- clean up old version
                        st.swimSet = true
                    end
                end
            end
        end
    end
    -- a pal nobody rides any more: back to its own normal values
    for key, st in pairs(mounts) do
        if not seenMounts[key] then
            if valid(st.comp) then
                restoreScaled(st.comp, st)
                pcall(function() st.comp:SetSwimSpeedMultiplier(KEY, 1.0) end)
                if st.trusted then setTrustClient(st.comp, false) end
            end
            mounts[key] = nil
            compState[key] = nil   -- learn fresh (vanilla) values next time it is ridden
            if CFG.Debug then log("Mount restored") end
        end
    end
    -- player bodies keep their state (orig values) while their owner rides,
    -- so getting off never re-learns an already boosted value
    for key, st in pairs(players) do
        if not seenPlayers[key] and not valid(st.comp) then
            players[key] = nil
            compState[key] = nil
        end
    end
end

-- Watchdog (2026-11-18): times every tick. For the first minutes after start
-- one "PERF" line per 30 s is written so the cost can be read from UE4SS.log;
-- after that a line appears only if a tick took 10 ms or more ("SLOW").
local perf = { n = 0, total = 0, max = 0, since = os.clock(), lines = 0 }
local function timed(fn)
    local t0 = os.clock()
    local ok, err = pcall(fn)
    local now = os.clock()
    local ms = (now - t0) * 1000
    perf.n = perf.n + 1; perf.total = perf.total + ms
    if ms > perf.max then perf.max = ms end
    if now - perf.since >= 30 then
        if perf.max >= 10 or perf.lines < 10 then
            perf.lines = perf.lines + 1
            log(string.format("%s %d ticks in %.0f s, avg %.2f ms, max %.0f ms", perf.max >= 10 and "SLOW" or "PERF",
                perf.n, now - perf.since, perf.total / perf.n, perf.max))
        end
        perf.n, perf.total, perf.max, perf.since = 0, 0, 0, now
    end
    return ok, err
end

local ticks = 0
LoopAsync(250, function()        -- 4x per second, only cached objects
    ticks = ticks + 1
    local doScan = (ticks % 4 == 1)  -- player list every second (cheap now)
    ExecuteInGameThread(function() timed(function()
        if doScan then pcall(scan) end
        syncOptions()
        if settingsChanged then
            settingsChanged = false
            -- new values: swim multipliers are re-applied; scaled fields follow
            -- CFG on the next tick (always orig*mult, never compounding)
            for _, st in pairs(compState) do st.swimSet = false end
            if not CFG.Enabled then
                for key, st in pairs(compState) do
                    if valid(st.comp) then
                        restoreScaled(st.comp, st)
                        pcall(function() st.comp:SetSwimSpeedMultiplier(KEY, 1.0) end)
                        if st.trusted then setTrustClient(st.comp, false) end
                    end
                    compState[key] = nil
                end
                players, mounts = {}, {}
                log("disabled - all speeds back to normal")
            end
        end
        if not CFG.Enabled then return end
        local ok, err = pcall(tick)
        if not ok and CFG.Debug then log("tick error: " .. tostring(err)) end
    end) end)
    return false
end)

log(string.format("Loaded (player x%.1f, mount ground x%.1f, swim x%.1f, fly x%.1f)",
    CFG.PlayerMove, CFG.MountMove, CFG.MountSwim, CFG.MountFly))
