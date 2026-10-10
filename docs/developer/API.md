# 扩展接口（VERSION = 1）

模组初始化时导出 `GLOBAL.AUTOMATIC_COLLECTOR_API`，并可通过 `require("ac_api")` 访问。扩展模组应声明依赖/安排加载顺序，再注册接口。所有作业与升级变更只在 master simulation 上执行；客户端不应读取服务端组件。

## 升级

0.6.0 内置注册 `ac_chassis_mk2`，`maxlevel = 1`。套件通过服务端 `ac_upgradeitem:Install(doer, target)` 安装；不要仅以 `SetLevel` 的返回值判断首次成功，该接口接受重复同等级设置。内置等级 1 绝对设置移速倍率 2、作业倍率 1，等级 0 恢复倍率 1；加载与重复应用不累乘。0.6.1 将等级 1 的工作半径固定为 20，等级 0 恢复服务器配置半径；应用时清除接收箱缓存并同步 `_ac_radius`，安装失败恢复升级前半径。其他速度或范围扩展若覆盖同一字段，需要自行合并。

两款车分别使用 `automatic_collector`（拾荒机）和 `automatic_collector_mk2`（采集车）prefab，由 `prefabs/automatic_collector.lua` 同时注册，共用组件与生命周期。`SpawnPrefab("automatic_collector_mk2")` 直接生成内置底盘等级 1 的采集车；`ac_upgrades.BASE_PREFAB` / `ADVANCED_PREFAB` 提供对应名称常量。升级保留原实体，通过原版 `SetPrefabName` 同步 Lua 与引擎身份，使新存档记录正确的 prefab；撤销等级或安装失败回滚时恢复普通车代码。旧存档仍可从 `automatic_collector` 加载，按原升级等级自动迁移为采集车代码。

0.7.4 恢复原版 `GetBasicDisplayName` 的优先级：扩展的 `displaynamefn`、`nameoverride`、带作者信息的过滤名称、`inst.name`。等级刷新仅更新未被自定义的默认名称；`named` 的非空名称即使恰好等于“拾荒机”或“采集车”，也会保留。需使用这两个默认字符串作为固定自定义名时，使用原版 `named` 组件，而不是仅赋值 `inst.name`。原版 `named` 负责自定义名称的网络同步和持久化。

存档兼容方向为旧版升级至新版。0.7.3 及以后写入的采集车记录使用 `automatic_collector_mk2`，0.7.2 及更早版本未注册此代码，不能恢复这些记录；降回旧模组应使用升级前的世界备份。

`_ac_mk2` 为在 `SetPristine` 前声明的只读布尔网络字段，客户端据此同步 prefab 名称并刷新 bank、build、地图图标、显示名与碰撞尺寸；服务端通过原版 `inventoryitem` 的 atlas/image 字段同步库存图标。两款车继续共用 `automatic_collector` 标签；查找所有小车时使用该标签，针对单款车时比较 `inst.prefab`。需要初始化两款车的扩展应分别注册两个 prefab 的 `AddPrefabPostInit`。

两端构造时均按 prefab 入口初始化 `_ac_mk2`：拾荒机为 false，采集车为 true，然后调用 `SetPristine`。不能只在服务端设置 mk2 初值；初始同步未再次下发该字段时，客户端必须依靠同一 prefab 的相同默认值保持等级。构造后初始反序列化仍不保证触发 `ac_mk2dirty`，因此保留客户端 `DoStaticTaskInTime(0, ...)` 的一次复查及后续 dirty 刷新。刷新同步 Lua / 引擎 prefab、外观与名称，不读取服务端组件，不改写升级存档或货物。

两款小车的物理胶囊统一为半径 .25（直径 .5），胶囊高度参数为 1；质量、碰撞组、掩码与美术缩放保持原值。新建、服务端升级/读档及客户端 dirty/晚加入刷新均应用该尺寸，撤销等级或安装失败回滚也保持此尺寸。导航直接读取实际 Physics 半径。

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
local api = GLOBAL.AUTOMATIC_COLLECTOR_API
local upgrade_name = "my_mod_capacity"
local maxlevel = 3

if api ~= nil then
    api.RegisterUpgrade(upgrade_name, {
        maxlevel = maxlevel,
        apply = function(inst, level)
            inst.components.ac_worker:SetCarrySlots(1 + level)
        end,
    })
end

