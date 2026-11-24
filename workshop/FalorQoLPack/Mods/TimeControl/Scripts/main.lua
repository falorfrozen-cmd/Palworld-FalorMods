-- TimeControl (host / world owner)
-- Change the time of day whenever you want, also in multiplayer.
--
--   Chat (anyone in the world, if the host allows friends):
--     !day     (Turkish: !gündüz)   -> day hour   (default 08:00)
--     !night   (Turkish: !gece)     -> night hour (default 22:00)
--     !time 15 (Turkish: !saat 15)  -> exact hour 0-23
--   Chat replies are English by default (Turkish selectable on the page).
--   Keys (host only): F8 = day, F9 = night (changeable in Esc > Mod Options).
--
-- How it works: world time is owned by the server (host). The game replicates
-- it to every player (APalGameStateInGame.WorldTime), so only the host's copy
-- of this mod changes it. Friends just type the chat command; they need nothing.
-- Chat is caught on the host via APalGameStateInGame:BroadcastChatMessage.
-- The hour is set with the game's own UPalTimeManager:SetGameTime_FixDay
-- (the call the game uses for its sleep skip). The result is read back from
-- the time manager and reported in chat, so it never claims a change that
-- did not happen. Fallback: APalPlayerController:Debug_SetPalWorldTime.
--
-- Settings page: Esc > Mod Options > Time of Day (needs the Workshop mod
-- "Mod Options Framework"); without it the defaults below are used.

local TAG = "[TimeControl] "
local function log(m) print(TAG .. tostring(m) .. "\n") end

local CFG = {
    enabled = true,
    allow_friends = true,
    day_hour = 8,
    night_hour = 22,
    key_day = "F8",
    key_night = "F9",
    announce = true,
    chat_language = "en",
}

-- chat texts: English default, Turkish optional (settings page)
local TEXT = {
    en = {
        set = "[Time] Time set to %s (%s).",
        failed = "[Time] Could not change the time (now %s).",
        range = "[Time] The hour must be 0-23.",
        usage = "[Time] Usage: !time 15",
        hostOnly = "[Time] Only the host can change the time.",
    },
    tr = {
        set = "[Zaman] Saat %s yapıldı (%s).",
        failed = "[Zaman] Saat değiştirilemedi (şu an %s).",
        range = "[Zaman] Saat 0-23 arası olmalı.",
        usage = "[Zaman] Kullanım: !saat 15",
        hostOnly = "[Zaman] Saati sadece host değiştirebilir.",
    },
}
local function T(k) return (TEXT[CFG.chat_language] or TEXT.en)[k] end

local function valid(o)
    if not o then return false end
    local ok, v = pcall(function() return o:IsValid() end)
    return ok and v
end

---------------------------------------------------------------------------
-- settings page (optional framework)
---------------------------------------------------------------------------
local options = nil
local generation = 0
local function applySettings(v)
    if type(v) ~= "table" then return end
    for k in pairs(CFG) do
        if v[k] ~= nil then CFG[k] = v[k] end
    end
end
local function syncOptions()
    if not options then return end
    pcall(function()
        generation = select(1, options.sync(generation, function(values) applySettings(values) end))
    end)
end

-- English is the default; Turkish (tr) is shown automatically when the game
-- language is Turkish.
local schema = {
    id = "BizimModlar.TimeControl",
    mod_folder = "TimeControl",
    title = "Time of Day",
    titles = { tr = "Zaman (gece / gündüz)" },
    description = "Change the time whenever you want. Type !day, !night or !time 15 in chat. Runs on the world host; the time changes for everyone.",
    descriptions = { tr = "Saati istediğin zaman değiştir. Sohbete !day, !night veya !time 15 yaz (Türkçe: !gündüz, !gece, !saat 15). Sadece dünyayı açan (host) kişide çalışır, saat herkese geçer." },
    version = 2,
    apply_mode = "event",
    options = {
        { key = "enabled", type = "boolean", label = "Enabled", labels = { tr = "Mod açık" }, default = true },
        { key = "allow_friends", type = "boolean", label = "Friends can change the time", labels = { tr = "Arkadaşlar da değiştirebilsin" },
          description = "When off, only the host can use the chat commands.",
          descriptions = { tr = "Kapalıysa sohbet komutlarını sadece host kullanabilir." }, default = true },
        { key = "time_section", type = "section", label = "Hours", labels = { tr = "Saatler" } },
        { key = "day_hour", type = "integer", label = "Day hour (!day)", labels = { tr = "Gündüz saati (!day)" }, default = 8, minimum = 0, maximum = 23, step = 1 },
        { key = "night_hour", type = "integer", label = "Night hour (!night)", labels = { tr = "Gece saati (!night)" }, default = 22, minimum = 0, maximum = 23, step = 1 },
        { key = "keys_section", type = "section", label = "Keys (host)", labels = { tr = "Tuşlar (host)" } },
        { key = "key_day", type = "keybind", label = "Make it day", labels = { tr = "Gündüz yap tuşu" }, default = "F8",
          description = "Key changes apply after restarting the game.",
          descriptions = { tr = "Tuş değişikliği oyun yeniden açılınca geçerli olur." } },
        { key = "key_night", type = "keybind", label = "Make it night", labels = { tr = "Gece yap tuşu" }, default = "F9" },
        { key = "chat_section", type = "section", label = "Chat", labels = { tr = "Sohbet" } },
        { key = "announce", type = "boolean", label = "Announce in chat", labels = { tr = "Sohbette duyur" }, default = true },
        { key = "chat_language", type = "enum", label = "Chat message language", labels = { tr = "Sohbet mesajı dili" }, default = "en",
          choices = { { value = "en", label = "English" }, { value = "tr", label = "Türkçe" } } },
    },
}

