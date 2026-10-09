# 开发者指南

本指南面向开发者，说明源码开发、资源构建、验证和发行流程。玩家安装与使用见 [README](../../README.md)；其他专题见 [开发者文档索引](README.md)。

## 文档导航

- [技术报告](TECHNICAL_REPORT.md)：架构、采集与运输策略、动作时序和兼容边界。
- [扩展接口](API.md)：升级、容量、资源适配器、标签和事件。
- [美术与动画](ART.md)：源图、绑定、编译格式和动画制作。
- [音效](SOUNDS.md)：原创 WAV 合成、FMOD 编译、试听与声音生命周期。
- [采集车设计规格](UPGRADE_DESIGN.md)：当前升级玩法、车身结构与套件造型。
- [测试指南](TESTING.md)：回归覆盖、环境依赖、隔离服务器工具与验证边界。
- [寻路性能约束](NAVIGATION_LIMITATIONS.md)：已确认限制与后续验收要求。

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

`.reference/`、`.runtime/`、`asset_work/`、缓存和 `publish/` 都是本机参考或输出，不作为源码提交。不分发游戏或工坊参考资源、测试存档与缓存。

## 编码与提交约定

Lua 使用四空格缩进，兼容 Lua 5.1/LuaJIT；局部变量用 `snake_case`，组件方法用 `PascalCase`，自定义组件与动作用 `ac_`、`AC_` 前缀。Python 使用四空格缩进、100 字符行宽，并通过 Ruff 格式、风格与 ty 类型检查。

在 `main`/`master` 以外的工作分支开发，新分支默认使用 `codex/<主题>`。提交采用 Conventional Commits，例如 `fix: preserve partial pickup stacks`，只包含相应任务的变更。commit message 的标题和正文，以及 PR 的标题、描述和评论，均使用英文。

作业只在 master simulation 执行，每次动作只交互一个目标，在动画接触时重新验证。使用原版组件接口，保持物品数量守恒，避免替换原版全局行为；架构约束见 [技术报告](TECHNICAL_REPORT.md)。

## 安装工具与验证

在仓库根目录执行：

```powershell
$env:UV_CACHE_DIR = Join-Path (Get-Location) '.cache/uv'
uv sync --locked
uv run --locked python -m pytest -q --basetemp=.cache/pytest
uv run --locked ruff check tools tests
uv run --locked ruff format --check tools tests
uv run --locked ty check tools tests
```

测试临时目录设在仓库缓存内，避免本机系统临时目录的访问限制。pytest 使用 Lupa 执行 LuaJIT，检查语法、作业行为、资源二进制和发行范围；没有固定覆盖率门槛。修改行为时补充相应边界场景，测试命名使用 `test_*.py` 与 `test_*`。

各测试模块的覆盖范围、本机游戏源码依赖与隔离服务器工具见 [开发者测试指南](TESTING.md)。

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

正常使用无需持续开启诊断；需要定位延迟时使用上述日志。涉及其他模组时，固定当前版本并分别启用复测，避免同时改变多个条件后推断冲突来源。旧版本的实机反馈见 [历史记录](../ai/history/VALIDATION_HISTORY.md#v0621-待机启动实机复测反馈2026-10-06)。

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

源图与绑定位于 `assets/source/upgrade/`；预览输出到 `assets/generated/upgrade/collector/` 和 `kit/`，编译输出到 `anim/` 与 `images/`。升级玩法已接入；美术构建与 LuaJIT 回归不能代替客户端及联网验收。四面实体只导出前、共享侧面和后视，左侧由引擎镜像。

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

将 `publish/` 的内容复制到游戏的 `mods/automatic_collector/`。发布新模组版本时同步 `modinfo.lua`、`pyproject.toml`、锁文件中的项目版本及 README；文档整理不单独提升模组版本。`modinfo.lua` 的 `description` 只修改版本号，不主动修改文案内容。

## 游戏验证与文档维护

离线测试和动画预览不能代替客户端验证。实机检查使用 [玩家验收清单](../user/TESTING.md)，隔离服务器工具见 [测试指南](TESTING.md)。记录实测版本、环境与覆盖范围，历史版本的成功结果不能证明新版本通过。

修改用户可见行为时更新根目录 README；当前实现、接口、美术、音效和测试方法分别更新对应专题。AI 的协作约束、生成提示词与任务执行记录维护在 `docs/ai/`，具体分工见 [文档索引](../README.md)。
