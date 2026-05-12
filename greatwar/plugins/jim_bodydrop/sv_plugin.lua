local PLUGIN = PLUGIN

-- ─────────────────────────────────────────────────────────────────────────────
-- CONFIG
-- ─────────────────────────────────────────────────────────────────────────────

-- How much of the player's death velocity carries into the ragdoll (0–1).
-- 0 = dead stop/crumple in place. 1 = full momentum carry.
local VELOCITY_CARRY = 0.4

-- Damping on bones to kill bouncy jelly behaviour.
-- Higher = stiffer, settles faster.
local LINEAR_DAMPING  = 2.0
local ANGULAR_DAMPING = 2.0

-- ─────────────────────────────────────────────────────────────────────────────
-- HOOK
-- ─────────────────────────────────────────────────────────────────────────────

hook.Add("DoPlayerDeath", "ixRagdollCrumple_Apply", function(client, attacker, dmginfo)
    -- Wait one tick for Helix to spawn the ragdoll.
    timer.Simple(0, function()
        if (!IsValid(client)) then return end

        local ragdoll = client.ixRagdoll
        if (!IsValid(ragdoll)) then
            ragdoll = IsValid(client:GetRagdollEntity()) and client:GetRagdollEntity() or nil
        end
        if (!IsValid(ragdoll)) then return end

        local deathVel = client:GetVelocity() * VELOCITY_CARRY

        for i = 0, ragdoll:GetPhysicsObjectCount() - 1 do
            local phys = ragdoll:GetPhysicsObjectNum(i)
            if (!IsValid(phys)) then continue end

            -- Gravity stays ON — bodies fall and crumple naturally.
            phys:EnableGravity(true)
            phys:SetDamping(LINEAR_DAMPING, ANGULAR_DAMPING)
            phys:SetVelocity(deathVel)
        end
    end)
end)