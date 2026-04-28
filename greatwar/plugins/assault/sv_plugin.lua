local PLUGIN = PLUGIN

-- ============================================================
-- Spawn enable/disable helpers
-- ============================================================

local function SetSpawnsForSector(team, sectorID, disabled)
    local n = 0
    for _, ent in ipairs(ents.GetAll()) do
        if (not IsValid(ent)) then continue end
        local class = ent:GetClass()
        if (class ~= "ix_spawn_forward_axis" and class ~= "ix_spawn_forward_allies") then continue end
        if (not ent.GetTeam or not ent.GetSectorID) then continue end
        if (ent:GetTeam() ~= team) then continue end
        if ((ent:GetSectorID() or "") ~= sectorID) then continue end
        if (ent.SetDisabled) then
            ent:SetDisabled(disabled)
            n = n + 1
        end
    end
    return n
end

local function ReEnableAllForwardSpawns()
    for _, ent in ipairs(ents.GetAll()) do
        local class = ent:GetClass()
        if (class == "ix_spawn_forward_axis" or class == "ix_spawn_forward_allies") then
            if (ent.SetDisabled) then ent:SetDisabled(false) end
        end
    end
end

-- ============================================================
-- Capture point helpers
-- ============================================================

local function ForEachCapturePoint(fn)
    for _, ent in ipairs(ents.GetAll()) do
        if (not IsValid(ent)) then continue end
        local class = ent:GetClass()
        if (class == "ix_capture_axis" or class == "ix_capture_allies") then
            fn(ent)
        end
    end
end

local function ResetAllCapturePoints()
    ForEachCapturePoint(function(ent)
        ent:SetProgress(0)
        ent:SetCapturingTeam("")
        ent:SetContested(false)
        ent:SetLocked(false)
    end)
end

-- Sector A is "captured" when every defender-side capture point with
-- SectorID == A has progress >= 1 and Locked == true.
local function IsSectorCleared(defenderTeam, sectorID)
    local found = false
    for _, ent in ipairs(ents.GetAll()) do
        if (not IsValid(ent)) then continue end
        local class = ent:GetClass()
        if (class ~= "ix_capture_axis" and class ~= "ix_capture_allies") then continue end
        if (ent:GetTeam() ~= defenderTeam) then continue end
        if ((ent:GetSectorID() or "") ~= sectorID) then continue end

        found = true
        if (not ent:GetLocked() or (ent:GetProgress() or 0) < 1) then
            return false
        end
    end
    return found
end

-- ============================================================
-- Network helpers
-- ============================================================

local function BroadcastState()
    net.Start("ixAssaultStateChanged")
        net.WriteBool(ix.assault.active)
        net.WriteString(ix.assault.activeSector or "")
        net.WriteFloat(ix.assault.deadline)
        net.WriteString(ix.assault.ATTACKER_TEAM or "")
        net.WriteString(ix.assault.DEFENDER_TEAM or "")
    net.Broadcast()
end

-- kind: "slot_captured" | "sector_fallen" | "sector_retaken" |
--       "win" | "fail" | "started"
local function BroadcastEvent(kind, sectorID, slotID, extra)
    net.Start("ixAssaultEvent")
        net.WriteString(kind)
        net.WriteString(sectorID or "")
        net.WriteString(slotID or "")
        net.WriteString(extra or "")
    net.Broadcast()
end

local function BroadcastFallen(team, sectorID)
    net.Start("ixAssaultSectorFallen")
        net.WriteString(team)
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
-- Sequence helpers
-- ============================================================

local function NextSectorAfter(currentSector)
    for i, s in ipairs(ix.assault.SECTOR_SEQUENCE) do
        if (s == currentSector) then
            return ix.assault.SECTOR_SEQUENCE[i + 1]
        end
    end
    return nil
end

-- ============================================================
-- State machine
-- ============================================================

function PLUGIN:StartAssault(attackerTeam)
    if (ix.assault.active) then return false, "Assault already active." end
    if (attackerTeam ~= "axis" and attackerTeam ~= "allies") then
        return false, "Attacker team required."
    end

    ix.assault.ATTACKER_TEAM = attackerTeam
    ix.assault.DEFENDER_TEAM = (attackerTeam == "axis") and "allies" or "axis"

    ix.assault.ResetFallen()
    ResetAllCapturePoints()
    ReEnableAllForwardSpawns()

    ix.assault.active       = true
    ix.assault.activeSector = ix.assault.SECTOR_SEQUENCE[1]
    ix.assault.deadline     = CurTime() + ix.assault.START_TIME

    BroadcastState()
    BroadcastEvent("started", ix.assault.activeSector, "", attackerTeam)
    print(string.format("[ASSAULT] Started. ATT=%s DEF=%s sector=%s",
        attackerTeam, ix.assault.DEFENDER_TEAM, ix.assault.activeSector))
    return true
