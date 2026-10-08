"""Run bounded navigation against terrain/collision fixtures and native locomotor methods."""

import importlib
import os
import re
from pathlib import Path
from zipfile import ZipFile

import pytest

ROOT = Path(__file__).resolve().parents[1]
SCENARIOS = [
    "navigation_river_outside_range",
    "navigation_river_inside_range",
    "navigation_statue_detour",
    "navigation_collision_masks",
    "navigation_narrow_offset_corridor",
    "navigation_narrow_wall_path_tiles",
    "navigation_narrow_closed_corridor",
    "navigation_winding_corridor_outside",
    "navigation_winding_corridor_inside",
    "navigation_winding_corridor_after_pickup",
    "navigation_winding_corridor_reopens",
    "navigation_winding_corridor_outside_range",
    "navigation_winding_corridor_shared_budget",
    "navigation_small_target_displacement",
    "navigation_terrain_narrow_elbow",
    "navigation_index_large_obstacle",
    "navigation_moonbase_walled_tile",
    "navigation_moonbase_shared_refinement",
    "navigation_chest_approach",
    "navigation_dynamic_obstacle",
    "navigation_stuck_recovery",
    "navigation_pickup_tolerance",
    "navigation_character_on_drop",
    "navigation_path_failure_retry_backoff",
    "navigation_home_detour",
    "navigation_boat_moves",
    "navigation_boat_stuck",
    "navigation_queued_boat_moves",
    "navigation_queued_platform_removed",
    "navigation_queued_obstacles_change",
    "navigation_cancel_and_retry",
    "navigation_overlapping_blocker_escape",
    "navigation_blocked_pickup_releases_claim",
    "navigation_outside_save_returns",
    "navigation_same_frame_corner",
    "navigation_three_blockers_stable_turns",
    "navigation_shore_pickup",
    "navigation_shore_pickup_already_near",
    "navigation_shore_pickup_tangent",
    "navigation_shore_overhang_pickup_delivery",
    "navigation_shore_overhang_approach_from_land",
    "navigation_shore_overhang_home",
    "navigation_shore_overhang_water_gap",
    "navigation_shore_overhang_inland_rejection",
    "navigation_shore_overhang_refinement",
    "navigation_shore_overhang_body_clearance",
    "navigation_shore_does_not_cross_water",
    "navigation_grid_arrival_point",
    "navigation_plain_waypoints",
    "navigation_trace_explains_cooldown",
    "navigation_shared_search_budget",
    "navigation_cancel_queued_search",
    "navigation_crowded_collectors",
    "navigation_delivery_waits_for_route",
    "navigation_waiting_delivery_loses_capacity",
    "navigation_home_retry_backoff",
    "navigation_queued_search_capacity_changes",
    "navigation_cancel_queued_refresh",
    "navigation_refresh_wait_not_stuck",
    "navigation_refresh_obstacles_change",
    "navigation_refresh_with_busy_search",
    "navigation_queued_refresh_platform_removed",
    "navigation_refresh_snapshot_expires",
    "navigation_refresh_arrival_waits",
    "navigation_refresh_movement_counts_for_stuck",
]


def native_bundle() -> Path:
    game_root = Path(
        os.environ.get("DST_GAME_ROOT", "D:/Programs/Steam/steamapps/common/Don't Starve Together")
    )
    bundle = game_root / "data/databundles/scripts.zip"
    if not bundle.is_file():
        pytest.skip("Native navigation contract check requires installed DST scripts")
    return bundle


def native_methods() -> str:
    bundle = native_bundle()
    with ZipFile(bundle) as archive:
        source = archive.read("scripts/components/locomotor.lua").decode("utf-8")
    prefix = source[
        source.index("local STATUS_CALCULATING") : source.index("local function onrunspeed")
    ]
    methods = []
    for name in (
        "GoToEntity",
        "GoToPoint",
        "SetBufferedAction",
        "Clear",
        "ResetPath",
        "KillPathSearch",
        "Stop",
        "OnUpdate",
        "SetMotorSpeed",
        "WalkForward",
        "PushAction",
        "StartUpdatingInternal",
        "StopUpdatingInternal",
        "StopMoving",
        "WantsToMoveForward",
        "WantsToRun",
    ):
        start = source.index(f"function LocoMotor:{name}(")
        boundary = re.search(r"\n(?:local )?function \w", source[start + 1 :])
        assert boundary is not None, f"Missing method boundary for {name}"
        methods.append(source[start : start + 1 + boundary.start()])
    return prefix + "\nlocal LocoMotor = {}\n" + "\n".join(methods) + "\nNAV_NATIVE = LocoMotor"


