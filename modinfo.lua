name = "拾荒机 · Automatic Collector"
description = "version: 0.5.2\n拾荒机：每采摘 5 个农作物，集中拾取和运输；巨大作物采摘后先敲开。\n产物暂无可用接收箱时留地跳过，不阻塞后续工作。\n兼容 Insight、棱镜和能力勋章。\n右键暂停/启动。"
author = "Lingxiao00294"
version = "0.5.2"
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
        name = "pick_plants", label = "自动采摘与收获", default = true,
        options = { { description = "开启", data = true }, { description = "关闭", data = false } },
    },
    {
        name = "hammer_giants", label = "敲开巨大作物", default = true,
        options = { { description = "开启", data = true }, { description = "关闭", data = false } },
    },
}
