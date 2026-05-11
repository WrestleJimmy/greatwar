print("[AMMO] sv_plugin.lua loaded")

local PLUGIN = PLUGIN

-- =====================================================================
-- Pool sync: inventory → engine ammo pool
-- =====================================================================
-- Invariant we maintain: client:GetAmmoCount(ammoType) equals the sum
-- of all stacks of items with that ammoType in the player's inventory.
--
-- Called whenever inventory state changes for one of our managed
-- ammo types. Walks inventory once, totals up, and sets the pool.
function PLUGIN:SyncAmmoPool(client, ammoType)
    if not IsValid(client) or not client:IsPlayer() then return end
    if not ammoType or not ix.ammoSystem.IsManaged(ammoType) then return end

    local char = client:GetCharacter()
    if not char then return end
    local inv = char:GetInventory()
    if not inv then return end

    local total = 0
    for _, invItem in pairs(inv:GetItems()) do
        -- Match by base AND ammoType. The base check is critical: weapon
        -- items also declare ammoType (to tell us which pool they use),
        -- but they're NOT ammo stacks. Only items inheriting from
        -- base_gw_ammo are stackable rounds.
        if invItem.base == "base_gw_ammo" and invItem.ammoType == ammoType then
            -- Stackable plugin stores count in "amount" data.
            -- A fresh stack with no data defaults to 1 round.
            total = total + (invItem:GetData("amount", 1))
        end
    end

    -- Cap at 9999 just to avoid weird engine clamps.
    total = math.min(total, 9999)

    client:SetAmmo(total, ammoType)
end

-- Resync ALL managed ammo types for a player. Used on spawn,
-- character load, and as a belt-and-suspenders refresh.
function PLUGIN:SyncAllAmmoPools(client)
    if not IsValid(client) or not client:IsPlayer() then return end
    for ammoType, _ in pairs(ix.ammoSystem.TYPES) do
        self:SyncAmmoPool(client, ammoType)
    end
end

