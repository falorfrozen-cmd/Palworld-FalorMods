-- UnlockAllWaypoints - loader
-- Every fast-travel statue and watch tower is unlocked for you without going
-- there, in a few seconds, and you do not move. On the world host it is
-- automatic (also for friends, if the setting is on); the key (default F11)
-- runs it on request.
--
-- How (verified 2026-11-17 on the host, 174 of 174 unlocked): the game only
-- accepts a statue unlock when the statue's interact box is next to the
-- player. So each statue is moved under the player, unlocked and moved back
-- inside one frame - it is never drawn there. See wp_logic.lua.
-- You also get the game's normal technology points for each unlock.
--
-- In a friend's own game (not the host) this trick may be refused by the
-- host; then the key falls back to visiting each statue (a few minutes).
--
-- All logic is in wp_logic.lua next to this file; this loader re-reads it
-- every 2 s so fixes apply without restarting (UE4SS hot reload stays off).
-- Settings: Esc > Mod Options > Unlock All Waypoints.

local TAG = "[UnlockAllWaypoints] "
local function log(m) print(TAG .. tostring(m) .. "\n") end

local function scriptDir()
    local src = ""
    pcall(function() src = debug.getinfo(1, "S").source or "" end)
    return (src:gsub("^@", "")):match("^(.*)[/\\]")
end
local DIR = scriptDir()
local LOGIC = DIR and (DIR .. "/wp_logic.lua") or nil

local L, lastSrc = nil, nil

-- chat line for the local player (falls back to the log)
local function say(msg)
    log(msg)
    pcall(function()
        local util = StaticFindObject("/Script/Pal.Default__PalUtility")
        for _, pc in ipairs(FindAllOf("PalPlayerController") or {}) do
            if pc:IsLocalController() then
                local g = pc.PlayerState.PlayerUId
                util:SendSystemToPlayerChat(pc, "[Waypoints] " .. msg, { { A = g.A, B = g.B, C = g.C, D = g.D } })
            end
        end
    end)
end

---------------------------------------------------------------------------
-- settings page
---------------------------------------------------------------------------
local keyName = "F11"
local settings = nil
local options, generation = nil, 0
local function pushSettings()
    if settings and L and L.setSettings then pcall(L.setSettings, settings) end
end
local function applySettings(v)
    if type(v) ~= "table" then return end
    settings = v
    if v.key then keyName = v.key end
    pushSettings()
end

local function reload()
    if not LOGIC then return end
    local f = io.open(LOGIC, "rb")
    if not f then return end
    local src = f:read("a")
    f:close()
    if not src or src == "" or src == lastSrc then return end
    lastSrc = src
    local chunk, err = load(src, "@wp_logic.lua")
    if not chunk then log("wp_logic.lua has an error, keeping the old version: " .. tostring(err)) return end
    local ok, mod = pcall(chunk)
    if not ok or type(mod) ~= "table" then log("wp_logic.lua failed to start, keeping the old version: " .. tostring(mod)) return end
    local first = (L == nil)
    L = mod
    L.say = say
    pushSettings()
    log((first and "logic loaded" or "logic RELOADED live (no restart needed)") .. " - version " .. tostring(mod.version))
end

local okReq, sdk = pcall(require, "PalModOptionsClient")
if okReq and sdk then
    options = sdk
    pcall(sdk.register_when_ready, {
        id = "BizimModlar.UnlockAllWaypoints",
        mod_folder = "UnlockAllWaypoints",
        title = "Unlock All Waypoints",
        titles = { tr = "Tüm Waypoint'leri Aç" },
        description = "Unlocks every fast-travel statue and watch tower without going there. Takes a few seconds; you do not move. Unlocks are saved: turning this off does not lock them again.",
        descriptions = { tr = "Tüm hızlı yolculuk heykellerini ve gözetleme kulelerini oraya gitmeden açar. Birkaç saniye sürer, karakterin hareket etmez. Açılanlar kaydedilir: modu kapatmak onları geri kilitlemez." },
        version = 2,
        apply_mode = "event",
        options = {
            { key = "enabled", type = "boolean", label = "Enabled", labels = { tr = "Mod açık" }, default = true },
            { key = "auto", type = "boolean", label = "Unlock automatically", labels = { tr = "Otomatik aç" }, default = true,
              description = "Unlocks everything by itself a few seconds after a character enters the world (new characters too). When off, only the key does it.",
              descriptions = { tr = "Bir karakter dünyaya girdikten birkaç saniye sonra her şeyi kendiliğinden açar (yeni karakterler dahil). Kapalıyken sadece tuşla açılır." } },
            { key = "include_friends", type = "boolean", label = "Also for friends (host)", labels = { tr = "Arkadaşlar için de (host)" }, default = true,
              description = "The world host also unlocks for the other players. When off, only for your own character.",
              descriptions = { tr = "Dünyayı açan kişi diğer oyuncular için de açar. Kapalıyken sadece kendi karakterin için." } },
            { key = "key", type = "keybind", label = "Unlock now key", labels = { tr = "Şimdi aç tuşu" }, default = "F11",
              description = "Key changes apply after restarting the game.",
              descriptions = { tr = "Tuş değişikliği oyun yeniden açılınca geçerli olur." } },
        },
    }, function(v, err)
        if v ~= nil then
            applySettings(v)
            generation = sdk.generation()
            log("settings: on=" .. tostring(v.enabled) .. ", auto=" .. tostring(v.auto) .. ", friends=" .. tostring(v.include_friends))
        else
            log("Mod Options unavailable, using defaults: " .. tostring(err))
        end
    end)
end

local okR, errR = pcall(reload)
if not okR then log("load error: " .. tostring(errR)) end

ExecuteWithDelay(5000, function()
    local k = Key[keyName] or Key.F11
    RegisterKeyBind(k, function()
        if options and options.capture_active and options.capture_active() then return end
        ExecuteInGameThread(function()
            if not L then return end
            if settings and settings.enabled == false then return end
            local ok, e = pcall(L.toggle or L.start)
            if not ok then log("error: " .. tostring(e)) end
        end)
    end)
    log("unlock-now key: " .. tostring(keyName))
end)

local ticks = 0
LoopAsync(500, function()
    ticks = ticks + 1
    ExecuteInGameThread(function()
        if ticks % 4 == 0 then   -- every 2 s
            local ok1, e1 = pcall(reload)
            if not ok1 then log("reload error: " .. tostring(e1)) end
            if options then
                pcall(function()
                    generation = select(1, options.sync(generation, function(v) applySettings(v) end))
                end)
            end
            -- background control without a key press: write a command into wp_cmd.txt
            -- (start, stop, tour, locked, status <id>, instant <id>, comp <id>)
            pcall(function()
                if not DIR then return end
                local p = DIR .. "/wp_cmd.txt"
                local f = io.open(p, "rb")
                if not f then return end
                local txt = f:read("a") or ""
                f:close()
                if txt:match("^%s*$") then return end
                local w = io.open(p, "wb"); if w then w:close() end
                local c = txt:match("%S+")
                log("CMD " .. tostring(c))
                if c and L and L.command then L.command(c, txt:match("^%s*%S+%s+(%S+)") or "") end
            end)
        end
        if L and L.runTick then
            local ok2, e2 = pcall(L.runTick)
            if not ok2 then log("error: " .. tostring(e2)) end
        end
    end)
    return false
end)

log("Loaded - fast-travel waypoints unlock by themselves (Esc > Mod Options > Unlock All Waypoints, F11 = now)")
