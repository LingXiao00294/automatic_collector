# AI 协作入口

本文件供在本仓库工作的 AI 读取。开始任务时先阅读 [协作规范](docs/ai/WORKFLOW.md) 和 [文档写作规范](docs/ai/WRITING.md)，再按任务查阅对应的开发文档。

## 文档分工

| 读者 | 入口 | 内容 |
| --- | --- | --- |
| 玩家 | [README](README.md)、[玩家文档](docs/user/README.md) | 制作、操作、配置、兼容与手动验收 |
| 开发者 | [开发者文档](docs/developer/README.md) | 工具、架构、接口、资源规格与可重复的测试方法 |
| AI | [AI 文档](docs/ai/README.md) | 协作与写作规则、生成提示词、历史任务与验证记录 |

完整目录与维护位置见 [文档索引](docs/README.md)。

## 必须遵守

- 始终使用中文沟通；commit message 的标题和正文，以及 PR 的标题、描述和评论，均使用英文。
- 不直接在 `main`/`master` 开发，新分支默认使用 `codex/<主题>`。默认不创建提交；用户要求提交时采用 Conventional Commits，仅纳入授权范围内的改动。
- Python 工具使用 Python 3.12+ 和 `uv`。构建、测试与发行命令见 [开发者指南](docs/developer/DEVELOPMENT.md)。
- 作业只在 master simulation 执行；每次动作仅交互一个目标，在动画接触时重新验证。使用原版组件接口，保持物品数量守恒，避免替换原版全局行为。
- 游戏测试由用户负责；未经明确要求，不启动客户端或专用服务器。离线预览、历史验证和当前实机结果必须分别说明。
- 未经用户或适用指令明确要求，不派子代理。
- 不分发游戏或工坊参考资源、测试存档与缓存；发行仅通过白名单脚本生成 `publish/`。`docs/` 仅留在源码仓库，游戏必需的动画 ZIP 原样复制。
- `modinfo.lua` 的 `description` 只修改版本号，不主动修改文案内容。
- 用户可见功能、配置或 API 变化时同步玩家和开发者文档；模组版本变更时同步工具项目与锁文件版本。AI 执行过程与交接记录按写作规范单独保存。

## 按任务阅读

- 实现与修复：[技术报告](docs/developer/TECHNICAL_REPORT.md)、[测试指南](docs/developer/TESTING.md)。
- 配置、升级或扩展：[接口文档](docs/developer/API.md)、[采集车设计规格](docs/developer/UPGRADE_DESIGN.md)。
- 美术与音效：[美术说明](docs/developer/ART.md)、[音效说明](docs/developer/SOUNDS.md)；生成图片前另读 [AI 美术生成说明](docs/ai/ART_GENERATION.md)。
- 寻路：[性能约束与待改进问题](docs/developer/NAVIGATION_LIMITATIONS.md)。历史诊断用于了解基线，不替代当前验证。
