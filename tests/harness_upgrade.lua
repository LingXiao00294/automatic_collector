local H = upgrade_contract
local Upgrades = require("ac_upgrades")
local UpgradeItem = require("components/ac_upgradeitem")
local Upgradable = require("components/ac_upgradable")
local API = require("ac_api")
TheWorld = { ismastersim = true }
STRINGS = { NAMES = { AUTOMATIC_COLLECTOR = "拾荒机", AUTOMATIC_COLLECTOR_MK2 = "采集车" } }
Upgrades.Register()

local function visuals(inst)
    function inst:SetPrefabName(name)
        self.prefab, self.native_prefab = name, name
        self.name = self.name or STRINGS.NAMES[string.upper(name)]
    end
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
    inst.Physics = { radius = .25 }
    function inst.Physics:SetCapsule(radius, height) self.radius, self.height = radius, height end
    function inst.Physics:GetRadius() return self.radius end
    function inst.Physics:IsActive() return false end
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
        assert(w.inst.prefab == "automatic_collector_mk2" and w.inst.native_prefab == w.inst.prefab)
        assert(w.inst.Physics:GetRadius() == .25 and w.inst.Physics.height == 1)
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
    assert(w.inst.prefab == "automatic_collector" and w.inst.native_prefab == w.inst.prefab)
    assert(w.inst.Physics:GetRadius() == .25, "Failed installation must preserve the shared collision radius")
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
    assert(w.inst.prefab == "automatic_collector")
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
        local drop = H.item("twigs", 1, nil, 3)
        w.farm_count = 2
        local action = w:GetNextAction()
        local state = H.enter(w, action, "pickup")
        if hit then w.inst.sg.timeinstate = .5 state.onupdate(w.inst) end
        -- enter's animation stub tracks only the work state; retain actual visuals for apply.
        visuals(w.inst)
        assert(installer:Install(player, w.inst))
        assert(w.farm_count == 2 and w:GetCargo() == (hit and drop or nil))
        assert(w.pending == nil and w.cooldowns[drop] == nil and w:IsHarvestEnabled())
        assert(w.inst.sg.currentstate.name == "upgrade" and w.inst.sg.timeout == .4)
        drop.valid = false
    end
end

function scenarios.harvest_toggle_upgrade_and_load_order()
    local w, player, _, installer = prepare()
    local crop = H.farm_crop(1)
    assert(not w:IsHarvestEnabled() and w:GetNextAction() == nil)
    assert(installer:Install(player, w.inst) and w:IsHarvestEnabled())
    local action = w:GetNextAction()
    assert(action.target == crop)
    w:Cancel(true)
    w.farm_count = 2
    w:SetHarvestEnabled(false)
    local current, levels = w:OnSave(), w.inst.components.ac_upgradable:OnSave()
    assert(current.enabled and not current.harvest_enabled)
    for _, data in ipairs({ current, { enabled = false, farm_count = 2 }, { enabled = true } }) do
        for _, worker_first in ipairs({ false, true }) do
            local restored = prepare()
            if worker_first then restored:OnLoad(data) end
            restored.inst.components.ac_upgradable:OnLoad(levels)
            if not worker_first then restored:OnLoad(data) end
            local expected = data.harvest_enabled ~= false and data.enabled ~= false
            assert(restored.enabled and restored:IsHarvestEnabled() == expected)
            assert(restored.inst._ac_enabled:value() and restored.inst._ac_harvest_enabled:value() == expected)
            assert(restored.farm_count == (data.farm_count or 0))
            restored:OnPickup(nil) restored:OnDropped()
            assert(restored:IsHarvestEnabled() == expected)
        end
    end
    local legacy_base = prepare()
    legacy_base:OnLoad({ enabled = false, farm_count = 3, farm_draining = true })
    assert(legacy_base.enabled and not legacy_base:IsHarvestEnabled())
    local drop = H.item("twigs", 1)
    assert(legacy_base:GetNextAction().target == drop)
    assert(legacy_base.farm_count == 3 and legacy_base.farm_draining)
end

