local H = upgrade_contract
local Sounds = require("ac_sounds")

local function record(inst, advanced)
    local log = { plays = {}, loops = {}, kills = 0 }
    inst._ac_mk2 = { value = function() return advanced end }
    inst.SoundEmitter = {
        PlaySound = function(_, event, channel)
            table.insert(log.plays, event)
            if channel ~= nil then log.loops[channel] = event end
        end,
        KillSound = function(_, channel) log.loops[channel] = nil log.kills = log.kills + 1 end,
    }
    return log
end

function scenarios.sound_walk_continuous_and_cancelled()
    for _, advanced in ipairs({ false, true }) do
        local w = H.worker()
        H.enter(w, nil, "walk_start")
        local log = record(w.inst, advanced)
        Sounds.StopWalk(w.inst)
        w.inst.sg:GoToState("walk_start")
        w.inst.sg:GoToState("walk")
        w.inst.sg:GoToState("walk")
        w.inst.sg:GoToState("walk_stop")
        assert(#log.plays == 1 and log.loops.ac_walk ~= nil, "Walk cycles must not restart the loop")
        assert(log.plays[1] == "ac_collector/" .. (advanced and "metal" or "wood") .. "/walk_loop")
        w:SetEnabled(false)
        assert(log.loops.ac_walk == nil and not w.inst._ac_walk_sound)
        w.inst.sg:GoToState("walk")
        w.inst.sg:GoToState("pick")
        assert(log.loops.ac_walk == nil and not w.inst._ac_walk_sound)
    end
end

function scenarios.sound_work_contact_and_profiles()
    for _, advanced in ipairs({ false, true }) do
        local w = H.setup()
        local target = H.item("twigs", 1)
        local state = H.enter(w, w:GetNextAction(), "pickup")
        local log = record(w.inst, advanced)
        w.inst.sg.timeinstate = .49 state.onupdate(w.inst)
        assert(#log.plays == 0)
        w.inst.sg.timeinstate = .5 state.onupdate(w.inst) state.onupdate(w.inst)
        assert(#log.plays == 1 and w.inst.mutations == 1)
        assert(log.plays[1] == "ac_collector/" .. (advanced and "metal" or "wood") .. "/pickup")
        target.valid = false
        state.onexit(w.inst)
        local invalid = H.item("flint", 1)
        w.nextscan = 0
        state = H.enter(w, w:GetNextAction(), "pickup")
        log = record(w.inst, advanced)
        invalid.valid = false
        w.inst.sg.timeinstate = .5 state.onupdate(w.inst)
        assert(#log.plays == 0, "Invalid work must not emit a contact cue")
    end
end

function scenarios.sound_signals_skip_held_and_sleeping()
    local w = H.worker()
    local log = record(w.inst, true)
    Sounds.OnEnabledChanged(w.inst, { enabled = true })
    Sounds.OnEnabledChanged(w.inst, { enabled = false })
    assert(table.concat(log.plays, ",") == "ac_collector/metal/start,ac_collector/metal/stop")
    w.inst.held = true Sounds.OnEnabledChanged(w.inst, { enabled = false })
    w.inst.held = false w.inst.asleep = true
    Sounds.OnEnabledChanged(w.inst, { enabled = true })
    assert(#log.plays == 2)
end
