local H = upgrade_contract
local API = require("ac_api")
local Targets = require("ac_targets")
local Features = require("ac_features")
local Controls = require("ac_controls")

function scenarios.reserved_facilities_and_ground_materials()
    local w = H.setup()
    local facilities = {
        { prefab = "sculptingtable", tag = "structure", product = "cutstone" },
        { prefab = "sculptingtable", tag = "prototyper", product = "marble" },
        { prefab = "sculptingtable", component = "craftingstation", product = "moonglass" },
        { prefab = "meatrack", component = "dryingrack", product = "smallmeat_dried" },
        { prefab = "birdcage", component = "trader", product = "bird_egg" },
        { prefab = "display", component = "inventoryitemholder", product = "cutstone" },
        { prefab = "machine", component = "container", product = "twigs" },
    }
    for index, spec in ipairs(facilities) do
        local facility = H.plant(index / 10)
        facility.prefab = spec.prefab
        facility.components.pickable.product = spec.product
        if spec.tag ~= nil then facility:AddTag(spec.tag) end
        if spec.component ~= nil then facility.components[spec.component] = {} end
        assert(Targets.Kind(w, facility) == nil)
    end
    -- No prefab blacklist: the same materials on the ground remain transportable.
    for _, prefab in ipairs({ "cutstone", "marble", "moonglass" }) do
        local item = H.item(prefab, 1, nil, 3)
        assert(Targets.Kind(w, item) == "pickup")
        H.execute(w, w:GetNextAction())
        H.execute(w, w:GetNextAction())
        assert(w:GetCargo() == nil)
    end
    local mounted = H.item("marble", 1)
    mounted.parent = H.entity("display", 1)
    assert(Targets.Kind(w, mounted) == nil)
    mounted.parent = nil
    assert(Targets.Kind(w, mounted) == "pickup")
end

function scenarios.reserved_targets_revalidate_before_contact()
    for index, kind in ipairs({ "plant", "adapter", "pickup" }) do
        for _, watchdog in ipairs({ false, true }) do
            local x = index * 100 + (watchdog and 30 or 0)
            local w = H.worker(x)
            H.chest(x + 3)
            local target = kind == "pickup" and H.item("cutstone", x + 1, nil, 7)
                or kind == "plant" and H.plant(x + 1) or H.entity("custom_resource", x + 1)
            if kind == "adapter" then
                API.RegisterAdapter("protected_resource", {
                    match = function(_, t) return t == target end,
                    action = function() return ACTIONS.HARVEST end,
                    product = function() return "cutgrass", 1 end,
                })
            end
            local action = w:GetNextAction()
            assert(action ~= nil and action.target == target)
            local state = H.enter(w, action, kind == "pickup" and "pickup" or "pick")
            if kind == "pickup" then target.parent = H.entity("display", x + 1)
            else target:AddTag("structure") end
            if watchdog then w:Watchdog() else
                w.inst.sg.timeinstate = 1
                state.onupdate(w.inst)
            end
            assert(w.pending == nil and w.inst.mutations == nil and w:GetCargo() == nil)
            assert(w.cooldowns[target] == nil and w.farm_count == 0)
            if kind == "pickup" then assert(target.components.stackable:StackSize() == 7) end
        end
    end
end

function scenarios.feature_combinations(crops, plants, hammer)
    local w = H.setup()
    assert(w:SetFeatureEnabled("harvest_crops", crops))
    assert(w:SetFeatureEnabled("pick_plants", plants))
    assert(w:SetFeatureEnabled("hammer_giants", hammer))
    local crop, resource, fruit = H.farm_crop(1), H.plant(2), H.giant()
    local legacy = H.entity("legacy_crop", 3)
    legacy.components.crop = { matured = true, product_prefab = "carrot" }
    assert((Targets.Kind(w, crop) == "pick") == crops)
    assert((Targets.Kind(w, legacy) == "harvest") == crops)
    assert((Targets.Kind(w, resource) == "pick") == plants)
    assert((Targets.Kind(w, fruit) == "hammer") == hammer)
    local dropped = H.item("twigs", 1)
    assert(Targets.Kind(w, dropped) == "pickup")
    local action = w:GetNextAction()
    assert(action ~= nil)
    if hammer then assert(action.target == fruit)
    elseif crops then assert(action.target == crop)
    else assert(action.target == dropped) end
    assert(w.harvest_enabled == (crops or plants or hammer))
    for name, value in pairs({ harvest_crops = crops, pick_plants = plants, hammer_giants = hammer }) do
        assert(Features.GetPreference(w.inst, name) == value)
    end
