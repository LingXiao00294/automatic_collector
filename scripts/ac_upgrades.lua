local API = require("ac_api")
local Upgrades = { CHASSIS = "ac_chassis_mk2" }

function Upgrades.IsAdvanced(inst)
    return inst._ac_mk2 ~= nil and inst._ac_mk2:value()
end

-- Runs on both hosts and clients; it never reads server-only components.
function Upgrades.RefreshVisual(inst)
    local name = Upgrades.IsAdvanced(inst) and "automatic_collector_mk2" or "automatic_collector"
    inst.AnimState:SetBank(name)
    inst.AnimState:SetBuild(name)
    inst.MiniMapEntity:SetIcon(name .. ".tex")
end

function Upgrades.DisplayName(inst)
    return Upgrades.IsAdvanced(inst) and STRINGS.NAMES.AUTOMATIC_COLLECTOR_MK2 or nil
end

function Upgrades.Apply(inst, level)
    local advanced = level > 0
    local worker = inst.components.ac_worker
    worker:SetMoveSpeed(advanced and 2 or 1)
    worker:SetActionSpeed(1)
    worker.radius = advanced and 20 or worker.config.radius
    worker._containercache = nil
    worker:SyncHome()
    inst._ac_mk2:set(advanced)
    Upgrades.RefreshVisual(inst)
    local name = advanced and "automatic_collector_mk2" or "automatic_collector"
    inst.components.inventoryitem.atlasname = "images/inventoryimages/" .. name .. ".xml"
    inst.components.inventoryitem:ChangeImageName(name)
end

function Upgrades.Register()
    API.RegisterUpgrade(Upgrades.CHASSIS, { maxlevel = 1, apply = Upgrades.Apply })
end

return Upgrades
