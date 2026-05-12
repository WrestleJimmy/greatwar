-- ============================================================
-- Meeting Engagement (Both teams attack same morning, same slot)
--
-- Called by the HQ plugin's dawn watcher when both sides are armed
-- for the SAME slot on the SAME yearday. Both teams go over the top
-- at once. The engagement resolves when one side captures any
-- neutral capture point (ix_capture_neutral) — that team becomes
-- the attacker, the other becomes the defender, and a normal
-- assault proceeds from there.
-- ============================================================

local PLUGIN = PLUGIN

ix.assault = ix.assault or {}

-- True between StartMeetingEngagement and ResolveMeetingEngagement
-- (or stalemate timeout). While true, neutral capture points tick;
-- outside this window they're inert.
ix.assault.meetingActive = false
ix.assault.meetingTeams  = nil   -- { teamA, teamB } when active

-- Stalemate timer length. If no neutral point is captured within this
-- window, both sides fail. Tune to taste; the existing assault
-- START_TIME is 60s, so 240s gives players a reasonable clash window
-- without dragging on. Adjust later based on playtest feedback.
ix.assault.MEETING_TIMEOUT = 240

local function BroadcastToTeam(team, msg)
    for _, ply in ipairs(player.GetAll()) do
        local c = ply:GetCharacter()
        if (c and ix.team and ix.team.GetTeam(c:GetFaction()) == team) then
            ply:ChatPrint(msg)
        end
    end
end

local function BroadcastBothTeams(msg)
    BroadcastToTeam("axis",   msg)
    BroadcastToTeam("allies", msg)
end

-- ============================================================
-- Neutral capture point helpers
-- ============================================================

local function ForEachNeutralCapturePoint(fn)
    for _, ent in ipairs(ents.GetAll()) do
        if (not IsValid(ent)) then continue end
        if (ent:GetClass() == "ix_capture_neutral") then
            fn(ent)
        end
    end
end

local function ResetNeutralProgress(ent)
    ent:SetProgress(0)
    ent:SetCapturingTeam("")
    ent:SetContested(false)
end

local function UnlockAllNeutralPoints()
    local n = 0
    ForEachNeutralCapturePoint(function(ent)
        ResetNeutralProgress(ent)
        ent:SetLocked(false)
        n = n + 1
    end)
    return n
end

local function LockAllNeutralPoints()
    ForEachNeutralCapturePoint(function(ent)
        ResetNeutralProgress(ent)
        ent:SetLocked(true)
    end)
end

-- ============================================================
-- Stalemate timer
-- ============================================================

local function CancelStalemateTimer()
    timer.Remove("ixAssaultMeetingStalemate")
end

local function StartStalemateTimer()
    timer.Remove("ixAssaultMeetingStalemate")
    timer.Create("ixAssaultMeetingStalemate", ix.assault.MEETING_TIMEOUT, 1, function()
        if (not ix.assault.meetingActive) then return end

        print("[ASSAULT] Meeting engagement stalemate — no neutral point captured.")

        ix.assault.meetingActive = false
        ix.assault.meetingTeams  = nil
        SetGlobalBool("ixMeetingActive", false)

        LockAllNeutralPoints()

        BroadcastBothTeams(
            "[HQ] The attack has stalled in no-man's-land. Fall back to your trenches.")
    end)
end

-- ============================================================
-- Public API
-- ============================================================

function PLUGIN:StartMeetingEngagement(teamA, teamB)
    if (not teamA or not teamB) then
        return false, "Both teams required."
    end
    if (teamA == teamB) then
        return false, "Meeting engagement needs two different teams."
    end
    if (ix.assault.active) then
        return false, "An assault is already active."
    end
    if (ix.assault.meetingActive) then
        return false, "A meeting engagement is already active."
    end

    -- Count placed neutral points. If there are none on the map, fail
    -- loudly so admins know to place them — meeting engagement is not
    -- meaningful without contested ground.
    local count = 0
    ForEachNeutralCapturePoint(function() count = count + 1 end)
    if (count == 0) then
        print(string.format(
            "[ASSAULT] WARNING: meeting engagement triggered (%s vs %s) but " ..
            "no ix_capture_neutral entities are placed on this map. Both " ..
            "sides will stand down with no clash. Place neutral points to " ..
            "enable meeting engagements on this map.", teamA, teamB))
        BroadcastBothTeams(
            "[HQ] The attack has stalled in no-man's-land. Fall back to your trenches.")
        return true
    end

    print(string.format(
        "[ASSAULT] Meeting engagement started — %s vs %s (%d neutral point(s)).",
        teamA, teamB, count))

    ix.assault.meetingActive = true
    ix.assault.meetingTeams  = { teamA, teamB }
    SetGlobalBool("ixMeetingActive", true)

    -- Unlock neutral points so they begin ticking. Their Think functions
    -- check ix.assault.meetingActive themselves; the unlock just clears
    -- the locked flag and resets progress.
    UnlockAllNeutralPoints()

    -- Start the stalemate fail-timer.
    StartStalemateTimer()

    return true
