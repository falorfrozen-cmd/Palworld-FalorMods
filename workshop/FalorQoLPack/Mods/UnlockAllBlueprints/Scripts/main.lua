-- UnlockAllBlueprints - loader
-- Furniture that needs a blueprint item (candlesticks, lanterns, statues,
-- flags ...) and gear that needs a schematic (weapons, armor, hats,
-- accessories, every rarity) can be built / crafted without owning the item.
-- No item is added to the inventory and nothing is written to the save:
-- the requirement is switched off in memory and comes back when the mod is
-- turned off.
--
-- Verified 2026-11-20 on the host: 15 build objects and 575 recipes changed,
-- read back, shown in the build menu (B) and at the workbenches.
--
-- All logic is in ub_logic.lua next to this file; this loader re-reads it
-- every 2 s so fixes apply without restarting (UE4SS hot reload stays off).
-- Settings: Esc > Mod Options > Unlock All Blueprints.

local TAG = "[UnlockAllBlueprints] "
local function log(m) print(TAG .. tostring(m) .. "\n") end

local function scriptDir()
    local src = ""
    pcall(function() src = debug.getinfo(1, "S").source or "" end)
    return (src:gsub("^@", "")):match("^(.*)[/\\]")
end
local LOGIC = scriptDir() and (scriptDir() .. "/ub_logic.lua") or nil

local L, lastSrc = nil, nil
local function reload()
    if not LOGIC then return end
    local f = io.open(LOGIC, "rb")
    if not f then return end
    local src = f:read("a")
    f:close()
    if not src or src == "" or src == lastSrc then return end
    lastSrc = src
    local chunk, err = load(src, "@ub_logic.lua")
    if not chunk then log("ub_logic.lua has an error, keeping the old version: " .. tostring(err)) return end
    local ok, mod = pcall(chunk)
    if not ok or type(mod) ~= "table" then log("ub_logic.lua failed to start, keeping the old version: " .. tostring(mod)) return end
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
        id = "BizimModlar.UnlockAllBlueprints",
        mod_folder = "UnlockAllBlueprints",
        title = "Unlock All Blueprints",
        titles = { tr = "Tüm Planlar Açık" },
        description = "Build blueprint furniture and craft schematic gear without owning the blueprint or schematic item. Nothing is added to your inventory and nothing is written to the save; turning it off brings the requirement back.",
        descriptions = { tr = "Plan gerektiren mobilyaları ve şema gerektiren ekipmanı, plan eşyasına sahip olmadan inşa et / üret. Envantere bir şey eklenmez, kayda bir şey yazılmaz; kapatınca şart geri gelir." },
        version = 1,
        apply_mode = "event",
        options = {
            { key = "enabled", type = "boolean", label = "Enabled", labels = { tr = "Mod açık" }, default = true },
            { key = "furniture", type = "boolean", label = "Furniture blueprints", labels = { tr = "Mobilya planları" }, default = true,
              description = "Candlesticks, lanterns, statues, flags, laboratory desk and chair: shown in the build menu (B) without the blueprint item.",
              descriptions = { tr = "Şamdanlar, fenerler, heykeller, bayraklar, laboratuvar masası ve sandalyesi: plan eşyası olmadan inşa menüsünde (B) çıkar." } },
            { key = "gear", type = "boolean", label = "Weapon and armor schematics", labels = { tr = "Silah ve zırh şemaları" }, default = true,
              description = "Every rarity of weapons, armor, hats and accessories can be crafted at the workbench without the schematic. You still need the materials.",
              descriptions = { tr = "Silah, zırh, şapka ve aksesuarların her nadirlik seviyesi şema olmadan tezgâhta üretilebilir. Malzemeler yine gerekir." } },
        },
    }, function(v, err)
        if v ~= nil then
            settings = v
            generation = sdk.generation()
            pushSettings()
            log("settings: on=" .. tostring(v.enabled) .. ", furniture=" .. tostring(v.furniture) .. ", gear=" .. tostring(v.gear))
        else
            log("Mod Options unavailable, using defaults: " .. tostring(err))
        end
    end)
end

local okR, errR = pcall(reload)
if not okR then log("load error: " .. tostring(errR)) end

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
        if L and L.tick then   -- returns at once unless a setting changed or a world was loaded
            local ok2, e2 = pcall(L.tick)
            if not ok2 then log("error: " .. tostring(e2)) end
        end
    end)
    return false
end)

log("Loaded - blueprint and schematic items are not needed (Esc > Mod Options > Unlock All Blueprints)")
