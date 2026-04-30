PLUGIN.name        = "HQ Entities"
PLUGIN.author      = "Schema"
PLUGIN.description = "Faction headquarters entities and officer voting for the trench warfare gamemode."

-- ============================================================
-- Team system
-- ============================================================

TEAM_AXIS   = "axis"
TEAM_ALLIES = "allies"

ix.team = ix.team or {}
ix.team.factions = {
    [TEAM_AXIS]   = { FACTION_GERMAN },
    [TEAM_ALLIES] = { FACTION_BRITISH },
}

function ix.team.GetTeam(faction)
    for team, factions in pairs(ix.team.factions) do
        for _, f in ipairs(factions) do
            if f == faction then return team end
        end
    end
    return nil
end

function ix.team.IsOnTeam(character, team)
    if not character then return false end
    return ix.team.GetTeam(character:GetFaction()) == team
end

function ix.team.SameTeam(charA, charB)
    if not charA or not charB then return false end
    local tA = ix.team.GetTeam(charA:GetFaction())
    local tB = ix.team.GetTeam(charB:GetFaction())
    return tA ~= nil and tA == tB
end

-- ============================================================
-- Dawn assault time slots (SF2 hours, 05:40 – 06:40)
-- ============================================================

ix.hq = ix.hq or {}

ix.hq.SLOTS = {
    { label = "05:40", time = 340 },
    { label = "05:50", time = 350 },
    { label = "06:00", time = 360 },
    { label = "06:10", time = 370 },
    { label = "06:20", time = 380 },
    { label = "06:30", time = 390 },
    { label = "06:40", time = 400 },
}

ix.hq.SLOT_WINDOW       = 5
ix.hq.VOTE_DURATION     = 300
ix.hq.DAY_REAL_SECONDS  = 1200
ix.hq.ASSAULT_WINDOW    = 600

-- ============================================================
-- Officer check helpers
-- ============================================================

local OFFICER_MIN_PAYGRADE = 6

local function GetPaygrade(character)
    if not character then return 0 end
    local info = character:GetData("rankinfo")
    return info and info.paygrade or 0
end

function ix.hq.IsOfficer(character)
    return GetPaygrade(character) >= OFFICER_MIN_PAYGRADE
end

function ix.hq.GetHighestRankOnTeam(team)
    local best, bestPlayer, bestGrade = nil, nil, 0
    for _, ply in ipairs(player.GetAll()) do
        local char = ply:GetCharacter()
        if not char then continue end
        if ix.team.GetTeam(char:GetFaction()) ~= team then continue end
        local grade = GetPaygrade(char)
        if grade > bestGrade then
            best, bestPlayer, bestGrade = char, ply, grade
        end
    end
    return best, bestPlayer
end

