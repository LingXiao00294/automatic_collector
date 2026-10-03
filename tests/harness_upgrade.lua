local H = upgrade_contract
local Upgrades = require("ac_upgrades")
local UpgradeItem = require("components/ac_upgradeitem")
local Upgradable = require("components/ac_upgradable")
local API = require("ac_api")
TheWorld = { ismastersim = true }
STRINGS = { NAMES = { AUTOMATIC_COLLECTOR_MK2 = "采集车" } }
Upgrades.Register()

local function visuals(inst)
    local level = false
    inst._ac_mk2 = { value = function() return level end, set = function(_, v) level = v end }
    inst.AnimState = {
        SetBank = function(_, v) inst.bank = v end,
        SetBuild = function(_, v) inst.build = v end,
        SetDeltaTimeMultiplier = function(_, v) inst.multiplier = v end,
        PlayAnimation = function(_, v) inst.animation = v end,
    }
    inst.MiniMapEntity = { SetIcon = function(_, v) inst.mapicon = v end }
    inst.SoundEmitter = { PlaySound = function() inst.sounds = (inst.sounds or 0) + 1 end }
    inst.SoundEmitter.KillSound = function() end
end

local function prepare(count, worker)
    local w = worker or H.setup()
    visuals(w.inst)
    w.inst.components.inventoryitem.ChangeImageName = function(self, v) self.imagename = v end
    w.inst.components.ac_upgradable = Upgradable(w.inst)
    w.inst.components.locomotor.walkspeed = 3
    local player = H.entity("wilson", 0, { "player" })
    player.components.inventory = H.inventory(player)
    local kit = H.item("ac_upgrade_kit", 0, { "ac_upgrade_kit" }, count or 1)
    kit.skinname = "test_skin"
    player.components.inventory:GiveItem(kit)
    kit.components.ac_upgradeitem = UpgradeItem(kit)
    return w, player, kit, kit.components.ac_upgradeitem
end

function scenarios.upgrade_single_and_stack()
    for _, count in ipairs({ 1, 3 }) do
        local w, player, kit, installer = prepare(count)
        local guid = w.inst
        assert(installer:Install(player, w.inst))
        assert(w.inst == guid and Upgrades.IsAdvanced(w.inst))
        assert(w.inst.components.locomotor.walkspeed == 6 and w.action_speed == 1)
        assert(w.inst.bank == "automatic_collector_mk2" and w.inst.build == w.inst.bank)
        assert(w.inst.mapicon == "automatic_collector_mk2.tex")
        assert(w.inst.components.inventoryitem.imagename == "automatic_collector_mk2")
        assert(Upgrades.DisplayName(w.inst) == "采集车")
        if count == 1 then assert(not kit:IsValid()) else
            assert(kit:IsValid() and kit.components.stackable:StackSize() == count - 1)
            assert(kit.components.inventoryitem.owner == player and kit.skinname == "test_skin")
        end
        assert(not installer:Install(player, w.inst))
        assert(not installer.installing and not w.inst._ac_installing)
    end
end

function scenarios.upgrade_two_players_and_reentry()
    local w, player, kit, installer = prepare(3)
    local _, other, otherkit, otherinstaller = prepare(2)
    local original = w.inst.components.ac_upgradable.SetLevel
    w.inst.components.ac_upgradable.SetLevel = function(self, ...)
        assert(not otherinstaller:Install(other, w.inst))
        assert(not installer:Install(player, w.inst))
        return original(self, ...)
    end
    assert(installer:Install(player, w.inst))
    assert(not otherinstaller:Install(other, w.inst))
    assert(kit.components.stackable:StackSize() == 2 and otherkit.components.stackable:StackSize() == 2)
end

function scenarios.upgrade_invalid_or_interrupted()
    local w, player, kit, installer = prepare(4)
    for _, invalidate in ipairs({
        function() w.inst.held = true end,
        function() w.inst.valid = false end,
        function() w.inst:AddTag("INLIMBO") end,
        function() kit.components.inventoryitem.owner = nil end,
        function() kit.valid = false end,
        function() player.valid = false end,
        function() player:AddTag("playerghost") end,
        function() player.x = 20 end,
        function() kit.components.inventoryitem.islockedinslot = true end,
    }) do
        invalidate()
        assert(not installer:Install(player, w.inst))
        assert(kit.components.stackable:StackSize() == 4 and not Upgrades.IsAdvanced(w.inst))
        w.inst.held, w.inst.valid, w.inst.tags.INLIMBO = false, true, nil
        kit.components.inventoryitem.owner, kit.valid = player, true
        kit.components.inventoryitem.islockedinslot = nil
        player.valid, player.tags.playerghost, player.x = true, nil, 0
    end
    assert(not installer:Install(player, H.entity("grass")))
    TheWorld.ismastersim = false
    assert(not installer:Install(player, w.inst))
    TheWorld.ismastersim = true
    -- The upgrade action never ran (player action interrupted): no world effects.
    assert(w.inst.components.ac_upgradable:GetLevel(Upgrades.CHASSIS) == 0)
