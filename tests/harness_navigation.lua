-- Only physics integration and map queries are simulated. NAV_NATIVE replaces
-- the fixture movement/action methods with the installed game's original ones.
local H = upgrade_contract
local Navigation = require("ac_navigation")
local bit = bit
local time, ground = 0, function() return true end
local pathground, pathwalls
GetTime = function() return time end
GetTick = function() return math.floor(time / FRAMES + .5) end
GetTickTime = function() return FRAMES end
DEGREES = math.pi / 180
Point = Vector3
distsq = function(x1, z1, x2, z2) return (x1 - x2)^2 + (z1 - z2)^2 end
local CHARACTERS, OBSTACLES, ITEMS = 1024, 512, 256
COLLISION = { CHARACTERS = CHARACTERS, OBSTACLES = OBSTACLES, ITEMS = ITEMS }
local platforms = {}
TheWorld = { ismastersim = true, Map = {}, Pathfinder = {} }
function TheWorld.Map:IsPassableAtPoint(x, _, z) return ground(x, z) end
function TheWorld.Map:GetPlatformAtPoint(x, _, z)
    for _, boat in ipairs(platforms) do
        if boat:IsValid() and boat:GetDistanceSqToPoint(Vector3(x,0,z)) <= boat.radius^2 then return boat end
    end
end
function TheWorld.Pathfinder:IsClear(x1, _, z1, x2, _, z2, caps)
    local samples = math.max(1, math.ceil(math.sqrt(distsq(x1,z1,x2,z2)) / .1))
    for i = 0, samples do
        local x, z = x1+(x2-x1)*i/samples, z1+(z2-z1)*i/samples
        if not (pathground or ground)(x,z)
            or (pathwalls ~= nil and not (caps ~= nil and caps.ignorewalls) and not pathwalls(x,z)) then
            return false
        end
    end
    return true
end
TheWorld.Pathfinder.SubmitSearch = function() error("Collector must not request an unbounded native search") end

local function physics(ent, radius, group, mask)
    ent.Physics = { radius = radius, group = group, mask = mask, speed = 0 }
    function ent.Physics:IsActive() return self.active ~= false end
    function ent.Physics:GetRadius() return self.radius end
    function ent.Physics:GetCollisionGroup() return self.group end
    function ent.Physics:GetCollisionMask() return self.mask end
    function ent.Physics:GetMotorSpeed() return self.speed end
    function ent.Physics:GetMotorVel() return self.speed, 0, 0 end
    function ent.Physics:SetMotorVel(speed) self.speed = speed end
    function ent.Physics:Stop() self.speed = 0 end
    function ent:GetPhysicsRadius(default) return self.Physics:GetRadius() or default end
    return ent
end
local function blocker(x, z, radius, group, mask)
    local ent = physics(H.entity("statue_marble", x), radius or .66, group or OBSTACLES, mask or CHARACTERS)
    ent.z = z or 0
    return ent
end

local function prepare(w, radius)
    local inst = physics(w.inst, radius or .25, CHARACTERS, bit.bor(CHARACTERS,OBSTACLES))
    local rotation = 0
    function inst.Transform:GetRotation() return rotation end
    function inst.Transform:SetRotation(value) rotation = value end
    function inst:GetAngleToPoint(x, _, z) return math.atan2(self.z-z,x-self.x) / DEGREES end
    inst.sg = { state = "idle" }
    function inst.sg:GoToState(name) self.state = name end
    function inst.sg:HasStateTag(tag)
        return tag == "canrotate" or (tag == "moving" and self.state == "walk")
            or (tag == "busy" and self.state == "busy")
    end
    function inst:PushBufferedAction(action)
        self.buffered = action
        self.sg.state = "busy"
    end
    inst.StartUpdatingComponent, inst.StopUpdatingComponent = function() end, function() end
    local loco = { inst = inst, arrive_step_dist = .15, ismastersim = true,
        walkspeed = w.radius == 20 and 6 or 3,
        time_before_next_hop_is_allowed = 0, pathcaps = { allowocean = false } }
    function loco:WaitingForPathSearch() return self.path ~= nil and self.path.handle end
    function loco:StartUpdatingInternal() end
    function loco:StopUpdatingInternal() end
    function loco:StartMoveTimerInternal() end
    function loco:StopMoveTimerInternal() end
    function loco:CancelPredictMoveTimer() end
    function loco:CheckDrownable() return false end
    function loco:GetSpeedMultiplier() return 1 end
    function loco:GetRunSpeed() return 6 end
    function loco:GetWalkSpeed() return w.radius == 20 and 6 or 3 end
    function loco:WantsToMoveForward() return self.wantstomoveforward == true end
    function loco:WantsToRun() return self.wantstorun == true end
    function loco:SetMotorSpeed(speed) inst.Physics.speed = speed end
    function loco:WalkForward() self:SetMotorSpeed(self:GetWalkSpeed()) end
    function loco:FaceMovePoint() end
    function loco:SetMoveDir(dir) inst.Transform:SetRotation(dir) end
    function loco:StopMoving() inst.Physics:Stop() end
    function loco:ResetPath() self.path = nil end
    function loco:Stop()
        self:ResetPath() self.dest = nil self.wantstomoveforward = false self:StopMoving()
        self.isupdating = nil
        inst:PushEvent("locomote")
    end
    function loco:Clear()
        self.dest = nil self.wantstomoveforward = false
        if self.bufferedaction ~= nil then self.bufferedaction:Fail() end
        self.bufferedaction = nil
    end
    function loco:GoToEntity(target, action)
        self.isupdating = true
        self.bufferedaction = action
        self.arrive_dist = action.arrivedist or (.15 + inst:GetPhysicsRadius(0) + target:GetPhysicsRadius(0))
        self.dest = { IsValid = function() return target:IsValid() end,
            GetPoint = function() return target.Transform:GetWorldPosition() end }
        self.wantstomoveforward = true self:FindPath() self:OnUpdate(0,true)
    end
    function loco:GoToPoint(point, action)
        self.isupdating = true
        self.dest = { IsValid = function() return true end, GetPoint = function() return point:Get() end }
        self.arrive_dist = .5 self.bufferedaction = action
        self.wantstomoveforward = true self:FindPath() self:OnUpdate(0,true)
    end
    function loco:OnUpdate(_, arrive_check_only)
        if self.dest == nil then return end
        local x, _, z = self.dest:GetPoint()
        if distsq(inst.x,inst.z,x,z) <= self.arrive_dist^2 then
            inst:PushBufferedAction(self.bufferedaction) self.bufferedaction = nil
            self:Stop() self:Clear() return
        end
        if arrive_check_only then return end
        inst:PushEvent("locomote")
        local path = self.path
        if path ~= nil and path.currentstep < #path.steps then
            local point = path.steps[path.currentstep]
            if distsq(inst.x,inst.z,point.x,point.z) <= .7^2 + .15^2 then
                path.currentstep = path.currentstep + 1
            end
            if path.currentstep < #path.steps then
                x, z = path.steps[path.currentstep].x, path.steps[path.currentstep].z
            end
        end
        self:SetMoveDir(inst:GetAngleToPoint(x,0,z))
    end
    if NAV_NATIVE ~= nil then
        for name, fn in pairs(NAV_NATIVE) do loco[name] = fn end
    end
    local push = inst.PushEvent
    function inst:PushEvent(name, data)
        push(self,name,data)
        if name == "locomote" and not self.sg:HasStateTag("busy") then
            self.sg.state = loco.wantstomoveforward and "walk" or "idle"
        end
    end
    inst.components.locomotor = loco
    Navigation.Attach(inst)
    return loco
end

local function begin(w, before, wait_for_search)
    w.inst.sg.state, w.inst.buffered = "idle", nil
    local action = w:GetNextAction()
    assert(action ~= nil, "Expected a collector action")
    if before ~= nil then before(action) end
    if action.target ~= nil then
        if action.target.GetPhysicsRadius == nil then
            function action.target:GetPhysicsRadius(default) return default end
        end
        w.inst.components.locomotor:GoToEntity(action.target,action,false)
    else
        w.inst.components.locomotor:GoToPoint(action.pos,action,false)
    end
    if wait_for_search ~= false then
        local loco = w.inst.components.locomotor
        for _ = 1, 2000 do
            local state = loco._ac_navigation
            if state == nil or not state.searching then break end
            time = time + FRAMES
            loco:OnUpdate(FRAMES)
        end
        assert(loco._ac_navigation == nil or not loco._ac_navigation.searching,
            "A single search must finish within the fixture budget")
    end
    return action
