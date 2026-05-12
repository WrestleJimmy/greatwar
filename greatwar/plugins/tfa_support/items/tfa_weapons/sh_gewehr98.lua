ITEM.name = "Gewehr 98"
ITEM.description = "A long and imposing weapon that demands respect."
ITEM.model = "models/weapons/w_verdun_g98.mdl"
ITEM.width = 4
ITEM.height = 1
ITEM.iconCam = {
    pos = Vector(-3.25, 199.94, 0),
    ang = Angle(-0.05, 271.8, 0),
    fov = 16.76
}

ITEM.class = "tfa_gwsr_gewehr_98"
ITEM.weaponCategory = "Primary"


-- =====================================================================
-- Faction-locked ammo (added by ammo plugin)
-- =====================================================================
-- The ammo plugin's PlayerLoadout hook reads this field at equip time
-- and patches the SWEP instance's Primary.Ammo via SetStatRawL. The
-- underlying SWEP file (tfa_verdun_g98) declares Primary.Ammo as
-- "SniperPenetratedRound" — we override that to "bolt_axis" per
-- instance, so reloads pull from our German bolt ammo pool only.
ITEM.ammoType = "bolt_axis"
ITEM.faction  = "axis"

-- Default starting attachments (none for the basic infantry rifle).
-- Bayonet and scope are handled separately as attachment items.
ITEM.attachments = {}
