# 扩展接口（VERSION = 1）

模组初始化时导出 `GLOBAL.AUTOMATIC_COLLECTOR_API`，并可通过 `require("ac_api")` 访问。扩展模组应声明依赖/安排加载顺序，再注册接口。所有作业与升级变更只在 master simulation 上执行；客户端不应读取服务端组件。

## 升级

```lua
local G = GLOBAL
local api = G.AUTOMATIC_COLLECTOR_API
if api ~= nil then
    api.RegisterUpgrade("my_mod_speed", {
        maxlevel = 3,
        apply = function(inst, level, previous_level)
            local worker = inst.components.ac_worker
            worker:SetMoveSpeed(1 + level * .25)
            worker:SetActionSpeed(1 + level * .25)
        end,
    })
    api.RegisterUpgrade("my_mod_lamp", {
        maxlevel = 1,
        apply = function(inst, level, previous_level)
            inst.Light:SetRadius(level > 0 and 2 or 0)
            inst.Light:SetIntensity(.5)
            inst.Light:SetFalloff(.8)
            inst.Light:SetColour(1, .82, .55)
            inst.Light:Enable(level > 0)
        end,
    })
end
```

升级物品或其他服务端系统可调用：

```lua
local changed = collector.components.ac_upgradable:SetLevel("my_mod_speed", 2)
local level = collector.components.ac_upgradable:GetLevel("my_mod_speed")
```

容量升级预留接口（默认 1 组，尚无实际升级物品）：

```lua
api.RegisterUpgrade("my_mod_capacity", {
    maxlevel = 3,
    apply = function(inst, level)
        local accepted = inst.components.ac_worker:SetCarrySlots(1 + level)
        -- 降级时若高位运输槽仍有货物，返回 false；卸货后由扩展重试。
    end,
})
local slots = collector.components.ac_worker:GetCarrySlots()
```

`SetCarrySlots(count)` 接受有限数字，取整并限制为 `1..8`，返回是否接受。拒绝会截断现有货物的降级，不自动丢弃物品。容量随 `ac_worker` 存档保存，并在原版库存加载前恢复；注册升级也会在加载后重新应用等级。增加槽位后会逐个拾取、采摘和收获，分别合并各组可合并产物，装满可用槽位或没有更多合适目标后逐组卸货。仍然不提供打开内部库存的界面。

`SetLevel` 返回是否接受变更，将等级限制在整数 `0..maxlevel`，`0` 表示撤销。`apply(inst, level, previous_level)` 必须可重复执行，并处理 `level=0` 恢复默认值。载入存档会自动重新应用已注册升级；未注册的升级等级保留，扩展重新启用后可恢复。

升级应自行处理材料消耗、RPC、玩家操作和网络同步。不要跳过状态机动画或直接批量采集。速度接口为绝对倍率（限制 `.25..4`），多个扩展若同时改同一速度，需要自行合并。动作速度同时改变动画播放和接触时刻，保持二者同步。

## 自定义资源适配

标准 `pickable` 与成熟 `crop` 无需适配。`farm_plant`、`crop`、棱镜 `perennialcrop` / `perennialcrop2` 和带 `medal_fruit_tree` 标签的果树使用农作物批次流程：每成功采摘 5 个进入拾取运输阶段，农作物选择及接触时不查询预测产物或接收容量。雨竹等普通采摘资源仍使用 `ac_compat` 的只读产物识别。采摘执行原版动作及目标自己的回调。适配器用于额外的资源类型：

```lua
local G = GLOBAL
local api = G.AUTOMATIC_COLLECTOR_API
if api ~= nil then
    api.RegisterAdapter("my_mod_resource", {
        match = function(collector, target)
            return target:HasTag("my_mod_ready_resource")
                and target.components.harvestable ~= nil
        end,
        action = function(collector, target)
            return G.ACTIONS.HARVEST
        end,
        -- 可选：纯查询已知主产物及一次采集的数量，支持携货继续凑组。
        product = function(collector, target)
            return "my_mod_product", 1
        end,
    })
end
```

`match` 必须自行验证资源成熟、可交互及角色限制，且不能改变世界。`action` 返回同一个已注册 Action 对象，不能创建新对象或直接收获。选择目标和动作接触时都会重新判断。

`product` 为可选纯查询函数，返回主产物 prefab 和正数数量，不应生成物品或调用采集/随机掉落回调。对于普通采摘资源，省略或返回未知产物时先卸货再空载作业；携货续采仅对无皮肤及无自定义堆叠回调的同类货物进行预测，实际转移仍由原版库存完成。无需为标准 `pickable`、农田植物和 `crop` 注册此函数；农作物批次流程不使用此函数预测容量。

普通资源的空载适配器作业会使用 `product` 返回的主产物寻找匹配样品箱；若未提供，则沿用目标自身的标准产物信息。具有上述农作物标签或组件的适配目标改走农作物批次流程，实际回调给到小车的所有产物通过原版 `DropItem` 完整落地，稍后按真实物品规则拾取运输。

