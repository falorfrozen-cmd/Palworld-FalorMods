-- BossRespawn - loader (world host)
-- Choose how long it takes until a defeated boss is back:
--  * field bosses (the Alpha Pals standing on the map)
--  * dungeons (the boss of the fixed dungeons, and how soon a new random
--    dungeon appears)
-- Friends need nothing installed: the host decides when bosses return.
--
-- All logic is in br_logic.lua next to this file; this loader re-reads it
-- every 2 s so fixes apply without restarting (UE4SS hot reload stays off).
-- Settings: Esc > Mod Options > Boss Respawn.

local TAG = "[BossRespawn] "
local function log(m) print(TAG .. tostring(m) .. "\n") end

local function scriptDir()
    local src = ""
    pcall(function() src = debug.getinfo(1, "S").source or "" end)
    return (src:gsub("^@", "")):match("^(.*)[/\\]")
end
local DIR = scriptDir()
local LOGIC = DIR and (DIR .. "/br_logic.lua") or nil
_G.BR_DIR = DIR

local L, lastSrc = nil, nil
local function reload()
    if not LOGIC then return end
    local f = io.open(LOGIC, "rb")
    if not f then return end
    local src = f:read("a")
    f:close()
    if not src or src == "" or src == lastSrc then return end
    lastSrc = src
    local chunk, err = load(src, "@br_logic.lua")
    if not chunk then log("br_logic.lua has an error, keeping the old version: " .. tostring(err)) return end
    local ok, mod = pcall(chunk)
    if not ok or type(mod) ~= "table" then log("br_logic.lua failed to start, keeping the old version: " .. tostring(mod)) return end
    local first = (L == nil)
    L = mod
    L.dir = DIR
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
    return string.format("settings: on=%s, field bosses %s min, dungeons %s min", tostring(v.enabled), tostring(v.field_minutes), tostring(v.dungeon_minutes))
end
local okReq, sdk = pcall(require, "PalModOptionsClient")
if okReq and sdk then
    options = sdk
    pcall(sdk.register_when_ready, {
        id = "BizimModlar.BossRespawn",
        mod_folder = "BossRespawn",
        title = "Boss Respawn",
        titles = { tr = "Boss Yeniden Doğma" },
        description = "How long until a defeated boss is back. Runs on the world host and works for everyone. Timers count only while the world is running.",
        descriptions = { tr = "Yenilen bir bossun ne kadar sürede geri geleceği. Host'ta çalışır, herkes için geçerlidir. Süre yalnızca dünya açıkken işler." },
        version = 1,
        apply_mode = "event",
        options = {
            { key = "enabled", type = "boolean", label = "Enabled", labels = { tr = "Mod açık" }, default = true,
              description = "When off, the game's own timing is used again.",
              descriptions = { tr = "Kapalıyken oyunun kendi süreleri geçerli olur." } },
            { key = "field_minutes", type = "integer", label = "Field bosses (minutes)", labels = { tr = "Saha bossları (dakika)" },
              description = "Minutes after a field boss (Alpha Pal on the map) is defeated or caught until it can appear again. It appears when a player comes close.",
              descriptions = { tr = "Haritadaki bir saha bossu (Alpha Pal) yenildikten ya da yakalandıktan kaç dakika sonra tekrar çıkabilir. Bir oyuncu yaklaşınca belirir." },
              default = 10, minimum = 0, maximum = 120, step = 1 },
            { key = "dungeon_minutes", type = "integer", label = "Dungeons (minutes)", labels = { tr = "Zindanlar (dakika)" },
              description = "Minutes until the boss of a fixed dungeon is back, and until a new random dungeon appears (normally 60).",
              descriptions = { tr = "Sabit zindanın bossunun geri gelmesi ve yeni bir rastgele zindanın çıkması için dakika (normali 60)." },
              default = 30, minimum = 1, maximum = 600, step = 1 },
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

-- tell UnlockAllWaypoints (which ran the first test version) to stand down
pcall(function() ModRef:SetSharedVariable("BossRespawn.Loaded", true) end)

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
                -- test channel: write a command into br_cmd.txt (status | set field N | set dungeon N | now)
                pcall(function()
                    if not DIR or not L or not L.command then return end
                    local p = DIR .. "/br_cmd.txt"
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

log("Loaded - boss respawn times (Esc > Mod Options > Boss Respawn)")
