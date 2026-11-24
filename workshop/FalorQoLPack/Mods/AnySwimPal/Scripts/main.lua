-- AnySwimPal
-- Salvage floating wrecks while riding ANY pal that swims, whatever its
-- element (vanilla: only "swim pals" such as Surfent).
--
-- How (verified in game 2026-11-17): the salvage check uses the ridden pal's
-- UPalStaticCharacterParameterComponent:IsSwimPal(), which is true when its
-- MovementType is Swim (3) / SwimGroundDamage (4). While a player rides a pal
-- that is in the water (movement mode 4 = swimming), this mod sets its
-- MovementType to Swim; the moment it leaves the water or nobody rides it,
-- the original value comes back, so walking on land is never affected.
-- Chillet: MovementType 0 -> 3, IsSwimPal true, salvage worked; restored to 0
-- on land (seen 3 times in a row).
--
-- Install on host AND friends (each game checks its own riding player).
-- Settings: Esc > Mod Options > Salvage With Any Pal.

local TAG = "[AnySwimPal] "
local function log(m) print(TAG .. tostring(m) .. "\n") end

local enabled = true
local TICK_MS = 500

local function valid(o)
    if not o then return false end
    local ok, v = pcall(function() return o:IsValid() end)
    return ok and v
end

-- tell GlobalBaseStorage (which had the first test version) to stand down
pcall(function() ModRef:SetSharedVariable("AnySwimPal.Loaded", true) end)

---------------------------------------------------------------------------
-- settings page
---------------------------------------------------------------------------
local options, generation = nil, 0
local okReq, sdk = pcall(require, "PalModOptionsClient")
if okReq and sdk then
    options = sdk
    pcall(sdk.register_when_ready, {
        id = "BizimModlar.AnySwimPal",
        mod_folder = "AnySwimPal",
        title = "Salvage With Any Pal",
        titles = { tr = "Her Pal'la Enkaz Toplama" },
        description = "Any pal that swims counts as a water pal for salvaging floating wrecks (fishing rod still needed). Only while it is in the water.",
        descriptions = { tr = "Yüzebilen her Pal, yüzen enkazları toplamak için su Pal'ı sayılır (olta yine gerekir). Sadece suda iken." },
        version = 1,
        apply_mode = "event",
        options = {
            { key = "enabled", type = "boolean", label = "Enabled", labels = { tr = "Mod açık" }, default = true },
        },
    }, function(v, err)
        if v ~= nil then
            if v.enabled ~= nil then enabled = v.enabled end
            generation = sdk.generation()
            log("settings: on=" .. tostring(enabled))
        else
            log("Mod Options unavailable, using defaults: " .. tostring(err))
        end
    end)
end

---------------------------------------------------------------------------
-- logic
---------------------------------------------------------------------------
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

local changed = {}   -- static comp full name -> { comp, orig }
local controllers, ticks = {}, 0

local function tick()
    ticks = ticks + 1
    controllers = allControllers()
    if options then
        pcall(function()
            generation = select(1, options.sync(generation, function(v)
                if v.enabled ~= nil then enabled = v.enabled end
            end))
        end)
    end
    local active = {}
    if enabled then
        for _, pc in ipairs(controllers) do
            pcall(function()
                if not valid(pc) or not pc:IsRiding() then return end
                local pal = pc.Pawn               -- while riding, the Pawn is the pal
                local mc = pal:GetPalCharacterMovementComponent()
                local inWater = (tonumber(mc.MovementMode) == 4)
                if not inWater then return end
                local sc = pal.StaticCharacterParameterComponent
                if not valid(sc) then return end
                local key = sc:GetFullName()
                active[key] = true
                if changed[key] then return end
                local mt = tonumber(sc.MovementType)
                if mt == 3 or mt == 4 then return end   -- already a real swim pal
                changed[key] = { comp = sc, orig = mt }
                sc.MovementType = 3
                log("ridden pal in water counts as swim pal (MovementType " .. mt .. " -> 3)")
            end)
        end
    end
    for key, e in pairs(changed) do
        if not active[key] then
            pcall(function() if valid(e.comp) then e.comp.MovementType = e.orig end end)
            changed[key] = nil
            log("restored MovementType " .. tostring(e.orig))
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

LoopAsync(TICK_MS, function()
    ExecuteInGameThread(function()
        local ok, e = timed(tick)
        if not ok then log("error: " .. tostring(e)) end
    end)
    return false
end)

log("Loaded - any swimming pal can salvage")
