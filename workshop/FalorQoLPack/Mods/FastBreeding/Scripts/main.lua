-- FastBreeding
-- Breeding farm: one breeding (cake -> egg) takes BREED_SECONDS instead of the
-- vanilla 300 s. Works on the world host (the server runs the breeding).
-- Verified live 2026-11-15: BreedRequiredRealTime lives on the farm's model
-- (PalMapObjectBreedFarmModel) and its parameter component; vanilla 300.

local BREED_SECONDS = 1.0
local CHECK_EVERY_MS = 2000    -- timer; real work only when something changed (see below)

local TAG = "[FastBreeding] "
local function log(m) print(TAG .. tostring(m) .. "\n") end

local function valid(o)
    if not o then return false end
    local ok, v = pcall(function() return o:IsValid() end)
    return ok and v
end

local CLASSES = {
    "PalMapObjectBreedFarmModel",
    "PalMapObjectBreedFarmParameterComponent",
    "PalMapObjectMultiHatchingEggWithBreedModel",
    "PalMapObjectMultiHatchingEggWithBreedParameterComponent",
}

-- Settings page: Esc > Mod Options > Hızlı Üreme (optional framework).
local VANILLA_SECONDS = 300
local enabled = true
local autoHatch = true
local appliedHatch = {}   -- actor full name -> value we last sent

-- PERFORMANCE (measured 2026-11-18): FindAllOf walks every object in the game,
-- ~30 ms per call. The old version did 5 of them every 10 s (~150 ms stutter).
-- Now a search only happens when it is needed:
--  * farms: when a new farm object appears (NotifyOnNewObject raises a flag for
--    its class) and when the setting changes; each of those is followed by one
--    more search 10 s later, in case the game filled the value in afterwards
--  * AutoHatch: until it has been applied once per world / setting change
-- At most ONE search per tick. (Until 2026-11-18 there also was a full pass
-- every 5 minutes: 4 searches in one tick, a 110-190 ms stutter each time.)
local dirty = {}           -- class name -> true: search this class on the next tick
local recheckAt = {}       -- class name -> os.clock() of the one follow-up search
local hatchPending = true  -- AutoHatch still has to be applied
local function markAll() for _, c in ipairs({ "PalMapObjectBreedFarmModel", "PalMapObjectBreedFarmParameterComponent",
    "PalMapObjectMultiHatchingEggWithBreedModel", "PalMapObjectMultiHatchingEggWithBreedParameterComponent" }) do dirty[c] = true end end
markAll()
for _, c in ipairs({ "PalMapObjectBreedFarmModel", "PalMapObjectBreedFarmParameterComponent",
    "PalMapObjectMultiHatchingEggWithBreedModel", "PalMapObjectMultiHatchingEggWithBreedParameterComponent" }) do
    -- only a flag is set here; the object itself is never kept (a kept object
    -- can be gone a moment later, and touching it crashes the game)
    pcall(NotifyOnNewObject, "/Script/Pal." .. c, function() dirty[c] = true end)
end
-- AutoHatch needs two searches per try (~60 ms), so it is tried every 5 s, and
-- only every 60 s after 24 tries (title screen, or AutoHatch not installed)
local hatchTryAt, hatchTries = -100, 0
-- new world: apply AutoHatch again
pcall(NotifyOnNewObject, "/Script/Engine.GameStateBase", function() hatchPending = true; hatchTries = 0; hatchTryAt = -100 end)

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

-- AutoHatch (third-party Workshop mod) keeps an on/off per player. Verified
-- live 2026-11-17: its ModActor_C:LoadPlayerSettings(uidHex, bool) is the same
-- call its own "!autohatch on/off" chat command ends in. Sent for the local
-- player whenever the setting or the actor (new world) changes.
local function syncAutoHatch()
    if not hatchPending then return end
    local now = os.clock()
    if now - hatchTryAt < (hatchTries >= 24 and 60 or 5) then return end
    hatchTryAt = now; hatchTries = hatchTries + 1
    local actor
    for _, m in ipairs(FindAllOf("ModActor_C") or {}) do
        if valid(m) and m:IsA("/Game/Mods/AutoHatch/ModActor.ModActor_C") then actor = m end
    end
    if not actor then return end
    local key = actor:GetFullName()
    if appliedHatch[key] == autoHatch then hatchPending = false; return end
    local pc
    for _, c in ipairs(FindAllOf("PalPlayerController") or {}) do
        local ok, isLocal = pcall(function() return c:IsLocalController() end)
        if ok and isLocal and valid(c) then pc = c end
    end
    -- only once the player is really in the world (on the title screen the
    -- player id is not a real value yet)
    if not (pc and valid(pc.PlayerState) and valid(pc.Pawn)) then return end
    local g = pc.PlayerState.PlayerUId
    local uid = string.format("%08X%08X%08X%08X", g.A & 0xffffffff, g.B & 0xffffffff, g.C & 0xffffffff, g.D & 0xffffffff)
    actor:LoadPlayerSettings(uid, autoHatch)
    appliedHatch = { [key] = autoHatch }
    hatchPending = false
    log("AutoHatch " .. (autoHatch and "on" or "off") .. " for local player")
