PLUGIN.name        = "Readiness"
PLUGIN.author      = "Schema"
PLUGIN.description = "Team readiness pool gating assault calls, plus per-map sector AABBs that drive readiness deltas from kills."

print("[READINESS] sh_plugin.lua loaded on", SERVER and "SERVER" or "CLIENT")

-- Capture at load time. The global PLUGIN is only set during a plugin's
-- own load; later (in command OnRun, hook callbacks, timers) it's nil
-- or pointing at some other plugin. Captured local stays correct.
local PLUGIN = PLUGIN

-- =====================================================================
-- ix.readiness — team readiness pool (0..100)
-- =====================================================================
ix.readiness = ix.readiness or {}
ix.readiness.values = ix.readiness.values or { axis = 0, allies = 0 }

-- Tunables exposed on the namespace so other plugins (HQ, assault) can
-- read them rather than hardcoding.
ix.readiness.MIN_THRESHOLD = 30   -- minimum to call a Hasty assault
ix.readiness.MAX_THRESHOLD = 100  -- threshold for a Standard assault

-- Kill-based readiness deltas. Tunable in one place; sv_plugin reads these.
ix.readiness.DELTA = {
    KILL_OWN_SECTOR        =  5,
    KILL_ENEMY_OR_NOMANS   =  3,
    OFFICER_KILL_OWN       = 15,
    OFFICER_KILL_ENEMY     = 10,
    OFFICER_LOSS_VICTIM    = 10,  -- subtracted from victim team when their officer dies
    FF_REGULAR             =  3,  -- subtracted from attacker team
    FF_OFFICER_ATTACKER    = 15,  -- subtracted from attacker team
    FF_OFFICER_TEAM        = 10,  -- subtracted from team for losing the officer
    DEFENDER_HOLD_BONUS    = 15,  -- added to defender on FailAssault
}

-- Returns current readiness for a team (0..100). Always returns a number.
function ix.readiness.Get(team)
    if not team then return 0 end
    return ix.readiness.values[team] or 0
end

-- Server-side mutation helpers are defined in sv_plugin.lua. Stubs here
-- so client code can call .Get without erroring before sv_plugin loads.
if CLIENT then
    -- Client mirrors do nothing on the mutation API — the server is the
    -- authority. Provided so cross-realm code doesn't have to nil-check.
    function ix.readiness.Add(team, amount, reason, force)      end
    function ix.readiness.Subtract(team, amount, reason, force) end
    function ix.readiness.Set(team, value, reason, force)       end
    function ix.readiness.Lock(team, reason)                    end
    function ix.readiness.Unlock(team, reason)                  end
    function ix.readiness.IsLocked(team)                        return false end
end

-- =====================================================================
-- ix.sector — per-map team sector AABBs
-- =====================================================================
-- bounds[mapName][team] = { min = Vector, max = Vector }
-- Z is recorded but on lookup we expand vertically to cover the whole
-- map height, so admins can define sectors as 2D rectangles.
ix.sector = ix.sector or {}
ix.sector.bounds = ix.sector.bounds or {}

-- Vertical span used for IsInTeamSector / GetTeamForPosition. Expanded
-- on read so admin sector definitions become effectively 2D.
ix.sector.Z_MIN = -16384
ix.sector.Z_MAX =  16384

-- Test pos (Vector) against `team`'s sector on the current map.
function ix.sector.IsInTeamSector(pos, team)
    if not pos or not team then return false end

    local mapEntry = ix.sector.bounds[game.GetMap()]
    if not mapEntry then return false end

    local b = mapEntry[team]
    if not b or not b.min or not b.max then return false end

    -- XY check uses the saved bounds; Z is forced to the full map span.
    return  pos.x >= b.min.x and pos.x <= b.max.x
        and pos.y >= b.min.y and pos.y <= b.max.y
        and pos.z >= ix.sector.Z_MIN and pos.z <= ix.sector.Z_MAX
end

-- Returns "axis" | "allies" | nil. nil = no-mans-land.
function ix.sector.GetTeamForPosition(pos)
    if ix.sector.IsInTeamSector(pos, "axis")   then return "axis"   end
    if ix.sector.IsInTeamSector(pos, "allies") then return "allies" end
    return nil
end

