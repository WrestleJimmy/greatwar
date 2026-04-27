print("[SPAWN] cl_plugin.lua loaded on client")

-- Receive the spawnview config from the server. Storage is keyed per-spawn
-- by position string, e.g. ix.spawnView.config[mapName][posKey] = { ... }.
net.Receive("ixSpawnViewSync", function()
    local data = net.ReadTable()

    for posKey, cfg in pairs(data) do
        if cfg.pos and type(cfg.pos) == "table" then
            cfg.pos = Vector(cfg.pos[1] or 0, cfg.pos[2] or 0, cfg.pos[3] or 0)
        end
        if cfg.angles and type(cfg.angles) == "table" then
            cfg.angles = Angle(cfg.angles[1] or 0, cfg.angles[2] or 0, cfg.angles[3] or 0)
        end
    end

    ix.spawnView.config[game.GetMap()] = data
    print("[SPAWN] Received spawnview config from server.")
end)

-- =====================================================================
-- CalcView hook
-- =====================================================================
-- While the death screen has an active camera, override the player's view
-- to render the world from that camera's pos/angles/fov. Same idea as
-- Helix mapscenes.
--
-- Registered with HOOK_HIGH priority so we run before Helix's own CalcView
-- hooks (death cam etc.). For CalcView, the first non-nil return wins.
local lastReportedCam = nil
local function ixSpawnCalcView(ply, origin, angles, fov)
    local cam = ix.spawnView.activeViewCamera
    if not cam or not cam.pos then return end

    -- Diagnostic: print once whenever the camera reference changes so we
    -- can confirm in console that clicks are propagating to CalcView.
    if cam ~= lastReportedCam then
        lastReportedCam = cam
        print(string.format("[SPAWN] CalcView using camera at (%.0f,%.0f,%.0f) ang=(%.0f,%.0f,%.0f) fov=%d",
            cam.pos.x, cam.pos.y, cam.pos.z,
            cam.angles and cam.angles.p or 0,
            cam.angles and cam.angles.y or 0,
            cam.angles and cam.angles.r or 0,
            cam.fov or 0))
    end

    return {
        origin     = cam.pos,
        angles     = cam.angles or Angle(0, 0, 0),
        fov        = cam.fov or ix.spawnView.DEFAULT_FOV,
        drawviewer = false,
    }
end

-- HOOK_HIGH ensures we run before Helix's own CalcView hooks. Older GMod
-- builds without priority constants fall through to the no-priority form.
if HOOK_HIGH then
    hook.Add("CalcView", "ixSpawnDeathCalcView", ixSpawnCalcView, HOOK_HIGH)
else
    hook.Add("CalcView", "ixSpawnDeathCalcView", ixSpawnCalcView)
end

-- Hide the regular HUD while the death screen has an active camera.
hook.Add("HUDShouldDraw", "ixSpawnDeathHUDHide", function(name)
    if not ix.spawnView.activeViewCamera then return end
    -- Hide common HUD elements; let the death screen panel paint its own UI.
    if name == "CHudCrosshair"
        or name == "CHudHealth"
        or name == "CHudBattery"
        or name == "CHudAmmo"
        or name == "CHudSecondaryAmmo"
        or name == "CHudWeaponSelection"
    then
        return false
    end
end)

-- =====================================================================
-- Death silence
-- =====================================================================
-- While bSilenceDeathAudio is true we hard-suppress every new sound the
-- engine tries to emit. Combined with a `stopsound` issued the moment the
-- player dies, this gives a clean abrupt cut to silence under the black
-- overlay. The death screen panel sets/clears the flag.
local bSilenceDeathAudio = false

hook.Add("EmitSound", "ixSpawnDeathSilence", function(data)
    if bSilenceDeathAudio then
        return false
    end
end)

