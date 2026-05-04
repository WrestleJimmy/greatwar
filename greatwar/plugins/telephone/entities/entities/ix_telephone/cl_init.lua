include("shared.lua")

function ENT:Draw()
    self:DrawModel()
end

function ENT:GetOverlayText()
    if self:GetRinging() then
        return "Trench Phone - Ringing!"
    elseif self:GetInUse() then
        return "Trench Phone - In use"
    else
        return "Trench Phone"
    end
end

-- Build the Helix entity interaction menu
function ENT:GetEntityMenu(client)
    local options = {}
    local onPhone = (client.ixOnPhone == self)

    if self:GetRinging() then
        options["Answer Phone"] = function()
            return true
        end
    elseif onPhone then
        options["Hang Up"] = function()
            return true
        end
    elseif not self:GetInUse() then
        options["Talk on Phone"] = function()
            return true
        end
    end

    options["Pack Up Trench Phone"] = function()
        return true
    end

    return options
end

-- Sound definitions
local STATIC_SOUND  = "ambient/wind/wind1.wav"       -- CHAN_STATIC
local GUST_SOUND    = "ambient/wind/windgust.wav"    -- CHAN_VOICE
local MED_SOUND     = "ambient/wind/wind_med1.wav"   -- CHAN_WEAPON
local SIGNAL_SOUND  = "hl1/ambience/deadsignal2.wav" -- CHAN_ITEM
local FLOUR_SOUND   = "ambient/misc/flour_light.wav" -- CHAN_USER_BASE
local RAIN_SOUND    = "ambience/weather/rain.wav"    -- CHAN_USER_BASE + 2

local RANDOM_SOUNDS = {
    "ambient/wind/wind_hit1.wav",
    "ambient/wind/wind_hit2.wav",
    "ambient/wind/wind_hit3.wav",
    "ambient/wind/wind_snippet3.wav",
    "ambient/wind/wind_snippet4.wav",
    "ambient/wind/wind_snippet5.wav",
    "ambient/wind/windgust_strong.wav",
}

local bgActive = false

local gustDuration   = SoundDuration(GUST_SOUND)
local medDuration    = SoundDuration(MED_SOUND)
local signalDuration = SoundDuration(SIGNAL_SOUND)
local flourDuration  = SoundDuration(FLOUR_SOUND)
local rainDuration   = SoundDuration(RAIN_SOUND)

local function LoopGust()
    if !bgActive then return end
    LocalPlayer():EmitSound(GUST_SOUND, 75, 255, 0.25, CHAN_VOICE)
    timer.Simple(math.max(gustDuration - 0.1, 0.5), LoopGust)
end

local function LoopMed()
    if !bgActive then return end
    LocalPlayer():EmitSound(MED_SOUND, 75, 255, 0.25, CHAN_WEAPON)
    timer.Simple(math.max(medDuration - 0.1, 0.5), LoopMed)
end

local function LoopSignal()
    if !bgActive then return end
    LocalPlayer():EmitSound(SIGNAL_SOUND, 75, 100, 0.12, CHAN_ITEM)
    timer.Simple(math.max(signalDuration - 0.1, 0.5), LoopSignal)
end

local function LoopFlour()
    if !bgActive then return end
    LocalPlayer():EmitSound(FLOUR_SOUND, 75, 100, 0.1, CHAN_USER_BASE)
    timer.Simple(math.max(flourDuration - 0.1, 0.5), LoopFlour)
end

local function LoopRain()
    if !bgActive then return end
    LocalPlayer():EmitSound(RAIN_SOUND, 75, 255, 0.5, CHAN_STREAM)
    timer.Simple(math.max(rainDuration - 0.1, 0.5), LoopRain)
end

local function PlayRandomHit()
    if !bgActive then return end
    local snd = RANDOM_SOUNDS[math.random(1, #RANDOM_SOUNDS)]
    LocalPlayer():EmitSound(snd, 75, 255, 0.3, CHAN_STATIC)
    timer.Simple(math.Rand(1, 4), PlayRandomHit)
end

local function StartBG()
    if bgActive then return end
    bgActive = true
    LocalPlayer():EmitSound(STATIC_SOUND, 75, 255, 0.25, CHAN_STATIC)
    LoopGust()
    LoopMed()
    LoopSignal()
    LoopFlour()
    LoopRain()
    timer.Simple(math.Rand(1, 4), PlayRandomHit)
end

local ALL_SOUNDS = {
    STATIC_SOUND,
    GUST_SOUND,
    MED_SOUND,
    SIGNAL_SOUND,
    FLOUR_SOUND,
    RAIN_SOUND,
    -- rain is on CHAN_STREAM
}

local function StopBG()
    if !bgActive then return end
    bgActive = false
    local ply = LocalPlayer()
    for _, snd in ipairs(ALL_SOUNDS) do
        ply:StopSound(snd)
    end
    for _, snd in ipairs(RANDOM_SOUNDS) do
        ply:StopSound(snd)
    end
end

net.Receive("ixPhoneStatic", function()
    if net.ReadBool() then
        StartBG()
    else
        StopBG()
    end
end)

concommand.Add("phone_test_static", function()
    if bgActive then
        StopBG()
        print("[Telephone] Static stopped")
    else
        StartBG()
        print("[Telephone] Static started")
    end
end)

hook.Add("ShutDown", "ixTelephoneStaticCleanup", function()
    StopBG()
end)