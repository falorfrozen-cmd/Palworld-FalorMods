-- DevConsole (developer tool, local only)
-- Polls DevConsole/cmd.lua; when present, runs it inside the game (game thread),
-- captures print() output into DevConsole/out.txt, then deletes cmd.lua.
-- Disable this mod when development is finished.

local function modDir()
    local src = (debug.getinfo(1, "S").source or ""):gsub("^@", ""):gsub("\\", "/")
    return src:match("^(.*/)Scripts/[^/]+$") or ""
end
local DIR = modDir()
local CMD = DIR .. "cmd.lua"
local OUT = DIR .. "out.txt"
local busy = false

-- Persistent table for state shared between commands
DEV = DEV or {}

local function valueStr(v)
    local t = type(v)
    if t ~= "userdata" then return tostring(v) end
    local ok, s = pcall(function() return v:GetFullName() end)
    if ok and type(s) == "string" then return s end
    ok, s = pcall(function() return v:ToString() end)
    if ok and type(s) == "string" then return s end
    return tostring(v)
end

local function runCommand(code)
    local buf = {}
    local env = setmetatable({}, { __index = _G })
    env.print = function(...)
        local parts = {}
        for i = 1, select("#", ...) do parts[#parts + 1] = valueStr(select(i, ...)) end
        buf[#buf + 1] = table.concat(parts, "\t")
    end
    env.S = valueStr
    local fn, err = load(code, "cmd", "t", env)
    if not fn then
        buf[#buf + 1] = "COMPILE ERROR: " .. tostring(err)
    else
        local ok, rerr = xpcall(fn, debug.traceback)
        if not ok then buf[#buf + 1] = "RUNTIME ERROR: " .. tostring(rerr) end
    end
    buf[#buf + 1] = "-- done " .. os.date("%H:%M:%S")
    local f = io.open(OUT, "wb")
    if f then f:write(table.concat(buf, "\n"), "\n") f:close() end
end

LoopAsync(500, function()
    if busy then return false end
    local f = io.open(CMD, "rb")
    if not f then return false end
    local code = f:read("*a")
    f:close()
    os.remove(CMD)
    busy = true
    ExecuteInGameThread(function()
        runCommand(code)
        busy = false
    end)
    return false
end)

print("[DevConsole] Ready, watching " .. CMD .. "\n")
