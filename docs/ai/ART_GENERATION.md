# AI 美术生成说明

本页保存图像生成所需的上下文与提示词入口。当前可编辑源图、绑定、动画时序和编译方式见 [开发者美术说明](../developer/ART.md)，采集车结构约束见 [设计规格](../developer/UPGRADE_DESIGN.md)。

## 当前采集车参考

V2 使用金属底盘、四轮悬挂、木衬开放货斗和前部嵌入式六角月岩机芯；车尾为双槽检修盖。概念图用于校对造型，正式源图分别生成前、朝右的侧面、后视和套件世界图。

| 用途 | 提示词 | 参考图或正式源图 |
| --- | --- | --- |
| V2 主概念 | [主概念提示词](art/upgrade_concept_v2_prompt.txt) | [概念图](art/upgrade_concept_v2.png) |
| V2 结构校对 | [结构提示词](art/upgrade_structure_v2_prompt.txt) | [结构图](art/upgrade_structure_v2.png) |
| 采集车前视 | [前视提示词](art/body_front_production_prompt.txt) | [透明源图](../../assets/source/upgrade/body_front.png) |
| 采集车侧视 | [侧视提示词](art/body_side_production_prompt.txt) | [透明源图](../../assets/source/upgrade/body_side.png) |
| 采集车后视 | [后视提示词](art/body_back_production_prompt.txt) | [透明源图](../../assets/source/upgrade/body_back.png) |
| 升级套件 | [套件提示词](art/kit_production_prompt.txt) | [透明源图](../../assets/source/upgrade/kit_world.png) |

源图保留高分辨率 RGBA；实际裁边、缩放、140 单位车身高度、底部中心枢轴与 30 FPS 由绑定和构建器控制。概念图不是游戏截图，也不能直接裁切成正式源图。生成后检查四轮、两轴、连接关系、前后部件一致性和透明边缘；缩放后的像素不作为物理尺寸证据。

侧面只保留朝右的一份，左侧由引擎镜像；前后视与侧视须对应同一辆车。车轮和悬挂绘在整张车身图内，当前构建没有独立轮子旋转动画。资源变更仍须通过开发者构建、预览和资源检查，离线结果不替代客户端验收。

## 历史提示词

- [普通拾荒机原提示词](art/ART_PROMPT_CART.txt)：曾含现已删除的夹子、盖子、独立轮子等设计，不能按全文重新生成当前模型。当前普通车只使用三张车身源图及图中自带车轮。
- [V1 升级概念提示词](art/upgrade_concept_prompt.txt) 与 [V1 概念图](art/upgrade_concept_v1.png)：保留用于修订对照，后轮表达和升级结构未达到 V2 的要求。
- [升级套件历史实施计划](history/UPGRADE_PLAN.md)：保留阶段安排与当时状态；其中早期制作分类、代码名等内容不能替代 0.7.6 的当前设计规格和接口。

这些提示词和参考图只在源码仓库保留，不加入 `publish/`。未经任务要求，不重绘已有源图或重建未改动资源。
