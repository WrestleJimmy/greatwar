-- =====================================================================
-- greatwar/plugins/ammo/sh_commands.lua
-- =====================================================================
-- Admin commands for the ammo system. Two commands live here:
--
--   /CharGiveItem  -- OVERRIDE of Helix's stock command. We intercept
--                     when the requested item is one of our ammo types
--                     and route through ix.ammoSystem.GiveStacked so the
--                     count parameter means "rounds" and stacks merge
--                     automatically. Non-ammo items fall through to the
--                     original behavior.
--
--   /GiveAmmo      -- Friendlier alias for ammo specifically. Accepts
--                     several spellings of the ammo type (the GMod ammo
--                     type string, the item uniqueID, the displayName,
--                     or a fuzzy match on the description like "303"
--                     or "Mauser").
--
-- Why both: the override is the safety net — it catches admins typing
-- /CharGiveItem out of habit AND any other plugin that calls the same
-- command path. The /GiveAmmo alias is the explicit, less-error-prone
-- form for ammo specifically.
--
-- IMPORTANT: this file is NOT auto-loaded by Helix. It must be included
-- explicitly from sh_plugin.lua via `ix.util.Include("sh_commands.lua")`.
-- See the per-plugin loader quirk note in CLAUDE handoff doc §4.
-- =====================================================================

local PLUGIN = PLUGIN

print("[AMMO] sh_commands.lua loaded on", SERVER and "SERVER" or "CLIENT")

