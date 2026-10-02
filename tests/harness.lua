-- A small engine contract harness. World mutation occurs only when an action is executed.
function Class(base, ctor)
    if ctor == nil then ctor, base = base, nil end
    local c = {}
    c.__index = c
    return setmetatable(c, { __index = base, __call = function(_, ...)
        local self = setmetatable({}, c)
        ctor(self, ...)
        return self
    end })
end
math.clamp = function(x, a, b) return math.max(a, math.min(b, x)) end
local now = 0
FRAMES = 1 / 30
GetTime = function() return now end
function Vector3(x, y, z)
    local v = { x = x, y = y, z = z }
    v.Get = function(self) return self.x, self.y, self.z end
    return v
end
ACTIONS = {}
for _, name in ipairs({ "PICKUP", "STORE", "PICK", "HARVEST", "HAMMER", "AC_HAMMER", "WALKTO" }) do
    ACTIONS[name] = { id = name, distance = 1.5 }
end
TUNING = { AUTOMATIC_COLLECTOR = { radius = 12, walkspeed = 3, pick_plants = true,
    hammer_giants = true, matching_only = false, action_timeout = 20, retry_delay = 10 } }
local entities = {}
local scans = 0
TheSim = { FindEntities = function(_, x, y, z, radius, must, exclude)
    scans = scans + 1
    local found = {}
    for _, ent in ipairs(entities) do
        local ok = ent:IsValid() and ent:GetDistanceSqToPoint(Vector3(x,y,z)) <= radius^2
        for _, tag in ipairs(must or {}) do ok = ok and ent:HasTag(tag) end
        if ok and not ent:HasAnyTag(exclude or {}) then table.insert(found, ent) end
    end
    return found
end }
local function entity(prefab, x, tags)
    local e = { prefab = prefab, x = x or 0, z = 0, tags = {}, components = {}, events = {}, valid = true }
    for _, tag in ipairs(tags or {}) do e.tags[tag] = true end
    function e:IsValid() return self.valid end
    function e:HasTag(tag) return self.tags[tag] == true end
    function e:HasAnyTag(list) for _, tag in ipairs(list) do if self:HasTag(tag) then return true end end return false end
    function e:IsInLimbo() return self:HasTag("INLIMBO") end
    function e:IsAsleep() return self.asleep == true end
    function e:GetPosition() return Vector3(self.x, 0, self.z) end
    function e:GetDistanceSqToPoint(p) return (self.x-p.x)^2+(self.z-p.z)^2 end
    function e:GetDistanceSqToInst(other) return self:GetDistanceSqToPoint(other:GetPosition()) end
    function e:GetCurrentPlatform() return self.platform end
    function e:IsOnPassablePoint() return self.passable ~= false end
    function e:DoPeriodicTask(_, fn) self.periodic = fn return { Cancel = function() end } end
    function e:DoTaskInTime(_, fn) fn(self) end
    function e:PushEvent(name, data) table.insert(self.events, { name = name, data = data }) end
    function e:ClearBufferedAction() self.buffered = nil end
    function e:GetBufferedAction() return self.buffered end
    function e:ForceFacePoint(pos) self.faced = pos end
    e.Transform = {
        GetWorldPosition = function() return e.x, 0, e.z end,
        SetPosition = function(_, x, _, z) e.x, e.z = x, z end,
    }
    function e:PerformBufferedAction()
        self.mutations = (self.mutations or 0)+1
        local action = self.buffered
        if action.action == ACTIONS.PICKUP then
            self.components.inventory:GiveItem(action.target)
        elseif action.action == ACTIONS.PICK then
            action.target.components.pickable:Pick(self)
        elseif action.action == ACTIONS.HARVEST then
            action.target.components.crop:Harvest(self)
        elseif action.action == ACTIONS.AC_HAMMER then
            action.target.components.workable:WorkedBy(self,1)
        elseif action.action == ACTIONS.STORE then
            local cargo = self.components.inventory:RemoveItem(action.invobject)
            local container = action.target.components.container
            -- Native STORE opens stationary containers as it transfers the item.
            container:Open(self)
            local count = cargo.components.stackable:StackSize()
            container.stored[cargo.prefab] = (container.stored[cargo.prefab] or 0) + count
            container.capacity = container.capacity - count
            cargo.components.inventoryitem.owner = action.target
        end
        action:Succeed() self.buffered = nil
    end
    local function net() return { set = function(self, value) self.value = value end } end
    e._ac_enabled, e._ac_blocked = net(), net()
    table.insert(entities, e)
    return e
end
local function inventory(owner)
    local inv = { owner = owner, items = {}, maxslots = 1, closes = 0, opencontainers = {} }
    inv.itemslots = inv.items
    function inv:GetFirstItemInAnySlot()
        for slot=1,self.maxslots do if self.items[slot] ~= nil then return self.items[slot] end end
    end
    function inv:GetItemInSlot(slot) return self.items[slot] end
    function inv:CanAcceptCount(item)
        local count = item.components.stackable:StackSize()
        local room = 0
        for slot=1,self.maxslots do
            local existing = self.items[slot]
            if existing == nil then return count end
            if existing.components.stackable:CanStackWith(item) then room = room + existing.components.stackable:RoomLeft() end
        end
        return math.min(room,count)
    end
    function inv:GetActiveItem() return self.active end
    function inv:CloseAllChestContainers()
        self.closes = self.closes + 1
        for target in pairs(self.opencontainers) do
            if target:IsValid() and target.components.container.type == "chest" then
                target.components.container:Close(self.owner)
            end
        end
    end
    function inv:GiveItem(item)
        for slot=1,self.maxslots do
            local existing = self.items[slot]
            if existing ~= nil and existing.components.stackable:CanStackWith(item) then
                item = existing.components.stackable:Put(item)
                if item == nil then return true end
            end
        end
        for slot=1,self.maxslots do
            if self.items[slot] == nil then
                self.items[slot] = item item.components.inventoryitem.owner = self.owner return true
            end
        end
        self.active = item item.components.inventoryitem.owner = self.owner return true
    end
    function inv:RemoveItem(item)
        for i, value in pairs(self.items) do if value == item then self.items[i] = nil item.components.inventoryitem.owner = nil return item end end
        if self.active == item then self.active = nil item.components.inventoryitem.owner = nil return item end
    end
    function inv:DropItem(item, wholestack, randomdir)
        if item.components.inventoryitem.islockedinslot then return nil end
        self:RemoveItem(item)
        item.Transform:SetPosition(self.owner.Transform:GetWorldPosition())
        self.drops = self.drops or {}
        table.insert(self.drops, { item = item, wholestack = wholestack, randomdir = randomdir })
        return item
    end
    function inv:DropEverything() self.items = {} self.itemslots = self.items self.active = nil end
    return inv
