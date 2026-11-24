-- PickupBoost - loader (world host)
-- Items picked up from the ground by hand give more: Nightstar Sand and
-- everything else (Cavern Mushroom, Mushroom, Red Berries, small stones,
-- logs...) with separate multipliers 1-20. Pal eggs and treasure are never
-- touched. Friends need nothing (the host hands out the items).
--
-- All logic is in pb_logic.lua next to this file. This loader re-reads it
-- every 2 s and swaps the new version in when it changed, so fixes apply
-- WITHOUT restarting the game (UE4SS hot reload / Ctrl+R stays off - it
-- crashes this game). If the new file has an error, the old one keeps running.
--
-- Settings: Esc > Mod Options > Pickup Boost (Workshop mod "Mod Options
-- Framework"; without it the defaults are used).

local TAG = "[PickupBoost] "
local function log(m) print(TAG .. tostring(m) .. "\n") end

local function valid(o)
    if not o then return false end
    local ok, v = pcall(function() return o:IsValid() end)
    return ok and v
end

local function scriptDir()
    local src = ""
    pcall(function() src = debug.getinfo(1, "S").source or "" end)
    return (src:gsub("^@", "")):match("^(.*)[/\\]")
end
local LOGIC = scriptDir() and (scriptDir() .. "/pb_logic.lua") or nil

local L, lastSrc = nil, nil
local function reload()
    if not LOGIC then return end
    local f = io.open(LOGIC, "rb")
    if not f then return end
    local src = f:read("a")
    f:close()
    if not src or src == "" or src == lastSrc then return end
    lastSrc = src
    local chunk, err = load(src, "@pb_logic.lua")
    if not chunk then log("pb_logic.lua has an error, keeping the old version: " .. tostring(err)) return end
    local ok, mod = pcall(chunk)
    if not ok or type(mod) ~= "table" then log("pb_logic.lua failed to start, keeping the old version: " .. tostring(mod)) return end
    local first = (L == nil)
    L = mod
    log((first and "logic loaded" or "logic RELOADED live (no restart needed)") .. " - version " .. tostring(mod.version))
end

---------------------------------------------------------------------------
-- settings page
---------------------------------------------------------------------------
local options, generation, settings = nil, 0, nil
local function pushSettings()
    if settings and L and L.setSettings then pcall(L.setSettings, settings) end
end
local okReq, sdk = pcall(require, "PalModOptionsClient")
if okReq and sdk then
    options = sdk
    pcall(sdk.register_when_ready, {
        id = "BizimModlar.PickupBoost",
        mod_folder = "PickupBoost",
        title = "Pickup Boost",
        titles = { tr = "Toplama Çarpanı" },
        description = "Items picked up from the ground by hand give more. Runs on the world host; works for everyone.",
        descriptions = { tr = "Yerden elle toplanan eşyalar daha fazla verir. Host'ta çalışır, herkes için geçerli." },
        version = 2,
        apply_mode = "event",
        options = {
            { key = "enabled", type = "boolean", label = "Enabled", labels = { tr = "Mod açık" }, default = true,
              description = "When off, pickups give their normal amount.",
              descriptions = { tr = "Kapalıyken toplanan eşyalar normal miktarını verir." } },
            { key = "nightstar_mult", type = "integer", label = "Nightstar Sand multiplier", labels = { tr = "Nightstar Sand çarpanı" },
              default = 10, minimum = 1, maximum = 20, step = 1 },
            { key = "other_mult", type = "integer", label = "Other pickups multiplier", labels = { tr = "Diğer toplanan eşyalar çarpanı" },
              description = "Cavern Mushroom, Mushroom, Red Berries, small stones, logs... (not eggs).",
              descriptions = { tr = "Cavern Mushroom, mantar, Red Berries, küçük taş, kütük... (yumurtalar hariç)." },
              default = 10, minimum = 1, maximum = 20, step = 1 },
        },
    }, function(v, err)
        if v ~= nil then
            settings = v
            generation = sdk.generation()
            pushSettings()
            log(string.format("settings: on=%s, Nightstar Sand x%s, other pickups x%s",
                tostring(v.enabled), tostring(v.nightstar_mult), tostring(v.other_mult)))
        else
            log("Mod Options unavailable, using defaults: " .. tostring(err))
        end
    end)
end

local okR, errR = pcall(reload)
if not okR then log("load error: " .. tostring(errR)) end

---------------------------------------------------------------------------
-- reload check + settings
-- 2026-11-18: no more searching for pickups. pb_logic.lua hooks the game's
-- pickup request and sets the amount right then (verified: mushroom put back
-- to 1 gave 10). The old version searched the world whenever a pickup
-- appeared; every search walks all objects in the game (~75 ms = a stutter)
-- and its delayed callbacks crashed the game once (2026-11-17 23:15).
---------------------------------------------------------------------------
LoopAsync(2000, function()
    ExecuteInGameThread(function()
        local ok1, e1 = pcall(reload)
        if not ok1 then log("reload error: " .. tostring(e1)) end
        if options then
            pcall(function()
                generation = select(1, options.sync(generation, function(v) settings = v end))
            end)
        end
        pushSettings()
        if L and L.scan then   -- does nothing while the hook is active
            local ok2, e2 = pcall(L.scan)
            if not ok2 then log("scan error: " .. tostring(e2)) end
        end
    end)
    return false
end)

log("Loaded - pickups multiplied on the host (Esc > Mod Options > Pickup Boost)")
