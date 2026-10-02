name = "拾荒机 · Automatic Collector"
description = "木制采集小车：逐个拾取、采摘和收获，集中收集同类货物后送箱子，用冲撞打开巨大作物。右键暂停/启动，重新放下可改变工作中心。"
author = "Lingxiao00294"
version = "0.4.1"
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
