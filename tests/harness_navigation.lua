-- Only physics integration and map queries are simulated. NAV_NATIVE replaces
-- the fixture movement/action methods with the installed game's original ones.
local H = upgrade_contract
local Navigation = require("ac_navigation")
local bit = bit
local time, ground = 0, function() return true end
local pathground
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
function TheWorld.Pathfinder:IsClear(x1, _, z1, x2, _, z2)
    local samples = math.max(1, math.ceil(math.sqrt(distsq(x1,z1,x2,z2)) / .1))
    for i = 0, samples do
        if not (pathground or ground)(x1+(x2-x1)*i/samples, z1+(z2-z1)*i/samples) then return false end
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

local function prepare(w)
    local inst = physics(w.inst, .35, CHARACTERS, bit.bor(CHARACTERS,OBSTACLES))
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

local function begin(w, before)
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
            canmove = canmove and distsq(x,z,ent.x,ent.z) >= (other:GetRadius()+.35)^2
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

function scenarios.navigation_native_idle_lifecycle()
    time = 100
    local w = H.worker() local c = H.chest(8)
    local scene = dispatch_scene(w)
    for _ = 1, 900 do scene_tick(scene) end
    assert(#scene.actions == 0 and w.inst.sg.currentstate.name == "idle")
    assert(SGManager.hibernaters[w.inst.sg], "Idle stategraph must be truly hibernating")
    local target = H.item("rocks",4,nil,7)
    local dropped = time
    for _ = 1, 12 do
        scene_tick(scene)
        if w.inst.sg:HasStateTag("moving") then break end
    end
    assert(w.inst.sg:HasStateTag("moving") and time-dropped <= .4,
        string.format("Idle car must start moving within .4s: actions=%d state=%s pending=%s dest=%s updating=%s events=%d cooldown=%s",
            #scene.actions,w.inst.sg.currentstate.name,tostring(w.pending~=nil),tostring(scene.loco.dest~=nil),
            tostring(scene.loco.isupdating),#w.inst.events,tostring(w:IsCoolingDown(target))))
    for _ = 1, 600 do scene_tick(scene) end
    assert(c.components.container.stored.rocks == 7 and w.pending == nil and w:GetCargo() == nil)
    assert(w.inst.sg.currentstate.name == "idle")
    local again = H.item("rocks",4,nil,7)
    dropped = time
    for _ = 1, 12 do scene_tick(scene) end
    assert(w.pending ~= nil and w.pending.action.target == again and not w:IsCoolingDown(again))
    assert(scene.actions[#scene.actions].time-dropped <= .4 and target.components.inventoryitem.owner == c)
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
    for _ = 1, 12 do scene_tick(scene) end
    assert(w.pending ~= nil and w.pending.action.target == target,
        "New work must interrupt a home-only WALKTO within .4s")
    assert(scene.actions[2].time-dropped <= .4 and not w:IsCoolingDown(target))
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
        for _ = 1, 12 do scene_tick(scene) end
        assert(w.pending ~= nil and w.pending.action.target == target,
            "Idle patrol must wake a delayed/hibernating BrainManager entry within .4s")
        assert(scene.actions[1].time-dropped <= .4 and not w:IsCoolingDown(target))
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
    local dropped = time
    for _ = 1, 6 do scene_tick(scene) end
    assert(#scene.actions == 1, "Unreachable home must retain the return retry throttle")
    local target = H.item("rocks",8,nil,7)
    for _ = 1, 6 do scene_tick(scene) end
    assert(w.pending ~= nil and w.pending.action.target == target,
        "Failed return must not delay work on the car's reachable side")
    assert(scene.actions[2].time-dropped <= .4 and not w:IsCoolingDown(target))
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
        for _ = 1, 12 do
            manager_tick()
            if #actions > 0 then break end
        end
        assert(#actions == 1 and actions[1].action.target == target,
            "Long-idle brain must dispatch within .4s through BrainManager")
        assert(actions[1].time - dropped <= .4 and not w:IsCoolingDown(target))
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
    for _ = 1, 12 do manager_tick() end
    for _, car in ipairs(cars) do
        assert(#car.actions == 1 and car.actions[1].action.target == car.target,
            "Each idle car must dispatch through its own BrainManager waiter")
        assert(car.actions[1].time - dropped <= .4 and not car.worker:IsCoolingDown(car.target))
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
    assert(dispatch_by(brain,actions,1,time+.3).target == target)
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