local function RequestCapacityLevel(inst, level)
    if api == nil or GLOBAL.TheWorld == nil or not GLOBAL.TheWorld.ismastersim
        or inst == nil or not inst:IsValid()
        or type(level) ~= "number" or level ~= level
        or level == math.huge or level == -math.huge then
        return false, "INVALID_REQUEST"
    end
    local worker = inst.components.ac_worker
    local upgradable = inst.components.ac_upgradable
    if worker == nil or upgradable == nil or api.upgrades[upgrade_name] == nil then
        return false, "INVALID_REQUEST"
    end
    level = math.max(0, math.min(maxlevel, math.floor(level)))

    -- 最新的有效请求替换尚未完成的请求。
    if inst._my_mod_capacity_retry ~= nil then
        inst._my_mod_capacity_retry:Cancel()
        inst._my_mod_capacity_retry = nil
    end
    local function TryApply()
        -- 先确认实际槽位能调整，再提交等级；此过程不让出执行。
        if not worker:SetCarrySlots(1 + level) then return false end
        if inst._my_mod_capacity_retry ~= nil then
            inst._my_mod_capacity_retry:Cancel()
            inst._my_mod_capacity_retry = nil
        end
        return upgradable:SetLevel(upgrade_name, level)
    end
    if TryApply() then return true end

    -- 闭包保留本次等级请求，每 .5 秒复查，成功后停止重试。
    inst._my_mod_capacity_retry = inst:DoPeriodicTask(.5, TryApply)
    return false, "WAITING_FOR_CARGO"
