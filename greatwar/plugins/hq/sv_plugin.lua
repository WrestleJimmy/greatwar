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

    -- IMPORTANT: do NOT include meetingEngagement / lateMover in the payload.
    -- Officers learn about enemy movement by going over the top, not via UI.
    local dateLabel, shortDateLabel
    if state.armed and state.assaultYearDay then
        local currentDay = StormFox2 and StormFox2.Date and StormFox2.Date.GetYearDay
                       and StormFox2.Date.GetYearDay() or nil
        dateLabel       = ix.hq.FormatAssaultDate(state.assaultYearDay, currentDay)
        shortDateLabel  = ix.hq.FormatYearDay(state.assaultYearDay)
    end

    local payload = {
        team           = team,
        active         = state.active,
        armed          = state.armed,
        passedAt       = state.passedAt,
        isFallback     = isFallback,
        voters         = voterList,
        slot           = state.slot,
        slotLabel      = slotInfo and slotInfo.label or nil,
        voteDeadline   = state.voteDeadline,
        cooldown       = ix.hq.CooldownRemaining(team),
        assaultYearDay = state.assaultYearDay,
        dateLabel      = dateLabel,
        shortDateLabel = shortDateLabel,
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

    local dateLabel, shortDateLabel
    if state.armed and state.assaultYearDay then
        local currentDay = StormFox2 and StormFox2.Date and StormFox2.Date.GetYearDay
                       and StormFox2.Date.GetYearDay() or nil
        dateLabel       = ix.hq.FormatAssaultDate(state.assaultYearDay, currentDay)
        shortDateLabel  = ix.hq.FormatYearDay(state.assaultYearDay)
    end

    local payload = {
        team           = hqTeam,
        active         = state.active,
        armed          = state.armed,
        passedAt       = state.passedAt,
        isFallback     = isFallback,
        voters         = voterList,
        slot           = state.slot,
        slotLabel      = slotInfo and slotInfo.label or nil,
        voteDeadline   = state.voteDeadline,
        cooldown       = ix.hq.CooldownRemaining(hqTeam),
        slots          = ix.hq.SLOTS,
        assaultYearDay = state.assaultYearDay,
        dateLabel      = dateLabel,
        shortDateLabel = shortDateLabel,
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

        -- Compute the scheduled assault yearday based on when the vote passed.
        local assaultDay, dayOffset = ix.hq.GetScheduledAssaultDay()

        state.active         = false
        state.armed          = true
        state.armedAt        = CurTime()
        state.passedAt       = CurTime()
        state.assaultYearDay = assaultDay   -- nil if SF2 not ready; falls back to old gate

        -- Silently detect collision against enemy's armed state.
        -- This stamps internal flags; NO broadcast is sent so officers
        -- can't read the enemy's intent off the HQ panel.
        local collision = ix.hq.DetectVoteCollision(team)
        if collision and collision ~= "none" then
            print(string.format(
                "[HQ] Vote collision: %s arming for day %s detected as '%s' vs %s.",
                team, tostring(assaultDay), collision,
                (team == "axis") and "allies" or "axis"))
        end

        local slotLabel = ix.hq.SLOTS[state.slot] and ix.hq.SLOTS[state.slot].label or "dawn"

        local dateStr
        if assaultDay then
            local currentDay = StormFox2.Date.GetYearDay()
            dateStr = ix.hq.FormatAssaultDate(assaultDay, currentDay)
        else
            dateStr = "the next eligible dawn"
        end

        BroadcastToTeam(team, string.format(
            "[HQ] Assault ordered for %s, %s. Prepare to advance.",
            dateStr, slotLabel))

        hook.Run("HQAssaultOrdered", team, state.slot, assaultDay)

        -- Sync the enemy too if collision flagged them — their state object
        -- changed (lateMover or meetingEngagement got set) and any open HQ
        -- panels on their side should re-pull. We deliberately don't push
        -- the flags to the client, so this just keeps cached state fresh.
        if collision and collision ~= "none" then
            local enemy = (team == "axis") and "allies" or "axis"
            SyncVoteToTeam(enemy)
        end

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
-- Dawn watcher — polls every 2 real seconds.
--
-- Firing rules at dawn:
--   1. lateMover         → silently disarm. The first-mover team's assault
--                          will fire normally; the late team becomes the
--                          defender by virtue of having no active push.
--                          Cooldown still applies (they committed forces).
--   2. meetingEngagement → both teams' armed states are valid for the same
--                          slot. Hand off to assault plugin's
--                          StartMeetingEngagement(team, enemy). The flag
--                          is checked against LIVE enemy state as a safety
--                          net (in case enemy state was reset by admin).
--   3. Default           → normal assault, hand off to StartAssault(team).
-- ============================================================

local _slotFired   = {}
local _lastSF2Time = nil

local function CheckDawnTrigger()
    if not StormFox2 or not StormFox2.Time or not StormFox2.Time.Get then return end
    local t = StormFox2.Time.Get()

    -- Legacy midnight detection — only flips fallback gate.
    if _lastSF2Time and (_lastSF2Time - t) > 100 then
        for _, team in ipairs({ "axis", "allies" }) do
            local state = ix.hq.GetVoteState(team)
            if state.armed and not state.assaultYearDay then
                state.nightGateCleared = true
                print(string.format(
                    "[HQ] Midnight crossed — legacy night gate cleared for %s assault.", team))
            end
        end
    end
    _lastSF2Time = t

    local currentYearDay = StormFox2.Date and StormFox2.Date.GetYearDay
                       and StormFox2.Date.GetYearDay() or nil

    for _, team in ipairs({ "axis", "allies" }) do
        local state = ix.hq.GetVoteState(team)
        if not state.armed then continue end
        if not state.slot  then continue end

        -- Gate check.
        local gateOpen
        if state.assaultYearDay and currentYearDay then
            local daysLate = (currentYearDay - state.assaultYearDay) % 365
            gateOpen = daysLate <= 7
        else
            gateOpen = state.nightGateCleared == true
        end

        if not gateOpen then continue end

        local slot = ix.hq.SLOTS[state.slot]
        if not slot then continue end

        local delta    = math.abs(t - slot.time)
        local inWindow = (delta <= ix.hq.SLOT_WINDOW)

        if inWindow and _slotFired[team] ~= state.slot then
            _slotFired[team] = state.slot

            local enemy      = (team == "axis") and "allies" or "axis"
            local enemyState = ix.hq.GetVoteState(enemy)

            -- ============================================================
            -- ROUTE 1: late mover safety net.
            -- In normal operation Route 3 disarms the late mover the moment
            -- the first-mover (earlier slot) fires. This branch only runs
            -- if that didn't happen — e.g. the first-mover team got admin-
            -- reset between their slot and ours. Silent disarm, no broadcast.
            -- ============================================================
            if state.lateMover then
                print(string.format(
                    "[HQ] %s flagged as late mover but reached its own slot — silent disarm.", team))
                ix.hq.DisarmAssault(team)
                _slotFired[team] = nil
                SyncVoteToTeam(team)
                continue
            end

            -- ============================================================
            -- ROUTE 2: meeting engagement → both sides go over the top.
            -- Re-check enemy live state in case their flag is stale (admin
            -- reset, enemy disarmed, etc.). If enemy isn't actually armed
            -- and meeting-flagged for this same slot, fall through to a
            -- normal assault.
            -- ============================================================
            local isMeetingValid =
                state.meetingEngagement
                and enemyState.armed
                and enemyState.meetingEngagement
                and enemyState.slot == state.slot
                and enemyState.assaultYearDay == state.assaultYearDay

            if isMeetingValid then
                BroadcastToTeam(team,  "[HQ] The hour has come. Advance! Over the top!")
                BroadcastToTeam(enemy, "[HQ] The hour has come. Advance! Over the top!")

                hook.Run("HQDawnAssault", team,  state.slot)
                hook.Run("HQDawnAssault", enemy, enemyState.slot)

                local assaultPlugin = ix.plugin.list and ix.plugin.list.assault
                if assaultPlugin and assaultPlugin.StartMeetingEngagement then
                    local ok, err = assaultPlugin:StartMeetingEngagement(team, enemy)
                    if not ok then
                        print(string.format(
                            "[HQ] Could not start meeting engagement: %s", tostring(err)))
                    end
                else
                    print("[HQ] WARNING: assault plugin missing StartMeetingEngagement; " ..
                          "falling back to a one-sided assault for " .. team)
                    if assaultPlugin and assaultPlugin.StartAssault then
                        assaultPlugin:StartAssault(team)
                    end
                end

                -- Mark BOTH teams as fired so we don't double-trigger when
                -- the loop hits the enemy on this same poll tick.
                _slotFired[team]  = state.slot
                _slotFired[enemy] = enemyState.slot

                ix.hq.DisarmAssault(team)
                ix.hq.DisarmAssault(enemy)
                SyncVoteToTeam(team)
                SyncVoteToTeam(enemy)
                continue
            end

            -- ============================================================
            -- ROUTE 3: normal assault.
            -- ============================================================
            BroadcastToTeam(team,  "[HQ] The hour has come. Advance! Over the top!")
            BroadcastToTeam(enemy, "[HQ] Enemy forces are advancing. Stand to!")

            hook.Run("HQDawnAssault", team, state.slot)

            local assaultPlugin = ix.plugin.list and ix.plugin.list.assault
            if assaultPlugin and assaultPlugin.StartAssault then
                local ok, err = assaultPlugin:StartAssault(team)
                if not ok then
                    print(string.format(
                        "[HQ] Could not start assault for %s: %s", team, tostring(err)))
                end
            else
                print("[HQ] WARNING: assault plugin not loaded; capture points will not unlock.")
            end

            -- Stand down enemy's armed-but-stale state if any. This is the
            -- "first-mover wins" case: enemy voted for a later slot on this
            -- same day, so they were silently flagged as lateMover at vote
            -- time. Now that we (the earlier slot) are firing, broadcast
            -- the bad news to them and stand them down.
            if enemyState.armed then
                BroadcastToTeam(enemy,
                    "[HQ] The enemy has attacked before us! Defend our sectors with your lives!")
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

    timer.Simple(1, function()
        LockAllCapturePoints()
        print("[HQ] All capture points locked for start of battle.")
    end)
end)