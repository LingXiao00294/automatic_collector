local assets = {
    Asset("ANIM", "anim/ac_upgrade_kit.zip"),
    Asset("ATLAS", "images/inventoryimages/ac_upgrade_kit.xml"),
    Asset("IMAGE", "images/inventoryimages/ac_upgrade_kit.tex"),
}

local function fn()
    local inst = CreateEntity()
    inst.entity:AddTransform()
    inst.entity:AddAnimState()
    inst.entity:AddSoundEmitter()
    inst.entity:AddNetwork()
    MakeInventoryPhysics(inst)
    inst.AnimState:SetBank("ac_upgrade_kit")
    inst.AnimState:SetBuild("ac_upgrade_kit")
    inst.AnimState:PlayAnimation("idle")
    inst.pickupsound = "metal"
    inst:AddTag("ac_upgrade_kit")
    inst.entity:SetPristine()
    if not TheWorld.ismastersim then return inst end

    inst:AddComponent("inspectable")
    inst:AddComponent("inventoryitem")
    inst.components.inventoryitem.atlasname = "images/inventoryimages/ac_upgrade_kit.xml"
    inst.components.inventoryitem:ChangeImageName("ac_upgrade_kit")
    inst:AddComponent("stackable")
    inst.components.stackable.maxsize = 20
    inst:AddComponent("ac_upgradeitem")
    MakeHauntableLaunch(inst)
    return inst
end

return Prefab("ac_upgrade_kit", fn, assets)
