local M = {}
local Upgrades = require("ac_upgrades")
local JOBS = { pickup = "拾取", pick = "采摘", harvest = "收获", hammer = "敲巨大作物", store = "运输" }

function M.Describe(worker)
    local inst = worker.inst
    local status = inst.components.inventoryitem:IsHeld() and "已收起"
        or (not worker.enabled and "已暂停")
        or (worker.blocked and "无接收箱子")
        or (inst:IsAsleep() and "休眠")
        or (worker.pending ~= nil and (JOBS[worker.pending.kind] or "采集")) or "待机"
    local cargo = worker:GetCargo()
    local cargo_text = "空载"
    if cargo ~= nil then
        local name = STRINGS.NAMES[string.upper(cargo.prefab)] or cargo.prefab
        local stack = cargo.components.stackable
        cargo_text = string.format("%s × %d", name, stack ~= nil and stack:StackSize() or 1)
    end
    local advanced = Upgrades.IsAdvanced(inst)
    local collection = advanced and string.format("\n采集：%s\n农作物批次：%s",
        worker:IsHarvestEnabled() and "开启" or "关闭，仅拾取与运输",
        worker.farm_draining and "拾取与运输" or string.format("采摘 %d/5", worker.farm_count))
        or "\n功能：拾取与运输"
    return {
        name = "ac_worker",
        priority = 10,
        description = string.format("%s：%s%s\n工作半径：%g（约 %g 块地皮）\n货物：%s\n运输槽：%d\n运输规则：%s",
            advanced and "采集车" or "拾荒机", status, collection,
            worker.radius, worker.radius / 4, cargo_text, worker:GetCarrySlots(),
            worker.config.matching_only and "仅已有同类样品的箱子" or "优先同类，也用空箱"),
    }
end

function M.Unselect(inst)
    if inst._ac_range_task ~= nil then
        inst._ac_range_task:Cancel()
        inst._ac_range_task = nil
    end
    if inst._ac_range_indicator ~= nil then
        inst._ac_range_indicator:Remove()
        inst._ac_range_indicator = nil
    end
    if inst._ac_range_anchor ~= nil then
        inst._ac_range_anchor:Remove()
        inst._ac_range_anchor = nil
        inst:RemoveEventCallback("onremove", M.Unselect)
    end
end

function M.UpdateRange(inst)
    local indicator = inst._ac_range_indicator
    if indicator == nil then return end
    local visible = inst._ac_home_valid:value() and not inst:HasTag("INLIMBO")
    indicator:SetVisible(visible)
    if not visible then return end
    local x, z = inst._ac_home_x:value(), inst._ac_home_z:value()
    local platform = inst._ac_home_platform:value()
    if platform ~= nil and platform:IsValid() then
        local world_x, _, world_z = platform.entity:LocalToWorldSpace(x, 0, z)
        x, z = world_x, world_z
    end
    inst._ac_range_anchor.Transform:SetPosition(x, 0, z)
    indicator:SetRadius(inst._ac_radius:value() / 4)
end

function M.Select(inst)
    M.Unselect(inst)
    if TheNet:IsDedicated() or inst._ac_home_valid == nil
        or not inst._ac_home_valid:value() or inst:HasTag("INLIMBO") then return end
    local indicator = SpawnPrefab("insight_range_indicator")
    if indicator == nil then return end
    -- Independent local anchor keeps the ring at home while the collector walks.
    local anchor = CreateEntity()
    anchor.entity:AddTransform()
    anchor.entity:SetCanSleep(false)
    anchor.persists = false
    anchor:AddTag("FX")
    anchor:AddTag("NOCLICK")
    inst._ac_range_anchor, inst._ac_range_indicator = anchor, indicator
    indicator:Attach(anchor)
    indicator:SetColour(.3, .8, 1, 1)
    inst:ListenForEvent("onremove", M.Unselect)
    M.UpdateRange(inst)
    inst._ac_range_task = inst:DoPeriodicTask(.1, M.UpdateRange)
end

function M.Register(g, modname)
    local insight = g.rawget(g, "Insight")
    local api = insight ~= nil and insight.API ~= nil and insight.API.V1 or nil
    if api == nil or api.AddComponentDescriptor == nil or api.AddPrefabDescriptor == nil then
        return false
    end
    api.AddComponentDescriptor("ac_worker", { Describe = M.Describe }, { modname = modname })
    api.AddPrefabDescriptor("automatic_collector", {
        OnSelect = M.Select, OnUnselect = M.Unselect,
    }, { modname = modname })
    return true
end

return M
