-- BigInventory logic (re-read live by the loader).
-- Runs on the world host only.
--
-- The player inventory has 42 slots built into the game. The ONLY thing that
-- makes it bigger is carrying the pouches (key items AdditionalInventory_001
-- .. _004: Small, Medium, Large, Giant). How many slots one pouch adds is the
-- item's FloatValue1, which the PalSchema part of this mod
-- (PalSchema/mods/BigInventory) sets to 100 each: 42 + 4 x 100 = 442.
-- Without the pouches that setting does nothing - so this part hands every
-- player the pouches they do not carry yet.

local M = { version = "1" }
local TAG = "[BigInventory] "
local function log(m) print(TAG .. tostring(m) .. "\n") end

local function valid(o)
    if not o then return false end
    local ok, v = pcall(function() return o:IsValid() end)
    return ok and v
end

local function str(x)
    if x == nil then return "nil" end
    if type(x) == "string" then return x end
    local ok, s = pcall(function() return x:ToString() end)
    return ok and s or tostring(x)
end

local POUCHES = { "AdditionalInventory_001", "AdditionalInventory_002", "AdditionalInventory_003", "AdditionalInventory_004" }
local POUCH_PREFIX = "AdditionalInventory_"

-- PERFORMANCE: FindFirstOf walks every object (~30 ms), so the game state is
-- found once and kept; a new world only raises a flag here.
_G.BI_GS = _G.BI_GS or { gs = nil, at = -100, reset = false }
if not _G.BI_GS_NOTIFY then
    _G.BI_GS_NOTIFY = pcall(NotifyOnNewObject, "/Script/Engine.GameStateBase", function()
        local c = _G.BI_GS
        if c then c.gs = nil; c.at = -100; c.reset = true end
    end)
end
local function gameState()
    local c = _G.BI_GS
    if valid(c.gs) then return c.gs end
    local now = os.clock()
    if now - c.at < 10 then return nil end   -- look again at most every 10 s
    c.at = now
    local gs = FindFirstOf("PalGameStateInGame")
    c.gs = valid(gs) and gs or nil
    return c.gs
end

