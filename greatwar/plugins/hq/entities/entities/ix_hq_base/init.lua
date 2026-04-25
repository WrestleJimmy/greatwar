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
        -- Model has no usable physics mesh. Fall back to a bounding box
        -- so the entity is still solid and useable.
        print("[HQ] Warning: model", self.Model, "has no VPhysics. Using bbox fallback.")
        self:PhysicsInitBox(self:OBBMins(), self:OBBMaxs())
        self:EnableCustomCollisions(true)
        self:SetSolid(SOLID_BBOX)

        local fallbackPhys = self:GetPhysicsObject()
        if IsValid(fallbackPhys) then
            fallbackPhys:EnableMotion(false)
            fallbackPhys:Wake()
        end
    end

    self:SetUseType(SIMPLE_USE)

    if self.Team then
        self:SetTeam(self.Team)
    end
end

function ENT:Use(activator, caller)
    print("[HQ] Use fired by:", activator)

    if not IsValid(activator) or not activator:IsPlayer() then
        print("[HQ] Activator invalid or not a player")
        return
    end

    local character = activator:GetCharacter()
    if not character then
        print("[HQ] No character on activator")
        return
    end

    local hqTeam = self:GetTeam()
    print("[HQ] HQ team:", hqTeam, "| Player faction:", character:GetFaction(), "| Player team:", ix.team.GetTeam(character:GetFaction()))

    if not ix.team.IsOnTeam(character, hqTeam) then
        activator:Notify("This is not your headquarters.")
        return
    end

    activator:Notify("You access the HQ. (Functionality not yet implemented.)")
end

function ENT:OnTakeDamage(dmgInfo)
    return 0
end