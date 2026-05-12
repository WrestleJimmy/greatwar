local PLUGIN = PLUGIN

PLUGIN.name        = "Team Anti-Block"
PLUGIN.author      = "Schema"
PLUGIN.description = "Players on the same team pass through each other with a gentle TF2-style push force."

-- ─────────────────────────────────────────────────────────────
-- Team definitions
-- Values are faction uniqueIDs (the filename stem of the faction
-- file, e.g. "factions/sh_british.lua" → uniqueID "british").
-- ─────────────────────────────────────────────────────────────
local teamMap = {
    axis   = { "german"  },
    allies = { "british" },
}

-- ─────────────────────────────────────────────────────────────
-- Build a lookup: faction index → team name string.
-- Called lazily so it always runs after factions are loaded.
-- ─────────────────────────────────────────────────────────────
local factionTeamCache = {}
local cacheBuilt       = false

local function BuildCache()
    for teamName, factionIDs in pairs(teamMap) do
        for _, uniqueID in ipairs(factionIDs) do
            local index = ix.faction.GetIndex(uniqueID)
            if index then
                factionTeamCache[index] = teamName
            else
                ErrorNoHalt("[AntiBlock] Could not find faction for uniqueID: " .. tostring(uniqueID) .. "\n")
            end
        end
    end
    cacheBuilt = true
end

local function GetTeam(ply)
    if not cacheBuilt then BuildCache() end
    return factionTeamCache[ply:Team()]
end

local function SameTeam(ply1, ply2)
    local t = GetTeam(ply1)
    return t ~= nil and t == GetTeam(ply2)
end

-- ─────────────────────────────────────────────────────────────
-- Server: collision group swapping + soft push
--
-- Why SetCollisionGroup instead of ShouldCollide:
--   Source's player movement system uses its own hull traces that
--   completely bypass ShouldCollide. Setting a player to
--   COLLISION_GROUP_DEBRIS makes movement traces ignore them
--   while they still collide with world geometry normally.
--
-- When a player is near ANY teammate they are flagged as "near".
-- Near  → COLLISION_GROUP_DEBRIS  (teammates pass through)
-- Apart → COLLISION_GROUP_NONE    (normal solid again)
--
-- The activation radius is slightly larger than the push radius
-- so the soft wall disappears before the nudge kicks in.
-- ─────────────────────────────────────────────────────────────
if SERVER then
    local ACTIVATE_RADIUS = 56  -- units — collision group switches at this range
    local PUSH_RADIUS     = 48  -- units — push begins inside this range
    local PUSH_FORCE      = 45  -- units/s at dead-center overlap
    local THINK_RATE      = 0.1

    timer.Create("ixAntiBlockPush", THINK_RATE, 0, function()
        local plys      = player.GetAll()
        local n         = #plys
        local nearFlags = {} -- players currently near a teammate

        for i = 1, n do
            local a = plys[i]
            if not IsValid(a) or not a:Alive() then continue end

            for j = i + 1, n do
                local b = plys[j]
                if not IsValid(b) or not b:Alive() then continue end
                if not SameTeam(a, b) then continue end

                local delta = a:GetPos() - b:GetPos()
                delta.z     = 0
                local dist  = delta:Length()

                if dist < ACTIVATE_RADIUS then
                    nearFlags[a] = true
                    nearFlags[b] = true

                    -- Soft push when close enough
                    if dist < PUSH_RADIUS and dist > 0.5 then
                        local strength = (1 - dist / PUSH_RADIUS) * PUSH_FORCE
                        local dir      = delta:GetNormalized()
                        a:SetVelocity( dir * strength)
                        b:SetVelocity(-dir * strength)
                    end
                end
            end
        end

        -- Apply or restore collision groups
        for i = 1, n do
            local ply = plys[i]
            if not IsValid(ply) then continue end

            if nearFlags[ply] then
                if ply:GetCollisionGroup() ~= COLLISION_GROUP_DEBRIS then
                    ply:SetCollisionGroup(COLLISION_GROUP_DEBRIS)
                end
            else
                if ply:GetCollisionGroup() ~= COLLISION_GROUP_NONE then
                    ply:SetCollisionGroup(COLLISION_GROUP_NONE)
                end
            end
        end
    end)

    -- Restore collision group on death/disconnect so nothing is left broken
    local function RestoreCollision(ply)
        if IsValid(ply) then
            ply:SetCollisionGroup(COLLISION_GROUP_NONE)
        end
    end

    hook.Add("PlayerDeath",        "ixAntiBlockCleanup", RestoreCollision)
    hook.Add("PlayerDisconnected", "ixAntiBlockCleanup", RestoreCollision)
end