ITEM.name = "Uniform"
ITEM.description = "A standard-issue uniform. Deposit at a friendly drop point to resupply the forward spawn."
ITEM.model = "models/props_junk/cardboard_box003a_gib01.mdl"
ITEM.width = 1
ITEM.height = 1
ITEM.category = "Supplies"

-- Trace distance for finding a drop point in front of the player.
local DEPOSIT_TRACE_DISTANCE = 100

-- Helper: find a drop point the player is looking at within range.
-- Returns the drop point entity if found, nil otherwise.
local function FindDropPointInFront(client)
    if not IsValid(client) then return nil end

    local trace = client:GetEyeTrace()
    if not trace.Hit then return nil end

    local ent = trace.Entity
    if not IsValid(ent) then return nil end

    local class = ent:GetClass()
    if class ~= "ix_drop_point_axis" and class ~= "ix_drop_point_allies" then
        return nil
    end

    -- Range check.
    local distSqr = client:EyePos():DistToSqr(ent:GetPos())
    if distSqr > DEPOSIT_TRACE_DISTANCE * DEPOSIT_TRACE_DISTANCE then
        return nil
    end

    return ent
end

-- Single deposit: deposit just this one uniform.
ITEM.functions.Deposit = {
    name = "Deposit",
    tip = "Deposit this uniform at the drop point you're looking at.",
    icon = "icon16/box.png",

    OnRun = function(item)
        local client = item.player
        if not IsValid(client) then return false end

        local character = client:GetCharacter()
        if not character then return false end

        local dropPoint = FindDropPointInFront(client)
        if not dropPoint then
            client:Notify("No drop point in range.")
            return false
        end

        -- Team match check.
        local entTeam = dropPoint:GetTeam()
        if not ix.team.IsOnTeam(character, entTeam) then
            client:Notify("This is not your team's drop point.")
            return false
        end

        -- Try to deposit.
        local added = ix.dropPoint.AddUniforms(entTeam, 1)
        if added <= 0 then
            client:Notify("The drop point is at maximum capacity.")
            return false
        end

        client:Notify("Uniform deposited.")

        -- Phase 2 readiness: +1 per uniform deposited. Notify-eligible
        -- reason ("uniform_deposit") triggers the generic "supplies
        -- received" notify on the actor; entry shows up in the officer
        -- HQ log attributed to this player.
        if ix.readiness and ix.readiness.Add then
            ix.readiness.Add(entTeam, added, "uniform_deposit", false, client)
        end

        -- Returning true (default) deletes the item from inventory.
        return true
    end,

    OnCanRun = function(item)
        return IsValid(item.player) and not IsValid(item.entity)
    end
}

-- Bulk deposit: walk the inventory and deposit every uniform we have.
-- Helpful when carrying multiple at once.
ITEM.functions.DepositAll = {
    name = "Deposit All Uniforms",
    tip = "Deposit every uniform in your inventory at the drop point.",
    icon = "icon16/box.png",

    OnRun = function(item)
        local client = item.player
        if not IsValid(client) then return false end

        local character = client:GetCharacter()
        if not character then return false end

        local dropPoint = FindDropPointInFront(client)
        if not dropPoint then
            client:Notify("No drop point in range.")
            return false
        end

        local entTeam = dropPoint:GetTeam()
        if not ix.team.IsOnTeam(character, entTeam) then
            client:Notify("This is not your team's drop point.")
            return false
        end

        -- Collect all uniform items in the inventory.
        local inventory = character:GetInventory()
        if not inventory then return false end

        local uniforms = {}
        for _, invItem in pairs(inventory:GetItems()) do
            if invItem.uniqueID == "uniform" then
                table.insert(uniforms, invItem)
            end
        end

        if #uniforms == 0 then
            client:Notify("You have no uniforms.")
            return false
        end

        -- Deposit one at a time, respecting stockpile capacity.
        local depositedCount = 0
        for _, uniformItem in ipairs(uniforms) do
            local added = ix.dropPoint.AddUniforms(entTeam, 1)
            if added <= 0 then
                break -- stockpile full
            end

            uniformItem:Remove()
            depositedCount = depositedCount + 1
        end

        if depositedCount == 0 then
            client:Notify("The drop point is at maximum capacity.")
            return false
        elseif depositedCount < #uniforms then
            client:Notify("Deposited " .. depositedCount .. " uniforms. Drop point is now full.")
        else
            client:Notify("Deposited " .. depositedCount .. " uniforms.")
        end

        -- Phase 2 readiness: one batched entry for the whole bulk deposit
        -- (so officer log shows "+5 uniform_deposit_bulk" instead of five
        -- identical "+1" lines). The generic notify still fires once.
        if ix.readiness and ix.readiness.Add and depositedCount > 0 then
            ix.readiness.Add(entTeam, depositedCount, "uniform_deposit_bulk", false, client)
        end

        -- We removed the items manually above; tell Helix not to remove
        -- the calling item again (it's already gone).
        return false
    end,

    OnCanRun = function(item)
        return IsValid(item.player) and not IsValid(item.entity)
    end
}