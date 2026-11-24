-- GlobalBaseStorage
--
-- F6 (PullKey): in the build menu (B), select the structure you want, then press F6.
--   The mod looks up its material cost, checks what you are missing in your
--   inventory, and moves exactly the missing amount from whichever of your
--   bases has it into your inventory. Then build normally.
--   Uses the game's own server request that the Item Retrieval Machine uses
--   (UPalNetworkBaseCampComponent:RequestMoveItemToInventory_ToServer).
--
-- ShareStorageBetweenBases (OFF by default, experimental):
--   registers every base's chests in every base's storage module, so inside
--   ANY base, workbenches and building use the chests of ALL bases.
--   Off by default because removal of destroyed chests is not fully tested.

local CFG = {
    PullKey = Key.F6,
    AutoPullOnClick = true,             -- clicking a structure in the B menu pulls automatically
    PullCooldownSeconds = 1.5,
    ScanSeconds = 10,                   -- object scan interval (keep high, scanning costs FPS)
    ShareStorageBetweenBases = false,   -- experimental, see above
    Debug = true,
}

local TAG = "[GlobalBaseStorage] "
local function log(m) print(TAG .. tostring(m) .. "\n") end
local function dbg(m) if CFG.Debug then log(m) end end

local BUILD_DT = "/Game/Pal/DataTable/MapObject/Building/DT_BuildObjectDataTable.DT_BuildObjectDataTable"

local function valid(o)
    if not o then return false end
    local ok, v = pcall(function() return o:IsValid() end)
    return ok and v
end
local function gid(g)
    local ok, s = pcall(function() return string.format("%08X%08X%08X%08X", g.A, g.B, g.C, g.D) end)
    return ok and s or nil
end
local function guidTable(g)
    return { A = g.A, B = g.B, C = g.C, D = g.D }
end
local function nameStr(n)
    if n == nil then return nil end
    if type(n) == "string" then return n end
    local ok, s = pcall(function() return n:ToString() end)
    return ok and s or nil
end

---------------------------------------------------------------------------
-- cached objects (refreshed by scan, which is the only FindAllOf user)
---------------------------------------------------------------------------
local cache = {
    isServer = false,
    stackModules = {},   -- list of UPalBaseCampModuleItemStackInfo
    storages = {},       -- baseId -> UPalBaseCampModuleItemStorage
}

-- PERFORMANCE (measured 2026-11-18): FindAllOf / FindFirstOf walk every object
-- in the game: ~30 ms EACH (StaticFindObject ~15 ms). Reading the game state's
-- PlayerArray takes 0.015 ms. So nothing that runs on a timer may call
-- FindAllOf/FindFirstOf/StaticFindObject; the game state is found once and kept.
_G.GBS_GS = _G.GBS_GS or { gs = nil, at = -100 }
-- a new world's game state appeared: forget the old one
if not _G.GBS_GS_NOTIFY then
    _G.GBS_GS_NOTIFY = pcall(NotifyOnNewObject, "/Script/Engine.GameStateBase", function()
        local c = _G.GBS_GS
        if c then c.gs = nil; c.at = -100 end
    end)
end
local function gameState()
    local c = _G.GBS_GS
    if valid(c.gs) then return c.gs end
    local now = os.clock()
    if now - c.at < 10 then return nil end   -- look again at most every 10 s
    c.at = now
    local gs = FindFirstOf("PalGameStateInGame")
    c.gs = valid(gs) and gs or nil
    return c.gs
end

-- all player controllers on this machine (host: everyone; friend: only own)
local function controllers()
    local out = {}
    local gs = gameState()
    if not gs then return out end
    local arr = gs.PlayerArray
    for i = 1, #arr do
        local ps = arr[i]
        if valid(ps) then
            local pc = ps:GetPlayerController()
            if valid(pc) then out[#out + 1] = pc end
        end
    end
    return out
end

local function localController()
    for _, pc in ipairs(controllers()) do
        local ok, isLocal = pcall(function() return pc:IsLocalController() end)
        if ok and isLocal then return pc end
    end
    return nil
end

local lastScanAt = -100
local function scan()
    lastScanAt = os.clock()
    local pc = localController()
    cache.isServer = false
    if pc then
        local ok, auth = pcall(function() return pc:HasAuthority() end)
        cache.isServer = ok and auth or false
    end
    cache.stackModules = {}
    for _, m in ipairs(FindAllOf("PalBaseCampModuleItemStackInfo") or {}) do
        if valid(m) then cache.stackModules[#cache.stackModules + 1] = m end
    end
    cache.storages = {}
    if CFG.ShareStorageBetweenBases then
        for _, m in ipairs(FindAllOf("PalBaseCampModuleItemStorage") or {}) do
            local id = valid(m) and gid(m.OwnerBaseCampId)
            if id then cache.storages[id] = m end
        end
    end
end

-- The chest list is only needed at the moment materials are pulled, so it is
-- refreshed right then (if older than 10 s) instead of on a timer.
local function ensureScan()
    if #cache.stackModules == 0 or os.clock() - lastScanAt > 10 then scan() end
end

---------------------------------------------------------------------------
-- F6: pull missing materials for the selected build object
---------------------------------------------------------------------------
local lastPull = 0

local function selectedBuildObjectId(pc)
    -- 1) while placing (building mode)
    local id
    pcall(function()
        local out = {}
        pc.Pawn.BuilderComponent:GetSelectedBuildObjectId(out)
        id = nameStr(out.OutSelectedBuildObjectId)
    end)
    if id and id ~= "None" and id ~= "" then return id, "builder" end
    -- 2) last item selected in the build menu
    pcall(function()
        local hud = FindFirstOf("PalHUDService")
        id = nameStr(hud.TransientData.LastSelectedBuildObjectId)
    end)
    if id and id ~= "None" and id ~= "" then return id, "menu" end
    return nil
end

-- CRASH FIX (2026-11-15 11:09): UE4SS FindRow on a row name that does NOT
-- exist returns a row wrapping a NULL pointer (not nil); reading a field of it
-- crashed the game (access violation at 0x3C = Material1_Count offset), which
-- pcall cannot catch. So: ALWAYS confirm the row exists with the engine's own
-- DoesDataTableRowExist first, and never call FindRow if that can't be checked.
local DTLIB = "/Script/Engine.Default__DataTableFunctionLibrary"

local function rowExists(dt, buildId)
    local lib = StaticFindObject(DTLIB)
    if not valid(lib) then return false, "DataTableFunctionLibrary not found" end
    local ok, res = pcall(function() return lib:DoesDataTableRowExist(dt, FName(buildId)) end)
    if not ok then return false, "row check failed: " .. tostring(res) end
    return res == true, nil
end