end

function scenarios.upgrade_apply_rollback()
    local w, player, kit, installer = prepare(3)
    w.radius = 9 H.range_nets(w)
    w:SetMoveSpeed(1.5) w:SetActionSpeed(1.25)
    local original = API.upgrades[Upgrades.CHASSIS].apply
    API.upgrades[Upgrades.CHASSIS].apply = function(inst, level)
        original(inst, level)
        if level > 0 then error("injected apply failure") end
    end
    assert(not installer:Install(player, w.inst))
    API.upgrades[Upgrades.CHASSIS].apply = original
    assert(not Upgrades.IsAdvanced(w.inst) and w.inst.bank == "automatic_collector")
    assert(w.inst.components.ac_upgradable:GetLevel(Upgrades.CHASSIS) == 0)
    assert(w.inst.components.locomotor.walkspeed == 4.5 and w.action_speed == 1.25)
    assert(w.radius == 9 and w.inst._ac_radius:value() == 9)
    assert(kit.components.stackable:StackSize() == 3)
    assert(not installer.installing and not w.inst._ac_installing)
    assert(installer:Install(player, w.inst))
end

function scenarios.upgrade_radius_targets_and_delivery()
    local Targets = require("ac_targets")
    local w, player, _, installer = prepare(1, H.worker())
    H.range_nets(w)
    local inside, outside = H.chest(20), H.chest(20.1)
    assert(#Targets.GetContainers(w) == 0)
    local crop = H.farm_crop(20)
    assert(Targets.Kind(w, crop) == nil)
    assert(installer:Install(player, w.inst))
    assert(w.radius == 20 and w.inst._ac_radius:value() == 20)
    local containers = Targets.GetContainers(w)
    assert(#containers == 1 and containers[1] == inside, "Upgrade must invalidate same-tick container cache")
    assert(Targets.Kind(w, crop) == "pick")
    assert(Targets.Kind(w, H.farm_crop(20.1)) == nil)
    assert(Targets.Kind(w, H.item("twigs", 22)) == "pickup")
    assert(Targets.Kind(w, H.item("twigs", 22.1)) == nil)
    local giant_inside, giant_outside = H.giant(), H.giant()
    giant_inside.x, giant_outside.x = 22, 22.1
    assert(Targets.Kind(w, giant_inside) == "hammer")
    assert(Targets.Kind(w, giant_outside) == nil)
    local action = w:GetNextAction()
    assert(action ~= nil and w:ValidateAction(action), "Expanded boundary must work for planning and contact")
    w:Cancel(true)
    local cargo = H.item("twigs", 0)
    w.inst.components.inventory:GiveItem(cargo)
    assert(Targets.FindContainer(w, cargo) == inside)
    inside.valid = false
    assert(Targets.FindContainer(w, cargo) == nil and outside:IsValid())
end

function scenarios.upgrade_radius_config_save_and_display()
    local Insight = require("ac_insight")
    H.range_runtime()
    for _, radius in ipairs({ 8, 12, 16 }) do
        TUNING.AUTOMATIC_COLLECTOR.radius = radius
        local w, player, _, installer = prepare()
        H.range_nets(w) H.range_events(w.inst)
        assert(w.radius == radius)
        Insight.Select(w.inst)
        assert(w.inst._ac_range_indicator.radius == radius / 4)
        assert(installer:Install(player, w.inst))
        Insight.UpdateRange(w.inst)
        assert(w.inst._ac_range_indicator.radius == 5 and w.inst._ac_range_anchor.x == 0)
        Insight.Unselect(w.inst)
        local data, levels = w:OnSave(), w.inst.components.ac_upgradable:OnSave()
        for _, worker_first in ipairs({ false, true }) do
            local restored = prepare()
            H.range_nets(restored)
            if worker_first then restored:OnLoad(data) end
            restored.inst.components.ac_upgradable:OnLoad(levels)
            if not worker_first then restored:OnLoad(data) end
            assert(restored.radius == 20 and restored.inst._ac_radius:value() == 20)
            restored:OnPickup(nil) restored.inst.x = 3 restored:OnDropped()
            assert(restored.radius == 20 and restored.inst._ac_radius:value() == 20 and restored:GetHome().x == 3)
            assert(restored.inst.components.ac_upgradable:SetLevel(Upgrades.CHASSIS, 0))
            assert(restored.radius == radius and restored.inst._ac_radius:value() == radius)
        end
    end
end

function scenarios.upgrade_consumption_rollback()
    local w, player, kit, installer = prepare()
    local remove = kit.Remove
    kit.Remove = function() error("injected removal failure") end
    assert(not installer:Install(player, w.inst))
    assert(kit:IsValid() and kit.components.inventoryitem.owner == player)
    assert(not Upgrades.IsAdvanced(w.inst) and w.inst.components.locomotor.walkspeed == 3)
    assert(not installer.installing and not w.inst._ac_installing)
    kit.Remove = function(self) remove(self) error("injected post-removal failure") end
    assert(installer:Install(player, w.inst))
    assert(not kit:IsValid() and Upgrades.IsAdvanced(w.inst))
end

function scenarios.upgrade_detach_failure_and_cancel_recheck()
    local w, player, kit, installer = prepare(2)
    local remove = player.components.inventory.RemoveItem
    player.components.inventory.RemoveItem = function() return nil end
    assert(not installer:Install(player, w.inst))
    assert(kit.components.stackable:StackSize() == 2 and not Upgrades.IsAdvanced(w.inst))
    player.components.inventory.RemoveItem = remove
    local cancel = w.Cancel
    w.Cancel = function(self, ...)
        cancel(self, ...)
        self.inst.held = true
    end
    assert(not installer:Install(player, w.inst))
    assert(kit.components.stackable:StackSize() == 2 and not installer.installing)
end

function scenarios.upgrade_removed_during_apply_returns_kit()
    local w, player, kit, installer = prepare(2)
    local original = w.inst.components.ac_upgradable.SetLevel
    w.inst.components.ac_upgradable.SetLevel = function(self, ...)
        original(self, ...)
        w.inst:Remove()
        w.inst.components = {} -- Removal may have already detached the component table.
        return true
    end
    assert(not installer:Install(player, w.inst))
    assert(kit.components.stackable:StackSize() == 2 and kit.components.inventoryitem.owner == player)
    assert(not installer.installing and not w.inst._ac_installing)
end

function scenarios.upgrade_actual_work_contacts_once()
    for i, name in ipairs({ "pickup", "pick", "harvest", "hammer", "store" }) do
        local x = i * 100
        local w = prepare(1, H.worker(x))
        assert(w.inst.components.ac_upgradable:SetLevel(Upgrades.CHASSIS, 1))
        local receiver = H.chest(x + 5)
        local target
        if name == "pickup" then target = H.item("twigs", x + 1)
        elseif name == "pick" then target = H.plant(x + 1)
        elseif name == "harvest" then target = H.farm_crop(x + 1)
        elseif name == "hammer" then target = H.giant() target.x = x + 1
        else
            target = receiver
            w.inst.components.inventory:GiveItem(H.item("twigs", x))
        end
        local action = w:GetNextAction() assert(action.target == target)
        local state = H.enter(w, action, name == "harvest" and "pick" or name)
        local impact = w.inst.sg.statemem.impact
        w.inst.sg.timeinstate = impact - .001 state.onupdate(w.inst)
        assert(w.inst.mutations == nil)
        w.inst.sg.timeinstate = impact state.onupdate(w.inst) state.onupdate(w.inst)
        assert(w.inst.mutations == 1 and w.pending == nil)
        state.onexit(w.inst)
        if name == "store" then assert(not receiver.components.container:IsOpenedBy(w.inst)) end
    end
end

function scenarios.upgrade_walk_cargo_pause_boat()
    local w, player, kit, installer = prepare(2)
    local cargo = H.item("twigs", 0, nil, 7) w.inst.components.inventory:GiveItem(cargo)
    local target = H.item("twigs", 3)
    local action = w:GetNextAction() assert(action.target == target)
    local loco = H.walk_to(w, action)
    local failures = 0 action:AddFailAction(function() failures = failures + 1 end)
    local home, platform, localhome = w.home, {}, Vector3(0, 0, 0)
    w.homeplatform, w.homelocal, w.inst.platform = platform, localhome, platform
    w.farm_count, w.farm_draining = 3, true
    assert(installer:Install(player, w.inst))
    assert(w.pending == nil and w.cooldowns[target] == nil and failures == 1)
    assert(loco.dest == nil and w:GetCargo() == cargo and cargo.components.stackable:StackSize() == 7)
    assert(w.home == home and w.homeplatform == platform and w.homelocal == localhome)
    assert(w.enabled and w.farm_count == 3 and w.farm_draining)
    local paused, owner, _, component = prepare()
    paused:SetEnabled(false)
    assert(component:Install(owner, paused.inst) and not paused.enabled)
end

function scenarios.upgrade_contact_before_and_after()
    for _, hit in ipairs({ false, true }) do
        local w, player, _, installer = prepare()
        local crop = H.plant(1) crop:AddTag("farm_plant")
        local action = w:GetNextAction()
        local state = H.enter(w, action, "pick")
        if hit then w.inst.sg.timeinstate = .7 state.onupdate(w.inst) end
        -- enter's animation stub tracks only the work state; retain actual visuals for apply.
        visuals(w.inst)
        assert(installer:Install(player, w.inst))
        assert(w.farm_count == (hit and 1 or 0) and (crop.harvests or 0) == (hit and 1 or 0))
        assert(w.pending == nil and w.cooldowns[crop] == nil)
        assert(w.inst.sg.currentstate.name == "upgrade" and w.inst.sg.timeout == .4)
        crop.valid = false
    end
end

function scenarios.upgrade_prefab_client_and_host()
    local current, seed
    Asset = function(...) return { ... } end
    Prefab = function(name, fn, assets) return { name = name, fn = fn, assets = assets } end
    MakeCharacterPhysics, MakeInventoryPhysics, MakeHauntableLaunch = function() end, function() end, function() end
    package.loaded["brains/ac_collectorbrain"] = {}
    CreateEntity = function()
        local inst = H.entity("automatic_collector")
        current = inst
        visuals(inst)
        inst.GUID = #inst.events + 1
        inst.entity = {}
        for _, name in ipairs({ "AddTransform", "AddAnimState", "AddSoundEmitter", "AddDynamicShadow",
            "AddMiniMapEntity", "AddNetwork", "AddLight" }) do inst.entity[name] = function() end end
        inst.entity.SetPristine = function()
            assert(inst._ac_mk2 ~= nil or inst:HasTag("ac_upgrade_kit"))
            assert(next(inst.components) == nil, "No authoritative components before SetPristine")
        end
        inst.Light = { SetRadius = function() end, Enable = function() end }
        inst.DynamicShadow = { SetSize = function() end }
        inst.Transform.SetFourFaced = function() end
        inst.AnimState.SetScale = function() end
        inst.listeners = {}
        function inst:ListenForEvent(event, fn) self.listeners[event] = fn end
        function inst:PushEvent(event, data)
            if self.listeners[event] ~= nil then self.listeners[event](self, data) end
        end
        function inst:AddComponent(name)
            if name == "inventoryitem" then
                self.components[name] = { IsHeld = function() return self.held == true end,
                    ChangeImageName = function(s, v) s.imagename = v end,
                    SetOnPickupFn = function(s, fn) s.onpickupfn = fn end,
                    SetOnDroppedFn = function(s, fn) s.ondroppedfn = fn end }
            elseif name == "inventory" then self.components[name] = H.inventory(self)
            elseif name == "locomotor" then
                self.components[name] = { SetTriggersCreep = function() end, Stop = function() end,
                    Clear = function() end, StopMoving = function() end }
            elseif name == "ac_worker" then self.components[name] = require("components/ac_worker")(self)
            elseif name == "ac_upgradable" then self.components[name] = Upgradable(self)
            elseif name == "ac_upgradeitem" then self.components[name] = UpgradeItem(self)
            else self.components[name] = {} end
        end
        function inst:SetStateGraph() self.sg = { GoToState = function() end } end
        function inst:SetBrain() end
        return inst
    end
    local function net(_, name, dirty)
        local value = name == "ac.mk2" and seed == true or false
        local inst = current
        return { value = function() return value end, set = function(_, v)
            value = v
            if dirty ~= nil then inst:PushEvent(dirty) end
        end }
    end
    net_bool, net_float, net_entity = net, net, net
    package.loaded["prefabs/automatic_collector"] = nil
    local prefab = require("prefabs/automatic_collector")
    local declared = {}
    for _, asset in ipairs(prefab.assets) do declared[asset[2]] = true end
    assert(declared["anim/automatic_collector_mk2.zip"])
    TheWorld.ismastersim = false
    local client = prefab.fn()
    assert(client.components.ac_worker == nil and client.bank == "automatic_collector")
    client._ac_mk2:set(true)
    assert(client.bank == "automatic_collector_mk2" and client.mapicon == "automatic_collector_mk2.tex")
    assert(client:displaynamefn() == "采集车")
    seed = true
    local late = prefab.fn()
    assert(late.bank == "automatic_collector_mk2" and late.components.ac_upgradable == nil)
    seed, TheWorld.ismastersim = false, true
    local host = prefab.fn()
    host.components.ac_upgradable:OnLoad({ levels = { [Upgrades.CHASSIS] = 1 } })
    assert(host.bank == "automatic_collector_mk2" and host.components.locomotor.walkspeed == 6)
    assert(host.components.ac_worker.radius == 20 and host._ac_radius:value() == 20)
    assert(host.components.inventoryitem.atlasname == "images/inventoryimages/automatic_collector_mk2.xml")
    assert(host.components.inventoryitem.imagename == "automatic_collector_mk2")
    local Sounds = require("ac_sounds")
    local loop, kills = false, 0
    host.SoundEmitter = {
        PlaySound = function(_, _, channel) if channel == "ac_walk" then loop = true end end,
        KillSound = function(_, channel)
            assert(channel == "ac_walk") loop = false kills = kills + 1
        end,
    }
    Sounds.StartWalk(host)
    host.components.inventoryitem.onpickupfn(host, nil)
    assert(not loop and not host._ac_walk_sound and kills == 1)
    Sounds.StartWalk(host)
    host.OnEntitySleep(host)
    assert(not loop and not host._ac_walk_sound and kills == 2)
    Sounds.StartWalk(host)
    host:PushEvent("onremove")
    assert(not loop and not host._ac_walk_sound and kills == 3)
    package.loaded["prefabs/ac_upgrade_kit"] = nil
    local kit_prefab = require("prefabs/ac_upgrade_kit")
    local kit = kit_prefab.fn()
    assert(kit.components.ac_upgradeitem ~= nil and kit.components.stackable.maxsize == 20)
    assert(kit.bank == "ac_upgrade_kit" and kit.components.inventoryitem.imagename == "ac_upgrade_kit")
    TheWorld.ismastersim = false
    local kit_client = kit_prefab.fn()
    assert(kit_client:HasTag("ac_upgrade_kit") and kit_client.components.ac_upgradeitem == nil)
end

function scenarios.upgrade_store_closes_only_own_opener()
    local w, player, _, installer = prepare()
    local target = H.chest(3)
    local cargo = H.item("twigs", 0, nil, 4) w.inst.components.inventory:GiveItem(cargo)
    local action = w:GetNextAction()
    local state = H.enter(w, action, "store")
    w.inst.sg.timeinstate = .2 state.onupdate(w.inst)
    assert(target.components.container:IsOpenedBy(w.inst))
    target.components.container:Open(player)
    visuals(w.inst)
    assert(installer:Install(player, w.inst))
    assert(not target.components.container:IsOpenedBy(w.inst))
    assert(target.components.container:IsOpenedBy(player) and target.components.container.stored.twigs == 4)
end

function scenarios.upgrade_load_idempotent_and_relocate()
    local w, player, _, installer = prepare()
    assert(installer:Install(player, w.inst))
    local data = w.inst.components.ac_upgradable:OnSave()
    data.levels.unknown_extension = 4
    local restored = prepare()
    restored.inst.components.ac_upgradable:OnLoad(data)
    restored.inst.components.ac_upgradable:OnLoad(data)
    assert(restored.inst.components.locomotor.walkspeed == 6 and restored.action_speed == 1)
    assert(restored.inst.components.ac_upgradable:GetLevel("unknown_extension") == 4)
    restored:OnPickup(nil) restored:OnDropped()
    assert(Upgrades.IsAdvanced(restored.inst) and restored.inst.components.locomotor.walkspeed == 6)
    assert(restored.inst.components.ac_upgradable:SetLevel(Upgrades.CHASSIS, 0))
    assert(restored.inst.components.locomotor.walkspeed == 3 and restored.inst.bank == "automatic_collector")
    local legacy = prepare() legacy.inst.components.ac_upgradable:OnLoad(nil)
    assert(not Upgrades.IsAdvanced(legacy.inst) and legacy.inst.components.locomotor.walkspeed == 3)
end

function scenarios.upgrade_work_timing_and_walk_reset()
    for _, name in ipairs({ "pickup", "pick", "hammer", "store" }) do
        local w = prepare()
        assert(w.inst.components.ac_upgradable:SetLevel(Upgrades.CHASSIS, 1))
        local target, action
        if name == "pickup" then target, action = H.item("twigs", 1), ACTIONS.PICKUP
        elseif name == "store" then target, action = H.chest(1), ACTIONS.STORE
        else target, action = H.plant(1), ACTIONS.PICK end
        local state = H.enter(w, BufferedAction(w.inst, target, action), name)
        assert(w.inst.sg.timeout == ((name == "pick" or name == "hammer") and 1.3 or 1))
        assert(w.inst.sg.statemem.impact == (name == "store" and .2 or name == "pickup" and .5 or .7))
        visuals(w.inst) w.inst._ac_mk2:set(true)
        for _, walk in ipairs(H.states) do
            if string.find(walk.name, "walk") then
                walk.onenter(w.inst) assert(w.inst.multiplier == 2)
                walk.onexit(w.inst) assert(w.inst.multiplier == 1)
            end
        end
        state.onexit(w.inst) assert(w.inst.multiplier == 1)
    end
end

-- Load the real modmain registration in a mod environment (without a running game).
function scenarios.upgrade_recipe_and_action_selection()
    local callbacks, recipes, handlers = {}, {}, {}
    GLOBAL = { TUNING = TUNING, STRINGS = { NAMES = {}, RECIPE_DESC = {}, ACTIONS = {},
        CHARACTERS = { GENERIC = { DESCRIBE = {}, ACTIONFAIL = {} } } },
        Ingredient = function(name, count) return { name = name, count = count } end,
        TECH = { SCIENCE_TWO = {} }, ActionHandler = ActionHandler }
    Asset = function(...) return { ... } end
    GetModConfigData = function() return nil end
    AddMinimapAtlas = function() end
    RegisterInventoryItemAtlas = function() end
    AddSimPostInit = function() end
    AddRecipe2 = function(name, ingredients, tech) recipes[name] = { ingredients = ingredients, tech = tech } end
    AddAction = function(id, _, fn)
        local a = { id = id, fn = fn } ACTIONS[id] = a return a
    end
    AddComponentAction = function(context, name, fn) callbacks[context .. ":" .. name] = fn end
    AddStategraphActionHandler = function(name, handler) handlers[name .. ":" .. handler.action.id] = handler.state end
    assert(loadfile(TEST_ROOT .. "/modmain.lua"))()
    local recipe = recipes.ac_upgrade_kit
    assert(recipe.tech == GLOBAL.TECH.SCIENCE_TWO)
    for i, expected in ipairs({ {"thulecite", 10}, {"wagpunk_bits", 3}, {"moonrocknugget", 5} }) do
        assert(recipe.ingredients[i].name == expected[1] and recipe.ingredients[i].count == expected[2])
    end
    assert(handlers["wilson:AC_UPGRADE"] == "doshortaction")
    assert(handlers["wilson_client:AC_UPGRADE"] == "doshortaction")
    local w, player, kit = prepare(2)
    player.replica = { inventory = player.components.inventory }
    player.components.inventory.active = kit
    local actions = {}
    callbacks["USEITEM:ac_upgradeitem"](kit, player, w.inst, actions, true)
    callbacks["SCENE:inspectable"](w.inst, player, actions, true)
    assert(#actions == 1 and actions[1] == ACTIONS.AC_UPGRADE)
    assert(actions[1].priority > ACTIONS.AC_TOGGLE.priority)
    assert(actions[1].fn({ doer = player, target = w.inst, invobject = kit }))
    local ok, reason = actions[1].fn({ doer = player, target = w.inst, invobject = kit })
    assert(not ok and reason == "ALREADY_UPGRADED" and w.enabled)
    actions = {}
    callbacks["USEITEM:ac_upgradeitem"](kit, player, H.entity("grass"), actions, true)
    assert(#actions == 0)
    player.components.inventory.active = nil
    callbacks["SCENE:inspectable"](w.inst, player, actions, true)
    assert(#actions == 1 and actions[1] == ACTIONS.AC_TOGGLE)
end
