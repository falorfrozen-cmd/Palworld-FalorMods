-- UnlockAllBlueprints logic (re-read live by the loader).
--
-- Two kinds of "you need the blueprint item" checks exist in the game data:
--   1. furniture: a build object row has BlueprintItemID (15 rows: candlesticks,
--      lanterns, statues, flags, laboratory desk and chair ...)
--   2. gear: a craft recipe row has UnlockItemID (weapon, armor, hat and
--      accessory schematics, all rarities)
-- This mod blanks those two fields in MEMORY, so the build menu and the
-- workbenches offer everything without the item. Nothing is written to the
-- save and no item is added to the inventory; switching it off puts the
-- original values back.
--
-- Recipes whose schematic item has no in-game name are left alone: that is
-- content the game does not hand out.

local M = { version = "1" }
local TAG = "[UnlockAllBlueprints] "
local function log(m) print(TAG .. tostring(m) .. "\n") end

local RECIPE_TABLE = "/Game/Pal/DataTable/Item/DT_ItemRecipeDataTable.DT_ItemRecipeDataTable"
local UI_UTILITY = "/Script/Pal.Default__PalUIUtility"
local WORLD_GRACE = 20      -- seconds to leave a freshly loaded world alone
local RETRY = 10            -- seconds between looks while there is no world yet

local function valid(o)
    if not o then return false end
    local ok, v = pcall(function() return o:IsValid() end)
    return ok and v
end

local function rowName(rn)
    if type(rn) == "string" then return rn end
    local ok, s = pcall(function() return rn:ToString() end)
    return ok and s or nil
end

-- survives a live re-read of this file
_G.UB_STATE = _G.UB_STATE or {
    dirty = true,        -- something has to be (re)applied
    nextAt = 0,          -- do not look before this time
    seenAt = nil,        -- when the local player was first seen in this world
    recipeOrig = nil,    -- [recipe row] = original UnlockItemID
    recipeSkip = nil,    -- [recipe row] = true: schematic item has no name
}
local S = _G.UB_STATE

-- a new world: its data has to be looked at again (only flags are touched here)
if not _G.UB_NOTIFY then
    _G.UB_NOTIFY = pcall(NotifyOnNewObject, "/Script/Engine.GameStateBase", function()
        local s = _G.UB_STATE
        if s then s.dirty = true; s.seenAt = nil; s.nextAt = 0 end
    end)
end

M.cfg = { enabled = true, furniture = true, gear = true }
function M.setSettings(v)
    if type(v) ~= "table" then return end
    local c = M.cfg
    local e, f, g = c.enabled, c.furniture, c.gear
    if v.enabled ~= nil then c.enabled = v.enabled == true end
    if v.furniture ~= nil then c.furniture = v.furniture == true end
    if v.gear ~= nil then c.gear = v.gear == true end
    if e ~= c.enabled or f ~= c.furniture or g ~= c.gear then
        S.dirty = true
        S.nextAt = 0
    end
end

-- the player controller of this machine, or nil while no world is loaded
local function localController()
    local gs = FindFirstOf("PalGameStateInGame")
    if not valid(gs) then return nil end
    local found = nil
    local arr = gs.PlayerArray
    for i = 1, #arr do
        local ps = arr[i]
        pcall(function()
            if found or not valid(ps) then return end
            local pc = ps:GetPlayerController()
            if valid(pc) and pc:IsLocalController() then found = pc end
        end)
    end
    return found
end

-- furniture: returns ok, rows, changed
function M.applyFurniture(on)
    local dm = FindFirstOf("PalBuildObjectDataMap")
    if not valid(dm) then return false, 0, 0 end
    local item = {}     -- [build object id] = blueprint item id (this map is never changed)
    dm.BlueprintItemIdToBuildObjectIdMap:ForEach(function(k, v)
        pcall(function() item[v:get():ToString()] = k:get():ToString() end)
    end)
    local rows, changed = 0, 0
    dm.BuildObjectDataIdMap:ForEach(function(k, v)
        pcall(function()
            local need = item[k:get():ToString()]
            if not need then return end
            rows = rows + 1
            local row = v:get()
            local want = on and "None" or need
            if row.BlueprintItemID:ToString() ~= want then
                row.BlueprintItemID = FName(want)
                if row.BlueprintItemID:ToString() == want then changed = changed + 1 end
            end
        end)
    end)
    return true, rows, changed
end

-- gear: returns ok, rows, changed
function M.applyGear(pc, on)
    local dt = StaticFindObject(RECIPE_TABLE)
    if not valid(dt) then return false, 0, 0 end

    if not S.recipeOrig then
        local orig, n = {}, 0
        dt:ForEachRow(function(rn, row)
            pcall(function()
                local need = row.UnlockItemID:ToString()
                local name = rowName(rn)
                if name and need ~= "None" and need ~= "" then orig[name] = need; n = n + 1 end
            end)
        end)
        local skip, named, skipped = {}, 0, 0
        if n > 0 then
            local u = StaticFindObject(UI_UTILITY)
            if not valid(u) or not valid(pc) then return false, 0, 0 end
            for name, need in pairs(orig) do
                local text = ""
                pcall(function()
                    local o = {}
                    u:GetItemName(pc, FName(need), o)
                    text = o.outName:ToString()
                end)
                if text:find("^ITEM_NAME_") then skip[name] = true; skipped = skipped + 1
                elseif text ~= "" then named = named + 1 end
            end
            if named == 0 then return false, 0, 0 end   -- names are not readable yet: try again later
        end
        S.recipeOrig, S.recipeSkip = orig, skip
        log("schematic recipes found: " .. n .. " (" .. skipped .. " left alone: their schematic has no name in the game)")
    end

    local orig, skip = S.recipeOrig, S.recipeSkip
    local rows, changed = 0, 0
    dt:ForEachRow(function(rn, row)
        local name = rowName(rn)
        local need = name and orig[name]
        if need and not skip[name] then
            rows = rows + 1
            pcall(function()
                local want = on and "None" or need
                if row.UnlockItemID:ToString() ~= want then
                    row.UnlockItemID = FName(want)
                    if row.UnlockItemID:ToString() == want then changed = changed + 1 end
                end
            end)
        end
    end)
    return true, rows, changed
end

-- called by the loader every 2 s; does nothing unless something changed
function M.tick()
    if not S.dirty then return end
    local now = os.clock()
    if now < S.nextAt then return end
    local pc = localController()
    if not pc then
        S.seenAt = nil
        S.nextAt = now + RETRY
        return
    end
    if not S.seenAt then
        S.seenAt = now
        S.nextAt = now + WORLD_GRACE
        return
    end
    if now - S.seenAt < WORLD_GRACE then
        S.nextAt = S.seenAt + WORLD_GRACE
        return
    end

    local c = M.cfg
    local wantF = c.enabled and c.furniture
    local wantG = c.enabled and c.gear
    local okF, rowsF, chF = M.applyFurniture(wantF)
    local okG, rowsG, chG = M.applyGear(pc, wantG)
    if okF and (chF > 0 or S.saidF ~= wantF) then
        S.saidF = wantF
        log("furniture blueprints " .. (wantF and "NOT needed" or "needed as in the base game") .. ": " .. rowsF .. " build objects, " .. chF .. " changed")
    end
    if okG and (chG > 0 or S.saidG ~= wantG) then
        S.saidG = wantG
        log("weapon / armor schematics " .. (wantG and "NOT needed" or "needed as in the base game") .. ": " .. rowsG .. " recipes, " .. chG .. " changed")
    end
    if okF and okG then
        S.dirty = false
    else
        S.nextAt = now + RETRY
    end
end

return M