def native_brain_methods() -> str:
    modules = ("class", "behaviourtree", "brain", "behaviours/doaction", "behaviours/standstill")
    chunks = []
    with ZipFile(native_bundle()) as archive:
        for name in modules:
            source = archive.read(f"scripts/{name}.lua").decode("utf-8", errors="replace")
            chunks.append(f'package.preload["{name}"] = function(...)\n{source}\nend')
    chunks.extend(f'require("{name}")' for name in modules[:3])
    return "\n".join(chunks)


def native_dispatch_methods() -> str:
    chunks = [native_brain_methods()]
    modules = ("easing", "stategraph", "stategraphs/commonstates")
    with ZipFile(native_bundle()) as archive:
        for name in modules:
            source = archive.read(f"scripts/{name}.lua").decode("utf-8", errors="replace")
            chunks.append(f'package.preload["{name}"] = function(...)\n{source}\nend')
            chunks.append(f'package.loaded["{name}"] = nil\nrequire("{name}")')
        source = archive.read("scripts/entityscript.lua").decode("utf-8")
        chunks.append("local EntityScript = {}")
        for name in ("PushBufferedAction", "GetBufferedAction", "ClearBufferedAction"):
            start = source.index(f"function EntityScript:{name}(")
            boundary = re.search(r"\n(?:local )?function \w", source[start + 1 :])
            assert boundary is not None, f"Missing method boundary for {name}"
            chunks.append(source[start : start + 1 + boundary.start()])
        chunks.append("NAV_ENTITY = EntityScript")
    chunks.append('package.loaded["stategraphs/SGac_collector"] = nil')
    return "\n".join(chunks)


@pytest.fixture(params=["fixture", "native"])
def navigation(request):
    runtime = importlib.import_module("lupa.luajit21").LuaRuntime(unpack_returned_tuples=True)
    runtime.execute(f'package.path = "{ROOT.as_posix()}/scripts/?.lua;" .. package.path')
    runtime.execute((ROOT / "tests/harness.lua").read_text(encoding="utf-8"))
    if request.param == "native":
        runtime.execute(native_methods())
    runtime.execute((ROOT / "tests/harness_navigation.lua").read_text(encoding="utf-8"))
    return runtime


@pytest.mark.parametrize("runtime_module", ["lupa.lua51", "lupa.luajit21"])
def test_prefab_and_navigation_with_engine_global_bit(runtime_module):
    runtime = importlib.import_module(runtime_module).LuaRuntime(unpack_returned_tuples=True)
    runtime.execute(f'package.path = "{ROOT.as_posix()}/scripts/?.lua;" .. package.path')
    # DST supplies bit globally but does not provide a require("bit") module.
    # LuaJIT's bundled module otherwise hides this prefab registration failure.
    runtime.globals().bit = runtime.table(
        band=lambda left, right: left & right,
        bor=lambda left, right: left | right,
    )
    runtime.execute("""
        package.loaded.bit, package.preload.bit = nil, nil
        local original_require = require
        require = function(name)
            if name == "bit" then error("module 'bit' not found") end
            return original_require(name)
        end
    """)
    runtime.globals().TEST_ROOT = ROOT.as_posix()
    for name in ("harness.lua", "harness_upgrade.lua"):
        runtime.execute((ROOT / "tests" / name).read_text(encoding="utf-8"))
    runtime.globals().scenarios.upgrade_prefab_client_and_host()
    runtime.execute((ROOT / "tests/harness_navigation.lua").read_text(encoding="utf-8"))
    runtime.globals().scenarios.navigation_collision_masks()


@pytest.mark.parametrize("scenario", SCENARIOS)
def test_navigation_scenario(navigation, scenario):
    navigation.globals().scenarios[scenario]()


@pytest.mark.parametrize("radius", [12, 20])
@pytest.mark.parametrize("start", [(5.375, -2.625), (5.01, -2.4), (10.375, 3.125), (2.125, -1.625)])
def test_winding_corridor_start_offsets(navigation, radius, start):
    navigation.globals().scenarios.navigation_winding_corridor_outside(*start, radius)


@pytest.mark.parametrize("startz", [0, 0.04, 0.125, 0.21])
@pytest.mark.parametrize("angle", [0, 0.37])
def test_subgrid_circular_elbow(navigation, startz, angle):
    navigation.globals().scenarios.navigation_subgrid_circular_elbow(startz, angle)


@pytest.mark.parametrize("change", ["move", "remove", "cancel"])
def test_snapshot_boat_lifecycle(navigation, change):
    navigation.globals().scenarios.navigation_snapshot_boat_lifecycle(change)


