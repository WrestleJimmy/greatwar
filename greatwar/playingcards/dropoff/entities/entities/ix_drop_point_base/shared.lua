ENT.Type = "anim"
ENT.Base = "base_anim"
ENT.PrintName = "Drop Point Base"
ENT.Category = "Helix - Trench Warfare"
ENT.Author = "Schema"
ENT.Spawnable = false
ENT.AdminOnly = true

-- Subclasses set this to "axis" or "allies".
ENT.Team = nil

-- Same cube model as spawn entities. Different material later for visual ID.
ENT.Model = "models/hunter/blocks/cube075x075x075.mdl"

function ENT:SetupDataTables()
    self:NetworkVar("String", 0, "Team")
    self:NetworkVar("Int", 0, "Uniforms")
end