end
function BufferedAction(doer, target, action, item, pos)
    local a = { doer = doer, target = target, action = action, invobject = item, pos = pos, success = {}, fail = {} }
    function a:AddSuccessAction(fn) table.insert(self.success, fn) end
    function a:AddFailAction(fn) table.insert(self.fail, fn) end
    function a:Succeed() for _, fn in ipairs(self.success) do fn() end end
    function a:Fail() for _, fn in ipairs(self.fail) do fn() end end
    return a
end
local Worker = require("components/ac_worker")
local Targets = require("ac_targets")
local Upgradable = require("components/ac_upgradable")
local API = require("ac_api")
local function worker(x)
    local e = entity("automatic_collector", x, { "automatic_collector" })
    e.components.inventoryitem = { IsHeld = function() return e.held == true end }
    e.components.inventory = inventory(e)
    e.components.locomotor = { Stop = function() end, Clear = function() end, StopMoving = function() end }
    e.sg = { GoToState = function() end }
    local w = Worker(e)
    e.components.ac_worker = w
    w:SetHome()
    return w
end
local function item(prefab, x, tags, count)
    local e = entity(prefab or "twigs", x, tags)
    e.components.inventoryitem = { canbepickedup = true, cangoincontainer = true,
        IsHeld = function(self) return self.owner ~= nil end }
    local stack = { stacksize = count or 1, maxsize = 40 }
    function stack:StackSize() return self.stacksize end
    function stack:IsFull() return self.stacksize >= self.maxsize end
    function stack:RoomLeft() return self.maxsize - self.stacksize end
    function stack:CanStackWith(other)
        return e.prefab == other.prefab and e.skinname == other.skinname and other.nomerge ~= true
    end
    function stack:Get(amount)
        if amount >= self.stacksize then return e end
        self.stacksize = self.stacksize - amount
        local portion = item(e.prefab,e.x,nil,amount)
        portion.skinname, portion.z = e.skinname, e.z
        portion.components.stackable.maxsize = self.maxsize
        return portion
    end
    function stack:Put(other)
        local taken = math.min(self:RoomLeft(),other.components.stackable:StackSize())
        self.stacksize = self.stacksize + taken
        other.components.stackable.stacksize = other.components.stackable.stacksize - taken
        if other.components.stackable.stacksize <= 0 then other.valid = false return nil end
        return other
    end
    e.components.stackable = stack
    return e
end
local function chest(x, has, capacity)
    local e = entity("treasurechest", x, { "_container" })
    local c = { type = "chest", canbeopened = true, slots = {}, stored = {}, capacity = capacity or 40, has = has or {}, openers = {} }
    function c:Has(prefab) return self.has[prefab] == true end
    function c:CanAcceptCount(it, maxcount) return math.min(self.capacity, maxcount or it.components.stackable:StackSize()) end
    function c:IsFull() return self.capacity == 0 end
    function c:IsRestricted() return self.restricted == true end
    function c:CanOpen() return self.locked ~= true end
    function c:IsOpenedByOthers() return self.open == true end
    function c:IsOpenedBy(doer) return self.openers[doer] == true end
    function c:Open(doer)
        self.openers[doer] = true
        doer.components.inventory.opencontainers[e] = true
    end
    function c:Close(doer)
        self.openers[doer] = nil
        doer.components.inventory.opencontainers[e] = nil
    end
    e.components.container = c
    return e
end
local function plant(x, mature)
    local e = entity("grass", x)
    local pickable = { product = "cutgrass", numtoharvest = 1, mature = mature ~= false, caninteractwith = true,
        CanBePicked = function(self) return self.mature end, IsStuck = function() return false end }
    function pickable:Pick(doer)
        local product = self.product or e.plant_def.product
        local yield = item(product,e.x,nil,self.numtoharvest)
        if not self.droppicked then doer.components.inventory:GiveItem(yield) end
        for _, extra in ipairs(self.extras or {}) do
            doer.components.inventory:GiveItem(item(extra,e.x))
        end
        self.mature = false e.harvests = (e.harvests or 0) + 1
    end
    e.components.pickable = pickable
    return e
end
local function setup()
    local w = worker()
    chest(5)
    return w
end
local function execute(w, action)
    assert(w:ValidateAction(action))
    w.inst.buffered = action
    w:PerformAction(action)
    now = now + 1.1
end

scenarios = {}
function scenarios.single_target()
    local w = setup()
    local a, b = item("twigs", 1), item("twigs", 2)
    local action = w:GetNextAction()
    assert(action.target == a and w:GetNextAction() == nil and a.components.inventoryitem.owner == nil)
    assert(b.components.inventoryitem.owner == nil)
end
function scenarios.cargo_collects_same_product()
    local w = setup()
    plant(1) item("twigs",2)
    local cargo = item("cutgrass",0)
    w.inst.components.inventory:GiveItem(cargo)
    assert(w:GetNextAction().action == ACTIONS.PICK)
end
function scenarios.matching_priority()
    local w = worker()
    local near, far = chest(1), chest(8,{twigs=true})
    local it = item("twigs",2)
    assert(Targets.FindContainer(w,it) == far)
    far.components.container.capacity = 0
    assert(Targets.FindContainer(w,it) == near)
    w.config.matching_only = true
    assert(Targets.FindContainer(w,it) == nil)
end
function scenarios.full_chest()
    local w = worker() local c = chest(3, nil, 0)
    local cargo = item("twigs",1) w.inst.components.inventory:GiveItem(cargo)
    assert(w:GetNextAction() == nil and not w.blocked and w:GetCargo() == nil)
    assert(cargo:IsValid() and cargo.components.inventoryitem.owner == nil and cargo.x == 0)
    now = .5 assert(w:GetNextAction() == nil, "Do not pick up undeliverable dropped cargo")
    c.components.container.capacity = 40 now = 1
    local pickup = w:GetNextAction() assert(pickup.action == ACTIONS.PICKUP and not w.blocked)
    execute(w,pickup)
    execute(w,w:GetNextAction())
    assert(c.components.container.stored.twigs == 1)
