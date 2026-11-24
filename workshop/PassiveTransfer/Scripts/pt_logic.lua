-- PassiveTransfer logic.
-- A panel (default key F5) to move ONE passive skill from a Pal in your party
-- to another Pal in your party. The giver loses the passive. If the receiver
-- already has 4 passives you pick one of them: it goes to the giver (a swap).
-- Runs on the world host (passives live on the server).
--
-- Verified live 2026-11-18 (host): UPalIndividualCharacterParameter
--   :RemovePassiveSkill(FName) and :AddPassiveSkill(FName, FName("None"))
-- change SaveParameter.PassiveSkillList at once. The second argument of
-- AddPassiveSkill does NOT replace anything (tested), so a replace is done as
-- remove + add.
--
-- UI: built from Lua the same way the Mod Options framework does it - plain
-- UMG widgets plus the game's own Esc-menu button; clicks arrive through a
-- hook on that button's click event (registered by the loader).

local M = { version = "1.0.0" }
local TAG = "[PassiveTransfer] "
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

M.BTN_ASSET = "/Game/Pal/Blueprint/UI/UserInterface/ESCMenu/WBP_MenuESC_Button"
M.BTN_CLASS = M.BTN_ASSET .. ".WBP_MenuESC_Button_C"
M.CLICK_FN = M.BTN_CLASS .. ":BndEvt__WBP_MenuESC_Button_WBP_PalInvisibleButton_K2Node_ComponentBoundEvent_0_CommonButtonBaseClicked__DelegateSignature"
local MAX_PASSIVES = 4
local PARTY = 5

-- state of the panel
_G.PT = _G.PT or { ui = nil, giver = nil, taker = nil, pick = nil, swap = nil,
    note = nil, names = {}, obj = {}, gs = nil, gsAt = -100 }
local S = _G.PT
if not _G.PT_NOTIFY then
    -- new world: only flags here
    _G.PT_NOTIFY = pcall(NotifyOnNewObject, "/Script/Engine.GameStateBase", function()
        local s = _G.PT
        if s then s.gs = nil; s.gsAt = -100; s.ui = nil end
    end)
end

M.cfg = { enabled = true, lang = "auto" }
function M.setSettings(v)
    if type(v) ~= "table" then return end
    if v.enabled ~= nil then M.cfg.enabled = v.enabled end
    if type(v.language) == "string" then M.cfg.lang = v.language end
end

---------------------------------------------------------------------------
-- texts (English by default, Turkish as translation)
---------------------------------------------------------------------------
local TEXT = {
    en = {
        title = "Passive Transfer",
        giver = "1. Giver", pick = "2. Passive to move", taker = "3. Receiver", swap = "4. Swap with",
        go = "Transfer", close = "Close",
        s_giver = "Pick the Pal that gives a passive (it will lose it).",
        s_pick = "Pick the passive to move.",
        s_none = "%s has no passives.",
        s_taker = "Pick the Pal that receives \"%s\".",
        s_has = "%s already has \"%s\".",
        s_swap = "%s already has 4 passives. Pick the one that goes back to %s.",
        s_swapdup = "%s already has \"%s\", so it cannot take it back. Pick another one.",
        s_ready = "Ready: \"%s\" moves from %s to %s.",
        s_ready2 = "Ready: \"%s\" moves from %s to %s, and \"%s\" goes back to %s.",
        done = "Done: %s now has \"%s\".",
        done2 = "Done: %s now has \"%s\", %s got \"%s\".",
        failed = "It did not work, nothing was changed.",
        host = "Only the world host can use this.",
        party = "Put both Pals in your party first.",
    },
    tr = {
        title = "Pasif Aktarımı",
        giver = "1. Veren", pick = "2. Aktarılacak pasif", taker = "3. Alan", swap = "4. Şununla değiş",
        go = "Aktar", close = "Kapat",
        s_giver = "Pasif verecek Pal'ı seç (o pasifi kaybedecek).",
        s_pick = "Aktarılacak pasifi seç.",
        s_none = "%s üzerinde pasif yok.",
        s_taker = "\"%s\" pasifini alacak Pal'ı seç.",
        s_has = "%s üzerinde \"%s\" zaten var.",
        s_swap = "%s üzerinde zaten 4 pasif var. %s tarafına geri gidecek olanı seç.",
        s_swapdup = "%s üzerinde \"%s\" zaten var, onu geri alamaz. Başka birini seç.",
        s_ready = "Hazır: \"%s\", %s üzerinden %s üzerine geçecek.",
        s_ready2 = "Hazır: \"%s\", %s üzerinden %s üzerine geçecek; \"%s\" de %s üzerine dönecek.",
        done = "Tamam: %s artık \"%s\" pasifine sahip.",
        done2 = "Tamam: %s artık \"%s\" pasifine sahip, %s de \"%s\" aldı.",
        failed = "Olmadı, hiçbir şey değişmedi.",
        host = "Bunu yalnızca dünyanın host'u kullanabilir.",
        party = "Önce iki Pal'ı da takımına al.",
    },
}
local function lang()
    local l = M.cfg.lang
    if l == "en" or l == "tr" then return l end
    if S.autoLang == nil then
        S.autoLang = "en"
        pcall(function()
            local k = StaticFindObject("/Script/Engine.Default__KismetInternationalizationLibrary")
            if valid(k) then
                local c = str(k:GetCurrentLanguage()):lower()
                if c:sub(1, 2) == "tr" then S.autoLang = "tr" end
            end
        end)
    end
    return S.autoLang
