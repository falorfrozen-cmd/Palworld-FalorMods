-- BaseWorkerMultiplier
-- Multiplies the number of worker Pals allowed per base.
--
-- How it works:
--  1) Writes a PalSchema "raw" patch for DT_BaseCampLevelData so the
--     WorkerMaxNum of every base level is changed WHEN THE TABLE LOADS
--     (before the game caches it). Requires the PalSchema mod.
--  2) At runtime, also patches the in-memory table (fallback) and raises
--     the world setting BaseCampWorkerMaxNum so the game doesn't clamp it.
-- All targets are absolute (vanilla * Multiplier), so nothing ever compounds.

local cfg = require("config")
local TAG = "[BaseWorkerMultiplier] "
local TABLE_PATH = "/Game/Pal/DataTable/BaseCamp/DT_BaseCampLevelData.DT_BaseCampLevelData"

local MULT = tonumber(cfg.Multiplier) or 3
local HARD_MAX = tonumber(cfg.HardMax) or 150

local function log(msg) print(TAG .. tostring(msg) .. "\n") end
local function dbg(msg) if cfg.Debug then log(msg) end end

-- Vanilla WorkerMaxNum per base level (Palworld 1.0): level N -> N, capped at 30, rows 1..35.
local VANILLA = {}
for lvl = 1, 35 do VANILLA[tostring(lvl)] = math.min(lvl, 30) end

local function scaled(v)
    local n = math.ceil(v * MULT)
    if n > HARD_MAX then n = HARD_MAX end
    if n < v then n = v end
    return n
end

local TARGET, desiredCap = {}, 0
for k, v in pairs(VANILLA) do
    TARGET[k] = scaled(v)
    if TARGET[k] > desiredCap then desiredCap = TARGET[k] end
end

----------------------------------------------------------------------
-- 1) PalSchema patch file (applied at table load on the next launch)
----------------------------------------------------------------------
local function modsDir()
    local src = debug.getinfo(1, "S").source or ""
    src = src:gsub("^@", ""):gsub("\\", "/")
    -- .../UE4SS/Mods/BaseWorkerMultiplier/Scripts/main.lua -> .../UE4SS/Mods/
    return src:match("^(.*/)[^/]+/Scripts/[^/]+$")
end

