"""Execute the shipped Lua in LuaJIT (the same Lua 5.1 dialect used by DST)."""

import importlib
import os
from pathlib import Path
from zipfile import ZipFile

import pytest

LuaRuntime = importlib.import_module("lupa.luajit21").LuaRuntime

ROOT = Path(__file__).resolve().parents[1]


@pytest.fixture
def lua():
    runtime = LuaRuntime(unpack_returned_tuples=True)
    runtime.execute(f'package.path = "{ROOT.as_posix()}/scripts/?.lua;" .. package.path')
    runtime.execute((ROOT / "tests/harness.lua").read_text(encoding="utf-8"))
    runtime.globals().TEST_ROOT = ROOT.as_posix()
    runtime.execute((ROOT / "tests/harness_upgrade.lua").read_text(encoding="utf-8"))
    runtime.execute((ROOT / "tests/harness_sounds.lua").read_text(encoding="utf-8"))
    return runtime


def test_lua_51_syntax():
    runtime = LuaRuntime()
    compile_lua = runtime.eval("function(source, name) return loadstring(source, name) end")
    files = [
        ROOT / "modmain.lua",
        ROOT / "modinfo.lua",
        *ROOT.glob("scripts/**/*.lua"),
        ROOT / "tests/engine_smoke.lua",
    ]
    for path in files:
        result = compile_lua(path.read_text(encoding="utf-8"), str(path))
        assert not isinstance(result, tuple), f"{path}: {result}"


@pytest.mark.parametrize(
    "scenario",
    [
        "single_target",
        "cargo_collects_same_product",
        "matching_priority",
        "full_chest",
        "two_workers",
        "failed_path",
        "timeout",
        "pause",
        "target_removed",
        "target_held",
        "native_failure_before_watchdog",
        "native_failure_preserves_cargo",
        "native_failure_world_conditions",
        "native_failure_timeout_and_pause",
        "giant_displaced_drop_before_next_plant",
        "pickup_stolen_en_route",
        "pickup_removed_en_route",
        "pickup_stolen_preserves_carried_stack",
        "work_targets_change_en_route",
        "active_watchdog_fast_recovery",
        "watchdog_idle_and_lifecycle",
        "active_watchdog_keeps_valid_target",
        "active_watchdog_rechecks_work_and_capacity",
        "immature",
        "giant_harvest",
        "giant_hammer",
        "waxed_giant",
        "unsafe_items",
        "same_platform",
        "home_radius",
        "moving_boat",
        "save_load",
        "pickup_unloads",
        "unknown_upgrade",
        "upgrades",
        "adapter",
        "adapter_scans_do_not_sort_names",
        "adapter_order_overwrite_and_late_registration",
        "sound_walk_continuous_and_cancelled",
        "sound_work_contact_and_profiles",
        "sound_signals_skip_held_and_sleeping",
        "scan_cost",
        "impact_once",
        "impact_cancelled",
        "impact_speed",
        "native_component_contract",
        "merge_then_deliver",
        "full_stack_delivers",
        "partial_stack_pickup",
        "destination_limits_merge",
        "delivery_capacity_stops_when_sufficient",
        "delivery_capacity_finds_best_partial_receiver",
        "delivery_capacity_respects_filters_and_cooldowns",
        "capacity_changes_at_impact",
        "skin_and_mod_merge_rules",
        "no_active_overflow",
        "future_carry_slots",
        "claimed_merge_target",
        "work_faces_target",
        "batch_plants",
        "pickup_and_pick_batch",
        "harvest_yield_capacity",
        "harvest_capacity_at_impact",
        "batch_crops_with_seeds",
        "batch_legacy_crops",
        "unknown_harvest_delivers_first",
        "batch_adapter",
        "harvest_uses_ram_animation",
        "pickup_uses_winona_arrival_distance",
        "two_workers_pickup_overlapping_drops",
        "store_open_window",
        "two_workers_store_in_open_chest",
        "two_workers_store_rechecks_remaining_capacity",
        "store_open_speed",
        "store_open_interrupted",
        "store_open_cancelled_after_success",
        "store_open_failed_preflight",
        "store_direct_closes",
        "store_open_failed_action",
        "giant_matching_primary_sample",
        "giant_matching_seed_sample",
        "giant_matching_split_destinations",
        "giant_matching_wrong_or_full_sample",
        "giant_matching_open_container",
        "delivery_full_en_route",
        "delivery_full_drop_recovers",
        "delivery_drop_one_group",
        "delivery_drop_active_cargo",
        "delivery_full_at_contact",
        "cancel_notifies_native_action",
        "giant_batch_prepare_all",
        "giant_batch_mixed_groups",
        "giant_batch_stack_limit",
        "giant_batch_mature_plants",
        "legion_soil_matching",
        "legion_soil_yield_changes",
        "legion_soil_giant_priority",
        "legion_cluster_matching",
        "legion_cluster_custom_yield",
        "legion_secondary_yields",
        "legion_monstrain_secondary_sample",
        "medal_tree_random_yield",
        "mod_plants_contact_revalidation",
        "special_soil_item_preserved",
        "adapter_matching_sample",
        "insight_optional_registration",
        "insight_worker_information",
        "insight_home_range_lifecycle",
        "insight_boat_save_range",
        "farm_five_then_drain_resume",
        "farm_pinecone_hammer_priority",
        "farm_large_yield_without_preflight",
        "farm_skips_unavailable_cargo",
        "farm_unmatched_and_filtered_cargo",
        "farm_gift_fruit_mixed_drops_resume",
        "farm_restored_drain_without_receiver",
        "farm_delivery_loses_receiver_resumes",
        "farm_success_count_and_contact_safety",
        "farm_partial_failure_preserves_products",
        "farm_pause_save_restore_and_relocate",
        "scavenger_only_pickup_and_transport",
        "harvest_toggle_cancels_gather_work",
        "harvest_toggle_keeps_pickup_and_store",
        "harvest_toggle_preserves_farm_batch",
        "harvest_toggle_contact_revalidation",
        "harvest_toggle_respects_config",
        "harvest_toggle_upgrade_and_load_order",
        "navigation_configuration",
        "upgrade_single_and_stack",
        "upgrade_two_players_and_reentry",
        "upgrade_invalid_or_interrupted",
        "upgrade_apply_rollback",
        "upgrade_radius_targets_and_delivery",
        "upgrade_radius_config_save_and_display",
        "upgrade_consumption_rollback",
        "upgrade_detach_failure_and_cancel_recheck",
        "upgrade_removed_during_apply_returns_kit",
        "upgrade_actual_work_contacts_once",
        "upgrade_walk_cargo_pause_boat",
        "upgrade_contact_before_and_after",
        "upgrade_store_closes_only_own_opener",
        "upgrade_load_idempotent_and_relocate",
        "upgrade_work_timing_and_walk_reset",
        "upgrade_recipe_and_action_selection",
        "collector_distinct_prefabs",
        "upgrade_prefab_client_and_host",
        "upgrade_kit_preserves_stack_mod_settings",
        "collector_mouse_pickup",
    ],
)
def test_scenario(lua, scenario):
    lua.globals().scenarios[scenario]()


