ITEM.name        = "Ammo Base"
ITEM.description = "Base class for all faction-locked ammunition stacks."
ITEM.model       = "models/items/boxsrounds.mdl"
ITEM.width       = 1
ITEM.height      = 1
ITEM.category    = "Ammunition"

-- We inherit from base_stackable for the conceptual "stackable" tag, but
-- in practice the stackable plugin's PaintOver and combine function are
-- not reliably inherited across the realm boundary on this server. We
-- redefine them on our own base below to guarantee they exist.
ITEM.base = "base_stackable"
ITEM.max  = 10                     -- mirrors ix.ammoSystem.STACK_MAX

-- These three fields MUST be overridden on each concrete ammo item.
-- Default to nil so a misconfigured item fails loudly rather than
-- silently routing rounds to the wrong type.
ITEM.ammoType    = nil             -- e.g. "bolt_axis" — must be a key of ix.ammoSystem.TYPES
ITEM.faction     = nil             -- "axis" | "allies"
ITEM.weaponClass = nil             -- "pistol" | "bolt" | "mg"

-- Drop into corpse inventory on death, per design doc §7.
ITEM.bDropOnDeath = true

-- Tooltip name shows the count: ".303 British Rounds (10)"
function ITEM:GetName()
    local amount = self:GetData("amount", 1)
    return self.name .. " (" .. amount .. ")"
end

-- Tooltip description shows the count and ammo type cleanly.
function ITEM:GetDescription()
    local rounds = self:GetData("amount", 1)
    local typeInfo = ix.ammoSystem and ix.ammoSystem.TYPES[self.ammoType]
    local typeName = typeInfo and typeInfo.displayName or self.ammoType or "?"
    return string.format("%d rounds of %s.", rounds, typeName)
end

-- ----- NO Load FUNCTION -----
-- Per design: there is NO "Load" right-click action. Inventory IS the
-- reserve. The R-to-reload bridge in sv_plugin syncs the engine ammo
-- pool to inventory totals automatically.

-- Helper used by sv_plugin and any cleanup code: drop the stack by 1,
-- removing the item if that hits zero. Returns true if removed.
function ITEM:ReduceAmount()
    local amount = self:GetData("amount", 1)
    if amount > 0 then
        if (amount - 1) <= 0 then
            return true
        end
        self:SetData("amount", amount - 1)
    end
    return false
end

-- =====================================================================
-- Drag-to-merge (combine function)
-- =====================================================================
-- Helix's vanilla inventory: when the player drops an item icon onto
-- another item icon, if the target item has a `combine` function, Helix
-- calls it with `data = { droppedItemID }`. We absorb the dropped
-- stack's amount into ours, up to ITEM.max, and discard or trim the
-- dropped stack accordingly.
--
-- We only combine identical ammo types (matched by uniqueID). Trying
-- to drop a bolt_axis stack onto a pistol_allies stack does nothing.
ITEM.functions.combine = {
    OnRun = function(item, data)
        local other = ix.item.instances[data[1]]
        if not other then return false end
        if other.uniqueID ~= item.uniqueID then return false end

        local current = item:GetData("amount", 1)
        local incoming = other:GetData("amount", 1)
        local combined = current + incoming
        local capacity = item.max or 10

        if combined <= capacity then
            -- Everything fits.
            item:SetData("amount", combined)
            other:Remove()
        else
            -- Top off and leave the leftover on the dropped stack.
            item:SetData("amount", capacity)
            other:SetData("amount", combined - capacity)
        end

        return false   -- don't delete the calling item
    end,
    OnCanRun = function() return true end,
}

-- =====================================================================
-- Count overlay (PaintOver)
-- =====================================================================
-- Drawn over the inventory icon. The stackable plugin draws the count
-- in tiny DermaDefault — we use a bigger bold font with a dark
-- background pill so it's readable against any item icon.
if CLIENT then
    -- Register the font once.
    if not _AMMO_COUNT_FONT_CREATED then
        surface.CreateFont("ixAmmoStackCount", {
            font    = "Roboto Bold",
            size    = 18,
            weight  = 900,
            antialias = true,
        })
        _AMMO_COUNT_FONT_CREATED = true
    end

    function ITEM:PaintOver(item, w, h)
        local amount = item:GetData("amount", 1)
        local text = tostring(amount)

        surface.SetFont("ixAmmoStackCount")
        local tw, th = surface.GetTextSize(text)

        -- Padding around the text.
        local px, py = 4, 1
        local boxW, boxH = tw + px * 2, th + py * 2
        local boxX = w - boxW - 2
        local boxY = h - boxH - 2

        -- Dark background pill so the number is always readable.
        surface.SetDrawColor(0, 0, 0, 200)
        surface.DrawRect(boxX, boxY, boxW, boxH)
        surface.SetDrawColor(255, 255, 255, 60)
        surface.DrawOutlinedRect(boxX, boxY, boxW, boxH)

        -- The count itself.
        surface.SetTextColor(255, 255, 255, 255)
        surface.SetTextPos(boxX + px, boxY + py)
        surface.DrawText(text)
    end
