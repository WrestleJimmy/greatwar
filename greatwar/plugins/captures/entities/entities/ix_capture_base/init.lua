AddCSLuaFile("shared.lua")
AddCSLuaFile("cl_init.lua")
include("shared.lua")

function ENT:Initialize()
    self:SetModel(self.Model)
    self:PhysicsInit(SOLID_VPHYSICS)
    self:SetMoveType(MOVETYPE_NONE)
    self:SetSolid(SOLID_VPHYSICS)

    -- Fallback for static-folder models that lack a .phy mesh
    local phys = self:GetPhysicsObject()
    if (not IsValid(phys)) then
        self:PhysicsInitBox(self:OBBMins(), self:OBBMaxs())
        self:EnableCustomCollisions(true)
        phys = self:GetPhysicsObject()
    end
    if (IsValid(phys)) then
        phys:EnableMotion(false)
        phys:Sleep()
    end

    -- Defaults / sensible fallbacks
    self:SetTeam(self.Team or "axis")
    self:SetSectorID("A")
    self:SetSlotID("1")
    self:SetProgress(0)
    self:SetCapturingTeam("")
    self:SetContested(false)
    self:SetLocked(false)

    if (ix.capture and ix.capture.Register) then
        ix.capture.Register(self)
    end

    self:NextThink(CurTime() + ix.capture.THINK_INTERVAL)
end

function ENT:Think()
    -- Lazy lookup: PLUGIN list is populated by the time Think fires.
    local plugin = ix.plugin.list and ix.plugin.list["captures"]
    if (plugin and plugin.UpdateCapturePoint) then
        plugin:UpdateCapturePoint(self, ix.capture.THINK_INTERVAL)
    end
    self:NextThink(CurTime() + ix.capture.THINK_INTERVAL)
    return true
end

function ENT:OnTakeDamage(dmg)
    return 0
end

function ENT:OnRemove()
    if (ix.capture and ix.capture.Unregister) then
        ix.capture.Unregister(self)
    end
end
