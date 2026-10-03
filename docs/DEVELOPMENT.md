# 开发者指南

本指南说明源码开发、资源构建、验证和发行流程。玩家安装与使用见 [README](../README.md)；贡献约定见 [AGENTS.md](../AGENTS.md)。

## 文档导航

- [技术报告](TECHNICAL_REPORT.md)：架构、采集与运输策略、动作时序和兼容边界。
- [扩展接口](API.md)：升级、容量、资源适配器、标签和事件。
- [美术与动画](ART.md)：源图、绑定、编译格式和动画制作。
- [升级套件方案](UPGRADE_PLAN.md)：升级车与套件的设计、已制作美术和待实现玩法。
- [验证记录](TESTING.md)：各版本检查结果、历史服务器验证和实机验收项目。

开发文档只保留在源码仓库的 `docs/`；发行 README 只提供玩家说明，不链接未发行的文档。

## 环境与项目结构

使用 Python 3.12+ 和 `uv` 管理工具环境。游戏内逻辑使用 Lua 5.1/LuaJIT；玩家运行模组不需要 Python。

| 路径 | 用途 |
| --- | --- |
| `modinfo.lua`、`modmain.lua` | 模组元信息、配置、配方、动作与接口注册 |
| `scripts/` | 实体、组件、Brain、StateGraph 与目标筛选 |
| `assets/source/` | 原创车身贴图与 `rig.json` |
| `assets/generated/` | 可编辑 SCML、图集、GIF 和预览，构建时覆盖 |
| `anim/`、`images/`、`modicon.*` | 游戏直接加载的编译资源 |
| `tests/` | LuaJIT 行为场景、资源与发行检查 |
| `tools/` | 美术构建、发行和隔离服务器验证工具 |

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

源图与绑定位于 `assets/source/upgrade/`；预览输出到 `assets/generated/upgrade/collector/` 和 `kit/`，编译输出到 `anim/` 与 `images/`。升级玩法尚未实现，完成美术构建不能视为升级功能已发布。

## 发行

```powershell
uv run tools/publish.py
```

脚本先验证源文件，再清空固定的 `publish/` 并复制发行文件，保留目录结构，不生成发行压缩包或 `dist/`。不要在 `publish/` 保存手动修改。源文件缺失时保留上一份发行；输出目录为符号链接、Junction 或普通文件时拒绝覆盖。

发行白名单为 `modinfo.lua`、`modmain.lua`、`modicon.xml`、`modicon.tex`、`README.md`、`LICENSE`，以及 `scripts/`、`anim/`、`images/`。动画 ZIP 是游戏必需的编译资源，会原样复制。`docs/`、美术源、测试、构建工具、参考脚本、存档及缓存均不发行。

将 `publish/` 的内容复制到游戏的 `mods/automatic_collector/`。发布新模组版本时同步 `modinfo.lua`、`pyproject.toml`、锁文件中的项目版本及 README；文档整理不单独提升模组版本。

## 游戏验证与协作

离线测试和动画预览不能代替客户端验证。游戏测试由用户负责；未经明确要求，不启动客户端或专用服务器。[验证记录](TESTING.md) 保留隔离服务器复现命令，但历史版本的成功结果不能证明新版本通过。

始终在工作分支开发，默认不创建提交；用户要求提交时采用 Conventional Commits，只纳入任务相关内容。修改用户可见行为时更新 README；实现细节更新技术报告，接口、美术和测试记录分别更新对应文档。