local okReq, sdk = pcall(require, "PalModOptionsClient")
if okReq and sdk then
    options = sdk
    local okR, e = pcall(sdk.register_when_ready, schema, function(settings, err)
        if settings ~= nil then
            applySettings(settings)
            generation = sdk.generation()
            log("settings page ready (Esc > Mod Options)")
        else
            log("Mod Options unavailable, using defaults: " .. tostring(err))
        end
    end)
    if not okR then log("Mod Options register error: " .. tostring(e)) end
else
    log("Mod Options SDK not found, using defaults")
end

---------------------------------------------------------------------------
-- time
---------------------------------------------------------------------------
local function timeManager()
    local tm = FindFirstOf("PalTimeManager")
    if valid(tm) then return tm end
    return nil
end

local function hourNow(tm)
    local h
    pcall(function() h = tm:GetCurrentPalWorldHoursFloat() end)
    return h
end

local function localController()
    for _, pc in ipairs(FindAllOf("PalPlayerController") or {}) do
        local ok, isLocal = pcall(function() return pc:IsLocalController() end)
        if ok and isLocal and valid(pc) then return pc end
    end
    return nil
end

local function isServer()
    local pc = localController()
    if not pc then return false end
    local ok, auth = pcall(function() return pc:HasAuthority() end)
    return ok and auth or false
end