end

function scenarios.feature_changes_cancel_only_own_work()
    for index, name in ipairs({ "harvest_crops", "pick_plants", "hammer_giants", "custom" }) do
        for _, direct in ipairs({ false, true }) do
            local x = index * 100 + (direct and 30 or 0)
            local w = H.worker(x)
            H.chest(x + 3)
            local target = name == "harvest_crops" and H.farm_crop(x + 1)
                or name == "pick_plants" and H.plant(x + 1)
                or name == "hammer_giants" and H.giant() or H.entity("custom", x + 1)
            target.x = x + 1
            if name == "custom" then
                name = "hammer_giants"
                API.RegisterAdapter("independent_feature", {
                    feature = name,
                    match = function(_, t) return t == target end,
                    action = function() return ACTIONS.HARVEST end,
                    product = function() return "cutgrass", 1 end,
                })
            end
            local action = w:GetNextAction()
            assert(action ~= nil and action.target == target and w.pending.feature == name)
            local state = H.enter(w, action, name == "hammer_giants" and "hammer" or "pick")
            local failures = 0
            action:AddFailAction(function() failures = failures + 1 end)
            local other = name == "pick_plants" and "hammer_giants" or "pick_plants"
            assert(w:SetFeatureEnabled(other, false))
            assert(w.pending.action == action and w:ValidateAction(action))
            w.farm_count = 2
            if direct then
                w.feature_enabled[name] = false
                w.inst.sg.timeinstate = .7
                state.onupdate(w.inst)
            else
                assert(w:SetFeatureEnabled(name, false))
            end
            assert(w.pending == nil and failures == 1 and w.inst.mutations == nil)
            assert(w.cooldowns[target] == nil and w.farm_count == 2)
            action:Succeed()
            assert(w.farm_count == 2 and target.harvests == nil)
        end
    end
end

function scenarios.feature_preferences_save_migrate_and_resume()
    local w = H.setup()
    H.farm_crop(1)
    local resource = H.plant(2)
    w.farm_count, w.farm_draining = 3, true
    w:SetFeatureEnabled("harvest_crops", false)
    w:SetFeatureEnabled("hammer_giants", false)
    assert(w:GetNextAction().target == resource, "Paused farm batch must not block independent plant work")
    w:Cancel(true)
    w.feature_enabled.absent_extension = false
    local data = w:OnSave()
    data.feature_enabled.pick_plants = false
    assert(w:GetFeatureEnabled("pick_plants"), "Save data must not alias live preferences")
    local saved = w:OnSave()
    local restored = H.worker(100)
    restored:OnLoad(saved)
    assert(not restored:GetFeatureEnabled("harvest_crops") and restored:GetFeatureEnabled("pick_plants"))
    assert(not restored:GetFeatureEnabled("hammer_giants") and restored.farm_count == 3 and restored.farm_draining)
    assert(restored:OnSave().feature_enabled.absent_extension == false)
    restored:OnPickup(nil)
    restored:OnDropped()
    assert(not restored:GetFeatureEnabled("harvest_crops") and restored:GetFeatureEnabled("pick_plants"))
    for _, legacy in ipairs({ { enabled = false }, { enabled = true, harvest_enabled = false },
        { enabled = false, harvest_enabled = true }, { enabled = true, harvest_enabled = true } }) do
        local old = H.worker(200)
        old:OnLoad(legacy)
        local expected = legacy.harvest_enabled == true or legacy.harvest_enabled == nil and legacy.enabled
        for _, name in ipairs(API.GetFeatureNames()) do assert(old:GetFeatureEnabled(name) == expected) end
        assert(old.enabled == (legacy.harvest_enabled == nil or legacy.enabled))
    end
    w:SetHarvestEnabled(false)
    w:SetFeatureEnabled("harvest_crops", true)
    assert(w:IsFeatureEnabled("harvest_crops") and not w:IsFeatureEnabled("pick_plants"))
    assert(not w:SetFeatureEnabled("unknown", true) and not w:SetFeatureEnabled("pick_plants", 1))
