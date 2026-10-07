"""Check upgrade kits against the installed game's stack component and replica."""

import importlib
import os
from pathlib import Path
from zipfile import ZipFile

import pytest

LuaRuntime = importlib.import_module("lupa.luajit21").LuaRuntime
ROOT = Path(__file__).resolve().parents[1]
STACK_KEYS = (
    "STACK_SIZE_MEDITEM",
    "STACK_SIZE_SMALLITEM",
    "STACK_SIZE_LARGEITEM",
    "STACK_SIZE_TINYITEM",
    "STACK_SIZE_PELLET",
)


@pytest.fixture
def native_stack_sources():
    game_root = Path(
        os.environ.get("DST_GAME_ROOT", "D:/Programs/Steam/steamapps/common/Don't Starve Together")
    )
    bundle = game_root / "data/databundles/scripts.zip"
    if not bundle.is_file():
        pytest.skip("Native stack contract check requires installed DST scripts")
    with ZipFile(bundle) as archive:
        return {
            name: archive.read(f"scripts/{name}.lua").decode("utf-8")
            for name in ("class", "components/stackable_replica", "components/stackable")
        }


@pytest.mark.parametrize("ismastersim", [False, True], ids=["client", "host"])
@pytest.mark.parametrize(
    "sizes, post_init_maxsize, ignore_maxsize",
    [
        ((20, 40, 10, 60, 120), None, False),
        ((64, 64, 64, 64, 64), None, False),
        ((64, 128, 32, 256, 512), None, False),
        ((20, 40, 10, 60, 120), 40, False),
        ((20, 40, 10, 60, 120), 40, True),
    ],
    ids=["vanilla", "uniform-64", "changed-categories", "component-hook", "infinite-hook"],
)
def test_native_upgrade_kit_stack_settings(
    native_stack_sources, ismastersim, sizes, post_init_maxsize, ignore_maxsize
):
    runtime = LuaRuntime(unpack_returned_tuples=True)
    runtime.globals().TUNING = runtime.table_from(dict(zip(STACK_KEYS, sizes, strict=True)))
    runtime.globals().TheWorld = runtime.table_from({"ismastersim": ismastersim})
    runtime.globals().STACK_POST_INIT_SIZE = post_init_maxsize
    runtime.globals().IGNORE_STACK_MAXSIZE = ignore_maxsize
    runtime.execute("""
        MAXUINT = 4294967295
        table.invert = function(values)
            local result = {}
            for key, value in pairs(values) do result[value] = key end
            return result
        end
        local function netvar(initial)
            local current = initial
            return { set = function(_, value) current = value end,
                value = function() return current end }
        end
        net_smallbyte = function() return netvar(0) end
        net_tinybyte = net_smallbyte
        net_bool = function() return netvar(false) end
    """)
    runtime.execute(native_stack_sources["class"], name="@scripts/class.lua")
    runtime.globals().NativeStackReplica = runtime.execute(
        native_stack_sources["components/stackable_replica"],
        name="@scripts/components/stackable_replica.lua",
    )
    runtime.globals().NativeStack = runtime.execute(
        native_stack_sources["components/stackable"], name="@scripts/components/stackable.lua"
    )
    runtime.execute("""
        Asset = function(...) return {...} end
        Prefab = function(name, fn) return {name = name, fn = fn} end
        MakeInventoryPhysics = function() end
        MakeHauntableLaunch = function() end
        local function noop() end
        CreateEntity = function()
            local inst = {GUID = 1, prefab = "ac_upgrade_kit", components = {}, replica = {}}
            inst.entity = {AddTransform = noop, AddAnimState = noop,
                AddSoundEmitter = noop, AddNetwork = noop, SetPristine = noop}
            inst.AnimState = {SetBank = noop, SetBuild = noop, PlayAnimation = noop}
            inst.AddTag, inst.ListenForEvent, inst.PushEvent = noop, noop, noop
            function inst:AddComponent(name)
                if name == "stackable" then
                    self.replica.stackable = NativeStackReplica(self)
                    local stack = NativeStack(self)
                    if STACK_POST_INIT_SIZE ~= nil then stack.maxsize = STACK_POST_INIT_SIZE end
                    if IGNORE_STACK_MAXSIZE then stack:SetIgnoreMaxSize(true) end
                    self.components.stackable = stack
                elseif name == "inventoryitem" then
                    self.components.inventoryitem = {ChangeImageName = noop,
                        GetMoisture = function() return 0 end,
                        IsWet = function() return false end, InheritMoisture = noop,
                        GetTemperature = function() return 20 end, SetTemperature = noop}
                else
                    self.components[name] = {}
                end
            end
            return inst
        end
    """)
    runtime.globals().KitPrefab = runtime.execute(
        (ROOT / "scripts/prefabs/ac_upgrade_kit.lua").read_text(encoding="utf-8"),
        name="@scripts/prefabs/ac_upgrade_kit.lua",
    )
    runtime.execute("""
        SpawnPrefab = function(name)
            assert(name == "ac_upgrade_kit")
            return KitPrefab.fn()
        end
        kit = SpawnPrefab("ac_upgrade_kit")
    """)
    if not ismastersim:
        assert runtime.eval("next(kit.components) == nil")
        return

    expected_limit = post_init_maxsize if post_init_maxsize is not None else sizes[0]
    runtime.globals().EXPECTED_LIMIT = expected_limit
    runtime.execute("""
        local function check_limit(inst)
            local stack = inst.components.stackable
            assert(stack.maxsize == (IGNORE_STACK_MAXSIZE and math.huge or EXPECTED_LIMIT))
            assert(stack.originalmaxsize == (IGNORE_STACK_MAXSIZE and EXPECTED_LIMIT or nil))
            assert(inst.replica.stackable:OriginalMaxSize() == EXPECTED_LIMIT)
            assert(inst.replica.stackable:MaxSize() == stack.maxsize)
        end
        check_limit(kit)
        local count = EXPECTED_LIMIT + (IGNORE_STACK_MAXSIZE and 7 or 0)
        kit.components.stackable:SetStackSize(count)
        local saved = kit.components.stackable:OnSave()
        local restored = SpawnPrefab("ac_upgrade_kit")
        restored.components.stackable:OnLoad(saved)
        assert(restored.components.stackable:StackSize() == count)
        local portion = restored.components.stackable:Get(1)
        assert(portion ~= restored)
        assert(portion.components.stackable:StackSize() == 1)
        assert(restored.components.stackable:StackSize() == count - 1)
        assert(portion.replica.stackable:StackSize() == 1)
        assert(restored.replica.stackable:StackSize() == count - 1)
        check_limit(restored)
        check_limit(portion)
    """)
