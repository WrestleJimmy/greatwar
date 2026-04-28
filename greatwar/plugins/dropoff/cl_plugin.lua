print("[DROP] cl_plugin.lua loaded")

-- HUD overlay showing stockpile values when the player is looking at a
-- friendly drop point.
local HUD_TRACE_DISTANCE = 200

hook.Add("HUDPaint", "ixDropPointHUD", function()
    local client = LocalPlayer()
    if not IsValid(client) then return end

    local character = client:GetCharacter()
    if not character then return end

    local trace = client:GetEyeTrace()
    if not trace.Hit then return end

    local ent = trace.Entity
    if not IsValid(ent) then return end

    -- Only draw for drop point entities.
    local class = ent:GetClass()
    if class ~= "ix_drop_point_axis" and class ~= "ix_drop_point_allies" then
        return
    end

    -- Range check.
    local distSqr = client:EyePos():DistToSqr(ent:GetPos())
    if distSqr > HUD_TRACE_DISTANCE * HUD_TRACE_DISTANCE then return end

    -- Team match check — only show stockpile to friendly team.
    local entTeam = ent:GetTeam()
    if not ix.team.IsOnTeam(character, entTeam) then return end

    -- Draw the readout near the bottom-center of the screen.
    local uniforms = ent:GetUniforms()
    local maxUniforms = DROP_MAX_UNIFORMS or 10

    local text = string.format("Drop Point — Uniforms: %d / %d", uniforms, maxUniforms)
    surface.SetFont("ixGenericFont")
    local tw, th = surface.GetTextSize(text)

    local scrW, scrH = ScrW(), ScrH()
    local x = scrW * 0.5 - tw * 0.5
    local y = scrH * 0.7

    -- Background
    surface.SetDrawColor(0, 0, 0, 180)
    surface.DrawRect(x - 12, y - 6, tw + 24, th + 12)

    surface.SetDrawColor(180, 180, 180, 220)
    surface.DrawOutlinedRect(x - 12, y - 6, tw + 24, th + 12)

    -- Text
    surface.SetTextColor(255, 255, 255, 255)
    surface.SetTextPos(x, y)
    surface.DrawText(text)
end)