end

-- Called by the NeutralCapturePointTaken hook (and also exposed for
-- admin/manual override). Converts an in-progress meeting into a normal
-- one-sided assault with `attackerTeam` as the attacker.
function PLUGIN:ResolveMeetingEngagement(attackerTeam)
    if (not ix.assault.meetingActive) then
        return false, "No meeting engagement in progress."
    end
    if (attackerTeam ~= "axis" and attackerTeam ~= "allies") then
        return false, "Attacker team must be axis or allies."
    end

    print(string.format(
        "[ASSAULT] Meeting engagement resolved — %s breaks through.", attackerTeam))

    ix.assault.meetingActive = false
    ix.assault.meetingTeams  = nil
    SetGlobalBool("ixMeetingActive", false)

    CancelStalemateTimer()
    LockAllNeutralPoints()

    local defenderTeam = (attackerTeam == "axis") and "allies" or "axis"
    BroadcastToTeam(attackerTeam,
        "[HQ] Our forces have broken through! Press the attack!")
    BroadcastToTeam(defenderTeam,
        "[HQ] The enemy has broken our line! Hold the sectors at all costs!")

    -- Hand off to the standard one-sided assault state machine.
    if (not self.StartAssault) then
        return false, "StartAssault missing on assault plugin."
    end
    return self:StartAssault(attackerTeam)
end

-- ============================================================
-- Hook: neutral capture point captured
-- ============================================================
--
-- Fires from the ix_capture_neutral_base Think every time a neutral
-- point reaches 1.0 progress. With LIVE captures, a single cap doesn't
-- end the meeting — the point stays unlocked and can be retaken.
-- The meeting only resolves when ONE team holds ALL neutral points
-- on the map at progress 1.0 simultaneously.

local function CountTotalAndHeldByTeam()
    local total = 0
    local axisHeld, alliesHeld = 0, 0

    for _, ent in ipairs(ents.GetAll()) do
        if (not IsValid(ent)) then continue end
        if (ent:GetClass() ~= "ix_capture_neutral") then continue end

        total = total + 1

        local progress = ent:GetProgress() or 0
        local holder   = ent:GetCapturingTeam()

        if (progress >= 1.0) then
            if (holder == "axis") then
                axisHeld = axisHeld + 1
            elseif (holder == "allies") then
                alliesHeld = alliesHeld + 1
            end
        end
    end

    return total, axisHeld, alliesHeld
end

hook.Add("NeutralCapturePointTaken", "ixAssaultMeetingResolve", function(point, capturingTeam)
    if (not IsValid(point)) then return end
    if (not ix.assault.meetingActive) then return end
    if (capturingTeam ~= "axis" and capturingTeam ~= "allies") then return end

    local total, axisHeld, alliesHeld = CountTotalAndHeldByTeam()
    if (total == 0) then return end

    local winner
    if (axisHeld == total) then
        winner = "axis"
    elseif (alliesHeld == total) then
        winner = "allies"
    end

    if (not winner) then
        -- Not all neutrals held by one team yet. Just announce the partial
        -- progress for situational awareness — both teams hear it because
        -- this is observable on-screen anyway.
        print(string.format(
            "[ASSAULT] Neutral point captured by %s (axis %d / allies %d / total %d).",
            capturingTeam, axisHeld, alliesHeld, total))
        return
    end

    print(string.format(
        "[ASSAULT] %s holds all %d neutral point(s) — meeting resolved.",
        winner, total))

    local plugin = ix.plugin.list and ix.plugin.list.assault
    if (not plugin or not plugin.ResolveMeetingEngagement) then
        print("[ASSAULT] WARNING: neutral cap fired but ResolveMeetingEngagement missing.")
        return
    end

    plugin:ResolveMeetingEngagement(winner)
end)

-- ============================================================
-- Reset state on map change
-- ============================================================

hook.Add("InitPostEntity", "ixAssaultMeetingReset", function()
    ix.assault.meetingActive = false
    ix.assault.meetingTeams  = nil
    SetGlobalBool("ixMeetingActive", false)
    CancelStalemateTimer()
end)