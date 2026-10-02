PrefabFiles = { "automatic_collector" }

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
    Asset("ATLAS", "images/inventoryimages/automatic_collector.xml"),
    Asset("IMAGE", "images/inventoryimages/automatic_collector.tex"),
    Asset("ATLAS", "images/map_icons/automatic_collector.xml"),
    Asset("IMAGE", "images/map_icons/automatic_collector.tex"),
}
AddMinimapAtlas("images/map_icons/automatic_collector.xml")

local strings = G.STRINGS
strings.NAMES.AUTOMATIC_COLLECTOR = "拾荒机"
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

-- Insight loads at a lower priority. Register once all modmain files have run,
-- on both clients and servers, without requiring any third-party script.
local insight_compat = require("ac_insight")
AddSimPostInit(function() insight_compat.Register(G, modname) end)