-- =====================================================================
-- Network strings (server only — registration must happen on server)
-- =====================================================================
if SERVER then
    util.AddNetworkString("ixReadinessSync")    -- single-team readiness push
    util.AddNetworkString("ixSectorSync")       -- whole bounds table for current map
    util.AddNetworkString("ixReadinessLogSync") -- bulk log push (initial sync) and incremental log entries
    util.AddNetworkString("ixReadinessNotify")  -- "you helped" notify trigger to a specific player
end

-- =====================================================================
-- Log configuration (Phase 2)
-- =====================================================================
-- Per-team ring buffer of recent readiness events. Officers see this in
-- the HQ menu. Soldiers never see kill entries (atmospheric mystery —
-- only officers correlate kills to readiness).
ix.readiness.LOG_MAX = 50

-- Reasons that count as "kills" for notify-suppression purposes. The
-- actor is never told their kill changed readiness — only officers see
-- the contribution in the HQ log.
ix.readiness.KILL_REASONS = {
    kill_own_sector              = true,
    kill_enemy_or_nomans         = true,
    officer_kill_own_sector      = true,
    officer_kill_enemy_or_nomans = true,
    officer_lost                 = true,    -- victim's team penalty for losing officer
    ff_regular                   = true,
    ff_officer_attacker          = true,
    ff_officer_loss              = true,
}

-- Reasons that DO trigger a notify to the actor. Currently only deposits;
-- Phase 2+ will add raid_completion etc. to this set.
ix.readiness.NOTIFY_REASONS = {
    uniform_deposit      = true,
    uniform_deposit_bulk = true,
}

-- =====================================================================
-- Realm-specific files
-- =====================================================================
-- Helix's auto-loader does NOT auto-include sv_plugin.lua / cl_plugin.lua
-- when they sit next to sh_plugin.lua. Must explicitly include.
ix.util.Include("sv_plugin.lua", "server")
ix.util.Include("cl_plugin.lua", "client")

-- =====================================================================
-- Admin commands
-- =====================================================================
-- Defined HERE (after the Includes above) because ix.command.Add isn't
-- ready when sv_plugin.lua loads. Same pattern as the captures plugin.

if SERVER then
    -- Pending corner-1 state for /SetSector, keyed by SteamID. Holds the
    -- team being defined and the recorded first corner. Cleared after the
    -- second run completes, or after PENDING_TIMEOUT seconds idle.
    PLUGIN.pendingSector = PLUGIN.pendingSector or {}

    -- Pending confirmation state for /ClearSector.
    PLUGIN.pendingClear = PLUGIN.pendingClear or {}

    local PENDING_TIMEOUT       = 5 * 60  -- /SetSector corner-1 hold (5 min)
    local PENDING_CLEAR_TIMEOUT = 30      -- /ClearSector confirm window (30s)

    -- Periodic janitor: drops stale pending entries.
    timer.Create("ixReadinessPendingJanitor", 30, 0, function()
        local now = CurTime()
        for sid, p in pairs(PLUGIN.pendingSector) do
            if (now - (p.at or 0)) > PENDING_TIMEOUT then
                PLUGIN.pendingSector[sid] = nil
            end
        end
        for sid, p in pairs(PLUGIN.pendingClear) do
            if (now - (p.at or 0)) > PENDING_CLEAR_TIMEOUT then
                PLUGIN.pendingClear[sid] = nil
            end
        end
    end)
end

local function ValidTeamArg(teamStr)
    if not teamStr then return nil end
    local t = string.lower(teamStr)
    if t == "axis" or t == "allies" then return t end
    return nil
end

