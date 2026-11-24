-- BigInventory - loader (world host)
-- The player inventory (42 slots) only grows by carrying the four pouches.
-- The PalSchema part of this mod (PalSchema/mods/BigInventory) makes every
-- pouch add 100 slots; this part gives each player the pouches they do not
-- carry yet, so the inventory becomes 42 + 400 = 442 slots.
-- Friends need nothing installed: the host hands out the pouches.
--
-- NOTE: the pouches are saved with the character. Turning the mod off later
-- does not take them away.
--
-- All logic is in bi_logic.lua next to this file; this loader re-reads it
-- every 2 s so fixes apply without restarting (UE4SS hot reload stays off).
-- Settings: Esc > Mod Options > Big Inventory.

local TAG = "[BigInventory] "
local function log(m) print(TAG .. tostring(m) .. "\n") end

local function scriptDir()
    local src = ""
    pcall(function() src = debug.getinfo(1, "S").source or "" end)
    return (src:gsub("^@", "")):match("^(.*)[/\\]")
end
local DIR = scriptDir()
local LOGIC = DIR and (DIR .. "/bi_logic.lua") or nil

local L, lastSrc = nil, nil
local function reload()
    if not LOGIC then return end
    local f = io.open(LOGIC, "rb")
    if not f then return end
    local src = f:read("a")
    f:close()
    if not src or src == "" or src == lastSrc then return end
    lastSrc = src
    local chunk, err = load(src, "@bi_logic.lua")
    if not chunk then log("bi_logic.lua has an error, keeping the old version: " .. tostring(err)) return end
    local ok, mod = pcall(chunk)
    if not ok or type(mod) ~= "table" then log("bi_logic.lua failed to start, keeping the old version: " .. tostring(mod)) return end
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
local function describe(v)
    return "settings: on=" .. tostring(v.enabled) .. ", friends=" .. tostring(v.include_friends)
end
local okReq, sdk = pcall(require, "PalModOptionsClient")
if okReq and sdk then
    options = sdk
    pcall(sdk.register_when_ready, {
        id = "BizimModlar.BigInventory",
        mod_folder = "BigInventory",
        title = "Big Inventory",
        titles = { tr = "Büyük Envanter" },
        description = "Gives every player the four pouches (Small, Medium, Large, Giant); each one adds 100 inventory slots, 442 in total. Runs on the world host. The pouches stay with the character: turning this off does not take them away.",
        descriptions = { tr = "Her oyuncuya dört keseyi (Küçük, Orta, Büyük, Dev) verir; her biri envantere 100 slot ekler, toplam 442. Host'ta çalışır. Keseler karakterde kalır: modu kapatmak onları geri almaz." },
        version = 1,
        apply_mode = "event",
        options = {
            { key = "enabled", type = "boolean", label = "Enabled", labels = { tr = "Mod açık" }, default = true },
            { key = "include_friends", type = "boolean", label = "Also for friends", labels = { tr = "Arkadaşlar için de" }, default = true,
              description = "When off, only the host's own character gets the pouches.",
              descriptions = { tr = "Kapalıyken sadece host'un kendi karakteri keseleri alır." } },
        },
    }, function(v, err)
        if v ~= nil then
            settings = v
            generation = sdk.generation()
            pushSettings()
            log(describe(v))
        else
            log("Mod Options unavailable, using defaults: " .. tostring(err))
        end
    end)
end

local okR, errR = pcall(reload)
if not okR then log("load error: " .. tostring(errR)) end

-- watchdog: one line only when a tick took 10 ms or more
local perf = { n = 0, total = 0, max = 0, since = os.clock() }
local function timed(fn)
    local t0 = os.clock()
    local ok, err = pcall(fn)
    local now = os.clock()
    local ms = (now - t0) * 1000
    perf.n = perf.n + 1; perf.total = perf.total + ms
    if ms > perf.max then perf.max = ms end
    if now - perf.since >= 30 then
        if perf.max >= 10 then
            log(string.format("SLOW %d ticks in %.0f s, avg %.2f ms, max %.0f ms", perf.n, now - perf.since, perf.total / perf.n, perf.max))
        end
        perf.n, perf.total, perf.max, perf.since = 0, 0, 0, now
    end
    return ok, err
end

local ticks = 0
LoopAsync(1000, function()
    ticks = ticks + 1
    ExecuteInGameThread(function()
        timed(function()
            if ticks % 2 == 0 then
                local ok1, e1 = pcall(reload)
                if not ok1 then log("reload error: " .. tostring(e1)) end
                if options then
                    pcall(function()
                        generation = select(1, options.sync(generation, function(v) settings = v; log(describe(v)) end))
                    end)
                end
                pushSettings()
                -- test channel: write a command into bi_cmd.txt (status)
                pcall(function()
                    if not DIR or not L or not L.command then return end
                    local p = DIR .. "/bi_cmd.txt"
                    local f = io.open(p, "rb")
                    if not f then return end
                    local txt = f:read("a") or ""
                    f:close()
                    if txt:match("^%s*$") then return end
                    local w = io.open(p, "wb"); if w then w:close() end
                    log("CMD " .. txt:gsub("%s+$", ""))
                    L.command(txt)
                end)
            end
            if L and L.tick then
                local ok2, e2 = pcall(L.tick)
                if not ok2 then log("error: " .. tostring(e2)) end
            end
        end)
    end)
    return false
end)

log("Loaded - gives the inventory pouches to every player (Esc > Mod Options > Big Inventory)")
