print("[AMMO] cl_plugin.lua loaded")

local PLUGIN = PLUGIN

-- =====================================================================
-- Per-entity log mirror
-- =====================================================================
ix.ammoSystem = ix.ammoSystem or {}
ix.ammoSystem.depotLogs = ix.ammoSystem.depotLogs or {}

-- =====================================================================
-- UI palette + fonts
-- =====================================================================
local PANEL_W = 540
local PANEL_H = 600

local C = {
    bg        = Color(34,  28,  18),
    paper     = Color(210, 195, 158),
    paperDark = Color(185, 168, 128),
    ink       = Color(38,  30,  18),
    inkLight  = Color(80,  65,  40),
    accent    = Color(120, 95,  55),
    yes       = Color(55,  100, 50),
    no        = Color(140, 40,  30),
    white     = Color(240, 230, 210),
    bar       = Color(110, 80,  40),
    barFill   = Color(170, 130, 60),
    btnBase   = Color(80,  65,  40),
    btnHover  = Color(110, 90,  55),
    btnDis    = Color(60,  55,  45),
}

surface.CreateFont("ixDepot_Title",   { font = "Trajan Pro",  size = 22, weight = 700 })
surface.CreateFont("ixDepot_Sub",     { font = "Trajan Pro",  size = 15, weight = 400 })
surface.CreateFont("ixDepot_Mono",    { font = "Courier New", size = 13, weight = 400 })
surface.CreateFont("ixDepot_MonoBig", { font = "Courier New", size = 16, weight = 700 })
surface.CreateFont("ixDepot_Small",   { font = "Courier New", size = 11, weight = 400 })

-- =====================================================================
-- Helpers
-- =====================================================================
local function DrawPaper(x, y, w, h)
    draw.RoundedBox(4, x, y, w, h, C.paper)
    surface.SetDrawColor(C.paperDark.r, C.paperDark.g, C.paperDark.b, 120)
    surface.DrawRect(x, y, w, 2)
    surface.DrawRect(x, y, 2, h)
    surface.DrawRect(x + w - 2, y, 2, h)
    surface.DrawRect(x, y + h - 2, w, 2)
end

local function TimeAgo(ts)
    local dt = math.max(0, CurTime() - (ts or 0))
    if dt < 10  then return "just now"  end
    if dt < 60  then return string.format("%ds ago", math.floor(dt)) end
    if dt < 3600 then return string.format("%dm ago", math.floor(dt / 60)) end
    return string.format("%dh ago", math.floor(dt / 3600))
end

local function ClassDisplay(class)
    if class == "pistol" then return "Pistol Rounds" end
    if class == "bolt"   then return "Bolt Rounds"   end
    if class == "mg"     then return "MG Rounds"     end
    return class
end

local function CountInventoryAmmo(class, team)
    local lp = LocalPlayer()
    if not IsValid(lp) then return 0 end
    local char = lp:GetCharacter()
    if not char then return 0 end
    local inv = char:GetInventory()
    if not inv then return 0 end

    local ammoType = class .. "_" .. team
    local total = 0
    for _, invItem in pairs(inv:GetItems()) do
        if invItem.base == "base_gw_ammo" and invItem.ammoType == ammoType then
            total = total + invItem:GetData("amount", 1)
        end
    end
    return total
end

-- =====================================================================
-- The menu panel (one at a time — only one depot open per player)
-- =====================================================================
local depotPanel = nil