local function prefab_runtime(stack_post_init)
    local current, seed
    local native_locomotor = {
        SetTriggersCreep = function() end,
        FindPath = function(self) self.native_paths = (self.native_paths or 0) + 1 end,
        OnUpdate = function() end, Stop = function() end, Clear = function() end,
        StopMoving = function() end, WantsToMoveForward = function() return false end,
        SetMoveDir = function() end, SetMotorSpeed = function() end,
    }
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
        inst.entity.SetPrefabName = function(_, name) inst.native_prefab = name end
        inst.entity.HasTag = function(_, tag) return inst:HasTag(tag) end
        inst.entity.IsValid = function() return inst:IsValid() end
        for _, name in ipairs({ "AddTransform", "AddAnimState", "AddSoundEmitter", "AddDynamicShadow",
            "AddMiniMapEntity", "AddNetwork", "AddLight" }) do inst.entity[name] = function() end end
        inst.entity.SetPristine = function()
            assert(inst._ac_mk2 ~= nil or inst:HasTag("ac_upgrade_kit"))
            assert(inst._ac_harvest_enabled ~= nil or inst:HasTag("ac_upgrade_kit"))
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
                self.components[name] = {}
                for method, fn in pairs(native_locomotor) do self.components[name][method] = fn end
            elseif name == "ac_worker" then self.components[name] = require("components/ac_worker")(self)
            elseif name == "ac_upgradable" then self.components[name] = Upgradable(self)
            elseif name == "ac_upgradeitem" then self.components[name] = UpgradeItem(self)
            elseif name == "stackable" then
                self.components[name] = { maxsize = TUNING.STACK_SIZE_MEDITEM }
                if stack_post_init ~= nil then stack_post_init(self.components[name]) end
            else self.components[name] = {} end
        end
        function inst:SetStateGraph() self.sg = { GoToState = function() end } end
        function inst:SetBrain() end
        for name, method in pairs(NativeEntityScript or {}) do inst[name] = method end
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
    local prefab, advanced = assert(loadfile(TEST_ROOT .. "/scripts/prefabs/automatic_collector.lua"))()
    package.loaded["prefabs/automatic_collector"] = prefab
    return prefab, function(value) seed = value end, native_locomotor, advanced
end

function scenarios.collector_distinct_prefabs()
    local base, set_seed, _, advanced = prefab_runtime()
    assert(base.name == "automatic_collector" and advanced.name == "automatic_collector_mk2")
    TheWorld.ismastersim = true
    local ordinary, collector = base.fn(), advanced.fn()
    assert(ordinary.prefab == base.name and collector.prefab == advanced.name)
    assert(not ordinary.components.ac_worker:IsHarvestEnabled())
    assert(collector.components.ac_worker:IsHarvestEnabled())
    assert(collector.components.ac_upgradable:GetLevel(Upgrades.CHASSIS) == 1)
    assert(collector.components.locomotor.walkspeed == 6 and collector.components.ac_worker.radius == 20)
    assert(ordinary:displaynamefn() == "拾荒机" and collector:displaynamefn() == "采集车")
    assert(ordinary:HasTag("automatic_collector") and collector:HasTag("automatic_collector"))
    local cargo = H.item("twigs", 0, nil, 7)
    ordinary.components.inventory:GiveItem(cargo)
    ordinary.components.ac_worker.farm_count = 3
    ordinary.components.ac_worker:SetHarvestEnabled(false)
    assert(ordinary.components.ac_upgradable:SetLevel(Upgrades.CHASSIS, 1))
    assert(ordinary.prefab == advanced.name and ordinary.components.ac_worker:GetCargo() == cargo)
    assert(ordinary.components.ac_worker.farm_count == 3 and not ordinary._ac_harvest_enabled:value())
    assert(collector.components.ac_upgradable:SetLevel(Upgrades.CHASSIS, 0))
    assert(collector.prefab == base.name and collector.native_prefab == base.name)
    assert(collector:displaynamefn() == "拾荒机" and not collector.components.ac_worker:IsHarvestEnabled())
    TheWorld.ismastersim = false
    set_seed(true)
    local client = advanced.fn()
    assert(client.prefab == advanced.name and client.components.ac_worker == nil)
    assert(client:displaynamefn() == "采集车")
    client._ac_mk2:set(false)
    assert(client.prefab == base.name and client.native_prefab == base.name)
    assert(client:displaynamefn() == "拾荒机")
