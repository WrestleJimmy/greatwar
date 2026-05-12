include("shared.lua")

-- =====================================================================
-- Hover text
-- =====================================================================
-- When the player is looking at the depot from close range, show a
-- subtle "Use to access" prompt. We don't surface counts in 3D space —
-- you have to open the menu to see numbers (per your design call).
function ENT:DrawTranslucent()
    self:DrawModel()

    -- Only the matching team gets the hover text. Cross-team players
    -- just see a barrel; they don't even know it's an ammo depot.
    local lp = LocalPlayer()
    if not IsValid(lp) then return end

    local char = lp:GetCharacter()
    if not char then return end

    local team = ix.team and ix.team.GetTeam and ix.team.GetTeam(char:GetFaction()) or nil
    if team ~= self.Team then return end

    -- Show the hint when player is looking near the entity AND within
    -- usable range (~100 units).
    local pos    = lp:GetShootPos()
    local aim    = lp:GetAimVector()
    local target = self:WorldSpaceCenter()
    local dist   = pos:Distance(target)
    if dist > 200 then return end

    -- Project — only render if entity is within a small angular cone of
    -- the player's view direction (roughly looking at it).
    local toEnt = (target - pos):GetNormalized()
    local dot   = aim:Dot(toEnt)
    if dot < 0.95 then return end   -- ~18° cone

    local screenPos = target:ToScreen()
    if not screenPos.visible then return end

    surface.SetFont("DermaDefaultBold")
    local text = "[E] Use to access"
    local tw, th = surface.GetTextSize(text)

    -- Background pill.
    local px, py = 8, 4
    local boxW, boxH = tw + px * 2, th + py * 2
    local boxX = screenPos.x - boxW / 2
    local boxY = screenPos.y - boxH / 2

    surface.SetDrawColor(0, 0, 0, 200)
    surface.DrawRect(boxX, boxY, boxW, boxH)
    surface.SetDrawColor(255, 255, 255, 60)
    surface.DrawOutlinedRect(boxX, boxY, boxW, boxH)

    surface.SetTextColor(255, 255, 255, 255)
    surface.SetTextPos(boxX + px, boxY + py)
    surface.DrawText(text)
end
