print("[READINESS] sv_plugin.lua loaded")

local PLUGIN = PLUGIN

-- =====================================================================
-- Sector persistence
-- =====================================================================
-- Same load/save pattern as plugins/spawnsystem/sv_plugin.lua. Vectors
-- are serialized as plain {x, y, z} arrays because util.TableToJSON
-- doesn't handle Vector userdata directly.
local SECTOR_FILE = "ix_sectors.txt"

local function VecToArr(v)
    if not v then return nil end
    return { v.x, v.y, v.z }
end

local function ArrToVec(a)
    if type(a) ~= "table" then return nil end
    return Vector(a[1] or a.x or 0, a[2] or a.y or 0, a[3] or a.z or 0)
end

local function SaveSectors()
    local serializable = {}
    for mapName, mapEntry in pairs(ix.sector.bounds) do
        serializable[mapName] = {}
        for team, b in pairs(mapEntry) do
            serializable[mapName][team] = {
                min = VecToArr(b.min),
                max = VecToArr(b.max),
            }
        end
    end
    file.Write(SECTOR_FILE, util.TableToJSON(serializable, true))
end

local function LoadSectors()
    if not file.Exists(SECTOR_FILE, "DATA") then
        ix.sector.bounds = {}
        return
    end

    local raw = file.Read(SECTOR_FILE, "DATA")
    if not raw or raw == "" then
        ix.sector.bounds = {}
        return
    end

    local decoded = util.JSONToTable(raw)
    if not decoded then
        print("[READINESS] Could not decode sectors file; starting empty.")
        ix.sector.bounds = {}
        return
    end

    -- Reconstruct vectors from stored arrays. Drop any malformed entries.
    for mapName, mapEntry in pairs(decoded) do
        for team, b in pairs(mapEntry) do
            if type(b) ~= "table" or not b.min or not b.max then
                mapEntry[team] = nil
            else
                b.min = ArrToVec(b.min)
                b.max = ArrToVec(b.max)
                if not b.min or not b.max then
                    mapEntry[team] = nil
                end
            end
        end
    end

    ix.sector.bounds = decoded
    print("[READINESS] Loaded sectors from disk.")
end

-- Public so commands in sh_plugin.lua can call us.
function PLUGIN:SetSectorBounds(mapName, team, minV, maxV)
    ix.sector.bounds[mapName] = ix.sector.bounds[mapName] or {}
    ix.sector.bounds[mapName][team] = { min = minV, max = maxV }
    SaveSectors()
    self:BroadcastSectors()
end

function PLUGIN:ClearSectorBounds(mapName, team)
    local mapEntry = ix.sector.bounds[mapName]
    if not mapEntry or not mapEntry[team] then return false end
    mapEntry[team] = nil
    SaveSectors()
    self:BroadcastSectors()
    return true
end

-- =====================================================================
-- Sector net sync
-- =====================================================================
-- We send only the current map's bounds; clients don't need other maps.
local function BuildSectorPayload()
    local mapName  = game.GetMap()
    local mapEntry = ix.sector.bounds[mapName] or {}

    local payload = {}
    for team, b in pairs(mapEntry) do
        payload[team] = {
            min = VecToArr(b.min),
            max = VecToArr(b.max),
        }
    end
    return payload
end

function PLUGIN:BroadcastSectors()
    local payload = BuildSectorPayload()
    net.Start("ixSectorSync")
        net.WriteTable(payload)
    net.Broadcast()
end

local function SyncSectorsToPlayer(client)
    if not IsValid(client) then return end
    local payload = BuildSectorPayload()
    net.Start("ixSectorSync")
        net.WriteTable(payload)
    net.Send(client)
end

-- =====================================================================
-- Readiness mutators
-- =====================================================================
-- All three end up funneling through Set so clamp/broadcast logic lives
-- in one place. `reason` is stored on the most recent change for each
-- team; Phase 2 will turn this into a per-team event log.
ix.readiness.lastReason = ix.readiness.lastReason or { axis = nil, allies = nil }

-- =====================================================================
-- Phase 2: per-team event log (ring buffer)
-- =====================================================================
-- Each entry: { ts, value, delta, reason, actorName, actorSteamID }
--   ts          = CurTime() at the moment of the change
--   value       = readiness AFTER the change
--   delta       = signed change (+5, -3, etc.)
--   reason      = short tag ("kill_own_sector", "uniform_deposit", etc.)
--   actorName   = display name of who caused it (or nil for system events)
--   actorSteamID= steamid of actor (or nil)
-- Newest entries at the END of the array.
ix.readiness.log = ix.readiness.log or { axis = {}, allies = {} }