@pytest.mark.parametrize("kind", ["pickup", "store"])
@pytest.mark.parametrize("change", ["none", "character", "target", "cart", "wall", "water"])
def test_contact_conditions(navigation, kind, change):
    with ZipFile(native_bundle()) as archive:
        navigation.execute(archive.read("scripts/bufferedaction.lua").decode("utf-8"))
        source = archive.read("scripts/actions.lua").decode("utf-8")
    start = source.index("ACTIONS.PICKUP.fn = function(act)")
    end = source.index("\nACTIONS.EMPTY_CONTAINER.fn", start)
    navigation.execute(source[start:end])
    navigation.globals().scenarios.navigation_contact_conditions(change, kind)


@pytest.mark.parametrize("population", [120, 300])
@pytest.mark.parametrize("detour", [False, True])
def test_dense_obstacle_budget(navigation, population, detour):
    result = navigation.globals().scenarios.navigation_dense_obstacle_budget(population, detour)
    assert result.scans <= 4, "Initial and completion snapshots must share the query-start limit"
    assert result.reads <= 4096, (
        "Snapshot entity processing must yield within the shared work budget"
    )
    assert result.collisions <= 4608, (
        "Detailed collision checks must be budgeted, not only A* nodes"
    )


@pytest.mark.parametrize(
    "scenario",
    [
        "navigation_queue_keeps_progress",
        "navigation_long_walking_progress",
        "navigation_long_navigation_target_changes",
        "navigation_search_no_progress_timeout",
        "navigation_walk_no_progress_timeout",
        "navigation_timeout_contact_phase",
        "navigation_timeout_cancelled_progress",
    ],
)
def test_navigation_progress_deadlines(navigation, scenario):
    with ZipFile(native_bundle()) as archive:
        navigation.execute(archive.read("scripts/bufferedaction.lua").decode("utf-8"))
    navigation.execute("""
        ACTIONS.STORE.distance = nil
        local original_item = upgrade_contract.item
        upgrade_contract.item = function(...)
            local item = original_item(...)
            item.replica = { inventoryitem = { IsHeldBy = function(_, owner)
                return item.components.inventoryitem.owner == owner
            end } }
            return item
        end
    """)
    navigation.globals().scenarios[scenario]()


def test_native_map_overhang_recovery(navigation):
    with ZipFile(native_bundle()) as archive:
        source = archive.read("scripts/components/map.lua").decode("utf-8")
    methods = []
    for name in ("IsPassableAtPoint", "IsPassableAtPointWithPlatformRadiusBias"):
        start = source.index(f"function Map:{name}(")
        boundary = re.search(r"\n(?:local )?function \w", source[start + 1 :])
        assert boundary is not None, f"Missing map method boundary for {name}"
        methods.append(source[start : start + 1 + boundary.start()])
    navigation.execute("local Map = TheWorld.Map\n" + "\n".join(methods))
    navigation.execute("""
        function TheWorld.Map:IsAboveGroundAtPoint(x) return x >= 0 end
        function TheWorld.Map:IsVisualGroundAtPoint(x) return x >= -1.2 end
        local passable, overhang = TheWorld.Map:IsPassableAtPoint(-.6, 0, -.3, false, true)
        assert(passable and overhang, "Native Map must identify passable visual land outside its tiles")
    """)
    navigation.globals().scenarios.navigation_shore_overhang_pickup_delivery()


def test_blocked_routes_skip_terrain_queries(navigation):
    result = navigation.globals().scenarios.navigation_enclosed_cargo_conservation()
    assert result.maximum_ground <= 5000, (
        "Blocked segments must be rejected before terrain sampling"
    )
    assert result.stored == 40


def test_moving_carts_share_recheck_budget(navigation):
    result = navigation.globals().scenarios.navigation_refresh_budget()
    assert result.maximum_scans == 1
    assert result.maximum_entities <= 650
    assert result.frames == result.cars == 8


@pytest.mark.parametrize(
    "scenario",
    [
        "navigation_drop_dispatch",
        "navigation_idle_dispatch",
        "navigation_resume_dispatch",
        "navigation_fast_job_dispatch",
        "navigation_manager_long_idle",
        "navigation_manager_multiple_idle",
    ],
)
def test_native_brain_dispatch(navigation, scenario):
    navigation.execute(native_brain_methods())
    navigation.globals().scenarios[scenario]()


@pytest.mark.parametrize(
    "scenario",
    [
        "navigation_native_idle_lifecycle",
        "navigation_native_return_dispatch",
        "navigation_native_idle_wakeup",
        "navigation_native_blocked_return_dispatch",
        "navigation_native_queued_search_lifecycle",
        "navigation_native_transport_continuous",
        "navigation_native_short_pause_resumes",
    ],
)
def test_native_dispatch_lifecycle(navigation, scenario):
    navigation.execute(native_dispatch_methods())
    navigation.globals().scenarios[scenario]()
