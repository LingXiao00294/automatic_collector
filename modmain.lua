PrefabFiles = { "automatic_collector", "ac_upgrade_kit" }

local G = GLOBAL
G.TUNING.AUTOMATIC_COLLECTOR = {
    radius = GetModConfigData("work_radius") or 12,
    matching_only = GetModConfigData("matching_only") == true,
    pick_plants = GetModConfigData("pick_plants") ~= false,
    hammer_giants = GetModConfigData("hammer_giants") ~= false,
    walkspeed = 3,
    action_timeout = 20,
    retry_delay = 10,
}

Assets = {
    Asset("SOUND", "sound/ac_collector.fsb"),
    Asset("SOUNDPACKAGE", "sound/ac_collector.fev"),
    Asset("ATLAS", "images/inventoryimages/automatic_collector.xml"),
    Asset("IMAGE", "images/inventoryimages/automatic_collector.tex"),
    Asset("ATLAS", "images/map_icons/automatic_collector.xml"),
    Asset("IMAGE", "images/map_icons/automatic_collector.tex"),
    Asset("ATLAS", "images/inventoryimages/automatic_collector_mk2.xml"),
    Asset("IMAGE", "images/inventoryimages/automatic_collector_mk2.tex"),
    Asset("ATLAS", "images/map_icons/automatic_collector_mk2.xml"),
    Asset("IMAGE", "images/map_icons/automatic_collector_mk2.tex"),
    Asset("ATLAS", "images/inventoryimages/ac_upgrade_kit.xml"),
    Asset("IMAGE", "images/inventoryimages/ac_upgrade_kit.tex"),
}
AddMinimapAtlas("images/map_icons/automatic_collector.xml")
AddMinimapAtlas("images/map_icons/automatic_collector_mk2.xml")
RegisterInventoryItemAtlas("images/inventoryimages/ac_upgrade_kit.xml", "ac_upgrade_kit.tex")
RegisterInventoryItemAtlas("images/inventoryimages/automatic_collector_mk2.xml", "automatic_collector_mk2.tex")

local strings = G.STRINGS
strings.NAMES.AUTOMATIC_COLLECTOR = "拾荒机"
strings.NAMES.AUTOMATIC_COLLECTOR_MK2 = "采集车"
strings.NAMES.AC_UPGRADE_KIT = "拾荒机升级套件"
strings.RECIPE_DESC.AC_UPGRADE_KIT = "铥矿加固，步履更快。"
strings.CHARACTERS.GENERIC.DESCRIBE.AC_UPGRADE_KIT = "给拾荒机装上这块机芯。"
strings.CHARACTERS.GENERIC.ACTIONFAIL.AC_UPGRADE = {
    ALREADY_UPGRADED = "这辆车已经升级了。",
    INVALID_TARGET = "拿好套件，靠近地上的拾荒机。",
    BUSY = "有人正在安装套件。",
    INSTALL_FAILED = "套件没有装好，再试一次吧。",
}
strings.RECIPE_DESC.AUTOMATIC_COLLECTOR = "逐个收集，凑组运送。"
strings.CHARACTERS.GENERIC.DESCRIBE.AUTOMATIC_COLLECTOR = {
    GENERIC = "它有自己的工作节奏。",
    PAUSED = "让它歇一会儿吧。",
    BLOCKED = "它需要一个能接收货物的箱子。",
    HELD = "放在地上，就能开始工作。",
}

AddRecipe2("automatic_collector", {
    G.Ingredient("boards", 2), G.Ingredient("cutstone", 2), G.Ingredient("gears", 1),
}, G.TECH.SCIENCE_TWO, {
    atlas = "images/inventoryimages/automatic_collector.xml",
    image = "automatic_collector.tex",
}, { "SCIENCE", "STRUCTURES" })

AddRecipe2("ac_upgrade_kit", {
    G.Ingredient("thulecite", 10), G.Ingredient("wagpunk_bits", 3), G.Ingredient("moonrocknugget", 5),
}, G.TECH.SCIENCE_TWO, {
    atlas = "images/inventoryimages/ac_upgrade_kit.xml",
    image = "ac_upgrade_kit.tex",
}, { "SCIENCE", "STRUCTURES" })

local upgrade = AddAction("AC_UPGRADE", "升级拾荒机", function(act)
    local installer = act.invobject ~= nil and act.invobject.components.ac_upgradeitem or nil
    if installer == nil then return false, "INVALID_TARGET" end
    return installer:Install(act.doer, act.target)
end)
upgrade.priority = 3
upgrade.rmb = true
upgrade.mount_valid = true
upgrade.distance = 2
AddComponentAction("USEITEM", "ac_upgradeitem", function(inst, doer, target, actions, right)
    -- Keep the action on upgraded cars so failure explains why and never toggles work.
    if right and target ~= nil and target:HasTag("automatic_collector")
        and not target:HasTag("INLIMBO") then
        table.insert(actions, upgrade)
    end
end)
AddStategraphActionHandler("wilson", G.ActionHandler(upgrade, "doshortaction"))
AddStategraphActionHandler("wilson_client", G.ActionHandler(upgrade, "doshortaction"))

local toggle = AddAction("AC_TOGGLE", "暂停/启动", function(act)
    local worker = act.target ~= nil and act.target.components.ac_worker or nil
    if worker == nil or act.target.components.inventoryitem:IsHeld() then
        return false
    end
    worker:SetEnabled(not worker.enabled)
    return true
end)
toggle.priority = 2
toggle.rmb = true
toggle.mount_valid = true
toggle.strfn = function(act)
    return act.target ~= nil and act.target._ac_enabled:value() and "STOP" or "START"
end
strings.ACTIONS.AC_TOGGLE = { STOP = "暂停采集", START = "启动采集" }
AddComponentAction("SCENE", "inspectable", function(inst, doer, actions, right)
    local inventory = doer ~= nil and doer.replica.inventory or nil
    local active = inventory ~= nil and inventory:GetActiveItem() or nil
    if active ~= nil and active:HasTag("ac_upgrade_kit") then return end
    if right and inst:HasTag("automatic_collector") and not inst:HasTag("INLIMBO") then
        table.insert(actions, toggle)
    end
end)
AddStategraphActionHandler("wilson", G.ActionHandler(toggle, "doshortaction"))
AddStategraphActionHandler("wilson_client", G.ActionHandler(toggle, "doshortaction"))

-- Internal action: no player handler/tool; one ram applies one native work unit.
local hammer = AddAction("AC_HAMMER", "撞开巨大作物", function(act)
    local worker = act.doer ~= nil and act.doer.components.ac_worker or nil
    if worker == nil or not worker:ValidateAction(act) then
        return false
    end
    act.target.components.workable:WorkedBy(act.doer, 1)
    return true
end)
hammer.distance = 1.5

-- Public registry: other mods can register adapters without changing base components.
-- Built-in handlers use the same component methods exposed to integrations.
G.AUTOMATIC_COLLECTOR_API = require("ac_api")
require("ac_upgrades").Register()

-- Insight loads at a lower priority. Register once all modmain files have run,
-- on both clients and servers, without requiring any third-party script.
local insight_compat = require("ac_insight")
AddSimPostInit(function() insight_compat.Register(G, modname) end)
