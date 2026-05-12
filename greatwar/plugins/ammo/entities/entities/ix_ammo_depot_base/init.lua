AddCSLuaFile("shared.lua")
AddCSLuaFile("cl_init.lua")
include("shared.lua")

-- =====================================================================
-- Initialize
-- =====================================================================
function ENT:Initialize()
    self:SetModel("models/props_c17/oildrum001.mdl")  -- placeholder
    self:PhysicsInit(SOLID_VPHYSICS)
    self:SetMoveType(MOVETYPE_VPHYSICS)
    self:SetSolid(SOLID_VPHYSICS)
    self:SetUseType(SIMPLE_USE)

    local phys = self:GetPhysicsObject()
    if IsValid(phys) then
        phys:EnableMotion(false)   -- depots stay where placed
        phys:Wake()
    end

    -- Per-entity event log: ring buffer of recent deposit/withdraw events.
    -- Each entry: { ts, delta, class, actorName, actorSteamID }
    self.Log = {}
    self.LogMax = (ix.ammoSystem and ix.ammoSystem.DEPOT_LOG_MAX) or 30

    -- Initialize all counts to 0 (these reset on server restart per your
    -- design call — no persistence layer for now).
    self:SetPistolCount(0)
    self:SetBoltCount(0)
    self:SetMgCount(0)
end

-- =====================================================================
-- Access gate
-- =====================================================================
-- Same-team only. Cross-team interaction is silently refused — the
-- enemy can E on the entity all they want, nothing happens. The Use
-- handler doesn't notify the enemy because we don't want to leak that
-- the entity is even ammo-related (atmospheric).
local function CanAccess(client, entity)
    if not IsValid(client) or not IsValid(entity) then return false end
    local char = client:GetCharacter()
    if not char then return false end

    local team = ix.team.GetTeam(char:GetFaction())
    if team ~= entity.Team then return false end

    return true
end

function ENT:Use(activator, caller)
    if not IsValid(activator) or not activator:IsPlayer() then return end
    if not CanAccess(activator, self) then return end

    -- Send open signal to client with current state + log snapshot.
    local payload = {
        entIndex = self:EntIndex(),
        team     = self.Team,
        pistol   = { count = self:GetPistolCount(), cap = self:GetCapFor("pistol") },
        bolt     = { count = self:GetBoltCount(),   cap = self:GetCapFor("bolt") },
        mg       = { count = self:GetMgCount(),     cap = self:GetCapFor("mg") },
        log      = self.Log,
    }

    net.Start("ixAmmoDepotOpen")
        net.WriteTable(payload)
    net.Send(activator)
end

