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
        -- Model has no VPhysics mesh; fall back to bounding box.
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
    if not IsValid(activator) or not activator:IsPlayer() then return end

    local hqTeam = self:GetTeam()
    if not hqTeam or hqTeam == "" then
        activator:Notify("This headquarters has no team assigned.")
        return
    end

    -- Delegate to the plugin handler which applies access gating + sends panel.
    -- PLUGIN is only set during load scope; look it up at runtime instead.
    local plugin = ix.plugin.list["hq"]
    if plugin and plugin.OnHQUsed then
        plugin:OnHQUsed(activator, hqTeam)
    else
        -- Fallback: scan list in case the folder key differs.
        for _, p in pairs(ix.plugin.list) do
            if p.OnHQUsed then
                p:OnHQUsed(activator, hqTeam)
                break
            end
        end
    end
end

function ENT:OnTakeDamage(dmgInfo)
    return 0  -- indestructible
end