end

function scenarios.feature_extensions_and_adapter_gating()
    API.RegisterFeature("water_plants", { label = "扩展照料", default = false, order = 40 })
    local w = H.setup()
    local target = H.entity("extension_plant", 1)
    local matches = 0
    API.RegisterAdapter("extension_plant", {
        feature = "water_plants",
        match = function(_, t) matches = matches + 1 return t == target end,
        action = function() return ACTIONS.HARVEST end,
        product = function() return "cutgrass", 1 end,
    })
    assert(Targets.Kind(w, target) == nil and matches == 0)
    w:SetHarvestEnabled(false)
    assert(w:SetFeatureEnabled("water_plants", true))
    local action = w:GetNextAction()
    assert(action ~= nil and action.target == target and w.pending.feature == "water_plants")
    w:SetFeatureEnabled("pick_plants", false)
    assert(w.pending.action == action)
    w:SetFeatureEnabled("water_plants", false)
    assert(w.pending == nil and w.cooldowns[target] == nil)
    local client = H.entity("automatic_collector_mk2", 0, { "automatic_collector" })
    client._ac_features:set(w.inst._ac_features:value())
    assert(not Features.GetPreference(client, "water_plants"))
end

local function farm_extension_worker()
    API.RegisterFeature("farm_extension", { label = "扩展作物", default = false, order = 40 })
    API.RegisterAdapter("farm_extension", {
        feature = "farm_extension",
        match = function(_, target)
            return target:HasTag("farm_extension_target") and target.components.pickable:CanBePicked()
        end,
        action = function() return ACTIONS.PICK end,
        product = function() error("Farm adapters must not predict harvest products") end,
    })
    local w = H.setup()
    w:SetHarvestEnabled(false)
    assert(w:SetFeatureEnabled("farm_extension", true))
    return w
end

local function farm_extension_target(x, marker)
    local target = H.plant(x)
    target:AddTag("farm_extension_target")
    if marker == "farm_plant" or marker == "medal_fruit_tree" then target:AddTag(marker)
    else target.components[marker] = {} end
    return target
end

function scenarios.feature_farm_adapters_schedule_and_drain()
    local w = farm_extension_worker()
    local targets = {}
    for index, marker in ipairs({ "farm_plant", "crop", "perennialcrop", "perennialcrop2", "medal_fruit_tree", "farm_plant" }) do
        targets[index] = farm_extension_target(index / 10, marker)
    end
    for index = 1, 5 do
        local action = w:GetNextAction()
        assert(action ~= nil and action.target == targets[index], "An enabled farm adapter must run with built-in crops disabled")
        assert(w.pending.feature == "farm_extension" and w.pending.farm)
        H.execute(w, action)
    end
    assert(w.farm_count == 5 and w.farm_draining and targets[6].harvests == nil)
    local stored = false
    for _ = 1, 12 do
        local action = w:GetNextAction()
        assert(action ~= nil)
        if action.target == targets[6] then
            assert(stored, "The sixth adapted crop must wait for batch delivery")
            H.execute(w, action)
            break
        end
        assert(w.pending.kind == "pickup" or w.pending.kind == "store")
        if w.pending.kind == "store" then stored = true end
        H.execute(w, action)
    end
    assert(targets[6].harvests == 1 and w.farm_count == 1 and not w.farm_draining)
    w:SetFeatureEnabled("farm_extension", false)
    targets[6].components.pickable.mature = true
    assert(Targets.Kind(w, targets[6]) == nil)
end

