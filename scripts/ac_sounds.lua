local Upgrades = require("ac_upgrades")
local Sounds = {}
local WALK_CHANNEL = "ac_walk"

function Sounds.Play(inst, cue)
    local profile = Upgrades.IsAdvanced(inst) and "metal" or "wood"
    inst.SoundEmitter:PlaySound("ac_collector/" .. profile .. "/" .. cue)
end

function Sounds.StartWalk(inst)
    if inst._ac_walk_sound then return end
    local profile = Upgrades.IsAdvanced(inst) and "metal" or "wood"
    inst.SoundEmitter:PlaySound("ac_collector/" .. profile .. "/walk_loop", WALK_CHANNEL)
    inst._ac_walk_sound = true
end

function Sounds.StopWalk(inst)
    inst.SoundEmitter:KillSound(WALK_CHANNEL)
    inst._ac_walk_sound = nil
end

function Sounds.OnEnabledChanged(inst, data)
    if inst.components.inventoryitem:IsHeld() or inst:IsAsleep() then return end
    Sounds.Play(inst, data.enabled and "start" or "stop")
end

return Sounds