-- =====================================================================
-- Death screen panel
-- =====================================================================
local function BuildDeathScreenPanel()
    local PANEL = {}

    local COLOR_FORWARD       = Color(80, 180, 90, 255)
    local COLOR_FORWARD_EMPTY = Color(140, 90, 90, 255)
    local COLOR_RESERVE       = Color(80, 130, 200, 255)
    local COLOR_OUTLINE       = Color(20, 20, 20, 255)
    local COLOR_SELECTED      = Color(255, 220, 120, 255)
    local COLOR_HOVER         = Color(220, 220, 220, 220)

    -- Panel layout
    local BUTTON_WIDTH      = 260
    local BUTTON_HEIGHT     = 60
    local BUTTON_SPACING    = 10
    local BUTTON_LEFT_PAD   = 32
    local DEPLOY_BTN_WIDTH  = 320
    local DEPLOY_BTN_HEIGHT = 70
    local DEPLOY_BTN_BOTTOM = 48

    -- Death blackout: hold a solid-black overlay over everything for
    -- BLACK_HOLD_DURATION seconds after death, then fade it out over
    -- BLACK_FADE_DURATION seconds to reveal the spawn menu underneath.
    -- During the entire blackout (hold + fade) game audio is silenced for
    -- dramatic effect; sound resumes the moment the overlay hits 0 alpha.
    local BLACK_HOLD_DURATION = 1.0
    local BLACK_FADE_DURATION = 1.0

    function PANEL:Init()
        local scrW, scrH = ScrW(), ScrH()

        self:SetSize(scrW, scrH)
        self:SetPos(0, 0)

        local text = string.utf8upper(L("youreDead"))

        surface.SetFont("ixMenuButtonHugeFont")
        local textW, textH = surface.GetTextSize(text)

        self.label = self:Add("DLabel")
        self.label:SetPaintedManually(true)
        self.label:SetPos(scrW * 0.5 - textW * 0.5, scrH * 0.10 - textH * 0.5)
        self.label:SetFont("ixMenuButtonHugeFont")
        self.label:SetText(text)
        self.label:SizeToContents()

        self.progress = 0
        self.bMapShown = false
        self.spawnEnts = {}
        self.deathStartTime = CurTime()

        -- Cut all currently playing client-side sounds for a hard, dramatic
        -- silence the moment death lands, and start suppressing any new
        -- sounds the engine wants to emit until the blackout finishes fading.
        bSilenceDeathAudio = true
        RunConsoleCommand("stopsound")

        -- Camera anchor (which spawn the world view is rendering from).
        self.activeSpawnEnt = nil
        self.activeCamera = nil

        -- Selection (which spawn the deploy button will spawn at).
        self.selectedSpawnEnt = nil

        -- The buttons we build dynamically.
        self.spawnButtons = {}
        self.deployButton = nil

        self:CreateAnimation(ix.config.Get("spawnTime", 5), {
            bIgnoreConfig = true,
            target = {progress = 1},
        })
    end

    function PANEL:GetTeamSpawns()
        local client = LocalPlayer()
        if not IsValid(client) then return nil, {} end

        local character = client:GetCharacter()
        if not character then return nil, {} end

        local team = ix.team.GetTeam(character:GetFaction())
        if not team then return nil, {} end

        local spawns = {}
        for _, ent in ipairs(ents.GetAll()) do
            if not IsValid(ent) then continue end

            local class = ent:GetClass()
            local isSpawnClass =
                class == "ix_spawn_forward_axis"
                or class == "ix_spawn_reserve_axis"
                or class == "ix_spawn_forward_allies"
                or class == "ix_spawn_reserve_allies"

            if isSpawnClass and ent:GetTeam() == team then
                table.insert(spawns, ent)
            end
        end

        -- Sort: reserve first, then forward, then by ent index for stability.
        table.sort(spawns, function(a, b)
            local aType = a:GetSpawnType()
            local bType = b:GetSpawnType()
            if aType ~= bType then
                if aType == SPAWN_RESERVE then return true end
                if bType == SPAWN_RESERVE then return false end
            end
            return a:EntIndex() < b:EntIndex()
        end)

        return team, spawns
    end

    function PANEL:GetTeamDropPoint()
        local client = LocalPlayer()
        if not IsValid(client) then return nil end

        local character = client:GetCharacter()
        if not character then return nil end

        local team = ix.team.GetTeam(character:GetFaction())
        if not team then return nil end

        for _, ent in ipairs(ents.GetAll()) do
            if not IsValid(ent) then continue end
            local class = ent:GetClass()
            if (class == "ix_drop_point_axis" or class == "ix_drop_point_allies")
                and ent:GetTeam() == team then
                return ent
            end
        end

        return nil
    end

    -- Returns a {pos, angles, fov} table for a given spawn. Falls back to a
    -- generic "above and behind, looking down at the spawn" view if the
    -- spawn has no camera configured, so the camera always works.
    function PANEL:GetCameraForSpawn(ent)
        if not IsValid(ent) then return nil end

        local cfg = ix.spawnView.GetForEntity(ent)
        if cfg and cfg.pos then
            return {
                pos    = cfg.pos,
                angles = cfg.angles or Angle(0, 0, 0),
                fov    = cfg.fov or ix.spawnView.DEFAULT_FOV,
            }
        end

        -- Fallback: 200 units back (along ent yaw) and 150 up, looking at the spawn.
        local spawnPos = ent:GetPos()
        local yaw = ent:GetAngles().y
        local back = Vector(math.cos(math.rad(yaw + 180)), math.sin(math.rad(yaw + 180)), 0) * 200
        local fallbackPos = spawnPos + back + Vector(0, 0, 150)
        local lookDir = (spawnPos - fallbackPos):Angle()
        return {
            pos    = fallbackPos,
            angles = lookDir,
            fov    = ix.spawnView.DEFAULT_FOV,
        }
    end

    -- Pick the spawn that should be camera-active and selected by default.
    -- Preference: first reserve > first forward.
    function PANEL:PickDefaultSpawn()
        local firstReserve, firstForward
        for _, ent in ipairs(self.spawnEnts) do
            if not IsValid(ent) then continue end
            local sType = ent:GetSpawnType()
            if sType == SPAWN_RESERVE and not firstReserve then
                firstReserve = ent
            elseif sType == SPAWN_FORWARD and not firstForward then
                firstForward = ent
            end
        end
        return firstReserve or firstForward
    end

    -- Set both the live camera AND the selected-for-deploy spawn.
    function PANEL:SetActiveSpawn(ent)
        if not IsValid(ent) then return end

        self.activeSpawnEnt   = ent
        self.activeCamera     = self:GetCameraForSpawn(ent)
        self.selectedSpawnEnt = ent

        -- Push to the global the CalcView hook reads.
        ix.spawnView.activeViewCamera = self.activeCamera

        -- Diagnostic: confirms the click path reached us and the global was
        -- updated. If you click a button and don't see this in console, the
        -- click isn't reaching SetActiveSpawn at all.
        local c = self.activeCamera
        print(string.format("[SPAWN] SetActiveSpawn ent=%s class=%s pos=(%.0f,%.0f,%.0f)",
            tostring(ent), ent:GetClass(),
            c.pos.x, c.pos.y, c.pos.z))
    end

    -- =================================================================
    -- Button building
    -- =================================================================
    function PANEL:BuildSpawnButtons()
        local _, scrH = ScrW(), ScrH()

        -- Center the stack vertically on the left side of the screen.
        local totalH = #self.spawnEnts * BUTTON_HEIGHT
            + math.max(0, #self.spawnEnts - 1) * BUTTON_SPACING
        local startY = scrH * 0.5 - totalH * 0.5

        for i, ent in ipairs(self.spawnEnts) do
            if not IsValid(ent) then continue end

            local btn = self:Add("DButton")
            btn:SetSize(BUTTON_WIDTH, BUTTON_HEIGHT)
            btn:SetPos(BUTTON_LEFT_PAD, startY + (i - 1) * (BUTTON_HEIGHT + BUTTON_SPACING))
            btn:SetText("")
            btn.spawnEnt = ent

            local panel = self
            btn.Paint = function(s, w, h)
                panel:PaintSpawnButton(s, w, h)
            end
            btn.DoClick = function(s)
                if not IsValid(s.spawnEnt) then return end
                surface.PlaySound("ui/buttonclick.wav")
                panel:SetActiveSpawn(s.spawnEnt)
            end

            self.spawnButtons[i] = btn
        end
    end

    function PANEL:BuildDeployButton()
        local scrW, scrH = ScrW(), ScrH()

        local btn = self:Add("DButton")
        btn:SetSize(DEPLOY_BTN_WIDTH, DEPLOY_BTN_HEIGHT)
        btn:SetPos(scrW * 0.5 - DEPLOY_BTN_WIDTH * 0.5, scrH - DEPLOY_BTN_HEIGHT - DEPLOY_BTN_BOTTOM)
        btn:SetText("")

        local panel = self
        btn.Paint = function(s, w, h)
            panel:PaintDeployButton(s, w, h)
        end
        btn.DoClick = function(s)
            panel:OnDeployClicked()
        end

        self.deployButton = btn
    end

    -- =================================================================
    -- Button paint
    -- =================================================================
    function PANEL:PaintSpawnButton(btn, w, h)
        local ent = btn.spawnEnt
        if not IsValid(ent) then return end

        local isSelected = (ent == self.selectedSpawnEnt)
        local isHover = btn:IsHovered()
        local spawnType = ent:GetSpawnType()

        -- Stripe color
        local stripeColor
        local label, sublabel

        if spawnType == SPAWN_FORWARD then
            local dropPoint = self:GetTeamDropPoint()
            local uniforms = IsValid(dropPoint) and dropPoint:GetUniforms() or 0
            local maxUniforms = DROP_MAX_UNIFORMS or 10

            stripeColor = uniforms <= 0 and COLOR_FORWARD_EMPTY or COLOR_FORWARD
            label = "FORWARD"
            sublabel = uniforms .. " / " .. maxUniforms .. " uniforms"
        elseif spawnType == SPAWN_RESERVE then
            stripeColor = COLOR_RESERVE
            label = "RESERVE"
            sublabel = "free"
        else
            stripeColor = COLOR_HOVER
            label = string.upper(tostring(spawnType))
            sublabel = ""
        end

        -- Background
        surface.SetDrawColor(0, 0, 0, isSelected and 220 or (isHover and 200 or 170))
        surface.DrawRect(0, 0, w, h)

        -- Color stripe
        surface.SetDrawColor(stripeColor)
        surface.DrawRect(0, 0, 6, h)

        -- Border
        if isSelected then
            surface.SetDrawColor(COLOR_SELECTED)
            surface.DrawOutlinedRect(0, 0, w, h, 2)
        elseif isHover then
            surface.SetDrawColor(COLOR_HOVER)
            surface.DrawOutlinedRect(0, 0, w, h, 1)
        else
            surface.SetDrawColor(COLOR_OUTLINE)
            surface.DrawOutlinedRect(0, 0, w, h, 1)
        end

        draw.SimpleText(label, "ixMenuButtonFont", 18, h * 0.5 - 11,
            Color(255, 255, 255, 255), TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)

        if sublabel ~= "" then
            draw.SimpleText(sublabel, "ixGenericFont", 18, h * 0.5 + 14,
                Color(220, 220, 220, 200), TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
        end
    end

    function PANEL:IsDeployEnabled()
        if self.progress < 1 then return false end
        if not IsValid(self.selectedSpawnEnt) then return false end

        if self.selectedSpawnEnt:GetSpawnType() == SPAWN_FORWARD then
            local dropPoint = self:GetTeamDropPoint()
            local uniforms = IsValid(dropPoint) and dropPoint:GetUniforms() or 0
            if uniforms <= 0 then return false end
        end

        return true
    end

    function PANEL:PaintDeployButton(btn, w, h)
        local enabled = self:IsDeployEnabled()
        local isHover = btn:IsHovered() and enabled

        -- Background
        if enabled then
            surface.SetDrawColor(40, 90, 50, isHover and 240 or 210)
        else
            surface.SetDrawColor(40, 40, 40, 200)
        end
        surface.DrawRect(0, 0, w, h)

        -- Border
        if enabled then
            surface.SetDrawColor(isHover and Color(120, 220, 130, 255) or Color(80, 180, 90, 255))
        else
            surface.SetDrawColor(80, 80, 80, 180)
        end
        surface.DrawOutlinedRect(0, 0, w, h, 2)

        local text
        if self.progress < 1 then
            local total = ix.config.Get("spawnTime", 5)
            local remaining = math.ceil(total * (1 - self.progress))
            text = string.format("DEPLOY  (%ds)", math.max(remaining, 0))
        elseif not IsValid(self.selectedSpawnEnt) then
            text = "SELECT A SPAWN"
        elseif not enabled then
            text = "NO UNIFORMS"
        else
            text = "DEPLOY"
        end

        draw.SimpleText(text, "ixMenuButtonFont", w * 0.5, h * 0.5,
            Color(255, 255, 255, enabled and 255 or 150),
            TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
    end

    function PANEL:OnDeployClicked()
        if not self:IsDeployEnabled() then
            self.emptyStockNoticeUntil = CurTime() + 1.5
            surface.PlaySound("buttons/button10.wav")
            return
        end

        net.Start("ixSpawnChoice")
            net.WriteUInt(self.selectedSpawnEnt:EntIndex(), 16)
        net.SendToServer()

        -- Respawn is in flight. Hide the buttons immediately so that when
        -- Helix kicks off the panel's close animation (which runs progress
        -- backward from 1 -> 0), the deploy button's "(Xs)" timer text
        -- doesn't appear to count back up while the player is regaining
        -- control of their newly-spawned character.
        self.bDeployed = true

        if IsValid(self.deployButton) then
            self.deployButton:SetVisible(false)
        end

        for _, btn in ipairs(self.spawnButtons) do
            if IsValid(btn) then
                btn:SetVisible(false)
            end
        end
    end

    -- =================================================================
    -- Map / panel ready
    -- =================================================================
    function PANEL:ShowSpawnMap()
        if self.bMapShown then return end
        self.bMapShown = true

        local team, spawns = self:GetTeamSpawns()
        self.spawnEnts = spawns
        self.team = team

        if #spawns == 0 then
            self:MakePopup()
            self:SetKeyboardInputEnabled(false)
            return
        end

        -- Pick + lock in the default view (reserve preferred).
        local defaultEnt = self:PickDefaultSpawn()
        if defaultEnt then
            self:SetActiveSpawn(defaultEnt)
        end

        self:BuildSpawnButtons()
        self:BuildDeployButton()

        self:MakePopup()
        self:SetKeyboardInputEnabled(false)
    end

    -- Returns the alpha [0..255] of the fullscreen black overlay for
    -- the current frame. 255 during the hold phase, fades to 0 over
    -- BLACK_FADE_DURATION, stays 0 after.
    function PANEL:GetBlackoutAlpha()
        local elapsed = CurTime() - (self.deathStartTime or CurTime())

        if elapsed < BLACK_HOLD_DURATION then
            return 255
        end

        local fadeT = (elapsed - BLACK_HOLD_DURATION) / BLACK_FADE_DURATION
        if fadeT >= 1 then return 0 end
        return math.Round(255 * (1 - fadeT))
    end

    function PANEL:Think()
        if IsValid(self.label) then
            -- Fade in over 0.3-0.6 of progress, then stay solid.
            local a = math.Clamp((self.progress - 0.3) / 0.3, 0, 1)
            self.label:SetAlpha(a * 255)
        end

        -- Keep audio suppressed only as long as the black overlay is still
        -- visible. The instant it hits 0 alpha, sound is allowed back in.
        if bSilenceDeathAudio and self:GetBlackoutAlpha() <= 0 then
            bSilenceDeathAudio = false
        end

        -- Hold the black overlay until the abrupt blackout phase ends, then
        -- bring up the spawn menu so it fades in from black underneath.
        if not self.bMapShown then
            local elapsed = CurTime() - (self.deathStartTime or CurTime())
            if elapsed >= BLACK_HOLD_DURATION then
                self:ShowSpawnMap()
            end
        end

        -- After the player has clicked Deploy and the server has actually
        -- respawned them, release the spawn camera so they see their newly
        -- spawned character right away (instead of staring at the spawn cam
        -- until the panel finishes its close animation).
        if self.bDeployed then
            local lp = LocalPlayer()
            if IsValid(lp) and lp:Alive() then
                ix.spawnView.activeViewCamera = nil
            end
        end

        -- Defensive: if our anchor spawn vanished (entity removed), pick a
        -- new default so the camera doesn't get stuck on a dead reference.
        if self.bMapShown and not self.bDeployed and not IsValid(self.activeSpawnEnt) then
            local defaultEnt = self:PickDefaultSpawn()
            if defaultEnt then
                self:SetActiveSpawn(defaultEnt)
            else
                ix.spawnView.activeViewCamera = nil
            end
        end
    end

    function PANEL:Paint(width, height)
        -- Subtle vignette/letterbox so the label and buttons stay readable
        -- on top of the live world view rendered by CalcView.

        -- Top dark band
        local topH = math.max(120, height * 0.16)
        surface.SetDrawColor(0, 0, 0, 200 * math.min(self.progress * 2, 1))
        surface.DrawRect(0, 0, width, topH)

        -- Bottom dark band (deploy button area)
        local botH = DEPLOY_BTN_HEIGHT + DEPLOY_BTN_BOTTOM * 2 + 20
        surface.SetDrawColor(0, 0, 0, 200 * math.min(self.progress * 2, 1))
        surface.DrawRect(0, height - botH, width, botH)

        -- Edge fade on the very edges (very light)
        surface.SetDrawColor(0, 0, 0, 60)
        surface.DrawRect(0, topH, width, 1)
        surface.DrawRect(0, height - botH - 1, width, 1)

        if IsValid(self.label) then
            self.label:PaintManual()
        end

        -- "No uniforms" notice
        if self.emptyStockNoticeUntil and CurTime() < self.emptyStockNoticeUntil then
            draw.SimpleTextOutlined(
                "No uniforms available",
                "ixMenuButtonFont",
                width * 0.5,
                height - DEPLOY_BTN_HEIGHT - DEPLOY_BTN_BOTTOM - 20,
                Color(255, 80, 80, 255),
                TEXT_ALIGN_CENTER, TEXT_ALIGN_BOTTOM,
                1, Color(0, 0, 0, 220)
            )
        end

        -- Hint above the spawn button stack
        if self.bMapShown and not self.bDeployed and #self.spawnEnts > 0 then
            local _, scrH = ScrW(), ScrH()
            local totalH = #self.spawnEnts * BUTTON_HEIGHT
                + math.max(0, #self.spawnEnts - 1) * BUTTON_SPACING
            local startY = scrH * 0.5 - totalH * 0.5

            draw.SimpleTextOutlined(
                "SELECT A SPAWN",
                "ixGenericFont",
                BUTTON_LEFT_PAD,
                startY - 22,
                Color(220, 220, 220, 220),
                TEXT_ALIGN_LEFT, TEXT_ALIGN_BOTTOM,
                1, Color(0, 0, 0, 220)
            )
        end
    end

    function PANEL:PaintOver(width, height)
        -- Fullscreen blackout. PaintOver runs after the panel's children
        -- (the spawn buttons + deploy button), so this rect actually covers
        -- them — the user sees solid black for BLACK_HOLD_DURATION and then
        -- the menu fades up from black underneath.
        local a = self:GetBlackoutAlpha()
        if a <= 0 then return end

        surface.SetDrawColor(0, 0, 0, a)
        surface.DrawRect(0, 0, width, height)
    end

    function PANEL:IsClosing()
        return self.bIsClosing
    end

    function PANEL:OnRemove()
        -- Make sure the global camera reference is cleared so CalcView
        -- stops overriding the player's view.
        ix.spawnView.activeViewCamera = nil

        -- Defensive: if the panel is removed before the blackout finishes,
        -- make sure we don't leave the player permanently silent.
        bSilenceDeathAudio = false
    end

    function PANEL:Close()
        self.bIsClosing = true

        -- Clear the camera immediately so the engine restores the player's
        -- normal view as the panel fades out.
        ix.spawnView.activeViewCamera = nil

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

    return PANEL
end

hook.Add("Initialize", "ixSpawnDeathScreenRegister", function()
    vgui.Register("ixDeathScreen", BuildDeathScreenPanel(), "Panel")
end)

vgui.Register("ixDeathScreen", BuildDeathScreenPanel(), "Panel")