end

local function tick(w, frozen, before)
    time = time + FRAMES
    if before ~= nil then before() end
    local inst, loco = w.inst, w.inst.components.locomotor
    loco:OnUpdate(FRAMES)
    if loco.dest == nil or frozen then return end
    local radius = loco._ac_navigation.radius
    local rotation = inst.Transform:GetRotation() * DEGREES
    local speed = inst.Physics.speed
    local x, z = inst.x + math.cos(rotation)*speed*FRAMES, inst.z - math.sin(rotation)*speed*FRAMES
    local canmove = inst.platform ~= nil and TheWorld.Map:GetPlatformAtPoint(x,0,z) == inst.platform or ground(x,z)
    for _, ent in ipairs(TheSim:FindEntities(x,0,z,4)) do
        local other = ent.Physics
        if ent ~= inst and other ~= nil and other:IsActive()
            and bit.band(other:GetCollisionMask(), inst.Physics:GetCollisionGroup()) ~= 0
            and bit.band(inst.Physics:GetCollisionMask(), other:GetCollisionGroup()) ~= 0 then
            canmove = canmove and distsq(x,z,ent.x,ent.z) >= (other:GetRadius()+inst.Physics:GetRadius())^2
        end
    end
    if canmove then inst.x, inst.z = x, z end
    assert(inst:GetDistanceSqToPoint(w:GetHome()) <= (radius+.01)^2, "Movement left the permitted work range")
end

local function arrive(w, before)
    for _ = 1, 550 do
        tick(w,false,before)
        if w.inst.buffered ~= nil then return w.inst.buffered end
        assert(w.inst.components.locomotor.dest ~= nil, string.format(
            "Navigation failed before arrival at %.3f,%.3f after %.3fs", w.inst.x,w.inst.z,time))
    end
    error("Collector did not arrive")
end
local function deliver(w, action)
    assert(arrive(w) == action and w:ValidateAction(action))
    w:PerformAction(action)
    assert(w.pending == nil and w:GetCargo() == nil)
end

function scenarios.navigation_river_outside_range()
    local w = H.worker(-4) local loco = prepare(w)
    local c = physics(H.chest(5), .5, OBSTACLES, CHARACTERS)
    local cargo = H.item("rocks",-4,nil,16) w.inst.components.inventory:GiveItem(cargo)
    ground = function(x,z) return x < -.5 or x > .5 or math.abs(z) > 30 end
    local action = begin(w)
    if loco.dest ~= nil then tick(w) end
    assert(action.target == c and w.pending == nil and loco.dest == nil and not loco.wantstomoveforward)
    assert(w:IsCoolingDown(c) and w:GetCargo() == cargo and cargo.components.stackable:StackSize() == 16)
    local nearby = H.chest(-7)
    time = time + .6
    assert(w:GetNextAction().target == nearby and w.inst.x == -4)
end

