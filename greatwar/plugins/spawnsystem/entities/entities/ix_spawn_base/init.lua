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

    if self.SpawnType then
        self:SetSpawnType(self.SpawnType)
    end

    -- Register with the spawn lookup so respawns can find us.
    ix.spawn.Register(self, self.Team, self.SpawnType)
end

function ENT:OnRemove()
    ix.spawn.Unregister(self)
end

-- Indestructible.
function ENT:OnTakeDamage(dmgInfo)
    return 0
end
