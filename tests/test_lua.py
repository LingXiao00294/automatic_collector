"""Execute the shipped Lua in LuaJIT (the same Lua 5.1 dialect used by DST)."""

import importlib
from pathlib import Path

import pytest

LuaRuntime = importlib.import_module("lupa.luajit21").LuaRuntime

ROOT = Path(__file__).resolve().parents[1]


@pytest.fixture
def lua():
    runtime = LuaRuntime(unpack_returned_tuples=True)
    runtime.execute(f'package.path = "{ROOT.as_posix()}/scripts/?.lua;" .. package.path')
    runtime.execute((ROOT / "tests/harness.lua").read_text(encoding="utf-8"))
    return runtime


def test_lua_51_syntax():
    runtime = LuaRuntime()
    compile_lua = runtime.eval("function(source, name) return loadstring(source, name) end")
    files = [ROOT / "modmain.lua", ROOT / "modinfo.lua", *ROOT.glob("scripts/**/*.lua")]
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
        "scan_cost",
        "impact_once",
        "impact_cancelled",
        "impact_speed",
        "native_component_contract",
        "merge_then_deliver",
        "full_stack_delivers",
        "partial_stack_pickup",
        "destination_limits_merge",
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
    ],
)
def test_scenario(lua, scenario):
    lua.globals().scenarios[scenario]()