def test_native_collector_crafting_filters(lua):
    game_root = Path(
        os.environ.get("DST_GAME_ROOT", "D:/Programs/Steam/steamapps/common/Don't Starve Together")
    )
    bundle = game_root / "data/databundles/scripts.zip"
    if not bundle.is_file():
        pytest.skip("Native crafting filter check requires installed DST scripts")
    with ZipFile(bundle) as scripts:
        filter_source = scripts.read("scripts/recipes_filter.lua").decode("utf-8")
        modutil_source = scripts.read("scripts/modutil.lua").decode("utf-8")
    lua.execute("""
        table.invert = function(values)
            local result = {}
            for index, value in ipairs(values) do result[value] = index end
            return result
        end
        env = {}
        NativeCraftingRegistration = env
        initprint = function() end
        package.loaded.recipe = true
        Recipe2 = function(name, ingredients, tech, config)
            return { name = name, ingredients = ingredients, tech = tech, config = config,
                SetModRPCID = function() end }
        end
    """)
    lua.execute(filter_source, name="@native/recipes_filter.lua")
    for method in ("AddRecipeToFilter", "AddRecipe2"):
        start = modutil_source.index(f"env.{method} = function(")
        end = modutil_source.index("\n\tend", start) + len("\n\tend")
        lua.execute(modutil_source[start:end], name=f"@native/modutil/{method}.lua")
    lua.execute("""
        upgrade_contract.register_modmain()
        for _, recipe in ipairs({ "automatic_collector", "ac_upgrade_kit" }) do
            for _, filter_name in ipairs({ "TOOLS", "MODS" }) do
                local filter = CRAFTING_FILTERS[filter_name]
                local index = filter.default_sort_values[recipe]
                assert(index ~= nil and filter.recipes[index] == recipe)
            end
            for _, filter_name in ipairs({ "PROTOTYPERS", "STRUCTURES" }) do
                assert(CRAFTING_FILTERS[filter_name].default_sort_values[recipe] == nil)
            end
        end
    """)


