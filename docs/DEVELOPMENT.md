# 开发者指南

本指南说明源码开发、资源构建、验证和发行流程。玩家安装与使用见 [README](../README.md)；贡献约定见 [AGENTS.md](../AGENTS.md)。

## 文档导航

- [技术报告](TECHNICAL_REPORT.md)：架构、采集与运输策略、动作时序和兼容边界。
- [扩展接口](API.md)：升级、容量、资源适配器、标签和事件。
- [美术与动画](ART.md)：源图、绑定、编译格式和动画制作。
- [音效](SOUNDS.md)：原创 WAV 合成、FMOD 编译、试听与声音生命周期。
- [升级套件方案](UPGRADE_PLAN.md)：升级车与套件的设计、已制作美术、升级实现与实机验收。
- [验证记录](TESTING.md)：各版本检查结果、历史服务器验证和实机验收项目。

开发文档只保留在源码仓库的 `docs/`；发行 README 只提供玩家说明，不链接未发行的文档。

## 环境与项目结构

使用 Python 3.12+ 和 `uv` 管理工具环境。游戏内逻辑使用 Lua 5.1/LuaJIT；玩家运行模组不需要 Python。

| 路径 | 用途 |
| --- | --- |
| `modinfo.lua`、`modmain.lua` | 模组元信息、配置、配方、动作与接口注册 |
| `scripts/` | 实体、组件、Brain、StateGraph 与目标筛选 |
| `assets/source/` | 原创车身贴图、`rig.json`、音源 WAV 与 FDP |
| `assets/generated/` | 可编辑 SCML、图集、GIF 和预览，构建时覆盖 |
| `anim/`、`images/`、`sound/`、`modicon.*` | 游戏直接加载的编译资源 |
| `preview.jpg` | 创意工坊封面宣传插画 |
| `tests/` | LuaJIT 行为场景、资源与发行检查 |
| `tools/` | 美术与音效构建、发行和隔离服务器验证工具 |

## 安装工具与验证

在仓库根目录执行：

```powershell
$env:UV_CACHE_DIR = Join-Path (Get-Location) '.cache/uv'
uv sync --locked
uv run --locked pytest -q --basetemp=.cache/pytest
uv run --locked ruff check tools tests
uv run --locked ruff format --check tools tests
uv run --locked ty check tools tests
```

测试临时目录设在仓库缓存内，避免本机系统临时目录的访问限制。pytest 使用 Lupa 执行 LuaJIT，检查语法、作业行为、资源二进制和发行范围；没有固定覆盖率门槛。修改行为时补充相应边界场景，测试命名使用 `test_*.py` 与 `test_*`。

启动兼容回归另使用 Lupa 的 Lua 5.1 和 LuaJIT：提供全局 `bit` 并拒绝 `require("bit")`，执行真实小车 prefab 的客户端/服务端初始化及导航碰撞掩码场景。该检查不依赖安装游戏，避免 LuaJIT 自带模块掩盖 DST 注册 prefab 时的加载错误。

升级套件堆叠回归包含不依赖游戏安装的组件初始化设置保留场景，以及 `tests/test_stackable.py` 的原版契约检查。后者从本机 `scripts.zip` 只读加载原版 Class、`stackable` 与 `stackable_replica`，执行真实套件 prefab，覆盖默认档位、统一上限 64、各档位分别修改、组件初始化回调与无限堆叠，并检查主机/客户端初始化、拆分、存档恢复及数量守恒。可通过 `DST_GAME_ROOT` 指定安装目录；未安装游戏时跳过原版检查，不启动游戏或分发游戏源码。

