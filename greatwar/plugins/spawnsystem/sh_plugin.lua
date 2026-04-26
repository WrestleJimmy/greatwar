PLUGIN.name = "Spawn System"
PLUGIN.author = "Schema"
PLUGIN.description = "Team-based spawn point entities and respawn handling."

print("[SPAWN] sh_plugin.lua loaded on", SERVER and "SERVER" or "CLIENT")

if SERVER then
    AddCSLuaFile("cl_deathscreen.lua")
    util.AddNetworkString("ixSpawnChoice")
end

-- Spawn type constants
SPAWN_FORWARD = "forward"
SPAWN_RESERVE = "reserve"

-- Track spawn entities by team and type so we can look them up fast.
ix.spawn = ix.spawn or {}
ix.spawn.entities = ix.spawn.entities or {}

function ix.spawn.Register(ent, team, spawnType)
    ix.spawn.entities[team] = ix.spawn.entities[team] or {}
    ix.spawn.entities[team][spawnType] = ix.spawn.entities[team][spawnType] or {}
    table.insert(ix.spawn.entities[team][spawnType], ent)
    print("[SPAWN] Registered entity", ent, "team:", team, "type:", spawnType)
end

function ix.spawn.Unregister(ent)
    for team, types in pairs(ix.spawn.entities) do
        for spawnType, list in pairs(types) do
            for i, e in ipairs(list) do
                if e == ent then
                    table.remove(list, i)
                    return
                end
            end
        end
    end
end

function ix.spawn.Get(team, spawnType)
    if not ix.spawn.entities[team] then return {} end
    return ix.spawn.entities[team][spawnType] or {}
end

function ix.spawn.PickRandom(team, spawnType)
    local list = ix.spawn.Get(team, spawnType)
    if #list == 0 then return nil end
    return list[math.random(#list)]
end