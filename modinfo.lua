name = "拾荒机 · Automatic Collector"
description = "version: 0.7.0\n拾荒机：帮你收纳物品。\n采集车：还能帮你收获植物、农作物。\n右键开关采集功能。\n兼容 Insight、棱镜和能力勋章。\n\n本模组代码、美术资源和动画由 AI（Codex）生成。\n\nchangelog: \nv0.7.0\n- 重写了小车的寻路算法\n\n- 减小了采集车的碰撞体积\n\nv0.6.2\n- 删除了基础版小车的采集功能\n- 右键开关小车改成了开关采集功能\n- 现在小车不会被行动键（默认“空格”键）捡起了"
author = "Lingxiao00294"
version = "0.7.0"
api_version = 10
dst_compatible = true
dont_starve_compatible = false
reign_of_giants_compatible = false
all_clients_require_mod = true
client_only_mod = false
server_filter_tags = { "automatic_collector" }
icon_atlas = "modicon.xml"
icon = "modicon.tex"

configuration_options = {
    {
        name = "work_radius", label = "工作半径", default = 12,
        options = {
            { description = "8", data = 8 },
            { description = "12（默认）", data = 12 },
            { description = "16", data = 16 },
        },
    },
    {
        name = "matching_only", label = "运输规则", default = true,
        options = {
            { description = "优先同类，也用空箱", data = false },
            { description = "仅已有同类物品的箱子", data = true },
        },
    },
    {
        name = "pick_plants", label = "自动采摘与收获（采集车）", default = true,
        options = { { description = "开启", data = true }, { description = "关闭", data = false } },
    },
    {
        name = "hammer_giants", label = "敲开巨大作物（采集车）", default = true,
        options = { { description = "开启", data = true }, { description = "关闭", data = false } },
    },
}
