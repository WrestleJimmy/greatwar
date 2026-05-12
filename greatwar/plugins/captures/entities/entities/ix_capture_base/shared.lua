ENT.Type      = "anim"
ENT.Base      = "base_anim"
ENT.PrintName = "Capture Point (Base)"
ENT.Author    = "WrestleJimmy"
ENT.Category  = "Helix - Captures"
ENT.Spawnable = false  -- only subclasses are spawnable
ENT.AdminOnly = true

ENT.Model = "models/hunter/blocks/cube05x05x05.mdl"

-- Subclasses override this; indicates which team DEFENDS this point.
-- String literal per Helix-quirk note: TEAM_* constants may not be loaded yet.
ENT.Team = "axis"

function ENT:SetupDataTables()
    self:NetworkVar("Float",  0, "Progress")
    self:NetworkVar("Bool",   0, "Contested")
    self:NetworkVar("Bool",   1, "Locked")
    self:NetworkVar("String", 0, "CapturingTeam")
    self:NetworkVar("String", 1, "Team")
    self:NetworkVar("String", 2, "SectorID")
    self:NetworkVar("String", 3, "SlotID")
end