本版本状态机支持 `PICKUP`、`PICK`、`HARVEST`、`STORE` 和内部 `AC_HAMMER`，自定义资源通常返回 `PICK` 或 `HARVEST`。额外动作需由扩展对 `SGac_collector` 添加 handler，并提供动作动画和验证。适配器按注册名称排序；标准处理优先。关闭“自动采摘与收获”也会禁用采摘适配器。

## 容器与排除

- 带 `ac_ignore` 的实体不参与任何自动工作。
- 带 `ac_no_delivery` 的容器不会接收货物。
- 默认接收 `container.type == "chest"`。其他安全的自定义容器可加 `ac_delivery_container`。
- 容器依然必须具备开启能力（`canbeopened`）、非只读、非烹饪/晾晒设备、非角色限制、同一平台、在范围内，并通过原版 `CanAcceptCount`。不以 `CanOpen()` 或 `IsOpenedByOthers()` 排除当前已打开的接收箱，实际存放仍执行原版 `STORE`。
- 普通采摘资源的空载预检要求至少一种已知产物有匹配接收容器；农作物采摘与巨大作物敲击不做产物、样品或容量预检。实际掉落后仍按真实物品过滤和容量拾取；无匹配容器的物品留地，不绕过运输规则。
- 农作物清理阶段只做巨大作物敲击、拾取和运输。计数满 5，或不足 5 但已无可采作物时进入该阶段；车内空载且当前没有可执行的清理任务时结束。缺少匹配样品、满箱、槽位过滤拒收、目标占用或失败冷却的产物留地跳过，不阻塞恢复；后续扫描仍使用真实接收容量和安全规则，条件恢复后可再次运输。巨大作物敲击仍优先于拾取，开箱状态不影响阶段结束判定。
- 自定义回调若依赖玩家专属字段，应自行允许该机器人，或为相应资源加 `ac_ignore`。
- 所有待执行任务（行走及交互接触前）每 .1 秒复查并在动画接触时再次验证；任务成功、失败或取消后恢复 .5 秒待机巡检，待机选目标仍保持 .5 秒节流。高频巡检只验证当前任务及其接收条件，不重新扫描全部工作目标，也不因出现更优目标中断有效任务。目标失效或条件变化时走 `Cancel(true)`，通知原版动作失败回调、释放占用、清理移动与状态机并立即允许重新规划；此类取消不施加目标失败冷却，不增加农作物成功计数。路径失败及超时仍保留既有冷却。

## 服务端组件与事件

`ac_worker`：`GetHome()`、`SetHome()`、`GetCargo()`、`SetEnabled(bool)`、`SetMoveSpeed(multiplier)`、`SetActionSpeed(multiplier)`、`GetCarrySlots()`、`SetCarrySlots(count)`。`GetCargo()` 返回当前待运输的一组货物，不是全部物品列表。运输槽由原版 `inventory` 持久化；不要给拾荒机增加可打开的 `container`。

服务端内部 `farm_count` 为本批成功采摘数，`farm_draining` 为拾取运输阶段标志，均随组件存档保存。失败、取消和敲击不增加计数；暂停、休眠保留进度，拾取或重新放置重置。仅供观察，扩展应避免直接改写批次状态。农作物动作完成时使用任务内保存的类型，避免第三方回调重生、移除植株组件后漏记或漏放下产物。

| 事件 | 数据 | 时机 |
| --- | --- | --- |
| `ac_jobsuccess` | `{ target, action }` | 一个目标的动作完成 |
| `ac_jobfailed` | `{ target, action }` | 作业失败或中断 |
| `ac_enabledchanged` | `{ enabled }` | 启停变化 |
| `ac_upgradechanged` | `{ name, level }` | 升级等级变化 |

目标可能在动作成功时已经移除，不要直接访问无效实体。`_ac_enabled`、`_ac_blocked` 是仅用于显示的只读网络状态，不应由扩展客户端写入。

## Insight 显示接入

`ac_insight` 在 `AddSimPostInit` 中检测 `GLOBAL.Insight.API.V1`，注册 `ac_worker` 组件描述器及 `automatic_collector` prefab 的 `OnSelect` / `OnUnselect`。不依赖工坊目录名，不导入或分发第三方脚本；未启用 Insight 时直接跳过。

服务端描述器读取真实组件，并显示农作物批次进度与阶段；客户端范围显示只读取 `_ac_home_valid`、`_ac_home_x`、`_ac_home_z`、`_ac_home_platform`、`_ac_radius` 网络字段。无平台时坐标为世界坐标，有平台时为平台局部坐标；工作中心在放置、拾取和存档恢复时同步。范围圈使用客户端临时锚点，每 .1 秒更新平台位置，取消悬停或实体移除时清理，收起时隐藏。扩展客户端不得修改这些字段。
