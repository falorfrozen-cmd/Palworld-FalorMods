-- PickupBoost logic (live-reloaded by main.lua every 2 s; no game restart needed)
--
-- Verified in game 2026-11-17:
--  * every ground pickup is a UPalMapObjectPickupItemOnLevelModel; what you get
--    is slot N of its item container (filled when it spawns). Editing the
--    pickup component's DropItems later changes nothing.
--  * the container contents are SAVED with the world, so the base amount comes
--    from the pickup components' DropItems (BP defaults: NightStone 1,
--    CaveMushroom 1, Stone 2, Wood 2, Berries 2, ...) - never from the
--    container, otherwise it would multiply again after every restart.
--  * the same model class is used for treasure contents
--    ("TreasureBox_VisibleContent") and items lying on the ground; only map
--    object ids starting with "PickupItem_" are touched.
--  * 2026-11-17 bug: Cavern Mushrooms at a cave entrance gave 1 because the
--    base for a NEW pickup type was learned only once a minute. Now a pickup is
--    handled the moment it appears (main.lua NotifyOnNewObject) and an unknown
--    item type triggers learning right away.

local M = { version = "5" }
local TAG = "[PickupBoost] "
local function log(m) print(TAG .. tostring(m) .. "\n") end

-- state that must survive a live reload
_G.PB_STATE = _G.PB_STATE or { base = {}, lastLearn = 0 }
local S = _G.PB_STATE

M.CFG = M.CFG or { enabled = true, nightstar_mult = 10, other_mult = 10 }
local CFG = M.CFG

local SKIP = { "Egg", "SkillUnlock", "KeySphere", "Fragment", "Relic", "Lantern", "Note", "Journal" }
local function multFor(item)
    for _, p in ipairs(SKIP) do if item:find(p, 1, true) then return nil end end
    if item == "NightStone" then return CFG.nightstar_mult end
    return CFG.other_mult
end

local function valid(o)
    if not o then return false end
    local ok, v = pcall(function() return o:IsValid() end)
    return ok and v
end

function M.setSettings(v)
    if type(v) ~= "table" then return end
    if v.enabled ~= nil then CFG.enabled = v.enabled end
    if v.nightstar_mult then CFG.nightstar_mult = v.nightstar_mult end
    if v.other_mult then CFG.other_mult = v.other_mult end
end

-- "Am I the host?" needs one search of the whole game (~30 ms), and it used to
-- be repeated every 5 s = a small hitch on the first pickup after any pause.
-- Hosting does not change inside a world, so a "yes" is now kept for 10
-- minutes and dropped when a new world's game state appears.
_G.PB_SERVER = _G.PB_SERVER or { v = false, at = -1000 }
if not _G.PB_GS_NOTIFY then
    _G.PB_GS_NOTIFY = pcall(NotifyOnNewObject, "/Script/Engine.GameStateBase", function() _G.PB_SERVER.at = -1000 end)
end
local function isServer()
    local c = _G.PB_SERVER
    local now = os.clock()
    if now - c.at < (c.v and 600 or 5) then return c.v end
    c.at = now
    c.v = false
    for _, pc in ipairs(FindAllOf("PalPlayerController") or {}) do
        local okL, isLocal = pcall(function() return pc:IsLocalController() end)
        if okL and isLocal then
            local okA, auth = pcall(function() return pc:HasAuthority() end)
            c.v = okA and auth or false
            break
        end
    end
    return c.v
end

-- learn base amounts from one component
function M.learnFromComponent(comp)
    pcall(function()
        comp.DropItems:ForEach(function(i, el)
            local d = el:get()
            local id = d.StaticItemId.Key:ToString()
            if id ~= "None" and d.Num > 0 and not S.base[id] then
                S.base[id] = d.Num
                log("base " .. id .. " = " .. d.Num)
            end
        end)
    end)
end

function M.learnAll()
    S.lastLearn = os.clock()
    for _, comp in ipairs(FindAllOf("PalMapObjectPickupItemParameterComponent") or {}) do
        M.learnFromComponent(comp)
    end
end

-- returns number of changed slots; "unknown" = saw an item with no base yet
local function applyModel(m)
    local changed, unknown = 0, false
    pcall(function()
        local mid = m:TryGetMapObjectId():ToString()
        if not mid:find("^PickupItem_") then return end
        local c = m:GetItemContainerModule():GetContainer()
        for i = 0, c:Num() - 1 do
            local s = c:Get(i)
            if valid(s) then
                local id = s.ItemId.StaticId:ToString()
                local mult = multFor(id)
                local b = S.base[id]
                if mult and not b and id ~= "None" then unknown = true end
                if mult and b and s.StackCount > 0 then
                    local want = b * (CFG.enabled and mult or 1)
                    if s.StackCount ~= want then
                        s.StackCount = want
                        changed = changed + 1
                    end
                end
            end
        end
    end)
    return changed, unknown
