PLUGIN.name        = "Ammo"
PLUGIN.author      = "Schema"
PLUGIN.description = "Faction-locked ammo system. Stacks in inventory act as the reserve pool — TFA reloads pull from inventory automatically. Includes deposit entities for resupply."

print("[AMMO] sh_plugin.lua loaded on", SERVER and "SERVER" or "CLIENT")

local PLUGIN = PLUGIN

-- =====================================================================
-- ix.ammoSystem — namespace for our ammo system
-- =====================================================================
-- Note: NOT named ix.ammo because Helix's stock base_ammo registers a
-- top-level ix.ammo namespace at item-load time. Don't collide.
ix.ammoSystem = ix.ammoSystem or {}

-- =====================================================================
-- Ammo type catalog
-- =====================================================================
-- The 6 (faction × class) ammo types. Keys are the GMod ammo type
-- strings (registered with game.AddAmmoType below) AND the lookup
-- string for everything in the system.
ix.ammoSystem.TYPES = {
    pistol_axis   = { faction = "axis",   class = "pistol", displayName = "9mm Parabellum" },
    pistol_allies = { faction = "allies", class = "pistol", displayName = ".455 Webley"     },
    bolt_axis     = { faction = "axis",   class = "bolt",   displayName = "7.92×57mm Mauser" },
    bolt_allies   = { faction = "allies", class = "bolt",   displayName = ".303 British"     },
    mg_axis       = { faction = "axis",   class = "mg",     displayName = "7.92×57mm MG"    },
    mg_allies     = { faction = "allies", class = "mg",     displayName = ".303 MG"         },
}

-- Helper: returns true if `ammoType` is one of ours.
function ix.ammoSystem.IsManaged(ammoType)
    return ix.ammoSystem.TYPES[ammoType] ~= nil
end

-- Helper: returns faction string ("axis"|"allies") or nil.
function ix.ammoSystem.GetFaction(ammoType)
    local entry = ix.ammoSystem.TYPES[ammoType]
    return entry and entry.faction or nil
end

-- Helper: returns class string ("pistol"|"bolt"|"mg") or nil.
function ix.ammoSystem.GetClass(ammoType)
    local entry = ix.ammoSystem.TYPES[ammoType]
    return entry and entry.class or nil
end

-- =====================================================================
-- Tunables
-- =====================================================================
-- Stack size cap for ammo items. Stacking plugin enforces this via
-- ITEM.max on the base.
ix.ammoSystem.STACK_MAX = 10

-- Per-class deposit caps. All set to 20 for testing per design doc.
-- Tune later. Per-class because we want a depot spammed with pistol
-- rounds to still have room for bolt rounds.
ix.ammoSystem.DEPOT_CAPS = {
    pistol = 20,
    bolt   = 20,
    mg     = 20,
}

-- Per-Take stack size from depot. Each Take action gives one full stack
-- of this many rounds (or less if depot has less remaining).
ix.ammoSystem.WITHDRAW_STACK = 10

-- Readiness reward per ammo class deposited. Ready-to-flip later if you
-- want different rewards per class. Right now: +1 per round, all classes.
ix.ammoSystem.DEPOSIT_REWARD_BY_CLASS = {
    pistol = 1,
    bolt   = 1,
    mg     = 1,
}

-- Reserve spawn kit size. Players spawning at the rear get this many
-- rounds of their assigned weapon's ammo type, distributed as full stacks.
ix.ammoSystem.RESERVE_SPAWN_ROUNDS = 30

-- Depot log size. Smaller than HQ readiness log because it's per-depot
-- and per-deposit/withdraw events accumulate fast.
ix.ammoSystem.DEPOT_LOG_MAX = 30

-- =====================================================================
-- GMod ammo type registration
-- =====================================================================
-- Register all 6 strings as real GMod ammo types so client:GiveAmmo,
-- client:GetAmmoCount, weapon:GetPrimaryAmmoType etc. recognize them.
-- The damage/force values mirror SniperPenetratedRound (the type the
-- existing rifles already used) since this is what they were tuned for.
local AMMO_PROPS = {
    pistol = { dmgtype = DMG_BULLET, npcdmg = 8,  pldmg = 8,  force = 800,  tracer = TRACER_LINE, plydmg = 8 },
    bolt   = { dmgtype = DMG_BULLET, npcdmg = 80, pldmg = 80, force = 5800, tracer = TRACER_LINE, plydmg = 80 },
    mg     = { dmgtype = DMG_BULLET, npcdmg = 80, pldmg = 80, force = 5800, tracer = TRACER_LINE, plydmg = 80 },
}

for ammoType, info in pairs(ix.ammoSystem.TYPES) do
    local props = AMMO_PROPS[info.class]
    if props then
        game.AddAmmoType({
            name     = ammoType,
            dmgtype  = props.dmgtype,
            tracer   = props.tracer,
            plydmg   = props.plydmg,
            npcdmg   = props.npcdmg,
            force    = props.force,
            minsplash = 4,
            maxsplash = 8,
        })
    end
end

-- =====================================================================
-- Network strings
-- =====================================================================
if SERVER then
    util.AddNetworkString("ixAmmoDepotOpen")        -- open depot UI
    util.AddNetworkString("ixAmmoDepotAction")      -- client → server: deposit/withdraw
    util.AddNetworkString("ixAmmoDepotSync")        -- server → all team: stockpile counts changed
    util.AddNetworkString("ixAmmoDepotLogSync")     -- server → all team: new log entry
    util.AddNetworkString("ixAmmoSplit")            -- client → server: split a stack
end

-- =====================================================================
-- Realm-specific files
-- =====================================================================
ix.util.Include("sv_plugin.lua", "server")
ix.util.Include("cl_plugin.lua", "client")
ix.util.Include("sh_commands.lua", "shared")