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

-- Seven 10-minute windows. label is display string, time is SF2 minutes (0-1440).
-- SF2 API: StormFox2.Time.Get() returns 0-1440.
-- 05:40 = 340, 05:50 = 350, 06:00 = 360 ... 06:40 = 400
ix.hq.SLOTS = {
    { label = "05:40", time = 340 },
    { label = "05:50", time = 350 },
    { label = "06:00", time = 360 },
    { label = "06:10", time = 370 },
    { label = "06:20", time = 380 },
    { label = "06:30", time = 390 },
    { label = "06:40", time = 400 },
}

-- ±5 minute trigger window around each slot centre (in SF2 minutes).
ix.hq.SLOT_WINDOW = 5

-- Real-time vote duration in seconds (5 minutes).
ix.hq.VOTE_DURATION = 300

-- Real seconds representing one full SF2 day cycle.
-- Default SF2 day = 20 real minutes. Adjust if you've changed SF2's day length.
ix.hq.DAY_REAL_SECONDS = 1200

-- Real seconds the assault window stays open after dawn fires (10 minutes base).
ix.hq.ASSAULT_WINDOW = 600

-- ============================================================
-- Officer check helpers
-- ============================================================

local OFFICER_MIN_PAYGRADE = 6

local function GetPaygrade(character)
    if not character then return 0 end
    local info = character:GetData("rankinfo")
    return info and info.paygrade or 0
end

-- Returns true if this character qualifies as an officer for HQ access.
function ix.hq.IsOfficer(character)
    if not character then return false end
    local class = character:GetClass()
    if CLASS_BRITISH_OFFICER and class == CLASS_BRITISH_OFFICER then return true end
    if CLASS_GERMAN_OFFICER  and class == CLASS_GERMAN_OFFICER  then return true end
    return GetPaygrade(character) >= OFFICER_MIN_PAYGRADE
end

-- Returns the highest-paygrade online character for a given team.
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

-- Returns a list of {char, player} for all online officers on a team.
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
--     active          = bool,
--     slot            = number|nil,    index into ix.hq.SLOTS
--     voteDeadline    = CurTime()|nil, real-time deadline for the vote
--     votes           = { [steamid] = bool },
--     passedAt        = CurTime()|nil,
--     armed           = bool,
--     armedAt         = CurTime()|nil,
--     assaultYearDay  = number|nil,    SF2 yearday on which to fire
--     lastFiredAt     = CurTime()|nil, set when dawn assault actually fires
-- }

ix.hq.votes = ix.hq.votes or {}

function ix.hq.GetVoteState(team)
    ix.hq.votes[team] = ix.hq.votes[team] or {
        active         = false,
        slot           = nil,
        voteDeadline   = nil,
        votes          = {},
        passedAt       = nil,
        armed          = false,
        armedAt        = nil,
        assaultYearDay = nil,
        lastFiredAt    = nil,
    }
    return ix.hq.votes[team]
end

-- Resets only the active vote, preserving armed/cooldown state.
function ix.hq.ResetVote(team)
    local prev = ix.hq.votes[team] or {}
    ix.hq.votes[team] = {
        active         = false,
        slot           = nil,
        voteDeadline   = nil,
        votes          = {},
        passedAt       = nil,
        armed          = prev.armed          or false,
        armedAt        = prev.armedAt        or nil,
        assaultYearDay = prev.assaultYearDay or nil,
        lastFiredAt    = prev.lastFiredAt    or nil,
    }
end

-- Called when a dawn assault fires to disarm and stamp the cooldown.
function ix.hq.DisarmAssault(team)
    local state = ix.hq.GetVoteState(team)
    local firedAt = CurTime()
    ix.hq.votes[team] = {
        active         = false,
        slot           = nil,
        voteDeadline   = nil,
        votes          = {},
        passedAt       = nil,
        armed          = false,
        armedAt        = nil,
        assaultYearDay = nil,
        lastFiredAt    = firedAt,
    }
end

function ix.hq.IsAssaultArmed(team)
    return ix.hq.GetVoteState(team).armed == true
end

-- Returns true if a full day cycle has passed since the last assault.
function ix.hq.CanCallVote(team)
    local state = ix.hq.GetVoteState(team)
    if not state.lastFiredAt then return true end
    return (CurTime() - state.lastFiredAt) >= ix.hq.DAY_REAL_SECONDS
end

-- Returns seconds remaining on cooldown, or 0 if ready.
function ix.hq.CooldownRemaining(team)
    local state = ix.hq.GetVoteState(team)
    if not state.lastFiredAt then return 0 end
    return math.max(0, ix.hq.DAY_REAL_SECONDS - (CurTime() - state.lastFiredAt))
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
--
-- This guarantees the enemy gets one complete night cycle between the
-- decision and the push, regardless of when in the cycle the vote passes.

-- Returns the SF2 yearday on which an armed assault should fire,
-- given the current SF2 yearday and SF2 time-of-day (0-1440).
-- sunrise defaults to 360 (06:00) which matches the dawn slot window.
function ix.hq.ComputeAssaultYearDay(currentYearDay, currentTime, sunrise, sunset)
    sunrise = sunrise or 360
    sunset  = sunset  or 1080

    local isDay = currentTime >= sunrise and currentTime < sunset

    local offset
    if isDay then
        -- Day vote: through coming night, fire next dawn.
        offset = 1
    elseif currentTime < sunrise then
        -- Night-after-midnight: skip the imminent dawn, wait one more night.
        offset = 1
    else
        -- Night-before-midnight: midnight will roll the day, then we still
        -- need a full night. Fire two dawns from now.
        offset = 2
    end

    return (currentYearDay + offset) % 365, offset
end

-- Convenience wrapper that pulls live values from StormFox2.
-- Returns (assaultYearDay, offsetDays) or nil if SF2 isn't ready.
function ix.hq.GetScheduledAssaultDay()
    if not StormFox2 or not StormFox2.Time or not StormFox2.Time.Get then return nil end
    if not StormFox2.Date or not StormFox2.Date.GetYearDay then return nil end

    local t   = StormFox2.Time.Get()
    local day = StormFox2.Date.GetYearDay()
    return ix.hq.ComputeAssaultYearDay(day, t)
end

-- Decompose a yearday into (dayOfMonth, monthNumber, weekdayNumber).
-- Uses the same os.date trick as sh_date.lua so the calendar matches.
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

-- Returns a human-readable date for a yearday, e.g. "Tuesday, June 6th".
function ix.hq.FormatYearDay(nDay)
    local d, m, w = _decomposeYearDay(nDay)
    if not d or not m or not w then return "an unknown date" end
    local monthName   = _MONTHS[m] or "?"
    local weekdayName = _WEEKDAYS[w] or "?"
    return string.format("%s, %s %s", weekdayName, monthName, _ordinal(d))
end

-- Returns just the relative phrasing if assault is exactly tomorrow,
-- otherwise the absolute weekday-and-date.
-- currentYearDay is needed to decide "tomorrow" vs absolute.
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
    util.AddNetworkString("ixHQVoteStart")   -- carries slot index
end

-- ============================================================
-- File loading
-- ============================================================

ix.util.Include("sv_plugin.lua", "server")
ix.util.Include("cl_plugin.lua", "client")