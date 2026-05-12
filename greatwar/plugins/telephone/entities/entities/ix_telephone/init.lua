AddCSLuaFile("cl_init.lua")
AddCSLuaFile("shared.lua")
include("shared.lua")

util.AddNetworkString("ixPhoneStatic")
util.AddNetworkString("ixPhoneVoice")

local HANGUP_DISTANCE = 150

function ENT:Initialize()
    self:SetModel("models/props_supplies/german/field-radio01.mdl")
    self:PhysicsInit(SOLID_VPHYSICS)
    self:SetMoveType(MOVETYPE_VPHYSICS)
    self:SetSolid(SOLID_VPHYSICS)
    self:SetUseType(SIMPLE_USE)

    local phys = self:GetPhysicsObject()
    if IsValid(phys) then phys:Wake() end
end

local function SendStatic(client, enabled)
    net.Start("ixPhoneStatic")
        net.WriteBool(enabled)
    net.Send(client)
end

local function SendVoice(client, speaking)
    net.Start("ixPhoneVoice")
        net.WriteBool(speaking)
    net.Send(client)
end

local function GetCallPartner(client)
    local phone = client.ixOnPhone
    if !IsValid(phone) then return nil end
    local linked = phone.ixLinkedPhone
    if !IsValid(linked) then return nil end
    if IsValid(linked.ixUser) and linked.ixUser != client then return linked.ixUser end
    if IsValid(linked.ixCaller) and linked.ixCaller != client then return linked.ixCaller end
end

hook.Add("PlayerStartVoice", "ixTelephoneVoice", function(speaker)
    local partner = GetCallPartner(speaker)
    if IsValid(partner) then SendVoice(partner, true) end
end)

hook.Add("PlayerEndVoice", "ixTelephoneVoice", function(speaker)
    local partner = GetCallPartner(speaker)
    if IsValid(partner) then SendVoice(partner, false) end
end)

timer.Create("ixPhoneDistanceCheck", 0.5, 0, function()
    for _, client in player.Iterator() do
        local phone = client.ixOnPhone
        if !IsValid(phone) then continue end
        if client:GetPos():Distance(phone:GetPos()) > HANGUP_DISTANCE then
            client:ChatPrint("You walked too far from the telephone.")
            phone:HangUp()
        end
    end
end)

hook.Add("PlayerDeath", "ixTelephoneDisconnect", function(client)
    local phone = client.ixOnPhone
    if IsValid(phone) then phone:HangUp() end
end)

hook.Add("PlayerDisconnected", "ixTelephoneDisconnect", function(client)
    local phone = client.ixOnPhone
    if IsValid(phone) then phone:HangUp() end
end)

-- Called when player selects "Talk on Phone"
function ENT:OnSelectTalkonPhone(client)
    if !client:GetCharacter() then return end

    local linked = self.ixLinkedPhone

    if client.ixOnPhone == self then
        self:HangUp()
        return
    end

    if !IsValid(linked) then
        client:ChatPrint("This telephone is not connected to anything.")
        return
    end

    -- Pick up a ringing phone
    if self:GetRinging() and IsValid(linked.ixCaller) then
        local caller = linked.ixCaller
        client.ixOnPhone = self
        caller.ixOnPhone = linked
        self.ixUser = client
        self:SetRinging(false)
        self:SetInUse(true)
        linked:SetInUse(true)
        client:EmitSound("hl1/fvox/blip.wav")
        client:ChatPrint("Call connected.")
        caller:ChatPrint("Call connected.")
        SendStatic(client, true)
        SendStatic(caller, true)
        return
    end

    -- Start a call
    if !linked:GetInUse() and !linked:GetRinging() then
        self.ixCaller = client
        client.ixOnPhone = self
        self:SetInUse(true)
        linked:SetRinging(true)
        linked:EmitSound("ambient/alarms/city_firebell_loop1.wav", 80, 100, 1, CHAN_AUTO)
        client:ChatPrint("Calling... (waiting for pickup)")
    else
        client:ChatPrint("The line is busy.")
    end
end

-- "Answer Phone" option (shown when ringing)
function ENT:OnSelectAnswerPhone(client)
    self:OnSelectTalkonPhone(client)
end

-- "Hang Up" option (shown when on a call)
function ENT:OnSelectHangUp(client)
    self:HangUp()
end

-- "Pack Up Trench Phone" option
function ENT:OnSelectPackUpTrenchPhone(client)
    if !client:GetCharacter() then return end

    -- Only the NW owner or an admin can pack it up
    local ownerID = self:GetNWInt("owner", -1)
    local charID = client:GetCharacter():GetID()

    if ownerID != -1 and ownerID != charID and !client:IsAdmin() then
        client:ChatPrint("You did not deploy this telephone.")
        return
    end

    -- Make sure not in an active call
    if self:GetInUse() then
        self:HangUp()
    end

    local character = client:GetCharacter()
    local inventory = character:GetInventory()
    local itemUniqueID = "telephone" -- must match your item's uniqueID / filename

    if inventory:FindEmptySlot(1, 1) then
        inventory:Add(itemUniqueID)
        client:ChatPrint("You pack up the trench phone.")
    else
        client:ChatPrint("You don't have enough inventory space.")
        return
    end

    self:Remove()
end

function ENT:HangUp()
    local linked = self.ixLinkedPhone

    if IsValid(self.ixUser) and self.ixUser.ixOnPhone == self then
        self.ixUser:ChatPrint("Call ended.")
        SendStatic(self.ixUser, false)
        self.ixUser.ixOnPhone = nil
        self.ixUser = nil
    end

    if IsValid(self.ixCaller) and self.ixCaller.ixOnPhone == self then
        self.ixCaller:ChatPrint("Call ended.")
        SendStatic(self.ixCaller, false)
        self.ixCaller.ixOnPhone = nil
        self.ixCaller = nil
    end

    self:SetRinging(false)
    self:SetInUse(false)
    self:StopSound("ambient/alarms/city_firebell_loop1.wav")

    if IsValid(linked) then
        if IsValid(linked.ixUser) then
            linked.ixUser:ChatPrint("Call ended.")
            SendStatic(linked.ixUser, false)
            linked.ixUser.ixOnPhone = nil
            linked.ixUser = nil
        end
        if IsValid(linked.ixCaller) then
            linked.ixCaller:ChatPrint("Call ended.")
            SendStatic(linked.ixCaller, false)
            linked.ixCaller.ixOnPhone = nil
            linked.ixCaller = nil
        end
        linked:SetRinging(false)
        linked:SetInUse(false)
        linked:StopSound("ambient/alarms/city_firebell_loop1.wav")
    end
end

function ENT:OnRemove()
    self:HangUp()
end

function ENT:UpdateTransmitState()
    return TRANSMIT_ALWAYS
end