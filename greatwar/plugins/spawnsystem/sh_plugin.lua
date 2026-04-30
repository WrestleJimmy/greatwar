PLUGIN.name = "Spawn System"
PLUGIN.author = "Schema"
PLUGIN.description = "Team-based spawn point entities and respawn handling."

print("[SPAWN] sh_plugin.lua loaded on", SERVER and "SERVER" or "CLIENT")

-- =====================================================================
-- Spawn type constants
-- =====================================================================
SPAWN_FORWARD = "forward"
SPAWN_RESERVE = "reserve"

-- =====================================================================
-- Spawn lookup registry
-- =====================================================================
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

function ix.spawn.GetAllForTeam(team)
    local out = {}
    if not ix.spawn.entities[team] then return out end
    for _, list in pairs(ix.spawn.entities[team]) do
        for _, ent in ipairs(list) do
            if IsValid(ent) then
                table.insert(out, ent)
            end
        end
    end
    return out
end

-- Find the spawn entity nearest to `pos`. Returns ent, distance.
function ix.spawn.FindNearest(pos, maxDist)
    local nearest, nearestDist
    for team, types in pairs(ix.spawn.entities) do
        for spawnType, list in pairs(types) do
            for _, ent in ipairs(list) do
                if not IsValid(ent) then continue end
                local d = ent:GetPos():Distance(pos)
                if (not maxDist or d <= maxDist) and (not nearestDist or d < nearestDist) then
                    nearest = ent
                    nearestDist = d
                end
            end
        end
    end
    return nearest, nearestDist
end

-- =====================================================================
-- Spawn view (camera) registry
-- =====================================================================
-- Cameras are keyed per spawn entity by world position. Each camera now
-- stores a first-person-style view: position + look angles + FOV. This is
-- the same shape Helix's mapscene system uses, so /SpawnviewSet behaves
-- like /mapsceneadd.
--
-- ix.spawnView.config[mapName][posKey] = {
--     pos       = Vector,  -- camera world position
--     angles    = Angle,   -- camera look direction (pitch, yaw, roll)
--     fov       = number,  -- field of view in degrees
--     team      = string,  -- copied from the spawn ent (for /SpawnviewShow)
--     spawnType = string,  -- copied from the spawn ent (for /SpawnviewShow)
-- }

ix.spawnView = ix.spawnView or {}
ix.spawnView.config = ix.spawnView.config or {}
ix.spawnView.DEFAULT_FOV = 75

-- The camera the death screen wants the engine to render from. Set by the
-- client-side panel; read by the CalcView hook. nil when no death screen
-- is active.
ix.spawnView.activeViewCamera = nil

-- Build a stable key from a Vector. Rounded so tiny floating-point drift
-- between save/load doesn't break lookups.
function ix.spawnView.PosKey(pos)
    return string.format("%d,%d,%d",
        math.Round(pos.x), math.Round(pos.y), math.Round(pos.z))
end

-- Returns the camera config for a specific spawn entity, or nil.
function ix.spawnView.GetForEntity(ent)
    if not IsValid(ent) then return nil end
    local mapEntry = ix.spawnView.config[game.GetMap()]
    if not mapEntry then return nil end
    return mapEntry[ix.spawnView.PosKey(ent:GetPos())]
end

-- Network strings registered on server only.
if SERVER then
    util.AddNetworkString("ixSpawnChoice")
    util.AddNetworkString("ixSpawnViewSync")
end

-- =====================================================================
-- Realm-specific files
-- =====================================================================
ix.util.Include("sv_plugin.lua", "server")
ix.util.Include("cl_plugin.lua", "client")

-- =====================================================================
-- Admin commands
-- =====================================================================
local SPAWN_LINK_RANGE = 4096 -- max distance from admin to a spawn ent for linking