-- ---------------------------------------------------------------
-- /SetSector <axis|allies> — two-step rectangle definition
-- ---------------------------------------------------------------
ix.command.Add("SetSector", {
    description    = "Define a team's sector AABB on the current map. Run once at corner 1, again at the opposite corner.",
    adminOnly      = true,
    arguments      = { ix.type.string },
    OnRun = function(self, client, teamStr)
        local team = ValidTeamArg(teamStr)
        if not team then
            return "Team must be 'axis' or 'allies'."
        end

        local sid = client:SteamID()
        local pos = client:GetPos()
        local pending = PLUGIN.pendingSector[sid]

        if not pending or pending.team ~= team then
            -- First corner. (Or switching teams mid-flow — start fresh.)
            PLUGIN.pendingSector[sid] = {
                team   = team,
                corner = pos,
                at     = CurTime(),
            }
            return string.format(
                "Corner 1 set, run again at opposite corner to define the %s sector.",
                team)
        end

        -- Second corner — finalize.
        local c1, c2 = pending.corner, pos
        local minV = Vector(
            math.min(c1.x, c2.x),
            math.min(c1.y, c2.y),
            math.min(c1.z, c2.z))
        local maxV = Vector(
            math.max(c1.x, c2.x),
            math.max(c1.y, c2.y),
            math.max(c1.z, c2.z))

        PLUGIN.pendingSector[sid] = nil
        PLUGIN:SetSectorBounds(game.GetMap(), team, minV, maxV)

        return string.format(
            "%s sector saved: min(%d, %d, %d) -> max(%d, %d, %d).",
            team,
            math.Round(minV.x), math.Round(minV.y), math.Round(minV.z),
            math.Round(maxV.x), math.Round(maxV.y), math.Round(maxV.z))
    end
})

-- ---------------------------------------------------------------
-- /ShowSectors — print both teams' bounds for the current map
-- ---------------------------------------------------------------
ix.command.Add("ShowSectors", {
    description = "Print sector bounds for both teams on the current map.",
    adminOnly   = true,
    arguments   = {},
    OnRun = function(self, client)
        local mapName  = game.GetMap()
        local mapEntry = ix.sector.bounds[mapName] or {}

        local function fmt(team)
            local b = mapEntry[team]
            if not b or not b.min or not b.max then return "(unset)" end
            return string.format("min(%d, %d, %d) -> max(%d, %d, %d)",
                math.Round(b.min.x), math.Round(b.min.y), math.Round(b.min.z),
                math.Round(b.max.x), math.Round(b.max.y), math.Round(b.max.z))
        end

        client:ChatPrint(string.format("[Sectors / %s]", mapName))
        client:ChatPrint("  axis:   " .. fmt("axis"))
        client:ChatPrint("  allies: " .. fmt("allies"))
        -- Returning nothing — output goes via ChatPrint above.
    end
})

-- ---------------------------------------------------------------
-- /ClearSector <axis|allies> — confirm-required removal
-- ---------------------------------------------------------------
ix.command.Add("ClearSector", {
    description = "Remove a team's sector definition for the current map. Confirm with a second run within 30s.",
    adminOnly   = true,
    arguments   = { ix.type.string },
    OnRun = function(self, client, teamStr)
        local team = ValidTeamArg(teamStr)
        if not team then
            return "Team must be 'axis' or 'allies'."
        end

        local sid = client:SteamID()
        local pending = PLUGIN.pendingClear[sid]

        if not pending or pending.team ~= team then
            PLUGIN.pendingClear[sid] = { team = team, at = CurTime() }
            return string.format(
                "Confirm removal of %s sector by running /ClearSector %s again within 30 seconds.",
                team, team)
        end

        PLUGIN.pendingClear[sid] = nil
        local removed = PLUGIN:ClearSectorBounds(game.GetMap(), team)
        if removed then
            return string.format("%s sector cleared for %s.", team, game.GetMap())
        else
            return string.format("%s sector was not set for %s.", team, game.GetMap())
        end
    end
})

-- ---------------------------------------------------------------
-- /UnlockReadiness <axis|allies> — admin recovery for orphaned locks
-- ---------------------------------------------------------------
-- Safety valve. Normally locks clear automatically (DisarmAssault, or
-- the auto-clear in Set when force-zeroing). This is for the case
-- where something weird happened in testing or admin meddling left
-- a team's readiness locked when it shouldn't be.
ix.command.Add("UnlockReadiness", {
    description = "Force-clear a team's readiness lock. Use only if a lock got stuck.",
    adminOnly   = true,
    arguments   = { ix.type.string },
    OnRun = function(self, client, teamStr)
        local team = ValidTeamArg(teamStr)
        if not team then
            return "Team must be 'axis' or 'allies'."
        end

        if not ix.readiness.IsLocked(team) then
            return string.format("%s readiness is not locked.", team)
        end

        ix.readiness.Unlock(team, "admin_unlock")
        return string.format("%s readiness lock cleared.", team)
    end
})