PLUGIN.name = "Drop Point System"
PLUGIN.author = "Schema"
PLUGIN.description = "Forward drop points where uniforms are deposited for the team."

print("[DROP] sh_plugin.lua loaded on", SERVER and "SERVER" or "CLIENT")

-- Stockpile max sizes. Currently only uniforms are tracked.
-- Add ammo / medical maxes here later when we wire those up.
DROP_MAX_UNIFORMS = 10

-- Drop point registry: ix.dropPoint.entities[team] = entity
-- One drop point per team. If multiple exist, the most recently registered
-- wins. We can revisit this later if we want distributed drop points.
ix.dropPoint = ix.dropPoint or {}
ix.dropPoint.entities = ix.dropPoint.entities or {}

function ix.dropPoint.Register(ent, team)
    ix.dropPoint.entities[team] = ent
    print("[DROP] Registered drop point", ent, "for team:", team)
end

function ix.dropPoint.Unregister(ent)
    for team, e in pairs(ix.dropPoint.entities) do
        if e == ent then
            ix.dropPoint.entities[team] = nil
            return
        end
    end
end

-- Returns the drop point entity for a team, or nil if none placed.
function ix.dropPoint.GetForTeam(team)
    return ix.dropPoint.entities[team]
end

-- Adds N uniforms to the team's stockpile. Caps at the max.
-- Returns the number actually added (0 if no drop point or already full).
function ix.dropPoint.AddUniforms(team, amount)
    local ent = ix.dropPoint.GetForTeam(team)
    if not IsValid(ent) then return 0 end

    local current = ent:GetUniforms()
    local space = DROP_MAX_UNIFORMS - current
    if space <= 0 then return 0 end

    local added = math.min(amount, space)
    ent:SetUniforms(current + added)
    return added
end

-- Consumes one uniform from the team's stockpile.
-- Returns true if successful, false if stockpile empty or no drop point.
function ix.dropPoint.ConsumeUniform(team)
    local ent = ix.dropPoint.GetForTeam(team)
    if not IsValid(ent) then return false end

    local current = ent:GetUniforms()
    if current <= 0 then return false end

    ent:SetUniforms(current - 1)
    return true
end

ix.util.Include("sv_plugin.lua", "server")
ix.util.Include("cl_plugin.lua", "client")
