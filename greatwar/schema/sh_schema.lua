
-- The shared init file. You'll want to fill out the info for your schema and include any other files that you need.

-- Schema info
Schema.name = "Great War Test"
Schema.author = "Jim"
Schema.description = "A base schema for development."

-- Additional files that aren't auto-included should be included here. Note that ix.util.Include will take care of properly
-- using AddCSLuaFile, given that your files have the proper naming scheme.

-- You could technically put most of your schema code into a couple of files, but that makes your code a lot harder to manage -
-- especially once your project grows in size. The standard convention is to have your miscellaneous functions that don't belong
-- in a library reside in your cl/sh/sv_schema.lua files. Your gamemode hooks should reside in cl/sh/sv_hooks.lua. Logical
-- groupings of functions should be put into their own libraries in the libs/ folder. Everything in the libs/ folder is loaded
-- automatically.
ix.util.Include("cl_schema.lua")
ix.util.Include("sv_schema.lua")

ix.util.Include("cl_hooks.lua")
ix.util.Include("sh_hooks.lua")
ix.util.Include("sv_hooks.lua")

-- You'll need to manually include files in the meta/ folder, however.
ix.util.Include("meta/sh_character.lua")
ix.util.Include("meta/sh_player.lua")

ix.anim.SetModelClass("models/wassimadamoxdu02/imperialcommunity/britishv2/1soldatbritish.mdl", "player")
ix.anim.SetModelClass("models/wassimadamoxdu02/imperialcommunity/britishv2/2soldatbritish.mdl", "player")
ix.anim.SetModelClass("models/wassimadamoxdu02/imperialcommunity/britishv2/3soldatbritish.mdl", "player")
ix.anim.SetModelClass("models/wassimadamoxdu02/imperialcommunity/britishv2/4soldatbritish.mdl", "player")
ix.anim.SetModelClass("models/wassimadamoxdu02/imperialcommunity/britishv2/5soldatbritish.mdl", "player")
ix.anim.SetModelClass("models/wassimadamoxdu02/imperialcommunity/britishv2/6soldatbritish.mdl", "player")

ix.anim.SetModelClass("models/adamwassim/imperialcommunity/1soldatallemandv2.mdl", "player")
ix.anim.SetModelClass("models/adamwassim/imperialcommunity/2soldatallemandv2.mdl", "player")
ix.anim.SetModelClass("models/adamwassim/imperialcommunity/3soldatallemandv2.mdl", "player")
ix.anim.SetModelClass("models/adamwassim/imperialcommunity/4soldatallemandv2.mdl", "player")
ix.anim.SetModelClass("models/adamwassim/imperialcommunity/5soldatallemandv2.mdl", "player")
ix.anim.SetModelClass("models/adamwassim/imperialcommunity/6soldatallemandv2.mdl", "player")


