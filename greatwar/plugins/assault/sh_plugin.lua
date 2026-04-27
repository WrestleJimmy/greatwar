PLUGIN.name = "Assault Orchestrator"
PLUGIN.author = "WrestleJimmy"
PLUGIN.description = "Listens to capture point events and manages sector state. When a sector falls, it disables that sector's defender forward spawns. Acts as the middleman between captures and spawnsystem; neither plugin reads the other's state directly."

-- ============================================================
-- Sector state registry
--
-- ix.assault.fallen[teamThatLost][sectorID] = true
--
-- Keyed by the team that LOST the sector. When axis loses sector A,
-- ix.assault.fallen.axis.A = true. The spawn system checks this when
-- filtering forward spawns for the death screen and when validating
-- a respawn choice.
-- ============================================================

ix.assault = ix.assault or {}
ix.assault.fallen = ix.assault.fallen or { axis = {}, allies = {} }

function ix.assault.IsSectorFallen(team, sectorID)
    if (not team or not sectorID) then return false end
    return ix.assault.fallen[team] and ix.assault.fallen[team][sectorID] == true
end

function ix.assault.MarkSectorFallen(team, sectorID)
    if (not team or not sectorID) then return end
    ix.assault.fallen[team] = ix.assault.fallen[team] or {}
    ix.assault.fallen[team][sectorID] = true
end

function ix.assault.ResetSector(team, sectorID)
    if (ix.assault.fallen[team]) then
        ix.assault.fallen[team][sectorID] = nil
    end
end

function ix.assault.ResetAll()
    ix.assault.fallen = { axis = {}, allies = {} }
end

-- Network strings (server announces sector falls / state to clients so the
-- death screen can render disabled spawns correctly).
if (SERVER) then
    util.AddNetworkString("ixAssaultSectorFallen")
    util.AddNetworkString("ixAssaultSyncState")
    util.AddNetworkString("ixAssaultSectorReset")
end

ix.util.Include("sv_plugin.lua", "server")
ix.util.Include("cl_plugin.lua", "client")

-- ============================================================
-- Admin commands
-- ============================================================

ix.command.Add("AssaultStatus", {
    description = "Show fallen sectors for both teams.",
    superAdminOnly = true,
    OnRun = function(self, client)
        local lines = { "=== Assault status ===" }
        for _, team in ipairs({ "axis", "allies" }) do
            local fallen = ix.assault.fallen[team] or {}
            local list = {}
            for sector in pairs(fallen) do list[#list + 1] = sector end
            table.sort(list)
            if (#list == 0) then
                lines[#lines + 1] = string.format("  %s: no sectors lost", team)
            else
                lines[#lines + 1] = string.format("  %s lost: %s", team, table.concat(list, ", "))
            end
        end
        for _, line in ipairs(lines) do client:ChatPrint(line) end
    end
})

ix.command.Add("AssaultResetSector", {
    description = "Restore a fallen sector for a team (re-enables that sector's forward spawns). Usage: /AssaultResetSector axis A",
    superAdminOnly = true,
    arguments = { ix.type.string, ix.type.string },
    OnRun = function(self, client, team, sector)
        team   = string.lower(team or "")
        sector = string.upper(sector or "")
        if (team ~= "axis" and team ~= "allies") then
            return "Team must be 'axis' or 'allies'."
        end
        if (sector == "") then
            return "Sector ID required."
        end
        if (SERVER and PLUGIN and PLUGIN.ResetSector) then
            PLUGIN:ResetSector(team, sector)
        end
        client:ChatPrint(string.format("Restored sector %s for %s.", sector, team))
    end
})

ix.command.Add("AssaultResetAll", {
    description = "Reset all sector state for both teams (testing/round restart).",
    superAdminOnly = true,
    OnRun = function(self, client)
        if (SERVER and PLUGIN and PLUGIN.ResetAll) then
            PLUGIN:ResetAll()
        end
        client:ChatPrint("All assault state reset.")
    end
})
