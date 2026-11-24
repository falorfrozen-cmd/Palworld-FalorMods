-- CompleteAllQuests - loader
-- Finishes quests for you, with their rewards, through the game's own quest
-- path (one objective per second). Two separate switches: main quests and
-- side quests. Both are OFF until you turn them on, because a finished quest
-- cannot be un-finished.
--
-- Verified 2026-11-22 on a copy of a real save (world host): the main chain
-- up to the World Tree and 44 side quests finished, each with its rewards.
--
-- All logic is in cq_logic.lua next to this file; this loader re-reads it
-- every 2 s so fixes apply without restarting (UE4SS hot reload stays off).
-- Settings: Esc > Mod Options > Complete All Quests.

local TAG = "[CompleteAllQuests] "
local function log(m) print(TAG .. tostring(m) .. "\n") end

local function scriptDir()
    local src = ""
    pcall(function() src = debug.getinfo(1, "S").source or "" end)
    return (src:gsub("^@", "")):match("^(.*)[/\\]")
end
local LOGIC = scriptDir() and (scriptDir() .. "/cq_logic.lua") or nil

local L, lastSrc = nil, nil
local function reload()
    if not LOGIC then return end
    local f = io.open(LOGIC, "rb")
    if not f then return end
    local src = f:read("a")
    f:close()
    if not src or src == "" or src == lastSrc then return end
    lastSrc = src
    local chunk, err = load(src, "@cq_logic.lua")
    if not chunk then log("cq_logic.lua has an error, keeping the old version: " .. tostring(err)) return end
    local ok, mod = pcall(chunk)
    if not ok or type(mod) ~= "table" then log("cq_logic.lua failed to start, keeping the old version: " .. tostring(mod)) return end
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
        id = "BizimModlar.CompleteAllQuests",
        mod_folder = "CompleteAllQuests",
        title = "Complete All Quests",
        titles = { tr = "Tüm Görevleri Bitir" },
        -- The page has room for two lines here and for ONE line under each
        -- option (a third line runs into the next row), so keep these short.
        description = "Finishes quests through the game's own quest steps, so every reward (experience, items, skins) is given as usual. Both switches are off at first. A finished quest cannot be un-finished. World host only.",
        descriptions = { tr = "Görevleri oyunun kendi adımlarıyla bitirir; bütün ödüller (deneyim, eşya, kostüm) normaldeki gibi verilir. İki anahtar da başta kapalı. Biten görev geri alınamaz. Yalnızca dünya sahibinde çalışır." },
        version = 1,
        apply_mode = "event",
        options = {
            { key = "enabled", type = "boolean", label = "Enabled", labels = { tr = "Mod açık" }, default = true },
            { key = "main", type = "boolean", label = "Finish main quests", labels = { tr = "Ana görevleri bitir" }, default = false,
              description = "The quest is finished and rewarded; bosses stay alive.",
              descriptions = { tr = "Görev biter, ödülü gelir; boss'lar yenilmez." } },
            { key = "side", type = "boolean", label = "Finish side quests", labels = { tr = "Yan görevleri bitir" }, default = false,
              description = "Also the ones not accepted yet. Endless requests stay.",
              descriptions = { tr = "Almadıkların da dahil. Bitmeyen istekler kalır." } },
        },
    }, function(v, err)
        if v ~= nil then
            settings = v
            generation = sdk.generation()
            pushSettings()
            log("settings: on=" .. tostring(v.enabled) .. ", main=" .. tostring(v.main) .. ", side=" .. tostring(v.side))
        else
            log("Mod Options unavailable, quests stay untouched: " .. tostring(err))
        end
    end)
end

local okR, errR = pcall(reload)
if not okR then log("load error: " .. tostring(errR)) end

local n = 0
LoopAsync(1000, function()
    ExecuteInGameThread(function()
        n = n + 1
        if n % 2 == 0 then
            local ok1, e1 = pcall(reload)
            if not ok1 then log("reload error: " .. tostring(e1)) end
            if options then
                pcall(function()
                    generation = select(1, options.sync(generation, function(v) settings = v end))
                end)
            end
            pushSettings()
        end
        if L and L.tick then   -- returns at once while both switches are off or nothing is left
            local ok2, e2 = pcall(L.tick)
            if not ok2 then log("error: " .. tostring(e2)) end
        end
    end)
    return false
end)

log("Loaded - both switches are off until you turn them on (Esc > Mod Options > Complete All Quests)")