end

-- Uses the installed game's actual EntityScript and SpawnSaveRecord methods.
function scenarios.collector_prefab_native_save_load()
    local base, _, _, advanced = prefab_runtime()
    local prefabs = { [base.name] = base, [advanced.name] = advanced }
    SpawnPrefab = function(name)
        local inst = prefabs[name].fn()
        inst:SetPrefabName(inst.prefab or name)
        return inst
    end
    TheWorld.ismastersim = true
    for _, name in ipairs({ base.name, advanced.name }) do
        local inst = SpawnPrefab(name)
        local worker = inst.components.ac_worker
        inst.Transform:SetPosition(3, 0, 4)
        worker:SetHome()
        worker:SetHarvestEnabled(false)
        worker.farm_count, worker.farm_draining = 3, true
        inst.components.ac_upgradable.levels.unknown_extension = 4
        local record = inst:GetSaveRecord()
        assert(record.prefab == name and inst.native_prefab == name)
        local restored = SpawnSaveRecord(record)
        assert(restored.prefab == name and restored.native_prefab == name)
        assert(restored:GetBasicDisplayName() == (name == base.name and "拾荒机" or "采集车"))
        assert(restored.components.ac_upgradable:GetLevel("unknown_extension") == 4)
        local loaded = restored.components.ac_worker
        assert(loaded:GetHome().x == 3 and loaded:GetHome().z == 4)
        assert(loaded.farm_count == 3 and loaded.farm_draining and not loaded.harvest_enabled)
        assert(loaded:IsHarvestEnabled() == false)
        if name == advanced.name then
            -- Old worlds saved the upgraded car under the base prefab name.
            record.prefab = base.name
            local legacy = SpawnSaveRecord(record)
            assert(legacy.prefab == advanced.name and legacy.native_prefab == advanced.name)
            assert(legacy:GetSaveRecord().prefab == advanced.name)
            assert(legacy.components.locomotor.walkspeed == 6 and legacy.components.ac_worker.radius == 20)
            assert(legacy.components.ac_worker.farm_count == 3 and not legacy._ac_harvest_enabled:value())
            assert(legacy.components.ac_upgradable:SetLevel(Upgrades.CHASSIS, 0))
            local downgraded = SpawnSaveRecord(legacy:GetSaveRecord())
            assert(downgraded.prefab == base.name and downgraded:GetBasicDisplayName() == "拾荒机")
        end
    end
end

function scenarios.upgrade_prefab_client_and_host()
    local prefab, set_seed = prefab_runtime()
    local declared = {}
    for _, asset in ipairs(prefab.assets) do declared[asset[2]] = true end
    assert(declared["anim/automatic_collector_mk2.zip"])
    TheWorld.ismastersim = false
    local client = prefab.fn()
    assert(client.components.ac_worker == nil and client.bank == "automatic_collector")
    assert(client.prefab == "automatic_collector" and client:displaynamefn() == "拾荒机")
    assert(client.Physics:GetRadius() == .25)
    assert(client._ac_harvest_enabled:value())
    client._ac_mk2:set(true)
    assert(client.prefab == "automatic_collector_mk2" and client.native_prefab == client.prefab)
    assert(client.bank == "automatic_collector_mk2" and client.mapicon == "automatic_collector_mk2.tex")
    assert(client.Physics:GetRadius() == .25)
    assert(client:displaynamefn() == "采集车")
    set_seed(true)
    local late = prefab.fn()
    assert(late.prefab == "automatic_collector_mk2")
    assert(late.bank == "automatic_collector_mk2" and late.components.ac_upgradable == nil)
    assert(late.Physics:GetRadius() == .25)
    set_seed(false)
    TheWorld.ismastersim = true
    local host = prefab.fn()
    assert(host.components.inventoryitem.canbepickedup == false,
        "The action button must not pick up either car")
    assert(not host.components.ac_worker:IsHarvestEnabled())
    host.components.ac_upgradable:OnLoad({ levels = { [Upgrades.CHASSIS] = 1 } })
    assert(host.prefab == "automatic_collector_mk2")
    assert(host.bank == "automatic_collector_mk2" and host.components.locomotor.walkspeed == 6)
    assert(host.Physics:GetRadius() == .25)
    assert(host.components.ac_worker.radius == 20 and host._ac_radius:value() == 20)
    assert(host.components.inventoryitem.atlasname == "images/inventoryimages/automatic_collector_mk2.xml")
    assert(host.components.inventoryitem.imagename == "automatic_collector_mk2")
    assert(host.components.inventoryitem.canbepickedup == false)
    host.components.ac_worker:SetHarvestEnabled(false)
    assert(host.components.ac_worker.enabled and not host._ac_harvest_enabled:value())
    host.components.ac_worker:SetHarvestEnabled(true)
    local Sounds = require("ac_sounds")
    local loop, kills, signals = false, 0, {}
    host.SoundEmitter = {
        PlaySound = function(_, event, channel)
            if channel == "ac_walk" then loop = true else table.insert(signals, event) end
        end,
        KillSound = function(_, channel)
            assert(channel == "ac_walk") loop = false kills = kills + 1
        end,
    }
    Sounds.StartWalk(host)
    host.components.ac_worker:SetHarvestEnabled(false)
    host.components.ac_worker:SetHarvestEnabled(true)
    assert(loop and kills == 0, "Collection changes must not stop transport's rolling sound")
    assert(table.concat(signals, ",") == "ac_collector/metal/stop,ac_collector/metal/start")
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

