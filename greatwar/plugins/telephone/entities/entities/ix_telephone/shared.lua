ENT.Type = "anim"
ENT.Base = "base_gmodentity"
ENT.PrintName = "Trench Phone"
ENT.Spawnable = true
ENT.AdminOnly = true
ENT.Category = "Helix"
ENT.ShowPlayerInteraction = true

function ENT:SetupDataTables()
    self:NetworkVar("Bool", 0, "Ringing")
    self:NetworkVar("Bool", 1, "InUse")
end