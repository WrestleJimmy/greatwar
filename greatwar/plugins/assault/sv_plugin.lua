local PLUGIN = PLUGIN

-- ============================================================
-- Disable forward spawns for the LOSING team in the lost sector.
-- We mark them with a NetworkVar bool "Disabled" that both the
-- death-screen filter and the respawn validator check.
-- ============================================================

local function DisableForwardSpawnsForSector(losingTeam, sectorID)
    local n = 0
    for _, ent in ipairs(ents.GetAll()) do
        if (not IsValid(ent)) then continue end

        local class = ent:GetClass()
        -- Only spawn entities (forward variant of either team)
        if (class ~= "ix_spawn_forward_axis" and class ~= "ix_spawn_forward_allies") then
            continue
        end

        if (not ent.GetTeam or not ent.GetSectorID) then continue end
        if (ent:GetTeam() ~= losingTeam) then continue end
        if ((ent:GetSectorID() or "") ~= sectorID) then continue end

        if (ent.SetDisabled) then
            ent:SetDisabled(true)
            n = n + 1
        end
    end
    return n
end

local function EnableForwardSpawnsForSector(team, sectorID)
    local n = 0
    for _, ent in ipairs(ents.GetAll()) do
        if (not IsValid(ent)) then continue end
        local class = ent:GetClass()
        if (class ~= "ix_spawn_forward_axis" and class ~= "ix_spawn_forward_allies") then
            continue
        end
        if (not ent.GetTeam or not ent.GetSectorID) then continue end
        if (ent:GetTeam() ~= team) then continue end
        if ((ent:GetSectorID() or "") ~= sectorID) then continue end

        if (ent.SetDisabled) then
            ent:SetDisabled(false)
            n = n + 1
        end
    end
    return n
end

local function BroadcastFallen(losingTeam, sectorID)
    net.Start("ixAssaultSectorFallen")
        net.WriteString(losingTeam)
        net.WriteString(sectorID)
    net.Broadcast()
end

local function BroadcastReset(team, sectorID)
    net.Start("ixAssaultSectorReset")
        net.WriteString(team)
        net.WriteString(sectorID)
    net.Broadcast()
end

-- ============================================================
-- Hook into capture points
-- ============================================================

-- Are all capture points sharing this team+sector currently locked
-- (progress >= 1)? If yes, the whole sector has fallen.
local function AllSectorSlotsCaptured(losingTeam, sectorID)
    local found = false
    for _, ent in ipairs(ents.GetAll()) do
        if (not IsValid(ent)) then continue end
        local class = ent:GetClass()
        if (class ~= "ix_capture_axis" and class ~= "ix_capture_allies") then continue end
        if (ent:GetTeam() ~= losingTeam) then continue end
        if ((ent:GetSectorID() or "") ~= sectorID) then continue end

        found = true
        if (not ent:GetLocked() or (ent:GetProgress() or 0) < 1) then
            return false
        end
    end
    return found
end

hook.Add("CapturePointTaken", "ixAssaultOnCapture", function(point, attackerTeam)
    if (not IsValid(point)) then return end

    local losingTeam = point:GetTeam()
    local sectorID   = point:GetSectorID() or "A"
    local slotID     = point:GetSlotID()   or "1"

    if (not losingTeam or losingTeam == "") then return end
    if (ix.assault.IsSectorFallen(losingTeam, sectorID)) then return end

    -- Per-slot announce so attackers know they're making progress.
    for _, ply in ipairs(player.GetAll()) do
        ply:ChatPrint(string.format("[ASSAULT] Objective %s%s captured.",
            sectorID, slotID))
    end

    -- Only retire forward spawns once every sibling slot in the sector
    -- is locked.
    if (not AllSectorSlotsCaptured(losingTeam, sectorID)) then
        print(string.format("[ASSAULT] %s slot %s%s captured (sector incomplete).",
            losingTeam, sectorID, slotID))
        return
    end

    ix.assault.MarkSectorFallen(losingTeam, sectorID)

    local disabled = DisableForwardSpawnsForSector(losingTeam, sectorID)
    BroadcastFallen(losingTeam, sectorID)

    print(string.format("[ASSAULT] %s lost sector %s. %d forward spawn(s) disabled.",
        losingTeam, sectorID, disabled))

    for _, ply in ipairs(player.GetAll()) do
        ply:ChatPrint(string.format("[ASSAULT] %s SECTOR %s HAS FALLEN. Forward spawns retired.",
            string.upper(losingTeam), sectorID))
    end
end)

-- ============================================================
-- Block respawning at a disabled forward spawn (defense in depth -
-- the death-screen UI also filters them out, but a stale client
-- could still try).
-- ============================================================

hook.Add("ixSpawnChoiceValidate", "ixAssaultBlockDisabled", function(client, spawnEnt)
    if (not IsValid(spawnEnt)) then return end
    if (spawnEnt.GetDisabled and spawnEnt:GetDisabled()) then
        return false, "That spawn has been overrun."
    end
end)

-- ============================================================
-- Sync state to joining players
-- ============================================================

local function SyncStateToPlayer(client)
    if (not IsValid(client)) then return end

    local payload = {}
    for team, sectors in pairs(ix.assault.fallen) do
        payload[team] = {}
        for sector in pairs(sectors) do
            payload[team][#payload[team] + 1] = sector
        end
    end

    net.Start("ixAssaultSyncState")
        net.WriteTable(payload)
    net.Send(client)
end

hook.Add("PlayerInitialSpawn", "ixAssaultSyncOnJoin", function(client)
    timer.Simple(2, function()
        if (IsValid(client)) then SyncStateToPlayer(client) end
    end)
end)

-- ============================================================
-- Admin command helpers (called from sh_plugin.lua)
-- ============================================================

function PLUGIN:ResetSector(team, sectorID)
    if (not ix.assault.IsSectorFallen(team, sectorID)) then return end
    ix.assault.ResetSector(team, sectorID)
    EnableForwardSpawnsForSector(team, sectorID)
    BroadcastReset(team, sectorID)
end

function PLUGIN:ResetAll()
    local snapshot = {}
    for team, sectors in pairs(ix.assault.fallen) do
        snapshot[team] = {}
        for sector in pairs(sectors) do
            snapshot[team][#snapshot[team] + 1] = sector
        end
    end

    ix.assault.ResetAll()

    -- Re-enable every forward spawn that we'd previously disabled.
    for team, sectors in pairs(snapshot) do
        for _, sector in ipairs(sectors) do
            EnableForwardSpawnsForSector(team, sector)
            BroadcastReset(team, sector)
        end
    end

    -- Belt-and-suspenders: also re-enable any forward spawn that's still
    -- flagged disabled but no longer matches a fallen sector (e.g. admin
    -- toggled a spawn manually in a previous session).
    for _, ent in ipairs(ents.GetAll()) do
        local class = ent:GetClass()
        if (class == "ix_spawn_forward_axis" or class == "ix_spawn_forward_allies") then
            if (ent.SetDisabled) then ent:SetDisabled(false) end
        end
    end
end

-- ============================================================
-- Map-load reset (don't carry sector state across maps).
-- ============================================================

hook.Add("InitPostEntity", "ixAssaultMapReset", function()
    ix.assault.ResetAll()
end)