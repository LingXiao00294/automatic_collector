local brain = require("brains/ac_collectorbrain")
local assets = {
    Asset("ANIM", "anim/automatic_collector.zip"),
    Asset("ATLAS", "images/inventoryimages/automatic_collector.xml"),
    Asset("IMAGE", "images/inventoryimages/automatic_collector.tex"),
}

local function OnPickup(inst, owner)
    inst.components.ac_worker:OnPickup(owner)
end

local function OnDropped(inst)
    inst.components.ac_worker:OnDropped()
end

local function GetStatus(inst)
    if inst.components.inventoryitem:IsHeld() then return "HELD" end
    if not inst.components.ac_worker.enabled then return "PAUSED" end
    if inst.components.ac_worker.blocked then return "BLOCKED" end
end

local function OnRemove(inst)
    inst.components.inventory:DropEverything()
end

local function fn()
    local inst = CreateEntity()
    inst.entity:AddTransform()
    inst.entity:AddAnimState()
    inst.entity:AddSoundEmitter()
    inst.entity:AddDynamicShadow()
    inst.entity:AddMiniMapEntity()
    inst.entity:AddNetwork()
    inst.entity:AddLight()
    inst.Light:SetRadius(0)
    inst.Light:Enable(false)

    MakeCharacterPhysics(inst, 20, .35)
    inst.Transform:SetFourFaced()
    inst.AnimState:SetBank("automatic_collector")
    inst.AnimState:SetBuild("automatic_collector")
    inst.AnimState:PlayAnimation("idle", true)
    inst.AnimState:SetScale(1.15, 1.15)
    inst.DynamicShadow:SetSize(2.4, 1.3)
    inst.MiniMapEntity:SetIcon("automatic_collector.tex")

    inst:AddTag("automatic_collector")
    inst:AddTag("companion")
    inst:AddTag("mech")
    inst:AddTag("NOBLOCK")
    inst._ac_enabled = net_bool(inst.GUID, "ac.enabled")
    inst._ac_blocked = net_bool(inst.GUID, "ac.blocked")
    inst._ac_home_valid = net_bool(inst.GUID, "ac.home_valid")
    inst._ac_home_x = net_float(inst.GUID, "ac.home_x")
    inst._ac_home_z = net_float(inst.GUID, "ac.home_z")
    inst._ac_home_platform = net_entity(inst.GUID, "ac.home_platform")
    inst._ac_radius = net_float(inst.GUID, "ac.radius")
    inst._ac_radius:set(TUNING.AUTOMATIC_COLLECTOR.radius)
    inst._ac_enabled:set(true)
    inst.entity:SetPristine()
    if not TheWorld.ismastersim then return inst end

    inst:AddComponent("inspectable")
    inst.components.inspectable.getstatus = GetStatus
    inst:AddComponent("inventoryitem")
    inst.components.inventoryitem.atlasname = "images/inventoryimages/automatic_collector.xml"
    inst.components.inventoryitem.imagename = "automatic_collector"
    inst.components.inventoryitem.nobounce = true
    inst.components.inventoryitem:SetOnPickupFn(OnPickup)
    inst.components.inventoryitem:SetOnDroppedFn(OnDropped)
    inst:AddComponent("inventory")
    inst.components.inventory.maxslots = 1
    inst.components.inventory.acceptsstacks = true
    inst.components.inventory.noheavylifting = true
    inst:AddComponent("locomotor")
    inst.components.locomotor.walkspeed = TUNING.AUTOMATIC_COLLECTOR.walkspeed
    inst.components.locomotor:SetTriggersCreep(false)
    inst.components.locomotor.pathcaps = { ignorecreep = true, allowocean = false }
    inst:AddComponent("ac_worker")
    inst:AddComponent("ac_upgradable")
    inst:SetStateGraph("SGac_collector")
    inst:SetBrain(brain)
    inst.OnPreLoad = function(inst, data)
        inst.components.ac_worker:OnPreLoad(data ~= nil and data.ac_worker or nil)
    end
    inst:ListenForEvent("onremove", OnRemove)
    inst:ListenForEvent("teleported", function() inst.components.ac_worker:OnDropped() end)
    inst.OnEntitySleep = function() inst.components.ac_worker:Cancel() end
    inst:DoTaskInTime(0, function()
        if inst.components.ac_worker.home == nil and not inst.components.inventoryitem:IsHeld() then
            inst.components.ac_worker:SetHome()
        end
    end)
    return inst
end

return Prefab("automatic_collector", fn, assets)
