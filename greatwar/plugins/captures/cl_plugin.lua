local PLUGIN = PLUGIN

-- ============================================================
-- Bottom-of-screen HUD bar shown when player is in or near
-- a capture point (entity-local 3D2D badge lives in cl_init.lua).
-- ============================================================

local TEAM_COLOR = {
    axis   = Color(180, 60, 60),
    allies = Color(60, 100, 180),
}

local NEUTRAL         = Color(220, 220, 220)
local CONTESTED_COLOR = Color(220, 200, 80)
local HUD_RANGE_BUFFER = 100  -- show HUD slightly outside the actual zone

-- Returns true if this capture-point entity should be considered "live"
-- right now (i.e. capturable / shown on HUD).
--
--   * Standard team-locked points: only when they're in the active
--     sector of an ongoing assault.
--   * Neutral points: only during a meeting engagement.
local function IsPointLive(ent)
    local team = ent:GetTeam()

    if (team == "neutral") then
        return GetGlobalBool("ixMeetingActive", false)
    end

    if (ix.assault and ix.assault.IsSectorActive) then
        return ix.assault.IsSectorActive(ent:GetSectorID() or "")
    end

    return false
end

hook.Add("HUDPaint", "ixCaptureHUD", function()
    local client = LocalPlayer()
    if (not IsValid(client) or not client:Alive()) then return end

    local hudRange = ix.capture.RADIUS + HUD_RANGE_BUFFER
    local nearestEnt, nearestDist

    for _, ent in ipairs(ents.FindByClass("ix_capture_*")) do
        if (not IsValid(ent)) then continue end

        -- Skip the abstract base entities (they shouldn't be spawned, but
        -- guard anyway).
        local class = ent:GetClass()
        if (class == "ix_capture_base" or class == "ix_capture_neutral_base") then continue end

        if (not IsPointLive(ent)) then continue end

        local d = ent:GetPos():Distance(client:GetPos())
        if (d <= hudRange and (not nearestDist or d < nearestDist)) then
            nearestEnt, nearestDist = ent, d
        end
    end

    if (not IsValid(nearestEnt)) then return end

    local sector    = nearestEnt:GetSectorID() or "?"
    local slot      = nearestEnt:GetSlotID()   or "?"
    local progress  = nearestEnt:GetProgress() or 0
    local capTeam   = nearestEnt:GetCapturingTeam()
    local contested = nearestEnt:GetContested()
    local defender  = nearestEnt:GetTeam()
    local locked    = nearestEnt:GetLocked()
    local isNeutral = (defender == "neutral")

    local sw, sh   = ScrW(), ScrH()
    local barW, barH = 320, 18
    local x, y     = (sw - barW) * 0.5, sh - 140

    local label = string.format("OBJECTIVE %s%s", sector, slot)
    if (locked and progress >= 1) then
        if (isNeutral and capTeam ~= "" and capTeam ~= nil) then
            label = label .. "  -  " .. string.upper(capTeam) .. " HELD"
        else
            label = label .. "  -  CAPTURED"
        end
    elseif (contested) then
        label = label .. "  -  CONTESTED"
    elseif (isNeutral and (capTeam == "" or capTeam == nil)) then
        label = label .. "  -  NEUTRAL"
    end

    -- Background
    surface.SetDrawColor(0, 0, 0, 200)
    surface.DrawRect(x, y, barW, barH)

    -- Fill color + width logic
    local fillColor
    local displayProgress = progress

    if (contested) then
        fillColor = CONTESTED_COLOR
    elseif (capTeam ~= "" and capTeam ~= nil) then
        fillColor = TEAM_COLOR[capTeam] or NEUTRAL
    else
        if (isNeutral) then
            -- Empty neutral point: thin neutral band (10% fill so the bar isn't blank).
            fillColor       = NEUTRAL
            displayProgress = 0.1
        else
            -- Nobody currently capturing -> show defender color full
            fillColor       = TEAM_COLOR[defender] or NEUTRAL
            displayProgress = 1
        end
    end

    surface.SetDrawColor(fillColor.r, fillColor.g, fillColor.b, 220)
    surface.DrawRect(x, y, barW * displayProgress, barH)

    -- Border
    surface.SetDrawColor(255, 255, 255, 80)
    surface.DrawOutlinedRect(x, y, barW, barH)

    -- Label above the bar
    draw.SimpleText(label, "DermaDefaultBold", x + barW * 0.5, y - 4,
        Color(255, 255, 255, 230), TEXT_ALIGN_CENTER, TEXT_ALIGN_BOTTOM)
end)