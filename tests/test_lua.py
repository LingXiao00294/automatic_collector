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
        "pickup_arrives_over_item",
    ],
)
def test_scenario(lua, scenario):
    lua.globals().scenarios[scenario]()