function scenarios.feature_farm_adapter_batch_save_pause_resume()
    local w = farm_extension_worker()
    local target = farm_extension_target(.2, "farm_plant")
    local action = w:GetNextAction()
    assert(action ~= nil and action.target == target, "An independently enabled farm adapter must be scheduled")
    H.execute(w, action)
    assert(w.farm_count == 1 and not w.farm_draining)
    w:SetFeatureEnabled("farm_extension", false)
    w:SetFeatureEnabled("pick_plants", true)
    action = w:GetNextAction()
    assert(action ~= nil and w.pending.kind == "pickup" and w.farm_count == 1 and not w.farm_draining)
    w:Cancel(true)
    local data = w:OnSave()
    data.farm_features.farm_extension = false
    assert(w.farm_features.farm_extension, "Saved batch features must not alias live state")
    data = w:OnSave()
    data.farm_features.absent_extension = true
    data.farm_features["invalid-name"] = true
    local restored = H.worker()
    restored:OnLoad(data)
    assert(restored.farm_features.farm_extension and restored:OnSave().farm_features.absent_extension)
    assert(restored.farm_features["invalid-name"] == nil)
    action = restored:GetNextAction()
    assert(action ~= nil and restored.pending.kind == "pickup" and restored.farm_count == 1 and not restored.farm_draining)
    restored:Cancel(true)
    restored:SetFeatureEnabled("farm_extension", true)
    action = restored:GetNextAction()
    assert(action ~= nil and restored.pending.kind == "pickup" and restored.farm_draining,
        "An enabled adapter must finish a short batch even after its last target becomes immature")
    H.execute(restored, action)
    action = restored:GetNextAction()
    assert(action ~= nil and restored.pending.kind == "store")
    H.execute(restored, action)
    restored:GetNextAction()
    assert(restored.farm_count == 0 and not restored.farm_draining and next(restored.farm_features) == nil)
    local legacy = H.worker(100)
    legacy:OnLoad({ enabled = true, harvest_enabled = false, farm_count = 3, farm_draining = true })
    assert(legacy.farm_features.harvest_crops and legacy.farm_count == 3 and legacy.farm_draining)
    restored.farm_features.farm_extension = true
    restored:OnPickup(nil)
    restored:OnDropped()
    assert(next(restored.farm_features) == nil)
end

function scenarios.feature_farm_adapter_resumes_frozen_drain()
    local w = farm_extension_worker()
    w.farm_count, w.farm_draining = 5, true
    w.farm_features.harvest_crops = true
    local target = farm_extension_target(.2, "crop")
    local drop = H.item("cutgrass", .1, nil, 3)
    local action = w:GetNextAction()
    assert(action ~= nil and action.target == drop and w.farm_count == 5 and w.farm_draining)
    H.execute(w, action)
    action = w:GetNextAction()
    assert(action ~= nil and w.pending.kind == "store")
    H.execute(w, action)
    action = w:GetNextAction()
    assert(action ~= nil and action.target == target and w.pending.feature == "farm_extension",
        "A newly enabled farm adapter must resume a batch paused by another feature")
    assert(w.farm_count == 0 and not w.farm_draining)
    H.execute(w, action)
    assert(target.harvests == 1 and w.farm_count == 1 and w.farm_features.farm_extension)
end

local function control_session(config)
    local callbacks = H.register_modmain(config)
    local w = H.setup()
    local player = H.entity("wilson", 0, { "player" })
    player.userid = "test_player"
    player.components.inventory = H.inventory(player)
    player.replica = { inventory = player.components.inventory }
    return callbacks, w, player
end

