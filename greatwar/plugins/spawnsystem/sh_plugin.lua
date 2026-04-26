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

-- =====================================================================
-- Spawn view (camera) registry
-- =====================================================================
-- Maps a (mapName, team, spawnType) -> { center = Vector, viewSpan = number }.
-- viewSpan is the number of world units shown across the longer screen
-- dimension when this camera is active.
--
-- The server loads/saves this to data/ix_spawnview.txt (JSON) and
-- broadcasts the current map's config to clients on join.

ix.spawnView = ix.spawnView or {}
ix.spawnView.config = ix.spawnView.config or {}
ix.spawnView.DEFAULT_VIEW_SPAN = 2500

-- Returns the camera config for a (team, spawnType) on the current map,
-- or nil if not configured.
function ix.spawnView.Get(team, spawnType)
    local mapEntry = ix.spawnView.config[game.GetMap()]
    if not mapEntry then return nil end

    local teamEntry = mapEntry[team]
    if not teamEntry then return nil end

    return teamEntry[spawnType]
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
-- Registered shared so the client autocomplete and permission system
-- know about them. OnRun fires server-side regardless.

local function GetCallerTeam(client)
    local character = client:GetCharacter()
    if not character then return nil end
    return ix.team.GetTeam(character:GetFaction())
end

do
    local COMMAND = {}
    COMMAND.description = "Save your current standing position as the camera center for a spawn (forward or reserve) on this map for your team."
    COMMAND.arguments = { ix.type.string }
    COMMAND.adminOnly = true

    function COMMAND:OnRun(client, spawnType)
        spawnType = string.lower(spawnType)
        if spawnType ~= SPAWN_FORWARD and spawnType ~= SPAWN_RESERVE then
            return "Specify 'forward' or 'reserve'."
        end

        local team = GetCallerTeam(client)
        if not team then
            return "You are not on a team."
        end

        ix.spawnView.Set(team, spawnType, client:GetPos(), nil)

        if ix.spawnView.SyncBroadcast then
            ix.spawnView.SyncBroadcast()
        end

        local cfg = ix.spawnView.Get(team, spawnType)
        client:Notify(string.format(
            "Saved %s camera for team %s on %s. View span: %d.",
            spawnType, team, game.GetMap(), cfg.viewSpan or 0
        ))
    end

    ix.command.Add("SpawnviewSet", COMMAND)
end

do
    local COMMAND = {}
    COMMAND.description = "Set the view span (world units across longer screen dimension) for a spawn camera."
    COMMAND.arguments = { ix.type.string, ix.type.number }
    COMMAND.adminOnly = true

    function COMMAND:OnRun(client, spawnType, viewSpan)
        spawnType = string.lower(spawnType)
        if spawnType ~= SPAWN_FORWARD and spawnType ~= SPAWN_RESERVE then
            return "Specify 'forward' or 'reserve'."
        end

        if viewSpan < 100 or viewSpan > 50000 then
            return "View span must be between 100 and 50000."
        end

        local team = GetCallerTeam(client)
        if not team then
            return "You are not on a team."
        end

        ix.spawnView.Set(team, spawnType, nil, viewSpan)

        if ix.spawnView.SyncBroadcast then
            ix.spawnView.SyncBroadcast()
        end

        client:Notify(string.format(
            "Set %s camera view span to %d for team %s on %s.",
            spawnType, viewSpan, team, game.GetMap()
        ))
    end

    ix.command.Add("SpawnviewSpan", COMMAND)
end

do
    local COMMAND = {}
    COMMAND.description = "Print the current camera config for this map and your team."
    COMMAND.arguments = {}
    COMMAND.adminOnly = true

    function COMMAND:OnRun(client)
        local team = GetCallerTeam(client)
        if not team then
            return "You are not on a team."
        end

        local mapName = game.GetMap()
        local mapEntry = ix.spawnView.config[mapName] or {}
        local teamEntry = mapEntry[team] or {}

        local lines = { string.format("Spawnview config for %s, team %s:", mapName, team) }
        local count = 0
        for spawnType, cfg in pairs(teamEntry) do
            count = count + 1
            local center = cfg.center
            local centerStr = center and string.format("(%.0f, %.0f, %.0f)", center.x, center.y, center.z) or "nil"
            table.insert(lines, string.format("  %s: center=%s span=%s",
                spawnType, centerStr, tostring(cfg.viewSpan)))
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