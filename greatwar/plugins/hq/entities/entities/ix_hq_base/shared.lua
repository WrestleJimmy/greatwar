ENT.Type = "anim"
ENT.Base = "base_anim"
ENT.PrintName = "HQ Base"
ENT.Category = "Helix - Trench Warfare"
ENT.Author = "Schema"
ENT.Spawnable = false
ENT.AdminOnly = true

-- Subclasses set this to TEAM_AXIS or TEAM_ALLIES.
ENT.Team = nil

ENT.Model = "models/static/maptable.mdl"

function ENT:SetupDataTables()
    self:NetworkVar("String", 0, "Team")
end