function scenarios.navigation_river_inside_range()
    local w = H.worker(-4) local loco = prepare(w)
    local c = physics(H.chest(5), .5, OBSTACLES, CHARACTERS)
    local cargo = H.item("rocks",-4,nil,16) w.inst.components.inventory:GiveItem(cargo)
    ground = function(x,z) return x < -.5 or x > .5 or math.abs(z) > 4 end
    local action = begin(w)
    assert(#loco.path.steps > 3)
    deliver(w,action)
    assert(c.components.container.stored.rocks == 16)
end

function scenarios.navigation_statue_detour()
    local w = H.worker() local loco = prepare(w) H.chest(8)
    blocker(4,0,.66)
    local cargo = H.item("rocks",0,nil,16) w.inst.components.inventory:GiveItem(cargo)
    local action = begin(w)
    assert(#loco.path.steps > 3)
    deliver(w,action)
end

function scenarios.navigation_collision_masks()
    local w = H.worker() local loco = prepare(w) H.chest(8)
    blocker(4,0,2,ITEMS,OBSTACLES)
    blocker(5,0,2).Physics.active = false
    local cargo = H.item("rocks",0) w.inst.components.inventory:GiveItem(cargo)
    local action = begin(w)
    assert(#loco.path.steps == 3, "Non-colliding and inactive physics must not obstruct the route")
    deliver(w,action)
end

local function narrow_corridor(startx)
    local w = H.worker(startx) w.inst.z = -3 w:SetHome()
    local loco = prepare(w,.25)
    local c = physics(H.chest(.4),.3,OBSTACLES,CHARACTERS) c.z = 4
    for z = 0, 6 do blocker(-.6,z,.5) blocker(1.4,z,.5) end
    blocker(.4,6,.5)
    w.inst.components.inventory:GiveItem(H.item("rocks",startx,nil,7))
    return w,loco,c
end

function scenarios.navigation_narrow_offset_corridor()
    local w,loco,c = narrow_corridor(0)
    local action = begin(w)
    assert(loco.dest ~= nil, "The .5-diameter cart must find the off-grid, 1-unit-wide corridor")
    deliver(w,action)
    assert(c.components.container.stored.rocks == 7)
end

function scenarios.navigation_narrow_wall_path_tiles()
    local w,loco,c = narrow_corridor(.4)
    -- Wall path tiles can cover physically clear space beside their round bodies.
    pathwalls = function(x,z) return z < -.5 or z > 6.5 or x < -1.5 or x > 2.5 end
    local action = begin(w)
    assert(loco.dest ~= nil, "Coarse wall path tiles must not close a physically clear corridor")
    assert(loco.path ~= nil and #loco.path.steps == 3)
    assert(loco.pathcaps.ignorewalls == nil, "Native locomotor capabilities must not be mutated")
    deliver(w,action)
    assert(c.components.container.stored.rocks == 7)
end

function scenarios.navigation_narrow_closed_corridor()
    local w,loco,c = narrow_corridor(0)
    blocker(.4,1,.5)
    pathwalls = function() return false end
    begin(w)
    if loco.dest ~= nil then tick(w,true) end
    assert(w.pending == nil and loco.dest == nil and w:IsCoolingDown(c),
        "Wall tile precision must not let a cart cross a real physical wall")
    assert(w:GetCargo().components.stackable:StackSize() == 7)
end

local function moonbase_tile()
    -- A 4x4 tile, walls immediately outside its boundary, and the native
    -- moonbase's radius-1 body at its centre. Start between coarse grid lines.
    blocker(0,0,1)
    for i = 0, 5 do
        local offset = i - 2.5
        blocker(offset,-2.5,.5) blocker(offset,2.5,.5)
        blocker(-2.5,offset,.5) blocker(2.5,offset,.5)
    end
    local c = physics(H.chest(.4),.3,OBSTACLES,CHARACTERS) c.z = 1.5
    return c
end

function scenarios.navigation_moonbase_walled_tile()
    local c = moonbase_tile()
    local w = H.worker(.375) w.inst.z = -1.625 w:SetHome()
    local loco = prepare(w,.25)
    w.inst.components.inventory:GiveItem(H.item("rocks",.4,nil,7))
    local action = begin(w)
    assert(loco.dest ~= nil, "The cart must use the real clearance between a moonbase and surrounding walls")
    deliver(w,action)
    assert(c.components.container.stored.rocks == 7)
end

function scenarios.navigation_moonbase_shared_refinement()
    moonbase_tile()
    local cars, calls, tick_id, maximum = {}, 0, GetTick(), 0
    local clear = TheWorld.Pathfinder.IsClear
    TheWorld.Pathfinder.IsClear = function(self, ...)
        if GetTick() ~= tick_id then tick_id, calls = GetTick(), 0 end
        calls = calls + 1 maximum = math.max(maximum,calls)
        assert(calls <= 1200, "Fine-grid fallback must share the same frame budget across all carts")
        return clear(self, ...)
    end
    for _ = 1, 8 do
        local w = H.worker(.375) w.inst.z = -1.625 w:SetHome()
        local loco = prepare(w,.25)
        w.inst.components.inventory:GiveItem(H.item("rocks",.375,nil,7))
        begin(w,nil,false)
        table.insert(cars,{worker=w,loco=loco})
    end
    local completed = 0
    for _ = 1, 300 do
        time = time + FRAMES
        for _, car in ipairs(cars) do
            if not car.done then
                car.loco:OnUpdate(FRAMES)
                assert(car.worker.pending ~= nil, "Every cart must find the narrow route")
                if not car.loco._ac_navigation.searching then
                    assert(car.loco.path ~= nil and car.worker:GetCargo().components.stackable:StackSize() == 7)
                    car.worker:Cancel(true)
                    car.done, completed = true, completed + 1
                end
            end
        end
        if completed == #cars then break end
    end
    assert(completed == 8, "No fine-grid search may starve behind the other carts")
    TheWorld.Pathfinder.IsClear = clear
    return {maximum=maximum,cars=completed}
end

function scenarios.navigation_shared_search_budget()
    local cars, calls, maximum, total = {}, 0, 0, 0
    local clear = TheWorld.Pathfinder.IsClear
    TheWorld.Pathfinder.IsClear = function(self, ...)
        calls = calls + 1
        return clear(self, ...)
    end
    H.chest(5)
    ground = function(x,z) return x < -.5 or x > .5 end
    for _ = 1, 8 do
        local w = H.worker(-4) local loco = prepare(w)
        w.inst.components.inventory:GiveItem(H.item("rocks",-4,nil,7))
        table.insert(cars, {worker=w,loco=loco})
        begin(w,nil,false)
    end
    assert(calls <= 1200, "Coincident placements exceeded the frame budget: " .. tostring(calls))
    maximum, total = calls, calls
    local waiting = 0
    for _, car in ipairs(cars) do
        if car.loco._ac_navigation ~= nil and car.loco._ac_navigation.searching then waiting = waiting + 1 end
    end
    assert(waiting > 0, "Expensive searches must yield instead of blocking the simulation")
    local completed = 0
    for _ = 1, 600 do
        time = time + FRAMES calls = 0
        for _, car in ipairs(cars) do
            if car.loco.dest ~= nil then car.loco:OnUpdate(FRAMES) end
        end
        assert(calls <= 1200, "All collectors must share the same per-frame search budget")
        maximum, total = math.max(maximum,calls), total + calls
    end
    for _, car in ipairs(cars) do
        assert(car.worker.pending == nil, "Round-robin search must eventually service every car")
        assert(car.worker:GetCargo().components.stackable:StackSize() == 7)
        completed = completed + 1
    end
    assert(completed == #cars)
    TheWorld.Pathfinder.IsClear = clear
    return {maximum=maximum,total=total,cars=#cars}
end

function scenarios.navigation_queued_search_capacity_changes()
    H.chest(5)
    ground = function(x,z) return x < -.5 or x > .5 end
    local busy = H.worker(-4) prepare(busy)
    busy.inst.components.inventory:GiveItem(H.item("rocks",-4))
    begin(busy,nil,false)
    local w = H.worker(-4) local loco = prepare(w)
    local c = H.chest(-6) local cargo = H.item("twigs",-4,nil,7)
    w.inst.components.inventory:GiveItem(cargo)
    local failures = 0
    local action = begin(w,function(a) a:AddFailAction(function() failures = failures + 1 end) end,false)
    assert(action.target == c and loco._ac_navigation.searching)
    c.components.container.capacity = 0 w:Watchdog()
    assert(w.pending == nil and loco.dest == nil and failures == 1 and not w:IsCoolingDown(c))
    for _ = 1, 240 do time = time + FRAMES busy.inst.components.locomotor:OnUpdate(FRAMES) end
    assert(w:GetCargo() == cargo and loco.path == nil and failures == 1)
end

function scenarios.navigation_cancel_queued_search()
    H.chest(5)
    ground = function(x,z) return x < -.5 or x > .5 end
    local busy = H.worker(-4) prepare(busy)
    busy.inst.components.inventory:GiveItem(H.item("rocks",-4))
    begin(busy,nil,false)
    local w = H.worker(-4) local loco = prepare(w)
    local cargo = H.item("rocks",-4,nil,7) w.inst.components.inventory:GiveItem(cargo)
    local failures = 0
    begin(w,function(action) action:AddFailAction(function() failures = failures + 1 end) end,false)
    assert(loco._ac_navigation ~= nil and loco._ac_navigation.searching)
    w:Cancel(true) w.inst.held = true
    for _ = 1, 240 do time = time + FRAMES busy.inst.components.locomotor:OnUpdate(FRAMES) end
    assert(loco.dest == nil and loco.path == nil and loco._ac_navigation == nil and failures == 1)
    assert(w:GetCargo() == cargo and cargo.components.stackable:StackSize() == 7)
end

function scenarios.navigation_crowded_collectors()
    local w = H.worker() local loco = prepare(w) H.chest(8)
    local peer = H.worker(4) prepare(peer)
    w.inst.components.inventory:GiveItem(H.item("rocks",0,nil,7))
    local action = begin(w)
    assert(#loco.path.steps == 3, "Other collectors must not trigger expensive static detours")
    peer.inst.z = 3 -- Native character physics can separate/yield; no ghosting is introduced.
    deliver(w,action)
end

function scenarios.navigation_delivery_waits_for_route()
    local w = H.worker(-4) prepare(w) local c = H.chest(5)
    local cargo = H.item("rocks",-4,nil,7) w.inst.components.inventory:GiveItem(cargo)
    ground = function(x,z) return x < -.5 or x > .5 end
    for _ = 1, 3 do
        begin(w)
        if w.inst.components.locomotor.dest ~= nil then tick(w,true) end
        assert(w.pending == nil and w:IsCoolingDown(c))
        time = time + .01 w.nextscan = 0
        assert(w:GetNextAction(false) == nil)
        assert(w:GetCargo() == cargo and w.blocked and w.inst.components.inventory.drops == nil,
            "An accepting but unreachable chest must not cause pickup/drop ping-pong")
        assert(cargo.components.inventoryitem.owner == w.inst)
        time = w.cooldowns[c] + .01
    end
    ground = function() return true end
    deliver(w,begin(w))
    assert(c.components.container.stored.rocks == 7 and not w.blocked)
end

function scenarios.navigation_enclosed_cargo_conservation()
    local passable = TheWorld.Map.IsPassableAtPoint
    local calls, maximum, tick_id = 0, 0, GetTick()
    TheWorld.Map.IsPassableAtPoint = function(self, ...)
        if GetTick() ~= tick_id then tick_id, calls = GetTick(), 0 end
        calls = calls + 1 maximum = math.max(maximum,calls)
        return passable(self, ...)
    end
    local cars, walls = {}, {}
    local c = physics(H.chest(5),.5,OBSTACLES,CHARACTERS)
    for step = -4, 4 do
        local offset = step * .5
        for _, point in ipairs({{offset,2},{offset,-2},{2,offset},{-2,offset}}) do
            table.insert(walls,blocker(point[1],point[2],.4))
        end
    end
    for i = 1, 8 do H.item("rocks",i*.05,nil,5) end
    for _ = 1, 8 do
        local w = H.worker() local loco = prepare(w)
        local action = begin(w)
        assert(action.action == ACTIONS.PICKUP and w.inst.buffered == action)
        w:PerformAction(action)
        table.insert(cars,{worker=w,loco=loco})
    end
    for _ = 1, 300 do
        time = time + FRAMES
        for _, car in ipairs(cars) do
            local w, loco = car.worker, car.loco
            if loco.dest ~= nil then loco:OnUpdate(FRAMES) end
            if w.pending == nil then
                local action = w:GetNextAction(false)
                if action ~= nil then loco:GoToEntity(action.target,action,false) end
            end
            assert(w:GetCargo() ~= nil and w:GetCargo().components.stackable:StackSize() == 5,
                "Walls must not create a multi-car pickup/drop cycle")
            assert(w.inst.components.inventory.drops == nil)
        end
    end
    for _, wall in ipairs(walls) do wall.Physics.active = false end
    for _, car in ipairs(cars) do car.worker.inst.z = 3 end
    for _, car in ipairs(cars) do
        local w = car.worker
        time = math.max(time + .3, (w.cooldowns[c] or 0) + .01)
        w.inst.z = 0 -- The other carts yield through native physics in game.
        deliver(w,begin(w))
        w.inst.z = 3
        assert(w:GetCargo() == nil and w.inst.components.inventory.drops == nil)
    end
    assert(c.components.container.stored.rocks == 40,
        "Opening the enclosure must resume delivery without losing or duplicating cargo")
    TheWorld.Map.IsPassableAtPoint = passable
    return { maximum_ground=maximum, stored=c.components.container.stored.rocks }
end

local function refreshing_cars(count)
    local cars = {}
    H.chest(8)
    for _ = 1, count do
        local w = H.worker() local loco = prepare(w)
        w.inst.components.inventory:GiveItem(H.item("rocks",0,nil,7))
        local action = begin(w)
        table.insert(cars,{worker=w,loco=loco,action=action,context=loco._ac_navigation.context})
    end
    return cars
end

function scenarios.navigation_refresh_budget()
    for i = 1, 120 do blocker(i%10-5,4+math.floor(i/10)*.25,.1) end
    for _ = 1, 500 do H.entity("decoration",2) end
    local cars = refreshing_cars(8)
    local find = TheSim.FindEntities
    local scans, entities, max_scans, max_entities, tick_id = 0, 0, 0, 0, GetTick()
    TheSim.FindEntities = function(self, ...)
        local result = find(self, ...)
        if GetTick() ~= tick_id then tick_id, scans, entities = GetTick(), 0, 0 end
        scans, entities = scans+1, entities+#result
        max_scans, max_entities = math.max(max_scans,scans), math.max(max_entities,entities)
        return result
    end
    time = (GetTick()+8)*FRAMES -- First simulation tick after the .25-second recheck interval.
    local refreshed, frames = 0, 0
    for frame = 1, 16 do
        for _, car in ipairs(cars) do
            if not car.done then
                car.loco:OnUpdate(FRAMES)
                assert(car.worker.pending.action == car.action)
                if car.loco._ac_navigation.context ~= car.context then
                    car.done, refreshed = true, refreshed+1
                else
                    assert(car.loco._ac_navigation.refreshing and car.worker.inst.Physics.speed == 0,
                        "Rechecks waiting for their turn must stop instead of using an expired snapshot")
                    car.loco:SetMotorSpeed(6)
                    assert(car.worker.inst.Physics.speed == 0, "Animations cannot restart a waiting cart")
                end
            end
        end
        frames = frame
        if refreshed == #cars then break end
        time = time+FRAMES
    end
    TheSim.FindEntities = find
    assert(refreshed == #cars, "Every cart must receive a recheck without starvation")
    return {maximum_scans=max_scans,maximum_entities=max_entities,frames=frames,cars=refreshed}
end

function scenarios.navigation_cancel_queued_refresh()
    local cars = refreshing_cars(2)
    time = time+.25
    for _, car in ipairs(cars) do car.loco:OnUpdate(FRAMES) end
    local waiting = cars[2]
    assert(waiting.loco._ac_navigation.refreshing)
    local failures = 0 waiting.action:AddFailAction(function() failures = failures+1 end)
    local cargo = waiting.worker:GetCargo()
    waiting.worker:Cancel(true)
    for _ = 1, 10 do time = time+FRAMES cars[1].loco:OnUpdate(FRAMES) end
    assert(waiting.loco._ac_navigation == nil and waiting.loco.dest == nil and waiting.loco.path == nil)
    assert(failures == 1 and waiting.worker:GetCargo() == cargo)
end

function scenarios.navigation_refresh_wait_not_stuck()
    local cars = refreshing_cars(2)
    time = time+.25
    for _, car in ipairs(cars) do car.loco:OnUpdate(FRAMES) end
    local waiting = cars[2]
    assert(waiting.loco._ac_navigation.refreshing)
    local path = waiting.loco.path
    time = time+2
    waiting.loco:OnUpdate(FRAMES)
    assert(waiting.loco.path == path and waiting.loco._ac_navigation.retries == 0,
        "Deliberate recheck waiting must not be counted as a physical stall")
    assert(not waiting.loco._ac_navigation.refreshing and not waiting.loco._ac_navigation_paused)
end

function scenarios.navigation_refresh_obstacles_change()
    local cars = refreshing_cars(2)
    time = time+.25
    for _, car in ipairs(cars) do car.loco:OnUpdate(FRAMES) end
    local waiting = cars[2]
    assert(waiting.loco._ac_navigation.refreshing)
    local path = waiting.loco.path
    blocker(4,0,1)
    cars[1].worker.inst.z = 3
    time = (GetTick()+1)*FRAMES
    waiting.loco:OnUpdate(FRAMES)
    assert(waiting.loco._ac_navigation.searching or waiting.loco.path ~= path,
        "A refreshed snapshot must replan before moving toward a newly placed obstacle")
    deliver(waiting.worker,waiting.action)
end

function scenarios.navigation_refresh_with_busy_search()
    local cars = refreshing_cars(2)
    H.chest(108)
    local busy = H.worker(100) local busy_loco = prepare(busy)
    busy.inst.components.inventory:GiveItem(H.item("rocks",100,nil,7))
    ground = function(x) return x < 103.5 or x > 104.5 end
    begin(busy,nil,false)
    time = (GetTick()+8)*FRAMES
    busy_loco:OnUpdate(FRAMES)
    assert(busy_loco._ac_navigation.searching)
    for _, car in ipairs(cars) do
        car.loco:OnUpdate(FRAMES)
        assert(car.loco._ac_navigation.refreshing)
    end
    for i = 1, #cars do
        time = time+FRAMES
        busy_loco:OnUpdate(FRAMES)
        cars[i].loco:OnUpdate(FRAMES)
        assert(cars[i].loco._ac_navigation.context ~= cars[i].context,
            "Searches must reserve a budget turn for queued rechecks")
    end
end

function scenarios.navigation_waiting_delivery_loses_capacity()
    local w = H.worker(-4) prepare(w) local c = H.chest(5)
    local cargo = H.item("rocks",-4,nil,7) w.inst.components.inventory:GiveItem(cargo)
    ground = function(x,z) return x < -.5 or x > .5 end
    begin(w)
    if w.inst.components.locomotor.dest ~= nil then tick(w,true) end
    time = time + .01 w.nextscan = 0
    assert(w:GetNextAction(false) == nil and w:GetCargo() == cargo)
    c.components.container.capacity = 0 time = time + .5
    assert(w:GetNextAction(false) == nil and w:GetCargo() == nil)
    assert(#w.inst.components.inventory.drops == 1 and cargo:IsValid()
        and cargo.components.stackable:StackSize() == 7 and cargo.components.inventoryitem.owner == nil)
    assert(H.worker(-4):GetPickupCount(cargo) == 0)
end

function scenarios.navigation_home_retry_backoff()
    local w = H.worker(-4) prepare(w) w.inst.x = 5
    ground = function(x,z) return x < -.5 or x > .5 end
    for _, delay in ipairs({.5,1,2,4,8,10}) do
        begin(w)
        if w.inst.components.locomotor.dest ~= nil then tick(w,true) end
        assert(w.pending == nil and w.inst.components.locomotor.dest == nil)
        assert(math.abs(w.nextreturn-time-delay) < .00001,
            "Unreachable home must use increasing backoff without blocking new work")
        assert(w:GetHomeAction() == nil)
        time = w.nextreturn + .01
    end
    H.chest(7) local target = H.item("rocks",6)
    local action = begin(w)
    assert(action.target == target and arrive(w) == action)
end

function scenarios.navigation_chest_approach()
    local w = H.worker() local loco = prepare(w)
    local c = physics(H.chest(8), .5, OBSTACLES, CHARACTERS)
    w.inst.components.inventory:GiveItem(H.item("rocks",0,nil,7))
    local action = begin(w)
    assert(#loco.path.steps == 3)
    deliver(w,action)
    assert(c.components.container.stored.rocks == 7 and w.inst.x < c.x)
end

function scenarios.navigation_dynamic_obstacle()
    local w = H.worker() local loco = prepare(w) H.chest(8)
    w.inst.components.inventory:GiveItem(H.item("rocks",0,nil,7))
    local action = begin(w)
    for _ = 1, 10 do tick(w) end
    blocker(4,0,1)
    local oldpath = loco.path
    deliver(w,action)
    assert(loco.path ~= oldpath and not w:IsCoolingDown(action.target))
end

function scenarios.navigation_stuck_recovery()
    local w = H.worker() local loco = prepare(w) local c = H.chest(8)
    local cargo = H.item("rocks",0,nil,7) w.inst.components.inventory:GiveItem(cargo)
    begin(w)
    for _ = 1, 190 do tick(w,true) end
    assert(w.pending == nil and loco.dest == nil and w:IsCoolingDown(c) and w:GetCargo() == cargo)
    assert(time < w.config.action_timeout and w.inst.x == 0)
end

function scenarios.navigation_pickup_tolerance()
    local w = H.worker() local loco = prepare(w) H.chest(5)
    local drop = H.item("rocks",13,nil,7)
    local action = begin(w)
    assert(action.target == drop and loco._ac_navigation.radius == 14)
    assert(arrive(w) == action and w:ValidateAction(action)) w:PerformAction(action)
    assert(w:GetCargo() == drop and drop.components.stackable:StackSize() == 7)
    time = time + .6
    local store = begin(w)
    deliver(w,store)
end

function scenarios.navigation_character_on_drop()
    -- A character standing on the drop can yield. Keep the travel corridor
    -- clear, but permit pickup within the native action's arrival distance.
    local w = H.worker() prepare(w) H.chest(5)
    local target = H.item("rocks",8,nil,7)
    blocker(8,0,.5,CHARACTERS,bit.bor(CHARACTERS,OBSTACLES))
    local action = begin(w)
    assert(action.target == target and w.pending ~= nil and not w:IsCoolingDown(target),
        "A character standing on a drop must not park the target")
    assert(arrive(w) == action and w:ValidateAction(action))
    w:PerformAction(action)
    assert(w:GetCargo() == target and target.components.stackable:StackSize() == 7)
    time = time + .6
    deliver(w,begin(w))
end

function scenarios.navigation_path_failure_retry_backoff()
    local w = H.worker(-4) prepare(w) H.chest(-7)
    local target = H.item("rocks",5,nil,7)
    ground = function(x,z) return x < -.5 or x > .5 or math.abs(z) > 30 end
    for _, expected in ipairs({"0.50","1.00","2.00","4.00","8.00","10.00","10.00"}) do
        begin(w)
        if w.inst.components.locomotor.dest ~= nil then tick(w) end
        assert(w.pending == nil and w:IsCoolingDown(target)
            and target.components.stackable:StackSize() == 7)
        assert(w:GetDebugString():find("retry_in=" .. expected,1,true),
            "Repeated plan failures must back off to " .. expected .. ": " .. w:GetDebugString())
        time = w.cooldowns[target] + .01
    end
end

function scenarios.navigation_home_detour()
    local w = H.worker() local loco = prepare(w) w.inst.x = 8
    blocker(4,0,1)
    local action = begin(w)
    assert(action.action == ACTIONS.WALKTO and w.pending == nil and #loco.path.steps > 3)
    assert(arrive(w) == action and w.inst:GetDistanceSqToPoint(w:GetHome()) <= 1)
end

local function boat_worker()
    local boat = H.entity("boat",50) boat.z, boat.radius = 30, 4
    boat.angle = 0
    boat.entity = {
        WorldToLocalSpace = function(_,x,y,z)
            local dx,dz = x-boat.x,z-boat.z
            return dx*math.cos(boat.angle)+dz*math.sin(boat.angle),y,
                -dx*math.sin(boat.angle)+dz*math.cos(boat.angle)
        end,
        LocalToWorldSpace = function(_,x,y,z)
            return boat.x+x*math.cos(boat.angle)-z*math.sin(boat.angle),y,
                boat.z+x*math.sin(boat.angle)+z*math.cos(boat.angle)
        end,
    }
    table.insert(platforms,boat)
    local w = H.worker(50) w.inst.z, w.inst.platform = 30, boat w:SetHome()
    local loco = prepare(w)
    local c = H.chest(53) c.z, c.platform = 30, boat
    local obstacle = blocker(51.5,30,.5) obstacle.platform = boat
    local cargo = H.item("rocks",50,nil,7) w.inst.components.inventory:GiveItem(cargo)
    ground = function() return false end
    return w,loco,boat,c,obstacle,cargo
end

function scenarios.navigation_boat_moves()
    local w,loco,boat,c,obstacle = boat_worker()
    local action = begin(w)
    local function moveboat()
        local localpoints = {}
        for _, ent in ipairs({w.inst,c,obstacle}) do
            table.insert(localpoints,{ ent = ent, point = Vector3(boat.entity:WorldToLocalSpace(ent:GetPosition():Get())) })
        end
        boat.x, boat.z, boat.angle = boat.x+.04, boat.z+.02, boat.angle+.01
        for _, entry in ipairs(localpoints) do
            entry.ent.x, _, entry.ent.z = boat.entity:LocalToWorldSpace(entry.point:Get())
        end
    end
    assert(arrive(w,moveboat) == action and w:ValidateAction(action)) w:PerformAction(action)
    assert(c.components.container.stored.rocks == 7 and loco._ac_navigation == nil)
end

function scenarios.navigation_boat_stuck()
    local w,loco,boat,c,obstacle,cargo = boat_worker()
    begin(w)
    for _ = 1, 190 do
        tick(w,true,function()
            for _, ent in ipairs({boat,w.inst,c,obstacle}) do ent.x = ent.x+.04 end
        end)
    end
    assert(w.pending == nil and loco.dest == nil and w:GetCargo() == cargo and w:IsCoolingDown(c))
end

local function queued_boat_worker()
    local w,loco,boat,c,obstacle,cargo = boat_worker()
    boat.radius, w.radius = 12, 20
    w.inst.x, c.x = 41, 59
    w:SetHome()
    obstacle.x, obstacle.Physics.radius = 50, 7
    local action = begin(w,nil,false)
    assert(loco._ac_navigation.searching, "This detour must span multiple simulation frames")
    return w,loco,boat,c,obstacle,cargo,action
end

function scenarios.navigation_queued_boat_moves()
    local w,loco,boat,c,obstacle,_,action = queued_boat_worker()
    local plans = 0
    w.Trace = function(_, event) if event == "path_found" then plans = plans + 1 end end
    local function moveboat()
        local localpoints = {}
        for _, ent in ipairs({w.inst,c,obstacle}) do
            table.insert(localpoints,{ent=ent,point=Vector3(boat.entity:WorldToLocalSpace(ent:GetPosition():Get()))})
        end
        boat.x, boat.z, boat.angle = boat.x+.3, boat.z+.1, boat.angle+.02
        for _, entry in ipairs(localpoints) do
            local x, _, z = boat.entity:LocalToWorldSpace(entry.point:Get())
            entry.ent.x, entry.ent.z = x, z
        end
    end
    assert(arrive(w,moveboat) == action and w:ValidateAction(action))
    w:PerformAction(action)
    assert(c.components.container.stored.rocks == 7 and loco._ac_navigation == nil)
    assert(plans == 1, "A moving boat must not invalidate an in-progress local route")
end

function scenarios.navigation_queued_platform_removed()
    local w,loco,boat,_,_,cargo = queued_boat_worker()
    boat:Remove()
    boat.entity.LocalToWorldSpace = function() error("Do not transform through a removed platform") end
    boat.entity.WorldToLocalSpace = boat.entity.LocalToWorldSpace
    tick(w,true)
    assert(w.pending == nil and loco.dest == nil and w:GetCargo() == cargo)
end

function scenarios.navigation_queued_refresh_platform_removed()
    local cars = refreshing_cars(1)
    local w,loco,boat,_,_,cargo = boat_worker()
    ground = function() return true end
    begin(w)
    time = math.max(cars[1].loco._ac_navigation.nextcheck,loco._ac_navigation.nextcheck)+FRAMES
    cars[1].loco:OnUpdate(FRAMES)
    loco:OnUpdate(FRAMES)
    assert(loco._ac_navigation.refreshing)
    boat:Remove()
    boat.entity.LocalToWorldSpace = function() error("Queued rechecks must not transform a removed platform") end
    boat.entity.WorldToLocalSpace = boat.entity.LocalToWorldSpace
    time = time+FRAMES
    loco:OnUpdate(FRAMES)
    assert(w.pending == nil and loco.dest == nil and w:GetCargo() == cargo)
end

function scenarios.navigation_queued_obstacles_change()
    local w,loco,boat = queued_boat_worker()
    -- Enclose the stationary car after its search has taken the old snapshot.
    for step = -3, 3 do
        local offset = step * .5
        for _, point in ipairs({{offset,1.5},{offset,-1.5},{1.5,offset},{-1.5,offset}}) do
            local wall = blocker(41+point[1],30+point[2],.4) wall.platform = boat
        end
    end
    for _ = 1, 300 do
        tick(w,true)
        if loco.dest == nil then break end
        assert(w.inst.Physics.speed == 0,
            "A completed search must recheck new obstacles before starting its motor")
    end
    assert(loco.dest == nil and w:GetCargo() ~= nil)
end

function scenarios.navigation_cancel_and_retry()
    local w = H.worker() local loco = prepare(w) H.chest(8)
    blocker(4,0,1) local drop = H.item("rocks",8,nil,7)
    local action = begin(w)
    local failures = 0 action:AddFailAction(function() failures = failures + 1 end)
    w:Cancel()
    assert(failures == 1 and loco.path == nil and loco._ac_navigation == nil)
    assert(drop.components.stackable:StackSize() == 7 and w:IsCoolingDown(drop))
    time = w.config.retry_delay + 1
    local retry = begin(w)
    assert(retry.target == drop and arrive(w) == retry and w:ValidateAction(retry))
    w:PerformAction(retry)
    assert(w:GetCargo() == drop and failures == 1)
end

function scenarios.navigation_overlapping_blocker_escape()
    local w = H.worker() prepare(w) H.chest(8)
    blocker(0,0,.35,CHARACTERS,bit.bor(CHARACTERS,OBSTACLES))
    w.inst.components.inventory:GiveItem(H.item("rocks",0,nil,7))
    local action = begin(w)
    -- Simulate physics separating initially coincident characters along the route.
    w.inst.x = .8
    deliver(w,action)
end

function scenarios.navigation_blocked_pickup_releases_claim()
    local w = H.worker(-4) local loco = prepare(w) H.chest(-7)
    local target = H.item("rocks",5,nil,7)
    ground = function(x,z) return x < -.5 or x > .5 or math.abs(z) > 30 end
    local failures = 0
    local action = begin(w,function(buffered)
        buffered:AddFailAction(function() failures = failures + 1 end)
    end)
    -- For a moving car native GoToEntity defers the instant arrival check.
    if loco.dest ~= nil then tick(w) end
    assert(w.pending == nil and loco.dest == nil and w:IsCoolingDown(target))
    assert(require("ac_targets").IsAvailable(H.worker(5),target))
    assert(target.components.stackable:StackSize() == 7 and w:GetCargo() == nil)
    action:Fail() action:Succeed()
    assert(failures == 1 and w.farm_count == 0)
end

function scenarios.navigation_outside_save_returns()
    local w = H.worker() local saved = w:OnSave()
    local restored = H.worker(17) restored:OnLoad(saved)
    local loco = prepare(restored)
    blocker(8,0,1)
    local action = begin(restored)
    assert(action.action == ACTIONS.WALKTO and loco._ac_navigation.radius == 17)
    assert(arrive(restored) == action and restored.inst:GetDistanceSqToPoint(restored:GetHome()) <= 1)
end

function scenarios.navigation_same_frame_corner()
    local w = H.worker() local loco = prepare(w) H.chest(8)
    local obstacle = blocker(4,0,1)
    w.inst.components.inventory:GiveItem(H.item("rocks",0,nil,7))
    local action = begin(w)
    -- A corner immediately beside the statue would be skipped by native arrival tolerance.
    loco.path.steps = { Vector3(0,0,0), Vector3(3,0,-1.5), Vector3(5,0,-1.5), Vector3(8,0,0) }
    loco.path.currentstep = 2
    local oldpath = loco.path
    w.inst.x, w.inst.z = 2.4,-1.2
    tick(w)
    assert(w.pending ~= nil and w.pending.action == action and obstacle:IsValid() and loco.path == oldpath)
    deliver(w,action)
end

function scenarios.navigation_three_blockers_stable_turns()
    -- Touching row of three statues: grid route corners are closer together than
    -- native locomotor's .7-unit waypoint tolerance, as in the reported layout.
    for _, offset in ipairs({-.3,0,.3}) do
        local base = offset*100
        local w = H.worker(base) w.radius = 20 w.inst.x,w.inst.z = base+.3,-2.5 w:SetHome()
        local loco = prepare(w)
        local c = physics(H.chest(base-3.5),.5,OBSTACLES,CHARACTERS) c.z = 3
        for _, x in ipairs({-1.3,0,1.3}) do blocker(base+x,0,.65) end
        w.inst.components.inventory:GiveItem(H.item("rocks",base,nil,16))
        local action = begin(w)
        local turns, previous = 0,nil
        for frame = 1, 240 do
            tick(w)
            if frame%10 == 0 and loco.dest ~= nil then loco:WalkForward() end
            local angle = w.inst.Transform:GetRotation()
            if previous ~= nil and math.abs((angle-previous+180)%360-180) > 100 then turns = turns+1 end
            previous = angle
            if w.inst.buffered ~= nil then break end
            assert(loco.dest ~= nil, "Statue row must remain reachable")
        end
        assert(w.inst.buffered == action and turns == 0, "Statue row must not trigger back-and-forth turns")
        assert(w:ValidateAction(action)) w:PerformAction(action)
        assert(c.components.container.stored.rocks == 16)
    end
end

local function shore_worker(x, z)
    local w = H.worker(x) w.inst.z = z or 0 w:SetHome() local loco = prepare(w)
    H.chest(-4)
    ground = function(px) return px <= 0 end
    -- Native path tiles end inland of the map's valid visual land overhang.
    pathground = function(px) return px <= -.4 end
    local target = H.item("rocks",-.1,nil,16) target.z = 0
    return w,loco,target
end

local function pickup_shore(w,target)
    local action = begin(w)
    assert(action.target == target and w.pending ~= nil, "Passable shoreline drop must not be ignored")
    if w.inst.buffered == nil then assert(arrive(w) == action) end
    assert(w.inst.x <= -.35, "Collector must pick up from the land side")
    assert(w:ValidateAction(action)) w:PerformAction(action)
    assert(w:GetCargo() == target and target.components.stackable:StackSize() == 16)
end

function scenarios.navigation_shore_pickup()
    local w,_,target = shore_worker(-3)
    pickup_shore(w,target)
end

function scenarios.navigation_shore_pickup_already_near()
    local w,_,target = shore_worker(-1)
    pickup_shore(w,target)
end

function scenarios.navigation_shore_pickup_tangent()
    local w,_,target = shore_worker(-.6,4)
    pickup_shore(w,target)
end

function scenarios.navigation_shore_does_not_cross_water()
    local w = H.worker(-1.6) local loco = prepare(w) H.chest(-3)
    local target = H.item("rocks",-.4,nil,16)
    ground = function(x) return x <= -1.2 or x >= -.6 end
    pathground = ground
    local action = begin(w)
    if loco.dest ~= nil then tick(w) end
    assert(w.pending == nil and w:IsCoolingDown(target) and w:GetCargo() == nil)
    assert(w.inst.x == -1.6 and target.components.stackable:StackSize() == 16 and action.target == target)
end

function scenarios.navigation_grid_arrival_point()
    local w = H.worker() local loco = prepare(w) H.chest(8)
    local target = H.item("rocks",4.5,nil,16)
    local clear = TheWorld.Pathfinder.IsClear
    -- Only grid-aligned endpoints pass this path-tile boundary. A* must reach a
    -- grid node already inside pickup range, instead of adding a reach endpoint.
    function TheWorld.Pathfinder:IsClear(x1,y1,z1,x2,y2,z2,...)
        if math.abs(x2/.75-math.floor(x2/.75+.5)) > .00001 then return false end
        return clear(self,x1,y1,z1,x2,y2,z2,...)
    end
    local action = begin(w)
    assert(arrive(w) == action and w:ValidateAction(action))
    w:PerformAction(action)
    assert(w:GetCargo() == target and target.components.stackable:StackSize() == 16)
end

function scenarios.navigation_plain_waypoints()
    for _, onboat in ipairs({false,true}) do
        local w,loco,c
        if onboat then
            local platform
            w,loco,platform,c = boat_worker()
        else
            w = H.worker() loco = prepare(w) c = H.chest(8)
            blocker(4,0,.66)
            w.inst.components.inventory:GiveItem(H.item("rocks",0,nil,7))
        end
        local action = begin(w)
        -- Native path.steps are plain coordinate tables. Keep the same route,
        -- but remove Vector3 methods in both world and platform-local points.
        for i, point in ipairs(loco.path.steps) do
            loco.path.steps[i] = {x=point.x,y=point.y,z=point.z}
        end
        for i, point in ipairs(loco._ac_navigation.localsteps) do
            loco._ac_navigation.localsteps[i] = {x=point.x,y=point.y,z=point.z}
        end
        deliver(w,action)
        assert(c.components.container.stored.rocks == 7)
    end
end

local function dispatch_brain(w, managed)
    local loco, actions = prepare(w), {}
    local native_push = loco.PushAction
    FunctionOrValue = function(value, ...)
        if type(value) == "function" then return value(...) end
        return value
    end
    function loco:PushAction(action, run)
        table.insert(actions, {action=action,time=time})
        action.options = {}
        action.TestForStart = action.IsValid
        function action:GetActionPoint() return self.pos end
        if action.target ~= nil and action.target.GetPhysicsRadius == nil then
            function action.target:GetPhysicsRadius(default) return default end
        end
        if native_push ~= nil then return native_push(self, action, run) end
        self:Clear()
        if action.target ~= nil then
            self:GoToEntity(action.target,action,run)
        else
            self:GoToPoint(action.pos,action,run)
        end
    end
    local brain = require("brains/ac_collectorbrain")(w.inst)
    brain.inst = w.inst
    w.inst.brain = brain
    if managed then
        w.inst.entity = { IsValid = function() return w.inst:IsValid() end }
        brain:_Start_Internal()
    else
        brain:OnStart()
    end
    return brain,actions
end

local function manager_tick()
    time = (GetTick() + 1) * FRAMES
    BrainManager:Update(GetTick())
end

local function dispatch_scene(w)
    local brain, actions = dispatch_brain(w, true)
    local inst, loco = w.inst, w.inst.components.locomotor
    local perform = inst.PerformBufferedAction
    function inst:RemoveTag(tag) self.tags[tag] = nil end
    function inst:PushEvent(name, data)
        -- Record the event without the simple movement fixture's state changes.
        table.insert(self.events, {name=name,data=data})
        if self.sg ~= nil and self.sg:IsListeningForEvent(name) and SGManager:OnPushEvent(self.sg) then
            self.sg:PushEvent(name,data)
        end
    end
    for name, fn in pairs(NAV_ENTITY) do inst[name] = fn end
    function inst:PerformBufferedAction()
        self.buffered = self.bufferedaction
        perform(self)
        self.bufferedaction = self.buffered
    end
    function inst:StartUpdatingComponent(component) component.isupdating = true end
    function inst:StopUpdatingComponent(component) component.isupdating = nil end
    inst.SoundEmitter = {PlaySound=function() end,KillSound=function() end}
    local animations = {walk_pre=.2,walk_loop=.6,walk_pst=.2,idle=1,pickup=1,hammer=1.3,store=1}
    inst.AnimState = {speed=1}
    function inst.AnimState:SetDeltaTimeMultiplier(speed) self.speed = speed end
    function inst.AnimState:GetCurrentAnimationLength() return animations[self.animation] / self.speed end
    function inst.AnimState:PlayAnimation(animation,loop)
        self.animation = animation
        self.finish = not loop and time+self:GetCurrentAnimationLength() or nil
    end
    function inst.AnimState:AnimDone() return self.finish == nil or time >= self.finish end
    TheSim.ProfilerPush, TheSim.ProfilerPop = function() end, function() end
    ModManager = {GetPostInitFns=function() return {} end,GetPostInitData=function() return {} end}
    -- Replace the simple idle/walk fixture with the actual server stategraph.
    inst.sg = StateGraphInstance(require("stategraphs/SGac_collector"),inst)
    SGManager:AddInstance(inst.sg)
    inst.sg:GoToState("idle")
    return {worker=w,brain=brain,actions=actions,loco=loco}
end

local function scene_tick(scene)
    time = (GetTick()+1)*FRAMES
    local inst, loco = scene.worker.inst, scene.loco
    for _, task in ipairs(inst.periodictasks or {}) do
        if not task.cancelled and task.nexttime <= time+.000001 then
            task.nexttime = time+task.period
            task.fn(inst)
        end
    end
    if loco.isupdating then loco:OnUpdate(FRAMES) end
    local animation = inst.AnimState
    if animation.finish ~= nil and time >= animation.finish then
        animation.finish = nil
        inst:PushEvent("animover") inst:PushEvent("animqueueover")
    end
    SGManager:Update(GetTick())
    BrainManager:Update(GetTick())
    local speed = inst.Physics.speed
    local angle = inst.Transform:GetRotation()*DEGREES
    inst.x, inst.z = inst.x+math.cos(angle)*speed*FRAMES, inst.z-math.sin(angle)*speed*FRAMES
end

function scenarios.navigation_native_queued_search_lifecycle()
    local scenes, waiting = {}, false
    H.chest(5)
    ground = function(x,z) return x < -.5 or x > .5 end
    for _ = 1, 8 do
        local w = H.worker(-4)
        w.inst.components.inventory:GiveItem(H.item("rocks",-4,nil,7))
        table.insert(scenes,dispatch_scene(w))
    end
    for _ = 1, 180 do
        scene_tick(scenes[1])
        for i, scene in ipairs(scenes) do
            if i > 1 and scene.loco.isupdating then scene.loco:OnUpdate(FRAMES) end
            local state = scene.loco._ac_navigation
            waiting = waiting or (state ~= nil and state.searching)
            assert(scene.worker:GetCargo() ~= nil and scene.worker.inst.components.inventory.drops == nil,
                "Native SG/Brain must preserve queued or route-blocked cargo without a drop loop")
            if scene.worker.last_failure ~= nil then
                assert(scene.worker.last_failure == "unreachable",
                    "Pausing navigation must not cancel the native action as a generic failure")
            end
        end
    end
    assert(waiting, "Native dispatch must exercise the shared search queue")
    for _, scene in ipairs(scenes) do
        assert(scene.worker:GetCargo().components.stackable:StackSize() == 7)
        assert(scene.worker.last_failure == "unreachable")
    end
end

function scenarios.navigation_native_idle_lifecycle()
    time = 100
    local w = H.worker() local c = H.chest(8)
    local scene = dispatch_scene(w)
    for _ = 1, 900 do scene_tick(scene) end
    assert(#scene.actions == 0 and w.inst.sg.currentstate.name == "idle")
    assert(SGManager.hibernaters[w.inst.sg], "Idle stategraph must be truly hibernating")
    local target = H.item("rocks",4,nil,7)
    local dropped = time
    for _ = 1, 20 do
        scene_tick(scene)
        if w.inst.sg:HasStateTag("moving") then break end
    end
    assert(w.inst.sg:HasStateTag("moving") and time-dropped <= .65,
        string.format("Idle car must start moving within .65s: actions=%d state=%s pending=%s dest=%s updating=%s events=%d cooldown=%s",
            #scene.actions,w.inst.sg.currentstate.name,tostring(w.pending~=nil),tostring(scene.loco.dest~=nil),
            tostring(scene.loco.isupdating),#w.inst.events,tostring(w:IsCoolingDown(target))))
    for _ = 1, 600 do scene_tick(scene) end
    assert(c.components.container.stored.rocks == 7 and w.pending == nil and w:GetCargo() == nil)
    assert(w.inst.sg.currentstate.name == "idle")
    local again = H.item("rocks",4,nil,7)
    dropped = time
    for _ = 1, 20 do scene_tick(scene) end
    assert(w.pending ~= nil and w.pending.action.target == again and not w:IsCoolingDown(again))
    assert(scene.actions[#scene.actions].time-dropped <= .65 and target.components.inventoryitem.owner == c)
end

function scenarios.navigation_native_return_dispatch()
    time = 100
    local w = H.worker() H.chest(8)
    local scene = dispatch_scene(w)
    w.inst.x = 10
    for _ = 1, 5 do scene_tick(scene) end
    assert(#scene.actions == 1 and scene.actions[1].action.action == ACTIONS.WALKTO)
    local target = H.item("rocks",12,nil,7)
    local dropped = time
    for _ = 1, 20 do scene_tick(scene) end
    assert(w.pending ~= nil and w.pending.action.target == target,
        "New work must interrupt a home-only WALKTO within .65s")
    assert(scene.actions[2].time-dropped <= .65 and not w:IsCoolingDown(target))
end

function scenarios.navigation_native_idle_wakeup()
    for _, sleep_mode in ipairs({"sleep","hibernate"}) do
        time = 100
        local base = sleep_mode == "sleep" and 40 or 80
        local w = H.worker(base) H.chest(base+8)
        local scene = dispatch_scene(w)
        for _ = 1, 900 do scene_tick(scene) end
        if sleep_mode == "sleep" then
            BrainManager:Sleep(scene.brain,10)
        else
            BrainManager:Hibernate(scene.brain)
        end
        local target = H.item("rocks",base+4,nil,7)
        local dropped = time
        for _ = 1, 20 do scene_tick(scene) end
        assert(w.pending ~= nil and w.pending.action.target == target,
            "Idle patrol must wake a delayed/hibernating BrainManager entry within .65s")
        assert(scene.actions[1].time-dropped <= .65 and not w:IsCoolingDown(target))
        scene.brain:_Stop_Internal() SGManager:RemoveInstance(w.inst.sg)
        w:OnRemoveFromEntity()
    end
end

function scenarios.navigation_native_blocked_return_dispatch()
    time = 100
    local w = H.worker() H.chest(8)
    local scene = dispatch_scene(w)
    w.inst.x = 6
    ground = function(x,z) return x < 2.5 or x > 3.5 or math.abs(z) > 30 end
    for _ = 1, 5 do scene_tick(scene) end
    assert(#scene.actions == 1 and w.pending == nil and scene.loco.dest == nil)
    for _ = 1, 6 do scene_tick(scene) end
    assert(#scene.actions == 1, "Unreachable home must retain the return retry throttle")
    local target = H.item("rocks",8,nil,7)
    local dropped = time
    for _ = 1, 20 do scene_tick(scene) end
    assert(w.pending ~= nil and w.pending.action.target == target,
        "Failed return must not delay work on the car's reachable side")
    assert(scene.actions[2].time-dropped <= .65 and not w:IsCoolingDown(target))
end

function scenarios.navigation_trace_explains_cooldown()
    local logs, original_print = {},print
    print = function(message) table.insert(logs,message) end
    local w = H.worker(-4) prepare(w) H.chest(-7)
    local target = H.item("rocks",5,nil,7)
    ground = function(x,z) return x < -.5 or x > .5 or math.abs(z) > 30 end
    begin(w)
    if w.inst.components.locomotor.dest ~= nil then tick(w) end
    assert(#logs == 0, "Diagnostic logging must be off by default")
    w:SetDebugEnabled(true)
    assert(w:GetDebugString():find("cooldowns=1",1,true))
    assert(w:GetDebugString():find("last_failure=unreachable",1,true))
    time = w.config.retry_delay+1
    begin(w)
    if w.inst.components.locomotor.dest ~= nil then tick(w) end
    local output = table.concat(logs,"\n")
    assert(output:find("event=scan",1,true) and output:find("event=job_selected",1,true))
    assert(output:find("event=path_failed",1,true) and output:find("event=job_failed",1,true))
    assert(output:find("retry_in=0.50",1,true) and output:find("retry_in=1.00",1,true))
    assert(output:find("scan_age=",1,true))
    assert(w:IsCoolingDown(target) and target.components.stackable:StackSize() == 7)
    w:SetDebugEnabled(false)
    local count = #logs w:Trace("suppressed") assert(#logs == count)
    print = original_print
end

function scenarios.navigation_manager_long_idle()
    -- Run the actual tick-waiter queue, including a long-running world's clock.
    for _, start in ipairs({0, 100, 300000}) do
        time = start
        local base = start * 3
        local w = H.worker(base) H.chest(base+8)
        local brain, actions = dispatch_brain(w, true)
        for _ = 1, 900 do manager_tick() end
        assert(#actions == 0 and w.pending == nil)
        local dropped = time
        local target = H.item("rocks",base+4,nil,7)
        for _ = 1, 20 do
            manager_tick()
            if #actions > 0 then break end
        end
        assert(#actions == 1 and actions[1].action.target == target,
            "Long-idle brain must dispatch within .65s through BrainManager")
        assert(actions[1].time - dropped <= .65 and not w:IsCoolingDown(target))
        brain:_Stop_Internal()
    end
end

function scenarios.navigation_manager_multiple_idle()
    time = 100
    local cars = {}
    for i = 1, 4 do
        local w = H.worker(i*40) H.chest(i*40+8)
        local brain, actions = dispatch_brain(w, true)
        table.insert(cars, {worker=w,brain=brain,actions=actions})
        for _ = 1, 7 do manager_tick() end
    end
    for _ = 1, 900 do manager_tick() end
    for i, car in ipairs(cars) do
        assert(#car.actions == 0)
        car.target = H.item("rocks",i*40+4,nil,7)
    end
    local dropped = time
    for _ = 1, 20 do manager_tick() end
    for _, car in ipairs(cars) do
        assert(#car.actions == 1 and car.actions[1].action.target == car.target,
            "Each idle car must dispatch through its own BrainManager waiter")
        assert(car.actions[1].time - dropped <= .65 and not car.worker:IsCoolingDown(car.target))
        car.brain:_Stop_Internal()
    end
end

local function dispatch_by(brain, actions, count, deadline)
    while time <= deadline+.000001 do
        brain:OnUpdate()
        if #actions >= count then return actions[count].action end
        time = time+FRAMES
    end
    error("Collector did not dispatch within the response budget")
end

function scenarios.navigation_drop_dispatch()
    -- Exercise the native PriorityNode startup scatter at world time zero too.
    for _, start in ipairs({0,100}) do
        time = start
        local base = start*3
        local w = H.worker(base) H.chest(base+8)
        local target = H.item("rocks",base+4,nil,7)
        local brain, actions = dispatch_brain(w)
        w:OnDropped()
        assert(dispatch_by(brain,actions,1,start+.1).target == target)
    end
end

function scenarios.navigation_idle_dispatch()
    time = 100
    local w = H.worker() H.chest(8)
    local brain, actions = dispatch_brain(w)
    brain:OnUpdate()
    assert(#actions == 0)
    time = time+FRAMES
    local target = H.item("rocks",4,nil,7)
    assert(dispatch_by(brain,actions,1,time+.65).target == target)
end

function scenarios.navigation_resume_dispatch()
    time = 100
    local w = H.worker() H.chest(8)
    local brain, actions = dispatch_brain(w)
    brain:OnUpdate()
    time = time+FRAMES
    w:SetEnabled(false)
    local target = H.item("rocks",4,nil,7)
    w:SetEnabled(true)
    assert(dispatch_by(brain,actions,1,time+.1).target == target)
end

function scenarios.navigation_fast_job_dispatch()
    time = 100
    local w = H.worker() H.chest(8)
    local target = H.item("rocks",4,nil,7)
    local brain, actions = dispatch_brain(w)
    local pickup = dispatch_by(brain,actions,1,time+.1)
    local loco = w.inst.components.locomotor
    loco.bufferedaction = nil loco:Stop() loco:Clear()
    w:SetActionSpeed(4)
    local state = H.enter(w,pickup,"pickup")
    function w.inst.sg:HasStateTag(tag)
        for _, value in ipairs(self.currentstate.tags or {}) do
            if value == tag then return true end
        end
        return false
    end
    local start = time
    time = start+.125
    w.inst.sg.timeinstate = .125 state.onupdate(w.inst)
    assert(w:GetCargo() == target and w.pending == nil)
    brain:OnUpdate()
    assert(#actions == 1, "Next job must wait for the current animation")
    time = start+.25 state.ontimeout(w.inst)
    assert(dispatch_by(brain,actions,2,time+.1).action == ACTIONS.STORE)
end
