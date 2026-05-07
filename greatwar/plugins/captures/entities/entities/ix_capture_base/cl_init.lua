include("shared.lua")

-- ============================================================
-- Floating badge above the cube: ring + sector/slot label +
-- progress pie + status text. cam.Start3D2D billboarded to player.
-- ============================================================

local TEAM_COLOR = {
    axis   = Color(180, 60, 60),
    allies = Color(60, 100, 180),
}
local NEUTRAL         = Color(220, 220, 220)
local CONTESTED_COLOR = Color(220, 200, 80)

local function GetDisplayColor(ent)
    if (ent:GetContested()) then return CONTESTED_COLOR end
    local capTeam = ent:GetCapturingTeam()
    if (capTeam ~= "" and capTeam ~= nil) then
        return TEAM_COLOR[capTeam] or NEUTRAL
    end
    return TEAM_COLOR[ent:GetTeam()] or NEUTRAL
end

-- Filled disc
local function DrawCircle(cx, cy, r, segs, color)
    surface.SetDrawColor(color.r, color.g, color.b, color.a or 255)
    draw.NoTexture()
    local poly = {}
    for i = 0, segs - 1 do
        local a = math.rad((i / segs) * 360)
        poly[i + 1] = { x = cx + math.cos(a) * r, y = cy + math.sin(a) * r }
    end
    surface.DrawPoly(poly)
end

-- Ring (outline) drawn as thin quads around the circumference
local function DrawRingOutline(cx, cy, r, segs, thickness, color)
    surface.SetDrawColor(color.r, color.g, color.b, color.a or 255)
    draw.NoTexture()
    local outer = r + thickness * 0.5
    local inner = r - thickness * 0.5
    for i = 0, segs - 1 do
        local a1 = math.rad((i / segs) * 360)
        local a2 = math.rad(((i + 1) / segs) * 360)
        local poly = {
            { x = cx + math.cos(a1) * inner, y = cy + math.sin(a1) * inner },
            { x = cx + math.cos(a1) * outer, y = cy + math.sin(a1) * outer },
            { x = cx + math.cos(a2) * outer, y = cy + math.sin(a2) * outer },
            { x = cx + math.cos(a2) * inner, y = cy + math.sin(a2) * inner },
        }
        surface.DrawPoly(poly)
    end
end

-- Pie slice fill from top, clockwise, by progress (0..1)
local function DrawPieSlice(cx, cy, r, segs, progress, color)
    if (progress <= 0) then return end
    surface.SetDrawColor(color.r, color.g, color.b, color.a or 255)
    draw.NoTexture()

    local fillSegs = math.max(1, math.ceil(segs * progress))
    for i = 0, fillSegs - 1 do
        local t1 = i / segs
        local t2 = math.min((i + 1) / segs, progress)
        local a1 = math.rad(t1 * 360 - 90)
        local a2 = math.rad(t2 * 360 - 90)
        local poly = {
            { x = cx, y = cy },
            { x = cx + math.cos(a1) * r, y = cy + math.sin(a1) * r },
            { x = cx + math.cos(a2) * r, y = cy + math.sin(a2) * r },
        }
        surface.DrawPoly(poly)
    end
end

function ENT:Draw()
    -- Hidden entirely until this sector is the active assault sector.
    if (ix.assault and ix.assault.IsSectorActive) then
        if (not ix.assault.IsSectorActive(self:GetSectorID() or "")) then
            return
        end
    end

    self:DrawModel()

    local pos = self:GetPos() + Vector(0, 0, 96)

    -- Distance LOD
    local dist = LocalPlayer():EyePos():Distance(pos)
    if (dist > 4096) then return end

    -- Billboard the 3D2D plane to the player (yaw-only, stays upright)
    local plyAng = LocalPlayer():EyeAngles()
    local ang    = Angle(0, plyAng.y - 90, 90)

    local sector   = self:GetSectorID() or "A"
    local slot     = self:GetSlotID()   or "1"
    local label    = sector .. slot
    local progress = self:GetProgress() or 0
    local color    = GetDisplayColor(self)
    local locked   = self:GetLocked()
    local defColor = TEAM_COLOR[self:GetTeam()] or NEUTRAL

    cam.Start3D2D(pos, ang, 0.5)
        -- Background disc (semi-transparent dark)
        DrawCircle(0, 0, 64, 48, Color(0, 0, 0, 140))

        -- Progress pie (capturing team color)
        if (progress > 0) then
            DrawPieSlice(0, 0, 60, 48, progress,
                Color(color.r, color.g, color.b, 180))
        end

        -- Outer ring (defender color)
        DrawRingOutline(0, 0, 64, 48, 4,
            Color(defColor.r, defColor.g, defColor.b, 220))

        -- Sector/slot label
        draw.SimpleText(label, "DermaLarge", 0, -6,
            Color(255, 255, 255, 240),
            TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)

        -- Status under label
        local status
        if (locked and progress >= 1) then
            status = "CAPTURED"
        elseif (self:GetContested()) then
            status = "CONTESTED"
        elseif (progress > 0 and progress < 1) then
            status = math.Round(progress * 100) .. "%"
        end

        if (status) then
            draw.SimpleText(status, "DermaDefault", 0, 22,
                Color(255, 255, 255, 200),
                TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
        end
    cam.End3D2D()
end