end
local options, generation = nil, 0
local function applySettings(v)
    if type(v) ~= "table" then return end
    if v.enabled ~= nil then enabled = v.enabled end
    if v.seconds then BREED_SECONDS = v.seconds end
    if v.auto_hatch ~= nil then
        if v.auto_hatch ~= autoHatch then hatchPending = true; hatchTries = 0; hatchTryAt = -100 end
        autoHatch = v.auto_hatch
    end
    log("settings: on=" .. tostring(enabled) .. ", " .. BREED_SECONDS .. " s")
end
local okReq, sdk = pcall(require, "PalModOptionsClient")
if okReq and sdk then
    options = sdk
    pcall(sdk.register_when_ready, {
        id = "BizimModlar.FastBreeding",
        mod_folder = "FastBreeding",
        title = "Fast Breeding",
        titles = { tr = "Hızlı Üreme" },
        description = "Time for one egg at the Breeding Farm (normally 300 seconds). Runs on the world host.",
        descriptions = { tr = "Üreme çiftliğinde bir yumurtanın süresi. Normali 300 saniye. Sadece host'ta çalışır." },
        version = 3,
        apply_mode = "event",
        options = {
            { key = "enabled", type = "boolean", label = "Enabled", labels = { tr = "Mod açık" }, default = true,
              description = "When off, breeding goes back to normal (300 s).",
              descriptions = { tr = "Kapalıyken süre normale (300 sn) döner." } },
            { key = "seconds", type = "integer", label = "Breeding time (seconds)", labels = { tr = "Üreme süresi (saniye)" },
              default = 1, minimum = 1, maximum = 300, step = 1 },
            { key = "auto_hatch", type = "boolean", label = "Hatch eggs instantly on pickup", labels = { tr = "Yumurta alınınca hemen çatlasın" }, default = true,
              description = "Your on/off switch of the Workshop mod AutoHatch (same as !autohatch on/off in chat).",
              descriptions = { tr = "Workshop modu AutoHatch'in senin için açık/kapalı ayarı (sohbette !autohatch on/off ile aynı)." } },
        },
    }, function(settings, err)
        if settings ~= nil then
            applySettings(settings)
            generation = sdk.generation()
        else
            log("Mod Options unavailable, using defaults: " .. tostring(err))
        end
    end)
end

local lastTarget = nil
local function apply()
    if options then
        pcall(function()
            generation = select(1, options.sync(generation, function(values) applySettings(values) end))
        end)
    end
    local target = enabled and BREED_SECONDS or VANILLA_SECONDS
    if target ~= lastTarget then lastTarget = target; markAll() end
    local now = os.clock()
    local changed, searched = 0, false
    for _, cls in ipairs(CLASSES) do
        local all = nil
        if not searched then
            local again = (not dirty[cls]) and recheckAt[cls] ~= nil and now >= recheckAt[cls]
            if dirty[cls] or again then
                searched = true   -- one search per tick; the other classes wait for the next ticks
                if again then recheckAt[cls] = nil else dirty[cls] = nil; recheckAt[cls] = now + 10 end
                all = FindAllOf(cls)
            end
        end
        if all then
            for _, o in ipairs(all) do
                if valid(o) then
                    pcall(function()
                        local t = o.BreedRequiredRealTime
                        if type(t) == "number" and math.abs(t - target) > 0.001 then
                            o.BreedRequiredRealTime = target
                            changed = changed + 1
                        end
                    end)
                end
            end
        end
    end
    if changed > 0 then log("breeding time set to " .. target .. " s on " .. changed .. " objects") end
end

LoopAsync(CHECK_EVERY_MS, function()
    ExecuteInGameThread(function()
        timed(function()
            local ok, e = pcall(apply)
            if not ok then log("error: " .. tostring(e)) end
            local okH, eH = pcall(syncAutoHatch)
            if not okH then log("AutoHatch error: " .. tostring(eH)) end
        end)
    end)
    return false
end)

log("Loaded - breeding takes " .. BREED_SECONDS .. " s")