function scenarios.upgrade_kit_preserves_stack_mod_settings()
    TheWorld.ismastersim = true
    local native_default = TUNING.STACK_SIZE_MEDITEM
    for _, config in ipairs({
        { default = 20, maxsize = 20 },
        { default = 64, maxsize = 64 },
        { default = 128, maxsize = 128 },
        { default = 20, maxsize = 40 },
        { default = 64, maxsize = math.huge, originalmaxsize = 64 },
    }) do
        TUNING.STACK_SIZE_MEDITEM = config.default
        prefab_runtime(function(stack)
            stack.maxsize, stack.originalmaxsize = config.maxsize, config.originalmaxsize
        end)
        package.loaded["prefabs/ac_upgrade_kit"] = nil
        local kit = require("prefabs/ac_upgrade_kit").fn()
        assert(kit.components.stackable.maxsize == config.maxsize,
            "Upgrade kits must preserve the stack limit set by native or mod initialization")
        assert(kit.components.stackable.originalmaxsize == config.originalmaxsize)
    end
    TUNING.STACK_SIZE_MEDITEM = native_default
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
    assert(restored.inst.Physics:GetRadius() == .25)
    assert(restored.inst.components.ac_upgradable:GetLevel("unknown_extension") == 4)
    restored:OnPickup(nil) restored:OnDropped()
    assert(Upgrades.IsAdvanced(restored.inst) and restored.inst.components.locomotor.walkspeed == 6)
    assert(restored.inst.components.ac_upgradable:SetLevel(Upgrades.CHASSIS, 0))
    assert(restored.inst.prefab == "automatic_collector" and Upgrades.DisplayName(restored.inst) == "拾荒机")
    assert(restored.inst.components.locomotor.walkspeed == 3 and restored.inst.bank == "automatic_collector")
    assert(restored.inst.Physics:GetRadius() == .25)
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
local function register_modmain(config)
    local callbacks, recipes, handlers = {}, {}, {}
    GLOBAL = { TUNING = TUNING, ACTIONS = ACTIONS, STRINGS = { NAMES = {}, RECIPE_DESC = {}, ACTIONS = {},
        CHARACTERS = { GENERIC = { DESCRIBE = {}, ACTIONFAIL = {} } } },
        Ingredient = function(name, count) return { name = name, count = count } end,
        TECH = { SCIENCE_TWO = {} }, ActionHandler = ActionHandler }
    Asset = function(...) return { ... } end
    config = config or {}
    GetModConfigData = function(name) return config[name] end
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
    return callbacks, recipes, handlers
end