end
function scenarios.two_workers()
    local a, b = worker(), worker() chest(5)
    local first, second = item("twigs",1), item("twigs",2)
    assert(a:GetNextAction().target == first)
    assert(b:GetNextAction().target == second)
    a:OnRemoveFromEntity()
    assert(Targets.IsAvailable(b,first))
end
function scenarios.failed_path()
    local w = setup() local a = item("twigs",1) local b = item("twigs",2)
    w:GetNextAction():Fail() now = 1
    assert(w:GetNextAction().target == b and w:IsCoolingDown(a))
end
function scenarios.timeout()
    local w = setup() local it = item("twigs",1) w:GetNextAction()
    now = 21 w:Watchdog()
    assert(w.pending == nil and w:IsCoolingDown(it))
end
function scenarios.pause()
    local w = setup() local it = item("twigs",1) local action = w:GetNextAction()
    w:SetEnabled(false)
    assert(not w:ValidateAction(action) and w.pending == nil and not w:IsWorking())
    assert(Targets.IsAvailable(worker(),it))
end
function scenarios.target_removed()
    local w = setup() local it = item("twigs",1) local a = w:GetNextAction()
    it.valid = false assert(not w:ValidateAction(a))
end
function scenarios.target_held()
    local w = setup() local it = item("twigs",1) local a = w:GetNextAction()
    it.components.inventoryitem.owner = entity("wilson",1)
    assert(not w:ValidateAction(a))
end
function scenarios.immature()
    local w = setup() plant(1,false)
    assert(w:GetNextAction() == nil)
end
function scenarios.giant_harvest()
    local w = setup() local p = plant(1)
    p.tags.farm_plant = true p.is_oversized = true p.plant_def = {product="carrot"}
    assert(w:GetNextAction().action == ACTIONS.PICK)
end
local function giant(prefab)
    local e = item(prefab or "carrot_oversized",1,{"oversized_veggie","heavy"})
    e.components.inventoryitem.cangoincontainer = false
    local product = e.prefab:match("^(.-)_oversized")
    e.components.lootdropper = {loot={product,product,product.."_seeds",product.."_seeds",product}}
    local workable = {workleft=3, GetWorkAction=function() return ACTIONS.HAMMER end}
    function workable:CanBeWorked() return self.workleft > 0 end
    function workable:WorkedBy(_,amount)
        self.workleft = self.workleft - amount
        if self.workleft <= 0 then
            e.valid = false
            for _, loot in ipairs(e.components.lootdropper.loot) do item(loot,e.x) end
        end
    end
    e.components.workable = workable
    return e
end
function scenarios.giant_hammer()
    local w = setup() local e = giant()
    assert(w:GetNextAction().action == ACTIONS.AC_HAMMER)
    assert(Targets.Kind(w,e) == "hammer")
    local house = entity("treasurechest",1)
    house.components.workable = e.components.workable
    assert(Targets.Kind(w,house) == nil)
end
function scenarios.waxed_giant()
    local w = setup() giant("carrot_oversized_waxed")
    assert(w:GetNextAction() == nil)
end
function scenarios.unsafe_items()
    local w = setup()
    for _, tag in ipairs({"irreplaceable","catchable","cursed","spider","heavy","ac_ignore"}) do
        local e = item("item",1,{tag}) assert(Targets.Kind(w,e) == nil)
    end
    local bait = item("seeds",1) bait.components.bait = {trap={}}
    assert(Targets.Kind(w,bait) == nil)
end
function scenarios.same_platform()
    local w = setup() local it = item("twigs",1) it.platform = entity("boat",0)
    assert(Targets.Kind(w,it) == nil)
end
function scenarios.home_radius()
    local w = setup() w.inst.x = 10
    assert(Targets.Kind(w,plant(20)) == nil)
    assert(Targets.Kind(w,item("twigs",13)) == "pickup")
    assert(Targets.Kind(w,item("twigs",15)) == nil)
end
function scenarios.moving_boat()
    local w = worker(4) local boat = entity("boat",0)
    boat.entity = { WorldToLocalSpace = function(_,x,y,z) return x-boat.x,y,z end,
        LocalToWorldSpace = function(_,x,y,z) return x+boat.x,y,z end }
    w.inst.platform = boat w:SetHome() boat.x = 20
    assert(w:GetHome().x == 24)
end
function scenarios.save_load()
    local w = worker(6) w:SetEnabled(false)
    local data = w:OnSave() local restored = worker() restored:OnLoad(data)
    assert(restored:GetHome().x == 6 and not restored.enabled)
    restored:OnDropped() assert(restored.enabled and restored:GetHome().x == 0)
end
function scenarios.pickup_unloads()
    local w = setup() local cargo = item("cutgrass",1) w.inst.components.inventory:GiveItem(cargo)
    local owner = entity("wilson",0) owner.components.inventory = inventory(owner)
    w:OnPickup(owner)
    assert(w:GetCargo() == nil and owner.components.inventory.items[1] == cargo and w.home == nil)
end
function scenarios.unknown_upgrade()
    local u = Upgradable(entity("robot",0)) u:OnLoad({levels={lamp=2}})
    assert(u:GetLevel("lamp") == 2 and u:OnSave().levels.lamp == 2)
end
function scenarios.upgrades()
    local e = entity("robot",0) local u = Upgradable(e)
    API.RegisterUpgrade("speed", { maxlevel = 3, apply = function(inst,level) inst.speed = level end })
    assert(u:SetLevel("speed",8) and e.speed == 3)
    assert(u:SetLevel("speed",0) and e.speed == 0)
    assert(not u:SetLevel("speed",0/0))
end
function scenarios.adapter()
    local w = setup() local e = entity("mod_crop",1)
    API.RegisterAdapter("mod_crop", {match=function(_,t) return t == e end, action=function() return ACTIONS.HARVEST end})
    assert(w:GetNextAction().action == ACTIONS.HARVEST)
end
function scenarios.scan_cost()
    local w = setup() for i=1,30 do item("twigs",1+i/100) end
    w:GetNextAction() assert(scans == 2, "Scan containers once per selection")
