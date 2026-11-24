-- GlobalBaseStorage - loader
--
-- All the logic lives in gbs_logic.lua next to this file. This loader re-reads
-- gbs_logic.lua every 2 s and swaps the new version in when it changed, so
-- fixes apply WITHOUT restarting the game. (UE4SS hot reload / Ctrl+R must stay
-- off - it crashes this game. This only reloads this one mod's own file.)
-- If the new file has an error, the old version keeps running.

local TAG = "[GlobalBaseStorage] "
local function log(m) print(TAG .. tostring(m) .. "\n") end

local function valid(o)
    if not o then return false end
    local ok, v = pcall(function() return o:IsValid() end)
    return ok and v
end

local function findLogicFile()
    local p
    pcall(function() p = package.searchpath("gbs_logic", package.path) end)
    if p then return p end
    local src = ""
    pcall(function() src = debug.getinfo(1, "S").source or "" end)
    src = src:gsub("^@", "")
    local dir = src:match("^(.*)[/\\]")
    if dir and dir ~= "" then return dir .. "/gbs_logic.lua" end
    return nil
end

local LOGIC = findLogicFile()
local L = nil
local lastSrc = nil

local function reload()
    if not LOGIC then return end
    local f = io.open(LOGIC, "rb")
    if not f then return end
    local src = f:read("a")
    f:close()
    if not src or src == "" or src == lastSrc then return end
    lastSrc = src
    local chunk, err = load(src, "@gbs_logic.lua")
    if not chunk then log("gbs_logic.lua has an error, keeping the old version: " .. tostring(err)) return end
    local ok, mod = pcall(chunk)
    if not ok or type(mod) ~= "table" then log("gbs_logic.lua failed to start, keeping the old version: " .. tostring(mod)) return end
    pcall(function() mod.baseDir = LOGIC:match("^(.*)[/\\]") end)
    local first = (L == nil)
    L = mod
    log((first and "logic loaded" or "logic RELOADED live (no restart needed)") .. " - version " .. tostring(mod.version))
end

local hooked = {}   -- path -> UFunction object we hooked
local function ensureHooks()
    if not (L and L.hooks) then return end
    for path in pairs(L.hooks) do
        if not valid(hooked[path]) then
            local fn = StaticFindObject(path)
            if valid(fn) then
                hooked[path] = fn
                local ok, e = pcall(RegisterHook, path, function(...)
                    local h = L and L.hooks and L.hooks[path]
                    if h then
                        local ok2, e2 = pcall(h, ...)
                        if not ok2 then log("hook error: " .. tostring(e2)) end
                    end
                end)
                if ok then log("hooked " .. tostring(path:match(":(.*)$")))
                else log("hook failed " .. tostring(path:match(":(.*)$")) .. ": " .. tostring(e)) end
            end
        end
    end
end

-- Settings page: Esc > Mod Options > Ortak Depo (optional framework)
local options, generation, settings = nil, 0, nil
local function pushSettings()
    if settings and L and L.setSettings then pcall(L.setSettings, settings) end
end
local okReq, sdk = pcall(require, "PalModOptionsClient")
if okReq and sdk then
    options = sdk
    pcall(sdk.register_when_ready, {
        id = "BizimModlar.GlobalBaseStorage",
        mod_folder = "GlobalBaseStorage",
        title = "Global Base Storage",
        titles = { tr = "Ortak Depo" },
        description = "In the build menu (B), left-click a structure you lack materials for: the missing materials come from your bases' chests into your inventory.",
        descriptions = { tr = "B menüsünde malzemesi yetmeyen yapıya sol tıklayınca eksik malzeme üslerdeki sandıklardan envantere gelir." },
        version = 3,
        apply_mode = "event",
        options = {
            { key = "enabled", type = "boolean", label = "Enabled", labels = { tr = "Mod açık" }, default = true },
            { key = "auto_pull", type = "boolean", label = "Pull materials on click", labels = { tr = "Tıklayınca malzeme çek" }, default = true,
              description = "When off, clicking a structure does not pull any materials.",
              descriptions = { tr = "Kapalıyken yapıya tıklamak malzeme çekmez." } },
            { key = "chat_language", type = "enum", label = "Chat message language", labels = { tr = "Sohbet mesajı dili" }, default = "en",
              choices = { { value = "en", label = "English" }, { value = "tr", label = "Türkçe" } } },
        },
    }, function(v, err)
        if v ~= nil then
            settings = v
            generation = sdk.generation()
            pushSettings()
        else
            log("Mod Options unavailable, using defaults: " .. tostring(err))
        end
    end)
end

log("logic file: " .. tostring(LOGIC))
local okR, errR = pcall(reload)
if not okR then log("load error: " .. tostring(errR)) end
if not L then log("WARNING: gbs_logic.lua could not be loaded yet") end

LoopAsync(2000, function()
    ExecuteInGameThread(function()
        local ok1, e1 = pcall(reload)
        if not ok1 then log("reload error: " .. tostring(e1)) end
        if options then
            pcall(function()
                generation = select(1, options.sync(generation, function(v) settings = v end))
            end)
        end
        pushSettings()   -- cheap; also covers a freshly reloaded logic file
        local ok2, e2 = pcall(ensureHooks)
        if not ok2 then log("hook setup error: " .. tostring(e2)) end
        if L and L.tick then
            local ok3, e3 = pcall(L.tick)
            if not ok3 then log("tick error: " .. tostring(e3)) end
        end
    end)
    return false
end)

RegisterKeyBind(Key.F6, function()
    ExecuteInGameThread(function()
        if L and L.onPullKey then
            local ok, err = pcall(L.onPullKey)
            if not ok then log("pull error: " .. tostring(err)) end
        end
    end)
end)

log("Loaded - B menu: click a structure to pull missing materials (F6 = backup)")