function scenarios.navigation_configuration()
    assert(loadfile(TEST_ROOT .. "/modinfo.lua"))()
    local option
    for _, value in ipairs(configuration_options) do
        if value.name == "new_navigation" then option = value end
    end
    assert(option ~= nil and option.default == true, "New navigation must be enabled by default")
    assert(option.options[1].data == true and option.options[2].data == false)
    local native_require = require
    local function without_navigation(name)
        assert(name ~= "ac_navigation", "Disabled navigation and clients must not load the planner")
        return native_require(name)
    end
    for _, config in ipairs({ {}, { new_navigation = false }, { new_navigation = true } }) do
        register_modmain(config)
        local enabled = config.new_navigation ~= false
        assert(TUNING.AUTOMATIC_COLLECTOR.new_navigation == enabled)
        require = without_navigation
        local prefab, _, native_locomotor = prefab_runtime()
        TheWorld.ismastersim = false
        assert(prefab.fn().components.locomotor == nil)
        TheWorld.ismastersim = true
        if enabled then require = native_require end
        local function check_navigation(inst)
            local loco = inst.components.locomotor
            assert((loco._ac_navigation_attached == true) == enabled)
            if not enabled then
                for name, fn in pairs(native_locomotor) do assert(loco[name] == fn, name) end
                loco:FindPath()
                assert(loco.native_paths == 1, "Disabled navigation must keep native path dispatch")
                assert(loco._ac_navigation == nil)
            else
                assert(loco.FindPath ~= native_locomotor.FindPath)
            end
        end
        for _, level in ipairs({ 0, 1 }) do
            local host = prefab.fn()
            host.components.ac_worker:OnDropped()
            assert(host.components.ac_upgradable:SetLevel(Upgrades.CHASSIS, level))
            check_navigation(host)
            local restored = prefab.fn()
            restored.components.ac_worker:OnLoad(host.components.ac_worker:OnSave())
            restored.components.ac_upgradable:OnLoad(host.components.ac_upgradable:OnSave())
            check_navigation(restored)
            assert(restored.Physics:GetRadius() == .25)
            assert(restored.components.ac_worker.radius == (level == 1 and 20 or 12))
        end
        require = native_require
    end
end