-- =====================================================================
-- Log helpers
-- =====================================================================
function ENT:PushLogEntry(class, delta, actor)
    local entry = {
        ts           = CurTime(),
        class        = class,
        delta        = delta,
        actorName    = nil,
        actorSteamID = nil,
    }

    if IsValid(actor) and actor:IsPlayer() then
        local char = actor:GetCharacter()
        entry.actorName    = char and char:GetName() or actor:Nick()
        entry.actorSteamID = actor:SteamID()
    end

    self.Log[#self.Log + 1] = entry

    -- Trim from the front when over cap.
    while #self.Log > self.LogMax do
        table.remove(self.Log, 1)
    end

    -- Broadcast to all same-team players on the map. Non-officers
    -- on the team see depot logs (Foxhole-style transparency, your
    -- earlier call). Cross-team players don't.
    for _, ply in ipairs(player.GetAll()) do
        local char = ply:GetCharacter()
        if not char then continue end
        if ix.team.GetTeam(char:GetFaction()) ~= self.Team then continue end

        net.Start("ixAmmoDepotLogSync")
            net.WriteUInt(self:EntIndex(), 16)
            net.WriteFloat(entry.ts)
            net.WriteString(entry.class)
            net.WriteInt(entry.delta, 16)
            net.WriteString(entry.actorName    or "")
            net.WriteString(entry.actorSteamID or "")
        net.Send(ply)
    end
end

-- =====================================================================
-- Deposit
-- =====================================================================
-- Walks the player's inventory for stacks of the matching ammo type
-- (faction-locked — the entity's Team determines which faction's ammo
-- to look for) and dumps them into the depot up to capacity.
--
-- Class is one of "pistol" | "bolt" | "mg".
-- Returns the actual amount deposited (may be less than the player had,
-- if the depot filled up partway through).
function ENT:Deposit(client, class)
    if not CanAccess(client, self) then return 0 end
    if class ~= "pistol" and class ~= "bolt" and class ~= "mg" then return 0 end

    local char = client:GetCharacter()
    if not char then return 0 end
    local inv = char:GetInventory()
    if not inv then return 0 end

    local ammoType = class .. "_" .. self.Team   -- e.g. "bolt_axis"
    local current = self:GetCountFor(class)
    local cap = self:GetCapFor(class)
    local roomLeft = cap - current
    if roomLeft <= 0 then
        client:Notify("This depot is full of " .. class .. " ammunition.")
        return 0
    end

    -- Walk inventory, take as much as fits.
    local deposited = 0
    -- Snapshot stacks first so we can mutate during iteration.
    local stacks = {}
    for _, invItem in pairs(inv:GetItems()) do
        if invItem.base == "base_gw_ammo" and invItem.ammoType == ammoType then
            stacks[#stacks + 1] = invItem
        end
    end

    for _, stack in ipairs(stacks) do
        if roomLeft <= 0 then break end
        local amt = stack:GetData("amount", 1)
        if amt <= roomLeft then
            -- Whole stack fits.
            deposited = deposited + amt
            roomLeft = roomLeft - amt
            stack:Remove()
        else
            -- Partial: take what fits, leave the rest.
            deposited = deposited + roomLeft
            stack:SetData("amount", amt - roomLeft)
            roomLeft = 0
        end
    end

    if deposited <= 0 then
        client:Notify("You have no matching " .. class .. " ammunition.")
        return 0
    end

    -- Apply.
    self:SetCountFor(class, current + deposited)
    self:PushLogEntry(class, deposited, client)

    -- NOTE: ammo deposits do NOT award readiness. Earlier design had
    -- this coupling but it created a deposit/withdraw exploit (loop
    -- forever for unlimited readiness). Uniforms can stay coupled
    -- because they're consumed one-way (no withdraw path); ammo is
    -- two-way and any reward is exploitable without per-player
    -- net-tracking. Revisit in a future phase if logistics-as-
    -- readiness becomes important.

    return deposited
end

-- =====================================================================
-- Withdraw
-- =====================================================================
-- Pulls one stack's worth (up to WITHDRAW_STACK rounds) from the depot
-- and routes through ix.ammoSystem.GiveStacked so it auto-merges with
-- any existing stacks the player has.
--
-- If depot has fewer than WITHDRAW_STACK, takes whatever's there.
-- Returns the actual amount withdrawn.
function ENT:Withdraw(client, class)
    if not CanAccess(client, self) then return 0 end
    if class ~= "pistol" and class ~= "bolt" and class ~= "mg" then return 0 end

    local current = self:GetCountFor(class)
    if current <= 0 then
        client:Notify("This depot is out of " .. class .. " ammunition.")
        return 0
    end

    local withdrawAmount = ix.ammoSystem.WITHDRAW_STACK or 10
    local toWithdraw = math.min(withdrawAmount, current)

    local ammoType = class .. "_" .. self.Team

    -- GiveStacked tops off existing stacks first, then makes new ones.
    -- Returns the surplus that didn't fit (e.g. inventory full).
    local surplus = ix.ammoSystem.GiveStacked(client, ammoType, toWithdraw)
    local actuallyTaken = toWithdraw - surplus

    if actuallyTaken <= 0 then
        client:Notify("Your inventory is full.")
        return 0
    end

    self:SetCountFor(class, current - actuallyTaken)
    self:PushLogEntry(class, -actuallyTaken, client)

    if surplus > 0 then
        client:Notify(string.format(
            "Took %d rounds (%d couldn't fit).", actuallyTaken, surplus))
    end

    return actuallyTaken
end

-- =====================================================================
-- Net receiver: client → server action
-- =====================================================================
net.Receive("ixAmmoDepotAction", function(len, client)
    if not IsValid(client) then return end

    local entIndex = net.ReadUInt(16)
    local action   = net.ReadString()
    local class    = net.ReadString()

    local ent = ents.GetByIndex(entIndex)
    if not IsValid(ent) then return end
    if not ent.Deposit or not ent.Withdraw then return end   -- not a depot

    if action == "deposit" then
        ent:Deposit(client, class)
    elseif action == "withdraw" then
        ent:Withdraw(client, class)
    end
end)