end

-- Execute the actual stategraph callbacks and test animation impact synchronisation.
package.preload["stategraphs/commonstates"] = function()
    CommonHandlers = { OnLocomote = function() return {} end }
    CommonStates = { AddWalkStates = function() end }
end
State = function(s) return s end
ActionHandler = function(a,s) return {action=a,state=s} end
StateGraph = function(_,s) return s end
local states = require("stategraphs/SGac_collector")
local function enter(w, action, name)
    local state
    for _, s in ipairs(states) do if s.name == (name or "pickup") then state = s end end
    w.inst.buffered = action
    w.inst.AnimState = {SetDeltaTimeMultiplier=function() end, PlayAnimation=function(_, animation) w.inst.animation = animation end}
    w.inst.SoundEmitter = {PlaySound=function() end}
    w.inst.sg = {statemem={}, timeinstate=0, currentstate=state,
        SetTimeout=function(self,t) self.timeout=t end,
        GoToState=function(self,name)
            if self.currentstate.onexit ~= nil then self.currentstate.onexit(w.inst) end
            for _, nextstate in ipairs(states) do
                if nextstate.name == name then
                    self.currentstate, self.statemem, self.timeinstate = nextstate, {}, 0
                    if nextstate.onenter ~= nil then nextstate.onenter(w.inst) end
                    return
                end
            end
        end}
    state.onenter(w.inst)
    return state
end
function scenarios.impact_once()
    local w = setup() item("twigs",1)
    local state = enter(w,w:GetNextAction())
    w.inst.sg.timeinstate = .49 state.onupdate(w.inst)
    assert(w.inst.mutations == nil)
    w.inst.sg.timeinstate = .5 state.onupdate(w.inst) state.onupdate(w.inst)
    assert(w.inst.mutations == 1)
end
function scenarios.impact_cancelled()
    local w = setup() local it = item("twigs",1)
    local state = enter(w,w:GetNextAction()) it.valid=false
    w.inst.sg.timeinstate = .6 state.onupdate(w.inst)
    assert(w.inst.mutations == nil and w.pending == nil)
end
function scenarios.impact_speed()
    local w = setup() item("twigs",1) w:SetActionSpeed(2)
    local state = enter(w,w:GetNextAction())
    assert(w.inst.sg.timeout == .5)
    w.inst.sg.timeinstate = .25 state.onupdate(w.inst)
    assert(w.inst.mutations == 1)
end
function scenarios.native_component_contract()
    -- These are the APIs used at impact, not invented bulk harvest methods.
    local w = setup() local p = plant(1)
    assert(Targets.Kind(w,p) == "pick")
    p.components.pickable.caninteractwith = false
    assert(Targets.Kind(w,p) == nil)
    local c = chest(3) c.components.container.open = true
    assert(not Targets.IsContainer(w,c))
    c.components.container.open = false c.components.container.restricted = true
    assert(not Targets.IsContainer(w,c))
end

function scenarios.merge_then_deliver()
    local w = worker() local c = chest(5)
    local a,b,different = item("twigs",1),item("twigs",2),item("flint",.1)
    -- Select the nearer flint only after this twig group has been unloaded.
    different.tags.ac_ignore = true
    execute(w,w:GetNextAction())
    different.tags.ac_ignore = nil
    local nextaction = w:GetNextAction()
    assert(nextaction.target == b and nextaction.action == ACTIONS.PICKUP)
    execute(w,nextaction)
    assert(w:GetCargo().components.stackable:StackSize() == 2 and w.inst.components.inventory:GetActiveItem() == nil)
    assert(not b:IsValid() and a.components.inventoryitem.owner == w.inst)
    local delivery = w:GetNextAction()
    assert(delivery.action == ACTIONS.STORE)
    execute(w,delivery)
    assert(w:GetCargo() == nil and c.components.container.stored.twigs == 2 and different:IsValid())
end

function scenarios.full_stack_delivers()
    local w = setup() local cargo = item("twigs",0,nil,40)
    w.inst.components.inventory:GiveItem(cargo)
    item("twigs",1)
    assert(w:GetNextAction().action == ACTIONS.STORE)
end

function scenarios.partial_stack_pickup()
    local w = setup() local cargo = item("twigs",0,nil,39)
    w.inst.components.inventory:GiveItem(cargo)
    local ground = item("twigs",2,nil,7)
    local action = w:GetNextAction()
    assert(action.action == ACTIONS.PICKUP and w:GetPickupCount(ground) == 1)
    execute(w,action)
    assert(cargo.components.stackable:StackSize() == 40 and ground.components.stackable:StackSize() == 6)
    assert(w.inst.components.inventory:GetActiveItem() == nil and Targets.IsAvailable(worker(),ground))
    assert(w:GetNextAction().action == ACTIONS.STORE)
end

function scenarios.destination_limits_merge()
    local w = worker() local c = chest(5,nil,5)
    local cargo = item("twigs",0,nil,4) w.inst.components.inventory:GiveItem(cargo)
    local ground = item("twigs",1,nil,3)
    assert(w:GetPickupCount(ground) == 1)
    execute(w,w:GetNextAction())
    assert(cargo.components.stackable:StackSize() == 5 and ground.components.stackable:StackSize() == 2)
    execute(w,w:GetNextAction())
    assert(c.components.container.stored.twigs == 5 and w:GetNextAction() == nil)
end

function scenarios.capacity_changes_at_impact()
    local w = worker() local c = chest(5)
    local cargo = item("twigs",0,nil,4) w.inst.components.inventory:GiveItem(cargo)
    local ground = item("twigs",1,nil,3)
    local action = w:GetNextAction()
    c.components.container.capacity = 5
    execute(w,action)
    assert(cargo.components.stackable:StackSize() == 5 and ground.components.stackable:StackSize() == 2)
end

function scenarios.skin_and_mod_merge_rules()
    local w = setup() local cargo = item("twigs",0) w.inst.components.inventory:GiveItem(cargo)
    local skin = item("twigs",1) skin.skinname = "other_skin"
    local filtered = item("twigs",2) filtered.nomerge = true
    assert(w:GetNextAction().action == ACTIONS.STORE)
    assert(w:GetPickupCount(skin) == 0 and w:GetPickupCount(filtered) == 0)
