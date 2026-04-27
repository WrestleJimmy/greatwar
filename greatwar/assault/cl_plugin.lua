local PLUGIN = PLUGIN

-- ============================================================
-- State sync from server
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

    PLUGIN.flashUntil  = CurTime() + 2.5
    PLUGIN.flashTeam   = team
    PLUGIN.flashSector = sector
end)

net.Receive("ixAssaultSectorReset", function()
    local team   = net.ReadString()
    local sector = net.ReadString()
    ix.assault.ResetSector(team, sector)
end)

-- ============================================================
-- Sector-fallen screen flash
-- ============================================================

local FLASH_DURATION  = 2.5
local FLASH_FADE_IN   = 0.25
local FLASH_FADE_HOLD = 1.5

local TEAM_COLOR = {
    axis   = Color(180, 60, 60),
    allies = Color(60, 100, 180),
}

hook.Add("HUDPaint", "ixAssaultFlash", function()
    if (not PLUGIN.flashUntil or CurTime() > PLUGIN.flashUntil) then return end

    local elapsed = FLASH_DURATION - (PLUGIN.flashUntil - CurTime())
    local alpha
    if (elapsed < FLASH_FADE_IN) then
        alpha = elapsed / FLASH_FADE_IN
    elseif (elapsed < FLASH_FADE_IN + FLASH_FADE_HOLD) then
        alpha = 1
    else
        local fadeOutDur = FLASH_DURATION - FLASH_FADE_IN - FLASH_FADE_HOLD
        alpha = math.max(0, 1 - (elapsed - FLASH_FADE_IN - FLASH_FADE_HOLD) / fadeOutDur)
    end
    alpha = math.Clamp(alpha, 0, 1)

    -- Tone alpha based on whether this affects the local player's side
    local client = LocalPlayer()
    local myTeam = nil
    if (IsValid(client) and client:GetCharacter() and ix.team and ix.team.GetTeam) then
        myTeam = ix.team.GetTeam(client:GetCharacter():GetFaction())
    end

    local lostByMe = (myTeam == PLUGIN.flashTeam)
    local headline = lostByMe and "SECTOR LOST" or "SECTOR CAPTURED"
    local subtitle = string.format("Objective %s -- %s", PLUGIN.flashSector or "?", PLUGIN.flashTeam or "?")
    local bgColor  = lostByMe and Color(120, 30, 30) or Color(30, 80, 120)

    local sw, sh = ScrW(), ScrH()
    local barH = 80
    local y    = sh * 0.18

    surface.SetDrawColor(bgColor.r, bgColor.g, bgColor.b, math.floor(180 * alpha))
    surface.DrawRect(0, y, sw, barH)

    surface.SetDrawColor(255, 255, 255, math.floor(60 * alpha))
    surface.DrawRect(0, y, sw, 2)
    surface.DrawRect(0, y + barH - 2, sw, 2)

    draw.SimpleText(headline, "DermaLarge", sw * 0.5, y + barH * 0.32,
        Color(255, 255, 255, math.floor(255 * alpha)),
        TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)

    draw.SimpleText(subtitle, "DermaDefaultBold", sw * 0.5, y + barH * 0.68,
        Color(230, 230, 230, math.floor(220 * alpha)),
        TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
end)
