local API = require("ac_api")
local Upgrades = {
    CHASSIS = "ac_chassis_mk2",
    BASE_PREFAB = "automatic_collector",
    ADVANCED_PREFAB = "automatic_collector_mk2",
}

function Upgrades.IsAdvanced(inst)
    return inst._ac_mk2 ~= nil and inst._ac_mk2:value()
end

-- Runs on both hosts and clients; it never reads server-only components.
function Upgrades.RefreshVisual(inst)
    local advanced = Upgrades.IsAdvanced(inst)
    local name = advanced and Upgrades.ADVANCED_PREFAB or Upgrades.BASE_PREFAB
    -- Keep the Lua identity, engine spawn identity and save records in sync.
    if inst.prefab ~= name then inst:SetPrefabName(name) end
    -- Preserve native character masks, mass and capsule height on every peer.
    inst.Physics:SetCapsule(.25, 1)
    inst.AnimState:SetBank(name)
    inst.AnimState:SetBuild(name)
    inst.MiniMapEntity:SetIcon(name .. ".tex")
end

function Upgrades.DisplayName(inst)
    local name = Upgrades.IsAdvanced(inst) and Upgrades.ADVANCED_PREFAB or Upgrades.BASE_PREFAB
    return STRINGS.NAMES[string.upper(name)]
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
    local name = advanced and Upgrades.ADVANCED_PREFAB or Upgrades.BASE_PREFAB
    inst.components.inventoryitem.atlasname = "images/inventoryimages/" .. name .. ".xml"
    inst.components.inventoryitem:ChangeImageName(name)
end

function Upgrades.Register()
    API.RegisterUpgrade(Upgrades.CHASSIS, { maxlevel = 1, apply = Upgrades.Apply })
end

return Upgrades
