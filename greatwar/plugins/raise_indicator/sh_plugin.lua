local PLUGIN = PLUGIN
PLUGIN.name = "Weapon Raise HUD"
PLUGIN.author = "ChatGPT"
PLUGIN.description = "Displays a HUD element when raising a weapon."

if CLIENT then
    local raiseStartTime = 0
    local isRaising = false
    local iconMat = Material("vgui/gicons/colt-m1911.png")
    local showHUD = false
    local delayReached = false

    function PLUGIN:Think()
        if input.IsKeyDown(KEY_R) then
            if not isRaising then
                raiseStartTime = CurTime()
                isRaising = true
                showHUD = true
                delayReached = false
            end

            if isRaising and (CurTime() - raiseStartTime) >= 0.25 then
                delayReached = true
            end
        else
            isRaising = false
            showHUD = false
            delayReached = false
        end
    end

    function PLUGIN:HUDPaint()
        if showHUD and delayReached then
            local elapsedTime = CurTime() - (raiseStartTime + 0.25)

            if elapsedTime >= 0 and elapsedTime <= 0.75 then
                surface.SetMaterial(iconMat)
                surface.SetDrawColor(255, 255, 255, 255)
                surface.DrawTexturedRect(ScrW() / 2 - 16, ScrH() / 2 + 100, 32, 32)

                local barWidth = 220
                local barHeight = 15
                local barX = ScrW() / 2 - barWidth / 2
                local barY = ScrH() / 2 + 140
                local progress = math.Clamp(elapsedTime / 0.75, 0, 1)

                draw.RoundedBox(8, barX, barY, barWidth, barHeight, Color(50, 50, 50, 200))
                draw.RoundedBox(8, barX, barY, barWidth * progress, barHeight, Color(100, 200, 100, 255))
            else
                showHUD = false
            end
        end
    end
end