do
    local COMMAND = {}
    COMMAND.description = "Save your current eye position and view angles as the spawn-camera for the spawn entity nearest to you. Stand where you want the camera, look the way you want it to point, then run."
    COMMAND.arguments = {}
    COMMAND.adminOnly = true

    function COMMAND:OnRun(client)
        local nearest, dist = ix.spawn.FindNearest(client:GetPos(), SPAWN_LINK_RANGE)
        if not nearest then
            return string.format("No spawn entity within %d units. Place a spawn first or move closer to one.", SPAWN_LINK_RANGE)
        end

        local camPos = client:EyePos()
        local camAng = client:EyeAngles()

        ix.spawnView.Set(nearest, camPos, camAng, nil)

        if ix.spawnView.SyncBroadcast then
            ix.spawnView.SyncBroadcast()
        end

        local cfg = ix.spawnView.GetForEntity(nearest)
        client:Notify(string.format(
            "Linked camera to %s spawn (%s, %s) %d units away. FOV: %d. Use /SpawnviewFov to adjust.",
            nearest:GetSpawnType(), nearest:GetTeam(), nearest:GetClass(), math.Round(dist),
            cfg and cfg.fov or 0
        ))
    end

    ix.command.Add("SpawnviewSet", COMMAND)
end

do
    local COMMAND = {}
    COMMAND.description = "Set the FOV (in degrees) for the camera linked to the spawn entity nearest you."
    COMMAND.arguments = { ix.type.number }
    COMMAND.adminOnly = true

    function COMMAND:OnRun(client, fov)
        if fov < 10 or fov > 170 then
            return "FOV must be between 10 and 170."
        end

        local nearest, dist = ix.spawn.FindNearest(client:GetPos(), SPAWN_LINK_RANGE)
        if not nearest then
            return string.format("No spawn entity within %d units.", SPAWN_LINK_RANGE)
        end

        local cfg = ix.spawnView.GetForEntity(nearest)
        if not cfg or not cfg.pos then
            return "That spawn has no camera linked yet. Run /SpawnviewSet first."
        end

        ix.spawnView.Set(nearest, nil, nil, fov)

        if ix.spawnView.SyncBroadcast then
            ix.spawnView.SyncBroadcast()
        end

        client:Notify(string.format(
            "Set camera FOV to %d for %s %s spawn.",
            fov, nearest:GetTeam(), nearest:GetSpawnType()
        ))
    end

    ix.command.Add("SpawnviewFov", COMMAND)
end

do
    local COMMAND = {}
    COMMAND.description = "Print every camera-linked spawn on this map."
    COMMAND.arguments = {}
    COMMAND.adminOnly = true

    function COMMAND:OnRun(client)
        local mapName = game.GetMap()
        local mapEntry = ix.spawnView.config[mapName] or {}

        local lines = { string.format("Spawnview config for %s:", mapName) }
        local count = 0
        for posKey, cfg in pairs(mapEntry) do
            count = count + 1
            local pos = cfg.pos
            local ang = cfg.angles
            local posStr = pos
                and string.format("(%.0f, %.0f, %.0f)", pos.x, pos.y, pos.z)
                or "nil"
            local angStr = ang
                and string.format("p=%.0f y=%.0f r=%.0f", ang.p or 0, ang.y or 0, ang.r or 0)
                or "nil"
            table.insert(lines, string.format("  spawn@%s [%s/%s] camera=%s ang=%s fov=%s",
                posKey,
                tostring(cfg.team or "?"),
                tostring(cfg.spawnType or "?"),
                posStr, angStr,
                tostring(cfg.fov)))
        end

        if count == 0 then
            table.insert(lines, "  (no entries)")
        end

        for _, line in ipairs(lines) do
            client:ChatPrint(line)
        end
    end

    ix.command.Add("SpawnviewShow", COMMAND)
end

do
    local COMMAND = {}
    COMMAND.description = "Remove the camera linked to the spawn entity nearest you."
    COMMAND.arguments = {}
    COMMAND.adminOnly = true

    function COMMAND:OnRun(client)
        local nearest, dist = ix.spawn.FindNearest(client:GetPos(), SPAWN_LINK_RANGE)
        if not nearest then
            return string.format("No spawn entity within %d units.", SPAWN_LINK_RANGE)
        end

        if ix.spawnView.Clear and ix.spawnView.Clear(nearest) then
            if ix.spawnView.SyncBroadcast then
                ix.spawnView.SyncBroadcast()
            end
            client:Notify(string.format(
                "Cleared camera for %s %s spawn.",
                nearest:GetTeam(), nearest:GetSpawnType()
            ))
        else
            client:Notify("That spawn had no camera linked.")
        end
    end

    ix.command.Add("SpawnviewClear", COMMAND)
end