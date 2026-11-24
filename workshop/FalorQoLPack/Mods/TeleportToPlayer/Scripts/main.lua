-- TeleportToPlayer
-- F7: teleport next to another player (2 players: always the other one;
--     more players: each press goes to the next one).
--
-- Player icons on the world map are not clickable in this game version (no
-- click event ever fires for them), so a hotkey is used instead.
-- Target position comes from APalPlayerState:GetPlayerInfoForMap() (the same
-- data the map uses, replicated to everyone, works at any distance).
-- The move itself is the game's own server-authoritative sync teleport:
-- PlayerState.SyncTeleportComp:SyncTeleport(...). Each player needs this mod.

local CFG = {
    Key = Key.F7,
    OffsetDistance = 200,   -- cm beside the target
    OffsetUp = 100,         -- cm above the target
    CooldownSeconds = 3,
}

local TAG = "[TeleportToPlayer] "
local function log(m) print(TAG .. tostring(m) .. "\n") end

local function valid(o)
    if not o then return false end
    local ok, v = pcall(function() return o:IsValid() end)
    return ok and v
end

local function localController()
    for _, pc in ipairs(FindAllOf("PalPlayerController") or {}) do
        local ok, isLocal = pcall(function() return pc:IsLocalController() end)
        if ok and isLocal and valid(pc) then return pc end
    end
    return nil
end

local lastTeleport = 0
local nextIndex = 1

local function teleportToNext()
    local now = os.clock()
    if now - lastTeleport < CFG.CooldownSeconds then return end

    local pc = localController()
    if not pc then log("no local player") return end
    local myState = pc.PlayerState
    if not valid(myState) then return end

    -- collect other players
    local targets = {}
    for _, ps in ipairs(FindAllOf("PalPlayerState") or {}) do
        if valid(ps) and ps:GetFullName() ~= myState:GetFullName() and not ps:GetFullName():find("Default__") then
            pcall(function()
                local info = ps:GetPlayerInfoForMap()
                local t = info.Transform.Translation
                if t.X ~= 0 or t.Y ~= 0 then
                    targets[#targets + 1] = { name = info.PlayerName:ToString(), x = t.X, y = t.Y, z = t.Z }
                end
            end)
        end
    end
    if #targets == 0 then log("no other player found") return end
    table.sort(targets, function(a, b) return a.name < b.name end)
    if nextIndex > #targets then nextIndex = 1 end
    local target = targets[nextIndex]
    nextIndex = nextIndex + 1

    local comp
    pcall(function() comp = myState.SyncTeleportComp end)
    if not valid(comp) then log("SyncTeleportComp not found") return end
    local okB, busy = pcall(function() return comp:IsTeleporting() end)
    if okB and busy then log("already teleporting") return end

    local dx, dy = 1, 0
    pcall(function()
        local me = pc.Pawn:K2_GetActorLocation()
        dx, dy = me.X - target.x, me.Y - target.y
        local len = math.sqrt(dx * dx + dy * dy)
        if len < 1 then dx, dy = 1, 0 else dx, dy = dx / len, dy / len end
    end)
    local dest = {
        X = target.x + dx * CFG.OffsetDistance,
        Y = target.y + dy * CFG.OffsetDistance,
        Z = target.z + CFG.OffsetUp,
    }
    local half = math.atan(-dy, -dx) / 2
    lastTeleport = now
    local ok, err = pcall(function()
        comp:SyncTeleport({
            Location = dest,
            Rotation = { X = 0, Y = 0, Z = math.sin(half), W = math.cos(half) },
            bIsFadeInSkip = false,
            bIsFadeOutSkip = false,
            bIsPlaySyncTeleportStartSE = false,
        })
    end)
    if ok then
        log(string.format("Teleporting to %s (%.0f, %.0f, %.0f)", target.name, dest.X, dest.Y, dest.Z))
    else
        log("SyncTeleport failed: " .. tostring(err))
    end
end

-- Settings page: Esc > Mod Options > Işınlanma (optional framework).
-- The key is read once at start (change applies after restarting the game).
local enabled = true
local keyName = "F7"
local options, generation = nil, 0
local function applySettings(v)
    if type(v) ~= "table" then return end
    if v.enabled ~= nil then enabled = v.enabled end
    if v.key then keyName = v.key end
end
local okReq, sdk = pcall(require, "PalModOptionsClient")
if okReq and sdk then
    options = sdk
    pcall(sdk.register_when_ready, {
        id = "BizimModlar.TeleportToPlayer",
        mod_folder = "TeleportToPlayer",
        title = "Teleport to Player",
        titles = { tr = "Işınlanma" },
        description = "Press the key to teleport next to another player. With more players, each press goes to the next one.",
        descriptions = { tr = "Tuşa basınca diğer oyuncunun yanına ışınlanırsın. Birden çok oyuncu varsa her basışta sıradakine." },
        version = 2,
        apply_mode = "event",
        options = {
            { key = "enabled", type = "boolean", label = "Enabled", labels = { tr = "Mod açık" }, default = true },
            { key = "key", type = "keybind", label = "Teleport key", labels = { tr = "Işınlanma tuşu" }, default = "F7",
              description = "Key changes apply after restarting the game.",
              descriptions = { tr = "Tuş değişikliği oyun yeniden açılınca geçerli olur." } },
        },
    }, function(settings, err)
        if settings ~= nil then
            applySettings(settings)
            generation = sdk.generation()
        else
            log("Mod Options unavailable, using defaults: " .. tostring(err))
        end
    end)
end

ExecuteWithDelay(5000, function()
    local k = Key[keyName] or CFG.Key
    RegisterKeyBind(k, function()
        if options and options.capture_active and options.capture_active() then return end
        ExecuteInGameThread(function()
            if options then
                pcall(function()
                    generation = select(1, options.sync(generation, function(values) applySettings(values) end))
                end)
            end
            if not enabled then return end
            local ok, err = pcall(teleportToNext)
            if not ok then log("error: " .. tostring(err)) end
        end)
    end)
    log("teleport key: " .. tostring(keyName))
end)

log("Loaded - press F7 to teleport to another player")