-- =====================================================================
-- Resolution helper: input string → ammoType key
-- =====================================================================
-- Accepts any of:
--   * The ammoType key itself ("bolt_allies")
--   * The item uniqueID ("ammo_bolt_allies")
--   * The displayName (".303 British" or any case variant)
--   * A substring match on description, displayName, or item name
--     (e.g. "303", "Mauser", "Webley")
--
-- Returns the canonical ammoType string ("bolt_allies") or nil if
-- nothing resolved cleanly. On ambiguous matches (multiple types
-- contain the substring), prefers exact matches first; if still
-- ambiguous, returns nil so the caller can complain.
local function ResolveAmmoType(input)
    if not input or input == "" then return nil end
    local q = string.lower(tostring(input))

    -- Direct ammoType key match.
    if ix.ammoSystem.TYPES[q] then
        return q
    end

    -- "ammo_<class>_<faction>" → strip "ammo_" prefix.
    if q:sub(1, 5) == "ammo_" then
        local stripped = q:sub(6)
        if ix.ammoSystem.TYPES[stripped] then
            return stripped
        end
    end

    -- Try displayName exact-ish match (case-insensitive, trimmed).
    for ammoType, info in pairs(ix.ammoSystem.TYPES) do
        if info.displayName and string.lower(info.displayName) == q then
            return ammoType
        end
    end

    -- Substring fallback. Walk all types, collect candidates whose
    -- ammoType, displayName, or item name contains the query.
    local candidates = {}
    for ammoType, info in pairs(ix.ammoSystem.TYPES) do
        local hay = string.lower(ammoType)
        if hay:find(q, 1, true) then
            candidates[#candidates + 1] = ammoType
        else
            -- Check the displayName.
            if info.displayName and string.lower(info.displayName):find(q, 1, true) then
                candidates[#candidates + 1] = ammoType
            else
                -- Check the registered item's display name (e.g. "Mauser",
                -- "British", "Webley"). We have to look up the item table.
                local itemUniqueID = "ammo_" .. info.class .. "_" .. info.faction
                local itemTable = ix.item.list[itemUniqueID]
                if itemTable and itemTable.name
                   and string.lower(itemTable.name):find(q, 1, true) then
                    candidates[#candidates + 1] = ammoType
                end
            end
        end
    end

    if #candidates == 1 then
        return candidates[1]
    end

    -- More than one match → caller will need to disambiguate.
    return nil, candidates
end

-- =====================================================================
-- Helper: format a list of ammoType keys for an error message.
-- =====================================================================
local function ListAmmoTypes(types)
    local parts = {}
    for _, t in ipairs(types) do
        local info = ix.ammoSystem.TYPES[t]
        if info and info.displayName then
            parts[#parts + 1] = string.format("%s (%s)", t, info.displayName)
        else
            parts[#parts + 1] = t
        end
    end
    return table.concat(parts, ", ")
end

-- =====================================================================
-- Helper: detect "is this uniqueID an ammo item" without needing the
-- ammoType — used by the /CharGiveItem override.
-- =====================================================================
-- Returns the ammoType string if so, nil otherwise.
local function GetAmmoTypeForUniqueID(uniqueID)
    local itemTable = ix.item.list[uniqueID]
    if not itemTable then return nil end
    if itemTable.base ~= "base_gw_ammo" then return nil end
    if not itemTable.ammoType then return nil end
    if not ix.ammoSystem.IsManaged(itemTable.ammoType) then return nil end
    return itemTable.ammoType
end

-- =====================================================================
-- /GiveAmmo <character> <ammo> [rounds]
-- =====================================================================
-- Friendly admin command. Treats `rounds` as INDIVIDUAL ROUNDS (not
-- stacks) and routes through GiveStacked, so 30 rounds becomes 3 stacks
-- of 10 (or tops off existing partial stacks first).
--
-- Default rounds = STACK_MAX (one full stack) if unspecified.
ix.command.Add("GiveAmmo", {
    description    = "Give a character ammunition, auto-merged into stacks. Count is in rounds.",
    superAdminOnly = true,
    arguments      = {
        ix.type.character,
        ix.type.string,
        bit.bor(ix.type.number, ix.type.optional),
    },
    argumentNames  = { "target", "ammo", "rounds" },
    OnRun = function(self, client, target, ammoInput, rounds)
        local ammoType, ambiguous = ResolveAmmoType(ammoInput)

        if not ammoType then
            if ambiguous and #ambiguous > 1 then
                return string.format(
                    "Ambiguous ammo: '%s' matches multiple types: %s. Be more specific.",
                    ammoInput, ListAmmoTypes(ambiguous))
            end
            -- No match at all — list what's available.
            local all = {}
            for k, _ in pairs(ix.ammoSystem.TYPES) do all[#all + 1] = k end
            table.sort(all)
            return string.format(
                "Unknown ammo type: '%s'. Valid: %s.",
                ammoInput, table.concat(all, ", "))
        end

        rounds = rounds or ix.ammoSystem.STACK_MAX
        rounds = math.floor(rounds)
        if rounds <= 0 then
            return "Round count must be positive."
        end
        -- Sanity ceiling. If you really need 5,000 rounds, raise this
        -- or run the command twice. Mostly here to prevent typo'd
        -- /GiveAmmo target ammo 999999 from filling the inventory and
        -- spawning 100,000 leftover stacks on the floor.
        if rounds > 1000 then
            return "Refusing to give more than 1000 rounds in a single command."
        end

        local targetPlayer = target:GetPlayer()
        if not IsValid(targetPlayer) then
            return "Target is not currently online."
        end

        local surplus = ix.ammoSystem.GiveStacked(targetPlayer, ammoType, rounds)
        local actuallyGiven = rounds - surplus

        if actuallyGiven <= 0 then
            return string.format(
                "Could not give any rounds — target's inventory is full (surplus: %d).",
                surplus)
        end

        local typeInfo = ix.ammoSystem.TYPES[ammoType]
        local typeName = (typeInfo and typeInfo.displayName) or ammoType

        targetPlayer:NotifyLocalized("itemCreated")  -- reuses existing localized string

        if surplus > 0 then
            return string.format(
                "Gave %s %d rounds of %s (%d couldn't fit).",
                target:GetName(), actuallyGiven, typeName, surplus)
        end
        return string.format(
            "Gave %s %d rounds of %s.",
            target:GetName(), actuallyGiven, typeName)
    end
})

-- =====================================================================
-- /CharGiveItem override
-- =====================================================================
-- We can't directly intercept Helix's command without removing and
-- re-registering it. Helix stores commands in ix.command.list keyed by
-- lowercased name, so we replace ix.command.list["chargiveitem"]
-- entirely with our own version.
--
-- The override:
--   1. Detects ammo items by uniqueID lookup (or fuzzy match against
--      the item list, same as Helix's vanilla command does).
--   2. If it's an ammo item, routes the count through GiveStacked.
--   3. Otherwise, falls through to the original Helix behavior
--      (target:GetInventory():Add(uniqueID, amount)).
--
-- We only register the override on the SERVER realm because that's
-- where commands run. Clients receive command metadata via networking
-- and the override is invisible to them. (Actually Helix runs commands
-- shared, so we register on both — a no-op on client.)
-- =====================================================================

-- Save reference to the original implementation so we can fall back to
-- it for non-ammo items. Stored at file load — works because Helix's
-- core sh_commands.lua loads before plugin command files.
local originalCharGiveItem = ix.command.list and ix.command.list["chargiveitem"]
if not originalCharGiveItem then
    -- Defensive: if for some reason it's not loaded yet, defer one tick.
    -- This shouldn't fire on a normal server start but it's cheap.
    timer.Simple(0, function()
        originalCharGiveItem = ix.command.list and ix.command.list["chargiveitem"]
    end)
end

ix.command.Add("CharGiveItem", {
    description    = "@cmdCharGiveItem",
    superAdminOnly = true,
    arguments      = {
        ix.type.character,
        ix.type.string,
        bit.bor(ix.type.number, ix.type.optional),
    },
    OnRun = function(self, client, target, item, amount)
        local uniqueID = item:lower()

        -- Resolve via fuzzy match if no direct hit, mirroring the
        -- vanilla command's behavior so /CharGiveItem still feels the
        -- same for non-ammo items.
        if not ix.item.list[uniqueID] then
            for k, v in SortedPairs(ix.item.list) do
                if ix.util.StringMatches(v.name, uniqueID) then
                    uniqueID = k
                    break
                end
            end
        end

        amount = amount or 1

        -- Is this one of our ammo items? If so, route through the
        -- stack-aware path. Count means rounds, not stacks.
        local ammoType = GetAmmoTypeForUniqueID(uniqueID)
        if ammoType then
            local targetPlayer = target:GetPlayer()
            if not IsValid(targetPlayer) then
                return "@charNoExist"
            end

            -- Cap to prevent foot-guns. See /GiveAmmo for rationale.
            if amount > 1000 then
                return "Refusing to give more than 1000 rounds in a single command."
            end

            local surplus = ix.ammoSystem.GiveStacked(targetPlayer, ammoType, amount)
            local given = amount - surplus

            if given <= 0 then
                return "@noFit"
            end

            target:GetPlayer():NotifyLocalized("itemCreated")

            if target ~= client:GetCharacter() then
                if surplus > 0 then
                    return string.format(
                        "Gave %d rounds (%d couldn't fit).", given, surplus)
                end
                return "@itemCreated"
            end
            return  -- self-give, no return message needed
        end

        -- Not an ammo item — defer to the original Helix behavior.
        -- We replicate it inline rather than calling originalCharGiveItem
        -- because the original's OnRun expects the same `self` context
        -- and would re-resolve the uniqueID we already resolved.
        local bSuccess, error = target:GetInventory():Add(uniqueID, amount)

        if bSuccess then
            target:GetPlayer():NotifyLocalized("itemCreated")
            if target ~= client:GetCharacter() then
                return "@itemCreated"
            end
        else
            return "@" .. tostring(error)
        end
    end
})
