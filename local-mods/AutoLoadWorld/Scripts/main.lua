-- AutoLoadWorld
-- Lets the game be started and the world entered WITHOUT anyone clicking.
-- One-shot: only acts if Scripts/autoload.txt exists when the game starts.
--   autoload.txt line 1: world save folder name (32 hex characters, e.g. 0123456789ABCDEF0123456789ABCDEF)
--   optional line 2:     listen=1 (host for friends, default) or listen=0
-- The file is deleted BEFORE loading, so a problem can never cause a loop.
-- Normal game starts (no autoload.txt) are not touched.
-- Uses the game's own path: GameInstance:SelectWorldSaveDirectoryName + StartGame.

local TAG = "[AutoLoadWorld] "
local function log(m) print(TAG .. tostring(m) .. "\n") end

local function valid(o)
    if not o then return false end
    local ok, v = pcall(function() return o:IsValid() end)
    return ok and v
end

local TITLE_WORLD = "/Game/Pal/Maps/Title/PL_Title.PL_Title"
local MAIN_WORLD  = "/Game/Pal/Maps/MainWorld_5/PL_MainWorld5.PL_MainWorld5"
local START_FN    = "/Game/Pal/Blueprint/System/BP_PalGameInstance.BP_PalGameInstance_C:StartGame"
local WAIT_ON_TITLE = 8   -- seconds after the title screen appears

local function scriptDir()
    local src = ""
    pcall(function() src = debug.getinfo(1, "S").source or "" end)
    src = src:gsub("^@", "")
    return src:match("^(.*)[/\\]")
end

local DIR = scriptDir()
local TRIGGER = DIR and (DIR .. "/autoload.txt") or nil

local function readTrigger()
    if not TRIGGER then return nil end
    local f = io.open(TRIGGER, "rb")
    if not f then return nil end
    local txt = f:read("a") or ""
    f:close()
    local world = txt:match("^%s*([%w_%-]+)")
    if not world then return nil end
    local listen = not txt:find("listen%s*=%s*0")
    -- crossplay=1 matches what the title screen uses when the user starts the
    -- world themselves (seen in the log: crossPlay=true)
    local crossplay = txt:find("crossplay%s*=%s*1") ~= nil
    return { world = world, listen = listen, crossplay = crossplay }
end

local job = readTrigger()
log("Loaded - " .. (job and ("auto-load requested for world " .. job.world .. " (listen=" .. tostring(job.listen) .. ")") or "no autoload.txt, normal start"))

-- Always log how the title screen itself calls StartGame (to learn the real
-- arguments the game uses).
local startHooked = false
local function hookStartGame()
    if startHooked then return end
    if not valid(StaticFindObject(START_FN)) then return end
    startHooked = true
    local ok, e = pcall(RegisterHook, START_FN, function(_, bNew, bListen, bCross)
        local a, b, c = "?", "?", "?"
        pcall(function() a = tostring(bNew:get()) end)
        pcall(function() b = tostring(bListen:get()) end)
        pcall(function() c = tostring(bCross:get()) end)
        log("StartGame called: newGame=" .. a .. " listenServer=" .. b .. " crossPlay=" .. c)
    end)
    if not ok then log("StartGame hook failed: " .. tostring(e)) end
end

local titleSince = nil
local finished = false

local function step()
    hookStartGame()
    if finished or not job then return end
    if valid(StaticFindObject(MAIN_WORLD)) then
        finished = true
        log("already in the world, nothing to do")
        return
    end
    if not valid(StaticFindObject(TITLE_WORLD)) then return end
    if not titleSince then
        titleSince = os.time()
        log("title screen detected, loading in " .. WAIT_ON_TITLE .. " s")
        return
    end
    if os.time() - titleSince < WAIT_ON_TITLE then return end

    finished = true
    os.remove(TRIGGER)   -- one-shot, removed BEFORE loading
    local gi = FindFirstOf("BP_PalGameInstance_C")
    if not valid(gi) then log("game instance not found - aborted") return end
    local okSel, sel = pcall(function() return gi:SelectWorldSaveDirectoryName(job.world) end)
    log("SelectWorldSaveDirectoryName(" .. job.world .. ") -> " .. tostring(okSel and sel or ("error " .. tostring(sel))))
    if not okSel or sel == false then log("world not selectable - aborted") return end
    local okStart, err = pcall(function() gi:StartGame(false, job.listen, job.crossplay) end)
    log("StartGame(continue, listen=" .. tostring(job.listen) .. ") -> " .. (okStart and "called" or ("error " .. tostring(err))))
end

LoopAsync(1000, function()
    ExecuteInGameThread(function()
        local ok, e = pcall(step)
        if not ok then log("error: " .. tostring(e)) end
    end)
    return startHooked and (finished or not job)
end)
