-- ============================================================
-- HQ Officer Voting Panel — with time slot selection
-- ============================================================

local PANEL_W = 520
local PANEL_H = 480

local C = {
    bg        = Color(34,  28,  18),
    paper     = Color(210, 195, 158),
    paperDark = Color(185, 168, 128),
    ink       = Color(38,  30,  18),
    inkLight  = Color(80,  65,  40),
    red       = Color(160, 40,  30),
    accent    = Color(120, 95,  55),
    yes       = Color(55,  100, 50),
    no        = Color(140, 40,  30),
    white     = Color(240, 230, 210),
    armed     = Color(180, 130, 40),
    slotSel   = Color(70,  100, 60),
    slotHov   = Color(90,  75,  45),
}

surface.CreateFont("ixHQ_Title",   { font = "Trajan Pro",  size = 22, weight = 700 })
surface.CreateFont("ixHQ_Sub",     { font = "Trajan Pro",  size = 15, weight = 400 })
surface.CreateFont("ixHQ_Mono",    { font = "Courier New", size = 13, weight = 400 })
surface.CreateFont("ixHQ_MonoBig", { font = "Courier New", size = 16, weight = 700 })
surface.CreateFont("ixHQ_Stamp",   { font = "Arial Black", size = 28, weight = 900 })
surface.CreateFont("ixHQ_Small",   { font = "Courier New", size = 11, weight = 400 })

-- ============================================================
-- Local state
-- ============================================================

local hqState = {
    team           = nil,
    active         = false,
    armed          = false,
    passedAt       = nil,
    isFallback     = false,
    voters         = {},
    slot           = nil,
    slotLabel      = nil,
    voteDeadline   = nil,
    cooldown       = 0,
    slots          = {},
    assaultYearDay = nil,
    dateLabel      = nil,
    shortDateLabel = nil,
}

local hqPanel        = nil
local selectedSlot   = nil   -- locally chosen slot before sending vote start

-- ============================================================
-- Helpers
-- ============================================================

local function DrawPaper(x, y, w, h)
    draw.RoundedBox(4, x, y, w, h, C.paper)
    surface.SetDrawColor(C.paperDark.r, C.paperDark.g, C.paperDark.b, 120)
    surface.DrawRect(x, y, w, 2)
    surface.DrawRect(x, y, 2, h)
    surface.DrawRect(x + w - 2, y, 2, h)
    surface.DrawRect(x, y + h - 2, w, 2)
end

local function FormatCountdown(deadline)
    if not deadline then return "--:--" end
    local remaining = math.max(0, deadline - CurTime())
    return string.format("%d:%02d", math.floor(remaining / 60), math.floor(remaining % 60))
end

local function FormatCooldown(secs)
    if secs <= 0 then return nil end
    local m = math.floor(secs / 60)
    local s = math.floor(secs % 60)
    return string.format("%d:%02d", m, s)
end

local function VoteSymbol(v)
    if v == true  then return "[AYE]" end
    if v == false then return "[NAY]" end
    return "[ - ]"
end

local function VoteColor(v)
    if v == true  then return C.yes end
    if v == false then return C.no  end
    return C.inkLight
end

-- ============================================================
-- Panel builder
-- ============================================================

