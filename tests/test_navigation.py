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
    "navigation_chest_approach",
    "navigation_dynamic_obstacle",
    "navigation_stuck_recovery",
    "navigation_pickup_tolerance",
    "navigation_character_on_drop",
    "navigation_path_failure_retry_backoff",
    "navigation_home_detour",
    "navigation_boat_moves",
    "navigation_boat_stuck",
    "navigation_cancel_and_retry",
    "navigation_overlapping_blocker_escape",
    "navigation_blocked_pickup_releases_claim",
    "navigation_outside_save_returns",
    "navigation_same_frame_corner",
    "navigation_three_blockers_stable_turns",
    "navigation_shore_pickup",
    "navigation_shore_pickup_already_near",
    "navigation_shore_pickup_tangent",
    "navigation_shore_does_not_cross_water",
    "navigation_grid_arrival_point",
    "navigation_plain_waypoints",
    "navigation_trace_explains_cooldown",
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


@pytest.mark.parametrize("scenario", SCENARIOS)
def test_navigation_scenario(navigation, scenario):
    navigation.globals().scenarios[scenario]()


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
    ],
)
def test_native_dispatch_lifecycle(navigation, scenario):
    navigation.execute(native_dispatch_methods())
    navigation.globals().scenarios[scenario]()