end

function scenarios.no_active_overflow()
    local w = setup() local cargo = item("carrot",0)
    w.inst.components.inventory:GiveItem(cargo)
    w.inst.components.inventory.active = item("seeds",0)
    item("carrot",1)
    assert(w:GetNextAction().action == ACTIONS.STORE)
end

function scenarios.future_carry_slots()
    local w = setup()
    assert(w:GetCarrySlots() == 1 and w:SetCarrySlots(2))
    local cargo = item("twigs",0,nil,40) w.inst.components.inventory:GiveItem(cargo)
    local second = item("flint",1)
    execute(w,w:GetNextAction())
    assert(w.inst.components.inventory:GetItemInSlot(2) == second)
    assert(not w:SetCarrySlots(1) and not w:SetCarrySlots(0/0))
    assert(w:GetCarrySlots() == 2 and w.inst.components.inventory:GetActiveItem() == nil)
    local restored = worker()
    local data = w:OnSave()
    restored:OnPreLoad(data)
    restored.inst.components.inventory:GiveItem(item("twigs",0,nil,40))
    restored.inst.components.inventory:GiveItem(item("flint",0))
    restored:OnLoad(data)
    assert(restored:GetCarrySlots() == 2 and restored.inst.components.inventory:GetItemInSlot(2).prefab == "flint")
    assert(restored.inst.components.inventory:GetActiveItem() == nil)
end

function scenarios.claimed_merge_target()
    local w = setup() local cargo = item("twigs",0) w.inst.components.inventory:GiveItem(cargo)
    local ground = item("twigs",1)
    local other = worker() assert(Targets.Claim(other,ground))
    assert(w:GetNextAction().action == ACTIONS.STORE)
end

function scenarios.work_faces_target()
    local w = setup() local ground = item("twigs",2)
    enter(w,w:GetNextAction())
    assert(w.inst.faced.x == ground.x and w.inst.faced.z == ground.z)
end

function scenarios.batch_plants()
    local w = worker() local c = chest(5)
    local a,b,last = plant(1),plant(2),plant(3)
    local wrong = plant(.2) wrong.components.pickable.product = "twigs"
    wrong.components.pickable.mature = false
    execute(w,w:GetNextAction()) wrong.components.pickable.mature = true
    assert(a.harvests == 1 and b.harvests == nil and last.harvests == nil)
    execute(w,w:GetNextAction()) execute(w,w:GetNextAction())
    assert(w:GetCargo().prefab == "cutgrass" and w:GetCargo().components.stackable:StackSize() == 3)
    assert(a.harvests == 1 and b.harvests == 1 and last.harvests == 1 and wrong.harvests == nil)
    local delivery = w:GetNextAction() assert(delivery.action == ACTIONS.STORE)
    execute(w,delivery)
    assert(c.components.container.stored.cutgrass == 3)
end

function scenarios.pickup_and_pick_batch()
    local w = setup() local dropped = item("cutgrass",1) local p = plant(2)
    execute(w,w:GetNextAction())
    assert(w:GetNextAction().target == p)
    execute(w,w.pending.action)
    assert(dropped.components.stackable:StackSize() == 2 and w:GetNextAction().action == ACTIONS.STORE)
end

function scenarios.harvest_yield_capacity()
    local w = setup() local cargo = item("cutgrass",0,nil,39)
    w.inst.components.inventory:GiveItem(cargo)
    local p = plant(1) p.components.pickable.numtoharvest = 3
    assert(w:GetNextAction().action == ACTIONS.STORE and p.harvests == nil)
    w:Cancel() now = now + 11 w.nextscan = 0
    p.components.pickable.numtoharvest = 1
    execute(w,w:GetNextAction())
    assert(cargo.components.stackable:StackSize() == 40 and w:GetNextAction().action == ACTIONS.STORE)
end

function scenarios.harvest_capacity_at_impact()
    local w = worker() local c = chest(5)
    w.inst.components.inventory:GiveItem(item("cutgrass",0,nil,4))
    local p = plant(1) p.components.pickable.numtoharvest = 2
    local action = w:GetNextAction()
    local state = enter(w,action,"pick")
    c.components.container.capacity = 5
    w.inst.sg.timeinstate = .7 state.onupdate(w.inst)
    assert(w.inst.mutations == nil and p.harvests == nil and w.pending == nil)
end

function scenarios.batch_crops_with_seeds()
    local w = worker() local c = chest(5)
    local crops = {}
    for i=1,3 do
        local p = plant(i)
        p.tags.farm_plant = true p.plant_def = { product="carrot", seed="carrot_seeds" }
        p.components.pickable.product = nil
        p.components.pickable.use_lootdropper_for_product = true
        p.components.pickable.extras = {"carrot_seeds"}
        crops[i] = p
    end
    for i=1,3 do
        local action = w:GetNextAction() assert(action.target == crops[i] and action.action == ACTIONS.PICK)
        execute(w,action)
        assert(w.inst.components.inventory:GetActiveItem() == nil)
    end
    assert(w:GetCargo().components.stackable:StackSize() == 3)
    execute(w,w:GetNextAction())
    assert(c.components.container.stored.carrot == 3)
    for i=1,3 do execute(w,w:GetNextAction()) end
    assert(w:GetCargo().prefab == "carrot_seeds" and w:GetCargo().components.stackable:StackSize() == 3)
    execute(w,w:GetNextAction())
    assert(c.components.container.stored.carrot_seeds == 3)
end

function scenarios.batch_legacy_crops()
    local w = worker() local c = chest(5)
    for i=1,2 do
        local p = entity("old_crop",i)
        p.components.crop = {matured=true,product_prefab="carrot"}
        function p.components.crop:Harvest(doer)
            doer.components.inventory:GiveItem(item(self.product_prefab,p.x))
            self.matured = false
        end
    end
    execute(w,w:GetNextAction()) execute(w,w:GetNextAction())
    assert(w:GetCargo().components.stackable:StackSize() == 2)
    execute(w,w:GetNextAction()) assert(c.components.container.stored.carrot == 2)
end