function scenarios.upgrade_recipe_and_action_selection()
    local callbacks, recipes, handlers = register_modmain()
    local recipe = recipes.ac_upgrade_kit
    assert(recipe.tech == GLOBAL.TECH.SCIENCE_TWO)
    for i, expected in ipairs({ {"thulecite", 10}, {"wagpunk_bits", 3}, {"moonrocknugget", 5} }) do
        assert(recipe.ingredients[i].name == expected[1] and recipe.ingredients[i].count == expected[2])
    end
    assert(handlers["wilson:AC_UPGRADE"] == "doshortaction")
    assert(handlers["wilson_client:AC_UPGRADE"] == "doshortaction")
    local w, player, kit = prepare(2)
    player.replica = { inventory = player.components.inventory }
    local actions = {}
    callbacks["SCENE:inspectable"](w.inst, player, actions, true)
    assert(#actions == 0, "Base cars must not offer a player toggle")
    assert(not ACTIONS.AC_TOGGLE.fn({ doer = player, target = w.inst }) and w.enabled)
    player.components.inventory.active = kit
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
    assert(handlers["wilson:AC_TOGGLE"] == "doshortaction")
    assert(handlers["wilson_client:AC_TOGGLE"] == "doshortaction")
    assert(GLOBAL.STRINGS.ACTIONS.AC_TOGGLE.STOP == "关闭采集")
    assert(GLOBAL.STRINGS.ACTIONS.AC_TOGGLE.START == "开启采集")
    local toggle, act = actions[1], { doer = player, target = w.inst }
    assert(toggle.strfn(act) == "STOP" and toggle.fn(act))
    assert(w.enabled and not w.harvest_enabled and toggle.strfn(act) == "START")
    assert(toggle.fn(act) and w.enabled and w:IsHarvestEnabled())
    w.inst.held = true
    assert(not toggle.fn(act) and w.harvest_enabled)
    w.inst.held = false w.inst:AddTag("INLIMBO")
    actions = {}
    callbacks["SCENE:inspectable"](w.inst, player, actions, true)
    assert(#actions == 0 and not toggle.fn(act))
    w.inst.tags.INLIMBO = nil w.inst.valid = false
    assert(not toggle.fn(act))
    assert(not toggle.fn({ doer = player }))
    local client = H.entity("automatic_collector", 0, { "automatic_collector" })
    client._ac_mk2:set(true) client._ac_harvest_enabled:set(false)
    actions = {}
    callbacks["SCENE:inspectable"](client, player, actions, true)
    assert(#actions == 1 and toggle.strfn({ target = client }) == "START")
    assert(not toggle.fn({ doer = player, target = client }))
    actions = {}
    callbacks["SCENE:inspectable"](client, player, actions, false)
    assert(#actions == 0)
end

function scenarios.collector_mouse_pickup()
    local callbacks, _, handlers = register_modmain()
    local pickup = ACTIONS.AC_PICKUP
    assert(pickup ~= nil and pickup.priority == ACTIONS.PICKUP.priority)
    assert(pickup.mount_valid == ACTIONS.PICKUP.mount_valid)
    assert(pickup.extra_arrive_dist == ACTIONS.PICKUP.extra_arrive_dist)
    assert(handlers["wilson:AC_PICKUP"] == "doshortaction")
    assert(handlers["wilson_client:AC_PICKUP"] == "doshortaction")
    for _, advanced in ipairs({ false, true }) do
        local x = advanced and 100 or 0
        local w, player = prepare(1, H.worker(x, false))
        if advanced then assert(w.inst.components.ac_upgradable:SetLevel(Upgrades.CHASSIS, 1)) end
        player.x = x
        player.components.inventory.maxslots = 3
        player.replica = { inventory = player.components.inventory }
        local cargo = H.item("twigs", x, nil, 7)
        w.inst.components.inventory:GiveItem(cargo)
        local receiver = H.chest(x + 5)
        local action = w:GetNextAction()
        assert(action.target == receiver)
        local failures = 0
        action:AddFailAction(function() failures = failures + 1 end)
        local actions = {}
        callbacks["SCENE:inventoryitem"](w.inst, player, actions, false)
        assert(#actions == 1 and actions[1] == pickup)
        actions = {}
        callbacks["SCENE:inventoryitem"](w.inst, player, actions, true)
        assert(#actions == 0, "Right click must never pick up a car")
        callbacks["SCENE:inventoryitem"](H.item("flint", x), player, actions, false)
        assert(#actions == 0, "Other items keep their native pickup actions")
        w.inst:AddTag("INLIMBO")
        callbacks["SCENE:inventoryitem"](w.inst, player, actions, false)
        assert(#actions == 0 and not pickup.fn({ doer = player, target = w.inst }))
        w.inst.tags.INLIMBO = nil
        player.components.itemtyperestrictions = { IsAllowed = function() return false end }
        assert(not pickup.fn({ doer = player, target = w.inst }) and w:GetCargo() == cargo)
        player.components.itemtyperestrictions = nil
        player:AddTag("playerghost")
        callbacks["SCENE:inventoryitem"](w.inst, player, actions, false)
        assert(#actions == 0 and not pickup.fn({ doer = player, target = w.inst }))
        player.tags.playerghost = nil
        -- Native inventory GiveItem invokes the item's pickup callback as it transfers ownership.
        local give = player.components.inventory.GiveItem
        player.components.inventory.GiveItem = function(self, target, ...)
            if target == w.inst then w:OnPickup(player) end
            return give(self, target, ...)
        end
        assert(pickup.fn({ doer = player, target = w.inst }))
        assert(w:GetCargo() == nil and w.home == nil and w.pending == nil and failures == 1)
        assert(cargo.components.inventoryitem.owner == player and cargo.components.stackable:StackSize() == 7)
        assert(w.inst.components.inventoryitem.owner == player)
        w.inst.held = true
        assert(not pickup.fn({ doer = player, target = w.inst }))
        assert(w.inst.components.inventoryitem.canbepickedup == false)
        assert(not pickup.fn({ doer = player, target = H.item("rocks", x) }))
        assert(not pickup.fn({ doer = player }))
    end
end