-- =====================================================================
-- Pool sync: pool → inventory (after reload)
-- =====================================================================
-- After TFA's reload finishes draining the engine pool, we walk
-- inventory and DECREMENT stacks until inv total matches the pool.
-- This is what actually deletes rounds from the player's inventory
-- when they reload — TFA already took them from the pool.
local function DrainInventoryToPool(client, ammoType)
    if not IsValid(client) then return end
    local char = client:GetCharacter()
    if not char then return end
    local inv = char:GetInventory()
    if not inv then return end

    local poolNow = client:GetAmmoCount(ammoType)

    -- Total what's in inventory. Only count actual ammo stacks
    -- (base == "base_gw_ammo") — weapons also have ammoType but we
    -- must not treat them as ammo and Remove() them.
    local stacks = {}
    local invTotal = 0
    for _, invItem in pairs(inv:GetItems()) do
        if invItem.base == "base_gw_ammo" and invItem.ammoType == ammoType then
            stacks[#stacks + 1] = invItem
            invTotal = invTotal + invItem:GetData("amount", 1)
        end
    end

    -- We need to remove (invTotal - poolNow) rounds from inventory.
    local needToRemove = invTotal - poolNow
    if needToRemove <= 0 then
        -- Inventory already matches (or pool is somehow higher — that
        -- shouldn't happen but isn't worth panicking over).
        return
    end

    -- Drain stacks oldest-first. Remove fully-emptied ones.
    -- Iterating a snapshot list since we're mutating the inventory.
    for _, stack in ipairs(stacks) do
        if needToRemove <= 0 then break end
        local count = stack:GetData("amount", 1)
        if count <= needToRemove then
            needToRemove = needToRemove - count
            stack:Remove()
        else
            stack:SetData("amount", count - needToRemove)
            needToRemove = 0
        end
    end
end

-- =====================================================================
-- Reload bridge — TFA hooks
-- =====================================================================
-- TFA fires these in the reload state machine. The two we care about:
--   TFA_PostReload     — fires after a single-stage reload completes
--   TFA_CompleteReload — same purpose but a different code path
-- We hook both with the same handler. For looped (shotgun-style)
-- reloads, TFA decrements ammo per shell insert and the loop ends
-- when Ammo1() <= 0, so we don't need a per-shell hook — just sync
-- inventory once when the loop terminates.
--
-- The loop-end signal isn't a clean hook, but TFA_PostReload fires
-- after the reload status transitions out. Plus, just to be safe,
-- we also re-sync on any weapon's idle status check via a slow
-- timer per player, catching anything we miss.
local function OnReloadComplete(weapon)
    if not IsValid(weapon) then return end
    local owner = weapon:GetOwner()
    if not IsValid(owner) or not owner:IsPlayer() then return end

    -- weapon:GetPrimaryAmmoType() returns a numeric ID, but our
    -- ix.ammoSystem.TYPES table is keyed by ammo NAME strings. Convert
    -- with game.GetAmmoName before lookup. (Worth catching: stock
    -- HL2 ammos have IDs but their names are auto-generated lowercase.)
    local ammoID = weapon:GetPrimaryAmmoType()
    local ammoType = game.GetAmmoName(ammoID)
    if not ammoType or not ix.ammoSystem.IsManaged(ammoType) then return end

    -- Defer one tick: TFA's complete-reload code path does a few
    -- bookkeeping things after firing the hook, and we want the
    -- pool to be in its final post-reload state when we drain.
    timer.Simple(0, function()
        if not IsValid(owner) then return end
        DrainInventoryToPool(owner, ammoType)
    end)
end

hook.Add("TFA_PostReload",     "ixAmmoOnReload_Post",     OnReloadComplete)
hook.Add("TFA_CompleteReload", "ixAmmoOnReload_Complete", OnReloadComplete)

-- =====================================================================
-- Per-shell drain (looped reloads only)
-- =====================================================================
-- For looped/shotgun-style reloads (SMLE, Mauser stripper-clip, future
-- shotguns), TFA fires TFA_LoadShell once per shell-insert. We drain
-- one round from inventory per shell so the player sees rounds vanish
-- in real time instead of waiting until the whole loop finishes.
--
-- The OnReloadComplete handler still runs on TFA_PostReload as a final
-- reconciliation in case shells fail to insert (jam, interrupted, etc.).
hook.Add("TFA_LoadShell", "ixAmmoOnLoadShell", function(weapon)
    if not IsValid(weapon) then return end
    local owner = weapon:GetOwner()
    if not IsValid(owner) or not owner:IsPlayer() then return end

    local ammoID = weapon:GetPrimaryAmmoType()
    local ammoType = game.GetAmmoName(ammoID)
    if not ammoType or not ix.ammoSystem.IsManaged(ammoType) then return end

    -- TFA_LoadShell fires at the START of the shell-insert animation,
    -- BEFORE TFA decrements the pool. Wait for the animation to play
    -- out (LoopedReloadInsertTime, typically 0.35s) so the pool reflects
    -- the actual insert when we drain.
    --
    -- We use the weapon's stat for the timing if available, else 0.4s
    -- as a safe default that's slightly longer than typical insert time.
    local insertTime = 0.4
    if weapon.GetStatL then
        insertTime = weapon:GetStatL("LoopedReloadInsertTime") or 0.4
    end

    timer.Simple(insertTime + 0.05, function()
        if not IsValid(owner) then return end
        DrainInventoryToPool(owner, ammoType)
    end)
end)

-- =====================================================================
-- ix.ammoSystem.GiveStacked: smart-stacking inventory add
-- =====================================================================
-- Distributes `count` rounds of `ammoType` into the player's inventory.
-- Behavior:
--   1. Find existing non-full stacks of that type. Top them off first.
--   2. If rounds remain, create new stacks of STACK_MAX until exhausted.
--   3. Final partial stack carries the remainder.
--   4. If the inventory has no room for new stacks, the surplus is
--      returned (as a number) so the caller can decide what to do
--      (drop on ground, refund, log, etc.).
--
-- Returns the number of rounds that COULD NOT be added (0 on success).
function ix.ammoSystem.GiveStacked(client, ammoType, count)
    if not IsValid(client) or not client:IsPlayer() then return count end
    if not ix.ammoSystem.IsManaged(ammoType) then return count end
    if not count or count <= 0 then return 0 end

    local char = client:GetCharacter()
    if not char then return count end
    local inv = char:GetInventory()
    if not inv then return count end

    local typeInfo = ix.ammoSystem.TYPES[ammoType]
    if not typeInfo then return count end

    local stackMax = ix.ammoSystem.STACK_MAX
    local itemUniqueID = "ammo_" .. typeInfo.class .. "_" .. typeInfo.faction
    local remaining = count

    -- Step 1: top off existing non-full stacks of the same type.
    -- Iterate a snapshot so SetData mutations don't disturb the loop.
    local existingStacks = {}
    for _, invItem in pairs(inv:GetItems()) do
        if invItem.base == "base_gw_ammo"
           and invItem.ammoType == ammoType
           and invItem.uniqueID == itemUniqueID then
            existingStacks[#existingStacks + 1] = invItem
        end
    end

    for _, stack in ipairs(existingStacks) do
        if remaining <= 0 then break end
        local current = stack:GetData("amount", 1)
        local space = stackMax - current
        if space > 0 then
            local addNow = math.min(space, remaining)
            stack:SetData("amount", current + addNow)
            remaining = remaining - addNow
        end
    end

    -- Step 2: create new stacks for any leftover. Use inv:Add which
    -- finds an empty slot. If Add fails (no room), bail out and
    -- return the surplus.
    while remaining > 0 do
        local thisStack = math.min(remaining, stackMax)
        local result = inv:Add(itemUniqueID, 1, { amount = thisStack })
        if not result then
            -- Inventory is full. Return what couldn't fit.
            return remaining
        end
        remaining = remaining - thisStack
    end

    -- A pool sync will fire from the OnInstanced hook on new stacks,
    -- but for the SetData top-off case OnInstanced doesn't fire (we
    -- mutated an existing item, not created one). Force a final sync.
    PLUGIN:SyncAmmoPool(client, ammoType)

    return 0
end

-- =====================================================================
-- (No polling timer — see comment below)
-- =====================================================================
-- We deliberately do NOT run a periodic pool-sync timer. Such a timer
-- has two failure modes that I tried earlier and both bit:
--
-- 1. "Drain inventory to match pool" — destroys all inventory ammo if
--    the pool transiently reads 0 (weapon switch, server hiccup,
--    client desync). Catastrophic.
--
-- 2. "Set pool to match inventory" — opens a duping exploit where a
--    player interrupts a looped reload mid-shell-insert. TFA has
--    already transferred N rounds from pool→clip, but inventory still
--    shows the pre-reload total. The timer "restores" pool to that
--    total, and now the player has the rounds in the clip AND the
--    rounds in inventory.
--
-- Solution: rely entirely on event-driven sync.
--   - SyncAmmoPool fires on item OnInstanced/OnTransferred/OnRemoved
--     (whenever inventory state changes).
--   - DrainInventoryToPool fires on TFA_PostReload/CompleteReload
--     (whenever pool decreases from a reload).
--
-- If a sync gets missed, the player can fix it by toggling the weapon
-- (unequip and re-equip) which re-runs the equip-time sync. We can add
-- targeted recovery if specific cases fail in testing.

-- =====================================================================
-- Weapon equip patching: faction-lock the SWEP at equip time
-- =====================================================================
-- The TFA item base (base_tfa_weapons) calls ix.tfa.InitWeapon on
-- equip, and individual TFA items can also define OnEquipWeapon. We
-- hook the latter to patch the weapon instance's Primary.Ammo to
-- match the ITEM's ammoType field.
--
-- Only patches weapons whose ITEM declares an ammoType — leaves
-- vanilla/unmanaged weapons alone.
hook.Add("PlayerLoadout", "ixAmmoFactionPatchLoadout", function(client)
    -- After spawn/loadout, walk currently-held weapons and (re)sync
    -- their ammo pool. Since you've edited the SWEP files directly to
    -- declare Primary.Ammo = "bolt_axis"/"bolt_allies", we no longer
    -- need to patch via SetStatRawL — the SWEP class already has the
    -- right ammo type baked in. But we DO need to ensure the engine
    -- pool reflects the player's inventory at spawn time.
    timer.Simple(0.1, function()
        if not IsValid(client) then return end
        for _, wep in ipairs(client:GetWeapons()) do
            if not IsValid(wep) then continue end
            local item = wep.ixItem
            if not item or not item.ammoType then continue end
            if not ix.ammoSystem.IsManaged(item.ammoType) then continue end

            -- Sync the engine ammo pool to inventory total. This handles
            -- the case where a player respawns with ammo in inventory
            -- (e.g. carried over via a class kit or corpse loot).
            PLUGIN:SyncAmmoPool(client, item.ammoType)
        end
    end)
end)

-- =====================================================================
-- Spawn kit
-- =====================================================================
-- Per design: rear (reserve) spawn gives a free kit (weapon + ammo).
-- Front (forward) spawn gives weapon only, soldier withdraws from depot.
--
-- This requires knowing which spawn type the player just spawned at.
-- The spawnsystem plugin tracks ix.spawn.lastSpawnType[steamid] (or
-- similar) — if not, we infer from position vs registered spawns.
-- For now we assume ix.spawn.GetLastSpawnType(client) exists and
-- returns "forward" | "reserve" | nil.
--
-- ix.ammoSystem.RESERVE_SPAWN_ROUNDS rounds get split into stacks of
-- STACK_MAX and added to inventory, ammoType matching their primary
-- weapon's declared ammoType.
local function GiveSpawnKit(client)
    if not IsValid(client) then return end
    local char = client:GetCharacter()
    if not char then return end
    local inv = char:GetInventory()
    if not inv then return end

    -- Determine spawn type. ix.spawn might not expose GetLastSpawnType,
    -- so we fall back to "no kit" (forward-spawn behavior) if absent.
    local spawnType = "forward"  -- safe default = no kit
    if ix.spawn and ix.spawn.GetLastSpawnType then
        spawnType = ix.spawn.GetLastSpawnType(client) or "forward"
    end

    if spawnType ~= "reserve" then return end  -- forward = no kit

    -- Find the player's primary weapon item (already given by class
    -- system) and figure out what ammoType it needs.
    local primaryAmmoType
    for _, invItem in pairs(inv:GetItems()) do
        if invItem.weaponCategory == "Primary"
           and invItem.ammoType
           and ix.ammoSystem.IsManaged(invItem.ammoType) then
            primaryAmmoType = invItem.ammoType
            break
        end
    end

    if not primaryAmmoType then return end  -- no recognized primary

    -- Hand off to GiveStacked. It tops off any existing partial stacks
    -- before creating new ones, so a soldier carrying over a half-full
    -- stack from a previous life gets it filled rather than fragmented.
    local surplus = ix.ammoSystem.GiveStacked(client, primaryAmmoType, ix.ammoSystem.RESERVE_SPAWN_ROUNDS)
    if surplus > 0 then
        client:Notify(string.format(
            "Inventory full — %d rounds couldn't be issued.", surplus))
    end
