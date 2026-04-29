include("shared.lua")

-- ============================================================
-- Neutral capture point client render
--
-- Same visual style as ix_capture_base, with two changes:
--   * The "defender ring" color is white/grey since no one owns it.
--   * Gated on ix.assault.meetingActive instead of IsSectorActive.
-- ============================================================

local TEAM_COLOR = {
    axis   = Color(180, 60, 60),
    allies = Color(60, 100, 180),
}

local NEUTRAL         = Color(220, 220, 220)
local CONTESTED_COLOR = Color(220, 200, 80)

local function DrawCircle(x, y, radius, segs, color)
    surface.SetDrawColor(color.r, color.g, color.b, color.a or 255)
    local poly = {}
    for i = 0, segs do
        local a = math.rad((i / segs) * 360)
        poly[#poly + 1] = { x = x + math.cos(a) * radius, y = y + math.sin(a) * radius }
    end
    draw.NoTexture()
    surface.DrawPoly(poly)
end

local function DrawPieSlice(x, y, radius, segs, fraction, color)
    if (fraction <= 0) then return end
    surface.SetDrawColor(color.r, color.g, color.b, color.a or 255)
    local poly = { { x = x, y = y } }
    local sweep = math.Clamp(fraction, 0, 1)
    for i = 0, segs do
        local t = (i / segs) * sweep
        local a = math.rad(t * 360 - 90)
        poly[#poly + 1] = {
            x = x + math.cos(a) * radius,
            y = y + math.sin(a) * radius,
        }
    end
    draw.NoTexture()
    surface.DrawPoly(poly)
end

local function DrawRingOutline(x, y, radius, segs, thickness, color)
    surface.SetDrawColor(color.r, color.g, color.b, color.a or 255)
    for i = 0, segs - 1 do
        local a1 = math.rad((i       / segs) * 360)
        local a2 = math.rad(((i + 1) / segs) * 360)
        local x1 = x + math.cos(a1) * radius
        local y1 = y + math.sin(a1) * radius
        local x2 = x + math.cos(a2) * radius
        local y2 = y + math.sin(a2) * radius
        surface.DrawLine(x1, y1, x2, y2)
        if (thickness > 1) then
            local x1b = x + math.cos(a1) * (radius - thickness)
            local y1b = y + math.sin(a1) * (radius - thickness)
            local x2b = x + math.cos(a2) * (radius - thickness)
            local y2b = y + math.sin(a2) * (radius - thickness)
            surface.DrawLine(x1b, y1b, x2b, y2b)
        end
    end
end

local function GetDisplayColor(self)
    if (self:GetContested()) then return CONTESTED_COLOR end
    local capTeam = self:GetCapturingTeam()
    if (capTeam == "" or capTeam == nil) then return NEUTRAL end
    return TEAM_COLOR[capTeam] or NEUTRAL
end

function ENT:Draw()
    -- Hide entirely outside meeting engagement; nothing to interact with.
    -- Reads the networked global set by sv_meeting.lua. ix.assault.meetingActive
    -- is server-only and would always be false on the client.
    if (not GetGlobalBool("ixMeetingActive", false)) then
        return
    end

    self:DrawModel()

    local pos = self:GetPos() + Vector(0, 0, 96)

    local dist = LocalPlayer():EyePos():Distance(pos)
    if (dist > 4096) then return end

    local plyAng = LocalPlayer():EyeAngles()
    local ang    = Angle(0, plyAng.y - 90, 90)

    local sector   = self:GetSectorID() or "N"
    local slot     = self:GetSlotID()   or "1"
    local label    = sector .. slot
    local progress = self:GetProgress() or 0
    local color    = GetDisplayColor(self)
    local locked   = self:GetLocked()

    cam.Start3D2D(pos, ang, 0.5)
        DrawCircle(0, 0, 64, 48, Color(0, 0, 0, 140))

        if (progress > 0) then
            DrawPieSlice(0, 0, 60, 48, progress,
                Color(color.r, color.g, color.b, 180))
        end

        -- Neutral ring (white) since no team owns it.
        DrawRingOutline(0, 0, 64, 48, 4,
            Color(NEUTRAL.r, NEUTRAL.g, NEUTRAL.b, 220))

        draw.SimpleText(label, "DermaLarge", 0, -6,
            Color(255, 255, 255, 240),
            TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)

        local status
        if (locked and progress >= 1) then
            local capTeam = self:GetCapturingTeam()
            status = (capTeam ~= "" and capTeam ~= nil)
                and string.upper(capTeam) .. " HELD"
                or  "TAKEN"
        elseif (self:GetContested()) then
            status = "CONTESTED"
        elseif (progress > 0 and progress < 1) then
            status = math.Round(progress * 100) .. "%"
        else
            status = "NEUTRAL"
        end

        if (status) then
            draw.SimpleText(status, "DermaDefault", 0, 22,
                Color(255, 255, 255, 200),
                TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
        end
    cam.End3D2D()
end