local function buildJson()
    local lines = { "{", '  "DT_BaseCampLevelData": {' }
    for lvl = 1, 35 do
        local k = tostring(lvl)
        lines[#lines + 1] = string.format('    "%s": { "WorkerMaxNum": %d }%s', k, TARGET[k], lvl < 35 and "," or "")
    end
    lines[#lines + 1] = "  }"
    lines[#lines + 1] = "}"
    return table.concat(lines, "\n") .. "\n"
end

local function writePalSchemaPatch()
    local base = modsDir()
    if not base then log("Could not resolve Mods folder; PalSchema patch not written") return end
    local psDir = base .. "PalSchema/mods/"
    local probe = io.open(base .. "PalSchema/dlls/main.dll", "rb")
    if not probe then
        log("PalSchema NOT installed - load-time patch unavailable, only runtime patch will be used")
        return
    end
    probe:close()

    local path = psDir .. "BaseWorkerMultiplier/raw/BaseWorkerMultiplier.json"
    local wanted = buildJson()
    local f = io.open(path, "rb")
    local current = f and f:read("*a") or nil
    if f then f:close() end
    if current == wanted then
        dbg("PalSchema patch up to date (x" .. tostring(MULT) .. ")")
        return
    end
    os.execute('mkdir "' .. (psDir .. "BaseWorkerMultiplier/raw"):gsub("/", "\\") .. '" 2>nul')
    local w = io.open(path, "wb")
    if not w then log("Could not write " .. path) return end
    w:write(wanted)
    w:close()
    log("PalSchema patch written for x" .. tostring(MULT) .. " - RESTART THE GAME once for it to fully apply")
end

----------------------------------------------------------------------
-- 2) Runtime: verify/patch in-memory table
----------------------------------------------------------------------
local function rowKey(rowName)
    if type(rowName) == "string" then return rowName end
    local ok, s = pcall(function() return rowName:ToString() end)
    if ok and s then return s end
    return tostring(rowName)
end

local tableReported = false
local function applyTable()
    local dt = StaticFindObject(TABLE_PATH)
    if not dt or not dt:IsValid() then return false end

    local total, fixed, okRows = 0, 0, 0
    local ok, err = pcall(function()
        dt:ForEachRow(function(rowName, rowData)
            local key = rowKey(rowName)
            local target = TARGET[key]
            if not target then return end
            local okR, cur = pcall(function() return rowData.WorkerMaxNum end)
            if not okR or type(cur) ~= "number" then return end
            total = total + 1
            if cur == target then
                okRows = okRows + 1
            else
                pcall(function() rowData.WorkerMaxNum = target end)
                pcall(function()
                    local r = dt:FindRow(key)
                    if r and r.WorkerMaxNum ~= target then
                        rowData.WorkerMaxNum = target
                        dt:AddRow(key, rowData)
                    end
                end)
                fixed = fixed + 1
            end
        end)
    end)
    if not ok then log("ForEachRow failed: " .. tostring(err)) return false end
    if total == 0 then return false end

    if not tableReported or fixed > 0 then
        log(string.format("Table check: %d rows, %d already correct (load-time patch), %d patched at runtime. Level 1=%d, Level 10=%d, max=%d",
            total, okRows, fixed, TARGET["1"], TARGET["10"], desiredCap))
        tableReported = true
    end
    return true
end

----------------------------------------------------------------------
-- 3) Runtime: world setting cap
----------------------------------------------------------------------
local function raiseCapOn(obj, label)
    if not obj or not obj:IsValid() then return end
    local ok, err = pcall(function()
        local ws = obj.OptionWorldSettings
        if not ws then return end
        local cur = ws.BaseCampWorkerMaxNum
        if type(cur) ~= "number" then return end
        if cur < desiredCap then
            ws.BaseCampWorkerMaxNum = desiredCap
            log(string.format("%s BaseCampWorkerMaxNum %d -> %d", label, cur, desiredCap))
        end
    end)
    if not ok then dbg(label .. " cap error: " .. tostring(err)) end
end

local function applyCap()
    if not cfg.RaiseWorldCap then return end
    for _, opt in ipairs(FindAllOf("PalOptionSubsystem") or {}) do
        pcall(function()
            local entry = opt.OptionWorldStaticSettings.BaseCampWorkerMaxNum
            if entry and type(entry.Max) == "number" and entry.Max < desiredCap then
                entry.Max = desiredCap
            end
        end)
        raiseCapOn(opt, "PalOptionSubsystem")
    end
    for _, gs in ipairs(FindAllOf("PalGameStateInGame") or {}) do
        raiseCapOn(gs, "GameState")
    end
    -- Server-side copy the game actually reads (PalWorldSettings.ini OptionSettings)
    for _, gws in ipairs(FindAllOf("PalGameWorldSettings") or {}) do
        if gws:IsValid() then
            local ok, err = pcall(function()
                local os_ = gws.OptionSettings
                local cur = os_.BaseCampWorkerMaxNum
                if type(cur) == "number" and cur < desiredCap then
                    os_.BaseCampWorkerMaxNum = desiredCap
                    log(string.format("PalGameWorldSettings BaseCampWorkerMaxNum %d -> %d", cur, desiredCap))
                end
            end)
            if not ok then dbg("PalGameWorldSettings cap error: " .. tostring(err)) end
        end
    end
end

----------------------------------------------------------------------
-- 4) Diagnostics: what the bases actually report
----------------------------------------------------------------------
local function reportBases()
    if not cfg.Debug then return end
    for _, b in ipairs(FindAllOf("PalBaseCampModel") or {}) do
        if b:IsValid() then
            local parts = {}
            for _, name in ipairs({ "Level", "BaseCampLevel", "NowBaseCampLevel", "WorkerMaxNum" }) do
                local ok, v = pcall(function() return b[name] end)
                if ok and type(v) == "number" then parts[#parts + 1] = name .. "=" .. v end
            end
            for _, fn in ipairs({ "GetBaseCampLevel", "GetWorkerMaxNum", "GetMaxWorkerMaxNum" }) do
                local ok, v = pcall(function() return b[fn](b) end)
                if ok and type(v) == "number" then parts[#parts + 1] = fn .. "()=" .. v end
            end
            log("Base: " .. (#parts > 0 and table.concat(parts, ", ") or "(no readable fields)"))
        end
    end
end

local function applyAll()
    local ok, err = pcall(function()
        applyTable()
        applyCap()
    end)
    if not ok then log("Error: " .. tostring(err)) end
end

----------------------------------------------------------------------
-- Triggers
----------------------------------------------------------------------
log(string.format("Loaded. Multiplier = x%s (level 1 -> %d workers, max %d)", tostring(MULT), TARGET["1"], desiredCap))
pcall(writePalSchemaPatch)

-- Keep enforcing (cheap): table + cap every 5s. Values are absolute, so this is safe.
LoopAsync(5000, function()
    ExecuteInGameThread(applyAll)
    return false
end)

local diag = require("diag")
local function runDiag(reason)
    ExecuteInGameThread(function()
        applyAll()
        local ok, err = pcall(diag.dump, reason)
        if not ok then log("diag failed: " .. tostring(err)) end
    end)
end

pcall(function()
    RegisterHook("/Script/Engine.PlayerController:ServerAcknowledgePossession", function()
        ExecuteWithDelay(15000, function() runDiag("world entered") end)
    end)
end)

-- F8 in game: dump again (e.g. while standing at the base / Palbox open)
pcall(function()
    RegisterKeyBind(Key.F8, function() runDiag("F8") end)
end)
