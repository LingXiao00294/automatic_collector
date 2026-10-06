# 扩展接口（VERSION = 1）

模组初始化时导出 `GLOBAL.AUTOMATIC_COLLECTOR_API`，并可通过 `require("ac_api")` 访问。扩展模组应声明依赖/安排加载顺序，再注册接口。所有作业与升级变更只在 master simulation 上执行；客户端不应读取服务端组件。

## 升级

0.6.0 内置注册 `ac_chassis_mk2`，`maxlevel = 1`。套件通过服务端 `ac_upgradeitem:Install(doer, target)` 安装；不要仅以 `SetLevel` 的返回值判断首次成功，该接口接受重复同等级设置。内置等级 1 绝对设置移速倍率 2、作业倍率 1，等级 0 恢复倍率 1；加载与重复应用不累乘。0.6.1 将等级 1 的工作半径固定为 20，等级 0 恢复服务器配置半径；应用时清除接收箱缓存并同步 `_ac_radius`，安装失败恢复升级前半径。其他速度或范围扩展若覆盖同一字段，需要自行合并。

`_ac_mk2` 为在 `SetPristine` 前声明的只读布尔网络字段，客户端据此刷新 bank、build、地图图标、显示名与碰撞尺寸；服务端通过原版 `inventoryitem` 的 atlas/image 字段同步库存图标。仍使用 `automatic_collector` prefab，升级不会替换实体。

等级状态刷新同时同步物理胶囊：采集车半径 .25、普通拾荒机半径 .35，胶囊高度仍为 1；质量、碰撞组、掩码与美术缩放保持原值。服务端升级/读档及客户端 dirty/晚加入刷新均应用该尺寸，撤销等级恢复普通尺寸。导航直接读取实际 Physics 半径。

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

容量升级预留接口（默认 1 组，内置套件不增加容量）：

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

`SetCarrySlots(count)` 接受有限数字，取整并限制为 `1..8`，返回是否接受。拒绝会截断现有货物的降级，不自动丢弃物品。容量随 `ac_worker` 存档保存，并在原版库存加载前恢复；注册升级也会在加载后重新应用等级。增加槽位后会逐个拾取及采集普通资源，分别合并各组可合并产物，装满可用槽位或没有更多合适目标后逐组卸货。农作物仍按批次采摘，实际产物完整落地，再利用运输槽分组收集。仍然不提供打开内部库存的界面。

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

通过 `RegisterAdapter(name, adapter)` 新增或替换适配器。同名注册立即替换处理器，不重复加入名称列表；新增名称在注册时排序，后续扫描复用该顺序，运行期间的新注册也立即生效。`GetAdapterNames()` 返回共享的只读名称列表；`adapters` 注册表及名称列表仅用于读取，不应直接新增、删除或修改其条目。注册应放在初始化或其他扫描外的代码中，`match` / `action` 查询期间不修改注册表。

`product` 为可选纯查询函数，返回主产物 prefab 和正数数量，不应生成物品或调用采集/随机掉落回调。对于普通采摘资源，省略或返回未知产物时先卸货再空载作业；携货续采仅对无皮肤及无自定义堆叠回调的同类货物进行预测，实际转移仍由原版库存完成。无需为标准 `pickable`、农田植物和 `crop` 注册此函数；农作物批次流程不使用此函数预测容量。

普通资源的空载适配器作业会使用 `product` 返回的主产物寻找匹配样品箱；若未提供，则沿用目标自身的标准产物信息。具有上述农作物标签或组件的适配目标改走农作物批次流程，实际回调给到小车的所有产物通过原版 `DropItem` 完整落地，稍后按真实物品规则拾取运输。

本版本状态机支持 `PICKUP`、`PICK`、`HARVEST`、`STORE` 和内部 `AC_HAMMER`，自定义资源通常返回 `PICK` 或 `HARVEST`。额外动作需由扩展对 `SGac_collector` 添加 handler，并提供动作动画和验证。适配器按注册名称排序；标准处理优先。普通拾荒机只执行拾取与运输，不调用采摘适配器；采集车关闭单车采集或服务器“自动采摘与收获”配置后，也不调用采摘适配器。单车采集关闭时同时禁用巨大作物敲击。

## 容器与排除