function scenarios.control_panel_rpc_validation_and_multiple_players()
    local callbacks, w, player = control_session()
    local set = callbacks["SERVER_RPC:SetFeature"]
    assert(not set(player, w.inst, "harvest_crops", false))
    assert(ACTIONS.AC_CONTROL_PANEL.fn({ doer = player, target = w.inst }))
    assert(w:GetFeatureEnabled("harvest_crops"), "Opening must not toggle collection")
    assert(not set(player, w.inst, "unknown", true) and not set(player, w.inst, "pick_plants", "false"))
    assert(not set(player, 123, "pick_plants", true) and not set(nil, w.inst, "pick_plants", true))
    -- Invalid targets revoke that sender's session; reopen at the car.
    assert(Controls.BeginSession(player, w.inst))
    local other = H.entity("wilson", 1, { "player" })
    other.userid = "other_player"
    assert(not set(other, w.inst, "harvest_crops", false))
    assert(Controls.BeginSession(other, w.inst))
    assert(set(other, w.inst, "harvest_crops", false))
    assert(not w:IsFeatureEnabled("harvest_crops") and w:IsFeatureEnabled("pick_plants"))
    assert(set(player, w.inst, "hammer_giants", false))
    assert(w:IsFeatureEnabled("pick_plants"))
    local pickup = H.item("twigs", 1)
    local action = w:GetNextAction()
    assert(action.target == pickup)
    assert(set(player, w.inst, "pick_plants", false) and w.pending.action == action)
    H.execute(w, action)
    action = w:GetNextAction()
    local state = H.enter(w, action, "store")
    w.inst.sg.timeinstate = .2 state.onupdate(w.inst)
    local receiver = action.target.components.container
    assert(receiver:IsOpenedBy(w.inst))
    assert(set(player, w.inst, "harvest_crops", true) and receiver:IsOpenedBy(w.inst))
    state.onexit(w.inst)
    assert(not receiver:IsOpenedBy(w.inst))
    callbacks["SERVER_RPC:ClosePanel"](player, w.inst)
    assert(not set(player, w.inst, "harvest_crops", false))
    assert(Controls.BeginSession(player, w.inst))
    player.x = Controls.RANGE + 1
    assert(not set(player, w.inst, "harvest_crops", false))
    player.x = 0
    assert(not set(player, w.inst, "harvest_crops", false))
    assert(Controls.BeginSession(player, w.inst))
    w.inst:AddTag("INLIMBO")
    assert(not set(player, w.inst, "harvest_crops", false))
end

function scenarios.control_panel_respects_configuration_and_lifecycle()
    local callbacks, w, player = control_session({ pick_plants = false, hammer_giants = false })
    assert(Controls.BeginSession(player, w.inst))
    for _, name in ipairs(API.GetFeatureNames()) do
        assert(not callbacks["SERVER_RPC:SetFeature"](player, w.inst, name, true))
        assert(not w:IsFeatureEnabled(name))
    end
    assert(callbacks["SERVER_RPC:SetFeature"](player, w.inst, "harvest_crops", false))
    for _, condition in ipairs({ "playerghost", "corpse", "platform", "held", "fire", "base", "dead" }) do
        local _, worker, doer = control_session()
        if condition == "platform" then doer.platform = H.entity("boat")
        elseif condition == "held" then worker.inst.held = true
        elseif condition == "fire" then worker.inst:AddTag("fire")
        elseif condition == "base" then worker.inst._ac_mk2:set(false)
        elseif condition == "dead" then doer.components.health = { IsDead = function() return true end }
        else doer:AddTag(condition) end
        assert(not Controls.BeginSession(doer, worker.inst))
    end
    player.x = 5
    assert(not Controls.BeginSession(player, w.inst), "Opening requires native interaction proximity")
end