function ix.hq.GetOfficersOnTeam(team)
    local out = {}
    for _, ply in ipairs(player.GetAll()) do
        local char = ply:GetCharacter()
        if not char then continue end
        if ix.team.GetTeam(char:GetFaction()) ~= team then continue end
        if ix.hq.IsOfficer(char) then
            out[#out + 1] = { char = char, player = ply }
        end
    end
    return out
end

-- ============================================================
-- Vote registry
-- ============================================================
--
-- ix.hq.votes[team] = {
--     active             = bool,
--     slot               = number|nil,
--     voteDeadline       = CurTime()|nil,
--     votes              = { [steamid] = bool },
--     passedAt           = CurTime()|nil,
--     armed              = bool,
--     armedAt            = CurTime()|nil,
--     assaultYearDay     = number|nil,
--     lastFiredAt        = CurTime()|nil,
--     -- Collision flags (set silently by DetectVoteCollision when a vote passes):
--     meetingEngagement  = bool,    both teams armed for the SAME slot/day
--     lateMover          = bool,    enemy was already armed for an earlier slot same day
-- }

ix.hq.votes = ix.hq.votes or {}

function ix.hq.GetVoteState(team)
    ix.hq.votes[team] = ix.hq.votes[team] or {
        active            = false,
        slot              = nil,
        voteDeadline      = nil,
        votes             = {},
        passedAt          = nil,
        armed             = false,
        armedAt           = nil,
        assaultYearDay    = nil,
        lastFiredAt       = nil,
        meetingEngagement = false,
        lateMover         = false,
    }
    return ix.hq.votes[team]
end

-- Resets only the active vote, preserving armed/cooldown state.
function ix.hq.ResetVote(team)
    local prev = ix.hq.votes[team] or {}
    ix.hq.votes[team] = {
        active            = false,
        slot              = nil,
        voteDeadline      = nil,
        votes             = {},
        passedAt          = nil,
        armed             = prev.armed             or false,
        armedAt           = prev.armedAt           or nil,
        assaultYearDay    = prev.assaultYearDay    or nil,
        lastFiredAt       = prev.lastFiredAt       or nil,
        meetingEngagement = prev.meetingEngagement or false,
        lateMover         = prev.lateMover         or false,
    }
end

-- Called when a dawn assault fires (or stands down) to disarm and stamp cooldown.
function ix.hq.DisarmAssault(team)
    local firedAt = CurTime()
    ix.hq.votes[team] = {
        active            = false,
        slot              = nil,
        voteDeadline      = nil,
        votes             = {},
        passedAt          = nil,
        armed             = false,
        armedAt           = nil,
        assaultYearDay    = nil,
        lastFiredAt       = firedAt,
        meetingEngagement = false,
        lateMover         = false,
    }
end

function ix.hq.IsAssaultArmed(team)
    return ix.hq.GetVoteState(team).armed == true
end

function ix.hq.CanCallVote(team)
    local state = ix.hq.GetVoteState(team)
    if not state.lastFiredAt then return true end
    return (CurTime() - state.lastFiredAt) >= ix.hq.DAY_REAL_SECONDS
end

function ix.hq.CooldownRemaining(team)
    local state = ix.hq.GetVoteState(team)
    if not state.lastFiredAt then return 0 end
    return math.max(0, ix.hq.DAY_REAL_SECONDS - (CurTime() - state.lastFiredAt))
end

-- ============================================================
-- Vote collision detection
-- ============================================================
--
-- Called immediately after `team` arms its assault (vote just passed).
-- Compares against the enemy's current armed state and silently stamps
-- collision flags on one or both teams. NEVER broadcasts — officers must
-- discover collision by going over the top, not via the HQ panel.
--
-- Three cases:
--   1. Enemy not armed, or armed for a different yearday → no collision.
--   2. Same yearday, different slot → late-mover flag on whichever team
--      picked the LATER slot (compared by slot time-of-day). At dawn, the
--      earlier slot fires its assault normally; the later-slot team is
--      stood down and forced to defend.
--   3. Same yearday, same slot → meetingEngagement flag on BOTH teams.
--      At dawn, the meeting-engagement path runs instead of a normal assault.
--
-- Returns: a string describing the collision ("none", "late_mover",
-- "first_mover", "meeting") for logging only.
function ix.hq.DetectVoteCollision(team)
    local enemy      = (team == "axis") and "allies" or "axis"
    local myState    = ix.hq.GetVoteState(team)
    local enemyState = ix.hq.GetVoteState(enemy)

    if not myState.armed then return "none" end
    if not enemyState.armed then return "none" end
    if myState.assaultYearDay ~= enemyState.assaultYearDay then return "none" end

    -- Same yearday from here on.

    if myState.slot == enemyState.slot then
        myState.meetingEngagement    = true
        enemyState.meetingEngagement = true
        -- Make sure no stale late-mover flag survives a meeting collision.
        myState.lateMover    = false
        enemyState.lateMover = false
        return "meeting"
    end

    -- Different slots, same day → earlier slot fires first, the other defends.
    -- Compare the SLOT TIME-OF-DAY (5:40, 5:50, 6:00, ...) — not when the
    -- vote passed. The team whose slot comes earlier in the morning is the
    -- first-mover; the other becomes the late mover.
    local mySlotTime    = ix.hq.SLOTS[myState.slot]    and ix.hq.SLOTS[myState.slot].time    or 0
    local enemySlotTime = ix.hq.SLOTS[enemyState.slot] and ix.hq.SLOTS[enemyState.slot].time or 0

    if mySlotTime < enemySlotTime then
        -- Our slot comes earlier in the morning; enemy is the late mover.
        enemyState.lateMover = true
        myState.lateMover    = false
        return "first_mover"
    else
        -- Enemy's slot comes earlier; we are the late mover.
        myState.lateMover    = true
        enemyState.lateMover = false
        return "late_mover"
    end
end

-- ============================================================
-- Assault scheduling
-- ============================================================
--
-- The rule: there must be at least one full intervening night between
-- the vote passing and the assault firing. Concretely:
--
--   * Vote during DAY (sunrise..sunset)
--       → assault fires at the dawn after the coming night.
--       → assaultYearDay = currentYearDay + 1
--
--   * Vote during NIGHT, before midnight (sunset..2400)
--       → tonight's midnight rolls over the day counter (+1), then the
--         next day's night must pass in full. We skip the dawn that ends
--         tonight and fire at the dawn after the *following* night.
--       → assaultYearDay = currentYearDay + 2
--
--   * Vote during NIGHT, after midnight (0..sunrise)
--       → midnight already crossed; we are in the morning-side of night.
--         Skip the dawn that's only a few hours away and wait one more
--         full night.
--       → assaultYearDay = currentYearDay + 1

function ix.hq.ComputeAssaultYearDay(currentYearDay, currentTime, sunrise, sunset)
    sunrise = sunrise or 360
    sunset  = sunset  or 1080

    local isDay = currentTime >= sunrise and currentTime < sunset

    local offset
    if isDay then
        offset = 1
    elseif currentTime < sunrise then
        offset = 1
    else
        offset = 2
    end

    return (currentYearDay + offset) % 365, offset
end

function ix.hq.GetScheduledAssaultDay()
    if not StormFox2 or not StormFox2.Time or not StormFox2.Time.Get then return nil end
    if not StormFox2.Date or not StormFox2.Date.GetYearDay then return nil end

    local t   = StormFox2.Time.Get()
    local day = StormFox2.Date.GetYearDay()
    return ix.hq.ComputeAssaultYearDay(day, t)
end

-- ============================================================
-- Date formatting (unchanged)
-- ============================================================

local function _decomposeYearDay(nDay)
    local parts = string.Explode("-", os.date("%d-%m-%w", (nDay % 365) * 86400), false)
    return tonumber(parts[1]), tonumber(parts[2]), tonumber(parts[3])
end

local _MONTHS = {
    "January", "February", "March", "April", "May", "June",
    "July", "August", "September", "October", "November", "December",
}

local _WEEKDAYS = {
    [0] = "Sunday",  [1] = "Monday", [2] = "Tuesday", [3] = "Wednesday",
    [4] = "Thursday", [5] = "Friday", [6] = "Saturday",
}

local function _ordinal(n)
    local lastTwo = n % 100
    if lastTwo >= 11 and lastTwo <= 13 then return n .. "th" end
    local last = n % 10
    if last == 1 then return n .. "st"
    elseif last == 2 then return n .. "nd"
    elseif last == 3 then return n .. "rd" end
    return n .. "th"
end

function ix.hq.FormatYearDay(nDay)
    local d, m, w = _decomposeYearDay(nDay)
    if not d or not m or not w then return "an unknown date" end
    local monthName   = _MONTHS[m] or "?"
    local weekdayName = _WEEKDAYS[w] or "?"
    return string.format("%s, %s %s", weekdayName, monthName, _ordinal(d))
end

function ix.hq.FormatAssaultDate(assaultYearDay, currentYearDay)
    local absolute = ix.hq.FormatYearDay(assaultYearDay)
    if currentYearDay then
        local diff = (assaultYearDay - currentYearDay) % 365
        if diff == 1 then
            return "tomorrow (" .. absolute .. ")"
        elseif diff == 2 then
            return "the day after tomorrow (" .. absolute .. ")"
        end
    end
    return absolute
end

-- ============================================================
-- Network strings
-- ============================================================

if SERVER then
    util.AddNetworkString("ixHQOpen")
    util.AddNetworkString("ixHQVoteSync")
    util.AddNetworkString("ixHQVoteCast")
    util.AddNetworkString("ixHQVoteStart")
end

-- ============================================================
-- File loading
-- ============================================================

ix.util.Include("sv_plugin.lua", "server")
ix.util.Include("cl_plugin.lua", "client")