function scenarios.unknown_harvest_delivers_first()
    local w = setup() w.inst.components.inventory:GiveItem(item("cutgrass",0))
    local p = plant(1) p.components.pickable.product = nil
    p.components.pickable.use_lootdropper_for_product = true
    p.components.lootdropper = {lootsetupfn=function() error("Must not call loot setup") end}
    assert(w:GetNextAction().action == ACTIONS.STORE)
end

function scenarios.batch_adapter()
    local w = setup() w.inst.components.inventory:GiveItem(item("cutgrass",0))
    local p = entity("custom_crop",1)
    API.RegisterAdapter("batch_crop", {
        match=function(_,target) return target == p end,
        action=function() return ACTIONS.HARVEST end,
        product=function() return "cutgrass",2 end,
    })
    assert(w:GetNextAction().target == p)
    assert(w:ValidateAction(w.pending.action))
    w:Cancel() w.nextscan = 0
    API.adapters.batch_crop.product = nil
    assert(w:GetNextAction().action == ACTIONS.STORE)
end

function scenarios.harvest_uses_ram_animation()
    local w = setup() local p = plant(1)
    local state = enter(w,w:GetNextAction(),"pick")
    assert(w.inst.animation == "hammer" and w.inst.sg.timeout == 1.3)
    w.inst.sg.timeinstate = .69 state.onupdate(w.inst) assert(p.harvests == nil)
    w.inst.sg.timeinstate = .7 state.onupdate(w.inst) state.onupdate(w.inst)
    assert(p.harvests == 1 and w.inst.mutations == 1)
end

function scenarios.pickup_arrives_over_item()
    local w = setup() item("twigs",2)
    local action = w:GetNextAction()
    assert(action.arrivedist == .15 and ACTIONS.PICKUP.distance == 1.5)
    execute(w,action)
    assert(w:GetNextAction().arrivedist == nil, "Containers retain normal arrival distance")
end

local function enter_store(speed)
    local w = worker()
    local c = chest(3)
    w.inst.components.inventory:GiveItem(item("twigs",0,nil,3))
    if speed ~= nil then w:SetActionSpeed(speed) end
    return w, c, enter(w,w:GetNextAction(),"store")
end

function scenarios.store_open_window()
    local w,c,state = enter_store()
    local container = c.components.container
    assert(not container:IsOpenedBy(w.inst))
    w.inst.sg.timeinstate = 5 * FRAMES state.onupdate(w.inst)
    assert(w.inst.mutations == nil and not container:IsOpenedBy(w.inst))
    w.inst.sg.timeinstate = 6 * FRAMES state.onupdate(w.inst) state.onupdate(w.inst)
    assert(w.inst.mutations == 1 and w.pending == nil and w:GetCargo() == nil)
    assert(container.stored.twigs == 3 and container:IsOpenedBy(w.inst))
    assert(w.inst.components.inventory.closes == 0)
    w.inst.sg.timeinstate = .99 state.onupdate(w.inst)
    assert(container:IsOpenedBy(w.inst) and w.inst.mutations == 1)
    state.ontimeout(w.inst)
    assert(not container:IsOpenedBy(w.inst) and w.inst.components.inventory.closes == 1)
end

function scenarios.store_open_speed()
    local w,c,state = enter_store(2)
    assert(w.inst.sg.timeout == .5)
    w.inst.sg.timeinstate = .09 state.onupdate(w.inst)
    assert(w.inst.mutations == nil)
    w.inst.sg.timeinstate = .1 state.onupdate(w.inst)
    assert(c.components.container:IsOpenedBy(w.inst) and c.components.container.stored.twigs == 3)
    w.inst.sg.timeinstate = .49 state.onupdate(w.inst)
    assert(c.components.container:IsOpenedBy(w.inst))
    state.ontimeout(w.inst)
    assert(not c.components.container:IsOpenedBy(w.inst))
end

function scenarios.store_open_interrupted()
    local w,c,state = enter_store()
    w.inst.sg.timeinstate = .1 state.onupdate(w.inst)
    w:SetEnabled(false)
    assert(w.pending == nil and w:GetCargo() ~= nil and c.components.container.stored.twigs == nil)
    assert(not c.components.container:IsOpenedBy(w.inst))
end

function scenarios.store_open_cancelled_after_success()
    local w,c,state = enter_store()
    w.inst.sg.timeinstate = .2 state.onupdate(w.inst)
    assert(w.pending == nil and c.components.container:IsOpenedBy(w.inst))
    c.components.container.open = true -- Another opener must not be closed by the robot.
    w:SetEnabled(false)
    assert(not c.components.container:IsOpenedBy(w.inst) and c.components.container.open)
    assert(c.components.container.stored.twigs == 3 and w.inst.mutations == 1)
end

function scenarios.store_open_failed_preflight()
    local w,c,state = enter_store()
    c.components.container.capacity = 0
    w.inst.sg.timeinstate = .2 state.onupdate(w.inst)
    assert(w.inst.mutations == nil and w.pending == nil and w:GetCargo() ~= nil)
    assert(not c.components.container:IsOpenedBy(w.inst) and c.components.container.stored.twigs == nil)
end

function scenarios.store_direct_closes()
    local w = worker() local c = chest(3)
    w.inst.components.inventory:GiveItem(item("twigs",0,nil,3))
    execute(w,w:GetNextAction())
    assert(c.components.container.stored.twigs == 3 and not c.components.container:IsOpenedBy(w.inst))
end

function scenarios.store_open_failed_action()
    local w,c,state = enter_store()
    function w.inst:PerformBufferedAction()
        -- A third-party container can reject delivery after native STORE opens it.
        local action = self.buffered
        action.target.components.container:Open(self)
        action:Fail()
        self.buffered = nil
    end
    w.inst.sg.timeinstate = .2 state.onupdate(w.inst)
    assert(w.pending == nil and w:GetCargo().components.stackable:StackSize() == 3)
    assert(not c.components.container:IsOpenedBy(w.inst) and c.components.container.stored.twigs == nil)
    assert(w.inst.components.inventory.closes == 1)
end