-- every player state on this machine: { ps, name, isLocal, host, key }
function M.players()
    local out = {}
    local gs = gameState()
    if not gs then return out end
    local arr = gs.PlayerArray
    for i = 1, #arr do
        local ps = arr[i]
        pcall(function()
            if not valid(ps) then return end
            local pc = ps:GetPlayerController()
            if not valid(pc) then return end
            local isLocal = pc:IsLocalController()
            local host = false
            if isLocal then host = pc:HasAuthority() end
            local name = "?"
            pcall(function() name = str(ps:GetPlayerName()) end)
            out[#out + 1] = { ps = ps, name = name, isLocal = isLocal, host = host, key = ps:GetFullName() }
        end)
    end
    return out
end

function M.isHost(list)
    for _, p in ipairs(list or M.players()) do
        if p.isLocal then return p.host == true end
    end
    return false
end

-- inventory types: 0 = the normal bag, 2 = key items
local function container(inv, t)
    local out = {}
    local ok = pcall(function() inv:TryGetContainerFromInventoryType(t, out) end)
    local c = out.OutContainer
    if ok and valid(c) then return c end
    return nil
end
local function num(c)
    local n = -1
    pcall(function() n = c:Num() end)
    return tonumber(n) or -1
end

-- the pouches a player carries, as a set. nil = the key item bag could not be
-- read completely (still loading): never decide anything on a partial read.
local function carried(inv)
    local c = container(inv, 2)
    if not c then return nil end
    local n = num(c)
    if n <= 0 then return nil end
    local set, clean = {}, true
    for i = 0, n - 1 do
        local ok = pcall(function()
            local s = c:Get(i)
            if not valid(s) then return end
            local id = s.ItemId.StaticId:ToString()
            if id:sub(1, #POUCH_PREFIX) == POUCH_PREFIX then set[id] = true end
        end)
        if not ok then clean = false end
    end
    if not clean then return nil end
    return set
end

local function inventory(p)
    local inv
    pcall(function() inv = p.ps:GetInventoryData() end)
    return valid(inv) and inv or nil
end

-- slots of the normal bag and the carried pouches; nil when not readable yet
function M.read(p)
    local inv = inventory(p)
    if not inv then return nil end
    local common = container(inv, 0)
    local slots = common and num(common) or -1
    local have = carried(inv)
    if not have or slots < 1 then return nil end
    return inv, slots, have
end

M.cfg = { enabled = true, friends = true }
function M.setSettings(v)
    if type(v) ~= "table" then return end
    if v.enabled ~= nil then M.cfg.enabled = v.enabled end
    if v.include_friends ~= nil then M.cfg.friends = v.include_friends end
end

_G.BI_STATE = _G.BI_STATE or { p = {}, nextAt = 0 }
local S = _G.BI_STATE

local function check(p, st, now)
    local inv, slots, have = M.read(p)
    if not inv then st.at = now + 5 return end   -- inventory not loaded yet
    local miss = {}
    for _, id in ipairs(POUCHES) do
        if not have[id] then miss[#miss + 1] = id end
    end
    if #miss == 0 then
        st.done = true
        log(string.format("%s: carries all 4 pouches, inventory has %d slots", p.name, slots))
        return
    end
    if st.tries >= 3 then
        st.done = true
        log(string.format("%s: could not give %s (stopped after 3 tries, inventory has %d slots)", p.name, table.concat(miss, ", "), slots))
        return
    end
    st.tries = st.tries + 1
    st.at = now + 10   -- look again in 10 s to confirm
    for _, id in ipairs(miss) do
        log(string.format("%s: giving %s (inventory has %d slots)", p.name, id, slots))
        local res = "?"
        local ok, err = pcall(function() res = inv:AddItem_ServerInternal(FName(id), 1, false, 0.0, true) end)
        if not ok then log(string.format("%s: giving %s failed: %s", p.name, id, tostring(err)))
        elseif tonumber(res) ~= 0 then log(string.format("%s: the game answered %s for %s (0 = success)", p.name, tostring(res), id)) end
    end
end

-- called by the loader about once a second; real work every 5 s
function M.tick()
    local now = os.clock()
    if now < (S.nextAt or 0) then return end
    S.nextAt = now + 5
    if _G.BI_GS.reset then _G.BI_GS.reset = false; S.p = {} end
    local list = M.players()
    local seen = {}
    for _, p in ipairs(list) do seen[p.key] = true end
    for k in pairs(S.p) do if not seen[k] then S.p[k] = nil end end
    if not M.cfg.enabled then return end
    if not M.isHost(list) then return end
    for _, p in ipairs(list) do
        if p.isLocal or M.cfg.friends then
            local st = S.p[p.key]
            if not st then
                -- 10 s grace after a player appears, so their bags are loaded
                st = { at = now + 10, tries = 0 }
                S.p[p.key] = st
            end
            if not st.done and now >= st.at then check(p, st, now) end
        end
    end
end

-- test channel (bi_cmd.txt): status
function M.command(line)
    local sub = (line or ""):match("^%s*(%S+)") or ""
    if sub == "status" then
        local list = M.players()
        log(string.format("STATUS on=%s friends=%s host=%s players=%d", tostring(M.cfg.enabled), tostring(M.cfg.friends), tostring(M.isHost(list)), #list))
        for _, p in ipairs(list) do
            local inv, slots, have = M.read(p)
            if not inv then
                log("STATUS " .. p.name .. ": inventory not readable")
            else
                local ids = {}
                for _, id in ipairs(POUCHES) do if have[id] then ids[#ids + 1] = id:sub(#POUCH_PREFIX + 1) end end
                log(string.format("STATUS %s: %d slots, pouches [%s]", p.name, slots, table.concat(ids, " ")))
            end
        end
    else
        log("unknown command: " .. tostring(sub))
    end
end

return M
