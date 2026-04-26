print("[SPAWN] sv_plugin.lua loaded")

local PLUGIN = PLUGIN

-- =====================================================================
-- Respawn handling
-- =====================================================================
PLUGIN.deadPlayers = PLUGIN.deadPlayers or {}

local function GetSpawnTime()
    return ix.config.Get("spawnTime", 5)
end

hook.Add("PlayerDeathThink", "ixSpawnDeathThink", function(client)
    return false
end)

hook.Add("PlayerDeath", "ixSpawnPlayerDeath", function(victim, inflictor, attacker)
    if IsValid(victim) and victim:IsPlayer() then
        PLUGIN.deadPlayers[victim:SteamID()] = {
            time = CurTime(),
            chosen = nil
        }
    end
end)

hook.Add("PlayerDisconnected", "ixSpawnPlayerDisconnected", function(client)
    if IsValid(client) then
        PLUGIN.deadPlayers[client:SteamID()] = nil
    end
end)

net.Receive("ixSpawnChoice", function(len, client)
    local spawnType = net.ReadString()

    if not IsValid(client) or client:Alive() then return end

    local state = PLUGIN.deadPlayers[client:SteamID()]
    if not state then return end

    if CurTime() - state.time < GetSpawnTime() then
        client:Notify("You cannot respawn yet.")
        return
    end

    if spawnType ~= SPAWN_FORWARD and spawnType ~= SPAWN_RESERVE then
        return
    end

    local character = client:GetCharacter()
    if not character then return end

    local team = ix.team.GetTeam(character:GetFaction())
    if not team then
        client:Notify("Your faction has no team assigned.")
        return
    end

    local spawnEnt

    if spawnType == SPAWN_FORWARD then
        local consumed = ix.dropPoint and ix.dropPoint.ConsumeUniform(team)

        if not consumed then
            client:Notify("No uniforms available at the drop point.")
            return
        end

        spawnEnt = ix.spawn.PickRandom(team, SPAWN_FORWARD)

        if not spawnEnt then
            ix.dropPoint.AddUniforms(team, 1)
            client:Notify("No forward spawn placed for your team.")
            return
        end
    else
        spawnEnt = ix.spawn.PickRandom(team, SPAWN_RESERVE)

        if not spawnEnt then
            client:Notify("No reserve spawn placed for your team.")
            return
        end
    end

    state.chosen = spawnType
    PLUGIN.deadPlayers[client:SteamID()] = nil

    client:Spawn()
    client:SetPos(spawnEnt:GetPos() + Vector(0, 0, 16))
    client:SetEyeAngles(spawnEnt:GetAngles())
end)

-- =====================================================================
-- Spawn view persistence
-- =====================================================================
local SAVE_FILE = "ix_spawnview.txt"

local function LoadSpawnViewConfig()
    if not file.Exists(SAVE_FILE, "DATA") then
        ix.spawnView.config = {}
        return
    end

    local raw = file.Read(SAVE_FILE, "DATA")
    if not raw or raw == "" then
        ix.spawnView.config = {}
        return
    end

    local decoded = util.JSONToTable(raw)
    if not decoded then
        print("[SPAWN] Could not decode spawnview config; starting empty.")
        ix.spawnView.config = {}
        return
    end

    -- Reconstruct vectors from JSON arrays.
    for mapName, mapEntry in pairs(decoded) do
        for team, teamEntry in pairs(mapEntry) do
            for spawnType, cfg in pairs(teamEntry) do
                if cfg.center and type(cfg.center) == "table" then
                    cfg.center = Vector(cfg.center[1] or cfg.center.x or 0,
                                        cfg.center[2] or cfg.center.y or 0,
                                        cfg.center[3] or cfg.center.z or 0)
                end
            end
        end
    end

    ix.spawnView.config = decoded
    print("[SPAWN] Loaded spawnview config from disk.")
end

local function SaveSpawnViewConfig()
    local serializable = {}
    for mapName, mapEntry in pairs(ix.spawnView.config) do
        serializable[mapName] = {}
        for team, teamEntry in pairs(mapEntry) do
            serializable[mapName][team] = {}
            for spawnType, cfg in pairs(teamEntry) do
                local centerArr
                if cfg.center then
                    centerArr = { cfg.center.x, cfg.center.y, cfg.center.z }
                end
                serializable[mapName][team][spawnType] = {
                    center = centerArr,
                    viewSpan = cfg.viewSpan
                }
            end
        end
    end

    file.Write(SAVE_FILE, util.TableToJSON(serializable, true))
end

function ix.spawnView.Set(team, spawnType, center, viewSpan)
    local mapName = game.GetMap()

    ix.spawnView.config[mapName] = ix.spawnView.config[mapName] or {}
    ix.spawnView.config[mapName][team] = ix.spawnView.config[mapName][team] or {}

    local existing = ix.spawnView.config[mapName][team][spawnType] or {}
    ix.spawnView.config[mapName][team][spawnType] = {
        center = center or existing.center,
        viewSpan = viewSpan or existing.viewSpan or ix.spawnView.DEFAULT_VIEW_SPAN
    }

    SaveSpawnViewConfig()
end

local function SyncSpawnViewToPlayer(client)
    local mapName = game.GetMap()
    local mapConfig = ix.spawnView.config[mapName] or {}

    local serializable = {}
    for team, teamEntry in pairs(mapConfig) do
        serializable[team] = {}
        for spawnType, cfg in pairs(teamEntry) do
            serializable[team][spawnType] = {
                center = cfg.center and { cfg.center.x, cfg.center.y, cfg.center.z } or nil,
                viewSpan = cfg.viewSpan
            }
        end
    end

    net.Start("ixSpawnViewSync")
        net.WriteTable(serializable)
    net.Send(client)
end

-- Exposed on ix.spawnView so commands in sh_commands.lua can call it.
function ix.spawnView.SyncBroadcast()
    for _, client in ipairs(player.GetAll()) do
        SyncSpawnViewToPlayer(client)
    end
end

hook.Add("PlayerInitialSpawn", "ixSpawnViewSync", function(client)
    timer.Simple(2, function()
        if IsValid(client) then
            SyncSpawnViewToPlayer(client)
        end
    end)
end)

LoadSpawnViewConfig()