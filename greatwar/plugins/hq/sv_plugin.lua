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

    -- Slot info for display
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
-- Vote expiry timer
-- Starts when a vote opens. If the vote hasn't resolved in
-- VOTE_DURATION seconds, it fails and the slot is freed.
-- ============================================================

local function StartVoteTimer(team)
    local timerName = "ixHQVoteExpiry_" .. team
    timer.Remove(timerName)
    timer.Create(timerName, ix.hq.VOTE_DURATION, 1, function()
        local state = ix.hq.GetVoteState(team)
        if not state.active then return end  -- already resolved

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
        slots        = ix.hq.SLOTS,   -- send full slot list for the selector UI
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

    -- Validate slot index.
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

    -- Day cycle cooldown check.
    if not ix.hq.CanCallVote(team) then
        local remaining = math.ceil(ix.hq.CooldownRemaining(team))
        local mins = math.floor(remaining / 60)
        local secs = remaining % 60
        client:Notify(string.format(
            "Cannot call a vote yet. Next dawn vote available in %d:%02d.", mins, secs))
        return
    end

    -- Open the vote.
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

    -- Tally.
    local officers = ix.hq.GetOfficersOnTeam(team)
    local eligible = math.max(1, #officers)   -- fallback = 1

    local yesCount, noCount = 0, 0
    for _, v in pairs(state.votes) do
        if v then yesCount = yesCount + 1
        else       noCount  = noCount  + 1 end
    end

    local threshold = math.ceil(eligible * 0.5 + 0.01)

    if yesCount >= threshold then
        -- Vote passes.
        timer.Remove("ixHQVoteExpiry_" .. team)
        state.active   = false
        state.armed    = true
        state.armedAt  = CurTime()
        state.passedAt = CurTime()

        local slotLabel = ix.hq.SLOTS[state.slot] and ix.hq.SLOTS[state.slot].label or "dawn"
        BroadcastToTeam(team, string.format(
            "[HQ] Assault ordered for %s. Prepare to advance at dawn.", slotLabel))

        hook.Run("HQAssaultOrdered", team, state.slot)

    elseif noCount > math.floor(eligible / 2) then
        -- Vote fails outright.
        timer.Remove("ixHQVoteExpiry_" .. team)
        local slotLabel = ix.hq.SLOTS[state.slot] and ix.hq.SLOTS[state.slot].label or "dawn"
        ix.hq.ResetVote(team)
        BroadcastToTeam(team, string.format(
            "[HQ] The assault vote for %s has been rejected.", slotLabel))
    end

    SyncVoteToTeam(team)
end)

-- ============================================================
-- StormFox2 dawn watcher
-- Checks every 10 seconds whether armed teams hit their slot.
-- When one team fires, the opposing team's armed order is cancelled.
-- ============================================================

local _slotFired = {}   -- [team] = slotIndex last fired, reset on disarm

-- ============================================================
-- SF2 time check: runs every time SF2 broadcasts a time update.
-- SF2 sends the SF_T net message on its own tick (~every few seconds).
-- We hook into that receive so our check is driven by SF2's own
-- clock rather than an independent timer that could miss windows.
-- ============================================================

local function CheckDawnTrigger()
    if not StormFox2 or not StormFox2.Time or not StormFox2.Time.Get then return end
    local t = StormFox2.Time.Get()  -- 0-1440 (minutes in day)

    -- print("[HQ Dawn] SF2 time:", t)  -- uncomment to debug

    for _, team in ipairs({ "axis", "allies" }) do
        local state = ix.hq.GetVoteState(team)
        if not state.armed then continue end
        if not state.slot  then continue end

        local slot = ix.hq.SLOTS[state.slot]
        if not slot then continue end

        local delta    = math.abs(t - slot.time)
        local inWindow = (delta <= ix.hq.SLOT_WINDOW)

        if inWindow and _slotFired[team] ~= state.slot then
            _slotFired[team] = state.slot

            BroadcastToTeam(team,
                "[HQ] The hour has come. Advance! Over the top!")

            local enemy = (team == "axis") and "allies" or "axis"
            BroadcastToTeam(enemy,
                "[HQ] Enemy forces are advancing. Stand to!")

            hook.Run("HQDawnAssault", team, state.slot)

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

-- Hook into SF2's own net receive so our check fires exactly when
-- SF2 updates its internal clock — no independent polling timer needed.
hook.Add("stormfox2.postinit", "ixHQDawnWatcher", function()
    net.Receive("SF_T", function()
        CheckDawnTrigger()
    end)
end)

-- ============================================================
-- Reset on map change
-- ============================================================

hook.Add("InitPostEntity", "ixHQResetVotes", function()
    ix.hq.votes = {}
    _slotFired  = {}
    timer.Remove("ixHQVoteExpiry_axis")
    timer.Remove("ixHQVoteExpiry_allies")
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
        _slotFired[team] = nil
        client:ChatPrint("[HQ] Vote state for " .. team .. " fully reset.")
    end
})

ix.command.Add("HQArmAssault", {
    description    = "Forcibly arm the assault for a team at a given slot (1-7).",
    superAdminOnly = true,
    arguments      = { ix.type.string, ix.type.number },
    OnRun = function(self, client, team, slotIdx)
        team    = string.lower(team)
        slotIdx = math.floor(slotIdx)
        if team ~= "axis" and team ~= "allies" then
            return "Usage: /HQArmAssault <axis|allies> <slot 1-7>"
        end
        if not ix.hq.SLOTS[slotIdx] then
            return "Slot must be 1-7. Slots: " ..
                table.concat(table.GetKeys(ix.hq.SLOTS), ", ")
        end
        local state = ix.hq.GetVoteState(team)
        state.armed    = true
        state.slot     = slotIdx
        state.armedAt  = CurTime()
        state.active   = false
        state.passedAt = CurTime()
        client:ChatPrint("[HQ] Assault armed for " .. team ..
            " at " .. ix.hq.SLOTS[slotIdx].label .. ".")
        SyncVoteToTeam(team)
    end
})