local function findRowNames(substr)
    local dt = StaticFindObject(BUILD_DT)
    local lib = StaticFindObject(DTLIB)
    if not valid(dt) or not valid(lib) then return nil, "table/lib not found" end
    local out = {}
    lib:GetDataTableRowNames(dt, out)
    local found, total = {}, 0
    local arr = out.OutRowNames
    if arr == nil then return nil, "no row names returned" end
    local function add(n)
        total = total + 1
        local s = nameStr(n)
        if s and s:lower():find(substr:lower(), 1, true) then found[#found + 1] = s end
    end
    if type(arr) == "table" then
        for _, n in ipairs(arr) do add(n) end
    else
        arr:ForEach(function(_, e) add(e:get()) end)
    end
    return found, total
end

local function buildCost(buildId)
    local dt = StaticFindObject(BUILD_DT)
    if not valid(dt) then return nil, "build table not found" end
    local exists, why = rowExists(dt, buildId)
    if not exists then return nil, "no build table row '" .. tostring(buildId) .. "'" .. (why and (" (" .. why .. ")") or "") end
    local row
    local ok, err = pcall(function() row = dt:FindRow(buildId) end)
    if not ok or not row then return nil, "row not found: " .. buildId end
    local cost = {}
    for i = 1, 4 do
        pcall(function()
            local itemId = nameStr(row["Material" .. i .. "_Id"])
            local cnt = row["Material" .. i .. "_Count"]
            if itemId and itemId ~= "None" and type(cnt) == "number" and cnt > 0 then
                cost[#cost + 1] = { id = itemId, count = cnt }
            end
        end)
    end
    return cost
end

-- where is each item stored? { [staticId] = { {baseId=Guid, itemId=FPalItemId table, count=n}, ... } }
local function baseStock()
    local stock = {}
    for _, m in ipairs(cache.stackModules) do
        if valid(m) then
            pcall(function()
                local baseGuid = guidTable(m.OwnerBaseCampId)
                m.ItemStackRepInfoArray.Items:ForEach(function(_, e)
                    e:get().ItemStackInfos:ForEach(function(_, s)
                        local st = s:get()
                        local sid = nameStr(st.ItemId.StaticId)
                        if sid and st.StackCount > 0 then
                            stock[sid] = stock[sid] or {}
                            local d = st.ItemId.DynamicId
                            table.insert(stock[sid], {
                                baseId = baseGuid,
                                count = st.StackCount,
                                itemId = {
                                    StaticId = FName(sid),   -- copy, never keep a reference into the live array
                                    DynamicId = {
                                        CreatedWorldId = guidTable(d.CreatedWorldId),
                                        LocalIdInCreatedWorld = guidTable(d.LocalIdInCreatedWorld),
                                    },
                                },
                            })
                        end
                    end)
                end)
            end)
        end
    end
    return stock
end

-- forcedId / forcedSrc: given by the auto triggers (click / warning); nil for F6
local function pullForSelected(forcedId, forcedSrc)
    local now = os.clock()
    if now - lastPull < CFG.PullCooldownSeconds then return end
    lastPull = now

    local pc = localController()
    if not pc or not valid(pc.Pawn) then log("no local player") return end

    local buildId, src = forcedId, forcedSrc
    if not buildId then buildId, src = selectedBuildObjectId(pc) end
    if not buildId then log("No build object selected (open B, select a structure, then F6)") return end

    local cost, err = buildCost(buildId)
    if not cost then log(err) return end
    if #cost == 0 then log(buildId .. ": no materials needed") return end

    local util = StaticFindObject("/Script/Pal.Default__PalItemUtility")
    local uid = pc.PlayerState.PlayerUId
    local net
    pcall(function() net = pc.Transmitter.BaseCamp end)
    if not valid(util) or not valid(net) then log("game objects not ready") return end

    ensureScan()
    local stock = baseStock()

    local summary = {}
    local requested = {}   -- for the in-game confirmation
    for _, mat in ipairs(cost) do
        local have = 0
        pcall(function() have = util:CountLocalPlayerAndInsideBaseCampItemNum64(pc.Pawn, uid, FName(mat.id)) end)
        local missing = mat.count - have
        if missing > 0 then requested[#requested + 1] = { id = mat.id, before = have, need = mat.count } end
        if missing > 0 then
            local pulled = 0
            for _, src2 in ipairs(stock[mat.id] or {}) do
                if missing <= 0 then break end
                local take = math.min(missing, src2.count)
                local ok, e = pcall(function()
                    net:RequestMoveItemToInventory_ToServer(src2.baseId, src2.itemId, take)
                end)
                if ok then
                    missing = missing - take
                    pulled = pulled + take
                    src2.count = src2.count - take
                else
                    log("move request failed: " .. tostring(e))
                    break
                end
            end
            summary[#summary + 1] = string.format("%s +%d%s", mat.id, pulled, missing > 0 and (" (still missing " .. missing .. ")") or "")
        else
            summary[#summary + 1] = mat.id .. " ok"
        end
    end
    log(string.format("PULL %s [%s]: %s", buildId, src, table.concat(summary, ", ")))

    -- Confirm in game: recount the inventory 1.5 s later and show the REAL result in chat
    if #requested > 0 then
        ExecuteWithDelay(1500, function()
            ExecuteInGameThread(function()
                pcall(function()
                    local parts = {}
                    for _, r in ipairs(requested) do
                        local now2 = r.before
                        pcall(function() now2 = util:CountLocalPlayerAndInsideBaseCampItemNum64(pc.Pawn, uid, FName(r.id)) end)
                        parts[#parts + 1] = string.format(CFG.ChatLanguage == "tr" and "%s %d -> %d (gerekli %d)" or "%s %d -> %d (need %d)",
                            r.id, r.before, now2, r.need)
                    end
                    local text = (CFG.ChatLanguage == "tr" and "[Ortak Depo] " or "[Base Storage] ") .. table.concat(parts, ", ")
                    log("RESULT " .. text)
                    local pu = StaticFindObject("/Script/Pal.Default__PalUtility")
                    local g = pc.PlayerState.PlayerUId
                    pu:SendSystemToPlayerChat(pc, text, { { A = g.A, B = g.B, C = g.C, D = g.D } })
                end)
            end)
        end)
    end
end

---------------------------------------------------------------------------
-- Optional: share storage between bases (experimental, OFF by default)
---------------------------------------------------------------------------
local foreign = {}   -- baseId -> { [instId] = model }

local function syncStorages()
    if not CFG.ShareStorageBetweenBases or not cache.isServer then return end
    local mgr = FindFirstOf("PalMapObjectManager")
    if not valid(mgr) then return end
    local own = {}
    for baseId, st in pairs(cache.storages) do
        if valid(st) then
            own[baseId] = {}
            pcall(function()
                st.ContainerInfos:ForEach(function(_, e)
                    local info = e:get()
                    local id = gid(info.OwnerMapObjectConcreteModelInstanceId)
                    if id and not (foreign[baseId] and foreign[baseId][id]) then
                        local model = mgr:FindConcreteModel(info.OwnerMapObjectConcreteModelInstanceId)
                        if valid(model) then own[baseId][id] = model end
                    end
                end)
            end)
        end
    end
    for baseId, st in pairs(cache.storages) do
        if valid(st) and own[baseId] then
            foreign[baseId] = foreign[baseId] or {}
            local reg = foreign[baseId]
            for id, model in pairs(reg) do
                local still = false
                for other, list in pairs(own) do
                    if other ~= baseId and list[id] then still = true break end
                end
                if not still then
                    if valid(model) then pcall(function() st:OnNotAvailableConcreteModel_ServerInternal(model) end) end
                    reg[id] = nil
                end
            end
            for other, list in pairs(own) do
                if other ~= baseId then
                    for id, model in pairs(list) do
                        if not reg[id] and pcall(function() st:OnAvailableConcreteModel_ServerInternal(model) end) then
                            reg[id] = model
                        end
                    end
                end
            end
        end
    end
end

---------------------------------------------------------------------------
-- Everything below is called by main.lua (the loader). This file is
-- LIVE-RELOADED: main.lua re-reads it every 2 s and swaps it in when it
-- changed, so fixes here need NO game restart.
---------------------------------------------------------------------------
local function schedulePull(buildId, src)
    ExecuteInGameThread(function()
        local ok, err = pcall(pullForSelected, buildId, src)
        if not ok then log("auto pull error: " .. tostring(err)) end
    end)
end

local function iconBuildId(icon)
    local id
    pcall(function()
        local out = {}
        icon:GetBuildObjectId(out)
        id = nameStr(out.BuildObjectId)
    end)
    if id == "None" or id == "" then id = nil end
    return id
end

local ICON = "/Game/Pal/Blueprint/UI/UserInterface/IngameMenu/Construction/WBP_IngameMenu_Construction_Icon.WBP_IngameMenu_Construction_Icon_C:"
local ICON_EVT = "BndEvt__WBP_IngameMenu_Construction_Icon_WBP_PalInvisibleButton_K2Node_ComponentBoundEvent_%d_CommonButtonBaseClicked__DelegateSignature"

local M = { version = "9" }

-- Settings from Esc > Mod Options > Ortak Depo (main.lua passes them in,
-- also again after every live reload of this file).
function M.setSettings(v)
    if type(v) ~= "table" then return end
    if v.auto_pull ~= nil then CFG.AutoPullOnClick = v.auto_pull end
    if v.enabled ~= nil then CFG.Enabled = v.enabled end
    if v.chat_language then CFG.ChatLanguage = v.chat_language end
end
CFG.Enabled = true
CFG.ChatLanguage = "en"   -- English default; Turkish selectable on the settings page

-- hooks: UFunction path -> handler. main.lua registers each path once (as soon
-- as the function exists) and always calls the CURRENT handler from this table.
M.hooks = {}

-- Verified in game (2026-11-14 15:55): clicking a B-menu icon with NOT enough
-- materials fires the icon's button event 1 (hover) -> 0 (click) -> 2 (unhover).
-- The menu's OnSelectedBuildObject_Binded does NOT fire in that case.
do
    M.hooks[ICON .. string.format(ICON_EVT, 0)] = function(self)
        if not (CFG.Enabled and CFG.AutoPullOnClick) then return end
        local id
        pcall(function() id = iconBuildId(self:get()) end)
        log("click icon: " .. tostring(id))
        if id then schedulePull(id, "click") end
    end
end

---------------------------------------------------------------------------
-- Background test channel: write commands into gbs_cmd.txt (next to this
-- file); they run in game within 2 s and the result goes to UE4SS.log.
-- Only these fixed commands exist (no arbitrary code):
--   check <BuildObjectId>  -> read only: cost, what you have, what bases have
--   pull  <BuildObjectId>  -> same as clicking that structure in the B menu
---------------------------------------------------------------------------
M.baseDir = nil   -- set by main.lua

local function checkCost(buildId)
    local cost, err = buildCost(buildId)
    if not cost then log("CHECK " .. buildId .. ": " .. tostring(err)) return end
    local pc = localController()
    local util = StaticFindObject("/Script/Pal.Default__PalItemUtility")
    if not pc or not valid(pc.Pawn) or not valid(util) then log("CHECK: player not in world") return end
    local uid = pc.PlayerState.PlayerUId
    ensureScan()
    local stock = baseStock()
    local parts = {}
    for _, mat in ipairs(cost) do
        local have = -1
        pcall(function() have = util:CountLocalPlayerAndInsideBaseCampItemNum64(pc.Pawn, uid, FName(mat.id)) end)
        local inBases = 0
        for _, s in ipairs(stock[mat.id] or {}) do inBases = inBases + s.count end
        parts[#parts + 1] = string.format("%s need %d have %d inBases %d", mat.id, mat.count, have, inBases)
    end
    log(string.format("CHECK %s: %s (bases with stock info: %d)", buildId,
        #parts > 0 and table.concat(parts, ", ") or "no materials", #cache.stackModules))
end

-- read only: inventory slot counts + breeding farm settings (research)
local function objName(o)
    local n = "?"
    pcall(function() n = o:GetFName():ToString() end)
    return n
end
local function outerName(o)
    local n = "?"
    pcall(function() n = o:GetOuter():GetFullName() end)
    return n
end

local function probe()
    local pc = localController()
    if pc and valid(pc.PlayerState) then
        local inv
        pcall(function() inv = pc.PlayerState:GetInventoryData() end)
        if valid(inv) then
            for t = 0, 5 do
                local out = {}
                local okT = pcall(function() inv:TryGetContainerFromInventoryType(t, out) end)
                local c = out.OutContainer
                if okT and valid(c) then
                    local n = -1
                    pcall(function() n = c:Num() end)
                    local items = {}
                    if t == 2 then
                        for i = 0, n - 1 do
                            pcall(function()
                                local s = c:Get(i)
                                local id = s.ItemId.StaticId:ToString()
                                if id ~= "None" then items[#items + 1] = id .. "x" .. tostring(s.StackCount) end
                            end)
                        end
                    end
                    log(string.format("PROBE inventory type %d: %d slots %s", t, n, table.concat(items, " ")))
                end
            end
        else
            log("PROBE: no inventory data")
        end
    end
    for _, cls in ipairs({ "PalMapObjectBreedFarmParameterComponent", "PalMapObjectMultiHatchingEggWithBreedParameterComponent" }) do
        local all = FindAllOf(cls) or {}
        log("PROBE " .. cls .. ": " .. #all)
        for i, o in ipairs(all) do
            if i > 6 then break end
            local t = -1
            pcall(function() t = o.BreedRequiredRealTime end)
            log(string.format("  %s in %s time=%s", objName(o), outerName(o), tostring(t)))
        end
    end
    for _, cls in ipairs({ "PalMapObjectBreedFarmModel", "PalMapObjectMultiHatchingEggWithBreedModel" }) do
        local all = FindAllOf(cls) or {}
        log("PROBE " .. cls .. ": " .. #all)
        for i, o in ipairs(all) do
            if i > 6 then break end
            local t, p = -1, -1
            pcall(function() t = o.BreedRequiredRealTime; p = o.BreedProgressTime end)
            local can, eggs, item = "?", "?", "?"
            pcall(function() can = tostring(o:CanProceedBreeding()) end)
            pcall(function() eggs = tostring(#o.SpawnedEggInstanceIds) end)
            pcall(function() local out = {}; local r = o:CanConsumeBreedItem(out); item = tostring(r) end)
            log(string.format("  model required=%s progress=%s canProceed=%s eggsOnFarm=%s cakeCheck=%s",
                tostring(t), tostring(p), can, eggs, item))
        end
    end
end

-- test: set breeding time (seconds) on all breeding farms
local function setBreed(sec)
    local n = 0
    for _, cls in ipairs({ "PalMapObjectBreedFarmParameterComponent", "PalMapObjectMultiHatchingEggWithBreedParameterComponent",
                           "PalMapObjectBreedFarmModel", "PalMapObjectMultiHatchingEggWithBreedModel" }) do
        for _, o in ipairs(FindAllOf(cls) or {}) do
            if valid(o) then
                local ok = pcall(function() o.BreedRequiredRealTime = sec end)
                if ok then n = n + 1 end
            end
        end
    end
    log("BREED set " .. tostring(sec) .. " s on " .. n .. " objects")
end

-- test: give one pouch through the game's own debug add (host only)
local function addItem(id)
    local pc = localController()
    local inv
    pcall(function() inv = pc.PlayerState:GetInventoryData() end)
    if not valid(inv) then log("ADD: no inventory") return end
    local ok, e = pcall(function() inv:RequestAddItem_ForDebug(FName(id), 1, false) end)
    log("ADD " .. id .. " -> " .. (ok and "called" or tostring(e)))
end

-- read only: what the breeding farm accepts
local function arrStr(arr, fn)
    local t = {}
    local n = "?"
    local ok, e = pcall(function()
        n = arr:GetArrayNum()
        arr:ForEach(function(i, el) t[#t + 1] = fn(el) end)
    end)
    return "n=" .. tostring(n) .. "[" .. table.concat(t, ",") .. "]" .. (ok and "" or (" err " .. tostring(e)))
end

local ITEM_DT = "/Game/Pal/DataTable/Item/DT_ItemDataTable.DT_ItemDataTable"
local function breedProbe(extraId)
    local dt = StaticFindObject(ITEM_DT)
    if valid(dt) then
        for _, id in ipairs({ "Cake", "Berries", extraId }) do
            local ex = rowExists(dt, id)
            log("BPROBE item row " .. id .. " exists=" .. tostring(ex))
        end
    else
        log("BPROBE item table not found at " .. ITEM_DT)
    end
    for _, o in ipairs(FindAllOf("PalMapObjectBreedFarmParameterComponent") or {}) do
        log("BPROBE component " .. objName(o) .. " targets=" ..
            arrStr(o.TargetItemIds, function(e) return e:get().Key:ToString() end))
    end
    for _, m in ipairs(FindAllOf("PalMapObjectBreedFarmModel") or {}) do
        log("BPROBE model targets=" .. arrStr(m.TargetBreedItemIds, function(e) return e:get():ToString() end))
        pcall(function()
            local c = m:GetItemContainerModule():GetContainer()
            local p = c.Permission
            log(string.format("BPROBE farm box slots=%d permIds=%s permA=%s permB=%s", c:Num(),
                arrStr(p.PermissionItemStaticIds, function(e) return e:get():ToString() end),
                arrStr(p.PermissionTypeA, function(e) return tostring(e:get()) end),
                arrStr(p.PermissionTypeB, function(e) return tostring(e:get()) end)))
        end)
    end
end

-- test: replace one accepted breeding item by another IN PLACE (no array resize)
local function breedSwap(from, to)
    local n = 0
    local function swapArr(arr, isStruct)
        arr:ForEach(function(i, el)
            local cur = isStruct and el:get().Key:ToString() or el:get():ToString()
            if cur == from then
                if isStruct then el:get().Key = FName(to) else el:set(FName(to)) end
                n = n + 1
            end
        end)
    end
    for _, o in ipairs(FindAllOf("PalMapObjectBreedFarmParameterComponent") or {}) do
        pcall(swapArr, o.TargetItemIds, true)
    end
    for _, m in ipairs(FindAllOf("PalMapObjectBreedFarmModel") or {}) do
        pcall(swapArr, m.TargetBreedItemIds, false)
        pcall(function() swapArr(m:GetItemContainerModule():GetContainer().Permission.PermissionItemStaticIds, false) end)
    end
    log("BSWAP " .. from .. " -> " .. to .. " in " .. n .. " places")
end

local function runCommands()
    if not M.baseDir then return end
    local p = M.baseDir .. "/gbs_cmd.txt"
    local f = io.open(p, "rb")
    if not f then return end
    local txt = f:read("a") or ""
    f:close()
    if txt:match("^%s*$") then return end
    local w = io.open(p, "wb")   -- clear first so a command never runs twice
    if w then w:close() end
    for line in txt:gmatch("[^\r\n]+") do
        local cmd, arg = line:match("^%s*(%S+)%s*(%S*)")
        log("CMD " .. line)
        if cmd == "check" and arg ~= "" then
            local ok, e = pcall(checkCost, arg)
            if not ok then log("CHECK error: " .. tostring(e)) end
        elseif cmd == "pull" and arg ~= "" then
            lastPull = 0
            local ok, e = pcall(pullForSelected, arg, "test")
            if not ok then log("PULL error: " .. tostring(e)) end
        elseif cmd == "find" and arg ~= "" then
            local ok, found, total = pcall(findRowNames, arg)
            if ok and found then
                log(string.format("FIND '%s': %d of %d rows: %s", arg, #found, total or 0, table.concat(found, ", ")))
            else
                log("FIND error: " .. tostring(found) .. " " .. tostring(total))
            end
        elseif cmd == "breed" and tonumber(arg) then
            local ok, e = pcall(setBreed, tonumber(arg))
            if not ok then log("BREED error: " .. tostring(e)) end
        elseif cmd == "add" and arg ~= "" then
            local ok, e = pcall(addItem, arg)
            if not ok then log("ADD error: " .. tostring(e)) end
        elseif cmd == "stock" and arg ~= "" then
            ensureScan()
            local st = baseStock()
            local found = {}
            for id, list in pairs(st) do
                if id:lower():find(arg:lower(), 1, true) then
                    local n = 0
                    for _, s in ipairs(list) do n = n + s.count end
                    found[#found + 1] = id .. "=" .. n
                end
            end
            log("STOCK '" .. arg .. "': " .. (#found > 0 and table.concat(found, ", ") or "none in bases"))
        elseif cmd == "bswap" and arg ~= "" then
            local from, to = line:match("^%s*%S+%s+(%S+)%s+(%S+)")
            if from and to then
                local ok, e = pcall(breedSwap, from, to)
                if not ok then log("BSWAP error: " .. tostring(e)) end
            end
        elseif cmd == "names" and arg ~= "" then
            local all = FindAllOf(arg) or {}
            local t = {}
            for i, o in ipairs(all) do
                if i > 5 then break end
                local sn = "?"
                pcall(function() sn = tostring(o.SlotNum) end)
                t[#t + 1] = objName(o) .. "(slots " .. sn .. ")"
            end
            log("NAMES " .. arg .. " (" .. #all .. "): " .. table.concat(t, ", "))
        elseif cmd == "bprobe" then
            local ok, e = pcall(breedProbe, arg ~= "" and arg or "Berry")
            if not ok then log("BPROBE error: " .. tostring(e)) end
        elseif cmd == "probe" then
            local ok, e = pcall(probe)
            if not ok then log("PROBE error: " .. tostring(e)) end
        elseif cmd == "ahatch" and (arg == "on" or arg == "off") then
            -- AutoHatch (third-party) per-player switch, same call its own
            -- "!autohatch on/off" chat path makes after loading its json
            local ok, e = pcall(function()
                local actor
                for _, m in ipairs(FindAllOf("ModActor_C") or {}) do
                    if m:IsValid() and m:IsA("/Game/Mods/AutoHatch/ModActor.ModActor_C") then actor = m end
                end
                if not actor then log("AHATCH AutoHatch ModActor not found"); return end
                local pc = localController()
                local g = pc.PlayerState.PlayerUId
                local uid = string.format("%08X%08X%08X%08X", g.A & 0xffffffff, g.B & 0xffffffff, g.C & 0xffffffff, g.D & 0xffffffff)
                actor:LoadPlayerSettings(uid, arg == "on")
                log("AHATCH " .. objName(actor) .. " LoadPlayerSettings(" .. uid .. ", " .. arg .. ") ok")
            end)
            if not ok then log("AHATCH error: " .. tostring(e)) end
        elseif cmd == "swimpals" then
            -- read-only: which loaded pal species count as "swim pal" (salvage needs one)
            local ok, e = pcall(function()
                local yes, no = {}, {}
                for _, c in ipairs(FindAllOf("PalStaticCharacterParameterComponent") or {}) do
                    pcall(function()
                        local cls = c:GetOuter():GetClass():GetFName():ToString():gsub("^BP_", ""):gsub("_C$", "")
                        if c:IsSwimPal() then yes[cls] = true else no[cls] = true end
                    end)
                end
                local a, b = {}, {}
                for k in pairs(yes) do a[#a + 1] = k end
                for k in pairs(no) do b[#b + 1] = k end
                table.sort(a); table.sort(b)
                log("SWIMPALS yes: " .. table.concat(a, ", "))
                log("SWIMPALS no: " .. table.concat(b, ", "))
            end)
            if not ok then log("SWIMPALS error: " .. tostring(e)) end
        elseif cmd == "rides" then
            -- read-only: every player, the pal they ride, and both movement comps
            local ok, e = pcall(function()
                local pu = StaticFindObject("/Script/Pal.Default__PalUtility")
                for _, pc in ipairs(FindAllOf("PalPlayerController") or {}) do
                    pcall(function()
                        local who = pc:IsLocalController() and "HOST" or "FRIEND"
                        local riding, fly = false, false
                        pcall(function() riding = pc:IsRiding() end)
                        pcall(function() fly = pc:IsRidingFlyPal() end)
                        local function desc(ch)
                            local c = ch:GetPalCharacterMovementComponent()
                            local v = c.Velocity
                            return string.format("%s mode=%s fly=%.0f/%.0f maxFly=%.0f speed=%.0f trust=%s/%s",
                                objName(ch), tostring(c.MovementMode), c.FlySpeed_Default, c.FlySprintSpeed_Default, c.MaxFlySpeed,
                                math.sqrt(v.X * v.X + v.Y * v.Y + v.Z * v.Z),
                                tostring(c.bIgnoreClientMovementErrorChecksAndCorrection), tostring(c.bServerAcceptClientAuthoritativePosition))
                        end
                        log("RIDES " .. who .. " riding=" .. tostring(riding) .. " flyPal=" .. tostring(fly) .. " player: " .. desc(pc.Pawn))
                        if riding then
                            local pal = pc.Pawn
                            local swim = "?"
                            pcall(function() swim = tostring(pal.StaticCharacterParameterComponent:IsSwimPal()) end)
                            log("RIDES " .. who .. " ridden pal " .. objName(pal) .. " IsSwimPal=" .. swim)
                        end
                    end)
                end
            end)
            if not ok then log("RIDES error: " .. tostring(e)) end
        elseif cmd == "crafts" then
            -- read-only: active crafting jobs and work progress objects
            local ok, e = pcall(function()
                for _, m in ipairs(FindAllOf("PalMapObjectConvertItemModel") or {}) do
                    pcall(function()
                        local r = m.CurrentRecipeId:ToString()
                        if r ~= "None" then
                            local req, cur = "?", "?"
                            pcall(function()
                                local wp = m:GetWorkeeModule():GetWorkProgress()
                                req = string.format("%.0f", wp.RequiredWorkAmount)
                                cur = string.format("%.0f", wp.CurrentWorkAmount)
                            end)
                            log(string.format("CRAFT %s recipe=%s requested=%d remain=%d work %s/%s", objName(m), r, m.RequestedProductNum, m.RemainProductNum, cur, req))
                        end
                    end)
                end
                local n = 0
                for _, w in ipairs(FindAllOf("PalWorkProgress") or {}) do
                    pcall(function()
                        local req = w.RequiredWorkAmount
                        if req and req > 0 and w.CurrentWorkAmount < req then
                            n = n + 1
                            if n <= 15 then
                                log(string.format("WORK %s required=%.0f current=%.0f", objName(w), req, w.CurrentWorkAmount))
                            end
                        end
                    end)
                end
                log("CRAFTS done, unfinished work objects " .. n)
            end)
            if not ok then log("CRAFTS error: " .. tostring(e)) end
        elseif cmd == "pslots" then
            -- read-only: pickup containers' real contents
            local ok, e = pcall(function()
                local all = FindAllOf("PalMapObjectPickupItemOnLevelModel") or {}
                local agg = {}
                for _, m in ipairs(all) do
                    pcall(function()
                        local c = m:GetItemContainerModule():GetContainer()
                        local parts = {}
                        for i = 0, c:Num() - 1 do
                            local s = c:Get(i)
                            parts[#parts + 1] = s.ItemId.StaticId:ToString() .. "x" .. tostring(s.StackCount)
                        end
                        local mid = "?"
                        pcall(function() mid = m:TryGetMapObjectId():ToString() end)
                        local k = mid .. " " .. table.concat(parts, ",")
                        agg[k] = (agg[k] or 0) + 1
                    end)
                end
                log("PSLOTS models=" .. #all)
                for k, n in pairs(agg) do log("PSLOTS " .. n .. "x [" .. k .. "]") end
            end)
            if not ok then log("PSLOTS error: " .. tostring(e)) end
        elseif cmd == "rtypes" then
            -- read-only: recipes grouped by the product's item TypeB (60 Medicine, 61 Drug, 31 Bandage, 43 PalRevive)
            local ok, e = pcall(function()
                local items = StaticFindObject("/Game/Pal/DataTable/Item/DT_ItemDataTable.DT_ItemDataTable")
                local dt = StaticFindObject("/Game/Pal/DataTable/Item/DT_ItemRecipeDataTable.DT_ItemRecipeDataTable")
                local typeB = {}
                items:ForEachRow(function(rn, row)
                    local name = type(rn) == "string" and rn or rn:ToString()
                    typeB[name] = tonumber(row.TypeB)
                end)
                local want = { [60] = true, [61] = true, [31] = true, [43] = true }
                dt:ForEachRow(function(rn, row)
                    local pid = row.Product_Id:ToString()
                    local tb = typeB[pid]
                    if tb and want[tb] then
                        local name = type(rn) == "string" and rn or rn:ToString()
                        log(string.format("RTYPE %d %s -> %s x%d", tb, name, pid, row.Product_Count))
                    end
                end)
            end)
            if not ok then log("RTYPES error: " .. tostring(e)) end
        elseif cmd == "recipes" and arg ~= "" then
            -- read-only: recipe rows whose product id contains <arg> (lua pattern, lower case)
            local ok, e = pcall(function()
                local dt = StaticFindObject("/Game/Pal/DataTable/Item/DT_ItemRecipeDataTable.DT_ItemRecipeDataTable")
                if not (dt and dt:IsValid()) then log("RECIPES table not found"); return end
                local n, shown = 0, 0
                dt:ForEachRow(function(rowNameRaw, row)
                    n = n + 1
                    local rowName = type(rowNameRaw) == "string" and rowNameRaw or rowNameRaw:ToString()
                    local pid = row.Product_Id:ToString()
                    if pid:lower():find(arg) or rowName:lower():find(arg) then
                        shown = shown + 1
                        if shown <= 60 then
                            local mats = {}
                            for k = 1, 5 do
                                local id = row["Material" .. k .. "_Id"]:ToString()
                                if id ~= "None" then mats[#mats + 1] = id .. "x" .. row["Material" .. k .. "_Count"] end
                            end
                            log(string.format("RECIPE %s -> %s x%d [%s] work=%s", rowName, pid, row.Product_Count, table.concat(mats, ","), tostring(row.WorkAmount)))
                        end
                    end
                end)
                log("RECIPES '" .. arg .. "': " .. shown .. " of " .. n .. " rows")
            end)
            if not ok then log("RECIPES error: " .. tostring(e)) end
        elseif cmd == "nsmult" and tonumber(arg) then
            M.nsMult = math.max(1, math.min(20, math.floor(tonumber(arg))))
            log("NSMULT set to " .. M.nsMult)
            M.applyNightStone()
        elseif cmd == "pickups" then
            -- read-only: which pickup objects exist and what they drop
            local ok, e = pcall(function()
                local all = FindAllOf("PalMapObjectPickupItemParameterComponent") or {}
                local byClass = {}
                for _, c in ipairs(all) do
                    local items = {}
                    pcall(function()
                        c.DropItems:ForEach(function(i, el)
                            local d = el:get()
                            items[#items + 1] = d.StaticItemId.Key:ToString() .. "x" .. tostring(d.Num)
                        end)
                    end)
                    local cls = "?"
                    pcall(function() cls = c:GetOuter():GetClass():GetFName():ToString() end)
                    local key = cls .. " " .. objName(c) .. " [" .. table.concat(items, ",") .. "]"
                    byClass[key] = (byClass[key] or 0) + 1
                end
                log("PICKUPS components=" .. #all)
                for k, n in pairs(byClass) do log("PICKUPS " .. n .. "x " .. k) end
            end)
            if not ok then log("PICKUPS error: " .. tostring(e)) end
        elseif cmd == "save" then
            -- same save the game's own autosave does (world + players)
            local ok, e = pcall(function()
                local sm = FindFirstOf("PalSaveGameManager")
                if not (sm and sm:IsValid()) then log("SAVE no save manager"); return end
                sm:StartWorldDataAutoSave()
                log("SAVE started (StartWorldDataAutoSave)")
            end)
            if not ok then log("SAVE error: " .. tostring(e)) end
        elseif cmd == "fwatch" then
            M.fwatchRequest = tonumber(arg) or 60
            log("FWATCH started for " .. M.fwatchRequest .. " reports (one per 2 s)")
        elseif cmd == "tprobe" then
            -- read-only: current world time + which time-setting functions exist
            local ok, e = pcall(function()
                local tm = FindFirstOf("PalTimeManager")
                log("TPROBE timeManager valid=" .. tostring(tm and tm:IsValid()) .. " " .. (tm and objName(tm) or "nil"))
                if tm and tm:IsValid() then
                    local function g(fn) local r = "?"; pcall(function() r = tostring(tm[fn](tm)) end); return r end
                    log("TPROBE day=" .. g("GetCurrentPalWorldTime_Day") .. " hour=" .. g("GetCurrentPalWorldTime_Hour")
                        .. " min=" .. g("GetCurrentPalWorldTime_Minute") .. " hoursF=" .. g("GetCurrentPalWorldHoursFloat")
                        .. " type=" .. g("GetCurrentDayTimeType") .. " passRate=" .. g("GetDayTimePassRate")
                        .. " sleeping=" .. tostring(tm.SleepingPlayerNum))
                end
                -- NEVER call PalUtility:GetOptionWorldSettings from UE4SS Lua:
                -- returning that big struct crashed the game (2026-11-17 19:21,
                -- UE4SS.dll 0xc0000409).
                local gs = FindFirstOf("PalGameStateInGame")
                if gs and gs:IsValid() then
                    local a, b = "?", "?"
                    pcall(function() a = tostring(gs.WorldTime.GameDateTimeTicks); b = tostring(gs.WorldTime.RealDateTimeTicks) end)
                    log("TPROBE gamestate WorldTime gameTicks=" .. a .. " realTicks=" .. b .. " " .. objName(gs))
                end
                for _, fp in ipairs({
                    "/Script/Pal.PalTimeManager:SetGameTime_FixDay",
                    "/Script/Pal.PalPlayerController:Debug_SetPalWorldTime",
                    "/Script/Pal.PalCheatManager:SetPalWorldTime",
                    "/Script/Pal.PalCheatManager:SetGameTime_NextDay",
                    "/Script/Pal.PalCheatManager:SetGameTime_NextNight",
                }) do
                    local fo = StaticFindObject(fp)
                    log("TPROBE fn " .. fp .. " exists=" .. tostring(fo ~= nil and fo:IsValid()))
                end
                local pcs = FindAllOf("PalPlayerController") or {}
                log("TPROBE playerControllers=" .. #pcs)
                local cm = FindAllOf("PalCheatManager") or {}
                log("TPROBE cheatManagers=" .. #cm)
            end)
            if not ok then log("TPROBE error: " .. tostring(e)) end
        elseif cmd == "tech" then
            -- test channel for TechUnlockAll/Scripts/tu_logic.lua: "tech probe", "tech unlock host"
            local ok, e = pcall(function()
                local sub, a2 = line:match("^%s*%S+%s+(%S+)%s*(%S*)")
                local path = M.baseDir .. "/../../TechUnlockAll/Scripts/tu_logic.lua"
                local f = io.open(path, "rb")
                if not f then log("TECH tu_logic.lua not found: " .. path); return end
                local src = f:read("a"); f:close()
                local T = load(src, "@tu_logic.lua")()
                T.command(sub, a2 or "")
            end)
            if not ok then log("TECH error: " .. tostring(e)) end
        elseif cmd == "pktest" or cmd == "pkcount" then
            -- pktest: take the pickup nearest to the player, put its amount back to 1,
            -- count the item, send the game's own pickup request (PickupBoost's hook
            -- should set the multiplied amount). pkcount <item>: count again.
            local ok, e = pcall(function()
                local pc = localController()
                local util = StaticFindObject("/Script/Pal.Default__PalItemUtility")
                local function count(id)
                    local n = "?"
                    pcall(function() n = util:CountLocalPlayerAndInsideBaseCampItemNum64(pc.Pawn, pc.PlayerState.PlayerUId, FName(id)) end)
                    return tostring(n)
                end
                if cmd == "pkcount" then log("PKCOUNT " .. arg .. " = " .. count(arg)); return end
                local me = pc.Pawn:K2_GetActorLocation()
                local best, bestD, bestId
                local firstErr, nAll, nPick = nil, 0, 0
                for _, m in ipairs(FindAllOf("PalMapObjectPickupItemOnLevelModel") or {}) do
                    nAll = nAll + 1
                    local okM, eM = pcall(function()
                        if not m:TryGetMapObjectId():ToString():find("^PickupItem_") then return end
                        nPick = nPick + 1
                        local o = {}; m:GetMapObjectLocation(o)
                        local t = o.outVector or (o.X and o)
                        if not t then
                            local keys = {}
                            for k in pairs(o) do keys[#keys + 1] = tostring(k) end
                            error("out keys: " .. table.concat(keys, ","))
                        end
                        local d = math.sqrt((t.X - me.X) ^ 2 + (t.Y - me.Y) ^ 2 + (t.Z - me.Z) ^ 2)
                        if not bestD or d < bestD then
                            local slot = m:GetItemContainerModule():GetContainer():Get(0)
                            if slot and slot:IsValid() and slot.StackCount > 0 then
                                best, bestD, bestId = m, d, slot.ItemId.StaticId:ToString()
                            end
                        end
                    end)
                    if not okM and not firstErr then firstErr = tostring(eM) end
                end
                if not best then log("PKTEST no pickup found (models=" .. nAll .. ", pickups=" .. nPick .. ", first error=" .. tostring(firstErr) .. ")"); return end
                local slot = best:GetItemContainerModule():GetContainer():Get(0)
                local before = slot.StackCount
                slot.StackCount = 1
                log(string.format("PKTEST nearest pickup %s dist=%.0f amount %d -> 1, inventory %s = %s, requesting pickup", bestId, bestD, before, bestId, count(bestId)))
                best:RequestPickup(false)
            end)
            if not ok then log("PKTEST error: " .. tostring(e)) end
        elseif cmd == "ping" then
            log("PONG version " .. tostring(M.version))
        else
            log("unknown command: " .. line)
        end
    end
end

-- fwatch: read-only log of the local player's mount fly values while riding
local function flyReport()
    local pc = FindFirstOf("PalPlayerController")
    if not (pc and pc:IsValid()) then log("FWATCH no player controller"); return end
    local riding, fly = false, false
    pcall(function() riding = pc:IsRiding() end)
    pcall(function() fly = pc:IsRidingFlyPal() end)
    if not riding then log("FWATCH not riding"); return end
    local mount
    pcall(function() mount = pc:GetRiderCharacter() end)
    if not (mount and mount:IsValid()) then log("FWATCH no mount"); return end
    local c = mount.CharacterMovement
    if not (c and c:IsValid()) then log("FWATCH no movement comp"); return end
    local function f(k) local v = "?"; pcall(function() v = string.format("%.0f", c[k]) end); return v end
    local spd = "?"
    pcall(function() local v = c.Velocity; spd = string.format("%.0f", math.sqrt(v.X * v.X + v.Y * v.Y + v.Z * v.Z)) end)
    local mode, dash = "?", "?"
    pcall(function() mode = tostring(c.MovementMode) end)
    pcall(function() dash = tostring(c.IsFlyDashMode) end)
    log(string.format("FWATCH %s flyPal=%s mode=%s dash=%s speed=%s MaxFly=%s FlyDef=%s FlySprintDef=%s OvrFly=%s OvrFlySprint=%s RideSprintDef=%s",
        objName(mount), tostring(fly), mode, dash, spd, f("MaxFlySpeed"), f("FlySpeed_Default"), f("FlySprintSpeed_Default"),
        f("OverrideFlySpeed"), f("OverrideFlySprintSpeed"), f("RideSprintSpeed_Default")))
end

-- Nightstar Sand test: set DropItems Num on every NightStone pickup, and log
-- every change of the player's NightStone count (to see what a pickup gives).
M.nsMult = M.nsMult or nil
function M.applyNightStone()
    if not M.nsMult then return end
    local n = 0
    for _, c in ipairs(FindAllOf("PalMapObjectPickupItemParameterComponent") or {}) do
        pcall(function()
            c.DropItems:ForEach(function(i, el)
                local d = el:get()
                if d.StaticItemId.Key:ToString() == "NightStone" and d.Num ~= M.nsMult then
                    d.Num = M.nsMult
                    n = n + 1
                end
            end)
        end)
    end
    -- the pickup's real content: its model's item container (filled at spawn)
    local s, seen = 0, 0
    for _, m in ipairs(FindAllOf("PalMapObjectPickupItemOnLevelModel") or {}) do
        pcall(function()
            if m:GetVisualStaticItemId():ToString() ~= "NightStone" then return end
            seen = seen + 1
            local c = m:GetItemContainerModule():GetContainer()
            local slot = c:Get(0)
            if slot and slot:IsValid() and slot.ItemId.StaticId:ToString() == "NightStone" and slot.StackCount ~= M.nsMult then
                if s == 0 then log("NSMULT first slot before: " .. tostring(slot.StackCount)) end
                slot.StackCount = M.nsMult
                s = s + 1
            end
        end)
    end
    if n > 0 or s > 0 then log("NSMULT applied x" .. M.nsMult .. ": " .. n .. " components, " .. s .. " of " .. seen .. " pickup containers") end
end
local lastNS = nil
local function watchNightStone()
    if not M.nsMult then return end
    local pc = localController()
    local util = StaticFindObject("/Script/Pal.Default__PalItemUtility")
    if not (pc and valid(pc.Pawn) and valid(util)) then return end
    local n
    pcall(function() n = util:CountLocalPlayerAndInsideBaseCampItemNum64(pc.Pawn, pc.PlayerState.PlayerUId, FName("NightStone")) end)
    if type(n) ~= "number" then return end
    if lastNS and n ~= lastNS then log("NSWATCH NightStone " .. lastNS .. " -> " .. n .. " (" .. (n - lastNS > 0 and "+" or "") .. (n - lastNS) .. ")") end
    lastNS = n
end

-- Live fix test (2026-11-17): friend (client) cannot take off on a flying
-- mount. Suspect: SpeedBoost on the host sets
-- bIgnoreClientMovementErrorChecksAndCorrection / bServerAcceptClientAuthoritativePosition
-- on the friend's MOUNT, so the server never sends the "you are flying now"
-- correction. This turns both flags OFF on remote players' flying mounts
-- (SpeedBoost sets them only once per mount, so it does not fight back).
M.untrustFly = true
local untrusted = {}
local function untrustRemoteFlyMounts()
    if not M.untrustFly then return end
    local pcs = controllers()
    if #pcs < 2 then return end   -- alone in the world: nothing to do
    for _, pc in ipairs(pcs) do
        pcall(function()
            if pc:IsLocalController() then return end
            if not pc:IsRiding() then return end
            if not pc:IsRidingFlyPal() then return end
            -- verified 2026-11-17: while riding, the controller's Pawn IS the
            -- ridden pal (e.g. BP_Suzaku_BOSS_C); GetRiderCharacter() is the
            -- player body sitting on it.
            local mount = pc.Pawn
            local comp = mount:GetPalCharacterMovementComponent()
            if comp.bIgnoreClientMovementErrorChecksAndCorrection or comp.bServerAcceptClientAuthoritativePosition then
                comp.bIgnoreClientMovementErrorChecksAndCorrection = false
                comp.bServerAcceptClientAuthoritativePosition = false
                local key = comp:GetFullName()
                if not untrusted[key] then
                    untrusted[key] = true
                    log("FLYFIX friend's flying mount: server corrections back ON (" .. objName(mount) .. ")")
                end
            end
        end)
    end
end

-- auto watch: when the friend gets on a mount, log his + the pal's movement
-- state every 2 s for 40 s (read-only), so takeoff attempts show in the log.
local friendRideLeft, friendWasRiding = 0, false
local function friendRideWatch()
    local pu = StaticFindObject("/Script/Pal.Default__PalUtility")
    for _, pc in ipairs(FindAllOf("PalPlayerController") or {}) do
        pcall(function()
            if pc:IsLocalController() then return end
            local riding = pc:IsRiding()
            if riding and not friendWasRiding then friendRideLeft = 20; log("RIDEWATCH friend mounted") end
            friendWasRiding = riding
            if friendRideLeft <= 0 then return end
            friendRideLeft = friendRideLeft - 1
            local function desc(ch)
                local c = ch:GetPalCharacterMovementComponent()
                local v = c.Velocity
                return string.format("%s mode=%s custom=%s z=%.0f vz=%.0f speed=%.0f fly=%.0f maxFly=%.0f trust=%s/%s",
                    objName(ch), tostring(c.MovementMode), tostring(c.CustomMovementMode), ch:K2_GetActorLocation().Z, v.Z,
                    math.sqrt(v.X * v.X + v.Y * v.Y + v.Z * v.Z), c.FlySpeed_Default, c.MaxFlySpeed,
                    tostring(c.bIgnoreClientMovementErrorChecksAndCorrection), tostring(c.bServerAcceptClientAuthoritativePosition))
            end
            local line = "RIDEWATCH riding=" .. tostring(riding) .. " flyPal=" .. tostring(pc:IsRidingFlyPal()) .. " | player " .. desc(pc.Pawn)
            if riding then
                local pal = pu:GetRidePal(pc.Pawn)
                if pal and pal:IsValid() then line = line .. " | pal " .. desc(pal) end
            end
            log(line)
        end)
    end
end

-- AnySwimPal (2026-11-17): salvage (floating wrecks) only accepts a ridden pal
-- whose StaticCharacterParameterComponent:IsSwimPal() is true (only Surfent
-- etc.). While a player rides ANY pal that is swimming (MovementMode 4), its
-- MovementType is set to Swim (3); it goes back to the original value as soon
-- as the pal leaves the water or nobody rides it.
M.anySwimPal = (M.anySwimPal == nil) and true or M.anySwimPal
_G.GBS_SWIM = _G.GBS_SWIM or {}   -- comp full name -> { comp, orig }
local SW = _G.GBS_SWIM
local function anySwimPalTick()
    -- the real mod AnySwimPal does this from the next game start on
    local modLoaded = false
    pcall(function() modLoaded = ModRef:GetSharedVariable("AnySwimPal.Loaded") == true end)
    local active = {}
    if M.anySwimPal and not modLoaded and CFG.Enabled ~= false then
        for _, pc in ipairs(FindAllOf("PalPlayerController") or {}) do
            pcall(function()
                if not pc:IsRiding() then return end
                local pal = pc.Pawn
                local mc = pal:GetPalCharacterMovementComponent()
                local inWater = (tonumber(mc.MovementMode) == 4)
                pcall(function() inWater = inWater or mc:IsSwimming() end)
                if not inWater then return end
                local sc = pal.StaticCharacterParameterComponent
                local key = sc:GetFullName()
                active[key] = true
                local mt = tonumber(sc.MovementType)
                if mt == 3 or mt == 4 then
                    if not SW[key] then return end   -- a real swim pal, leave it
                else
                    if not SW[key] then SW[key] = { comp = sc, orig = mt } end
                    sc.MovementType = 3
                    log("SWIMPAL " .. objName(pal) .. " counts as swim pal now (MovementType " .. mt .. " -> 3), IsSwimPal=" .. tostring(sc:IsSwimPal()))
                end
            end)
        end
    end
    for key, e in pairs(SW) do
        if not active[key] then
            pcall(function()
                if e.comp:IsValid() then e.comp.MovementType = e.orig end
            end)
            log("SWIMPAL restored MovementType " .. tostring(e.orig))
            SW[key] = nil
        end
    end
end

-- interim: unlock all technology (also for a friend who joins) until the
-- real mod TechUnlockAll loads at the next game start
local function techUnlockTick()
    local modLoaded = false
    pcall(function() modLoaded = ModRef:GetSharedVariable("TechUnlockAll.Loaded") == true end)
    if modLoaded then return end
    local path = M.baseDir .. "/../../TechUnlockAll/Scripts/tu_logic.lua"
    local f = io.open(path, "rb")
    if not f then return end
    local src = f:read("a"); f:close()
    local T = load(src, "@tu_logic.lua")()
    T.tick()
    if not _G.GBS_TECH_LOGGED then
        _G.GBS_TECH_LOGGED = true
        log("TECH interim auto-unlock running (every 10 s, until TechUnlockAll loads)")
    end
end

local fwatchLeft = 0
local ticks = 0
function M.tick()
    local okC, eC = pcall(runCommands)
    if not okC then log("command error: " .. tostring(eC)) end
    if M.fwatchRequest then fwatchLeft = M.fwatchRequest; M.fwatchRequest = nil end
    -- 2026-11-18: the interim ticks (friend ride log, any-swim-pal, tech
    -- unlock) are gone from here - the real mods do that now. What is left
    -- on the timer costs well under 1 ms.
    if M.nsMult then
        pcall(watchNightStone)
        if ticks % 5 == 0 then pcall(M.applyNightStone) end
    end
    pcall(untrustRemoteFlyMounts)
    if fwatchLeft > 0 then
        fwatchLeft = fwatchLeft - 1
        local okF, eF = pcall(flyReport)
        if not okF then log("FWATCH error: " .. tostring(eF)) end
    end
    ticks = ticks + 1
    if CFG.ShareStorageBetweenBases then
        if os.clock() - lastScanAt > CFG.ScanSeconds then pcall(scan) end
        local ok, err = pcall(syncStorages)
        if not ok then log("share error: " .. tostring(err)) end
    end
end

function M.onPullKey()
    if not CFG.Enabled then return end
    pullForSelected()
end

-- timing: how long does tick take? (summary line every 30 s)
do
    _G.GBS_PERF = _G.GBS_PERF or { n = 0, total = 0, max = 0, since = os.clock() }
    local P = _G.GBS_PERF
    local inner = M.tick
    M.tick = function(...)
        local t0 = os.clock()
        local r = inner(...)
        local ms = (os.clock() - t0) * 1000
        P.n = P.n + 1; P.total = P.total + ms
        if ms > P.max then P.max = ms end
        local now = os.clock()
        if now - P.since >= 30 then
            -- watchdog: only speak up when a tick was slow enough to feel
            if P.max >= 10 then print(string.format("[GlobalBaseStorage] SLOW %d ticks in %.0f s, avg %.2f ms, max %.0f ms\n", P.n, now - P.since, P.total / P.n, P.max)) end
            P.n, P.total, P.max, P.since = 0, 0, 0, now
        end
        return r
    end
end

return M
