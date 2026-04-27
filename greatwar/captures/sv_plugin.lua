local PLUGIN = PLUGIN

-- ============================================================
-- Per-entity tick logic. Called from ix_capture_base:Think.
-- Counts attackers / defenders inside the cylinder, updates
-- progress, and fires CapturePointTaken on completion.
-- ============================================================

function PLUGIN:UpdateCapturePoint(ent, dt)
    if (not IsValid(ent)) then return end
    if (ent:GetLocked()) then return end

    local defenderTeam = ent:GetTeam()
    local attackerTeam = ix.capture.GetAttackerTeam(defenderTeam)
    if (not attackerTeam) then return end

    local origin  = ent:GetPos()
    local radSq   = ix.capture.RADIUS * ix.capture.RADIUS
    local zRange  = ix.capture.HEIGHT

    local attackers, defenders = 0, 0

    for _, ply in ipairs(player.GetAll()) do
        if (not ply:Alive()) then continue end

        local char = ply:GetCharacter()
        if (not char) then continue end

        local pos = ply:GetPos()
        if (math.abs(pos.z - origin.z) > zRange) then continue end

        local dx, dy = pos.x - origin.x, pos.y - origin.y
        if (dx * dx + dy * dy > radSq) then continue end

        if (ix.team and ix.team.IsOnTeam) then
            if (ix.team.IsOnTeam(char, attackerTeam)) then
                attackers = attackers + 1
            elseif (ix.team.IsOnTeam(char, defenderTeam)) then
                defenders = defenders + 1
            end
        end
    end

    -- Contested: any defender present halts progress, but we still
    -- show the capturing team so HUD reflects who's trying.
    if (attackers > 0 and defenders > 0) then
        ent:SetContested(true)
        ent:SetCapturingTeam(attackerTeam)
        return
    end

    ent:SetContested(false)

    if (attackers <= 0) then
        -- No decay; just clear the "capturing" flag if nothing's banked
        if (ent:GetProgress() <= 0) then
            ent:SetCapturingTeam("")
        end
        return
    end

    -- Apply capture rate
    ent:SetCapturingTeam(attackerTeam)

    local rate = ix.capture.BASE_RATE * (ix.capture.ATTACKER_MULT ^ (attackers - 1))
    local newProgress = math.Clamp(ent:GetProgress() + rate * dt, 0, 1)
    ent:SetProgress(newProgress)

    if (newProgress >= 1.0) then
        ent:SetLocked(true)

        -- Hook for assault orchestrator, war diary, sounds, etc.
        hook.Run("CapturePointTaken", ent, attackerTeam)

        local sector = ent:GetSectorID() or "?"
        local slot   = ent:GetSlotID()   or "?"
        for _, ply in ipairs(player.GetAll()) do
            ply:ChatPrint(string.format("[CAPTURE] Objective %s%s taken by %s.",
                sector, slot, attackerTeam))
        end
    end
end