end
```

对该容量升级的安装、降级和撤销均调用 `RequestCapacityLevel`，不要绕过预检直接调用 `SetLevel`。例如，`collector` 为服务端小车实体时：

```lua
local applied, reason = RequestCapacityLevel(collector, 0)
-- true：等级和容量均已更新。
-- false, "WAITING_FOR_CARGO"：保留原等级及容量，卸货后自动重试。
-- false, "INVALID_REQUEST"：未登记请求。
```

待重试请求只在当前实体存活期间保留；实体移除会取消其周期任务。需要在重载存档后继续请求的扩展，应自行保存请求等级，并在载入组件与升级注册就绪后重新调用此入口。材料消耗和成功提示应在实际等级提交后处理，等待期间不视为安装成功。

`SetCarrySlots(count)` 接受有限数字，取整并限制为 `1..8`，返回是否接受。拒绝会截断现有货物的降级，不自动丢弃物品。容量随 `ac_worker` 存档保存，并在原版库存加载前恢复；注册升级也会在加载后重新应用等级。增加槽位后会逐个拾取及采集普通资源，分别合并各组可合并产物，装满可用槽位或没有更多合适目标后逐组卸货。农作物仍按批次采摘，实际产物完整落地，再利用运输槽分组收集。仍然不提供打开内部库存的界面。

`SetLevel` 返回是否接受等级设置，将等级限制在整数 `0..maxlevel`，`0` 表示撤销。它先记录等级，再执行 `apply` 并发送 `ac_upgradechanged`；不读取 `apply` 的返回值，也不因回调返回 `false` 回滚等级。因此返回 `true` 不保证扩展效果已成功应用，需要拒绝变更的扩展应在调用前完成预检。`apply(inst, level, previous_level)` 必须可重复执行，并处理 `level=0` 恢复默认值。载入存档会自动重新应用已注册升级；未注册的升级等级保留，扩展重新启用后可恢复。

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
- 已创建 `pending` 的采集/运输任务（行走及交互接触前）每 .1 秒复查并在动画接触时再次验证；任务成功、失败或取消后恢复 .5 秒待机巡检，主动调用原版 Brain 的 `ForceUpdate()`，待机选目标同样每 .5 秒节流，Brain 每 .1 秒重评。放置、`SetEnabled(true)` 和成功完成任务时清除选目标的等待，下一任务仍须等当前动作动画结束。高频巡检只验证当前任务及其接收条件，不重新扫描全部工作目标，也不因出现更优目标中断有效任务。巡检先发现目标失效时走 `Cancel(true)`，通知原版动作失败回调、释放占用并清理移动与状态机。原版移动组件先触发失败时，`Finish` 在释放任务前识别失效原因；两种顺序均不施加目标失败冷却，并解除扫描等待，不增加农作物成功计数。实际交互回调中的失败，以及超时/暂停取消保留既有冷却；纯规划失败采用递增短退避。返回中心的 `WALKTO` 不建立 `pending`，不启用高频巡检，并可被新工作抢占。

## 避障寻路

服务器配置 `new_navigation`（“启用新版寻路”）默认 `true`，缺少配置值时也默认开启；同时作用于两款小车，修改后须重新载入世界。关闭时不加载或挂接 `ac_navigation`，保留原版 locomotor 的全部移动方法；工作目标范围和碰撞尺寸不变。该开关不写入单车存档，载入的小车使用当前服务器配置。以下自定义导航规则仅在开启时生效。

小车服务端移动由 `ac_navigation` 提供范围内避障路径，仍执行原版动作与到达距离。障碍按真实 Physics 碰撞组、掩码和半径筛选；其他 `automatic_collector` 不加入规划障碍，依靠原版角色碰撞与卡住退避处理拥挤。玩家和生物仍参与行车避障。`ac_ignore` / `ac_no_delivery` 只控制工作目标资格，不使障碍失去碰撞。

同一世界内的小车共享每模拟帧 128 个搜索工作单位，每轮最多执行 16 个单位后让出队列。节点展开、额外细邻居批次、平滑候选及快照启动按整单位计费；实体过滤、索引桶访问、候选碰撞检查、地形查询及间隙点构建等内层操作各计 1/128 单位，允许在内层循环中让出。初始、完成和途中复查的异步快照合计每帧最多启动 4 次实体查询，返回列表的处理和索引构建继续按预算分片。单次引擎 `FindEntities` / `Pathfinder:IsClear` 调用本身不可拆分，因此预算不是实机耗时保证。搜索未完成时保留动作并停止移动；`Stop` / `Clear` 会取消排队任务。船上索引、工作中心和搜索坐标保持平台局部坐标，平台移除后不再恢复构建中的快照。不对其他实体或原版全局寻路生效。

行驶障碍复查仍在 .25 秒后进入 FIFO 队列，每帧最多启动一份复查构建，可以跨帧完成；复查优先使用共享预算，每帧最多占用 64 单位，给新搜索保留机会。短暂排队时继续沿已验证路线行走；快照年龄从查询开始计算，达到 .5 秒、目标偏移超过 .25 单位，或即将满足动作到达距离时，停车等待新快照。构建完成时已经过期的快照也不能恢复行走。只有实际停车等待的时间不计入物理卡住；后台排队时马达运转但没有进展仍计入卡住。收步状态可在移动恢复时立即重新起步。取消、目标失效或平台移除不会恢复旧动作。碰撞体按膨胀后的包围盒写入 2 单位空间索引，线段只访问穿过的索引格，并按真实圆形碰撞体作精确检查；实体碰撞拒绝后不再查询地形。

开阔处使用 .75 单位网格，范围内的障碍或地形拒绝触发周边 .25 单位细化，纯地形窄道也适用；仅超出工作圆的候选不会触发沿圆周的密集细化。相邻静态圆形碰撞体膨胀后仍有不超过 .75 单位的间隙时，在自由区间中点生成几何节点，排除被第三个障碍、地形或范围阻挡的点。这些点连接附近网格和 1.5 单位内的其他间隙点，避免窄缝完全落在固定网格线之间；不会从几何点再生成无限多组平移网格。粗、细及几何节点共用同一队列和最多 4096 次节点展开，所有连线保留碰撞、地形和范围检查。导航查询独立复制 `pathcaps` 并设置 `ignorewalls=true`，仅跳过原版墙体寻路格的粗略封锁，不修改原版移动能力或碰撞掩码。

新版导航通过 `Worker:RecordActionProgress(action)` 更新当前动作的进展时间：搜索获得并消耗共享工作份额、停车等待中的复查继续处理，或车身在平台局部坐标中前进至少 .1 单位时续期。后台复查不替代车身移动；原有 1.5 秒卡住检测与有限重试仍生效。`pending.started` 保留最初时间供诊断，`action_timeout`（默认 20 秒）检查最近进展后的静默时间，不再限制整条长路线的总耗时；完全停止调度/移动仍会超时。状态图进入工作动画时重新计时，之后不再由旧导航任务续期。进展通知按动作对象身份匹配，已取消动作不能续期新任务；有效长任务的后续容量/目标变化仍按语义失效处理，不因最初开始时间较早而加上错误冷却。

路径失败会通知失败监听器、释放资源占用，并允许马上选择其他任务。找不到路线时，该目标先按 .5 秒重试，连续失败按 .5 / 1 / 2 / 4 / 8 秒递增，上限为配置的 `retry_delay`（默认 10 秒）；成功或重新放置后清除失败次数。持续卡住、搜索超时、平台变化及交互失败使用默认目标冷却。若接收箱仅因 `unreachable` / `stuck` / `search_timeout` / `navigation_timeout` 处于冷却且仍可实际接收，保留货物等待重试；满箱、过滤拒收等实际条件失效时仍按原规则逐组丢出。搜索停滞使用 `search_timeout`，已有路线的导航停滞使用 `navigation_timeout`，工作动画等非导航阶段仍为普通 `timeout`，不能统一当作导航失败。返程 `WALKTO` 不建立 `pending`，连续失败也递增退避至 `retry_delay`，成功或重新放置后清除次数，不阻塞工作扫描。

有限搜索与性能约束下仍待处理的行为见 [寻路性能约束与待改进问题](NAVIGATION_LIMITATIONS.md)，包含可达路线耗尽 4096 节点、较长共享队列等待和过期快照停车，不能把这些边界理解为可达性或实机耗时保证。

模块接管该小车实例的 `locomotor.FindPath`、`OnUpdate`、`Stop`、`Clear`、`WantsToMoveForward`、`SetMoveDir` 与 `SetMotorSpeed`，维护安全转弯点并在接近转角时限速；行走动画循环重新设置速度也须遵守限速，搜索等待时不得恢复前进。车身移动优先检查原版寻路地块、地图通行与碰撞净空。若原版射线拒绝，且线段至少一个端点由 `Map:IsPassableAtPoint(..., false, true)` 的第二个返回值明确标为可行走的岸边延伸区域，则以 .1 单位间隔复查整段地图通行及车身左右净空；延伸区域以外的连续陆地段仍必须通过原版射线。该规则支持拾取后驶离岸边以及空载返程，不放宽真实水域、实体阻挡或工作范围。最后的交互接近按地图可通行陆地和静态实体碰撞体检查，允许从陆地侧拾取岸边物品，不允许隔水或穿过静态障碍交互。玩家和生物不阻挡最后的交互接近，避免玩家站在掉落物上时将物品判为不可达。

路径点兼容原版的普通 `{ x, y, z }` 坐标表；转向与平台坐标转换直接读取坐标，不要求路径点具有 `Vector3:Get()` 方法。搜索节点进入交互距离时只保存其坐标，不将 A* 搜索元数据带进行走路径。

最后一段接近在目标移动后使用当前目标位置重新求可通行的接近点，小于 .25 单位的位移也会更新；静止目标保留原先已验证的岸边切向接近点，较早的转弯点仍按原路线推进。两种寻路模式都在工作动画接触时由 `Worker:CanInteract` 复查原版选定的到达距离；新版寻路另通过本车的 `locomotor.ac_can_interact` 获取接触附近的即时快照，检查静态遮挡与地图通行。该同步局部复查不使用已被 `Stop` 清除的路线快照，不进入异步搜索预算。空间条件失效时只通知一次失败、释放目标占用并允许重选，不拆分物品、不消耗货物、不增加成功采摘计数；行走中的语义巡检仍不要求已经靠近目标。

## 玩家拾取

两款车共用 `automatic_collector` 标签，原版 `inventoryitem.canbepickedup` 固定为 false，并由原版 replica 同步资格；升级和载入不恢复该值。原版 `GetActionButtonAction` 的自动扫描和指定目标/RPC 复查均因此跳过小车，其他物品仍使用原版动作选择。

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

`ac_insight` 在 `AddSimPostInit` 中检测 `GLOBAL.Insight.API.V1`，注册 `ac_worker` 组件描述器及 `automatic_collector`、`automatic_collector_mk2` 两个 prefab 的 `OnSelect` / `OnUnselect`。不依赖工坊目录名，不导入或分发第三方脚本；未启用 Insight 时直接跳过。

服务端描述器读取真实组件：普通拾荒机显示拾取与运输能力，采集车另显示采集开关及农作物批次进度与阶段；客户端范围显示只读取 `_ac_home_valid`、`_ac_home_x`、`_ac_home_z`、`_ac_home_platform`、`_ac_radius` 网络字段。无平台时坐标为世界坐标，有平台时为平台局部坐标；工作中心在放置、拾取和存档恢复时同步。范围圈使用客户端临时锚点，每 .1 秒更新平台位置，取消悬停或实体移除时清理，收起时隐藏。扩展客户端不得修改这些字段。
