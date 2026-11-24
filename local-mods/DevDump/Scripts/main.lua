-- DevDump: one-shot developer helper.
-- After the world is loaded, force-loads the UI/build-object blueprints we need
-- for the TeleportToPlayer and GlobalBaseStorage mods, then generates the
-- UE4SS C++ header dump (every class/function/property incl. these blueprints)
-- and an object dump. Runs once per game launch. F9 = run again.

local TAG = "[DevDump] "
local function log(m) print(TAG .. tostring(m) .. "\n") end

local ASSETS = {
    -- World map + player icon
    "/Game/Pal/Blueprint/UI/UserInterface/Map/WBP_Map_Base.WBP_Map_Base_C",
    "/Game/Pal/Blueprint/UI/UserInterface/Map/WBP_Map_Body.WBP_Map_Body_C",
    "/Game/Pal/Blueprint/UI/UserInterface/Map/WBP_Map_IconPlayer.WBP_Map_IconPlayer_C",
    "/Game/Pal/Blueprint/UI/UserInterface/Map/WBP_Map_IconCamp.WBP_Map_IconCamp_C",
    "/Game/Pal/Blueprint/UI/UserInterface/Map/WBP_Map_IconFTTower.WBP_Map_IconFTTower_C",
    "/Game/Pal/Blueprint/UI/UserInterface/Map/WBP_Map_Cursor.WBP_Map_Cursor_C",
    "/Game/Pal/Blueprint/UI/UserInterface/Map/WBP_MapPoint_Info.WBP_MapPoint_Info_C",
    "/Game/Pal/Blueprint/UI/WorldMap/IconWidgets/WBP_WorldMap_IconBase_NoDesign.WBP_WorldMap_IconBase_NoDesign_C",
    "/Game/Pal/Blueprint/UI/WorldMap/IconWidgets/WBP_WorldMap_IconBase_OnlyIcon.WBP_WorldMap_IconBase_OnlyIcon_C",
    -- Chests / item retrieval machine
    "/Game/Pal/Blueprint/UI/UserInterface/IngameMenu/Chest/WBP_IngameMenu_Chest.WBP_IngameMenu_Chest_C",
    "/Game/Pal/Blueprint/UI/UserInterface/IngameMenu/Chest/WBP_IngameMenu_ChestManage.WBP_IngameMenu_ChestManage_C",
    "/Game/Pal/Blueprint/UI/UserInterface/IngameMenu/Chest/WBP_IngameMenu_ChestManage_TakeOut.WBP_IngameMenu_ChestManage_TakeOut_C",
    "/Game/Pal/Blueprint/UI/UserInterface/IngameMenu/Chest/WBP_IngameMenu_ItemSearch.WBP_IngameMenu_ItemSearch_C",
    "/Game/Pal/Blueprint/UI/UserInterface/IngameMenu/Chest/WBP_IngameMenu_ItemSearchList.WBP_IngameMenu_ItemSearchList_C",
    "/Game/Pal/Blueprint/UI/UserInterface/IngameMenu/Chest/BP_HUDDispatchParameter_ItemSearch.BP_HUDDispatchParameter_ItemSearch_C",
    "/Game/Pal/Blueprint/UI/UserInterface/IngameMenu/Chest/WBP_Common_Inventory.WBP_Common_Inventory_C",
    "/Game/Pal/Blueprint/UI/MapObject/ItemChest/WBP_ItemChest.WBP_ItemChest_C",
    "/Game/Pal/Blueprint/MapObject/BuildObject/BP_BuildObject_BaseCampItemDispenser.BP_BuildObject_BaseCampItemDispenser_C",
    "/Game/Pal/Blueprint/MapObject/BuildObject/BP_BuildObject_ItemChest.BP_BuildObject_ItemChest_C",
}

local running = false

local function run(reason)
    if running then return end
    running = true
    ExecuteInGameThread(function()
        log("Start (" .. reason .. ")")
        local loaded = 0
        for _, path in ipairs(ASSETS) do
            local ok, obj = pcall(LoadAsset, path)
            if not ok or not obj then
                -- some UE4SS builds want the package path without the _C class
                local pkg = path:gsub("_C$", "")
                ok, obj = pcall(LoadAsset, pkg)
            end
            if ok and obj then loaded = loaded + 1 else log("Could not load " .. path) end
        end
        log(string.format("Loaded %d/%d assets. Generating C++ headers (game may freeze ~1 min)...", loaded, #ASSETS))
        local ok, err = pcall(GenerateSDK)
        log(ok and "C++ header dump done" or ("GenerateSDK failed: " .. tostring(err)))
        ok, err = pcall(DumpAllObjects)
        log(ok and "Object dump done" or ("DumpAllObjects failed: " .. tostring(err)))
        log("FINISHED")
        running = false
    end)
end

local done = false
RegisterHook("/Script/Engine.PlayerController:ServerAcknowledgePossession", function()
    if done then return end
    done = true
    ExecuteWithDelay(20000, function() run("world entered") end)
end)

pcall(function() RegisterKeyBind(Key.F9, function() run("F9") end) end)
log("Loaded - will dump 20s after entering a world (F9 to redo)")
