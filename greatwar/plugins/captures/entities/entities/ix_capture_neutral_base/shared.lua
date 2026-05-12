ENT.Type      = "anim"
ENT.Base      = "base_anim"
ENT.PrintName = "Capture Point (Neutral / Base)"
ENT.Author    = "WrestleJimmy"
ENT.Category  = "Helix - Captures"
ENT.Spawnable = false  -- only the spawnable subclass appears in the menu
ENT.AdminOnly = true

ENT.Model = "models/hunter/blocks/cube05x05x05.mdl"

-- Subclasses leave this as "neutral".
ENT.Team = "neutral"

-- ============================================================
-- Network vars
--
-- IDENTICAL slot layout to ix_capture_base. The HUD and 3D2D code
-- read these by name (GetTeam / GetProgress / etc.) so functionally
-- order doesn't matter — but keeping slot indices identical avoids
-- any chance of conflict.
--
-- Interpretation differs from team-locked points:
--   Team           = "neutral" (sentinel; never axis/allies)
--   CapturingTeam  = whichever side is currently progressing the cap
--                    (can be axis OR allies; flips between them)
--   Progress       = 0..1, owned by the current CapturingTeam.
--                    If cap team flips, progress resets.
-- ============================================================

function ENT:SetupDataTables()
    self:NetworkVar("Float",  0, "Progress")
    self:NetworkVar("Bool",   0, "Contested")
    self:NetworkVar("Bool",   1, "Locked")
    self:NetworkVar("String", 0, "CapturingTeam")
    self:NetworkVar("String", 1, "Team")
    self:NetworkVar("String", 2, "SectorID")
    self:NetworkVar("String", 3, "SlotID")
end