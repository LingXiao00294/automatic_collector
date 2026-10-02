require("behaviours/doaction")
require("behaviours/standstill")

local CollectorBrain = Class(Brain, function(self, inst)
    Brain._ctor(self, inst)
end)

function CollectorBrain:OnStart()
    self.bt = BT(self.inst, PriorityNode({
        WhileNode(function()
            return self.inst.components.ac_worker:IsWorking() and not self.inst.sg:HasStateTag("busy")
        end, "Collector available", DoAction(self.inst, function(inst)
            return inst.components.ac_worker:GetNextAction()
        end, "One collector job", false)),
        StandStill(self.inst),
    }, .25))
end

function CollectorBrain:OnStop()
    self.inst.components.ac_worker:Cancel()
end

return CollectorBrain
