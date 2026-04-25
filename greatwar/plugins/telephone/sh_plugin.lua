PLUGIN.name = "Telephone"
PLUGIN.author = "You"
PLUGIN.description = "Two-way telephone communication between entities."

-- Route voice between two connected players
function PLUGIN:PlayerCanHearPlayersVoice(listener, speaker)
    local speakerPhone = speaker.ixOnPhone
    local listenerPhone = listener.ixOnPhone

    if (IsValid(speakerPhone) and IsValid(listenerPhone)) then
        if (speakerPhone.ixLinkedPhone == listenerPhone) then
            return true, false -- false = non-positional, full volume like a real phone
        end
    end
end

ix.command.Add("LinkPhones", {
    description = "Links two telephones together. Look at one and run twice.",
    superAdminOnly = true,
    OnRun = function(self, client)
        local trace = client:GetEyeTrace()
        local ent = trace.Entity

        if (!IsValid(ent) or ent:GetClass() != "ix_telephone") then
            return "You must look at a telephone entity."
        end

        if (!client.ixPhoneLinkTarget) then
            client.ixPhoneLinkTarget = ent
            return "Phone A selected. Now look at Phone B and run the command again."
        else
            local phoneA = client.ixPhoneLinkTarget
            local phoneB = ent

            if (phoneA == phoneB) then
                client.ixPhoneLinkTarget = nil
                return "Cannot link a phone to itself."
            end

            phoneA.ixLinkedPhone = phoneB
            phoneB.ixLinkedPhone = phoneA
            client.ixPhoneLinkTarget = nil

            return "Phones linked successfully!"
        end
    end
})