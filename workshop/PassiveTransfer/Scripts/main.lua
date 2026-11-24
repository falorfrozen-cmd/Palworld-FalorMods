-- PassiveTransfer (world host)
-- A panel (default key F5) that moves one passive skill from a Pal in your
-- party to another Pal in your party. The giver loses the passive; if the
-- receiver is full (4 passives) one of its passives goes to the giver instead.
-- Runs on the world host only.
--
-- The logic is in pt_logic.lua next to this file.
-- Settings: Esc > Mod Options > Passive Transfer.
--
-- There is no timer in this mod: it only reacts to the key and to clicks on
-- its own buttons. Settings are read again each time the key is pressed.

local TAG = "[PassiveTransfer] "
local function log(m) print(TAG .. tostring(m) .. "\n") end

local L = nil
local keyName = "F5"
local settings = nil
local options, generation = nil, 0
local function pushSettings()
    if settings and L and L.setSettings then pcall(L.setSettings, settings) end
end
local function describe(v)
    return "settings: on=" .. tostring(v.enabled) .. ", key=" .. tostring(v.key) .. ", language=" .. tostring(v.language)
end

local okL, mod = pcall(require, "pt_logic")
if okL and type(mod) == "table" then
    L = mod
    log("logic loaded - version " .. tostring(mod.version))
else
    log("pt_logic.lua failed to load: " .. tostring(mod))
end

---------------------------------------------------------------------------
-- settings page
---------------------------------------------------------------------------
local okReq, sdk = pcall(require, "PalModOptionsClient")
if okReq and sdk then
    options = sdk
    pcall(sdk.register_when_ready, {
        id = "BizimModlar.PassiveTransfer",
        mod_folder = "PassiveTransfer",
        title = "Passive Transfer",
        titles = { tr = "Pasif Aktarımı" },
        description = "Press the key to open a panel that moves one passive skill from a Pal in your party to another Pal in your party. The giver loses it. If the receiver already has 4 passives, one of them goes to the giver instead. Works for the world host.",
        descriptions = { tr = "Tuşa basınca açılan panel, takımındaki bir Pal'ın pasifini takımındaki başka bir Pal'a taşır. Veren Pal o pasifi kaybeder. Alan Pal'da zaten 4 pasif varsa, onlardan biri verene geçer. Dünyanın host'unda çalışır." },
        version = 1,
        apply_mode = "event",
        options = {
            { key = "enabled", type = "boolean", label = "Enabled", labels = { tr = "Mod açık" }, default = true },
            { key = "key", type = "keybind", label = "Open / close key", labels = { tr = "Aç / kapat tuşu" }, default = "F5",
              description = "Key changes apply after restarting the game.",
              descriptions = { tr = "Tuş değişikliği oyun yeniden açılınca geçerli olur." } },
            { key = "language", type = "enum", label = "Panel language", labels = { tr = "Panel dili" }, default = "auto",
              choices = { { value = "auto", label = "Auto (game language)" }, { value = "en", label = "English" }, { value = "tr", label = "Türkçe" } } },
        },
    }, function(v, err)
        if v ~= nil then
            settings = v
            if v.key then keyName = v.key end
            generation = sdk.generation()
            pushSettings()
            log(describe(v))
        else
            log("Mod Options unavailable, using defaults: " .. tostring(err))
        end
    end)
end

-- settings changed on the Mod Options page since the last key press?
local function syncSettings()
    if not options then return end
    pcall(function()
        generation = select(1, options.sync(generation, function(v) settings = v; log(describe(v)) end))
    end)
    pushSettings()
end

---------------------------------------------------------------------------
-- clicks: a hook on the click event of the game's Esc-menu button. That
-- function only exists once the button's blueprint is loaded, so the hook is
-- installed the first time the panel is opened (in the game thread).
---------------------------------------------------------------------------
local hooked = false
local function ensureHook()
    if hooked or not L then return hooked end
    pcall(function() LoadAsset(L.BTN_ASSET) end)
    local ok, err = pcall(RegisterHook, L.CLICK_FN, function(ctx)
        if not L or not L.onClick then return end
        local okC, eC = pcall(L.onClick, ctx)
        if not okC then log("click error: " .. tostring(eC)) end
    end)
    if ok then hooked = true else log("click hook not ready: " .. tostring(err)) end
    return hooked
end

ExecuteWithDelay(5000, function()
    local k = Key[keyName] or Key.F5
    RegisterKeyBind(k, function()
        if options and options.capture_active and options.capture_active() then return end
        ExecuteInGameThread(function()
            if not L or not L.toggle then return end
            local ok, e = pcall(function()
                if L.isOpen() then L.close() return end
                syncSettings()
                if settings and settings.enabled == false then return end
                if not ensureHook() then return end
                L.open()
            end)
            if not ok then log("error: " .. tostring(e)) end
        end)
    end)
    log("panel key: " .. tostring(keyName))
end)

log("Loaded - passive transfer panel (Esc > Mod Options > Passive Transfer)")
