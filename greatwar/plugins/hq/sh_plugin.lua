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
--     active      = bool,
--     slot        = number|nil,    index into ix.hq.SLOTS
--     voteDeadline= CurTime()|nil, real-time deadline for the vote
--     votes       = { [steamid] = bool },
--     passedAt    = CurTime()|nil,
--     armed       = bool,
--     armedAt     = CurTime()|nil,
--     lastFiredAt = CurTime()|nil, set when dawn assault actually fires
-- }

ix.hq.votes = ix.hq.votes or {}

function ix.hq.GetVoteState(team)
    ix.hq.votes[team] = ix.hq.votes[team] or {
        active       = false,
        slot         = nil,
        voteDeadline = nil,
        votes        = {},
        passedAt     = nil,
        armed        = false,
        armedAt      = nil,
        lastFiredAt  = nil,
    }
    return ix.hq.votes[team]
end

-- Resets only the active vote, preserving armed/cooldown state.
function ix.hq.ResetVote(team)
    local prev = ix.hq.votes[team] or {}
    ix.hq.votes[team] = {
        active       = false,
        slot         = nil,
        voteDeadline = nil,
        votes        = {},
        passedAt     = nil,
        armed        = prev.armed       or false,
        armedAt      = prev.armedAt     or nil,
        lastFiredAt  = prev.lastFiredAt or nil,
    }
end

-- Called when a dawn assault fires to disarm and stamp the cooldown.
function ix.hq.DisarmAssault(team)
    local state = ix.hq.GetVoteState(team)
    local firedAt = CurTime()
    ix.hq.votes[team] = {
        active       = false,
        slot         = nil,
        voteDeadline = nil,
        votes        = {},
        passedAt     = nil,
        armed        = false,
        armedAt      = nil,
        lastFiredAt  = firedAt,
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