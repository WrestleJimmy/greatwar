print("[READINESS] cl_plugin.lua loaded")

local PLUGIN = PLUGIN

-- =====================================================================
-- Readiness mirror
-- =====================================================================
-- Server pushes "ixReadinessSync" every time the local player's team's
-- readiness changes (and once at PlayerInitialSpawn). We store the
-- value into ix.readiness.values so client code (HQ menu, etc.) can
-- read ix.readiness.Get(team) the same way the server does.
--
-- Net format:
--   string    team      ("axis" | "allies")
--   uint(7)   value     0..100
--   int(16)   delta     signed; 0 on initial sync. Reserved for Phase 2
--                       notification UI.
--   string    reason    short tag like "kill_own_sector". Phase 2 will
--                       drive a per-event log/toast off this.
net.Receive("ixReadinessSync", function()
    local team   = net.ReadString()
    local value  = net.ReadUInt(7)
    local delta  = net.ReadInt(16)
    local reason = net.ReadString()

    if team ~= "axis" and team ~= "allies" then return end

    ix.readiness.values[team] = value

    -- Per-team last-event tracking, same shape as the server's
    -- ix.readiness.lastReason. Useful for Phase 2 toast/log.
    ix.readiness.lastDelta  = ix.readiness.lastDelta  or {}
    ix.readiness.lastReason = ix.readiness.lastReason or {}
    ix.readiness.lastDelta[team]  = delta
    ix.readiness.lastReason[team] = reason

    -- Hook for future plugins (notifications, log panels). Phase 1
    -- doesn't bind anything to it but Phase 2 will.
    hook.Run("ReadinessChanged", team, value, delta, reason)
end)

-- =====================================================================
-- Sector mirror
-- =====================================================================
-- Server sends the current map's bounds on connect and any time admins
-- change them. Stored under the current map name to match the server's
-- ix.sector.bounds shape.
net.Receive("ixSectorSync", function()
    local payload = net.ReadTable() or {}

    local mapName = game.GetMap()
    ix.sector.bounds[mapName] = {}

    for team, b in pairs(payload) do
        if type(b) == "table" and b.min and b.max then
            ix.sector.bounds[mapName][team] = {
                min = Vector(b.min[1] or 0, b.min[2] or 0, b.min[3] or 0),
                max = Vector(b.max[1] or 0, b.max[2] or 0, b.max[3] or 0),
            }
        end
    end
end)

-- =====================================================================
-- Phase 2: readiness log mirror
-- =====================================================================
-- Officers receive the per-team event log. Soldiers don't (server only
-- sends to officers), but if a non-officer somehow ends up receiving
-- one we still store it harmlessly.
--
-- Net format:
--   string   team
--   bool     isBulk          (true = replace whole log; false = single new entry)
--   uint(8)  count           (1 if isBulk=false, 0..LOG_MAX if isBulk=true)
--   then `count` repeats of:
--     float   ts
--     uint(7) value
--     int(16) delta
--     string  reason
--     string  actorName
--     string  actorSteamID
ix.readiness.log = ix.readiness.log or { axis = {}, allies = {} }

net.Receive("ixReadinessLogSync", function()
    local team   = net.ReadString()
    local isBulk = net.ReadBool()
    local count  = net.ReadUInt(8)

    if team ~= "axis" and team ~= "allies" then return end

    local entries = {}
    for i = 1, count do
        entries[#entries + 1] = {
            ts           = net.ReadFloat(),
            value        = net.ReadUInt(7),
            delta        = net.ReadInt(16),
            reason       = net.ReadString(),
            actorName    = net.ReadString(),
            actorSteamID = net.ReadString(),
        }
    end

    if isBulk then
        ix.readiness.log[team] = entries
    else
        -- Append. Trim if we somehow exceed the cap (LOG_MAX is shared).
        local logTable = ix.readiness.log[team] or {}
        for _, e in ipairs(entries) do
            logTable[#logTable + 1] = e
        end
        while #logTable > (ix.readiness.LOG_MAX or 50) do
            table.remove(logTable, 1)
        end
        ix.readiness.log[team] = logTable
    end

    -- Hook for HQ panel auto-refresh: officer panel re-renders the log
    -- when this fires.
    hook.Run("ReadinessLogChanged", team)
end)

-- =====================================================================
-- Phase 2: notify trigger
-- =====================================================================
-- Server sends this after a successful supply deposit (or any future
-- opt-in NOTIFY_REASONS). Wording is generic — never reveals the delta
-- or the team's current readiness. Acting player only — kills are
-- silent on the actor's side by design.
net.Receive("ixReadinessNotify", function()
    local client = LocalPlayer()
    if not IsValid(client) or not client.Notify then return end
    client:Notify("Supplies received. Your team's readiness is bolstered.")
end)