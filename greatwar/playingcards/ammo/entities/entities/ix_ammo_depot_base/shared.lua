ENT.Type            = "anim"
ENT.PrintName       = "Ammo Depot"
ENT.Author          = "greatwar"
ENT.Category        = "Great War"
ENT.Spawnable       = false   -- spawned via the team-specific subclasses
ENT.AdminSpawnable  = false

-- Subclasses override this. Used to gate Use access and to determine
-- which faction's three ammo classes this depot holds.
ENT.Team = nil   -- "axis" | "allies"

-- Capacity caps come from the shared config so admins can tune them
-- without touching entity code.
local DEFAULT_CAP = 20
local function CapFor(class)
    if ix.ammoSystem and ix.ammoSystem.DEPOT_CAPS then
        return ix.ammoSystem.DEPOT_CAPS[class] or DEFAULT_CAP
    end
    return DEFAULT_CAP
end

-- =====================================================================
-- Networked vars
-- =====================================================================
-- Three counts per depot (this team's pistol/bolt/MG only). Every
-- player on the matching team sees the same numbers; opposite team
-- sees the entity but doesn't read these (we don't gate on the network
-- layer — gating happens at Use time).
function ENT:SetupDataTables()
    self:NetworkVar("Int", 0, "PistolCount")
    self:NetworkVar("Int", 1, "BoltCount")
    self:NetworkVar("Int", 2, "MgCount")
end

-- Convenience accessor — returns count for a class string.
function ENT:GetCountFor(class)
    if class == "pistol" then return self:GetPistolCount() end
    if class == "bolt"   then return self:GetBoltCount()   end
    if class == "mg"     then return self:GetMgCount()     end
    return 0
end

-- Convenience setter — server only.
function ENT:SetCountFor(class, value)
    value = math.Clamp(math.floor(value or 0), 0, CapFor(class))
    if class == "pistol" then self:SetPistolCount(value) end
    if class == "bolt"   then self:SetBoltCount(value)   end
    if class == "mg"     then self:SetMgCount(value)     end
end

-- Capacity exposed to client for UI math.
function ENT:GetCapFor(class)
    return CapFor(class)
end