local function allPlayerUIds()
    local list = {}
    for _, ps in ipairs(FindAllOf("PalPlayerState") or {}) do
        if valid(ps) and not ps:GetFullName():find("Default__") then
            pcall(function()
                local g = ps.PlayerUId
                list[#list + 1] = { A = g.A, B = g.B, C = g.C, D = g.D }
            end)
        end
    end
    return list
end

local function say(text)
    log(text)
    if not CFG.announce then return end
    pcall(function()
        local pc = localController()
        local pu = StaticFindObject("/Script/Pal.Default__PalUtility")
        if pc and valid(pu) then pu:SendSystemToPlayerChat(pc, text, allPlayerUIds()) end
    end)
end

local function fmt(h)
    if not h then return "?" end
    local hh = math.floor(h) % 24
    local mm = math.floor((h - math.floor(h)) * 60 + 0.5) % 60
    return string.format("%02d:%02d", hh, mm)
end

local busy = false
local function closeTo(a, b)
    if not a then return false end
    local d = math.abs(a - b) % 24
    return d < 0.5 or d > 23.5
end

-- Set the hour, then read it back from the game and report what really happened.
local function setHour(hour, who)
    if busy then return end
    hour = math.floor(tonumber(hour) or -1)
    if hour < 0 or hour > 23 then say(T("range")) return end
    local tm = timeManager()
    if not tm then log("no time manager yet") return end
    if not isServer() then
        log("not the host - only the world owner can change the time (friends: use the chat command)")
        return
    end
    busy = true
    local before = hourNow(tm)
    local okA, eA = pcall(function() tm:SetGameTime_FixDay(hour) end)
    if not okA then log("SetGameTime_FixDay error: " .. tostring(eA)) end
    ExecuteWithDelay(700, function()
        ExecuteInGameThread(function()
            local after = hourNow(tm)
            if closeTo(after, hour) then
                busy = false
                say(string.format(T("set"), fmt(after), who or "host"))
                return
            end
            log(string.format("FixDay did not change the hour (before %s, after %s) - trying fallback", fmt(before), fmt(after)))
            pcall(function() localController():Debug_SetPalWorldTime(hour) end)
            ExecuteWithDelay(700, function()
                ExecuteInGameThread(function()
                    busy = false
                    local after2 = hourNow(tm)
                    if closeTo(after2, hour) then
                        say(string.format(T("set"), fmt(after2), who or "host"))
                    else
                        say(string.format(T("failed"), fmt(after2)))
                    end
                end)
            end)
        end)
    end)
end

---------------------------------------------------------------------------
-- chat commands (host catches every player's chat)
---------------------------------------------------------------------------
local function normalize(s)
    s = s:gsub("Ü", "ü"):gsub("İ", "i"):gsub("Ğ", "ğ"):gsub("Ş", "ş"):gsub("Ç", "ç"):gsub("Ö", "ö")
    return s:lower()
end

local DAY_WORDS   = { ["!gündüz"] = true, ["!gunduz"] = true, ["!gun"] = true, ["!gün"] = true, ["!day"] = true, ["!sabah"] = true }
local NIGHT_WORDS = { ["!gece"] = true, ["!night"] = true }
local HOUR_WORDS  = { ["!saat"] = true, ["!time"] = true }

local function handleChat(text, sender, senderIsHost)
    syncOptions()
    if not CFG.enabled then return end
    local t = normalize(text or "")
    local word, arg = t:match("^%s*(!%S+)%s*(%S*)")
    if not word then return end
    local hour
    if DAY_WORDS[word] then hour = CFG.day_hour
    elseif NIGHT_WORDS[word] then hour = CFG.night_hour
    elseif HOUR_WORDS[word] then hour = tonumber(arg)
        if not hour then say(T("usage")) return end
    else return end
    if not senderIsHost and not CFG.allow_friends then
        say(T("hostOnly"))
        return
    end
    setHour(hour, sender)
end

local function hostName()
    local n = "host"
    pcall(function() n = localController().PlayerState:GetPlayerName():ToString() end)
    return n
end

local okH, eH = pcall(RegisterHook, "/Script/Pal.PalGameStateInGame:BroadcastChatMessage", function(self, msgParam)
    local okS, server = pcall(function() return self:get():HasAuthority() end)
    if not (okS and server) then return end
    local text, sender = "", "?"
    pcall(function()
        local m = msgParam:get()
        text = m.Message:ToString()
        sender = m.Sender:ToString()
    end)
    if not text:find("^%s*!") then return end
    local fromHost = (sender == hostName())
    ExecuteInGameThread(function()
        local ok, e = pcall(handleChat, text, sender, fromHost)
        if not ok then log("chat error: " .. tostring(e)) end
    end)
end)
log(okH and "chat commands active (!day / !night / !time N)" or ("chat hook failed: " .. tostring(eH)))

---------------------------------------------------------------------------
-- keys (host) - read the saved key once at start
---------------------------------------------------------------------------
local function bindKey(name, fn)
    local k = Key[name]
    if not k then log("unknown key " .. tostring(name)) return end
    RegisterKeyBind(k, function()
        if options and options.capture_active and options.capture_active() then return end
        ExecuteInGameThread(function()
            syncOptions()
            if not CFG.enabled then return end
            local ok, e = pcall(fn)
            if not ok then log("key error: " .. tostring(e)) end
        end)
    end)
end

-- give the framework a moment to deliver saved keys, then bind
ExecuteWithDelay(5000, function()
    bindKey(CFG.key_day, function() setHour(CFG.day_hour, hostName()) end)
    bindKey(CFG.key_night, function() setHour(CFG.night_hour, hostName()) end)
    log("keys: " .. CFG.key_day .. " = day, " .. CFG.key_night .. " = night")
end)

---------------------------------------------------------------------------
-- test channel (for checking without anyone typing): Scripts/tc_cmd.txt
--   say <text>    -> handled exactly like a chat line from the host
--   hour          -> log the current time
---------------------------------------------------------------------------
local function scriptDir()
    local src = ""
    pcall(function() src = debug.getinfo(1, "S").source or "" end)
    return (src:gsub("^@", "")):match("^(.*)[/\\]")
end
local CMD = scriptDir() and (scriptDir() .. "/tc_cmd.txt") or nil

LoopAsync(2000, function()
    if not CMD then return true end
    local f = io.open(CMD, "rb")
    if not f then return false end
    local txt = f:read("a") or ""
    f:close()
    if txt:match("^%s*$") then return false end
    local w = io.open(CMD, "wb"); if w then w:close() end
    ExecuteInGameThread(function()
        for line in txt:gmatch("[^\r\n]+") do
            log("CMD " .. line)
            local c, rest = line:match("^%s*(%S+)%s*(.*)$")
            if c == "say" then
                local ok, e = pcall(handleChat, rest, hostName(), true)
                if not ok then log("CMD error: " .. tostring(e)) end
            elseif c == "hour" then
                local tm = timeManager()
                local d = "?"
                pcall(function() d = tostring(tm:GetCurrentPalWorldTime_Day()) end)
                log("HOUR day " .. d .. " time " .. fmt(tm and hourNow(tm)) .. " server=" .. tostring(isServer()))
            end
        end
    end)
    return false
end)

log("Loaded - chat !day / !night / !time N, keys F8/F9 (host)")