function scenarios.giant_matching_primary_sample()
    local w = worker() w.config.matching_only = true
    local fridge = chest(3,{garlic=true}) fridge.prefab = "icebox"
    local e = giant("garlic_oversized")
    for stroke=1,3 do
        local action = w:GetNextAction()
        assert(action.target == e and action.action == ACTIONS.AC_HAMMER)
        local state = enter(w,action,"hammer")
        w.inst.sg.timeinstate = .69 state.onupdate(w.inst)
        assert(e.components.workable.workleft == 4 - stroke)
        w.inst.sg.timeinstate = .7 state.onupdate(w.inst) state.onupdate(w.inst)
        assert(e.components.workable.workleft == 3 - stroke)
        state.ontimeout(w.inst) now = now + 1.4
    end
    assert(not e:IsValid() and w.inst.mutations == 3)
    for _=1,3 do
        local action = w:GetNextAction()
        assert(action.action == ACTIONS.PICKUP and action.target.prefab == "garlic")
        execute(w,action)
    end
    assert(w:GetCargo().components.stackable:StackSize() == 3)
    local action = w:GetNextAction()
    assert(action.action == ACTIONS.STORE and action.target == fridge)
    execute(w,action)
    assert(fridge.components.container.stored.garlic == 3 and w:GetNextAction() == nil)
    local seeds = 0
    for _, target in ipairs(entities) do
        if target.prefab == "garlic_seeds" and target:IsValid() then
            assert(target.components.inventoryitem.owner == nil)
            seeds = seeds + target.components.stackable:StackSize()
        end
    end
    assert(seeds == 2, "Unmatched seed byproducts stay on the ground")
end

function scenarios.giant_matching_split_destinations()
    local w = worker() w.config.matching_only = true
    chest(3,{garlic=true}) chest(4,{garlic_seeds=true})
    local e = giant("garlic_oversized")
    assert(w:GetNextAction().target == e)
end

function scenarios.giant_matching_wrong_or_full_sample()
    local w = worker() w.config.matching_only = true
    local c = chest(3,{goldnugget=true})
    giant("garlic_oversized")
    assert(w:GetNextAction() == nil, "Unrelated samples cannot approve giant work")
    c.components.container.has = {garlic_seeds=true}
    c.components.container.capacity = 0 now = 1
    assert(w:GetNextAction() == nil, "A full destination must not approve giant work")
    c.components.container.capacity = 40 now = 2
    assert(w:GetNextAction().action == ACTIONS.AC_HAMMER)
end

function scenarios.giant_matching_seed_sample()
    local w = worker() w.config.matching_only = true
    local c = chest(3,{garlic_seeds=true})
    local e = giant("garlic_oversized")
    for _=1,3 do
        local action = w:GetNextAction()
        assert(action.action == ACTIONS.AC_HAMMER and action.target == e)
        execute(w,action)
    end
    for _=1,2 do
        local action = w:GetNextAction()
        assert(action.action == ACTIONS.PICKUP and action.target.prefab == "garlic_seeds")
        execute(w,action)
    end
    assert(w:GetCargo().components.stackable:StackSize() == 2)
    local action = w:GetNextAction() assert(action.action == ACTIONS.STORE)
    execute(w,action)
    assert(c.components.container.stored.garlic_seeds == 2 and w:GetNextAction() == nil)
    local vegetables = 0
    for _, target in ipairs(entities) do
        if target.prefab == "garlic" and target:IsValid() then
            assert(target.components.inventoryitem.owner == nil)
            vegetables = vegetables + target.components.stackable:StackSize()
        end
    end
    assert(vegetables == 3, "Unmatched vegetables stay on the ground")
end

function scenarios.giant_matching_open_container()
    local w = worker() w.config.matching_only = true
    local c = chest(3,{garlic=true}) c.prefab = "icebox"
    local e = giant("garlic_oversized")
    c.components.container.open = true
    assert(w:GetNextAction() == nil)
    c.components.container.open = false now = 1
    local action = w:GetNextAction() assert(action.target == e)
    c.components.container.open = true
    assert(not w:ValidateAction(action), "Recheck player opening at ram contact")
end

function scenarios.delivery_full_en_route()
    local w = worker()
    local first, backup = chest(3), chest(7)
    w.inst.components.inventory:GiveItem(item("twigs",0,nil,5))
    local action = w:GetNextAction() assert(action.target == first)
    local failed = 0 action:AddFailAction(function() failed = failed + 1 end)
    w.inst.buffered = action w.inst.x = 2
    first.components.container.capacity = 0 now = .5
    w:Watchdog()
    assert(failed == 1 and w.pending == nil and w.inst.buffered == nil)
    assert(not w:IsCoolingDown(first) and w:GetCargo().components.stackable:StackSize() == 5)
    local replacement = w:GetNextAction()
    assert(replacement.target == backup and replacement.action == ACTIONS.STORE)
    execute(w,replacement)
    assert(backup.components.container.stored.twigs == 5 and w:GetCargo() == nil)
end