end

-- Hook PlayerSpawn (Helix's CharacterLoaded fires too early — char
-- inventory may not be fully loaded). Defer a bit so inventory is
-- definitely settled before we add items.
hook.Add("PlayerSpawn", "ixAmmoGiveSpawnKit", function(client)
    timer.Simple(1, function()
        GiveSpawnKit(client)
    end)
end)

-- =====================================================================
-- Stack split receiver
-- =====================================================================
-- Client sent a request to split N rounds off this stack into a new one.
-- Validate ownership, validate amount, find an empty slot, perform.
net.Receive("ixAmmoSplit", function(len, client)
    if not IsValid(client) then return end
    local itemID = net.ReadUInt(32)
    local amount = net.ReadUInt(7)

    local item = ix.item.instances[itemID]
    if not item then return end
    if item.base ~= "base_gw_ammo" then return end

    -- Ownership: caller must be holding this item.
    local owner = item:GetOwner()
    if owner ~= client then
        client:Notify("That stack isn't in your inventory.")
        return
    end

    local current = item:GetData("amount", 1)
    if amount < 1 or amount >= current then
        client:Notify("Invalid split amount.")
        return
    end

    local char = client:GetCharacter()
    if not char then return end
    local inv = char:GetInventory()
    if not inv then return end

    -- Try to add the new stack — Add returns falsy if no room.
    local result = inv:Add(item.uniqueID, 1, { amount = amount })
    if not result then
        client:Notify("No room in inventory to split.")
        return
    end

    -- Decrement the source stack.
    item:SetData("amount", current - amount)

    -- Pool stays the same (we just moved rounds between stacks), but
    -- defensively re-sync in case anything is off.
    PLUGIN:SyncAmmoPool(client, item.ammoType)
end)

-- =====================================================================
-- Initial sync on character load
-- =====================================================================
-- When a player's character loads, sync all ammo pools so the engine
-- pool matches whatever stacks they have in inventory (carried over
-- from a previous life, picked up from a corpse, etc.).
hook.Add("PlayerLoadedCharacter", "ixAmmoSyncOnCharLoad", function(client, character)
    timer.Simple(0.5, function()
        if not IsValid(client) then return end
        PLUGIN:SyncAllAmmoPools(client)
    end)
end)

-- Also sync on initial spawn.
hook.Add("PlayerInitialSpawn", "ixAmmoSyncOnInitialSpawn", function(client)
    timer.Simple(2, function()
        if not IsValid(client) then return end
        PLUGIN:SyncAllAmmoPools(client)
    end)
end)