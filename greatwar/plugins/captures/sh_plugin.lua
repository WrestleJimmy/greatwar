PLUGIN.name = "Capture Points"
PLUGIN.author = "WrestleJimmy"
PLUGIN.description = "BF1-style capture point entities. Defender-owned by default; attackers progress 0->1 by occupying the zone. Contested = freeze. Sector/slot tagged for assault orchestrator."

-- ============================================================
-- Shared registry / constants
-- ============================================================

ix.capture = ix.capture or {}

ix.capture.RADIUS         = 200    -- cylinder radius in units
ix.capture.HEIGHT         = 100    -- +/- Z from entity origin (200u total)
ix.capture.BASE_RATE      = 0.1    -- progress/sec with 1 attacker (10s base)
ix.capture.ATTACKER_MULT  = 1.5    -- multiplier per additional attacker
ix.capture.THINK_INTERVAL = 0.25   -- seconds between capture ticks

-- Active capture point registry (server-authoritative; clients use ents.FindByClass)
ix.capture.points = ix.capture.points or {}

function ix.capture.Register(ent)
    ix.capture.points[ent] = true
end

function ix.capture.Unregister(ent)
    ix.capture.points[ent] = nil
end

function ix.capture.GetAll()
    local out = {}
    for ent in pairs(ix.capture.points) do
        if (IsValid(ent)) then
            out[#out + 1] = ent
        else
            ix.capture.points[ent] = nil
        end
    end
    return out
end

-- Returns the team that attacks a point defended by `defenderTeam`.
function ix.capture.GetAttackerTeam(defenderTeam)
    if (defenderTeam == "axis")   then return "allies" end
    if (defenderTeam == "allies") then return "axis"   end
    return nil
end

-- Nearest registered capture point within range from a position.
function ix.capture.FindNearest(pos, maxDist)
    maxDist = maxDist or 4096
    local best, bestDist
    for _, ent in ipairs(ix.capture.GetAll()) do
        local d = ent:GetPos():Distance(pos)
        if (d <= maxDist and (not bestDist or d < bestDist)) then
            best, bestDist = ent, d
        end
    end
    return best
end

-- ============================================================
-- File loading (Helix quirk: anything not in named subdirs must
-- be explicitly included via ix.util.Include from sh_plugin.lua)
-- ============================================================

ix.util.Include("sv_plugin.lua", "server")
ix.util.Include("cl_plugin.lua", "client")

-- ============================================================
-- Admin commands (defined AFTER ix.util.Include because
-- ix.command.Add isn't ready when sv_plugin.lua loads)
-- ============================================================

ix.command.Add("CaptureSet", {
    description = "Set sector and slot ID on the nearest capture point.",
    superAdminOnly = true,
    arguments = {ix.type.string, ix.type.string},
    OnRun = function(self, client, sector, slot)
        local ent = ix.capture.FindNearest(client:GetPos(), 4096)
        if (not IsValid(ent)) then
            return "No capture point within 4096 units."
        end

        sector = string.upper(sector or "A")
        slot   = tostring(slot or "1")

        ent:SetSectorID(sector)
        ent:SetSlotID(slot)

        client:ChatPrint(string.format("Capture point set to %s%s.", sector, slot))
    end
})

ix.command.Add("CaptureShow", {
    description = "List capture points on this map and their state.",
    superAdminOnly = true,
    OnRun = function(self, client)
        local list = ix.capture.GetAll()
        if (#list == 0) then
            client:ChatPrint("No capture points on this map.")
            return
        end

        client:ChatPrint(string.format("=== %d capture point(s) ===", #list))
        for _, ent in ipairs(list) do
            local team     = ent:GetTeam() or "?"
            local sector   = ent:GetSectorID() or "?"
            local slot     = ent:GetSlotID() or "?"
            local progress = math.Round((ent:GetProgress() or 0) * 100)
            local capTeam  = ent:GetCapturingTeam()
            if (capTeam == "" or capTeam == nil) then capTeam = "-" end
            local locked   = ent:GetLocked() and " [LOCKED]" or ""
            local cont     = ent:GetContested() and " [CONTESTED]" or ""

            client:ChatPrint(string.format(
                "  %s%s | def:%s | %d%% | cap:%s%s%s",
                sector, slot, team, progress, capTeam, locked, cont
            ))
        end
    end
})

ix.command.Add("CaptureReset", {
    description = "Reset nearest capture point's progress and unlock it.",
    superAdminOnly = true,
    OnRun = function(self, client)
        local ent = ix.capture.FindNearest(client:GetPos(), 4096)
        if (not IsValid(ent)) then
            return "No capture point within 4096 units."
        end
        ent:SetProgress(0)
        ent:SetCapturingTeam("")
        ent:SetContested(false)
        ent:SetLocked(false)
        client:ChatPrint("Capture point reset.")
    end
})

-- Sector tagging for spawn entities (requires the small ix_spawn_base
-- patch in spawnsystem - see handoff notes).
ix.command.Add("SpawnSetSector", {
    description = "Set sector ID on nearest spawn entity (e.g. A, B, C).",
    superAdminOnly = true,
    arguments = {ix.type.string},
    OnRun = function(self, client, sector)
        sector = string.upper(sector or "A")

        local best, bestDist
        for _, ent in ipairs(ents.GetAll()) do
            local class = ent:GetClass()
            if (class:sub(1, 9) == "ix_spawn_" and class ~= "ix_spawn_base") then
                local d = ent:GetPos():Distance(client:GetPos())
                if (d <= 4096 and (not bestDist or d < bestDist)) then
                    best, bestDist = ent, d
                end
            end
        end

        if (not IsValid(best)) then
            client:ChatPrint("No spawn entity within 4096 units.")
            return
        end

        if (not best.SetSectorID) then
            client:ChatPrint("Spawn entity is missing SectorID network var. Apply the ix_spawn_base patch first.")
            return
        end

        best:SetSectorID(sector)
        client:ChatPrint(string.format("Spawn sector set to %s.", sector))
    end
})