local function PushLogEntry(team, value, delta, reason, actor)
    local entry = {
        ts           = CurTime(),
        value        = value,
        delta        = delta,
        reason       = reason or "unknown",
        actorName    = nil,
        actorSteamID = nil,
    }

    if IsValid(actor) and actor:IsPlayer() then
        local char = actor:GetCharacter()
        entry.actorName    = char and char:GetName() or actor:Nick()
        entry.actorSteamID = actor:SteamID()
    end

    local logTable = ix.readiness.log[team]
    logTable[#logTable + 1] = entry

    -- Trim from the front when we exceed the cap.
    while #logTable > ix.readiness.LOG_MAX do
        table.remove(logTable, 1)
    end

    return entry
end

-- Push a single new log entry to all officers on the given team.
-- (Officers are the only ones who care; soldiers never see this.)
-- Also includes the current fallback (highest-rank non-officer) when
-- no officers are present, matching HQ access policy.
local function BroadcastLogEntryToOfficers(team, entry)
    -- Pre-compute fallback so we don't run the rank check per-player.
    local fallbackPly
    if ix.hq and ix.hq.GetOfficersOnTeam and ix.hq.GetHighestRankOnTeam then
        local officers = ix.hq.GetOfficersOnTeam(team)
        if #officers == 0 then
            local _, bestPlayer = ix.hq.GetHighestRankOnTeam(team)
            if IsValid(bestPlayer) then fallbackPly = bestPlayer end
        end
    end

    for _, ply in ipairs(player.GetAll()) do
        local char = ply:GetCharacter()
        if not char then continue end
        if ix.team.GetTeam(char:GetFaction()) ~= team then continue end

        local isOfficer  = ix.hq and ix.hq.IsOfficer and ix.hq.IsOfficer(char)
        local isFallback = (ply == fallbackPly)
        if not isOfficer and not isFallback then continue end

        net.Start("ixReadinessLogSync")
            net.WriteString(team)
            net.WriteBool(false)        -- false = single new entry, not bulk
            net.WriteUInt(1, 8)         -- count
            net.WriteFloat(entry.ts)
            net.WriteUInt(entry.value, 7)
            net.WriteInt(entry.delta, 16)
            net.WriteString(entry.reason)
            net.WriteString(entry.actorName    or "")
            net.WriteString(entry.actorSteamID or "")
        net.Send(ply)
    end
end

-- Send the entire current log for a team to one player. Used on join,
-- on character load, and from HQ when the menu opens.
--
-- Recipients: officers always; the highest-rank fallback if NO officers
-- are present on the team (matches HQ access policy — fallback can use
-- the HQ menu when nobody else can).
function ix.readiness.SyncFullLogToPlayer(client, team)
    if not IsValid(client) then return end
    local char = client:GetCharacter()
    if not char then return end
    if ix.team.GetTeam(char:GetFaction()) ~= team then return end

    local isOfficer = ix.hq and ix.hq.IsOfficer and ix.hq.IsOfficer(char)
    local isFallback = false
    if not isOfficer and ix.hq and ix.hq.GetOfficersOnTeam and ix.hq.GetHighestRankOnTeam then
        local officers = ix.hq.GetOfficersOnTeam(team)
        if #officers == 0 then
            local _, bestPlayer = ix.hq.GetHighestRankOnTeam(team)
            if IsValid(bestPlayer) and bestPlayer == client then
                isFallback = true
            end
        end
    end

    if not isOfficer and not isFallback then return end

    local logTable = ix.readiness.log[team] or {}
    local count    = math.min(#logTable, ix.readiness.LOG_MAX)
    -- Cap count at 255 so it fits in our UInt(8). LOG_MAX is 50 so this
    -- is just defensive against future raises.
    count = math.min(count, 255)

    net.Start("ixReadinessLogSync")
        net.WriteString(team)
        net.WriteBool(true)         -- true = bulk replace
        net.WriteUInt(count, 8)
        for i = #logTable - count + 1, #logTable do
            local entry = logTable[i]
            net.WriteFloat(entry.ts)
            net.WriteUInt(entry.value, 7)
            net.WriteInt(entry.delta, 16)
            net.WriteString(entry.reason)
            net.WriteString(entry.actorName    or "")
            net.WriteString(entry.actorSteamID or "")
        end
    net.Send(client)
end

-- Local alias for hooks below.
local SyncFullLogToPlayer = ix.readiness.SyncFullLogToPlayer

-- Public accessor (used by HQ payloads as a fallback if the client log
-- isn't in sync yet; the live entries are pushed via BroadcastLogEntryToOfficers).
function ix.readiness.GetLog(team)
    return ix.readiness.log[team] or {}
end

-- Notify the actor (and ONLY the actor) that they've contributed.
-- Generic message — never reveals delta, current value, or reason.
-- Suppressed for kills (atmospheric mystery) and for system events
-- (no actor to notify).
local function NotifyActor(actor, reason)
    if not IsValid(actor) or not actor:IsPlayer() then return end
    if not ix.readiness.NOTIFY_REASONS[reason] then return end

    net.Start("ixReadinessNotify")
        -- No payload needed — the message is hardcoded on the client side.
    net.Send(actor)
end

-- =====================================================================
-- Lock state — between vote-pass and assault-start, readiness is frozen.
-- =====================================================================
-- When an officer vote passes, HQ calls ix.readiness.Lock(team). The
-- value is captured at that moment; ALL subsequent Add/Subtract/Set
-- calls for that team are absorbed silently until Unlock() is called
-- (at StartAssault, at DisarmAssault, or at map change).
--
-- Bypass: callers that NEED to mutate during the lock (StartAssault
-- zeroing the attacker, FailAssault adjustments, the assault_started
-- reset itself) pass `force = true` as the fourth argument to Set.
ix.readiness.locked      = ix.readiness.locked      or { axis = false, allies = false }
ix.readiness.lockedValue = ix.readiness.lockedValue or { axis = nil,   allies = nil   }

function ix.readiness.IsLocked(team)
    if not team then return false end
    return ix.readiness.locked[team] == true
end

-- Lock a team's readiness at its current value. Idempotent: re-locking
-- doesn't change the captured value.
function ix.readiness.Lock(team, reason)
    if not team then return end
    if team ~= "axis" and team ~= "allies" then return end
    if ix.readiness.locked[team] then return end  -- already locked

    ix.readiness.locked[team]      = true
    ix.readiness.lockedValue[team] = ix.readiness.values[team] or 0
    print(string.format("[READINESS] Locked %s at %d (%s).",
        team, ix.readiness.lockedValue[team], reason or "no reason"))
end

function ix.readiness.Unlock(team, reason)
    if not team then return end
    if team ~= "axis" and team ~= "allies" then return end
    if not ix.readiness.locked[team] then return end  -- already unlocked

    ix.readiness.locked[team]      = false
    ix.readiness.lockedValue[team] = nil
    print(string.format("[READINESS] Unlocked %s (%s).", team, reason or "no reason"))
end

local function SyncReadinessToTeam(team, delta, reason)
    local value = ix.readiness.values[team] or 0
    for _, ply in ipairs(player.GetAll()) do
        local char = ply:GetCharacter()
        if not char then continue end
        if ix.team.GetTeam(char:GetFaction()) ~= team then continue end

        net.Start("ixReadinessSync")
            net.WriteString(team)
            net.WriteUInt(math.Clamp(value, 0, 100), 7)        -- 0..100 fits in 7 bits
            net.WriteInt(delta or 0, 16)                       -- signed delta for client notifications
            net.WriteString(reason or "")
        net.Send(ply)
    end
end

local function SyncReadinessToPlayer(client)
    if not IsValid(client) then return end
    local char = client:GetCharacter()
    if not char then return end
    local team = ix.team.GetTeam(char:GetFaction())
    if not team then return end

    local value = ix.readiness.values[team] or 0
    net.Start("ixReadinessSync")
        net.WriteString(team)
        net.WriteUInt(math.Clamp(value, 0, 100), 7)
        net.WriteInt(0, 16)        -- initial sync, no delta to display
        net.WriteString("initial")
    net.Send(client)
end

function ix.readiness.Set(team, value, reason, force, actor)
    if not team then return end
    if team ~= "axis" and team ~= "allies" then return end

    -- Lock check. Bypass with force=true (used by StartAssault/FailAssault
    -- and by the reset path at map change).
    if ix.readiness.locked[team] and not force then
        -- Silently absorbed. No notify, no broadcast, no log entry —
        -- the change didn't happen as far as the world is concerned.
        return
    end

    local prev   = ix.readiness.values[team] or 0
    local newVal = math.Clamp(math.floor(tonumber(value) or 0), 0, 100)
    local delta  = newVal - prev

    ix.readiness.values[team]     = newVal
    ix.readiness.lastReason[team] = reason

    -- Belt-and-suspenders: a force-Set that drops readiness to 0 implies
    -- "the vote arc is over" (StartAssault zeros the team; manual admin
    -- resets do too). Auto-clear the lock so it can never orphan even
    -- if DisarmAssault doesn't fire afterward.
    if force and newVal == 0 and ix.readiness.locked[team] then
        ix.readiness.locked[team]      = false
        ix.readiness.lockedValue[team] = nil
        print(string.format("[READINESS] Auto-unlocked %s (force-set to 0).", team))
    end

    if delta ~= 0 or reason == "reset" or reason == "initial" then
        SyncReadinessToTeam(team, delta, reason)
    end

    -- Phase 2: log every real change (skip "initial" sync events and
    -- skip no-op Sets where the value didn't actually move). Also skip
    -- the "reset" entries from map change so the log starts fresh each
    -- battle rather than leading with a "reset to 0" line.
    if delta ~= 0 and reason ~= "initial" and reason ~= "reset" then
        local entry = PushLogEntry(team, newVal, delta, reason, actor)
        BroadcastLogEntryToOfficers(team, entry)
    end

    -- Phase 2: notify the actor for opt-in reasons (deposits etc.).
    -- Kills are deliberately excluded — soldiers should not learn that
    -- their kills moved readiness. Officer-only knowledge.
    if reason and ix.readiness.NOTIFY_REASONS[reason] then
        NotifyActor(actor, reason)
    end
end

function ix.readiness.Add(team, amount, reason, force, actor)
    if not team or not amount or amount == 0 then return end
    -- Early lock check so we don't compute cur+amount unnecessarily.
    if ix.readiness.locked[team] and not force then return end
    local cur = ix.readiness.values[team] or 0
    ix.readiness.Set(team, cur + amount, reason, force, actor)
end

function ix.readiness.Subtract(team, amount, reason, force, actor)
    if not team or not amount or amount == 0 then return end
    if ix.readiness.locked[team] and not force then return end
    local cur = ix.readiness.values[team] or 0
    ix.readiness.Set(team, cur - amount, reason, force, actor)
end

-- =====================================================================
-- Officer detection
-- =====================================================================
-- Reuses the existing HQ helper if it's loaded (paygrade >= 6 = Lt+).
-- Falls back to the rankinfo lookup directly if HQ hasn't loaded yet
-- (load order between plugins is not guaranteed).
local function IsOfficer(character)
    if not character then return false end
    if ix.hq and ix.hq.IsOfficer then
        return ix.hq.IsOfficer(character)
    end
    local info = character:GetData("rankinfo")
    return (info and info.paygrade or 0) >= 6
end

-- =====================================================================
-- Kill hook -> readiness deltas
-- =====================================================================
local D = ix.readiness.DELTA

hook.Add("PlayerDeath", "ixReadinessOnKill", function(victim, inflictor, attacker)
    if not IsValid(victim) or not victim:IsPlayer() then return end
    if not IsValid(attacker) or not attacker:IsPlayer() then return end
    if attacker == victim then return end  -- suicide / world

    local victimChar   = victim:GetCharacter()
    local attackerChar = attacker:GetCharacter()
    if not victimChar or not attackerChar then return end

    local victimTeam   = ix.team.GetTeam(victimChar:GetFaction())
    local attackerTeam = ix.team.GetTeam(attackerChar:GetFaction())
    if not victimTeam or not attackerTeam then return end

    local victimIsOfficer = IsOfficer(victimChar)
    local victimInOwnerTeam = ix.sector.GetTeamForPosition(victim:GetPos())
    -- victimInOwnerTeam is the team that OWNS the sector the victim died in,
    -- or nil for no-mans-land. "Attacker's own sector" means attacker died
    -- defending — i.e. victimInOwnerTeam == attackerTeam.

    -- ----- Friendly fire branch -----
    if attackerTeam == victimTeam then
        if victimIsOfficer then
            -- Double drain: attacker is punished AND team loses the officer.
            -- Both entries attribute to the attacker (they caused both).
            ix.readiness.Subtract(attackerTeam, D.FF_OFFICER_ATTACKER, "ff_officer_attacker", false, attacker)
            ix.readiness.Subtract(victimTeam,   D.FF_OFFICER_TEAM,     "ff_officer_loss",     false, attacker)
        else
            ix.readiness.Subtract(attackerTeam, D.FF_REGULAR, "ff_regular", false, attacker)
        end
        return
    end

    -- ----- Enemy kill branch -----
    local inOwnSector = (victimInOwnerTeam == attackerTeam)

    if victimIsOfficer then
        local gain = inOwnSector and D.OFFICER_KILL_OWN or D.OFFICER_KILL_ENEMY
        local reason = inOwnSector and "officer_kill_own_sector" or "officer_kill_enemy_or_nomans"

        ix.readiness.Add(attackerTeam,   gain,                  reason,         false, attacker)
        -- Victim's team penalty: attribute to the victim (they're the one
        -- who fell; officer log will read "Lt Weber: officer lost  -10").
        ix.readiness.Subtract(victimTeam, D.OFFICER_LOSS_VICTIM, "officer_lost", false, victim)
    else
        local gain = inOwnSector and D.KILL_OWN_SECTOR or D.KILL_ENEMY_OR_NOMANS
        local reason = inOwnSector and "kill_own_sector" or "kill_enemy_or_nomans"

        ix.readiness.Add(attackerTeam, gain, reason, false, attacker)
    end
end)

-- =====================================================================
-- Map-change reset & initial player sync
-- =====================================================================
-- InitPostEntity is the cleanest "new map is up and entities are ready"
-- hook in this codebase (the assault meeting plugin uses it the same way).
hook.Add("InitPostEntity", "ixReadinessMapReset", function()
    LoadSectors()

    -- Battle end == map change for now. Clear any leftover locks first so
    -- the reset value actually applies. force=true is belt-and-suspenders.
    ix.readiness.Unlock("axis",   "map_reset")
    ix.readiness.Unlock("allies", "map_reset")
    ix.readiness.Set("axis",   0, "reset", true)
    ix.readiness.Set("allies", 0, "reset", true)

    -- Phase 2: fresh battle, fresh log.
    ix.readiness.log = { axis = {}, allies = {} }
end)

-- Catch the initial server-startup case too (InitPostEntity runs once on
-- map load; if our plugin loads after it on first boot, the file load
-- still needs to happen).
if ix.sector.bounds and next(ix.sector.bounds) == nil then
    LoadSectors()
end

hook.Add("PlayerInitialSpawn", "ixReadinessInitialSync", function(client)
    -- Slight delay so the character is loaded when we read their faction.
    timer.Simple(2, function()
        if not IsValid(client) then return end
        SyncSectorsToPlayer(client)
        SyncReadinessToPlayer(client)
        -- Phase 2: send full team log if they're an officer.
        local char = client:GetCharacter()
        if char then
            local team = ix.team.GetTeam(char:GetFaction())
            if team then SyncFullLogToPlayer(client, team) end
        end
    end)
end)

-- Also re-sync readiness whenever a player loads a character (faction
-- change, character switch). Sectors don't depend on character so
-- they're only sent on initial spawn.
hook.Add("PlayerLoadedCharacter", "ixReadinessCharSync", function(client, character, lastChar)
    if not IsValid(client) then return end
    SyncReadinessToPlayer(client)
    -- Phase 2: send fresh log in case they switched into an officer
    -- character (or loaded one for the first time).
    if character then
        local team = ix.team.GetTeam(character:GetFaction())
        if team then SyncFullLogToPlayer(client, team) end
    end
end)

-- Phase 2: also re-sync log if rank changes mid-session (someone gets
-- /Promote'd from Sergeant up to Lieutenant). Hooks into the rank
-- system's data update if it fires CharacterVarChanged on rankinfo.
hook.Add("CharacterVarChanged", "ixReadinessRankWatch", function(character, key, oldVar, value)
    if key ~= "rankinfo" then return end
    if not character then return end
    local client = character:GetPlayer()
    if not IsValid(client) then return end
    local team = ix.team.GetTeam(character:GetFaction())
    if not team then return end
    -- They may have just become an officer (or stopped being one).
    -- Re-sync covers both cases: officer gets the log, demoted player
    -- gets nothing new (their existing client cache stays but won't
    -- update further).
    SyncFullLogToPlayer(client, team)
end)