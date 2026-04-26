print("[SPAWN] cl_deathscreen.lua loaded on client")

local PANEL = {}

function PANEL:Init()
    print("[SPAWN] Death screen Init() running")

    local scrW, scrH = ScrW(), ScrH()

    self:SetSize(scrW, scrH)
    self:SetPos(0, 0)

    local text = string.utf8upper(L("youreDead"))

    surface.SetFont("ixMenuButtonHugeFont")
    local textW, textH = surface.GetTextSize(text)

    self.label = self:Add("DLabel")
    self.label:SetPaintedManually(true)
    self.label:SetPos(scrW * 0.5 - textW * 0.5, scrH * 0.5 - textH * 0.5)
    self.label:SetFont("ixMenuButtonHugeFont")
    self.label:SetText(text)
    self.label:SizeToContents()

    self.progress = 0
    self.bButtonsShown = false

    self:CreateAnimation(ix.config.Get("spawnTime", 5), {
        bIgnoreConfig = true,
        target = {progress = 1},

        OnComplete = function(animation, panel)
            print("[SPAWN] Spawn timer complete, showing buttons")
            if IsValid(panel) and not panel.bButtonsShown then
                panel:ShowSpawnButtons()
            end
        end
    })

    print("[SPAWN] Death screen Init() complete")
end

function PANEL:ShowSpawnButtons()
    print("[SPAWN] ShowSpawnButtons() running")
    self.bButtonsShown = true

    local scrW, scrH = ScrW(), ScrH()
    local btnW, btnH = 220, 56
    local spacing = 24
    local totalW = btnW * 2 + spacing
    local startX = scrW * 0.5 - totalW * 0.5
    local y = scrH * 0.5 + 80

    self.forwardBtn = self:Add("DButton")
    self.forwardBtn:SetSize(btnW, btnH)
    self.forwardBtn:SetPos(startX, y)
    self.forwardBtn:SetText("FORWARD\n(1 uniform)")
    self.forwardBtn:SetFont("ixMenuButtonFont")
    self.forwardBtn:SetTextColor(Color(255, 255, 255))
    self.forwardBtn.DoClick = function()
        self:PickSpawn(SPAWN_FORWARD)
    end
    self.forwardBtn.Paint = function(btn, w, h)
        local col = btn:IsHovered() and Color(80, 80, 80, 220) or Color(40, 40, 40, 220)
        surface.SetDrawColor(col)
        surface.DrawRect(0, 0, w, h)
        surface.SetDrawColor(180, 180, 180, 255)
        surface.DrawOutlinedRect(0, 0, w, h)
    end

    self.reserveBtn = self:Add("DButton")
    self.reserveBtn:SetSize(btnW, btnH)
    self.reserveBtn:SetPos(startX + btnW + spacing, y)
    self.reserveBtn:SetText("RESERVE\n(free)")
    self.reserveBtn:SetFont("ixMenuButtonFont")
    self.reserveBtn:SetTextColor(Color(255, 255, 255))
    self.reserveBtn.DoClick = function()
        self:PickSpawn(SPAWN_RESERVE)
    end
    self.reserveBtn.Paint = function(btn, w, h)
        local col = btn:IsHovered() and Color(80, 80, 80, 220) or Color(40, 40, 40, 220)
        surface.SetDrawColor(col)
        surface.DrawRect(0, 0, w, h)
        surface.SetDrawColor(180, 180, 180, 255)
        surface.DrawOutlinedRect(0, 0, w, h)
    end

    self:MakePopup()
    self:SetKeyboardInputEnabled(false)
end

function PANEL:PickSpawn(spawnType)
    print("[SPAWN] PickSpawn called with:", spawnType)

    if IsValid(self.forwardBtn) then self.forwardBtn:SetEnabled(false) end
    if IsValid(self.reserveBtn) then self.reserveBtn:SetEnabled(false) end

    net.Start("ixSpawnChoice")
        net.WriteString(spawnType)
    net.SendToServer()
end

function PANEL:Think()
    if IsValid(self.label) then
        self.label:SetAlpha(((self.progress - 0.3) / 0.3) * 255)
    end
end

function PANEL:IsClosing()
    return self.bIsClosing
end

function PANEL:Close()
    self.bIsClosing = true

    if IsValid(self.forwardBtn) then self.forwardBtn:SetVisible(false) end
    if IsValid(self.reserveBtn) then self.reserveBtn:SetVisible(false) end

    self:CreateAnimation(2, {
        index = 2,
        bIgnoreConfig = true,
        target = {progress = 0},

        OnComplete = function(animation, panel)
            if IsValid(panel) then
                panel:Remove()
            end
        end
    })
end

function PANEL:Paint(width, height)
    derma.SkinFunc("PaintDeathScreenBackground", self, width, height, self.progress)
    if IsValid(self.label) then
        self.label:PaintManual()
    end
    derma.SkinFunc("PaintDeathScreen", self, width, height, self.progress)
end

vgui.Register("ixDeathScreen", PANEL, "Panel")

print("[SPAWN] ixDeathScreen registered")