@pytest.fixture
def native_collector(lua):
    game_root = Path(
        os.environ.get("DST_GAME_ROOT", "D:/Programs/Steam/steamapps/common/Don't Starve Together")
    )
    bundle = game_root / "data/databundles/scripts.zip"
    if not bundle.is_file():
        pytest.skip("Native prefab save/load contract check requires installed DST scripts")
    with ZipFile(bundle) as scripts:
        entity_source = (
            scripts.read("scripts/entityscript.lua").decode("utf-8").replace("\r\n", "\n")
        )
        spawn_source = (
            scripts.read("scripts/mainfunctions.lua").decode("utf-8").replace("\r\n", "\n")
        )
        replica_source = (
            scripts.read("scripts/entityreplica.lua").decode("utf-8").replace("\r\n", "\n")
        )
        console_source = (
            scripts.read("scripts/consolecommands.lua").decode("utf-8").replace("\r\n", "\n")
        )
        named_sources = {
            name: scripts.read(f"scripts/{name}.lua").decode("utf-8")
            for name in ("class", "components/named", "components/named_replica")
        }
    lua.execute("""
        EntityScript = {}
        IsTableEmpty = function(values) return next(values) == nil end
        isbadnumber = function(value)
            return value ~= value or value == math.huge or value == -math.huge
        end
    """)
    for method in (
        "SetPrefabName",
        "GetBasicDisplayName",
        "GetSaveRecord",
        "GetPersistData",
        "SetPersistData",
    ):
        start = entity_source.index(f"function EntityScript:{method}(")
        end = entity_source.index("\nend", start) + len("\nend")
        lua.execute(entity_source[start:end], name=f"@native/entityscript/{method}.lua")
    lua.globals().NativeEntityScript = lua.globals().EntityScript
    start = replica_source.index("function EntityScript:ReplicateEntity(")
    end = replica_source.index("\nend", start) + len("\nend")
    lua.execute(replica_source[start:end], name="@native/entityreplica/ReplicateEntity.lua")
    for function in ("SpawnPrefab", "SpawnPrefabFromSim"):
        start = spawn_source.index(f"function {function}(")
        end = spawn_source.index("\nend", start) + len("\nend")
        lua.execute(spawn_source[start:end], name=f"@native/mainfunctions/{function}.lua")
    lua.globals().NativeSpawnPrefab = lua.globals().SpawnPrefab
    start = console_source.index("function c_removeall(")
    end = console_source.index("\nend", start) + len("\nend")
    lua.execute(console_source[start:end], name="@native/consolecommands/c_removeall.lua")
    start = spawn_source.index("local function ResolveSaveRecordPosition(")
    save_start = spawn_source.index("function SpawnSaveRecord(", start)
    end = spawn_source.index("\nend", save_start) + len("\nend")
    lua.execute(spawn_source[start:end], name="@native/mainfunctions/SpawnSaveRecord.lua")
    lua.execute(named_sources["class"], name="@native/class.lua")
    lua.globals().NativeNamed = lua.execute(
        named_sources["components/named"], name="@native/components/named.lua"
    )
    lua.globals().NativeNamedReplica = lua.execute(
        named_sources["components/named_replica"], name="@native/components/named_replica.lua"
    )
    return lua


def test_native_collector_prefab_save_load(native_collector):
    native_collector.globals().scenarios.collector_prefab_native_save_load()


@pytest.mark.parametrize("prefab_name", ["automatic_collector", "automatic_collector_mk2"])
@pytest.mark.parametrize("initial_phase", ["before_replication", "after_replication"])
@pytest.mark.parametrize("advanced_value", [False, True], ids=["base", "mk2"])
def test_native_collector_rejoin(native_collector, prefab_name, initial_phase, advanced_value):
    native_collector.globals().scenarios.collector_native_rejoin(
        prefab_name, initial_phase, advanced_value
    )


