ITEM.name = "Telephone Connector"
ITEM.description = "A connector used to link two field telephones together."
ITEM.model = "models/ger/equipment/ger_wire_spool_01/ger_wire_spool_01.mdl"
ITEM.width = 1
ITEM.height = 1
ITEM.iconCam = {
    pos = Vector(0.06, 733.91, 0.74),
    ang = Angle(-0.74, 269.91, 0),
    fov = 2.67
}


local TRACE_DISTANCE = 128 -- how far away you can be to connect a phone

local function GetLookedAtPhone(client)
    local trace = client:GetEyeTrace()
    local ent = trace.Entity

    if IsValid(ent) and ent:GetClass() == "ix_telephone" then
        -- check distance
        if client:GetPos():Distance(ent:GetPos()) <= TRACE_DISTANCE then
            return ent
        else
            return nil, "You are too far away from the telephone."
        end
    end

    return nil, "You must be looking at a telephone."
end

-- Step 1: Begin Connection
ITEM.functions.BeginConnection = {
    name = "Begin Connection",
    icon = "icon16/connect.png",
    OnRun = function(item)
        local client = item.player
        local phone, err = GetLookedAtPhone(client)

        if !IsValid(phone) then
            client:ChatPrint(err or "You must be looking at a telephone.")
            return false
        end

        if phone:GetInUse() or phone:GetRinging() then
            client:ChatPrint("That telephone is already in use.")
            return false
        end

        -- Store the entity index so we can find it again
        item:SetData("phoneA", phone:EntIndex())
        client:ChatPrint("Connection started. Now look at the second telephone and select 'Complete Connection'.")
        return false -- keep the item
    end,
    OnCanRun = function(item)
        -- Only show this option if we haven't started a connection yet
        return !IsValid(item.entity) and IsValid(item.player) and !item:GetData("phoneA")
    end
}

-- Step 2: Complete Connection
ITEM.functions.CompleteConnection = {
    name = "Complete Connection",
    icon = "icon16/tick.png",
    OnRun = function(item)
        local client = item.player
        local phoneB, err = GetLookedAtPhone(client)

        if !IsValid(phoneB) then
            client:ChatPrint(err or "You must be looking at a telephone.")
            return false
        end

        local phoneAIndex = item:GetData("phoneA")
        local phoneA = ents.GetByIndex(phoneAIndex)

        if !IsValid(phoneA) then
            client:ChatPrint("The first telephone is no longer valid. Starting over.")
            item:SetData("phoneA", nil)
            return false
        end

        if phoneA == phoneB then
            client:ChatPrint("You cannot connect a telephone to itself.")
            return false
        end

        if phoneB:GetInUse() or phoneB:GetRinging() then
            client:ChatPrint("That telephone is already in use.")
            return false
        end

        if IsValid(phoneA.ixLinkedPhone) then
            client:ChatPrint("The first telephone is already connected to another telephone.")
            item:SetData("phoneA", nil)
            return false
        end

        if IsValid(phoneB.ixLinkedPhone) then
            client:ChatPrint("That telephone is already connected to another telephone.")
            return false
        end

        -- Link the phones
        phoneA.ixLinkedPhone = phoneB
        phoneB.ixLinkedPhone = phoneA

        client:ChatPrint("Telephones connected successfully!")

        -- Return true to consume/remove the item
        return true
    end,
    OnCanRun = function(item)
        -- Only show this option if we have already selected a first phone
        return !IsValid(item.entity) and IsValid(item.player) and item:GetData("phoneA") != nil
    end
}

-- Allow cancelling mid-connection
ITEM.functions.CancelConnection = {
    name = "Cancel Connection",
    icon = "icon16/cross.png",
    OnRun = function(item)
        item:SetData("phoneA", nil)
        item.player:ChatPrint("Connection cancelled.")
        return false
    end,
    OnCanRun = function(item)
        return !IsValid(item.entity) and IsValid(item.player) and item:GetData("phoneA") != nil
    end
}