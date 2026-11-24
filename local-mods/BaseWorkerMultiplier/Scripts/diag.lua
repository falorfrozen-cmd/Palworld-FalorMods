-- Diagnostics: dumps the real runtime values that decide the base worker limit
-- into BaseWorkerMultiplier/diag.txt (overwritten each dump).

local M = {}

local function modDir()
    local src = (debug.getinfo(1, "S").source or ""):gsub("^@", ""):gsub("\\", "/")
    return src:match("^(.*/)Scripts/[^/]+$") or ""
end
local OUT = modDir() .. "diag.txt"

local buf
local function w(s) buf[#buf + 1] = s end

local function fname(x)
    local ok, s = pcall(function() return x:GetFName():ToString() end)
    return ok and s or "?"
end

local function valueStr(v)
    local t = type(v)
    if t == "number" or t == "boolean" or t == "string" then return tostring(v) end
    if t == "nil" then return "nil" end
    local ok, s = pcall(function() return v:ToString() end)
    if ok and type(s) == "string" then return s end
    ok, s = pcall(function() return v:GetFullName() end)
    if ok and type(s) == "string" then return s end
    return "<" .. t .. ">"
end

local INTERESTING = { "Worker", "Level", "Max", "Num", "Limit", "Capacity", "Slot", "Count" }
local function interesting(name)
    for _, k in ipairs(INTERESTING) do
        if name:find(k, 1, true) then return true end
    end
    return false
end

-- Dump properties of an object/struct (walking super classes)
local function dumpProps(container, struct, indent, onlyInteresting, depth)
    depth = depth or 0
    local s = struct
    local guard = 0
    while s and guard < 12 do
        guard = guard + 1
        local okValid = pcall(function() return s:IsValid() end)
        if not okValid then break end
        pcall(function()
            s:ForEachProperty(function(prop)
                local name = fname(prop)
                local ptype = fname(prop:GetClass())
                local okV, v = pcall(function() return container[name] end)
                local show = (not onlyInteresting) or interesting(name)
                if ptype == "StructProperty" and depth < 2 then
                    local okS, inner = pcall(function() return prop:GetStruct() end)
                    if okS and inner and okV and v ~= nil then
                        -- show struct contents only if struct name or field looks relevant
                        local sub = {}
                        local saved = buf
                        buf = sub
                        dumpProps(v, inner, indent .. "    ", onlyInteresting and not interesting(name), depth + 1)
                        buf = saved
                        if #sub > 0 then
                            w(indent .. name .. " (" .. fname(inner) .. "):")
                            for _, line in ipairs(sub) do w(line) end
                        end
                    end
                elseif show then
                    w(string.format("%s%s [%s] = %s", indent, name, ptype, okV and valueStr(v) or "<err>"))
                end
            end)
        end)
        local okSup, sup = pcall(function() return s:GetSuperStruct() end)
        if not okSup or not sup then break end
        local okIV, iv = pcall(function() return sup:IsValid() end)
        if not okIV or not iv then break end
        s = sup
    end
end

local FUNCS = {
    "GetWorkerMaxNum", "GetMaxWorkerMaxNum", "GetBaseCampLevel", "GetWorkerNum",
    "GetCurrentWorkerNum", "GetWorkerCount", "GetMaxWorkerNum", "GetBaseCampWorkerMaxNum",
}

local function dumpClass(className, onlyInteresting, maxObjs)
    local objs = FindAllOf(className) or {}
    w(string.format("===== %s (%d objects) =====", className, #objs))
    for i, o in ipairs(objs) do
        if i > (maxObjs or 3) then break end
        if o:IsValid() then
            w("-- " .. valueStr(o))
            for _, fn in ipairs(FUNCS) do
                local ok, r = pcall(function() return o[fn](o) end)
                if ok and r ~= nil then w(string.format("  %s() = %s", fn, valueStr(r))) end
            end
            dumpProps(o, o:GetClass(), "  ", onlyInteresting)
        end
    end
end

local function dumpTable()
    local dt = StaticFindObject("/Game/Pal/DataTable/BaseCamp/DT_BaseCampLevelData.DT_BaseCampLevelData")
    w("===== DT_BaseCampLevelData =====")
    if not dt or not dt:IsValid() then w("not found") return end
    local okRS, rs = pcall(function() return dt.RowStruct end)
    local n = 0
    pcall(function()
        dt:ForEachRow(function(rowName, row)
            n = n + 1
            if n <= 6 or n == 35 then
                local key = type(rowName) == "string" and rowName or valueStr(rowName)
                w("Row " .. key .. ":")
                if okRS and rs then dumpProps(row, rs, "    ", false, 1) end
            end
        end)
    end)
end

function M.dump(reason)
    buf = {}
    w("BaseWorkerMultiplier diag - " .. os.date("%Y-%m-%d %H:%M:%S") .. " (" .. tostring(reason) .. ")")
    local ok, err = pcall(function()
        dumpTable()
        dumpClass("PalBaseCampModel", false, 3)
        dumpClass("PalBaseCampWorkerDirector", true, 3)
        dumpClass("PalBaseCampManager", true, 2)
        dumpClass("PalGameWorldSettings", true, 3)
        dumpClass("PalOptionSubsystem", true, 2)
        dumpClass("PalGameStateInGame", true, 2)
        dumpClass("PalGameSetting", true, 2)
        dumpClass("PalBaseCampFunctionModuleAssign", false, 2)
    end)
    if not ok then w("DUMP ERROR: " .. tostring(err)) end
    local f = io.open(OUT, "wb")
    if f then
        f:write(table.concat(buf, "\n"), "\n")
        f:close()
        print("[BaseWorkerMultiplier] Diag written to " .. OUT .. "\n")
    else
        print("[BaseWorkerMultiplier] Could not write " .. OUT .. "\n")
    end
end

return M
