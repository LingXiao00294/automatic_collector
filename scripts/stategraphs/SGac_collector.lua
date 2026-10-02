require("stategraphs/commonstates")

local states = {
    State {
        name = "idle", tags = { "idle", "canrotate" },
        onenter = function(inst)
            inst.components.locomotor:StopMoving()
            inst.AnimState:SetDeltaTimeMultiplier(1)
            inst.AnimState:PlayAnimation("idle", true)
        end,
    },
}

local function WorkState(name, animation, duration, impact, sound)
    return State {
        name = name, tags = { "busy" },
        onenter = function(inst)
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
                    inst.SoundEmitter:PlaySound(sound)
                    worker:PerformAction(action)
                else
                    if action ~= nil then action:Fail() end
                    inst:ClearBufferedAction()
                end
            end
        end,
        ontimeout = function(inst) inst.sg:GoToState("idle") end,
        onexit = function(inst)
            inst.AnimState:SetDeltaTimeMultiplier(1)
            local action = inst.sg.statemem.action
            if inst.components.ac_worker.pending ~= nil and inst.components.ac_worker.pending.action == action then
                inst.components.ac_worker:Finish(action, false)
                inst:ClearBufferedAction()
            end
            inst.components.inventory:CloseAllChestContainers()
        end,
    }
end

table.insert(states, WorkState("pickup", "pickup", 1, .5, "dontstarve/wilson/pickup_reeds"))
table.insert(states, WorkState("pick", "hammer", 1.3, .7, "dontstarve/wilson/pickup_plants"))
table.insert(states, WorkState("hammer", "hammer", 1.3, .7, "dontstarve/wilson/hammer"))
table.insert(states, WorkState("store", "store", 1, .5, "dontstarve/wilson/pickup_reeds"))

CommonStates.AddWalkStates(states, nil, { startwalk = "walk_pre", walk = "walk_loop", stopwalk = "walk_pst" })

return StateGraph("ac_collector", states, {
    CommonHandlers.OnLocomote(false, true),
}, "idle", {
    ActionHandler(ACTIONS.PICKUP, "pickup"),
    ActionHandler(ACTIONS.PICK, "pick"),
    ActionHandler(ACTIONS.HARVEST, "pick"),
    ActionHandler(ACTIONS.AC_HAMMER, "hammer"),
    ActionHandler(ACTIONS.STORE, "store"),
})
