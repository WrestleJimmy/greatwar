PLUGIN.name = "HQ Entities"
PLUGIN.author = "Schema"
PLUGIN.description = "Faction headquarters entities for the trench warfare gamemode."

-- Team system
--
-- Teams group multiple factions under a single side. The HQ entities (and
-- later: spawns, objectives, drop points) belong to a TEAM, not a faction
-- directly. This means players from any faction in a team can use that
-- team's HQ.
--
-- To add a new faction (e.g. French) to an existing team, just add it to
-- the team's faction list below. No other code changes needed.

TEAM_AXIS   = "axis"
TEAM_ALLIES = "allies"

-- Team -> list of factions in that team.
ix.team = ix.team or {}
ix.team.factions = {
    [TEAM_AXIS]   = { FACTION_GERMAN },
    [TEAM_ALLIES] = { FACTION_BRITISH }
    -- When you add French: [TEAM_ALLIES] = { FACTION_BRITISH, FACTION_FRENCH }
}

-- Returns the team a given faction belongs to, or nil if it doesn't belong
-- to any team.
function ix.team.GetTeam(faction)
    for team, factions in pairs(ix.team.factions) do
        for _, f in ipairs(factions) do
            if f == faction then
                return team
            end
        end
    end
    return nil
end

-- Returns true if the given character is on the given team.
function ix.team.IsOnTeam(character, team)
    if not character then return false end
    return ix.team.GetTeam(character:GetFaction()) == team
end

-- Returns true if two characters are on the same team.
function ix.team.SameTeam(charA, charB)
    if not charA or not charB then return false end
    local teamA = ix.team.GetTeam(charA:GetFaction())
    local teamB = ix.team.GetTeam(charB:GetFaction())
    return teamA ~= nil and teamA == teamB
end
