print("[SPAWN] cl_plugin.lua loaded on client")

-- Receive the spawnview config from the server.
net.Receive("ixSpawnViewSync", function()
    local data = net.ReadTable()

    -- Reconstruct vectors.
    for team, teamEntry in pairs(data) do
        for spawnType, cfg in pairs(teamEntry) do
            if cfg.center and type(cfg.center) == "table" then
                cfg.center = Vector(cfg.center[1] or 0, cfg.center[2] or 0, cfg.center[3] or 0)
            end
        end
    end

    -- Store under current map.
    ix.spawnView.config[game.GetMap()] = data
    print("[SPAWN] Received spawnview config from server.")
end)

-- =====================================================================
-- Coordinate conventions (same as before)
-- =====================================================================
-- World +X -> screen up (negative Y in pixels)
-- World +Y -> screen left (negative X in pixels)
-- Camera origin at (cx, cy) above world; ortho view looking straight down.

local function BuildDeathScreenPanel()
    local PANEL = {}

    local MAP_VIEW_HEIGHT_FRAC = 0.55
    local MAP_PADDING = 64
    local SPAWN_ICON_RADIUS = 22
    local SPAWN_ICON_OUTLINE = 3
    local CAMERA_HEIGHT = 1500

    local COLOR_FORWARD       = Color(80, 180, 90, 255)
    local COLOR_FORWARD_EMPTY = Color(90, 90, 90, 200)
    local COLOR_RESERVE       = Color(80, 130, 200, 255)
    local COLOR_OUTLINE       = Color(20, 20, 20, 255)
    local COLOR_BORDER_ICON   = Color(220, 220, 220, 255)

    -- Margin between border icons and the map view edge.
    local BORDER_MARGIN = 8

    function PANEL:Init()
        local scrW, scrH = ScrW(), ScrH()

        self:SetSize(scrW, scrH)
        self:SetPos(0, 0)

        local text = string.utf8upper(L("youreDead"))

        surface.SetFont("ixMenuButtonHugeFont")
        local textW, textH = surface.GetTextSize(text)

        self.label = self:Add("DLabel")
        self.label:SetPaintedManually(true)
        self.label:SetPos(scrW * 0.5 - textW * 0.5, scrH * 0.18 - textH * 0.5)
        self.label:SetFont("ixMenuButtonHugeFont")
        self.label:SetText(text)
        self.label:SizeToContents()

        self.progress = 0
        self.bMapShown = false
        self.spawnEnts = {}

        -- The currently active camera. {center = Vector, viewSpan = number}
        self.activeCamera = nil

        -- Which spawnType the current camera belongs to (used to know when
        -- to "snap back" or stay on the active camera).
        self.activeCameraType = nil

        self:CreateAnimation(ix.config.Get("spawnTime", 5), {
            bIgnoreConfig = true,
            target = {progress = 1},
            OnComplete = function(animation, panel)
                if IsValid(panel) and not panel.bMapShown then
                    panel:ShowSpawnMap()
                end
            end
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

    -- Returns a camera config {center, viewSpan} for a given (team, spawnType).
    -- Falls back to: configured for that spawn -> position of the spawn entity
    -- itself -> nil.
    function PANEL:GetCameraFor(team, spawnType)
        local cfg = ix.spawnView.Get(team, spawnType)
        if cfg and cfg.center then
            return {
                center = cfg.center,
                viewSpan = cfg.viewSpan or ix.spawnView.DEFAULT_VIEW_SPAN
            }
        end

        -- Fallback: use the spawn entity's own position.
        for _, ent in ipairs(self.spawnEnts) do
            if IsValid(ent) and ent:GetSpawnType() == spawnType then
                return {
                    center = ent:GetPos(),
                    viewSpan = ix.spawnView.DEFAULT_VIEW_SPAN
                }
            end
        end

        return nil
    end

    function PANEL:ShowSpawnMap()
        self.bMapShown = true

        local team, spawns = self:GetTeamSpawns()
        self.spawnEnts = spawns
        self.team = team

        if #spawns == 0 then
            self:MakePopup()
            self:SetKeyboardInputEnabled(false)
            return
        end

        -- Default to the reserve camera.
        local reserveCam = self:GetCameraFor(team, SPAWN_RESERVE)
        if reserveCam then
            self.activeCamera = reserveCam
            self.activeCameraType = SPAWN_RESERVE
        else
            -- Fall back to forward if no reserve config exists.
            local forwardCam = self:GetCameraFor(team, SPAWN_FORWARD)
            if forwardCam then
                self.activeCamera = forwardCam
                self.activeCameraType = SPAWN_FORWARD
            end
        end

        self:MakePopup()
        self:SetKeyboardInputEnabled(false)
    end

    -- Pixels per world unit for the active camera, computed from viewSpan
    -- and the longer screen dimension.
    function PANEL:GetPixelsPerUnit()
        if not self.activeCamera then return 1 end

        local _, _, mapW, mapH = self:GetMapRect()
        local longer = math.max(mapW, mapH)

        return longer / self.activeCamera.viewSpan
    end

    function PANEL:WorldToMap(worldPos, mapX, mapY, mapW, mapH)
        if not self.activeCamera then
            return mapX + mapW * 0.5, mapY + mapH * 0.5
        end

        local cam = self.activeCamera.center
        local pxPerUnit = self:GetPixelsPerUnit()

        local px = mapX + mapW * 0.5 + (cam.y - worldPos.y) * pxPerUnit
        local py = mapY + mapH * 0.5 + (cam.x - worldPos.x) * pxPerUnit

        return px, py
    end

    -- Returns an icon position for a spawn entity. If the icon would be
    -- off-screen, clamps it to the map view's border. Returns:
    --   px, py, isClamped
    function PANEL:GetSpawnIconPosition(ent, mapX, mapY, mapW, mapH)
        local px, py = self:WorldToMap(ent:GetPos(), mapX, mapY, mapW, mapH)

        local minX = mapX + SPAWN_ICON_RADIUS + BORDER_MARGIN
        local maxX = mapX + mapW - SPAWN_ICON_RADIUS - BORDER_MARGIN
        local minY = mapY + SPAWN_ICON_RADIUS + BORDER_MARGIN
        local maxY = mapY + mapH - SPAWN_ICON_RADIUS - BORDER_MARGIN

        local clamped = false

        if px < minX then px = minX; clamped = true end
        if px > maxX then px = maxX; clamped = true end
        if py < minY then py = minY; clamped = true end
        if py > maxY then py = maxY; clamped = true end

        return px, py, clamped
    end

    function PANEL:Think()
        if IsValid(self.label) then
            self.label:SetAlpha(((self.progress - 0.3) / 0.3) * 255)
        end

        if not self.bMapShown then return end
        if not self.activeCamera then return end

        -- Hover detection: if the cursor is over a clamped (border) icon
        -- belonging to a different spawn type than the active camera,
        -- switch the active camera to that spawn's view.
        local mx, my = gui.MousePos()
        local mapX, mapY, mapW, mapH = self:GetMapRect()

        for _, ent in ipairs(self.spawnEnts) do
            if not IsValid(ent) then continue end

            local px, py, isClamped = self:GetSpawnIconPosition(ent, mapX, mapY, mapW, mapH)
            local dist = math.sqrt((mx - px)^2 + (my - py)^2)

            if dist <= SPAWN_ICON_RADIUS and isClamped then
                local spawnType = ent:GetSpawnType()
                if spawnType ~= self.activeCameraType then
                    local newCam = self:GetCameraFor(self.team, spawnType)
                    if newCam then
                        self.activeCamera = newCam
                        self.activeCameraType = spawnType
                    end
                end
                return
            end
        end
    end

    function PANEL:OnMousePressed(mouseCode)
        if mouseCode ~= MOUSE_LEFT then return end
        self:CheckSpawnIconClick()
    end

    function PANEL:CheckSpawnIconClick()
        if not self.activeCamera then return end
        if #self.spawnEnts == 0 then return end

        local mx, my = gui.MousePos()
        local mapX, mapY, mapW, mapH = self:GetMapRect()

        for _, ent in ipairs(self.spawnEnts) do
            if not IsValid(ent) then continue end

            local px, py = self:GetSpawnIconPosition(ent, mapX, mapY, mapW, mapH)
            local dist = math.sqrt((mx - px)^2 + (my - py)^2)

            if dist <= SPAWN_ICON_RADIUS then
                self:OnSpawnIconClicked(ent)
                return
            end
        end
    end

    function PANEL:OnSpawnIconClicked(ent)
        local spawnType = ent:GetSpawnType()

        if spawnType == SPAWN_FORWARD then
            local dropPoint = self:GetTeamDropPoint()
            if not IsValid(dropPoint) or dropPoint:GetUniforms() <= 0 then
                self.emptyStockNoticeUntil = CurTime() + 2
                surface.PlaySound("buttons/button10.wav")
                return
            end
        end

        net.Start("ixSpawnChoice")
            net.WriteString(spawnType)
        net.SendToServer()
    end

    function PANEL:GetMapRect()
        local scrW, scrH = ScrW(), ScrH()

        local mapH = scrH * MAP_VIEW_HEIGHT_FRAC
        local mapW = scrW - MAP_PADDING * 2
        local mapX = MAP_PADDING
        local mapY = scrH - mapH - MAP_PADDING

        return mapX, mapY, mapW, mapH
    end

    function PANEL:RenderMapView(mapX, mapY, mapW, mapH)
        if not self.activeCamera then return end

        local pxPerUnit = self:GetPixelsPerUnit()
        local scale = 1 / pxPerUnit  -- world units per pixel for ortho extents

        local view = {
            origin = Vector(
                self.activeCamera.center.x,
                self.activeCamera.center.y,
                self.activeCamera.center.z + CAMERA_HEIGHT
            ),
            angles = Angle(90, 0, 0),
            x = mapX,
            y = mapY,
            w = mapW,
            h = mapH,
            ortho = {
                left   = -mapW * 0.5 * scale,
                right  =  mapW * 0.5 * scale,
                top    = -mapH * 0.5 * scale,
                bottom =  mapH * 0.5 * scale,
            },
            zfar = 8192,
            znear = 16,
            drawhud = false,
            drawviewmodel = false,
            drawmonitors = false,
            dopostprocess = false,
        }

        render.RenderView(view)
    end

    function PANEL:DrawSpawnIcons(mapX, mapY, mapW, mapH)
        if not self.activeCamera then return end

        for _, ent in ipairs(self.spawnEnts) do
            if not IsValid(ent) then continue end

            local px, py, isClamped = self:GetSpawnIconPosition(ent, mapX, mapY, mapW, mapH)

            local spawnType = ent:GetSpawnType()
            local fillColor
            local label

            if spawnType == SPAWN_FORWARD then
                local dropPoint = self:GetTeamDropPoint()
                local uniforms = IsValid(dropPoint) and dropPoint:GetUniforms() or 0
                local maxUniforms = DROP_MAX_UNIFORMS or 10

                if uniforms <= 0 then
                    fillColor = COLOR_FORWARD_EMPTY
                else
                    fillColor = COLOR_FORWARD
                end

                label = "FORWARD (" .. uniforms .. "/" .. maxUniforms .. ")"
            elseif spawnType == SPAWN_RESERVE then
                fillColor = COLOR_RESERVE
                label = "RESERVE (free)"
            else
                fillColor = COLOR_BORDER_ICON
                label = string.upper(tostring(spawnType))
            end

            -- Outline ring.
            draw.NoTexture()
            surface.SetDrawColor(COLOR_OUTLINE)
            self:DrawCircle(px, py, SPAWN_ICON_RADIUS + SPAWN_ICON_OUTLINE, 32)

            -- Filled circle.
            surface.SetDrawColor(fillColor)
            self:DrawCircle(px, py, SPAWN_ICON_RADIUS, 32)

            -- Label below.
            draw.SimpleTextOutlined(
                label,
                "ixGenericFont",
                px,
                py + SPAWN_ICON_RADIUS + 12,
                Color(255, 255, 255, 255),
                TEXT_ALIGN_CENTER, TEXT_ALIGN_TOP,
                1, Color(0, 0, 0, 220)
            )
        end
    end

    function PANEL:DrawCircle(cx, cy, radius, segments)
        local poly = {}
        for i = 0, segments do
            local a = math.rad((i / segments) * 360)
            poly[i + 1] = {
                x = cx + math.cos(a) * radius,
                y = cy + math.sin(a) * radius
            }
        end
        surface.DrawPoly(poly)
    end

    function PANEL:Paint(width, height)
        derma.SkinFunc("PaintDeathScreenBackground", self, width, height, self.progress)

        if IsValid(self.label) then
            self.label:PaintManual()
        end

        derma.SkinFunc("PaintDeathScreen", self, width, height, self.progress)

        if not self.bMapShown then return end

        local mapX, mapY, mapW, mapH = self:GetMapRect()

        surface.SetDrawColor(0, 0, 0, 220)
        surface.DrawRect(mapX, mapY, mapW, mapH)

        if not self.activeCamera or #self.spawnEnts == 0 then
            draw.SimpleTextOutlined(
                "NO SPAWNS AVAILABLE",
                "ixMenuButtonFont",
                mapX + mapW * 0.5,
                mapY + mapH * 0.5,
                Color(255, 100, 100, 255),
                TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER,
                1, Color(0, 0, 0, 220)
            )
            return
        end

        self:RenderMapView(mapX, mapY, mapW, mapH)

        surface.SetDrawColor(180, 180, 180, 200)
        surface.DrawOutlinedRect(mapX, mapY, mapW, mapH)

        self:DrawSpawnIcons(mapX, mapY, mapW, mapH)

        if self.emptyStockNoticeUntil and CurTime() < self.emptyStockNoticeUntil then
            draw.SimpleTextOutlined(
                "No uniforms available",
                "ixMenuButtonFont",
                mapX + mapW * 0.5,
                mapY - 24,
                Color(255, 80, 80, 255),
                TEXT_ALIGN_CENTER, TEXT_ALIGN_BOTTOM,
                1, Color(0, 0, 0, 220)
            )
        end

        draw.SimpleTextOutlined(
            "Click a spawn to deploy. Hover an off-screen spawn to view it.",
            "ixGenericFont",
            mapX + mapW * 0.5,
            mapY + mapH + 8,
            Color(220, 220, 220, 200),
            TEXT_ALIGN_CENTER, TEXT_ALIGN_TOP,
            1, Color(0, 0, 0, 220)
        )
    end

    function PANEL:IsClosing()
        return self.bIsClosing
    end

    function PANEL:Close()
        self.bIsClosing = true

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