local function BuildHQPanel(data)
    if IsValid(hqPanel) then hqPanel:Remove() end

    -- Preserve locally selected slot if the vote just opened.
    if data.active and not selectedSlot then
        selectedSlot = data.slot
    elseif not data.active then
        selectedSlot = nil
    end

    local teamName     = data.team == "axis" and "GERMAN FORCES" or "ALLIED FORCES"
    local localSteamID = LocalPlayer():SteamID()
    local cooldownStr  = FormatCooldown(data.cooldown or 0)

    hqPanel = vgui.Create("DFrame")
    hqPanel:SetSize(PANEL_W, PANEL_H)
    hqPanel:Center()
    hqPanel:SetDraggable(true)
    hqPanel:SetDeleteOnClose(true)
    hqPanel:SetTitle("")
    hqPanel:MakePopup()

    hqPanel.Paint = function(self, w, h)
        draw.RoundedBox(6, 0, 0, w, h, C.bg)
        DrawPaper(4, 4, w - 8, h - 8)
        surface.SetDrawColor(C.ink.r, C.ink.g, C.ink.b, 220)
        surface.DrawRect(4, 4, w - 8, 52)
        -- corner ticks
        local tk = 12
        surface.SetDrawColor(C.accent.r, C.accent.g, C.accent.b, 200)
        surface.DrawRect(10, 60, tk, 2)  surface.DrawRect(10, 60, 2, tk)
        surface.DrawRect(w-10-tk, 60, tk, 2) surface.DrawRect(w-12, 60, 2, tk)
        surface.DrawRect(10, h-62, tk, 2)   surface.DrawRect(10, h-62, 2, tk)
        surface.DrawRect(w-10-tk, h-62, tk, 2) surface.DrawRect(w-12, h-62, 2, tk)
        surface.SetDrawColor(C.accent.r, C.accent.g, C.accent.b, 180)
        surface.DrawRect(4, 56, w - 8, 1)
    end

    -- Title
    local title = vgui.Create("DLabel", hqPanel)
    title:SetPos(0, 12)
    title:SetSize(PANEL_W, 18)
    title:SetText("HEADQUARTERS — " .. teamName)
    title:SetFont("ixHQ_Title")
    title:SetContentAlignment(5)
    title:SetTextColor(C.white)

    -- Close button
    local closeBtn = vgui.Create("DButton", hqPanel)
    closeBtn:SetPos(PANEL_W - 30, 8)
    closeBtn:SetSize(22, 22)
    closeBtn:SetText("✕")
    closeBtn:SetFont("ixHQ_Sub")
    closeBtn:SetTextColor(C.white)
    closeBtn.Paint = function(self, w, h)
        if self:IsHovered() then
            surface.SetDrawColor(180, 60, 40, 200)
            surface.DrawRect(0, 0, w, h)
        end
    end
    closeBtn.DoClick = function() hqPanel:Close() end

    local curY = 64

    -- Fallback warning
    if data.isFallback then
        local warn = vgui.Create("DLabel", hqPanel)
        warn:SetPos(20, curY)
        warn:SetSize(PANEL_W - 40, 16)
        warn:SetText("WARNING: NO OFFICERS PRESENT — SENIOR RANK AUTHORITY")
        warn:SetFont("ixHQ_Mono")
        warn:SetTextColor(C.red)
        warn:SetContentAlignment(5)
        curY = curY + 20
    end

    -- Cooldown notice
    if cooldownStr then
        local cdLabel = vgui.Create("DLabel", hqPanel)
        cdLabel:SetPos(20, curY)
        cdLabel:SetSize(PANEL_W - 40, 16)
        cdLabel:SetText("NEXT VOTE AVAILABLE IN: " .. cooldownStr)
        cdLabel:SetFont("ixHQ_Mono")
        cdLabel:SetTextColor(C.red)
        cdLabel:SetContentAlignment(5)
        curY = curY + 20
    end

    -- --------------------------------------------------------
    -- Officer roster
    -- --------------------------------------------------------
    local rosterLabel = vgui.Create("DLabel", hqPanel)
    rosterLabel:SetPos(20, curY)
    rosterLabel:SetSize(200, 16)
    rosterLabel:SetText("OFFICERS PRESENT")
    rosterLabel:SetFont("ixHQ_Sub")
    rosterLabel:SetTextColor(C.inkLight)
    curY = curY + 18

    local rosterH = 100
    local rosterPanel = vgui.Create("DScrollPanel", hqPanel)
    rosterPanel:SetPos(20, curY)
    rosterPanel:SetSize(PANEL_W - 40, rosterH)
    rosterPanel.Paint = function(self, w, h)
        surface.SetDrawColor(C.paperDark.r, C.paperDark.g, C.paperDark.b, 140)
        surface.DrawRect(0, 0, w, h)
    end

    for i, voter in ipairs(data.voters) do
        local row = vgui.Create("DPanel", rosterPanel)
        row:SetSize(PANEL_W - 40, 26)
        row:SetPos(0, (i - 1) * 27)
        row.Paint = function(self, w, h)
            if i % 2 == 0 then
                surface.SetDrawColor(0, 0, 0, 20)
                surface.DrawRect(0, 0, w, h)
            end
        end

        local nameLabel = vgui.Create("DLabel", row)
        nameLabel:SetPos(8, 4)
        nameLabel:SetSize(PANEL_W - 100, 18)
        nameLabel:SetText(string.upper(voter.fullRank) .. "  " .. voter.name)
        nameLabel:SetFont("ixHQ_Mono")
        nameLabel:SetTextColor(voter.steamid == localSteamID and C.ink or C.inkLight)

        local voteLabel = vgui.Create("DLabel", row)
        voteLabel:SetPos(0, 4)
        voteLabel:SetSize(PANEL_W - 50, 18)
        voteLabel:SetText(VoteSymbol(voter.vote))
        voteLabel:SetFont("ixHQ_MonoBig")
        voteLabel:SetTextColor(VoteColor(voter.vote))
        voteLabel:SetContentAlignment(6)
    end

    if #data.voters == 0 then
        local empty = vgui.Create("DLabel", rosterPanel)
        empty:SetPos(0, 8)
        empty:SetSize(PANEL_W - 40, 18)
        empty:SetText("No eligible personnel.")
        empty:SetFont("ixHQ_Mono")
        empty:SetTextColor(C.inkLight)
        empty:SetContentAlignment(5)
    end

    curY = curY + rosterH + 8

    -- --------------------------------------------------------
    -- Status banner
    -- --------------------------------------------------------
    local statusPanel = vgui.Create("DPanel", hqPanel)
    statusPanel:SetPos(20, curY)
    statusPanel:SetSize(PANEL_W - 40, 44)

    local statusText, statusCol, stampText, stampCol

    if data.armed then
        if data.shortDateLabel then
            statusText = string.format("ASSAULT — %s, %s",
                string.upper(data.shortDateLabel), data.slotLabel or "DAWN")
        else
            statusText = "ASSAULT ORDERED FOR " .. (data.slotLabel or "DAWN")
        end
        statusCol  = C.ink
        stampText  = "ORDERED"
        stampCol   = C.armed
        statusPanel.Paint = function(self, w, h)
            surface.SetDrawColor(C.armed.r, C.armed.g, C.armed.b, 60)
            surface.DrawRect(0, 0, w, h)
            surface.SetDrawColor(C.armed.r, C.armed.g, C.armed.b, 180)
            surface.DrawRect(0, 0, w, 2)
            surface.DrawRect(0, h - 2, w, 2)
        end
    elseif data.active then
        statusText = "VOTE IN PROGRESS — " .. (data.slotLabel or "??:??") ..
            "  [" .. FormatCountdown(data.voteDeadline) .. "]"
        statusCol  = C.ink
        stampText  = "VOTING"
        stampCol   = C.inkLight
        statusPanel.Paint = function(self, w, h)
            surface.SetDrawColor(60, 80, 60, 50)
            surface.DrawRect(0, 0, w, h)
        end
    else
        statusText = "NO ASSAULT ORDERED"
        statusCol  = C.inkLight
        stampText  = "STANDBY"
        stampCol   = C.inkLight
        statusPanel.Paint = function(self, w, h)
            surface.SetDrawColor(0, 0, 0, 30)
            surface.DrawRect(0, 0, w, h)
        end
    end

    local statLabel = vgui.Create("DLabel", statusPanel)
    statLabel:SetPos(10, 4)
    statLabel:SetSize(PANEL_W - 155, 36)
    statLabel:SetText(statusText)
    statLabel:SetFont("ixHQ_Mono")
    statLabel:SetTextColor(statusCol)
    statLabel:SetWrap(true)
    hqPanel._statLabel     = statLabel
    hqPanel._slotLabel     = data.slotLabel
    hqPanel._voteDeadline  = data.voteDeadline

    local stampLabel = vgui.Create("DLabel", statusPanel)
    stampLabel:SetPos(PANEL_W - 150, 4)
    stampLabel:SetSize(120, 36)
    stampLabel:SetText(stampText)
    stampLabel:SetFont("ixHQ_Stamp")
    stampLabel:SetTextColor(Color(stampCol.r, stampCol.g, stampCol.b, 90))
    stampLabel:SetContentAlignment(4)

    curY = curY + 52

    -- --------------------------------------------------------
    -- Determine if local player is an eligible voter
    -- --------------------------------------------------------
    local localIsVoter = false
    local localVote    = nil
    for _, voter in ipairs(data.voters) do
        if voter.steamid == localSteamID then
            localIsVoter = true
            localVote    = voter.vote
            break
        end
    end

    -- --------------------------------------------------------
    -- Action area
    -- --------------------------------------------------------
    local function StyledButton(parent, x, y, w, h, label, col, onClick)
        local btn = vgui.Create("DButton", parent)
        btn:SetPos(x, y)
        btn:SetSize(w, h)
        btn:SetText(label)
        btn:SetFont("ixHQ_MonoBig")
        btn:SetTextColor(C.white)
        btn.baseCol = col
        btn.Paint = function(self, bw, bh)
            local alpha = self:IsHovered() and 255 or 200
            local c = self.baseCol
            surface.SetDrawColor(c.r, c.g, c.b, alpha)
            surface.DrawRect(0, 0, bw, bh)
            surface.SetDrawColor(C.accent.r, C.accent.g, C.accent.b, 160)
            surface.DrawOutlinedRect(0, 0, bw, bh)
        end
        btn.DoClick = onClick
        return btn
    end

    if data.armed then
        local note = vgui.Create("DLabel", hqPanel)
        note:SetPos(20, curY + 6)
        note:SetSize(PANEL_W - 40, 18)
        note:SetText("Assault orders cannot be rescinded. Prepare your men.")
        note:SetFont("ixHQ_Mono")
        note:SetTextColor(C.accent)
        note:SetContentAlignment(5)

    elseif data.active then
        -- Vote is open — show AYE/NAY if voter.
        if localIsVoter then
            local bw = math.floor((PANEL_W - 50) / 2)

            StyledButton(hqPanel, 20, curY, bw, 34,
                localVote == true and "AYE  ✓" or "AYE",
                localVote == true and C.yes or Color(55, 90, 50),
                function()
                    net.Start("ixHQVoteCast")
                        net.WriteBool(true)
                    net.SendToServer()
                end
            )

            StyledButton(hqPanel, 30 + bw, curY, bw, 34,
                localVote == false and "NAY  ✕" or "NAY",
                localVote == false and C.no or Color(120, 40, 30),
                function()
                    net.Start("ixHQVoteCast")
                        net.WriteBool(false)
                    net.SendToServer()
                end
            )
        else
            local obs = vgui.Create("DLabel", hqPanel)
            obs:SetPos(20, curY + 8)
            obs:SetSize(PANEL_W - 40, 18)
            obs:SetText("Vote in progress — awaiting officer consensus.")
            obs:SetFont("ixHQ_Mono")
            obs:SetTextColor(C.inkLight)
            obs:SetContentAlignment(5)
        end

    elseif localIsVoter and not cooldownStr then
        -- No active vote — slot selector + call vote button.
        -- Buttons update their own Paint each frame from selectedSlot.
        -- No panel rebuild on click.

        local slotHeading = vgui.Create("DLabel", hqPanel)
        slotHeading:SetPos(20, curY)
        slotHeading:SetSize(PANEL_W - 40, 16)
        slotHeading:SetText("SELECT ASSAULT TIME")
        slotHeading:SetFont("ixHQ_Sub")
        slotHeading:SetTextColor(C.inkLight)
        curY = curY + 18

        local slots  = data.slots or ix.hq.SLOTS or {}
        local slotBW = math.floor((PANEL_W - 50) / 4)
        local slotBH = 28

        -- Create the call-vote button first so slot DoClick can reference it.
        local rowsUsed = math.ceil(#slots / 4)
        local callBtnY = curY + rowsUsed * (slotBH + 4) + 6
        local callBtn  = vgui.Create("DButton", hqPanel)
        callBtn:SetPos(20, callBtnY)
        callBtn:SetSize(PANEL_W - 40, 34)
        callBtn:SetFont("ixHQ_MonoBig")
        callBtn:SetText(selectedSlot
            and ("CALL ASSAULT VOTE — " .. slots[selectedSlot].label)
            or  "SELECT A TIME SLOT ABOVE")
        callBtn:SetTextColor(selectedSlot and C.white or C.inkLight)
        callBtn.baseCol = selectedSlot and Color(80, 65, 40) or Color(60, 55, 45)
        callBtn.Paint = function(self, w, h)
            local active = selectedSlot ~= nil
            local alpha  = (self:IsHovered() and active) and 255 or 200
            surface.SetDrawColor(self.baseCol.r, self.baseCol.g, self.baseCol.b, alpha)
            surface.DrawRect(0, 0, w, h)
            surface.SetDrawColor(C.accent.r, C.accent.g, C.accent.b, 160)
            surface.DrawOutlinedRect(0, 0, w, h)
        end
        callBtn.DoClick = function()
            if not selectedSlot then return end
            net.Start("ixHQVoteStart")
                net.WriteUInt(selectedSlot, 8)
            net.SendToServer()
        end

        -- Slot buttons — Paint reads selectedSlot live each frame.
        for i, slot in ipairs(slots) do
            local col = math.fmod(i - 1, 4)
            local row = math.floor((i - 1) / 4)
            local sx  = 20 + col * (slotBW + 4)
            local sy  = curY + row * (slotBH + 4)

            local btn = vgui.Create("DButton", hqPanel)
            btn:SetPos(sx, sy)
            btn:SetSize(slotBW, slotBH)
            btn:SetText("")   -- drawn manually below
            btn:SetFont("ixHQ_Mono")
            btn.myIdx = i
            btn.myLbl = slot.label

            btn.Paint = function(self, w, h)
                local isSel = (selectedSlot == self.myIdx)
                local base  = isSel and C.slotSel or C.paperDark
                if self:IsHovered() then base = C.slotHov end
                surface.SetDrawColor(base.r, base.g, base.b, 220)
                surface.DrawRect(0, 0, w, h)
                surface.SetDrawColor(C.accent.r, C.accent.g, C.accent.b, 140)
                surface.DrawOutlinedRect(0, 0, w, h)
                draw.SimpleText(self.myLbl, "ixHQ_Mono", w * 0.5, h * 0.5,
                    isSel and C.white or C.ink,
                    TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
            end

            btn.DoClick = function(self)
                selectedSlot = self.myIdx
                if IsValid(callBtn) then
                    callBtn:SetText("CALL ASSAULT VOTE — " .. self.myLbl)
                    callBtn:SetTextColor(C.white)
                    callBtn.baseCol = Color(80, 65, 40)
                end
            end
        end

    elseif cooldownStr then
        local cdNote = vgui.Create("DLabel", hqPanel)
        cdNote:SetPos(20, curY + 8)
        cdNote:SetSize(PANEL_W - 40, 18)
        cdNote:SetText("Next vote available in " .. cooldownStr .. ".")
        cdNote:SetFont("ixHQ_Mono")
        cdNote:SetTextColor(C.red)
        cdNote:SetContentAlignment(5)
    else
        local wait = vgui.Create("DLabel", hqPanel)
        wait:SetPos(20, curY + 8)
        wait:SetSize(PANEL_W - 40, 18)
        wait:SetText("Awaiting officer orders.")
        wait:SetFont("ixHQ_Mono")
        wait:SetTextColor(C.inkLight)
        wait:SetContentAlignment(5)
    end

    -- Footer
    local footer = vgui.Create("DLabel", hqPanel)
    footer:SetPos(10, PANEL_H - 28)
    footer:SetSize(PANEL_W - 20, 20)
    footer:SetText("CONFIDENTIAL — FOR AUTHORISED OFFICERS ONLY")
    footer:SetFont("ixHQ_Mono")
    footer:SetTextColor(C.inkLight)
    footer:SetContentAlignment(5)

    return hqPanel
end

-- ============================================================
-- Live countdown ticker for open vote panel
-- ============================================================

hook.Add("Think", "ixHQVoteCountdown", function()
    if not IsValid(hqPanel) then return end
    if not hqState.active then return end
    if not hqState.voteDeadline then return end
    if not IsValid(hqPanel._statLabel) then return end
    -- Update only the countdown text — no panel rebuild.
    if not hqPanel._lastTick or (CurTime() - hqPanel._lastTick) >= 1 then
        hqPanel._lastTick = CurTime()
        hqPanel._statLabel:SetText(
            "VOTE IN PROGRESS — " .. (hqPanel._slotLabel or "??:??") ..
            "  [" .. FormatCountdown(hqPanel._voteDeadline) .. "]"
        )
    end
end)

-- ============================================================
-- Net receivers
-- ============================================================

net.Receive("ixHQOpen", function()
    local data = net.ReadTable()
    hqState = data
    selectedSlot = nil
    BuildHQPanel(data)
end)

net.Receive("ixHQVoteSync", function()
    local data = net.ReadTable()
    hqState = data
    if IsValid(hqPanel) then
        BuildHQPanel(data)
    end
end)