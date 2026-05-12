print("[SPAWN] sv_plugin.lua loaded")

local PLUGIN = PLUGIN

-- =====================================================================
-- Respawn handling
-- =====================================================================
PLUGIN.deadPlayers = PLUGIN.deadPlayers or {}

local function GetSpawnTime()
    return ix.config.Get("spawnTime", 5)
end

local function IsSpawnClass(class)
    return class == "ix_spawn_forward_axis"
        or class == "ix_spawn_reserve_axis"
        or class == "ix_spawn_forward_allies"
        or class == "ix_spawn_reserve_allies"
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

-- The client now sends the entity index of the *specific* spawn it picked,
-- so the player ends up at the spawn they selected on the death screen
-- rather than a random spawn of that type.
net.Receive("ixSpawnChoice", function(len, client)
    local entIndex = net.ReadUInt(16)

    if not IsValid(client) or client:Alive() then return end

    local state = PLUGIN.deadPlayers[client:SteamID()]
    if not state then return end

    if CurTime() - state.time < GetSpawnTime() then
        client:Notify("You cannot respawn yet.")
        return
    end

    local spawnEnt = Entity(entIndex)
    if not IsValid(spawnEnt) or not IsSpawnClass(spawnEnt:GetClass()) then
        client:Notify("Invalid spawn selection.")
        return
    end

    local character = client:GetCharacter()
    if not character then return end

    local team = ix.team.GetTeam(character:GetFaction())
    if not team then
        client:Notify("Your faction has no team assigned.")
        return
    end

    if spawnEnt:GetTeam() ~= team then
        client:Notify("That spawn doesn't belong to your team.")
        return
    end

    local spawnType = spawnEnt:GetSpawnType()

    if spawnType == SPAWN_FORWARD then
        local consumed = ix.dropPoint and ix.dropPoint.ConsumeUniform(team)
        if not consumed then
            client:Notify("No uniforms available at the drop point.")
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
-- File format on disk (JSON):
--   { [mapName] = { [posKey] = {
--       pos      = [x, y, z],
--       angles   = [pitch, yaw, roll],
--       fov      = number,
--       team     = string,
--       spawnType= string,
--   } } }
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

    -- Reconstruct vectors and angles. Tolerates and discards any older shapes
    -- (the previous overhead-map format used `center`/`viewSpan`); admins
    -- will need to re-run /SpawnviewSet after upgrading.
    for mapName, mapEntry in pairs(decoded) do
        for posKey, cfg in pairs(mapEntry) do
            if type(cfg) ~= "table" or not cfg.pos then
                print(string.format("[SPAWN] Discarding legacy entry %s/%s.", mapName, tostring(posKey)))
                mapEntry[posKey] = nil
            else
                if type(cfg.pos) == "table" then
                    cfg.pos = Vector(
                        cfg.pos[1] or cfg.pos.x or 0,
                        cfg.pos[2] or cfg.pos.y or 0,
                        cfg.pos[3] or cfg.pos.z or 0
                    )
                end
                if cfg.angles and type(cfg.angles) == "table" then
                    cfg.angles = Angle(
                        cfg.angles[1] or cfg.angles.p or 0,
                        cfg.angles[2] or cfg.angles.y or 0,
                        cfg.angles[3] or cfg.angles.r or 0
                    )
                else
                    cfg.angles = Angle(0, 0, 0)
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
        for posKey, cfg in pairs(mapEntry) do
            local posArr, angArr
            if cfg.pos then
                posArr = { cfg.pos.x, cfg.pos.y, cfg.pos.z }
            end
            if cfg.angles then
                angArr = { cfg.angles.p, cfg.angles.y, cfg.angles.r }
            end
            serializable[mapName][posKey] = {
                pos       = posArr,
                angles    = angArr,
                fov       = cfg.fov,
                team      = cfg.team,
                spawnType = cfg.spawnType,
            }
        end
    end

    file.Write(SAVE_FILE, util.TableToJSON(serializable, true))
end

-- Set/update the camera config linked to a specific spawn entity. Any of
-- `pos`, `angles`, `fov` may be nil to leave that field unchanged.
function ix.spawnView.Set(spawnEnt, pos, angles, fov)
    if not IsValid(spawnEnt) then return end

    local mapName = game.GetMap()
    local key     = ix.spawnView.PosKey(spawnEnt:GetPos())

    ix.spawnView.config[mapName] = ix.spawnView.config[mapName] or {}
    local existing = ix.spawnView.config[mapName][key] or {}

    ix.spawnView.config[mapName][key] = {
        pos       = pos    or existing.pos,
        angles    = angles or existing.angles or Angle(0, 0, 0),
        fov       = fov    or existing.fov    or ix.spawnView.DEFAULT_FOV,
        team      = spawnEnt:GetTeam(),
        spawnType = spawnEnt:GetSpawnType(),
    }

    SaveSpawnViewConfig()
end

function ix.spawnView.Clear(spawnEnt)
    if not IsValid(spawnEnt) then return false end

    local mapName  = game.GetMap()
    local mapEntry = ix.spawnView.config[mapName]
    if not mapEntry then return false end

    local key = ix.spawnView.PosKey(spawnEnt:GetPos())
    if mapEntry[key] then
        mapEntry[key] = nil
        SaveSpawnViewConfig()
        return true
    end
    return false
end

local function SyncSpawnViewToPlayer(client)
    local mapName   = game.GetMap()
    local mapConfig = ix.spawnView.config[mapName] or {}

    local serializable = {}
    for posKey, cfg in pairs(mapConfig) do
        serializable[posKey] = {
            pos       = cfg.pos    and { cfg.pos.x, cfg.pos.y, cfg.pos.z } or nil,
            angles    = cfg.angles and { cfg.angles.p, cfg.angles.y, cfg.angles.r } or nil,
            fov       = cfg.fov,
            team      = cfg.team,
            spawnType = cfg.spawnType,
        }
    end

    net.Start("ixSpawnViewSync")
        net.WriteTable(serializable)
    net.Send(client)
end

-- Exposed on ix.spawnView so commands in sh_plugin.lua can call it.
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