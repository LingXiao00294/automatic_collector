# Repository Guidelines

## 项目结构与架构

这是饥荒联机版（DST）服务器模组，所有客户端均需安装。

- `modinfo.lua` 管理版本与配置；`modmain.lua` 注册配方、动作和扩展接口。
- `scripts/` 包含 prefab、组件、Brain、StateGraph；`ac_targets.lua` 负责目标筛选，`ac_api.lua` 提供扩展注册。
- `assets/source/` 保存原创贴图和 `rig.json`；动画曲线位于 `tools/build_assets.py`。`assets/generated/` 是构建输出，SCML 会被覆盖。
- `anim/`、`images/` 和 `modicon.*` 是游戏资源；`tests/` 保存回归测试。
- README 只保留玩家说明；[开发者指南](docs/DEVELOPMENT.md) 管理工具流程，[技术报告](docs/TECHNICAL_REPORT.md) 记录实现；`docs/` 另含接口、美术和验证记录。
- `.reference/`、`.runtime/`、`asset_work/` 和 `publish/` 均被忽略，不作为源码提交；发行输出只使用 `publish/`。

作业只在 master simulation 执行；每次动作仅交互一个目标，在动画接触时重新验证。使用原版组件接口，保持物品数量守恒，避免替换原版全局行为。

## 构建、测试与开发命令

在仓库根目录使用 Python 3.12+ 和 `uv`：

```powershell
$env:UV_CACHE_DIR = Join-Path (Get-Location) '.cache/uv'
uv sync
uv run pytest -q
uv run ruff check tools tests
uv run ruff format --check tools tests
uv run ty check tools tests
uv run tools/build_assets.py
uv run tools/publish.py
```

依次安装开发依赖、运行测试、检查 Python 风格及类型、构建资源、生成未压缩的 `publish/`。发行脚本先验证源文件，再清空旧输出并按白名单复制；不要手动修改该目录。资源构建需要官方 Mod Tools 的 `TextureConverter.exe`；路径不同可传 `--mod-tools "<mod_tools 路径>"`。玩家运行模组不需要 Python。

## 编码风格与命名

Lua 使用四空格缩进，兼容 Lua 5.1/LuaJIT；局部变量采用 `snake_case`，组件方法采用 `PascalCase`。自定义组件与动作使用 `ac_`、`AC_` 前缀。Python 使用四空格缩进、100 字符行宽，遵循 Ruff 格式并通过 ty 检查。

修改美术时编辑源图、绑定或运动曲线，再重新构建；四面实体共用侧面动画，由引擎镜像，勿再次导出预镜像左侧。

## 测试要求

pytest 通过 Lupa 执行 LuaJIT；`tests/harness.lua` 提供行为场景，`test_assets.py` 检查发布资源，`test_publish.py` 检查发行白名单、过期文件清理及失败时保留旧输出。测试文件使用 `test_*.py`，函数使用 `test_*`，Lua 场景使用描述性 `snake_case`。

没有固定覆盖率门槛。行为修复需覆盖相关边界，尤其堆叠、容量变化、目标抢占、存档恢复和交互时刻。离线预览不等于客户端验证；历史服务器结果不能证明新版通过。游戏测试由用户负责，未经明确要求不启动客户端或专用服务器。

## 提交与 Pull Request

默认不创建提交，不直接在 `main`/`master` 开发。新分支默认使用 `codex/<主题>`；用户要求提交时沿用 Conventional Commits，例如 `fix: preserve partial pickup stacks`，仅纳入任务相关文件。

PR 描述应说明问题、最终行为、验证结果和未验证范围，关联已有问题；美术变更附预览并注明是否游戏截图。功能、配置或 API 变化同步更新 README 和相关文档；模组版本变更时同步工具项目版本，发行目录固定为 `publish/`。

## 资源与协作约束

不分发游戏或工坊参考资源、测试存档与缓存；发行文件保持白名单，`docs/` 仅留在源码仓库，游戏必需的动画 ZIP 原样复制。始终使用中文沟通。未经用户或适用指令明确要求，不派子代理。

`modinfo.lua`中的description只修改版本号，不修改内容。
