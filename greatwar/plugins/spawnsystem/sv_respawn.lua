-- Server-side respawn handling with debug prints to diagnose issues.

print("[SPAWN] sv_respawn.lua loaded")

PLUGIN.deadPlayers = PLUGIN.deadPlayers or {}

local function GetSpawnTime()
    return ix.config.Get("spawnTime", 5)
end

-- Block default respawn behavior.
function PLUGIN:PlayerDeathThink(client)
    print("[SPAWN] PlayerDeathThink fired for", client)
    return false
end

function PLUGIN:DoPlayerDeath(client, attacker, dmgInfo)
    print("[SPAWN] DoPlayerDeath fired for", client)
    PLUGIN.deadPlayers[client:SteamID()] = {
        time = CurTime(),
        chosen = nil
    }
end

-- Hook into the standard PlayerDeath gmod hook as a backup.
hook.Add("PlayerDeath", "ixSpawnPlayerDeath", function(victim, inflictor, attacker)
    print("[SPAWN] PlayerDeath gmod hook fired for", victim)
    if IsValid(victim) and victim:IsPlayer() then
        PLUGIN.deadPlayers[victim:SteamID()] = {
            time = CurTime(),
            chosen = nil
        }
    end
end)

-- Backup respawn blocker using the standard gmod hook.
hook.Add("PlayerDeathThink", "ixSpawnDeathThink", function(client)
    return false
end)

function PLUGIN:PlayerDisconnected(client)
    PLUGIN.deadPlayers[client:SteamID()] = nil
end

-- Handle the spawn choice from the client.
net.Receive("ixSpawnChoice", function(len, client)
    print("[SPAWN] ixSpawnChoice received from", client)

    local spawnType = net.ReadString()
    print("[SPAWN] Spawn type chosen:", spawnType)

    if not IsValid(client) or client:Alive() then
        print("[SPAWN] Client invalid or already alive")
        return
    end

    local state = PLUGIN.deadPlayers[client:SteamID()]
    if not state then
        print("[SPAWN] No death state for client")
        return
    end

    if CurTime() - state.time < GetSpawnTime() then
        print("[SPAWN] Spawn timer not elapsed")
        client:Notify("You cannot respawn yet.")
        return
    end

    if spawnType ~= SPAWN_FORWARD and spawnType ~= SPAWN_RESERVE then
        print("[SPAWN] Invalid spawn type")
        return
    end

    local character = client:GetCharacter()
    if not character then
        print("[SPAWN] No character on client")
        return
    end

    local team = ix.team.GetTeam(character:GetFaction())
    print("[SPAWN] Player team:", team)

    if not team then
        client:Notify("Your faction has no team assigned.")
        return
    end

    local spawnEnt = ix.spawn.PickRandom(team, spawnType)
    print("[SPAWN] Picked spawn entity:", spawnEnt)

    if not spawnEnt and spawnType == SPAWN_FORWARD then
        spawnEnt = ix.spawn.PickRandom(team, SPAWN_RESERVE)
        if spawnEnt then
            client:Notify("No forward spawn available. Spawning at reserve.")
        end
    end

    if not spawnEnt then
        client:Notify("No spawn point available for your team.")
        return
    end

    state.chosen = spawnType
    PLUGIN.deadPlayers[client:SteamID()] = nil

    client:Spawn()
    client:SetPos(spawnEnt:GetPos() + Vector(0, 0, 16))
    client:SetEyeAngles(spawnEnt:GetAngles())
end)