end

-- a pickup just appeared (called by main.lua shortly after it was created)
function M.onNewModel(m)
    if not valid(m) or not isServer() then return end
    local changed, unknown = applyModel(m)
    if unknown then
        M.learnAll()
        changed = changed + select(1, applyModel(m))
    end
    if changed > 0 then
        M.appearCount = (M.appearCount or 0) + changed
        local now = os.clock()
        if not M.lastAppearLog or now - M.lastAppearLog > 5 then
            M.lastAppearLog = now
            log("set " .. M.appearCount .. " pickup slots as they appeared")
            M.appearCount = 0
        end
    end
    return changed
end

---------------------------------------------------------------------------
-- PICKUP HOOK (2026-11-18): instead of searching the world for pickups on a
-- timer (each search walks every object in the game: ~30 ms + ~45 ms for ~860
-- pickups = a visible stutter), the amount is set at the moment the pickup
-- request reaches the server, just before the game hands out the items.
-- Zero cost while nothing is picked up.
---------------------------------------------------------------------------
_G.PB_ON_PICKUP = function(model)
    if not valid(model) or not isServer() then return end
    local changed, unknown = applyModel(model)
    if unknown then
        M.learnAll()   -- a new item type: one search, once per type
        changed = changed + select(1, applyModel(model))
    end
    S.hookFired = (S.hookFired or 0) + 1
    if S.hookFired <= 20 then
        local id, n = "?", "?"
        pcall(function()
            local s = model:GetItemContainerModule():GetContainer():Get(0)
            if valid(s) then id = s.ItemId.StaticId:ToString(); n = tostring(s.StackCount) end
        end)
        log(string.format("hook #%d: %s x%s (%d slot(s) changed)", S.hookFired, id, n, changed))
    end
end

if not _G.PB_HOOKED then
    local ok, err = pcall(RegisterHook, "/Script/Pal.PalMapObjectPickableItemModelBase:RequestPickup_ServerInternal", function(self)
        local f = _G.PB_ON_PICKUP
        if f then
            local okC, eC = pcall(function() f(self:get()) end)
            if not okC then log("hook error: " .. tostring(eC)) end
        end
    end)
    _G.PB_HOOKED = ok
    log(ok and "pickup hook registered" or ("pickup hook FAILED: " .. tostring(err)))
end

-- timing: how long do the sweeps take? (summary line every 30 s)
_G.PB_PERF = _G.PB_PERF or { n = 0, total = 0, max = 0, models = 0, since = os.clock() }
local P = _G.PB_PERF
local function perf(ms, models)
    P.n = P.n + 1; P.total = P.total + ms; P.models = models
    if ms > P.max then P.max = ms end
    local now = os.clock()
    if now - P.since >= 30 then
        log(string.format("PERF %d sweeps in %.0f s, avg %.1f ms, max %.0f ms, %d pickup models", P.n, now - P.since, P.total / P.n, P.max, P.models))
        P.n, P.total, P.max, P.since = 0, 0, 0, now
    end
end

-- fallback sweep every few seconds (also applies setting changes)
function M.scan()
    -- VERIFIED 2026-11-18: with the pickup hook a Cavern Mushroom set back to 1
    -- gave 10 (inventory 30 -> 40), so no sweeps are needed at all. The old
    -- sweep stays only as a fallback if the hook could not be registered.
    if _G.PB_HOOKED then return end
    if os.clock() - (S.lastSweep or -100) < 60 then return end
    S.lastSweep = os.clock()
    local t0 = os.clock()
    local nModels = M.scanInner() or 0
    perf((os.clock() - t0) * 1000, nModels)
end

function M.scanInner()
    if not isServer() then return end
    if next(S.base) == nil or os.clock() - S.lastLearn > 60 then M.learnAll() end
    local changed, anyUnknown = 0, false
    local models = FindAllOf("PalMapObjectPickupItemOnLevelModel") or {}
    for _, m in ipairs(models) do
        local c, u = applyModel(m)
        changed = changed + c
        anyUnknown = anyUnknown or u
    end
    if anyUnknown then
        M.learnAll()
        for _, m in ipairs(models) do changed = changed + select(1, applyModel(m)) end
    end
    if changed > 0 then log("set " .. changed .. " pickup slots (sweep)") end
    return #models
end

return M
