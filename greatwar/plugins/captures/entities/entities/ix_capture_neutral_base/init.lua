AddCSLuaFile("shared.lua")
AddCSLuaFile("cl_init.lua")
include("shared.lua")

-- ============================================================
-- Neutral capture point
--
-- Differences from ix_capture_base:
--   * Owned by neither team (Team = "neutral").
--   * Either team can capture by being the only side in the zone.
--   * If both teams have at least one player in the zone → contested,
--     progress freezes (no team gains).
--   * If the capturing team changes (e.g. axis was capping, then leaves
--     and allies show up) progress resets to 0 and starts over for the
--     new team.
--   * Tick logic is gated on `ix.assault.meetingActive` instead of the
--     standard sector-active gate. Outside a meeting engagement, a
--     neutral point sits dormant even if unlocked.
--   * On capture, fires `NeutralCapturePointTaken(point, capturingTeam)`
--     so meeting-engagement resolution doesn't collide with the regular
--     `CapturePointTaken` hook (which is consumed by the assault
--     orchestrator for sector progression).
-- ============================================================

function ENT:Initialize()
    self:SetModel(self.Model)
    self:PhysicsInit(SOLID_VPHYSICS)
    self:SetMoveType(MOVETYPE_NONE)
    self:SetSolid(SOLID_VPHYSICS)

    -- Fallback for static-folder models that lack a .phy mesh
    local phys = self:GetPhysicsObject()
    if (not IsValid(phys)) then
        self:PhysicsInitBox(self:OBBMins(), self:OBBMaxs())
        self:EnableCustomCollisions(true)
        phys = self:GetPhysicsObject()
    end
    if (IsValid(phys)) then
        phys:EnableMotion(false)
        phys:Sleep()
    end

    -- Defaults
    self:SetTeam("neutral")
    self:SetSectorID("N")     -- "N" sector for neutral, distinct from A/B/etc.
    self:SetSlotID("1")
    self:SetProgress(0)
    self:SetCapturingTeam("")
    self:SetContested(false)
    self:SetLocked(true)       -- locked by default; meeting engagement unlocks them

    if (ix.capture and ix.capture.Register) then
        ix.capture.Register(self)
    end

    self:NextThink(CurTime() + ix.capture.THINK_INTERVAL)
end

local function CountTeamsInZone(ent)
    local origin = ent:GetPos()
    local radSq  = ix.capture.RADIUS * ix.capture.RADIUS
    local zRange = ix.capture.HEIGHT

    local axisCount, alliesCount = 0, 0

    for _, ply in ipairs(player.GetAll()) do
        if (not ply:Alive()) then continue end
        local char = ply:GetCharacter()
        if (not char) then continue end

        local pos = ply:GetPos()
        if (math.abs(pos.z - origin.z) > zRange) then continue end

        local dx, dy = pos.x - origin.x, pos.y - origin.y
        if (dx * dx + dy * dy > radSq) then continue end

        if (ix.team and ix.team.IsOnTeam) then
            if (ix.team.IsOnTeam(char, "axis")) then
                axisCount = axisCount + 1
            elseif (ix.team.IsOnTeam(char, "allies")) then
                alliesCount = alliesCount + 1
            end
        end
    end

    return axisCount, alliesCount
end

function ENT:Think()
    self:NextThink(CurTime() + ix.capture.THINK_INTERVAL)

    if (self:GetLocked()) then return true end

    -- Gate: only tick during a meeting engagement.
    if (not (ix.assault and ix.assault.meetingActive)) then
        self:SetProgress(0)
        self:SetCapturingTeam("")
        self:SetContested(false)
        return true
    end

    local axisCount, alliesCount = CountTeamsInZone(self)
    local dt = ix.capture.THINK_INTERVAL

    -- Both teams present → contested, freeze progress.
    if (axisCount > 0 and alliesCount > 0) then
        self:SetContested(true)
        return true
    end
    self:SetContested(false)

    -- No one present → progress decays back to zero (or just sits,
    -- depending on preference). We hold progress where it is so a team
    -- that briefly leaves doesn't lose all their work — but clear the
    -- capturing-team display once they're gone and progress is at zero.
    if (axisCount == 0 and alliesCount == 0) then
        if (self:GetProgress() <= 0) then
            self:SetCapturingTeam("")
        end
        return true
    end

    -- Exactly one team present.
    local presentTeam, count
    if (axisCount > 0) then
        presentTeam, count = "axis", axisCount
    else
        presentTeam, count = "allies", alliesCount
    end

    local currentHolder = self:GetCapturingTeam()
    local rate = ix.capture.BASE_RATE * (ix.capture.ATTACKER_MULT ^ (count - 1))

    if (currentHolder ~= "" and currentHolder ~= nil and currentHolder ~= presentTeam) then
        -- Different team is in the zone than the one whose progress is on the bar.
        -- Drain the existing progress down to 0 before letting the new team build
        -- their own. While draining, keep CapturingTeam set to the original holder
        -- so the bar color doesn't flip mid-drain.
        local drained = math.Clamp(self:GetProgress() - rate * dt, 0, 1)
        self:SetProgress(drained)

        if (drained <= 0) then
            -- Drain finished. Hand the point over to the team in the zone; their
            -- next tick will start filling from 0.
            self:SetCapturingTeam(presentTeam)
            self:SetProgress(0)
        end
        return true
    end

    -- Same team as the existing holder (or empty holder) → fill normally.
    if (currentHolder ~= presentTeam) then
        self:SetCapturingTeam(presentTeam)
    end

    local oldProgress = self:GetProgress()
    local newProgress = math.Clamp(oldProgress + rate * dt, 0, 1)
    self:SetProgress(newProgress)

    -- Only fire the hook on the TRANSITION to full (was <1, now =1).
    -- Without this guard the hook would spam every tick while a player
    -- stands on a point they already hold.
    -- IMPORTANT: do NOT lock the point. Live captures: it stays unlocked
    -- so the other team can retake it. The meeting resolution code (in
    -- sv_meeting.lua) decides whether the engagement is over by checking
    -- whether one team holds ALL neutrals.
    if (oldProgress < 1.0 and newProgress >= 1.0) then
        hook.Run("NeutralCapturePointTaken", self, presentTeam)
    end

    return true
end

function ENT:OnTakeDamage(dmg)
    return 0
end

function ENT:OnRemove()
    if (ix.capture and ix.capture.Unregister) then
        ix.capture.Unregister(self)
    end
end