local function BuildDepotPanel(data)
    if IsValid(depotPanel) then depotPanel:Remove() end

    local teamName = data.team == "axis" and "AXIS" or "ALLIES"

    depotPanel = vgui.Create("DFrame")
    depotPanel:SetSize(PANEL_W, PANEL_H)
    depotPanel:Center()
    depotPanel:SetDraggable(true)
    depotPanel:SetDeleteOnClose(true)
    depotPanel:SetTitle("")
    depotPanel:MakePopup()

    depotPanel.entIndex = data.entIndex
    depotPanel.team     = data.team

    depotPanel.Paint = function(self, w, h)
        draw.RoundedBox(6, 0, 0, w, h, C.bg)
        DrawPaper(4, 4, w - 8, h - 8)
        surface.SetDrawColor(C.ink.r, C.ink.g, C.ink.b, 220)
        surface.DrawRect(4, 4, w - 8, 52)
        surface.SetDrawColor(C.accent.r, C.accent.g, C.accent.b, 180)
        surface.DrawRect(4, 56, w - 8, 1)
    end

    -- Title
    local title = vgui.Create("DLabel", depotPanel)
    title:SetPos(0, 12)
    title:SetSize(PANEL_W, 18)
    title:SetText(teamName .. " AMMUNITION DEPOT")
    title:SetFont("ixDepot_Title")
    title:SetContentAlignment(5)
    title:SetTextColor(C.white)

    -- Close button
    local closeBtn = vgui.Create("DButton", depotPanel)
    closeBtn:SetPos(PANEL_W - 30, 8)
    closeBtn:SetSize(22, 22)
    closeBtn:SetText("✕")
    closeBtn:SetFont("ixDepot_Sub")
    closeBtn:SetTextColor(C.white)
    closeBtn.Paint = function(self, w, h)
        if self:IsHovered() then
            surface.SetDrawColor(180, 60, 40, 200)
            surface.DrawRect(0, 0, w, h)
        end
    end
    closeBtn.DoClick = function() depotPanel:Close() end

    -- =================================================================
    -- Stockpile rows: pistol / bolt / MG
    -- =================================================================
    local rowY = 70
    local ROW_H = 72

    local function StyledButton(parent, x, y, w, h, label, onClick, getEnabled)
        local btn = vgui.Create("DButton", parent)
        btn:SetPos(x, y)
        btn:SetSize(w, h)
        btn:SetText(label)
        btn:SetFont("ixDepot_Mono")
        btn:SetTextColor(C.white)
        btn._getEnabled = getEnabled or function() return true end
        btn.Paint = function(self, bw, bh)
            local enabled = self._getEnabled()
            local col
            if not enabled then
                col = C.btnDis
            elseif self:IsHovered() then
                col = C.btnHover
            else
                col = C.btnBase
            end
            surface.SetDrawColor(col.r, col.g, col.b, 220)
            surface.DrawRect(0, 0, bw, bh)
            surface.SetDrawColor(C.accent.r, C.accent.g, C.accent.b, 160)
            surface.DrawOutlinedRect(0, 0, bw, bh)
            self:SetTextColor(enabled and C.white or C.inkLight)
        end
        btn.DoClick = function(self)
            if not self._getEnabled() then return end
            onClick()
        end
        return btn
    end

    depotPanel.classRows = {}

    local function MakeClassRow(class, idx)
        local y = rowY + (idx - 1) * ROW_H
        local row = vgui.Create("DPanel", depotPanel)
        row:SetPos(20, y)
        row:SetSize(PANEL_W - 40, ROW_H - 6)
        row.Paint = function(self, w, h)
            surface.SetDrawColor(0, 0, 0, 18)
            surface.DrawRect(0, 0, w, h)
        end

        local nameLbl = vgui.Create("DLabel", row)
        nameLbl:SetPos(8, 4)
        nameLbl:SetSize(220, 18)
        nameLbl:SetText(ClassDisplay(class))
        nameLbl:SetFont("ixDepot_MonoBig")
        nameLbl:SetTextColor(C.ink)

        local countLbl = vgui.Create("DLabel", row)
        countLbl:SetPos(PANEL_W - 40 - 100 - 8, 4)
        countLbl:SetSize(100, 18)
        countLbl:SetFont("ixDepot_MonoBig")
        countLbl:SetTextColor(C.ink)
        countLbl:SetContentAlignment(6)

        local bar = vgui.Create("DPanel", row)
        bar:SetPos(8, 26)
        bar:SetSize(PANEL_W - 40 - 16, 8)
        bar.Paint = function(self, w, h)
            surface.SetDrawColor(C.bar.r, C.bar.g, C.bar.b, 180)
            surface.DrawRect(0, 0, w, h)

            local rs = depotPanel.classRows[class]
            local pct = 0
            if rs and rs.cap and rs.cap > 0 then
                pct = math.Clamp((rs.count or 0) / rs.cap, 0, 1)
            end
            surface.SetDrawColor(C.barFill.r, C.barFill.g, C.barFill.b, 240)
            surface.DrawRect(0, 0, w * pct, h)
        end

        local bw = math.floor((PANEL_W - 40 - 16 - 8) / 2)
        local depBtn = StyledButton(row, 8, 40, bw, 22,
            "Deposit All",
            function()
                net.Start("ixAmmoDepotAction")
                    net.WriteUInt(depotPanel.entIndex, 16)
                    net.WriteString("deposit")
                    net.WriteString(class)
                net.SendToServer()
            end,
            function()
                local rs = depotPanel.classRows[class]
                if not rs then return false end
                local hasAmmo = CountInventoryAmmo(class, depotPanel.team) > 0
                local hasRoom = (rs.count or 0) < (rs.cap or 0)
                return hasAmmo and hasRoom
            end
        )
        local takeBtn = StyledButton(row, 8 + bw + 8, 40, bw, 22,
            "Take 10",
            function()
                net.Start("ixAmmoDepotAction")
                    net.WriteUInt(depotPanel.entIndex, 16)
                    net.WriteString("withdraw")
                    net.WriteString(class)
                net.SendToServer()
            end,
            function()
                local rs = depotPanel.classRows[class]
                if not rs then return false end
                return (rs.count or 0) > 0
            end
        )

        depotPanel.classRows[class] = {
            row      = row,
            countLbl = countLbl,
            bar      = bar,
            depBtn   = depBtn,
            takeBtn  = takeBtn,
            count    = 0,
            cap      = 0,
        }
    end

    MakeClassRow("pistol", 1)
    MakeClassRow("bolt",   2)
    MakeClassRow("mg",     3)

    -- =================================================================
    -- Activity log (bottom block)
    -- =================================================================
    local logY = rowY + 3 * ROW_H + 8

    local logHeading = vgui.Create("DLabel", depotPanel)
    logHeading:SetPos(20, logY)
    logHeading:SetSize(PANEL_W - 40, 16)
    logHeading:SetText("RECENT ACTIVITY")
    logHeading:SetFont("ixDepot_Sub")
    logHeading:SetTextColor(C.inkLight)

    local logScroll = vgui.Create("DScrollPanel", depotPanel)
    logScroll:SetPos(20, logY + 18)
    logScroll:SetSize(PANEL_W - 40, PANEL_H - logY - 50)
    logScroll.Paint = function(self, w, h)
        surface.SetDrawColor(C.paperDark.r, C.paperDark.g, C.paperDark.b, 140)
        surface.DrawRect(0, 0, w, h)
    end
    depotPanel.logScroll = logScroll

    -- =================================================================
    -- Footer
    -- =================================================================
    local footer = vgui.Create("DLabel", depotPanel)
    footer:SetPos(10, PANEL_H - 28)
    footer:SetSize(PANEL_W - 20, 20)
    footer:SetText("FORWARD AMMUNITION RESUPPLY POINT")
    footer:SetFont("ixDepot_Mono")
    footer:SetTextColor(C.inkLight)
    footer:SetContentAlignment(5)

    -- =================================================================
    -- State application
    -- =================================================================
    function depotPanel:ApplyState(stateData)
        for _, class in ipairs({"pistol", "bolt", "mg"}) do
            local rs = self.classRows[class]
            if rs then
                local counts = stateData[class] or { count = 0, cap = 0 }
                rs.count = counts.count or 0
                rs.cap   = counts.cap   or 0
                if IsValid(rs.countLbl) then
                    rs.countLbl:SetText(string.format("%d / %d", rs.count, rs.cap))
                end
            end
        end
    end

    function depotPanel:RenderLog()
        if not IsValid(self.logScroll) then return end
        self.logScroll:Clear()

        local entries = ix.ammoSystem.depotLogs[self.entIndex] or {}

        if #entries == 0 then
            local empty = vgui.Create("DLabel", self.logScroll)
            empty:SetPos(0, 8)
            empty:SetSize(PANEL_W - 40, 18)
            empty:SetText("No activity yet.")
            empty:SetFont("ixDepot_Mono")
            empty:SetTextColor(C.inkLight)
            empty:SetContentAlignment(5)
            return
        end

        local rowYy = 0
        for i = #entries, 1, -1 do
            local e = entries[i]

            local row = vgui.Create("DPanel", self.logScroll)
            row:SetSize(PANEL_W - 40, 20)
            row:SetPos(0, rowYy)
            local rowIdx = (#entries - i) + 1
            row.Paint = function(self2, w, h)
                if rowIdx % 2 == 0 then
                    surface.SetDrawColor(0, 0, 0, 18)
                    surface.DrawRect(0, 0, w, h)
                end
            end

            local deltaText = (e.delta >= 0)
                and string.format("+%d", e.delta)
                or  tostring(e.delta)
            local deltaCol = (e.delta >= 0) and C.yes or C.no

            local deltaLbl = vgui.Create("DLabel", row)
            deltaLbl:SetPos(4, 2)
            deltaLbl:SetSize(40, 16)
            deltaLbl:SetText(deltaText)
            deltaLbl:SetFont("ixDepot_MonoBig")
            deltaLbl:SetTextColor(deltaCol)
            deltaLbl:SetContentAlignment(5)

            local classLbl = vgui.Create("DLabel", row)
            classLbl:SetPos(50, 3)
            classLbl:SetSize(60, 16)
            classLbl:SetText(e.class or "?")
            classLbl:SetFont("ixDepot_Mono")
            classLbl:SetTextColor(C.inkLight)

            local who = e.actorName or "—"
            local nameLbl = vgui.Create("DLabel", row)
            nameLbl:SetPos(115, 3)
            nameLbl:SetSize(PANEL_W - 40 - 115 - 70, 16)
            nameLbl:SetText(who)
            nameLbl:SetFont("ixDepot_Mono")
            nameLbl:SetTextColor(C.ink)

            local timeLbl = vgui.Create("DLabel", row)
            timeLbl:SetPos(PANEL_W - 40 - 70, 3)
            timeLbl:SetSize(66, 16)
            timeLbl:SetText(TimeAgo(e.ts))
            timeLbl:SetFont("ixDepot_Small")
            timeLbl:SetTextColor(C.inkLight)
            timeLbl:SetContentAlignment(6)

            rowYy = rowYy + 21
        end
    end

    depotPanel:ApplyState(data)

    ix.ammoSystem.depotLogs[data.entIndex] = data.log or {}
    depotPanel:RenderLog()

    timer.Create("ixDepotLogTick_" .. tostring(depotPanel), 10, 0, function()
        if not IsValid(depotPanel) then
            timer.Remove("ixDepotLogTick_" .. tostring(depotPanel))
            return
        end
        depotPanel:RenderLog()
    end)

    return depotPanel
end

-- =====================================================================
-- Net receivers
-- =====================================================================
net.Receive("ixAmmoDepotOpen", function()
    local data = net.ReadTable()
    BuildDepotPanel(data)
end)

net.Receive("ixAmmoDepotLogSync", function()
    local entIndex = net.ReadUInt(16)
    local entry = {
        ts           = net.ReadFloat(),
        class        = net.ReadString(),
        delta        = net.ReadInt(16),
        actorName    = net.ReadString(),
        actorSteamID = net.ReadString(),
    }

    ix.ammoSystem.depotLogs[entIndex] = ix.ammoSystem.depotLogs[entIndex] or {}
    local log = ix.ammoSystem.depotLogs[entIndex]
    log[#log + 1] = entry

    local cap = (ix.ammoSystem.DEPOT_LOG_MAX) or 30
    while #log > cap do
        table.remove(log, 1)
    end

    if IsValid(depotPanel) and depotPanel.entIndex == entIndex then
        depotPanel:RenderLog()
    end
end)

-- =====================================================================
-- State refresh
-- =====================================================================
-- After deposit/withdraw, the entity's NetworkVars update. Re-pull state
-- from the entity each tick (throttled) so the count text and progress
-- bar update without needing a full re-open.
hook.Add("Think", "ixAmmoDepotPanelRefresh", function()
    if not IsValid(depotPanel) then return end
    if not depotPanel.entIndex then return end

    local ent = ents.GetByIndex(depotPanel.entIndex)
    if not IsValid(ent) or not ent.GetCountFor then
        depotPanel:Close()
        return
    end

    if depotPanel._lastRefresh and (CurTime() - depotPanel._lastRefresh) < 0.1 then
        return
    end
    depotPanel._lastRefresh = CurTime()

    local stateData = {
        pistol = { count = ent:GetPistolCount(), cap = ent:GetCapFor("pistol") },
        bolt   = { count = ent:GetBoltCount(),   cap = ent:GetCapFor("bolt") },
        mg     = { count = ent:GetMgCount(),     cap = ent:GetCapFor("mg") },
    }
    depotPanel:ApplyState(stateData)
end)