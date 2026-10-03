require("stategraphs/commonstates")
local Upgrades = require("ac_upgrades")
local Sounds = require("ac_sounds")

local states = {
    State {
        name = "upgrade", tags = { "busy" },
        onenter = function(inst)
            Sounds.StopWalk(inst)
            inst.components.locomotor:StopMoving()
            inst.AnimState:SetDeltaTimeMultiplier(1)
            inst.AnimState:PlayAnimation("store")
            Sounds.Play(inst, "upgrade")
            inst.sg:SetTimeout(.4)
        end,
        ontimeout = function(inst) inst.sg:GoToState("idle") end,
    },
    State {
        name = "idle", tags = { "idle", "canrotate" },
        onenter = function(inst)
            Sounds.StopWalk(inst)
            inst.components.locomotor:StopMoving()
            inst.AnimState:SetDeltaTimeMultiplier(1)
            inst.AnimState:PlayAnimation("idle", true)
        end,
    },
}

local function WorkState(name, animation, duration, impact)
    return State {
        name = name, tags = { "busy" },
        onenter = function(inst)
            Sounds.StopWalk(inst)
            inst.components.locomotor:StopMoving()
            local speed = inst.components.ac_worker.action_speed
            inst.AnimState:SetDeltaTimeMultiplier(speed)
            inst.AnimState:PlayAnimation(animation)
            inst.sg.statemem.action = inst:GetBufferedAction()
            local target = inst.sg.statemem.action ~= nil and inst.sg.statemem.action.target or nil
            if target ~= nil and target:IsValid() then
                inst:ForceFacePoint(target:GetPosition())
            end
            inst.sg.statemem.impact = impact / speed
            inst.sg:SetTimeout(duration / speed)
        end,
        onupdate = function(inst)
            if not inst.sg.statemem.hit and inst.sg.timeinstate >= inst.sg.statemem.impact then
                inst.sg.statemem.hit = true
                local worker, action = inst.components.ac_worker, inst.sg.statemem.action
                if worker:ValidateAction(action) then
                    Sounds.Play(inst, name)
                    worker:PerformAction(action)
                else
                    worker:FailAction(action, action ~= nil and action.action == ACTIONS.STORE)
                    inst:ClearBufferedAction()
                end
            end
        end,
        ontimeout = function(inst) inst.sg:GoToState("idle") end,
        onexit = function(inst)
            inst.AnimState:SetDeltaTimeMultiplier(1)
            local action = inst.sg.statemem.action
            if inst.components.ac_worker.pending ~= nil and inst.components.ac_worker.pending.action == action then
                inst.components.ac_worker:FailAction(action)
                inst:ClearBufferedAction()
            end
            inst.components.inventory:CloseAllChestContainers()
        end,
    }
end

table.insert(states, WorkState("pickup", "pickup", 1, .5))
table.insert(states, WorkState("pick", "hammer", 1.3, .7))
table.insert(states, WorkState("hammer", "hammer", 1.3, .7))
-- Native storage_robot stores on frame 6 and closes the chest on state exit.
table.insert(states, WorkState("store", "store", 1, 6 * FRAMES))

local function WalkEnter(inst)
    inst.AnimState:SetDeltaTimeMultiplier(Upgrades.IsAdvanced(inst) and 2 or 1)
    Sounds.StartWalk(inst)
end
local function WalkExit(inst)
    -- Keep the emitter through CommonStates' per-cycle walk re-entry. Every
    -- non-walk state's onenter stops it; lifecycle callbacks also stop it.
    inst.AnimState:SetDeltaTimeMultiplier(1)
end
CommonStates.AddWalkStates(states, nil,
    { startwalk = "walk_pre", walk = "walk_loop", stopwalk = "walk_pst" }, false, false, {
        startonenter = WalkEnter, walkonenter = WalkEnter, endonenter = WalkEnter,
        startonexit = WalkExit, walkonexit = WalkExit, endonexit = WalkExit,
    })

return StateGraph("ac_collector", states, {
    CommonHandlers.OnLocomote(false, true),
}, "idle", {
    ActionHandler(ACTIONS.PICKUP, "pickup"),
    ActionHandler(ACTIONS.PICK, "pick"),
    ActionHandler(ACTIONS.HARVEST, "pick"),
    ActionHandler(ACTIONS.AC_HAMMER, "hammer"),
    ActionHandler(ACTIONS.STORE, "store"),
})