end

function PLUGIN:WinAssault()
    if (not ix.assault.active) then return end

    local winner = ix.assault.ATTACKER_TEAM
    BroadcastEvent("win", "", "", winner)

    ix.assault.active       = false
    ix.assault.activeSector = nil
    ix.assault.deadline     = 0
    BroadcastState()

    print(string.format("[ASSAULT] %s wins.", winner))

    -- Optional auto-advance map
    if (ix.assault.NEXT_MAP and ix.assault.NEXT_MAP ~= "") then
        timer.Simple(8, function()
            RunConsoleCommand("changelevel", ix.assault.NEXT_MAP)
        end)
    end
end

function PLUGIN:FailAssault(reason)
    if (not ix.assault.active) then return end

    BroadcastEvent("fail", "", "", reason or "timeout")

    ix.assault.active       = false
    ix.assault.activeSector = nil
    ix.assault.deadline     = 0

    -- Defenders reclaim everything.
    ix.assault.ResetFallen()
    ResetAllCapturePoints()
    ReEnableAllForwardSpawns()

    BroadcastState()
    print(string.format("[ASSAULT] Defenders win (%s).", reason or "timeout"))
end

function PLUGIN:HardReset()
    ix.assault.active       = false
    ix.assault.activeSector = nil
    ix.assault.deadline     = 0
    ix.assault.ResetFallen()
    ResetAllCapturePoints()
    ReEnableAllForwardSpawns()
    BroadcastState()
end

-- Advance to next sector after a clear. Adds time bonus.
local function AdvanceSector(prevSector)
    local nextSector = NextSectorAfter(prevSector)
    if (not nextSector) then
        PLUGIN:WinAssault()
        return
    end

    ix.assault.activeSector = nextSector
    ix.assault.deadline     = ix.assault.deadline + ix.assault.SECTOR_BONUS
    BroadcastState()
    print(string.format("[ASSAULT] Sector advanced to %s (+%ds)",
        nextSector, ix.assault.SECTOR_BONUS))
end

-- ============================================================
-- Capture hook
-- ============================================================

hook.Add("CapturePointTaken", "ixAssaultOnCapture", function(point, attackerTeam)
    if (not IsValid(point)) then return end
    if (not ix.assault.active) then return end

    local losingTeam = point:GetTeam()
    local sectorID   = point:GetSectorID() or "A"
    local slotID     = point:GetSlotID()   or "1"

    if (sectorID ~= ix.assault.activeSector) then return end

    BroadcastEvent("slot_captured", sectorID, slotID, losingTeam)

    if (not IsSectorCleared(losingTeam, sectorID)) then
        print(string.format("[ASSAULT] Slot %s%s captured (sector incomplete).",
            sectorID, slotID))
        return
    end

    if (ix.assault.IsSectorFallen(losingTeam, sectorID)) then return end

    ix.assault.MarkSectorFallen(losingTeam, sectorID)
    SetSpawnsForSector(losingTeam, sectorID, true)
    BroadcastFallen(losingTeam, sectorID)
    BroadcastEvent("sector_fallen", sectorID, "", losingTeam)

    print(string.format("[ASSAULT] %s lost sector %s.", losingTeam, sectorID))

    AdvanceSector(sectorID)
end)

-- ============================================================
-- Timer tick
-- ============================================================

timer.Create("ixAssaultTick", 1, 0, function()
    if (not ix.assault.active) then return end
    if (CurTime() >= ix.assault.deadline) then
        PLUGIN:FailAssault("timeout")
    end
end)

-- ============================================================
-- Spawn validator
-- ============================================================

hook.Add("ixSpawnChoiceValidate", "ixAssaultBlockDisabled", function(client, spawnEnt)
    if (not IsValid(spawnEnt)) then return end
    if (spawnEnt.GetDisabled and spawnEnt:GetDisabled()) then
        return false, "That spawn has been overrun."
    end
end)

-- ============================================================
-- Sync to joining players
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

    net.Start("ixAssaultStateChanged")
        net.WriteBool(ix.assault.active)
        net.WriteString(ix.assault.activeSector or "")
        net.WriteFloat(ix.assault.deadline)
        net.WriteString(ix.assault.ATTACKER_TEAM or "")
        net.WriteString(ix.assault.DEFENDER_TEAM or "")
    net.Send(client)
end

hook.Add("PlayerInitialSpawn", "ixAssaultSyncOnJoin", function(client)
    timer.Simple(2, function()
        if (IsValid(client)) then SyncStateToPlayer(client) end
    end)
end)

-- ============================================================
-- Map-load reset
-- ============================================================

hook.Add("InitPostEntity", "ixAssaultMapReset", function()
    PLUGIN:HardReset()
end)