function scenarios.delivery_full_drop_recovers()
    local w = worker() local c = chest(3)
    local cargo = item("twigs",0,nil,5) w.inst.components.inventory:GiveItem(cargo)
    w:GetNextAction() w.inst.x = 3 c.components.container.capacity = 0 now = .5
    w:Watchdog()
    local home = w:GetNextAction()
    assert(home.action == ACTIONS.WALKTO and home.pos.x == 0 and not w.blocked)
    assert(w:GetCargo() == nil and w.pending == nil)
    assert(cargo:IsValid() and cargo.components.inventoryitem.owner == nil and cargo.x == 3)
    assert(cargo.components.stackable:StackSize() == 5 and c.components.container.stored.twigs == nil)
    local drop = w.inst.components.inventory.drops[1]
    assert(drop.item == cargo and drop.wholestack and drop.randomdir,
        "Use the same whole-stack fling flags as native GoHomeAction")
    w.inst.x = 0 now = 1
    assert(w:GetNextAction() == nil and not w.blocked)
    assert(#w.inst.components.inventory.drops == 1, "No pickup/drop loop while full")
    c.components.container.capacity = 40 now = 1.5
    local pickup = w:GetNextAction()
    assert(pickup.target == cargo and pickup.action == ACTIONS.PICKUP and not w:IsCoolingDown(c))
    execute(w,pickup)
    execute(w,w:GetNextAction()) assert(c.components.container.stored.twigs == 5)
end

function scenarios.delivery_drop_one_group()
    local w = worker() w.config.matching_only = true w:SetCarrySlots(2)
    local c = chest(3,{cutgrass=true})
    local undeliverable = item("twigs",0,nil,5)
    local deliverable = item("cutgrass",0,nil,7)
    w.inst.components.inventory:GiveItem(undeliverable)
    w.inst.components.inventory:GiveItem(deliverable)
    w.inst.x = 2
    assert(w:GetNextAction().action == ACTIONS.WALKTO)
    assert(undeliverable.components.inventoryitem.owner == nil and undeliverable.x == 2)
    assert(deliverable.components.inventoryitem.owner == w.inst and #w.inst.components.inventory.drops == 1)
    now = .5 local action = w:GetNextAction()
    assert(action.action == ACTIONS.STORE and action.invobject == deliverable)
    execute(w,action)
    assert(c.components.container.stored.cutgrass == 7 and w:GetCargo() == nil)
    assert(undeliverable.components.stackable:StackSize() == 5)
end

function scenarios.delivery_drop_active_cargo()
    local w = worker() local c = chest(3,nil,0)
    local cargo = item("twigs",0,nil,9)
    w.inst.components.inventory.active = cargo cargo.components.inventoryitem.owner = w.inst
    w.inst.x = 2
    assert(w:GetNextAction().action == ACTIONS.WALKTO and w:GetCargo() == nil)
    assert(cargo:IsValid() and cargo.components.inventoryitem.owner == nil and cargo.x == 2)
    assert(cargo.components.stackable:StackSize() == 9 and c.components.container.stored.twigs == nil)
end

function scenarios.delivery_full_at_contact()
    local w,c,state = enter_store()
    local failed = 0 w.pending.action:AddFailAction(function() failed = failed + 1 end)
    c.components.container.capacity = 0
    w.inst.sg.timeinstate = .2 state.onupdate(w.inst)
    assert(failed == 1 and w.pending == nil and w:GetCargo() ~= nil)
    assert(not w:IsCoolingDown(c) and not c.components.container:IsOpenedBy(w.inst))
    state.ontimeout(w.inst)
    local cargo = w:GetCargo()
    now = 1 assert(w:GetNextAction() == nil and w:GetCargo() == nil)
    assert(cargo:IsValid() and cargo.components.inventoryitem.owner == nil)
    c.components.container.capacity = 40
    now = 1.5 local pickup = w:GetNextAction() assert(pickup.target == cargo)
    execute(w,pickup)
    local retry = w:GetNextAction() assert(retry.target == c)
    execute(w,retry) assert(c.components.container.stored.twigs == 3)
end

function scenarios.cancel_notifies_native_action()
    local w = setup() item("twigs",1)
    local action = w:GetNextAction()
    local failed = 0 action:AddFailAction(function() failed = failed + 1 end)
    w:Cancel() w:Cancel()
    assert(failed == 1 and w.pending == nil, "Native DoAction must exit RUNNING on cancellation")
end

local function prepare_giants(w,count)
    for _=1,count do
        local action = w:GetNextAction()
        assert(action ~= nil and action.action == ACTIONS.AC_HAMMER,
            "Prepare all available giants before collecting any drops")
        execute(w,action)
        assert(w:GetCargo() == nil)
    end
end

function scenarios.giant_batch_prepare_all()
    local w = worker() w.config.matching_only = true local c = chest(4,{garlic=true})
    local a,b = giant("garlic_oversized"),giant("garlic_oversized") b.x = 2
    prepare_giants(w,6)
    assert(not a:IsValid() and not b:IsValid())
    for _=1,6 do
        local action = w:GetNextAction()
        assert(action.action == ACTIONS.PICKUP and action.target.prefab == "garlic")
        execute(w,action)
    end
    assert(w:GetCargo().components.stackable:StackSize() == 6)
    local delivery = w:GetNextAction() assert(delivery.action == ACTIONS.STORE)
    execute(w,delivery) assert(c.components.container.stored.garlic == 6)
end

function scenarios.giant_batch_mixed_groups()
    local w = worker() w.config.matching_only = true local c = chest(4,{garlic=true,carrot=true})
    local a,b = giant("garlic_oversized"),giant("carrot_oversized") b.x = 2
    prepare_giants(w,6)
    assert(not a:IsValid() and not b:IsValid())
    for _, product in ipairs({"garlic","carrot"}) do
        for _=1,3 do
            local action = w:GetNextAction()
            assert(action.action == ACTIONS.PICKUP and action.target.prefab == product)
            execute(w,action)
        end
        assert(w:GetCargo().components.stackable:StackSize() == 3)
        local action = w:GetNextAction() assert(action.action == ACTIONS.STORE)
        execute(w,action)
        assert(c.components.container.stored[product] == 3)
    end
end

function scenarios.giant_batch_stack_limit()
    local w = worker() w.config.matching_only = true local c = chest(4,{garlic=true})
    giant("garlic_oversized") local b = giant("garlic_oversized") b.x = 2
    prepare_giants(w,6)
    for _, e in ipairs(entities) do
        if e.prefab == "garlic" then e.components.stackable.maxsize = 4 end
    end
    for _=1,4 do execute(w,w:GetNextAction()) end
    assert(w:GetCargo().components.stackable:StackSize() == 4)
    local delivery = w:GetNextAction() assert(delivery.action == ACTIONS.STORE)
    execute(w,delivery) assert(c.components.container.stored.garlic == 4)
    for _=1,2 do execute(w,w:GetNextAction()) end
    delivery = w:GetNextAction() assert(delivery.action == ACTIONS.STORE)
    execute(w,delivery) assert(c.components.container.stored.garlic == 6)
end

function scenarios.giant_batch_mature_plants()
    local w = worker() w.config.matching_only = true local c = chest(4,{garlic=true})
    item("garlic",.1)
    local p = plant(2) p.tags.farm_plant = true p.is_oversized = true
    p.plant_def = {product="garlic"}
    function p.components.pickable:Pick()
        self.mature = false
        local e = giant("garlic_oversized") e.x = p.x
    end
    local action = w:GetNextAction()
    assert(action.action == ACTIONS.PICK and action.target == p)
    execute(w,action)
    prepare_giants(w,3)
    for _=1,4 do
        action = w:GetNextAction() assert(action.action == ACTIONS.PICKUP)
        execute(w,action)
    end
    action = w:GetNextAction() assert(action.action == ACTIONS.STORE)
    execute(w,action) assert(c.components.container.stored.garlic == 4)
end
