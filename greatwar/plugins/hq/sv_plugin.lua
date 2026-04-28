local PLUGIN = PLUGIN

-- ============================================================
-- Utility: broadcast a full vote state to all team members
-- ============================================================

local function SyncVoteToTeam(team)
    local state    = ix.hq.GetVoteState(team)
    local officers = ix.hq.GetOfficersOnTeam(team)

    local isFallback = (#officers == 0)
    local fallbackPlayer
    if isFallback then
        _, fallbackPlayer = ix.hq.GetHighestRankOnTeam(team)
    end

    local voterList = {}
    if isFallback then
        if IsValid(fallbackPlayer) then
            local char = fallbackPlayer:GetCharacter()
            local info = char and char:GetData("rankinfo")
            voterList[#voterList + 1] = {
                steamid  = fallbackPlayer:SteamID(),
                name     = char and char:GetName() or fallbackPlayer:Nick(),
                fullRank = info and info.fullRank or "Unknown",
                paygrade = info and info.paygrade or 0,
                vote     = state.votes[fallbackPlayer:SteamID()],
            }
        end
    else
        for _, entry in ipairs(officers) do
            local ply  = entry.player
            local char = entry.char
            local info = char:GetData("rankinfo")
            voterList[#voterList + 1] = {
                steamid  = ply:SteamID(),
                name     = char:GetName(),
                fullRank = info and info.fullRank or "Unknown",
                paygrade = info and info.paygrade or 0,
                vote     = state.votes[ply:SteamID()],
            }
        end
    end

    local slotInfo = state.slot and ix.hq.SLOTS[state.slot] or nil

    local payload = {
        team         = team,
        active       = state.active,
        armed        = state.armed,
        passedAt     = state.passedAt,
        isFallback   = isFallback,
        voters       = voterList,
        slot         = state.slot,
        slotLabel    = slotInfo and slotInfo.label or nil,
        voteDeadline = state.voteDeadline,
        cooldown     = ix.hq.CooldownRemaining(team),
    }

    for _, ply in ipairs(player.GetAll()) do
        local char = ply:GetCharacter()
        if char and ix.team.GetTeam(char:GetFaction()) == team then
            net.Start("ixHQVoteSync")
                net.WriteTable(payload)
            net.Send(ply)
        end
    end
end

local function BroadcastToTeam(team, msg)
    for _, ply in ipairs(player.GetAll()) do
        local c = ply:GetCharacter()
        if c and ix.team.GetTeam(c:GetFaction()) == team then
            ply:ChatPrint(msg)
        end
    end
end

-- ============================================================
-- Capture point helpers
-- ============================================================

-- Lock all capture points on the map. Called on map load so points
-- are always closed until an assault is declared.
local function LockAllCapturePoints()
    for _, ent in ipairs(ents.GetAll()) do
        if not IsValid(ent) then continue end
        local c = ent:GetClass()
        if c ~= "ix_capture_axis" and c ~= "ix_capture_allies" then continue end
        ent:SetLocked(true)
        ent:SetProgress(0)
        ent:SetCapturingTeam("")
        ent:SetContested(false)
    end
end

-- Unlock sector A capture points defended by the given team.
-- Returns the number of points unlocked.
local function UnlockSectorForDefender(defenderTeam, sectorID)
    local n = 0
    for _, ent in ipairs(ents.GetAll()) do
        if not IsValid(ent) then continue end
        local c = ent:GetClass()
        if c ~= "ix_capture_axis" and c ~= "ix_capture_allies" then continue end
        if ent:GetTeam() ~= defenderTeam then continue end
        if (ent:GetSectorID() or "A") ~= sectorID then continue end
        ent:SetLocked(false)
        ent:SetProgress(0)
        ent:SetCapturingTeam("")
        ent:SetContested(false)
        n = n + 1
    end
    return n
end

-- Re-lock and reset sector capture points (assault window expired).
local function RelockSectorForDefender(defenderTeam, sectorID)
    for _, ent in ipairs(ents.GetAll()) do
        if not IsValid(ent) then continue end
        local c = ent:GetClass()
        if c ~= "ix_capture_axis" and c ~= "ix_capture_allies" then continue end
        if ent:GetTeam() ~= defenderTeam then continue end
        if (ent:GetSectorID() or "A") ~= sectorID then continue end
        ent:SetLocked(true)
        ent:SetProgress(0)
        ent:SetCapturingTeam("")
        ent:SetContested(false)
    end
end

-- ============================================================
-- Vote expiry timer
-- ============================================================

local function StartVoteTimer(team)
    local timerName = "ixHQVoteExpiry_" .. team
    timer.Remove(timerName)
    timer.Create(timerName, ix.hq.VOTE_DURATION, 1, function()
        local state = ix.hq.GetVoteState(team)
        if not state.active then return end

        state.active = false
        ix.hq.ResetVote(team)

        BroadcastToTeam(team,
            "[HQ] The assault vote has expired. No order was issued.")
        SyncVoteToTeam(team)
    end)
end

-- ============================================================
-- Assault window timer
-- Started when dawn fires. After 10 minutes, re-locks all
-- capture points for the defending team and ends the assault.
-- ============================================================

local function StartAssaultTimer(attackingTeam, defenderTeam)
    local timerName = "ixHQAssaultWindow_" .. attackingTeam
    timer.Remove(timerName)
    timer.Create(timerName, ix.hq.ASSAULT_WINDOW, 1, function()
        -- Relock sector A for the defender (failed assault).
        RelockSectorForDefender(defenderTeam, "A")

        for _, ply in ipairs(player.GetAll()) do
            ply:ChatPrint(string.format(
                "[HQ] The assault window has closed. %s forces fall back.",
                string.upper(attackingTeam)))
        end

        hook.Run("HQAssaultExpired", attackingTeam)
    end)
end

-- ============================================================
-- Access gate
-- ============================================================

local function CanAccessHQ(client, hqTeam)
    local char = client:GetCharacter()
    if not char then return false, false, "No character loaded." end
    if not ix.team.IsOnTeam(char, hqTeam) then
        return false, false, "This is not your headquarters."
    end

    if ix.hq.IsOfficer(char) then
        return true, false, nil
    end

    local officers = ix.hq.GetOfficersOnTeam(hqTeam)
    if #officers > 0 then
        return false, false, "Officer access only. An officer is present — seek their authority."
    end

    local _, bestPlayer = ix.hq.GetHighestRankOnTeam(hqTeam)
    if IsValid(bestPlayer) and bestPlayer == client then
        return true, true, nil
    end

    return false, false, "Officer access only. No officers are present."
end

-- ============================================================
-- HQ Use → send open signal to client
-- ============================================================

function PLUGIN:OnHQUsed(client, hqTeam)
    local allowed, isFallback, reason = CanAccessHQ(client, hqTeam)
    if not allowed then
        client:Notify(reason)
        return
    end

    local state    = ix.hq.GetVoteState(hqTeam)
    local officers = ix.hq.GetOfficersOnTeam(hqTeam)
    local voterList = {}

    if isFallback then
        local char = client:GetCharacter()
        local info = char and char:GetData("rankinfo")
        voterList[#voterList + 1] = {
            steamid  = client:SteamID(),
            name     = char and char:GetName() or client:Nick(),
            fullRank = info and info.fullRank or "Unknown",
            paygrade = info and info.paygrade or 0,
            vote     = state.votes[client:SteamID()],
        }
    else
        for _, entry in ipairs(officers) do
            local ply  = entry.player
            local char = entry.char
            local info = char:GetData("rankinfo")
            voterList[#voterList + 1] = {
                steamid  = ply:SteamID(),
                name     = char:GetName(),
                fullRank = info and info.fullRank or "Unknown",
                paygrade = info and info.paygrade or 0,
                vote     = state.votes[ply:SteamID()],
            }
        end
    end

    local slotInfo = state.slot and ix.hq.SLOTS[state.slot] or nil

    local payload = {
        team         = hqTeam,
        active       = state.active,
        armed        = state.armed,
        passedAt     = state.passedAt,
        isFallback   = isFallback,
        voters       = voterList,
        slot         = state.slot,
        slotLabel    = slotInfo and slotInfo.label or nil,
        voteDeadline = state.voteDeadline,
        cooldown     = ix.hq.CooldownRemaining(hqTeam),
        slots        = ix.hq.SLOTS,
    }

    net.Start("ixHQOpen")
        net.WriteTable(payload)
    net.Send(client)
end

-- ============================================================
-- Net: client starts a vote (carries chosen slot index)
-- ============================================================

net.Receive("ixHQVoteStart", function(len, client)
    local slotIndex = net.ReadUInt(8)

    local char = client:GetCharacter()
    if not char then return end

    local team = ix.team.GetTeam(char:GetFaction())
    if not team then return end

    local allowed, _, reason = CanAccessHQ(client, team)
    if not allowed then
        client:Notify(reason or "Access denied.")
        return
    end

    if not ix.hq.SLOTS[slotIndex] then
        client:Notify("Invalid time slot selected.")
        return
    end

    local state = ix.hq.GetVoteState(team)

    if state.active then
        client:Notify("A vote is already in progress for " ..
            (ix.hq.SLOTS[state.slot] and ix.hq.SLOTS[state.slot].label or "unknown") .. ".")
        return
    end

    if state.armed then
        client:Notify("An assault is already ordered for " ..
            (ix.hq.SLOTS[state.slot] and ix.hq.SLOTS[state.slot].label or "dawn") .. ".")
        return
    end

    if not ix.hq.CanCallVote(team) then
        local remaining = math.ceil(ix.hq.CooldownRemaining(team))
        local mins = math.floor(remaining / 60)
        local secs = remaining % 60
        client:Notify(string.format(
            "Cannot call a vote yet. Next dawn vote available in %d:%02d.", mins, secs))
        return
    end

    state.active       = true
    state.slot         = slotIndex
    state.votes        = {}
    state.passedAt     = nil
    state.voteDeadline = CurTime() + ix.hq.VOTE_DURATION

    local slotLabel = ix.hq.SLOTS[slotIndex].label

    BroadcastToTeam(team, string.format(
        "[HQ] An assault vote has been called for %s. Officers, cast your orders.", slotLabel))

    StartVoteTimer(team)
    SyncVoteToTeam(team)
end)

-- ============================================================
-- Net: client casts a vote
-- ============================================================

net.Receive("ixHQVoteCast", function(len, client)
    local voteYes = net.ReadBool()

    local char = client:GetCharacter()
    if not char then return end

    local team = ix.team.GetTeam(char:GetFaction())
    if not team then return end

    local allowed, isFallback, reason = CanAccessHQ(client, team)
    if not allowed then
        client:Notify(reason or "Access denied.")
        return
    end

    local state = ix.hq.GetVoteState(team)

    if not state.active then
        client:Notify("There is no active vote.")
        return
    end

    state.votes[client:SteamID()] = voteYes

    local officers = ix.hq.GetOfficersOnTeam(team)
    local eligible = math.max(1, #officers)

    local yesCount, noCount = 0, 0
    for _, v in pairs(state.votes) do
        if v then yesCount = yesCount + 1
        else       noCount  = noCount  + 1 end
    end

    local threshold = math.ceil(eligible * 0.5 + 0.01)

    if yesCount >= threshold then
        timer.Remove("ixHQVoteExpiry_" .. team)
        state.active           = false
        state.armed            = true
        state.armedAt          = CurTime()
        state.passedAt         = CurTime()
        state.nightGateCleared = false   -- gate opens after next midnight

        local slotLabel = ix.hq.SLOTS[state.slot] and ix.hq.SLOTS[state.slot].label or "dawn"
        BroadcastToTeam(team, string.format(
            "[HQ] Assault ordered for %s. Prepare to advance at dawn.", slotLabel))

        hook.Run("HQAssaultOrdered", team, state.slot)

    elseif noCount > math.floor(eligible / 2) then
        timer.Remove("ixHQVoteExpiry_" .. team)
        local slotLabel = ix.hq.SLOTS[state.slot] and ix.hq.SLOTS[state.slot].label or "dawn"
        ix.hq.ResetVote(team)
        BroadcastToTeam(team, string.format(
            "[HQ] The assault vote for %s has been rejected.", slotLabel))
    end

    SyncVoteToTeam(team)
end)

-- ============================================================
-- Dawn watcher — polls every 10 real seconds.
-- Night gate: the assault can only fire after midnight has been
-- crossed at least once since the vote passed. We track the last
-- SF2 time seen; when it drops (>1200 -> <200) a day rolled over
-- and we mark the gate open for any currently-armed teams.
-- ============================================================

local _slotFired   = {}
local _lastSF2Time = nil   -- previous poll value for midnight detection

local function CheckDawnTrigger()
    if not StormFox2 or not StormFox2.Time or not StormFox2.Time.Get then return end
    local t = StormFox2.Time.Get()   -- 0-1440

    -- Detect midnight crossing: time wrapped backwards by more than 100
    -- SF2-minutes. Works for any day length including short debug cycles.
    if _lastSF2Time and (_lastSF2Time - t) > 100 then
        for _, team in ipairs({ "axis", "allies" }) do
            local state = ix.hq.GetVoteState(team)
            if state.armed then
                state.nightGateCleared = true
                print(string.format("[HQ] Midnight crossed — night gate cleared for %s assault.", team))
            end
        end
    end
    _lastSF2Time = t

    for _, team in ipairs({ "axis", "allies" }) do
        local state = ix.hq.GetVoteState(team)
        if not state.armed then continue end
        if not state.slot  then continue end

        -- Night gate: midnight must have passed since the vote was armed.
        if not state.nightGateCleared then continue end

        local slot = ix.hq.SLOTS[state.slot]
        if not slot then continue end

        local delta    = math.abs(t - slot.time)
        local inWindow = (delta <= ix.hq.SLOT_WINDOW)

        if inWindow and _slotFired[team] ~= state.slot then
            _slotFired[team] = state.slot

            local enemy        = (team == "axis") and "allies" or "axis"
            local defenderTeam = enemy   -- attackers assault the enemy's points

            BroadcastToTeam(team,  "[HQ] The hour has come. Advance! Over the top!")
            BroadcastToTeam(enemy, "[HQ] Enemy forces are advancing. Stand to!")

            -- Unlock sector A capture points for the defending team.
            local opened = UnlockSectorForDefender(defenderTeam, "A")
            print(string.format("[HQ] Dawn assault by %s. %d sector A capture point(s) unlocked.",
                team, opened))

            -- Start the 10-minute assault window timer.
            StartAssaultTimer(team, defenderTeam)

            hook.Run("HQDawnAssault", team, state.slot)

            -- If the enemy also had an armed assault, stand it down.
            local enemyState = ix.hq.GetVoteState(enemy)
            if enemyState.armed then
                local enemySlot = ix.hq.SLOTS[enemyState.slot]
                BroadcastToTeam(enemy,
                    "[HQ] Enemy moved first. Your assault order for " ..
                    (enemySlot and enemySlot.label or "dawn") .. " is stood down.")
                ix.hq.DisarmAssault(enemy)
                _slotFired[enemy] = nil
                SyncVoteToTeam(enemy)
            end

            ix.hq.DisarmAssault(team)
            SyncVoteToTeam(team)

        elseif not inWindow and _slotFired[team] == state.slot then
            _slotFired[team] = nil
        end
    end
end

hook.Add("stormfox2.postinit", "ixHQDawnWatcher", function()
    timer.Create("ixHQDawnPoll", 2, 0, function()
        CheckDawnTrigger()
    end)
end)

-- ============================================================
-- Reset on map change: lock all capture points, clear vote state.
-- ============================================================

hook.Add("InitPostEntity", "ixHQResetVotes", function()
    ix.hq.votes = {}
    _slotFired  = {}
    timer.Remove("ixHQVoteExpiry_axis")
    timer.Remove("ixHQVoteExpiry_allies")
    timer.Remove("ixHQAssaultWindow_axis")
    timer.Remove("ixHQAssaultWindow_allies")
    timer.Remove("ixHQDawnPoll")

    -- Delay slightly so permaprop entities have spawned before we lock them.
    timer.Simple(1, function()
        LockAllCapturePoints()
        print("[HQ] All capture points locked for start of battle.")
    end)
end)

-- ============================================================
-- Admin commands
-- ============================================================

ix.command.Add("HQVoteReset", {
    description    = "Reset the assault vote state for a team (axis/allies).",
    superAdminOnly = true,
    arguments      = { ix.type.string },
    OnRun = function(self, client, team)
        team = string.lower(team)
        if team ~= "axis" and team ~= "allies" then
            return "Usage: /HQVoteReset <axis|allies>"
        end
        ix.hq.votes[team] = nil
        timer.Remove("ixHQVoteExpiry_" .. team)
        timer.Remove("ixHQAssaultWindow_" .. team)
        _slotFired[team] = nil
        client:ChatPrint("[HQ] Vote state for " .. team .. " fully reset.")
    end
})

ix.command.Add("HQArmAssault", {
    description    = "Forcibly arm the assault for a team at a given slot (1-7). Bypasses night gate.",
    superAdminOnly = true,
    arguments      = { ix.type.string, ix.type.number },
    OnRun = function(self, client, team, slotIdx)
        team    = string.lower(team)
        slotIdx = math.floor(slotIdx)
        if team ~= "axis" and team ~= "allies" then
            return "Usage: /HQArmAssault <axis|allies> <slot 1-7>"
        end
        if not ix.hq.SLOTS[slotIdx] then
            return "Slot must be 1-7."
        end
        local state = ix.hq.GetVoteState(team)
        state.armed            = true
        state.slot             = slotIdx
        state.armedAt          = CurTime()
        state.active           = false
        state.passedAt         = CurTime()
        state.nightGateCleared = true   -- admin bypass
        client:ChatPrint("[HQ] Assault armed for " .. team ..
            " at " .. ix.hq.SLOTS[slotIdx].label .. " (night gate bypassed).")
        SyncVoteToTeam(team)
    end
})