- 带 `ac_ignore` 的实体不参与任何自动工作。
- 带 `ac_no_delivery` 的容器不会接收货物。
- 默认接收 `container.type == "chest"`。其他安全的自定义容器可加 `ac_delivery_container`。
- 容器依然必须具备开启能力（`canbeopened`）、非只读、非烹饪/晾晒设备、非角色限制、同一平台、在范围内，并通过原版 `CanAcceptCount`。不以 `CanOpen()` 或 `IsOpenedByOthers()` 排除当前已打开的接收箱，实际存放仍执行原版 `STORE`。
- 普通采摘资源的空载预检要求至少一种已知产物有匹配接收容器；农作物采摘与巨大作物敲击不做产物、样品或容量预检。实际掉落后仍按真实物品过滤和容量拾取；无匹配容器的物品留地，不绕过运输规则。
- 农作物清理阶段只做巨大作物敲击、拾取和运输。计数满 5，或不足 5 但已无可采作物时进入该阶段；车内空载且当前没有可执行的清理任务时结束。缺少匹配样品、满箱、槽位过滤拒收、目标占用或失败冷却的产物留地跳过，不阻塞恢复；后续扫描仍使用真实接收容量和安全规则，条件恢复后可再次运输。巨大作物敲击仍优先于拾取，开箱状态不影响阶段结束判定。
- 自定义回调若依赖玩家专属字段，应自行允许该机器人，或为相应资源加 `ac_ignore`。
- 已创建 `pending` 的采集/运输任务（行走及交互接触前）每 .1 秒复查并在动画接触时再次验证；任务成功、失败或取消后恢复 .25 秒待机巡检，主动调用原版 Brain 的 `ForceUpdate()`，待机选目标同样每 .25 秒节流，Brain 每 .1 秒重评。放置、`SetEnabled(true)` 和成功完成任务时清除选目标的等待，下一任务仍须等当前动作动画结束。高频巡检只验证当前任务及其接收条件，不重新扫描全部工作目标，也不因出现更优目标中断有效任务。巡检先发现目标失效时走 `Cancel(true)`，通知原版动作失败回调、释放占用并清理移动与状态机。原版移动组件先触发失败时，`Finish` 在释放任务前识别失效原因；两种顺序均不施加目标失败冷却，并解除扫描等待，不增加农作物成功计数。实际交互回调中的失败，以及超时/暂停取消保留既有冷却；纯规划失败采用递增短退避。返回中心的 `WALKTO` 不建立 `pending`，不启用高频巡检，并可被新工作抢占。

## 避障寻路

小车服务端移动由 `ac_navigation` 提供范围内避障路径，仍执行原版动作与到达距离。障碍按真实 Physics 碰撞组、掩码和半径筛选；其他 `automatic_collector` 不加入规划障碍，依靠原版角色碰撞与卡住退避处理拥挤。玩家和生物仍参与行车避障。`ac_ignore` / `ac_no_delivery` 只控制工作目标资格，不使障碍失去碰撞。

同一世界内的小车共享每模拟帧 128 个搜索工作单位，每轮最多执行 16 个单位后让出队列；初始化快照与直达尝试、A* 节点展开、路径平滑候选及完成快照均计入预算。搜索未完成时保留动作并停止移动；`Stop` / `Clear` 会取消排队任务。船上搜索使用平台局部坐标，恢复行走前重新验证最新障碍与目标位置。不对其他实体或原版全局寻路生效；修改小车实例的移动方法时须与此模块协调。

先使用 .75 单位网格，存在目标以外的静态障碍且粗网格无解时，再用 .25 单位网格检查窄路；两次搜索合计最多展开 4096 个节点，沿用上述帧预算。导航查询独立复制 `pathcaps` 并设置 `ignorewalls=true`，仅跳过原版墙体寻路格的粗略封锁；地形、水域及双方真实 Physics 碰撞体仍参与检查，不修改原版移动能力或碰撞掩码，也不允许穿墙。

路径失败会通知失败监听器、释放资源占用，并允许马上选择其他任务。找不到路线时，该目标先按 .5 秒重试，连续失败按 .5 / 1 / 2 / 4 / 8 秒递增，上限为配置的 `retry_delay`（默认 10 秒）；成功或重新放置后清除失败次数。持续卡住、搜索超时、平台变化及交互失败使用默认目标冷却。若接收箱仅因 `unreachable` / `stuck` / `search_timeout` 处于冷却且仍可实际接收，保留货物等待重试；满箱、过滤拒收等实际条件失效时仍按原规则逐组丢出。返程 `WALKTO` 不建立 `pending`，连续失败也递增退避至 `retry_delay`，成功或重新放置后清除次数，不阻塞工作扫描。

模块接管该小车实例的 `locomotor.FindPath`、`OnUpdate`、`Stop`、`Clear`、`WantsToMoveForward`、`SetMoveDir` 与 `SetMotorSpeed`，维护安全转弯点并在接近转角时限速；行走动画循环重新设置速度也须遵守限速，搜索等待时不得恢复前进。车身移动检查原版寻路地块、地图通行与碰撞净空；最后的交互接近按地图可通行陆地和静态实体碰撞体检查，允许从陆地侧拾取岸边物品，不允许隔水或穿过静态障碍交互。玩家和生物不阻挡最后的交互接近，避免玩家站在掉落物上时将物品判为不可达。

路径点兼容原版的普通 `{ x, y, z }` 坐标表；转向与平台坐标转换直接读取坐标，不要求路径点具有 `Vector3:Get()` 方法。搜索节点进入交互距离时只保存其坐标，不将 A* 搜索元数据带进行走路径。

## 玩家拾取

两款车共用 `automatic_collector` prefab，原版 `inventoryitem.canbepickedup` 固定为 false，并由原版 replica 同步资格；升级和载入不恢复该值。原版 `GetActionButtonAction` 的自动扫描和指定目标/RPC 复查均因此跳过小车，其他物品仍使用原版动作选择。

