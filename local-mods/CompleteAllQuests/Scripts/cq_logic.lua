-- CompleteAllQuests logic (re-read live by the loader).
--
-- Finishes quests through the game's own path, one objective per second:
--   1. the current objective of a quest is marked "can be completed"
--      (UPalQuestBlock:SetCanComplete)
--   2. the quest is progressed with the same request an NPC talk sends
--      (UPalNetworkQuestComponent:RequestProgressQuest_ToServer)
--   3. only if an objective does not move after a few tries (it checks for a
--      real item in the bag), the quest is finished with the game's own
--      UPalQuestManager:ForceCompleteQuest_ServerInternal, which gives the
--      same rewards
-- So every objective's own code runs, the next quest of a chain is handed out
-- by the game, and the game itself gives the rewards (exp, items, skins).
-- Measured 2026-11-22 on a copy of a real save: main chain up to the World
-- Tree and 44 side quests, rewards arrived for each one.
--
-- Left alone on purpose:
--   * the never-ending requests (Pal Critic, Wise / Veteran Hunter, Pal
--     Ecological Researcher, Arrogant Foodie): they are not finished by the
--     quest system; forcing them gives NOTHING and ends the request
--   * repeatable replays (the table marks them "reorderable")
--   * hidden trigger quests
--   * main quests the game has not handed out (the old tutorial rows are
--     still in the table)
-- Only the world host (or a single-player game) can do this.

local M = { version = "3" }
local TAG = "[CompleteAllQuests] "
local function log(m) print(TAG .. tostring(m) .. "\n") end

local WORLD_GRACE = 60      -- seconds after a world starts loading before anything is touched
local IDLE_RECHECK = 20     -- seconds between looks when nothing is left to do
local ORDER_WAIT = 12       -- seconds to wait for a newly accepted quest to appear
local FORCE_AFTER = 6       -- steps on the same objective before the game's own "complete this quest" call is used
local MAX_TRIES = 15        -- steps on the same objective before giving up on a quest
local TYPE_MAIN, TYPE_SUB = 1, 2

local function valid(o)
    if not o then return false end
    local ok, v = pcall(function() return o:IsValid() end)
    return ok and v
end

local function nameOf(x)
    if type(x) == "string" then return x end
    local ok, s = pcall(function() return x:ToString() end)
    return ok and s or nil
end

-- survives a live re-read of this file
_G.CQ_STATE = _G.CQ_STATE or { reset = true, gs = nil, gsAt = -100 }
local S = _G.CQ_STATE

-- a new world: start over (only flags are touched here)
if not _G.CQ_NOTIFY then
    _G.CQ_NOTIFY = pcall(NotifyOnNewObject, "/Script/Engine.GameStateBase", function()
        local s = _G.CQ_STATE
        if s then s.reset = true; s.gs = nil; s.gsAt = -100; s.worldAt = os.clock() end
    end)
end

M.cfg = { enabled = true, main = false, side = false }
function M.setSettings(v)
    if type(v) ~= "table" then return end
    local c = M.cfg
    local e, m, s = c.enabled, c.main, c.side
    if v.enabled ~= nil then c.enabled = v.enabled == true end
    if v.main ~= nil then c.main = v.main == true end
    if v.side ~= nil then c.side = v.side == true end
    if e ~= c.enabled or m ~= c.main or s ~= c.side then
        S.nextAt = 0
        S.rowPos = 1
        S.idle = false
        local key = tostring(c.enabled) .. tostring(c.main) .. tostring(c.side)
        if S.saidCfg ~= key then
            S.saidCfg = key
            log("settings now: on=" .. tostring(c.enabled) .. ", main quests=" .. tostring(c.main) .. ", side quests=" .. tostring(c.side))
        end
    end
end

-- the game state is searched for at most every 10 s and then kept
local function gameState()
    if valid(S.gs) then return S.gs end
    local now = os.clock()
    if now - (S.gsAt or -100) < 10 then return nil end
    S.gsAt = now
    local gs = FindFirstOf("PalGameStateInGame")
    S.gs = valid(gs) and gs or nil
    return S.gs
end

-- player state + controller of this machine
local function localPlayer()
    local gs = gameState()
    if not gs then return nil end
    local ps, pc = nil, nil
    local arr = gs.PlayerArray
    for i = 1, #arr do
        local st = arr[i]
        pcall(function()
            if ps or not valid(st) then return end
            local c = st:GetPlayerController()
            if valid(c) and c:IsLocalController() then ps, pc = st, c end
        end)
    end
    return ps, pc
