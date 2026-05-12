AddCSLuaFile("cl_init.lua")
AddCSLuaFile("shared.lua")
include("shared.lua")

function ENT:Initialize()
    self:SetModel(self.Model)
    self:SetMoveType(MOVETYPE_NONE)
    self:SetSolid(SOLID_VPHYSICS)
    self:PhysicsInit(SOLID_VPHYSICS)

    local phys = self:GetPhysicsObject()
    if IsValid(phys) then
        phys:EnableMotion(false)
        phys:Wake()
    else
        self:PhysicsInitBox(self:OBBMins(), self:OBBMaxs())
        self:EnableCustomCollisions(true)
        self:SetSolid(SOLID_BBOX)

        local fb = self:GetPhysicsObject()
        if IsValid(fb) then
            fb:EnableMotion(false)
            fb:Wake()
        end
    end

    if self.Team then
        self:SetTeam(self.Team)
    end

    self:SetUniforms(0)

    -- Register with the drop point lookup.
    ix.dropPoint.Register(self, self.Team)
end

function ENT:OnRemove()
    ix.dropPoint.Unregister(self)
end

-- Indestructible (matches HQ — for now only stockpiles can be sabotaged,
-- which is just decrementing the count, not destroying the entity).
function ENT:OnTakeDamage(dmgInfo)
    return 0
end