-- Widget contract fixture: no renderer or running game. The real panel executes
-- against the public Screen/Text/template methods and simulated RPC replication.
local function widget_runtime()
    local Widget = Class(function(self, name) self.name, self.children = name, {} end)
    function Widget:AddChild(child) table.insert(self.children, child) return child end
    for _, name in ipairs({ "SetPosition", "SetScale", "SetRegionSize", "SetHAlign" }) do
        Widget[name] = function() end
    end
    function Widget:Hide() self.hidden = true end
    function Widget:Show() self.hidden = false end
    function Widget:Enable() self.disabled = false end
    function Widget:Disable() self.disabled = true end
    function Widget:SetText(value) self.text = value end
    function Widget:SetString(value) self.text = value end
    function Widget:SetFocus() self.focused = true end
    function Widget:SetFocusChangeDir(direction, value)
        self.focus = self.focus or {} self.focus[direction] = value
    end
    function Widget:OnControl() return false end
    function Widget:OnDestroy() self.killed = true end
    local Text = Class(Widget, function(self, font, size, text)
        Widget._ctor(self, "Text") self.text = text
    end)
    package.loaded["widgets/screen"] = Widget
    package.loaded["widgets/text"] = Text
    package.loaded["widgets/redux/templates"] = {
        BackgroundTint = function() return Widget("Tint") end,
        ScreenRoot = function() return Widget("Root") end,
        CurlyWindow = function() return Widget("Dialog") end,
        StandardButton = function(fn, text)
            local button = Widget("Button") button.onclick, button.text = fn, text return button
        end,
    }
    CHATFONT, ANCHOR_MIDDLE, MOVE_UP, MOVE_DOWN, CONTROL_CANCEL, CONTROL_PAUSE = "font", 0, 1, 2, 3, 4
    TheNet = { IsDedicated = function() return false end }
    TheFrontEnd = {
        PushScreen = function(self, screen) self.screen = screen end,
        PopScreen = function(self, screen)
            assert(self.screen == screen) self.screen = nil screen:OnDestroy()
        end,
    }
end