end

-- =====================================================================
-- Split function
-- =====================================================================
-- Right-click → Split → numeric prompt → creates a new stack with the
-- requested amount, decrements the source. Server validates and ensures
-- inventory has space.
ITEM.functions.Split = {
    name = "Split Stack",
    icon = "icon16/arrow_divide.png",

    OnClick = function(item)
        local current = item:GetData("amount", 1)
        if current <= 1 then
            LocalPlayer():Notify("Stack too small to split.")
            return false
        end

        local maxSplit = current - 1
        Derma_StringRequest(
            "Split Stack",
            string.format("How many rounds to move into a new stack? (1 - %d)", maxSplit),
            tostring(math.floor(current / 2)),
            function(text)
                local n = tonumber(text)
                if not n then
                    LocalPlayer():Notify("Invalid amount.")
                    return
                end
                n = math.floor(n)
                if n < 1 or n > maxSplit then
                    LocalPlayer():Notify(string.format(
                        "Amount must be between 1 and %d.", maxSplit))
                    return
                end

                -- Send via a dedicated net message because Helix's
                -- standard InventoryAction doesn't carry a numeric
                -- payload.
                net.Start("ixAmmoSplit")
                    net.WriteUInt(item.id, 32)
                    net.WriteUInt(n, 7)
                net.SendToServer()
            end,
            function() end,
            "Split", "Cancel")

        -- Don't run the OnRun pipeline — we've handled it client-side.
        return false
    end,

    OnRun = function(item)
        -- Required field for registration. Never reached because
        -- OnClick returns false.
        return false
    end,

    OnCanRun = function(item)
        return item:GetData("amount", 1) > 1
    end,
}

-- =====================================================================
-- Server-side: pool sync hooks
-- =====================================================================
-- Server-side: when an ammo stack appears in or vanishes from a
-- player's inventory, re-sync the engine ammo pool. Helix fires
-- OnInstanced/OnRemoved/OnTransferred at the right moments.
if SERVER then
    -- Capture the ammo plugin reference at load time. The PLUGIN global
    -- is only valid during the plugin's load; later (in the deferred
    -- callbacks below) it's nil or points at a different plugin. Reach
    -- the captured reference instead.
    local ammoPlugin = PLUGIN

    -- Helper: ask the plugin to recompute the player's pool for our type.
    local function ResyncOwner(item)
        local owner = item:GetOwner()
        if not IsValid(owner) or not owner:IsPlayer() then return end
        if ammoPlugin and ammoPlugin.SyncAmmoPool then
            ammoPlugin:SyncAmmoPool(owner, item.ammoType)
        end
    end

    function ITEM:OnInstanced(invID, x, y)
        -- Item just got placed into an inventory. Schedule a resync —
        -- defer one tick so the inventory state is fully settled.
        timer.Simple(0, function()
            if not self or not self.ammoType then return end
            ResyncOwner(self)
        end)
    end

    function ITEM:OnTransferred(oldInv, newInv)
        -- Moved between inventories. Resync both old and new owners.
        timer.Simple(0, function()
            if not self or not self.ammoType then return end
            ResyncOwner(self)
            if oldInv and ix.item.inventories[oldInv] then
                local oldInvObj = ix.item.inventories[oldInv]
                local oldOwner = oldInvObj.GetOwner and oldInvObj:GetOwner()
                if IsValid(oldOwner) and oldOwner:IsPlayer()
                   and ammoPlugin and ammoPlugin.SyncAmmoPool then
                    ammoPlugin:SyncAmmoPool(oldOwner, self.ammoType)
                end
            end
        end)
    end

    function ITEM:OnRemoved()
        local invID = self.invID
        local ammoType = self.ammoType
        timer.Simple(0, function()
            if invID and ix.item.inventories[invID] then
                local invObj = ix.item.inventories[invID]
                local owner = invObj.GetOwner and invObj:GetOwner()
                if IsValid(owner) and owner:IsPlayer()
                   and ammoPlugin and ammoPlugin.SyncAmmoPool then
                    ammoPlugin:SyncAmmoPool(owner, ammoType)
                end
            end
        end)
    end
end