`tests/test_lua.py` 另从本机 `scripts.zip` 只读加载原版实体命名、显示名、持久化与 `SpawnSaveRecord` 方法，验证两款车直接生成后的独立代码、存档重载、旧采集车代码迁移及撤销等级。命名检查加载原版 Class、`named` 和 `named_replica`，覆盖主机/客户端自定义名、作者过滤、名称回调与 `nameoverride` 优先级、与默认名相同的自定义名及清除命名后的等级切换。容量场景检查满额后的查询次数、单箱最大可接收量、过滤与冷却，不将调用次数换算为游戏帧率。实体与网络仍使用离线夹具，不模拟真实联网。安装目录沿用 `DST_GAME_ROOT`，缺少游戏时跳过原版检查。

制作分类回归同样从本机读取原版 `recipes_filter.lua` 和 `modutil` 的 `AddRecipe2` / `AddRecipeToFilter`，执行真实 `modmain.lua`，检查拾荒机与升级套件进入工具分类及原版自动添加的模组物品入口，且不进入科学或建筑分类。该项只验证分类注册，不渲染游戏制作界面；缺少游戏时跳过。

`tests/test_navigation.py` 在地形/碰撞夹具和本机原版 locomotor 方法两种模式下执行范围内避障场景，覆盖连续障碍转弯、行走动画循环重新设速、岸边拾取、隔水拒绝和普通坐标表路径点。调度场景另加载本机原版 Brain、BrainManager、行为树、`DoAction` 与 `StandStill`，覆盖放置、长时间待机、多车和快速动作后的下一任务；生命周期场景继续加载 SGManager、实际小车 StateGraph、原版动作提交与实体 BufferedAction 方法，检查完整拾取运输、返程抢占及返程失败后重选。人为设置 BrainManager 睡眠 10 秒或 Hibernate 的场景属于故障注入，只验证主动唤醒能力。原版方法从安装目录的 `data/databundles/scripts.zip` 只读加载；可通过 `DST_GAME_ROOT` 指定安装目录，未安装时跳过需要原版源码的检查，独立寻路夹具仍可运行。测试模拟时间与物理位移，不启动游戏，不分发游戏源码；客户端物理与服务器负载仍须实测。

多车回归覆盖 8 车同点共享搜索预算、搜索等待中的收起/容量变化、原版状态机暂停与恢复，以及围墙内保留货物并在拆墙后完整配送。平台场景覆盖跨帧搜索时船体平移/旋转、平台移除和新建障碍。寻路性能记录统计夹具中的 `Pathfinder:IsClear` 调用，不能直接换算为游戏帧率；夹具中让其他小车让路也不代表真实碰撞推挤已验证。

窄路回归使用原版月台半径 1、石墙半径 .5，模拟石墙紧贴 4×4 地皮外缘、月台位于中心的布局，检查偏离粗网格的起点及 8 车共享细化预算。另模拟墙体寻路格覆盖实际空隙，确认可通行空隙通过、实体封路仍拒绝；该墙格场景是契约模拟，需实机复核引擎具体栅格行为。升级回归检查碰撞半径在安装、撤销、重复读档、客户端 dirty 和晚加入时同步。

## 待机延迟诊断

重新进入世界加载当前发行文件后，在远程/服务端控制台执行：

```lua
for _, inst in pairs(Ents) do
    if inst.components.ac_worker ~= nil then
        inst.components.ac_worker:SetDebugEnabled(true)
    end
end
```

让小车先待机，再丢下可运输物品并走开。服务端日志中的 `[automatic_collector]` 行记录车的 GUID、扫描、任务选择、路径结果和成功/失败；结合日志时间、`scan_age`、`scan_in`、`brain`、`state`、`cooldowns`、`retry_in` 和 `last_failure` 区分未扫描、行为树等待及目标失败冷却。扫描日志最多每车每秒一条，诊断默认关闭且不存档；将上述 `true` 改为 `false` 即可停止输出。

