local PLUGIN = PLUGIN

PLUGIN.events = PLUGIN.events or {}

-- ============================================================
-- Net receivers
-- ============================================================

net.Receive("ixAssaultSyncState", function()
    local payload = net.ReadTable()
    ix.assault.fallen = { axis = {}, allies = {} }
    for team, sectors in pairs(payload or {}) do
        ix.assault.fallen[team] = {}
        for _, sector in ipairs(sectors) do
            ix.assault.fallen[team][sector] = true
        end
    end
end)

net.Receive("ixAssaultSectorFallen", function()
    local team   = net.ReadString()
    local sector = net.ReadString()
    ix.assault.MarkSectorFallen(team, sector)
end)

net.Receive("ixAssaultSectorReset", function()
    local team   = net.ReadString()
    local sector = net.ReadString()
    ix.assault.ResetSector(team, sector)
end)

net.Receive("ixAssaultStateChanged", function()
    ix.assault.active       = net.ReadBool()
    local sector            = net.ReadString()
    ix.assault.activeSector = (sector ~= "" and sector) or nil
    ix.assault.deadline     = net.ReadFloat()
    local att = net.ReadString()
    local def = net.ReadString()
    if (att ~= "") then ix.assault.ATTACKER_TEAM = att end
    if (def ~= "") then ix.assault.DEFENDER_TEAM = def end
end)

-- ============================================================
-- Per-side messaging
-- ============================================================

local function GetMyTeam()
    local client = LocalPlayer()
    if (not IsValid(client) or not client:GetCharacter()) then return nil end
    if (not ix.team or not ix.team.GetTeam) then return nil end
    return ix.team.GetTeam(client:GetCharacter():GetFaction())
end

local function PushBanner(headline, subtitle, color, duration)
    PLUGIN.events[#PLUGIN.events + 1] = {
        until_t   = CurTime() + (duration or 3.5),
        headline  = headline,
        subtitle  = subtitle or "",
        color     = color or Color(60, 80, 120),
    }
end

local COLOR_GOOD = Color(40, 110, 50)   -- attacker secure / defender hold
local COLOR_BAD  = Color(140, 30, 30)   -- defender lost / attacker fail
local COLOR_INFO = Color(60, 80, 120)

net.Receive("ixAssaultEvent", function()
    local kind   = net.ReadString()
    local sector = net.ReadString()
    local slot   = net.ReadString()
    local extra  = net.ReadString()

    local me = GetMyTeam()

    if (kind == "started") then
        PushBanner("ASSAULT BEGINS",
            string.format("Objective sector %s is now active.", sector),
            COLOR_INFO, 4)

    elseif (kind == "slot_captured") then
        local losingTeam = extra
        local imAttacker = (me and me ~= losingTeam)
        if (imAttacker) then
            PushBanner("OBJECTIVE SECURED",
                string.format("%s%s captured.", sector, slot),
                COLOR_GOOD, 3)
        else
            PushBanner("OBJECTIVE LOST",
                string.format("%s%s has fallen.", sector, slot),
                COLOR_BAD, 3)
        end

    elseif (kind == "sector_fallen") then
        local losingTeam = extra
        local imAttacker = (me and me ~= losingTeam)
        if (imAttacker) then
            PushBanner("SECTOR SECURED",
                string.format("Sector %s is yours.", sector),
                COLOR_GOOD, 5)
        else
            PushBanner("SECTOR LOST",
                string.format("Sector %s has fallen.", sector),
                COLOR_BAD, 5)
        end

    elseif (kind == "win") then
        local winner = extra
        local imWinner = (me == winner)
        PushBanner(imWinner and "VICTORY" or "DEFEAT",
            imWinner and "The assault has succeeded." or "The line has been broken.",
            imWinner and COLOR_GOOD or COLOR_BAD, 8)

    elseif (kind == "fail") then
        local imAttacker = (me ~= nil and me ~= ix.assault.DEFENDER_TEAM)
        if (imAttacker) then
            PushBanner("ASSAULT FAILED",
                "Time has run out.", COLOR_BAD, 6)
        else
            PushBanner("LINE HELD",
                "The defenders have repelled the assault.", COLOR_GOOD, 6)
        end
    end
end)

-- ============================================================
-- HUD: top-center banner stack + assault timer
-- ============================================================

local function FormatTime(t)
    t = math.max(0, math.floor(t))
    return string.format("%d:%02d", math.floor(t / 60), t % 60)
end

hook.Add("HUDPaint", "ixAssaultHUD", function()
    local sw, sh = ScrW(), ScrH()
    local now = CurTime()

    -- Timer (only while active)
    if (ix.assault.active and ix.assault.activeSector) then
        local timeLeft = math.max(0, ix.assault.deadline - now)
        local label = string.format("ASSAULT %s   %s",
            ix.assault.activeSector, FormatTime(timeLeft))

        local boxW, boxH = 220, 40
        local x, y = (sw - boxW) * 0.5, 24

        -- Pulsing background if under 15s
        local bgAlpha = 200
        if (timeLeft < 15) then
            bgAlpha = 200 + math.sin(now * 6) * 40
        end

        local bgColor = (timeLeft < 15) and Color(140, 30, 30) or Color(20, 20, 20)
        surface.SetDrawColor(bgColor.r, bgColor.g, bgColor.b, bgAlpha)
        surface.DrawRect(x, y, boxW, boxH)
        surface.SetDrawColor(255, 255, 255, 100)
        surface.DrawOutlinedRect(x, y, boxW, boxH)

        draw.SimpleText(label, "DermaDefaultBold", x + boxW * 0.5, y + boxH * 0.5,
            Color(255, 255, 255, 240), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
    end

    -- Banner stack
    local liveCount = 0
    for i = #PLUGIN.events, 1, -1 do
        if (PLUGIN.events[i].until_t < now) then
            table.remove(PLUGIN.events, i)
        else
            liveCount = liveCount + 1
        end
    end

    local bannerY = sh * 0.18
    for i, ev in ipairs(PLUGIN.events) do
        local timeLeft = ev.until_t - now
        local alpha = math.Clamp(timeLeft, 0, 1)
        if (timeLeft > 1) then alpha = 1 end

        local barH = 70
        surface.SetDrawColor(ev.color.r, ev.color.g, ev.color.b, math.floor(190 * alpha))
        surface.DrawRect(0, bannerY, sw, barH)
        surface.SetDrawColor(255, 255, 255, math.floor(60 * alpha))
        surface.DrawRect(0, bannerY, sw, 2)
        surface.DrawRect(0, bannerY + barH - 2, sw, 2)

        draw.SimpleText(ev.headline, "DermaLarge", sw * 0.5, bannerY + barH * 0.32,
            Color(255, 255, 255, math.floor(255 * alpha)),
            TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
        draw.SimpleText(ev.subtitle, "DermaDefaultBold", sw * 0.5, bannerY + barH * 0.68,
            Color(230, 230, 230, math.floor(220 * alpha)),
            TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)

        bannerY = bannerY + barH + 6
    end
end)