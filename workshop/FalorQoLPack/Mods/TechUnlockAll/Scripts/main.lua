-- TechUnlockAll - loader (world host)
-- Every technology in the tech tree is unlocked for every player in the
-- world: normal and Ancient ones, no level, point or tower-boss requirement.
-- Players who join later get it within ~10 s. Friends need nothing installed
-- (unlocks are decided by the host and sent to each player's game).
--
-- Verified 2026-11-17 on the host: 211 -> 588 of 588 unlocked, build objects
-- and craft recipes report unlocked, the player save grew (written to disk).
--
-- NOTE: unlocks are saved with the world. Turning the mod off later does NOT
-- lock them again.
--
-- All logic is in tu_logic.lua next to this file; this loader re-reads it
-- every 2 s so fixes apply without restarting (UE4SS hot reload stays off).
-- Settings: Esc > Mod Options > Unlock All Technology.

local TAG = "[TechUnlockAll] "
local function log(m) print(TAG .. tostring(m) .. "\n") end

local function scriptDir()
    local src = ""
    pcall(function() src = debug.getinfo(1, "S").source or "" end)
    return (src:gsub("^@", "")):match("^(.*)[/\\]")
end
local LOGIC = scriptDir() and (scriptDir() .. "/tu_logic.lua") or nil

local L, lastSrc = nil, nil
local function reload()
    if not LOGIC then return end
    local f = io.open(LOGIC, "rb")
    if not f then return end
    local src = f:read("a")
    f:close()
    if not src or src == "" or src == lastSrc then return end
    lastSrc = src
    local chunk, err = load(src, "@tu_logic.lua")
    if not chunk then log("tu_logic.lua has an error, keeping the old version: " .. tostring(err)) return end
    local ok, mod = pcall(chunk)
    if not ok or type(mod) ~= "table" then log("tu_logic.lua failed to start, keeping the old version: " .. tostring(mod)) return end
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
        id = "BizimModlar.TechUnlockAll",
        mod_folder = "TechUnlockAll",
        title = "Unlock All Technology",
        titles = { tr = "Tüm Teknolojiler Açık" },
        description = "Every technology (normal and Ancient) is unlocked, no points or level needed. Runs on the world host. Unlocks are saved: turning this off does not lock them again.",
        descriptions = { tr = "Tüm teknolojiler (normal ve Ancient) açılır, puan veya seviye gerekmez. Host'ta çalışır. Açılanlar kaydedilir: modu kapatmak onları geri kilitlemez." },
        version = 1,
        apply_mode = "event",
        options = {
            { key = "enabled", type = "boolean", label = "Enabled", labels = { tr = "Mod açık" }, default = true },
            { key = "include_friends", type = "boolean", label = "Also for friends", labels = { tr = "Arkadaşlar için de" }, default = true,
              description = "When off, only the host's own character gets everything.",
              descriptions = { tr = "Kapalıyken sadece host'un kendi karakteri her şeyi alır." } },
        },
    }, function(v, err)
        if v ~= nil then
            settings = v
            generation = sdk.generation()
            pushSettings()
            log("settings: on=" .. tostring(v.enabled) .. ", friends=" .. tostring(v.include_friends))
        else
            log("Mod Options unavailable, using defaults: " .. tostring(err))
        end
    end)
end

-- tell GlobalBaseStorage (which ran the first test version) to stand down
pcall(function() ModRef:SetSharedVariable("TechUnlockAll.Loaded", true) end)

local okR, errR = pcall(reload)
if not okR then log("load error: " .. tostring(errR)) end

local ticks = 0
LoopAsync(2000, function()
    ticks = ticks + 1
    ExecuteInGameThread(function()
        local ok1, e1 = pcall(reload)
        if not ok1 then log("reload error: " .. tostring(e1)) end
        if options then
            pcall(function()
                generation = select(1, options.sync(generation, function(v) settings = v end))
            end)
        end
        pushSettings()
        if ticks % 5 == 0 and L and L.tick then   -- every 10 s
            local ok2, e2 = pcall(L.tick)
            if not ok2 then log("error: " .. tostring(e2)) end
        end
    end)
    return false
end)

log("Loaded - all technology unlocked on the host (Esc > Mod Options > Unlock All Technology)")