end
local function T(key, ...)
    local t = TEXT[lang()] or TEXT.en
    local s = t[key] or TEXT.en[key] or key
    if select("#", ...) > 0 then
        local ok, r = pcall(string.format, s, ...)
        if ok then return r end
    end
    return s
end

---------------------------------------------------------------------------
-- cheap access (found once and kept; nothing here searches on a timer)
---------------------------------------------------------------------------
local function static(path)
    local o = S.obj[path]
    if valid(o) then return o end
    o = StaticFindObject(path)
    S.obj[path] = valid(o) and o or nil
    return S.obj[path]
end

local function gameState()
    if valid(S.gs) then return S.gs end
    local now = os.clock()
    if now - S.gsAt < 10 then return nil end
    S.gsAt = now
    local gs = FindFirstOf("PalGameStateInGame")
    S.gs = valid(gs) and gs or nil
    return S.gs
end

-- the local controller and whether this machine is the world host
local function localController()
    local gs = gameState()
    if not gs then return nil, false end
    local pc, host = nil, false
    local ok = pcall(function()
        local arr = gs.PlayerArray
        for i = 1, #arr do
            local ps = arr[i]
            if valid(ps) then
                local c = ps:GetPlayerController()
                if valid(c) and c:IsLocalController() then
                    pc = c
                    host = c:HasAuthority() == true
                    return
                end
            end
        end
    end)
    if not ok then S.gs = nil; S.gsAt = -100 end   -- look the game state up again
    return pc, host
end

local function passiveName(pc, id)
    local n = S.names[id]
    if n then return n end
    n = id
    pcall(function()
        local u = static("/Script/Pal.Default__PalUIUtility")
        if not u then return end
        local o = {}
        u:GetPassiveSkillName(pc, FName(id), o)
        local s = o.outName:ToString()
        if s and s ~= "" then n = s end
    end)
    S.names[id] = n
    return n
end