@pytest.mark.parametrize("origin", ["legacy", "kit", "direct", "base"])
@pytest.mark.parametrize("initial_phase", ["before_replication", "after_replication"])
@pytest.mark.parametrize("harvest_enabled", [False, True], ids=["harvest_off", "harvest_on"])
def test_native_collector_pristine_reload(native_collector, origin, initial_phase, harvest_enabled):
    native_collector.globals().scenarios.collector_pristine_reload(
        origin, initial_phase, harvest_enabled
    )


@pytest.mark.parametrize("ismastersim", [False, True], ids=["client", "host"])
def test_native_collector_display_names(native_collector, ismastersim):
    native_collector.globals().scenarios.collector_native_display_names(ismastersim)


@pytest.mark.parametrize("ismastersim", [False, True])
def test_native_action_button_skips_collectors(lua, ismastersim):
    game_root = Path(
        os.environ.get("DST_GAME_ROOT", "D:/Programs/Steam/steamapps/common/Don't Starve Together")
    )
    bundle = game_root / "data/databundles/scripts.zip"
    if not bundle.is_file():
        pytest.skip("Optional native input contract check requires installed DST scripts")
    with ZipFile(bundle) as scripts:
        source = scripts.read("scripts/components/playercontroller.lua").decode("utf-8")
    pickup = source[
        source.index("local function GetPickupAction") : source.index(
            "function PlayerController:IsDoingOrWorking"
        )
    ]
    targets = source[
        source.index("local TARGET_EXCLUDE_TAGS =") : source.index(
            "function PlayerController:GetActionButtonAction"
        )
    ]
    action_button = source[
        source.index("function PlayerController:GetActionButtonAction") : source.index(
            "function PlayerController:DoActionButton"
        )
    ]
    lua.globals().INPUT_IS_MASTER = ismastersim
    lua.execute("""
        PlayerController = {}
        CONTROL_ACTION = 1
        EQUIPSLOTS = { HANDS = "hands" }
        TOOLACTIONS = {}
        CanEntitySeeTarget = function(_, target) return target ~= nil and target:IsValid() end
        TheSim.RegisterFindTags = function() return {} end
        FindEntity = function(inst, radius, filter, must, exclude)
            local x, y, z = inst.Transform:GetWorldPosition()
            for _, target in ipairs(TheSim:FindEntities(x, y, z, radius, must, exclude)) do
                if target ~= inst and (filter == nil or filter(target, inst)) then return target end
            end
        end
    """)
    lua.execute(pickup + targets + action_button)
    lua.execute("""
        local H = upgrade_contract
        function PlayerController:IsEnabled() return true, false end
        function PlayerController:IsBusy() return false end
        function PlayerController:IsDoingOrWorking() return false end
        function PlayerController:HasItemSlots() return true end
        for _, directwalking in ipairs({ false, true }) do
            for _, advanced in ipairs({ false, true }) do
                local x = (advanced and 100 or 0) + (directwalking and 20 or 0)
                local car = H.worker(x, advanced).inst
                car.entity = { IsVisible = function() return true end }
                car:AddTag("_inventoryitem")
                assert(car.components.inventoryitem.canbepickedup == false)
                car.replica = { inventoryitem = {
                    CanBePickedUp = function() return car.components.inventoryitem.canbepickedup end,
                } }
                local player = H.entity("wilson", x, { "player" })
                player.replica = { inventory = {
                    IsFloaterHeld = function() return false end,
                    IsHeavyLifting = function() return false end,
                    GetEquippedItem = function() return nil end,
                } }
                local controller = setmetatable({ inst = player, remote_controls = {},
                    ismastersim = INPUT_IS_MASTER, directwalking = directwalking },
                    { __index = PlayerController })
                -- The car is the first nearby candidate; normal drops must still be selected.
                local drop = H.item("twigs", x + 1)
                drop:AddTag("_inventoryitem")
                drop.entity = { IsVisible = function() return true end }
                drop.replica = { inventoryitem = { CanBePickedUp = function() return true end } }
                local action = controller:GetActionButtonAction()
                assert(action ~= nil and action.target == drop and action.action == ACTIONS.PICKUP)
                assert(controller:GetActionButtonAction(car) == nil,
                    "Action-button RPC must reject an explicitly requested car")
                drop.valid = false
                assert(controller:GetActionButtonAction() == nil,
                    "A lone car must never be selected by the action button")
            end
        end
    """)
