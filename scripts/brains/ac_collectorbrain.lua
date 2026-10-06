require("behaviours/doaction")
require("behaviours/standstill")

local CollectorBrain = Class(Brain, function(self, inst)
    Brain._ctor(self, inst)
end)

local function Available(inst)
    return inst.components.ac_worker:IsWorking() and not inst.sg:HasStateTag("busy")
end

function CollectorBrain:OnStart()
    self.bt = BT(self.inst, PriorityNode({
        WhileNode(function()
            return Available(self.inst)
        end, "Collector available", DoAction(self.inst, function(inst)
            return inst.components.ac_worker:GetNextAction(false)
        end, "One collector job", false)),
        WhileNode(function()
            return Available(self.inst)
        end, "Collector returning", DoAction(self.inst, function(inst)
            return inst.components.ac_worker:GetHomeAction()
        end, "Return home", false)),
        StandStill(self.inst),
    }, .1, true))
end

function CollectorBrain:OnStop()
    self.inst.components.ac_worker:Cancel()
end

return CollectorBrain