end

-- never-ending requests, by id (also recognised by class, see isRequestQuest)
local function isRequestId(id)
    return id:find("^Sub_PalDisplay_") ~= nil or id:find("Reward$") ~= nil
end

-- their quest classes all draw their own reward display
local function isRequestQuest(q)
    local found = false
    pcall(function()
        local c = q:GetClass()
        for i = 1, 5 do
            if not valid(c) or not c:GetFullName():find("^BlueprintGeneratedClass") then break end
            c:ForEachFunction(function(fn)
                if fn:GetFName():ToString() == "GetCustomDisplayRewardData" then found = true end
            end)
            if found then break end
            c = c:GetSuperStruct()
        end
    end)
    return found
end

-- quest table: order, type and "reorderable" of every row (read once per world)
local function loadRows(qm)
    local dt = qm.QuestDataSet
    if not valid(dt) then return nil end
    local rows = { list = {}, type = {}, replay = {} }
    dt:ForEachRow(function(rn, row)
        local id = nameOf(rn)
        if not id then return end
        local t, re = 0, false
        pcall(function() t = tonumber(row.QuestType) or 0 end)
        pcall(function() re = row.bReorderable == true end)
        rows.list[#rows.list + 1] = id
        rows.type[id] = t
        rows.replay[id] = re
    end)
    if #rows.list == 0 then return nil end
    return rows
end

local function wanted(id)
    local c, rows = M.cfg, S.rows
    local t = rows.type[id]
    if t == TYPE_MAIN then
        if not c.main then return false end
    elseif t == TYPE_SUB then
        if not c.side then return false end
    else
        return false
    end
    if rows.replay[id] or isRequestId(id) or S.skip[id] then return false end
    return true
end

local function findOrdered(qm, id)
    local arr = qm.QuestReplicationData.OrderedQuestArray
    for i = 1, #arr do
        local q = arr[i]
        if valid(q) and nameOf(q.QuestId) == id then return q end
    end
    return nil
end

local function questTitle(q)
    local title = ""
    pcall(function()
        local o = {}
        q:GetQuestNameText(o)
        title = o.OutText:ToString()
    end)
    return title
end

local function kind(id)
    return S.rows.type[id] == TYPE_MAIN and "main" or "side"
end

-- the quest we were working on is gone from the list: finished?
local function closeCurrent(qm)
    local cur = S.cur
    if not cur then return end
    S.cur = nil
    local done = false
    pcall(function() done = qm:IsQuestCompleted(FName(cur.id)) end)
    if done then
        local k = kind(cur.id)
        S.count[k] = (S.count[k] or 0) + 1
        log("finished " .. k .. " quest: " .. (cur.title ~= "" and cur.title or cur.id) .. " (" .. cur.id .. ")")
    else
        local ordered = false
        pcall(function() ordered = qm:IsQuestOrdered(FName(cur.id)) end)
        if not ordered then log("quest left the list without being finished: " .. cur.id) end
    end
end

-- one step on one quest
local function step(qm, pc, q, id)
    local idx = q.QuestBlockIndex
    local cur = S.cur
    if not cur or cur.id ~= id then
        closeCurrent(qm)
        cur = { id = id, idx = idx, tries = 0, title = questTitle(q) }
        S.cur = cur
    elseif cur.idx ~= idx then
        cur.idx, cur.tries = idx, 0
    end

    -- collect the objectives first: the list changes as soon as one completes
    local blocks = {}
    local arr = q.NowQuestBlocks
    for j = 1, #arr do
        local b = arr[j]
        if valid(b) then blocks[#blocks + 1] = b end
    end
    if #blocks == 0 then return end           -- the next objective is still loading

    cur.tries = cur.tries + 1
    if cur.tries > MAX_TRIES then
        S.skip[id] = true
        S.cur = nil
        log("could not move this quest on, leaving it as it is: " .. (cur.title ~= "" and cur.title or id) .. " (" .. id .. ", objective " .. tostring(idx) .. ")")
        return
    end
    if cur.tries > FORCE_AFTER and not cur.forced then
        -- some objectives really look for an item in the bag ("find the lost
        -- item") and take their mark back. The game's own call for finishing a
        -- whole quest gives the same rewards (measured: items arrived).
        cur.forced = true
        qm:ForceCompleteQuest_ServerInternal(FName(id))
        return
    end

    for _, b in ipairs(blocks) do
        local now = findOrdered(qm, id)
        if not now or now.QuestBlockIndex ~= idx then return end   -- moved on by itself
        if valid(b) then b:SetCanComplete(true) end
    end

    local now = findOrdered(qm, id)
    if not now or now.QuestBlockIndex ~= idx then return end
    local tr = pc.Transmitter
    if not valid(tr) then return end
    local net = tr.Quest
    if not valid(net) then return end
    net:RequestProgressQuest_ToServer(FName(id))
end

local function summary()
    local c = S.count
    local parts = {}
    if (c.main or 0) > 0 then parts[#parts + 1] = c.main .. " main" end
    if (c.side or 0) > 0 then parts[#parts + 1] = c.side .. " side" end
    if #parts > 0 and S.saidCount ~= (c.main or 0) + (c.side or 0) then
        S.saidCount = (c.main or 0) + (c.side or 0)
        log("nothing left to do - finished in this session: " .. table.concat(parts, ", ") .. " quests")
    end
end

-- called by the loader every second; returns at once unless there is work
function M.tick()
    local c = M.cfg
    if not c.enabled or not (c.main or c.side) then return end
    local now = os.clock()
    if S.reset then
        S.reset = false
        S.rows, S.cur, S.pending = nil, nil, nil
        S.skip, S.count, S.checked, S.saidCount = {}, {}, {}, nil
        S.rowPos, S.nextAt, S.idle, S.saidGuest = 1, 0, false, false
    end
    if now < (S.nextAt or 0) then return end

    local ps, pc = localPlayer()
    if not ps then
        S.nextAt = now + 5
        return
    end
    -- the grace period counts from the moment the world started loading, so a
    -- switch turned on later in the session works at once
    S.worldAt = S.worldAt or now
    if now - S.worldAt < WORLD_GRACE then
        S.nextAt = S.worldAt + WORLD_GRACE
        return
    end
    if not pc:HasAuthority() then
        if not S.saidGuest then
            S.saidGuest = true
            log("this is somebody else's world: quests can only be finished by the world host")
        end
        S.nextAt = now + 60
        return
    end

    local qm = ps.QuestManager
    if not valid(qm) then S.nextAt = now + 5 return end
    if not S.rows then
        S.rows = loadRows(qm)
        if not S.rows then S.nextAt = now + 5 return end
    end

    -- 1. a quest that is already in the list
    local arr = qm.QuestReplicationData.OrderedQuestArray
    for i = 1, #arr do
        local q = arr[i]
        if valid(q) then
            local id = nameOf(q.QuestId)
            if id and wanted(id) then
                if S.checked[id] == nil then
                    S.checked[id] = isRequestQuest(q)
                    if S.checked[id] then S.skip[id] = true end
                end
                if not S.skip[id] then
                    S.pending, S.idle = nil, false
                    step(qm, pc, q, id)
                    return
                end
            end
        end
    end
    closeCurrent(qm)

    -- 2. a side quest that was accepted a moment ago and is still loading
    local pend = S.pending
    if pend then
        if findOrdered(qm, pend.id) then
            S.pending = nil                      -- it is in the list, but one we leave alone
            return
        end
        if now - pend.at < ORDER_WAIT then return end
        S.skip[pend.id] = true
        S.pending = nil
        log("the game did not hand out this quest, leaving it: " .. pend.id)
    end

    -- 3. accept the next side quest nobody has taken yet
    if c.side then
        local rows = S.rows
        while S.rowPos <= #rows.list do
            local id = rows.list[S.rowPos]
            S.rowPos = S.rowPos + 1
            if rows.type[id] == TYPE_SUB and wanted(id) then
                local done, ordered = true, true
                pcall(function() done = qm:IsQuestCompleted(FName(id)) end)
                pcall(function() ordered = qm:IsQuestOrdered(FName(id)) end)
                if not done and not ordered then
                    qm:OrderQuest_ServerInternal(FName(id), 0)
                    S.pending = { id = id, at = now }
                    return
                end
            end
        end
    end

    -- nothing to do: look again later (the game may hand out a new quest)
    if not S.idle then
        S.idle = true
        summary()
    end
    S.nextAt = now + IDLE_RECHECK
end

S.skip = S.skip or {}
S.count = S.count or {}
S.checked = S.checked or {}
S.rowPos = S.rowPos or 1

return M