`AC_PICKUP` 只在小车的左键 `SCENE:inventoryitem` 候选中加入，右键不加入；使用原版拾取优先级、骑乘标志与额外到达距离，为 `wilson` / `wilson_client` 注册 `doshortaction`。服务端复查小车与玩家有效性、是否已收起、火焰、幽灵及 `itemtyperestrictions`，通过后发送原版 `onpickupitem` 事件并调用 `inventory:GiveItem`。小车自身的拾取回调继续取消任务、清除工作中心并交还真实货物。扩展应保持快捷拾取资格为 false，不覆盖原版全局拾取动作或输入方法。

## 服务端组件与事件

`ac_worker`：`GetHome()`、`SetHome()`、`GetCargo()`、`SetEnabled(bool)`、`IsHarvestEnabled()`、`SetHarvestEnabled(bool)`、`SetMoveSpeed(multiplier)`、`SetActionSpeed(multiplier)`、`GetCarrySlots()`、`SetCarrySlots(count)`。`GetCargo()` 返回当前待运输的一组货物，不是全部物品列表。运输槽由原版 `inventory` 持久化；不要给拾荒机增加可打开的 `container`。

内部调度接口 `GetNextAction(allow_return)` 默认兼容原有自动返程；传入 `false` 时只选择工作。`GetHomeAction()` 单独选择返程，内置 Brain 将其置于工作之后，使新工作可打断返程。不要从扩展代码同时提交多个动作。

`SetDebugEnabled(bool)` 控制可选服务端诊断，默认关闭且不随存档保存。启用后记录扫描、任务选择、路径结果及动作成功/失败；扫描日志最多每秒一条。`GetDebugString()` 包含状态机状态、Brain 调度队列、扫描等待、返程状态、目标冷却和最近失败原因。示例见 [开发者指南](DEVELOPMENT.md#待机延迟诊断)。

`IsHarvestEnabled()` 查询是否已升级且单车采集开启；具体采摘、收获与敲击还须通过对应服务器配置和目标验证。`SetHarvestEnabled(bool)` 保存单车采集偏好、同步 `_ac_harvest_enabled` 并解除扫描等待；关闭时仅以 `Cancel(true)` 取消采摘、收获、敲击及适配器任务，释放占用且不施加失败冷却，保持已有拾取/运输任务与货物。普通车即使设置为 true 也不能采集，升级后才应用该偏好。玩家 `AC_TOGGLE` 只对地面采集车提供，客户端提示读网络字段，服务端复查升级、有效性与是否已收起。

`SetEnabled(bool)` 保留为扩展的全部作业启停接口，玩家右键不再调用。存档新增 `harvest_enabled`：有该字段时分别恢复完整启停与采集偏好；旧存档缺少该字段时恢复完整作业，将原 `enabled=false` 迁移为关闭采集，保证普通拾荒机恢复拾取运输。迁移不依赖组件加载顺序，采集能力仍在升级等级生效后判断。

服务端内部 `farm_count` 为本批成功采摘数，`farm_draining` 为拾取运输阶段标志，均随组件存档保存。失败、取消和敲击不增加计数；关闭采集、完整暂停与休眠保留进度，拾取或重新放置重置。关闭采集时的拾取运输不改变批次，开启后继续原阶段；采集偏好在重新放置后保留。仅供观察，扩展应避免直接改写批次状态。农作物动作完成时使用任务内保存的类型，避免第三方回调重生、移除植株组件后漏记或漏放下产物。

| 事件 | 数据 | 时机 |
| --- | --- | --- |
| `ac_jobsuccess` | `{ target, action }` | 一个目标的动作完成 |
| `ac_jobfailed` | `{ target, action }` | 作业失败或中断 |
| `ac_enabledchanged` | `{ enabled }` | 扩展完整启停变化 |
| `ac_harvestenabledchanged` | `{ enabled }` | 单车采集偏好变化 |
| `ac_upgradechanged` | `{ name, level }` | 升级等级变化 |

目标可能在动作成功时已经移除，不要直接访问无效实体。`_ac_enabled`、`_ac_harvest_enabled`、`_ac_blocked` 是只读网络状态，不应由扩展客户端写入；`_ac_harvest_enabled` 为采集偏好，能力是否存在还需结合 `_ac_mk2`。

## Insight 显示接入

`ac_insight` 在 `AddSimPostInit` 中检测 `GLOBAL.Insight.API.V1`，注册 `ac_worker` 组件描述器及 `automatic_collector` prefab 的 `OnSelect` / `OnUnselect`。不依赖工坊目录名，不导入或分发第三方脚本；未启用 Insight 时直接跳过。

服务端描述器读取真实组件：普通拾荒机显示拾取与运输能力，采集车另显示采集开关及农作物批次进度与阶段；客户端范围显示只读取 `_ac_home_valid`、`_ac_home_x`、`_ac_home_z`、`_ac_home_platform`、`_ac_radius` 网络字段。无平台时坐标为世界坐标，有平台时为平台局部坐标；工作中心在放置、拾取和存档恢复时同步。范围圈使用客户端临时锚点，每 .1 秒更新平台位置，取消悬停或实体移除时清理，收起时隐藏。扩展客户端不得修改这些字段。