function scenarios.control_panel_client_sync_pagination_and_close()
    API.RegisterFeature("extension_feature", { label = "扩展功能", default = false, order = 40 })
    local callbacks, w, player = control_session()
    widget_runtime()
    ThePlayer = player
    local client = H.entity("automatic_collector_mk2", 0, { "automatic_collector" })
    client._ac_mk2:set(true)
    client._ac_features:set(w.inst._ac_features:value())
    local requests = {}
    SendModRPCToServer = function(id, target, name, value, request_id)
        table.insert(requests, { id = id, target = target, name = name, value = value, request_id = request_id })
    end
    assert(Controls.BeginSession(player, w.inst))
    callbacks["CLIENT_RPC:OpenPanel"](client)
    local panel = Controls.screen
    assert(panel ~= nil and next(client.components) == nil and panel.rows[1].button.text == "采集作物：开启")
    callbacks["CLIENT_RPC:OpenPanel"](client)
    assert(Controls.screen == panel)
    panel.rows[1].button.onclick()
    local request = requests[1]
    assert(request.name == "harvest_crops" and request.value == 0 and request.target == client)
    assert(not panel.rows[1].button.disabled and panel.rows[1].button.text == "采集作物：关闭")
    assert(w:GetFeatureEnabled("harvest_crops"), "UI feedback precedes the queued server request")
    assert(callbacks["SERVER_RPC:SetFeature"](player, w.inst, request.name, request.value, request.request_id))
    local result = callbacks.last_client_rpc
    -- The ACK can arrive before the entity net_string update. The display must
    -- keep the confirmed value instead of falling back to the old snapshot.
    callbacks["CLIENT_RPC:FeatureResult"](client, request.name, request.request_id, 1,
        w.inst._ac_features:value())
    panel:OnUpdate(.1)
    assert(result.id.name == "FeatureResult" and panel.rows[1].button.text == "采集作物：关闭")
    client._ac_features:set(w.inst._ac_features:value())
    panel:OnUpdate(.1)
    assert(panel.rows[1].button.text == "采集作物：关闭" and not panel.rows[1].button.disabled)
    w:SetFeatureEnabled("pick_plants", false)
    client._ac_features:set(w.inst._ac_features:value())
    panel:OnUpdate(.1)
    assert(panel.rows[2].button.text == "采集植物：关闭")
    panel:ChangePage(1)
    assert(panel.page == 2 and panel.rows[1].name == "extension_feature" and panel.rows[2].button.hidden)
    panel.rows[1].button.onclick()
    request = requests[2]
    assert(request.name == "extension_feature" and request.value == 1)
    assert(callbacks["SERVER_RPC:SetFeature"](player, w.inst, request.name, request.value, request.request_id))
    callbacks["CLIENT_RPC:FeatureResult"](client, request.name, request.request_id, 1,
        w.inst._ac_features:value())
    client._ac_features:set(w.inst._ac_features:value())
    panel:OnUpdate(.1)
    assert(panel.rows[1].button.text == "扩展功能：开启")
    panel:ChangePage(-1)
    TUNING.AUTOMATIC_COLLECTOR.pick_plants = false
    panel:OnUpdate(.1)
    assert(panel.rows[1].button.disabled and panel.rows[1].button.text == "采集作物：服务器已禁用")
    assert(panel.rows[2].button.disabled and not panel.rows[3].button.disabled)
    assert(panel:OnControl(CONTROL_CANCEL, false))
    assert(Controls.screen == nil and TheFrontEnd.screen == nil and panel.killed)
    assert(requests[#requests].id.name == "ClosePanel")
    callbacks["SERVER_RPC:ClosePanel"](player, w.inst)
    assert(not callbacks["SERVER_RPC:SetFeature"](player, w.inst, "hammer_giants", false))
    assert(Controls.BeginSession(player, w.inst))
    callbacks["CLIENT_RPC:OpenPanel"](client)
    panel = Controls.screen
    client:AddTag("INLIMBO") panel:OnUpdate(.1)
    assert(Controls.screen == nil and panel.killed)
    client.tags.INLIMBO = nil
    assert(Controls.BeginSession(player, w.inst))
    callbacks["CLIENT_RPC:OpenPanel"](client)
    player:AddTag("playerghost") Controls.screen:OnUpdate(.1)
    assert(Controls.screen == nil)
end

function scenarios.control_panel_numeric_false_and_rapid_clicks()
    local callbacks, w, player = control_session()
    widget_runtime()
    ThePlayer = player
    local client = H.entity("automatic_collector_mk2", 0, { "automatic_collector" })
    client._ac_mk2:set(true)
    client._ac_features:set(w.inst._ac_features:value())
    local requests = {}
    SendModRPCToServer = function(id, target, name, value, request_id)
        if id.name ~= "SetFeature" then return end
        assert(type(value) == "number" and (value == 0 or value == 1))
        table.insert(requests, { name = name, value = value, request_id = request_id })
    end
    assert(Controls.BeginSession(player, w.inst))
    callbacks["CLIENT_RPC:OpenPanel"](client)
    local panel = Controls.screen
    local button = panel.rows[2].button
    button.onclick() assert(button.text == "采集植物：关闭" and not button.disabled)
    button.onclick() assert(button.text == "采集植物：开启" and not button.disabled)
    button.onclick() assert(button.text == "采集植物：关闭" and not button.disabled)
    assert(#requests == 3 and requests[1].value == 0 and requests[2].value == 1 and requests[3].value == 0)
    local replies = {}
    for index, request in ipairs(requests) do
        assert(callbacks["SERVER_RPC:SetFeature"](player, w.inst, request.name, request.value, request.request_id))
        replies[index] = w.inst._ac_features:value()
    end
    assert(not w:IsFeatureEnabled("pick_plants"))
    -- Reordered ACKs and stale net snapshots cannot undo the newest click.
    for _, index in ipairs({ 2, 1, 3 }) do
        callbacks["CLIENT_RPC:FeatureResult"](client, requests[index].name, requests[index].request_id, 1, replies[index])
        panel:OnUpdate(.1)
        assert(button.text == "采集植物：关闭")
    end
    client._ac_features:set(replies[2]) panel:OnUpdate(.1)
    assert(button.text == "采集植物：关闭")
    client._ac_features:set(replies[3]) panel:OnUpdate(.1)
    assert(button.text == "采集植物：关闭")
    w:SetFeatureEnabled("pick_plants", true)
    client._ac_features:set(w.inst._ac_features:value()) panel:OnUpdate(.1)
    assert(button.text == "采集植物：开启", "A newer change by another player must still appear")
    panel:Close()
end

function scenarios.control_panel_rejection_and_no_reply()
    local callbacks, w, player = control_session()
    widget_runtime()
    ThePlayer = player
    local client = H.entity("automatic_collector_mk2", 0, { "automatic_collector" })
    client._ac_mk2:set(true)
    client._ac_features:set(w.inst._ac_features:value())
    SendModRPCToServer = function() end
    assert(Controls.BeginSession(player, w.inst))
    callbacks["CLIENT_RPC:OpenPanel"](client)
    local panel = Controls.screen
    panel.rows[1].button.onclick()
    local request_id = panel.pending.harvest_crops.id
    Controls.EndSession(player, w.inst)
    assert(not callbacks["SERVER_RPC:SetFeature"](player, w.inst, "harvest_crops", 0, request_id))
    callbacks["CLIENT_RPC:FeatureResult"](client, "harvest_crops", request_id, 0, w.inst._ac_features:value())
    assert(panel.rows[1].button.text == "采集作物：开启" and panel.summary.text:find("设置未生效"))
    assert(w:IsFeatureEnabled("harvest_crops"))
    panel.rows[2].button.onclick()
    local static_time = GetStaticTime
    local deadline = static_time() + 4
    GetStaticTime = function() return deadline end
    panel:OnUpdate(.1)
    assert(panel.rows[2].button.text == "采集植物：开启" and panel.summary.text:find("未收到设置结果"))
    assert(not panel.rows[2].button.disabled)
    GetStaticTime = static_time
    panel:Close()
end

function scenarios.control_panel_reopen_ignores_old_results()
    local callbacks, w, player = control_session()
    widget_runtime()
    ThePlayer = player
    local client = H.entity("automatic_collector_mk2", 0, { "automatic_collector" })
    client._ac_mk2:set(true)
    local requests = {}
    SendModRPCToServer = function(id, _, name, value, request_id)
        if id.name == "SetFeature" then
            table.insert(requests, { name = name, value = value, request_id = request_id })
        end
    end
    for _, accepted in ipairs({ 1, 0 }) do
        w:SetFeatureEnabled("harvest_crops", false)
        client._ac_features:set(w.inst._ac_features:value())
        assert(Controls.BeginSession(player, w.inst))
        callbacks["CLIENT_RPC:OpenPanel"](client)
        local old_panel = Controls.screen
        old_panel.rows[1].button.onclick()
        local old_request = requests[#requests]
        assert(old_request.value == 1)
        if accepted == 1 then
            assert(callbacks["SERVER_RPC:SetFeature"](player, w.inst, old_request.name, old_request.value, old_request.request_id))
        else
            -- Another player can enable the feature while this request is rejected.
            w:SetFeatureEnabled("harvest_crops", true)
        end
        local old_snapshot = w.inst._ac_features:value()
        client._ac_features:set(old_snapshot)
        old_panel:Close()
        callbacks["SERVER_RPC:ClosePanel"](player, w.inst)
        assert(Controls.BeginSession(player, w.inst))
        callbacks["CLIENT_RPC:OpenPanel"](client)
        local panel = Controls.screen
        panel.rows[1].button.onclick()
        local request = requests[#requests]
        assert(request.value == 0)
        callbacks["CLIENT_RPC:FeatureResult"](client, old_request.name, old_request.request_id, accepted, old_snapshot)
        assert(panel.pending.harvest_crops ~= nil and panel.pending.harvest_crops.id == request.request_id,
            "A delayed response from the closed panel must not clear the new request")
        assert(request.request_id > old_request.request_id and panel.rows[1].button.text == "采集作物：关闭")
        assert(not panel.summary.text:find("设置未生效"))
        assert(callbacks["SERVER_RPC:SetFeature"](player, w.inst, request.name, request.value, request.request_id))
        callbacks["CLIENT_RPC:FeatureResult"](client, request.name, request.request_id, 1, w.inst._ac_features:value())
        assert(panel.pending.harvest_crops == nil and panel.rows[1].button.text == "采集作物：关闭")
        panel:Close()
        callbacks["SERVER_RPC:ClosePanel"](player, w.inst)
    end
end