-- party of the local player: list[slot 1..5] = false | { prm, name, lv, ids = {..}, has = {id = true} }
local function readParty(pc)
    local list = {}
    for i = 1, PARTY do list[i] = false end
    local util = static("/Script/Pal.Default__PalUtility")
    if not util then return list end
    local holder = util:GetOtomoHolderComponent(pc)
    if not valid(holder) then return list end
    local cont = holder.CharacterContainer
    if not valid(cont) then return list end
    local n = cont:Num()
    for i = 0, math.min(n, PARTY) - 1 do
        pcall(function()
            local slot = cont:Get(i)
            if not valid(slot) then return end
            if slot:IsEmpty() then return end
            local h = slot:GetHandle()
            if not valid(h) then return end
            local prm = h:TryGetIndividualParameter()
            if not valid(prm) then return end
            local e = { prm = prm, name = "?", lv = 0, ids = {}, has = {} }
            pcall(function() local o = {}; prm:GetNickname(o); e.name = str(o.outName) end)
            pcall(function() e.lv = tonumber(prm:GetLevel()) or 0 end)
            prm.SaveParameter.PassiveSkillList:ForEach(function(_, v)
                local id = str(v:get())
                e.ids[#e.ids + 1] = id
                e.has[id] = true
            end)
            list[i + 1] = e
        end)
    end
    return list
end

---------------------------------------------------------------------------
-- what the current selection means: ok, message
---------------------------------------------------------------------------
local function plan(pc, party)
    local g = S.giver and party[S.giver] or nil
    if not g then return false, T("s_giver") end
    if #g.ids == 0 then return false, T("s_none", g.name) end
    if not (S.pick and g.has[S.pick]) then return false, T("s_pick") end
    local pickName = passiveName(pc, S.pick)
    local t = S.taker and S.taker ~= S.giver and party[S.taker] or nil
    if not t then return false, T("s_taker", pickName) end
    if t.has[S.pick] then return false, T("s_has", t.name, pickName) end
    if #t.ids < MAX_PASSIVES then return true, T("s_ready", pickName, g.name, t.name) end
    if not (S.swap and t.has[S.swap]) then return false, T("s_swap", t.name, g.name) end
    if g.has[S.swap] then return false, T("s_swapdup", g.name, passiveName(pc, S.swap)) end
    return true, T("s_ready2", pickName, g.name, t.name, passiveName(pc, S.swap), g.name)
end

local function hasPassive(prm, id)
    local found = false
    prm.SaveParameter.PassiveSkillList:ForEach(function(_, v)
        if str(v:get()) == id then found = true end
    end)
    return found
end

-- do it; every step is read back, and undone if a later step fails
local function transfer(pc, party)
    local ok = plan(pc, party)
    if not ok then return false end
    local g, t = party[S.giver], party[S.taker]
    local G, R = g.prm, t.prm
    if not (valid(G) and valid(R)) then return false end
    local pick, swap = S.pick, (#t.ids >= MAX_PASSIVES) and S.swap or nil
    local none = FName("None")
    log(string.format("transfer \"%s\" from %s to %s%s", pick, g.name, t.name, swap and (", swapping \"" .. swap .. "\"") or ""))
    if swap then
        R:RemovePassiveSkill(FName(swap))
        if hasPassive(R, swap) then log("step failed: receiver kept " .. swap) return false end
    end
    G:RemovePassiveSkill(FName(pick))
    if hasPassive(G, pick) then
        log("step failed: giver kept " .. pick)
        if swap then R:AddPassiveSkill(FName(swap), none) end
        return false
    end
    R:AddPassiveSkill(FName(pick), none)
    if not hasPassive(R, pick) then
        log("step failed: receiver did not get " .. pick .. " - undoing")
        G:AddPassiveSkill(FName(pick), none)
        if swap then R:AddPassiveSkill(FName(swap), none) end
        return false
    end
    if swap then
        G:AddPassiveSkill(FName(swap), none)
        if not hasPassive(G, swap) then log("warning: giver did not get " .. swap .. " back") end
    end
    local pickName = passiveName(pc, pick)
    if swap then S.note = T("done2", t.name, pickName, g.name, passiveName(pc, swap))
    else S.note = T("done", t.name, pickName) end
    log("transfer done")
    S.pick, S.swap = nil, nil
    return true
end

---------------------------------------------------------------------------
-- panel
---------------------------------------------------------------------------
local UI_VERSION = 4
local W, H = 1010, 600
local COLX = { 30, 270, 510, 750 }
local COLW, ROWH, ROWGAP, ROWY = 230, 46, 52, 120

local function construct(path, outer)
    local class = static(path)
    if not class or not valid(outer) then return nil end
    local ok, w = pcall(function() return StaticConstructObject(class, outer, 0, 0, 0, nil, false, false, nil) end)
    return ok and valid(w) and w or nil
end

local function place(canvas, widget, x, y, w, h, z)
    local slot = canvas:AddChildToCanvas(widget)
    if not valid(slot) then return false end
    slot:SetAnchors({ Minimum = { X = 0.5, Y = 0.5 }, Maximum = { X = 0.5, Y = 0.5 } })
    slot:SetAlignment({ X = 0.0, Y = 0.0 })
    slot:SetPosition({ X = x - W / 2, Y = y - H / 2 })
    slot:SetSize({ X = w, Y = h })
    slot:SetZOrder(z or 1)
    return true
end

local function setText(w, s)
    if valid(w) then pcall(function() w:SetText(FText(tostring(s or ""))) end) end
end
local function setButtonText(b, s)
    if valid(b) then pcall(function() b.Text_Main:SetText(FText(tostring(s or ""))) end) end
end
local function show(w, on)
    if valid(w) then pcall(function() w:SetVisibility(on and 0 or 1) end) end   -- 0 Visible, 1 Collapsed
end

local function build(pc)
    local lib = static("/Script/UMG.Default__WidgetBlueprintLibrary")
    if not lib then log("no widget library") return nil end
    if not static(M.BTN_CLASS) then
        pcall(function() LoadAsset(M.BTN_ASSET) end)
        if not static(M.BTN_CLASS) then log("game button class not found") return nil end
    end
    -- The panel is one of the game's own "activatable" widgets with its input
    -- mode set to Menu. While it is active the game's menu system shows the
    -- cursor and stops camera/character input by itself, and gives control
    -- back when it is deactivated (also on Esc). Setting the input mode by
    -- hand did not hold: the game's menu system took the mouse back.
    local native = true
    local hostClass = static("/Script/Pal.PalActivatableWidget")
    if not hostClass then log("the game's menu widget class was not found") return nil end
    local root = nil
    pcall(function() root = lib:Create(pc, hostClass, pc) end)
    if not valid(root) then log("could not create the panel widget") return nil end
    root.InputConfig = 3                 -- EPalWidgetInputMode::Menu
    root.bAutoActivate = false
    root.bIsBackHandler = true           -- Esc closes it
    -- the game shows / hides the panel itself when it is activated / deactivated
    root.bSetVisibilityOnActivated = true
    root.ActivatedVisibility = 0         -- Visible
    root.bSetVisibilityOnDeactivated = true
    root.DeactivatedVisibility = 1       -- Collapsed
    local tree = root.WidgetTree
    if not valid(tree) then log("panel has no widget tree") return nil end
    local canvas = construct("/Script/UMG.CanvasPanel", tree)
    if not canvas then log("could not create the canvas") return nil end
    tree.RootWidget = canvas

    local ui = { root = root, canvas = canvas, actions = {}, cols = { {}, {}, {}, {} }, heads = {}, native = native, v = UI_VERSION }

    local bg = construct("/Script/UMG.Image", tree)
    if bg then
        place(canvas, bg, 0, 0, W, H, 0)
        pcall(function() bg:SetColorAndOpacity({ R = 0.015, G = 0.03, B = 0.045, A = 0.94 }) end)
    end

    local function button(x, y, w, h, action)
        local b = nil
        pcall(function() b = lib:Create(pc, static(M.BTN_CLASS), pc) end)
        if not valid(b) then return nil end
        if not place(canvas, b, x, y, w, h, 2) then return nil end
        local addr = b:GetAddress()
        if addr then ui.actions[addr] = action end
        return b
    end

    ui.go = button(COLX[3], H - 76, COLW, 52, { kind = "go" })
    ui.close = button(COLX[4], H - 76, COLW, 52, { kind = "close" })
    if not (ui.go and ui.close) then log("could not create the buttons") return nil end
    local fontFrom = nil
    pcall(function() fontFrom = ui.close.Text_Main end)

    local function text(x, y, w, h, size, wrap)
        local t = construct("/Script/UMG.TextBlock", tree)
        if not t then return nil end
        if valid(fontFrom) then
            pcall(function() t:SetFont(fontFrom.Font) end)
        end
        pcall(function() local f = t.Font; f.Size = size; t:SetFont(f) end)
        pcall(function() t:SetAutoWrapText(wrap == true) end)
        place(canvas, t, x, y, w, h, 1)
        return t
    end

    ui.title = text(30, 22, 600, 44, 26, false)
    for c = 1, 4 do
        ui.heads[c] = text(COLX[c], 84, COLW, 30, 15, false)
        local rows = (c == 1 or c == 3) and PARTY or MAX_PASSIVES
        for r = 1, rows do
            ui.cols[c][r] = button(COLX[c], ROWY + (r - 1) * ROWGAP, COLW, ROWH, { kind = "cell", col = c, row = r })
        end
    end
    ui.status = text(30, ROWY + PARTY * ROWGAP + 16, W - 60, 90, 16, true)

    root:SetVisibility(1)                -- hidden until it is activated
    -- Far above the game's own screens: the game's menu system gives the
    -- mouse to the activated widget that is drawn LAST. At z-order 50 the
    -- game's HUD stayed in charge (camera kept turning, buttons got no mouse).
    root:AddToViewport(20000)
    return ui
end

local function mark(selected, s)
    return (selected and "> " or "") .. s
end

local function render(pc, isHost)
    local ui = S.ui
    if not (ui and valid(ui.root)) then return end
    local party = readParty(pc)
    S.party = party
    -- drop selections that no longer exist
    if S.giver and not party[S.giver] then S.giver, S.pick = nil, nil end
    if S.taker and (not party[S.taker] or S.taker == S.giver) then S.taker, S.swap = nil, nil end
    local g = S.giver and party[S.giver] or nil
    local t = S.taker and party[S.taker] or nil
    if S.pick and not (g and g.has[S.pick]) then S.pick = nil end
    if S.swap and not (t and t.has[S.swap]) then S.swap = nil end

    setText(ui.title, T("title"))
    setText(ui.heads[1], T("giver")); setText(ui.heads[2], T("pick"))
    setText(ui.heads[3], T("taker")); setText(ui.heads[4], T("swap"))
    setButtonText(ui.go, T("go")); setButtonText(ui.close, T("close"))

    local count = 0
    for r = 1, PARTY do
        local e = party[r]
        if e then count = count + 1 end
        local label = e and string.format("%s  Lv %d", e.name, e.lv) or ""
        show(ui.cols[1][r], e ~= false)
        setButtonText(ui.cols[1][r], mark(S.giver == r, label))
        show(ui.cols[3][r], e ~= false and S.giver ~= nil and r ~= S.giver)
        setButtonText(ui.cols[3][r], mark(S.taker == r, label))
    end
    for r = 1, MAX_PASSIVES do
        local id = g and g.ids[r] or nil
        show(ui.cols[2][r], id ~= nil)
        if id then setButtonText(ui.cols[2][r], mark(S.pick == id, passiveName(pc, id))) end
        local full = t ~= nil and #t.ids >= MAX_PASSIVES
        local sid = full and t.ids[r] or nil
        show(ui.cols[4][r], sid ~= nil)
        if sid then setButtonText(ui.cols[4][r], mark(S.swap == sid, passiveName(pc, sid))) end
    end
    show(ui.heads[4], t ~= nil and #t.ids >= MAX_PASSIVES)

    local ok, msg = false, ""
    if not isHost then msg = T("host")
    elseif count < 2 then msg = T("party")
    else ok, msg = plan(pc, party) end
    if S.note then msg = S.note .. "\n" .. msg end
    setText(ui.status, msg)
    show(ui.go, ok)   -- (a disabled game button is drawn as a plain white box)
    S.canGo = ok
end

-- is the panel on screen right now? (asked from the game itself, no own flag:
-- the game closes the panel on Esc without telling us)
function M.isOpen()
    local ui = S.ui
    if not (ui and valid(ui.root)) then return false end
    local active = false
    pcall(function() active = ui.root:IsActivated() end)
    return active == true
end

function M.close()
    local ui = S.ui
    if ui and valid(ui.root) then pcall(function() ui.root:DeactivateWidget() end) end
end

function M.open()
    if not M.cfg.enabled then return end
    local pc, isHost = localController()
    if not pc then return end                     -- title screen / still loading
    if S.ui and valid(S.ui.root) and S.ui.v ~= UI_VERSION then
        pcall(function() S.ui.root:RemoveFromParent() end)   -- panel from an older version of this file
        S.ui = nil
    end
    if not (S.ui and valid(S.ui.root)) then
        S.ui = build(pc)
        if not S.ui then return end
        log("panel built")
    end
    S.note = nil
    render(pc, isHost)
    pcall(function() S.ui.root:ActivateWidget() end)
end

function M.toggle()
    if M.isOpen() then M.close() else M.open() end
end

-- Called from the click hook of the game's button (game thread, the moment a
-- button is clicked). The hook fires for every Esc-menu style button in the
-- game; only our own buttons are in ui.actions.
-- NOTE: there is deliberately NO timer in this mod. A test version that
-- polled 10 times a second while the panel was open ended in a crash inside
-- a Lua -> game call (2026-11-18 10:23); everything now runs only in direct
-- answer to a key press or a click.
function M.onClick(ctx)
    local ui = S.ui
    if not ui then return end
    local w = ctx
    pcall(function() w = ctx:get() end)
    local addr = nil
    pcall(function() addr = w:GetAddress() end)
    local a = addr and ui.actions[addr] or nil
    if not a then return end
    M.act(a)
end

function M.act(a)
    if not M.isOpen() then return end
    if a.kind == "close" then M.close() return end
    local pc, isHost = localController()
    if not pc then return end
    local party = readParty(pc)
    if a.kind == "go" then
        if isHost and plan(pc, party) then
            local ok, done = pcall(transfer, pc, party)
            if not ok then log("transfer error: " .. tostring(done)) end
            if not (ok and done) then S.note = T("failed") end
        end
    elseif a.kind == "cell" then
        S.note = nil
        if a.col == 1 then
            if party[a.row] then
                S.giver = a.row; S.pick = nil
                if S.taker == a.row then S.taker, S.swap = nil, nil end
            end
        elseif a.col == 2 then
            local g = S.giver and party[S.giver] or nil
            if g and g.ids[a.row] then S.pick = g.ids[a.row] end
        elseif a.col == 3 then
            if party[a.row] and a.row ~= S.giver then S.taker = a.row; S.swap = nil end
        elseif a.col == 4 then
            local t = S.taker and party[S.taker] or nil
            if t and t.ids[a.row] then S.swap = t.ids[a.row] end
        end
    end
    render(pc, isHost)
end

return M
