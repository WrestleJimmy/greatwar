ENT.Type = "anim"
ENT.Base = "base_anim"
ENT.PrintName = "Spawn Base"
ENT.Category = "Helix - Trench Warfare"
ENT.Author = "Schema"
ENT.Spawnable = false
ENT.AdminOnly = true

-- Subclasses set these.
ENT.Team = nil       -- TEAM_AXIS or TEAM_ALLIES
ENT.SpawnType = nil  -- SPAWN_FORWARD or SPAWN_RESERVE

ENT.Model = "models/hunter/blocks/cube075x075x075.mdl"

function ENT:SetupDataTables()
    self:NetworkVar("String", 0, "Team")
    self:NetworkVar("String", 1, "SpawnType")
end