2026-10-06 用户实机反馈：应用 0.6.2.1 的 `bit` 启动修复，并关闭 `DontStarveLuaJit2` 与“无卡顿加载”后，未再出现此前约 10 秒的待机等待。当前将上述组合记录为复测正常；代码修复与两个模组停用同时发生，尚未确定哪一项影响了延迟，不将任一模组认定为冲突来源。详细记录见 [验证记录](TESTING.md#v0621-待机启动实机复测反馈2026-10-06)。正常使用无需持续开启诊断；若问题再次出现，再用上述日志定位。若需要恢复两个模组，固定当前修复版本并分别启用复测，可逐项确认影响。

## 美术构建

只修改游戏逻辑或文档时无需重建美术。修改贴图、绑定或动画曲线后执行：

```powershell
uv run tools/build_assets.py --mod-tools "D:/Programs/Steam/steamapps/common/Don't Starve Mod Tools/mod_tools"
```

构建依赖官方 Mod Tools 的 `TextureConverter.exe`；路径不同可替换参数。源图在 `assets/source/`，运动曲线与导出逻辑在 `tools/build_assets.py`。构建会覆盖生成资源，不反读手工编辑的 SCML。完成后检查四方向及动作预览，并运行资源测试；详见 [美术说明](ART.md)。

升级车与套件独立构建，不覆盖原车：

```powershell
uv run --locked -m tools.build_upgrade_assets --mod-tools "D:/Programs/Steam/steamapps/common/Don't Starve Mod Tools/mod_tools"
```

源图与绑定位于 `assets/source/upgrade/`；预览输出到 `assets/generated/upgrade/collector/` 和 `kit/`，编译输出到 `anim/` 与 `images/`。0.6.0 已接入升级玩法；美术构建与 LuaJIT 回归不能代替用户的客户端及联网验收。

## 音效构建

```powershell
uv run --locked -m tools.build_sounds
```

使用官方 Mod Tools 的 `FMOD_Designer/fmod_designercl.exe`；安装目录不同可传 `--mod-tools`。合成源 WAV 与 FDP 位于 `assets/source/audio/`，试听位于 `assets/generated/audio/`，游戏使用 `sound/ac_collector.fev` 与 `.fsb`。编译日志与缓存只写入 `.cache/sound_build/`。修改音色应调整构建脚本并重建，不手改生成的 FDP；详见 [音效说明](SOUNDS.md)。

## 发行

```powershell
uv run tools/publish.py
```

脚本先验证源文件，再清空固定的 `publish/` 并复制发行文件，保留目录结构，不生成发行压缩包或 `dist/`。不要在 `publish/` 保存手动修改。源文件缺失时保留上一份发行；输出目录为符号链接、Junction 或普通文件时拒绝覆盖。

发行白名单为 `modinfo.lua`、`modmain.lua`、`modicon.xml`、`modicon.tex`、`preview.jpg`、`README.md`、`LICENSE`，以及 `scripts/`、`anim/`、`images/`、`sound/`。动画 ZIP 是游戏必需的编译资源，会原样复制。`docs/`、美术源、测试、构建工具、参考脚本、存档及缓存均不发行。

工坊封面保存在根目录 `preview.jpg`。更新封面后重新运行发行脚本，在上传工具的 `Update Preview Image` 中选择 `publish/preview.jpg`。封面使用方形 JPEG，文件保持小于 1 MB；它是宣传插画，并非游戏截图。

将 `publish/` 的内容复制到游戏的 `mods/automatic_collector/`。发布新模组版本时同步 `modinfo.lua`、`pyproject.toml`、锁文件中的项目版本及 README；文档整理不单独提升模组版本。

## 游戏验证与协作

离线测试和动画预览不能代替客户端验证。游戏测试由用户负责；未经明确要求，不启动客户端或专用服务器。[验证记录](TESTING.md) 保留隔离服务器复现命令，但历史版本的成功结果不能证明新版本通过。

始终在工作分支开发，默认不创建提交；用户要求提交时采用 Conventional Commits，只纳入任务相关内容。修改用户可见行为时更新 README；实现细节更新技术报告，接口、美术和测试记录分别更新对应文档。
