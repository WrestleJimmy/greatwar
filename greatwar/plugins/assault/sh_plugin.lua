PLUGIN.name = "Assault Orchestrator"
PLUGIN.author = "WrestleJimmy"
PLUGIN.description = "Assault state machine: sequential sectors, attacker timer, win/fail conditions."

ix.assault = ix.assault or {}

ix.assault.START_TIME      = 60
ix.assault.SECTOR_BONUS    = 30
ix.assault.SECTOR_SEQUENCE = { "A", "B" }
ix.assault.DEFENDER_TEAM   = "axis"
ix.assault.ATTACKER_TEAM   = "allies"
ix.assault.NEXT_MAP        = nil

ix.assault.fallen       = ix.assault.fallen or { axis = {}, allies = {} }
ix.assault.active       = false
ix.assault.activeSector = nil
ix.assault.deadline     = 0

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

function ix.assault.ResetFallen()
    ix.assault.fallen = { axis = {}, allies = {} }
end

function ix.assault.IsSectorActive(sectorID)
    return ix.assault.active and ix.assault.activeSector == sectorID
end

function ix.assault.GetTimeLeft()
    if (not ix.assault.active) then return 0 end
    return math.max(0, ix.assault.deadline - CurTime())
end

if (SERVER) then
    util.AddNetworkString("ixAssaultSectorFallen")
    util.AddNetworkString("ixAssaultSectorReset")
    util.AddNetworkString("ixAssaultSyncState")
    util.AddNetworkString("ixAssaultStateChanged")
    util.AddNetworkString("ixAssaultEvent")
end

ix.util.Include("sv_plugin.lua", "server")
ix.util.Include("cl_plugin.lua", "client")

ix.command.Add("AssaultStart", {
    description = "Start the assault. Usage: /AssaultStart axis  OR  /AssaultStart allies",
    superAdminOnly = true,
    arguments = { ix.type.string },
    OnRun = function(self, client, attackerTeam)
        attackerTeam = string.lower(attackerTeam or "")
        if (attackerTeam ~= "axis" and attackerTeam ~= "allies") then
            return "Attacker team must be 'axis' or 'allies'."
        end

        local p = ix.plugin.list and ix.plugin.list.assault
        if (not p or not p.StartAssault) then return "Assault plugin not loaded." end

        local ok, err = p:StartAssault(attackerTeam)
        if (not ok) then return err end
        client:ChatPrint(string.format("Assault started (%s attacking).", attackerTeam))
    end
})

ix.command.Add("AssaultEnd", {
    description = "Abort the current assault (defender win).",
    superAdminOnly = true,
    OnRun = function(self, client)
        local p = ix.plugin.list and ix.plugin.list.assault
        if (not p or not p.FailAssault) then return "Assault plugin not loaded." end
        p:FailAssault("aborted")
        client:ChatPrint("Assault aborted.")
    end
})

ix.command.Add("AssaultStatus", {
    description = "Print assault state.",
    superAdminOnly = true,
    OnRun = function(self, client)
        client:ChatPrint(string.format("Active: %s | Sector: %s | Time: %ds | ATT: %s | DEF: %s",
            tostring(ix.assault.active),
            tostring(ix.assault.activeSector),
            math.floor(ix.assault.GetTimeLeft()),
            tostring(ix.assault.ATTACKER_TEAM),
            tostring(ix.assault.DEFENDER_TEAM)))
        for _, team in ipairs({ "axis", "allies" }) do
            local list = {}
            for s in pairs(ix.assault.fallen[team] or {}) do list[#list + 1] = s end
            table.sort(list)
            client:ChatPrint(string.format("  %s lost: %s", team,
                #list == 0 and "none" or table.concat(list, ", ")))
        end
    end
})

ix.command.Add("AssaultResetAll", {
    description = "Hard reset all assault state.",
    superAdminOnly = true,
    OnRun = function(self, client)
        local p = ix.plugin.list and ix.plugin.list.assault
        if (not p or not p.HardReset) then return "Assault plugin not loaded." end
        p:HardReset()
        client:ChatPrint("Assault state reset.")
    end
})