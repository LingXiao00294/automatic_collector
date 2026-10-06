local M = {}
-- DST exposes bit globally; it has no require("bit") module.
local bit = bit

local GRID = .75
local MAX_NODES = 4096
local CLEARANCE = .05
local RECHECK = .25
local STUCK_TIME = 1.5
local FRAME_BUDGET = 128
local SEARCH_SLICE = 16
local scheduler
local EXCLUDE = { "INLIMBO", "FX" }
local DIRECTIONS = { { 1, 0 }, { 0, 1 }, { -1, 0 }, { 0, -1 },
    { 1, 1 }, { -1, 1 }, { -1, -1 }, { 1, -1 } }

local function DistanceSq(a, b)
    return (a.x - b.x) ^ 2 + (a.z - b.z) ^ 2
end

local function LocalPoint(platform, point)
    return platform ~= nil and Vector3(platform.entity:WorldToLocalSpace(point.x, point.y or 0, point.z)) or point
end

local function WorldPoint(platform, point)
    return platform ~= nil and Vector3(platform.entity:LocalToWorldSpace(point.x, point.y or 0, point.z)) or point
end

local function Context(inst, radius, target)
    local home = inst.components.ac_worker:GetHome()
    local physics = inst.Physics
    local context = { home = home, radius = radius, platform = inst:GetCurrentPlatform(),
        clearance = physics:GetRadius() + CLEARANCE,
        pathcaps = inst.components.locomotor.pathcaps, target = target, blockers = {} }
    -- Physics masks also cover modded statues and walls. Collector-to-collector
    -- congestion is handled by native character physics and the stuck backoff,
    -- rather than rebuilding static routes around each moving/overlapping cart.
    local scanradius = radius + (MAX_PHYSICS_RADIUS or 4) + context.clearance
    for _, ent in ipairs(TheSim:FindEntities(home.x, 0, home.z, scanradius, nil, EXCLUDE)) do
        local other = ent.Physics
        if ent ~= inst and not ent:HasTag("automatic_collector") and other ~= nil and other:IsActive()
            and bit.band(other:GetCollisionMask(), physics:GetCollisionGroup()) ~= 0
            and bit.band(physics:GetCollisionMask(), other:GetCollisionGroup()) ~= 0
            and ent:GetCurrentPlatform() == context.platform then
            local point = ent:GetPosition()
            point.radius = other:GetRadius() + context.clearance
            point.physics_radius, point.entity = other:GetRadius(), ent
            -- Players and creatures do not obstruct the final interaction reach.
            point.character = other:GetCollisionGroup() == COLLISION.CHARACTERS
            if context.platform ~= nil then point.localpos = LocalPoint(context.platform, point) end
            table.insert(context.blockers, point)
        end
    end
    return context
end

local function OnGround(context, x, z)
    if context.platform ~= nil then
        if context.local_coordinates then
            local worldx, _, worldz = context.platform.entity:LocalToWorldSpace(x, 0, z)
            x, z = worldx, worldz
        end
        return TheWorld.Map:GetPlatformAtPoint(x, 0, z) == context.platform
    end
    return TheWorld.Map:IsPassableAtPoint(x, 0, z, false, true)
end

local function InRange(context, point)
    return DistanceSq(context.home, point) <= context.radius ^ 2 + .000001
end

local function TerrainClear(context, a, b, clearance)
    if clearance > 0 and context.platform == nil and not TheWorld.Pathfinder:IsClear(
        a.x, 0, a.z, b.x, 0, b.z, context.pathcaps) then return false end
    local dx, dz = b.x - a.x, b.z - a.z
    local length = math.sqrt(dx * dx + dz * dz)
    local nx, nz = 0, 0
    if length > 0 then nx, nz = -dz / length * clearance, dx / length * clearance end
    local sample_step = clearance > 0 and .5 or .1
    local samples = math.max(1, math.ceil(length / sample_step))
    for i = 0, samples do
        local x, z = a.x + dx * i / samples, a.z + dz * i / samples
        if not OnGround(context, x, z) or (clearance > 0 and
            (not OnGround(context, x + nx, z + nz) or not OnGround(context, x - nx, z - nz))) then return false end
    end
    return true
end

local function SegmentDistanceSq(a, b, point)
    local dx, dz = b.x - a.x, b.z - a.z
    local length_sq = dx * dx + dz * dz
    local t = length_sq > 0
        and math.clamp(((point.x - a.x) * dx + (point.z - a.z) * dz) / length_sq, 0, 1) or 0
    return (a.x + t * dx - point.x) ^ 2 + (a.z + t * dz - point.z) ^ 2
end

local function InteractionClear(context, point, goal)
    -- A shoreline item can be on valid visual land outside native path tiles.
    -- Only the car's travel corridor needs those tiles; the final reach stays
    -- on passable ground and cannot reach through another physical obstacle.
    -- Characters are not obstacles: native pickup has no reach limit and physics
    -- separates bodies, so the player who dropped a stack, a creature or another
    -- car standing on it must not make that drop permanently unreachable.
    if not TerrainClear(context, point, goal, 0) then return false end
    for _, blocker in ipairs(context.blockers) do
        if not blocker.character and blocker.entity ~= context.target
            and SegmentDistanceSq(point, goal, blocker) < blocker.physics_radius ^ 2 then return false end
    end
    return true
end

local function SegmentClear(context, a, b)
    if not InRange(context, b) or not TerrainClear(context, a, b, context.clearance) then
        return false
    end
    local dx, dz = b.x - a.x, b.z - a.z
    for _, blocker in ipairs(context.blockers) do
        if SegmentDistanceSq(a, b, blocker) < blocker.radius ^ 2 then
            -- A newly placed obstacle may overlap the car; allow only an escape
            -- segment whose distance from that obstacle increases from the start.
            if DistanceSq(a, blocker) >= blocker.radius ^ 2
                or (a.x - blocker.x) * dx + (a.z - blocker.z) * dz < 0
                or DistanceSq(b, blocker) <= DistanceSq(a, blocker) then return false end
        end
    end
    return true
end

local function Approach(context, point, goal, arrive)
    local length = math.sqrt(DistanceSq(point, goal))
    if length <= arrive then
        -- A* nodes contain search metadata and are not Vector3 instances.
        return InteractionClear(context, point, goal) and Vector3(point.x, 0, point.z) or nil
    end
    local stop = math.max(0, arrive - CLEARANCE)
    local endpoint = Vector3(goal.x + (point.x - goal.x) / length * stop, 0,
        goal.z + (point.z - goal.z) / length * stop)
    return SegmentClear(context, point, endpoint)
        and InteractionClear(context, endpoint, goal) and endpoint or nil
end

local function SpendBudget()
    if scheduler.slice == 0 then coroutine.yield() end
    scheduler.slice = scheduler.slice - 1
end

local function Smooth(context, steps)
    local result, index = { steps[1] }, 1
    while index < #steps - 1 do
        local next_index = index + 1
        for i = #steps - 1, index + 2, -1 do
            SpendBudget()
            if SegmentClear(context, steps[index], steps[i]) then next_index = i break end
        end
        table.insert(result, steps[next_index])
        index = next_index
    end
    table.insert(result, steps[#steps])
    return result
end

local function Push(heap, node)
    local entry = { node = node, cost = node.cost, score = node.score }
    local index = #heap + 1
    while index > 1 do
        local parent = math.floor(index / 2)
        if heap[parent].score <= entry.score then break end
        heap[index], index = heap[parent], parent
    end
    heap[index] = entry
end

local function Pop(heap)
    local first, last = heap[1], table.remove(heap)
    if #heap > 0 then
        local index = 1
        while index * 2 <= #heap do
            local child = index * 2
            if child < #heap and heap[child + 1].score < heap[child].score then child = child + 1 end
            if last.score <= heap[child].score then break end
            heap[index], index = heap[child], child
        end
        heap[index] = last
    end
    return first
end

local function Plan(context, start, goal, arrive)
    local endpoint = Approach(context, start, goal, arrive)
    if endpoint ~= nil then return { start, endpoint, goal } end
    local first = { x = start.x, y = 0, z = start.z, i = 0, j = 0, cost = 0, score = 0 }
    local nodes, heap = { ["0:0"] = first }, {}
    Push(heap, first)
    local expanded = 0
    while #heap > 0 and expanded < MAX_NODES do
        local entry = Pop(heap)
        local node = entry.node
        if not node.closed and node.cost == entry.cost then
            SpendBudget()
            node.closed = true
            expanded = expanded + 1
            endpoint = Approach(context, node, goal, arrive)
            if endpoint ~= nil then
                local reverse = { endpoint }
                while node ~= nil do
                    table.insert(reverse, Vector3(node.x, 0, node.z))
                    node = node.parent
                end
                local steps = {}
                for i = #reverse, 1, -1 do table.insert(steps, reverse[i]) end
                table.insert(steps, goal)
                return Smooth(context, steps)
            end
            for _, direction in ipairs(DIRECTIONS) do
                local i, j = node.i + direction[1], node.j + direction[2]
                local key = i .. ":" .. j
                local nextnode = nodes[key]
                if nextnode == nil then
                    nextnode = { x = start.x + i * GRID, y = 0, z = start.z + j * GRID,
                        i = i, j = j, cost = math.huge }
                    nodes[key] = nextnode
                end
                local cost = node.cost + GRID * math.sqrt(direction[1] ^ 2 + direction[2] ^ 2)
                if not nextnode.closed and cost < nextnode.cost and SegmentClear(context, node, nextnode) then
                    nextnode.cost, nextnode.parent = cost, node
                    nextnode.score = cost + math.max(0, math.sqrt(DistanceSq(nextnode, goal)) - arrive)
                    Push(heap, nextnode)
                end
            end
        end
    end
    return nil
end

local function PauseMovement(locomotor)
    locomotor:StopMoving()
    if not locomotor._ac_navigation_paused then
        locomotor._ac_navigation_paused = true
        locomotor.inst:PushEvent("locomote")
    end
end

local function CancelSearch(state)
    if state ~= nil then
        state.search, state.locomotor, state.context, state.dest, state.target = nil, nil, nil, nil, nil
        state.searching = false
    end
end

local function CompleteSearch(state, context, steps, goal)
    local locomotor = state.locomotor
    state.search, state.searching = nil, false
    state.context, state.failed = context, steps == nil
    state.validate = true
    state.progress = LocalPoint(context.platform, locomotor.inst:GetPosition())
    state.progress_time, state.nextcheck = GetTime(), GetTime() + RECHECK
    state.goal = goal
    if steps ~= nil then
        state.localsteps = steps
        local worldsteps = {}
        for i, step in ipairs(steps) do worldsteps[i] = WorldPoint(context.platform, step) end
        locomotor.path = { steps = worldsteps, currentstep = 2 }
    end
    locomotor.inst.components.ac_worker:Trace(steps ~= nil and "path_found" or "path_failed", state.target,
        steps ~= nil and "waypoints=" .. tostring(#steps) or "unreachable")
end

local function PumpSearches()
    local tick = math.floor(GetTime() / FRAMES + .5)
    if scheduler == nil or scheduler.world ~= TheWorld then
        scheduler = { world = TheWorld, queue = {}, head = 1, tail = 0 }
    end
    if scheduler.tick ~= tick then scheduler.tick, scheduler.remaining = tick, FRAME_BUDGET end
    while scheduler.remaining > 0 and scheduler.head <= scheduler.tail do
        local state = scheduler.queue[scheduler.head]
        scheduler.queue[scheduler.head] = nil
        scheduler.head = scheduler.head + 1
        local locomotor = state.locomotor
        if locomotor ~= nil and locomotor._ac_navigation == state and locomotor.dest == state.dest
            and locomotor.inst:IsValid() and locomotor.inst.components.ac_worker:IsWorking()
            and locomotor.dest:IsValid() then
            local context = state.context
            if context ~= nil and (locomotor.inst:GetCurrentPlatform() ~= context.platform
                or (context.platform ~= nil and not context.platform:IsValid())) then
                state.search, state.searching, state.failed = nil, false, true
                state.failure_reason = "platform_changed"
            else
                local quota = math.min(SEARCH_SLICE, scheduler.remaining)
                scheduler.slice = quota
                local ok, result, steps, goal = coroutine.resume(state.search)
                assert(ok, result)
                scheduler.remaining = scheduler.remaining - (quota - scheduler.slice)
                if coroutine.status(state.search) == "dead" then
                    CompleteSearch(state, result, steps, goal)
                else
                    scheduler.tail = scheduler.tail + 1
                    scheduler.queue[scheduler.tail] = state
                end
            end
        else
            CancelSearch(state)
        end
    end
    if scheduler.head > scheduler.tail then scheduler.queue, scheduler.head, scheduler.tail = {}, 1, 0 end
end

local function FindPath(locomotor)
    local inst, worker = locomotor.inst, locomotor.inst.components.ac_worker
    if locomotor.dest == nil or not locomotor.dest:IsValid() then return end
    local previous = locomotor._ac_navigation
    if previous ~= nil and previous.dest == locomotor.dest and previous.searching then
        PumpSearches()
        return
    end
    if previous ~= nil and previous.dest ~= locomotor.dest then previous = nil end
    local kind = worker.pending ~= nil and worker.pending.kind or nil
    local radius = worker.radius + ((kind == "pickup" or kind == "hammer") and 2 or 0)
    local start = inst:GetPosition()
    -- A car restored outside its range or returning from drop tolerance may move
    -- inward without expanding its allowed distance beyond the starting point.
    radius = math.max(radius, previous ~= nil and previous.radius or
        math.sqrt(DistanceSq(start, worker:GetHome())))
    local target = worker.pending ~= nil and worker.pending.action.target or locomotor.dest.inst
    CancelSearch(locomotor._ac_navigation)
    locomotor:ResetPath()
    local state = { dest = locomotor.dest, locomotor = locomotor, target = target, radius = radius,
        searching = true, step = 2, dt = previous ~= nil and previous.dt or FRAMES,
        nextplan = GetTime() + RECHECK,
        retries = previous ~= nil and previous.retries or 0 }
    locomotor._ac_navigation = state
    -- Snapshot/query work starts only after obtaining the shared frame budget.
    -- Round-robin slices prevent a crowd of unreachable targets blocking one tick.
    state.search = coroutine.create(function()
        SpendBudget()
        local context = Context(inst, radius, target)
        state.context = context
        local platform = context.platform
        -- Keep the entire in-progress search in the boat's coordinate system.
        -- Map queries project into its current pose, even after a yielded frame.
        if platform ~= nil then
            context.local_coordinates = true
            context.home = LocalPoint(platform, context.home)
            for _, blocker in ipairs(context.blockers) do
                blocker.x, blocker.z = blocker.localpos.x, blocker.localpos.z
            end
        end
        local goal = LocalPoint(platform, Vector3(state.dest:GetPoint()))
        local steps = Plan(context, LocalPoint(platform, inst:GetPosition()), goal, locomotor.arrive_dist)
        SpendBudget()
        -- Obstacles may change while queued; validate against a fresh snapshot
        -- before resuming movement, not a quarter second after starting to walk.
        return Context(inst, radius, target), steps, goal
    end)
    PumpSearches()
    scheduler.tail = scheduler.tail + 1
    scheduler.queue[scheduler.tail] = state
    PumpSearches()
    if state.searching then PauseMovement(locomotor) end
end

local function Reject(locomotor, reason)
    local worker = locomotor.inst.components.ac_worker
    local had_job = worker.pending ~= nil
    worker:Cancel(false, reason or "unreachable")
    -- Home failures throttle only return retries. New work may still start at once.
    -- Clear also notifies a home WALKTO's native failure listeners.
    worker.nextscan = 0
    if not had_job then worker:BackoffHome() end
end

local function NextPoint(locomotor)
    local path = locomotor.path
    local state = locomotor._ac_navigation
    if path ~= nil and path.steps ~= nil and state.step < #path.steps then
        return path.steps[state.step]
    end
    local goal = Vector3(locomotor.dest:GetPoint())
    return Approach(state.context, locomotor.inst:GetPosition(), goal, locomotor.arrive_dist)
end

local function AtGoal(locomotor)
    local state, start = locomotor._ac_navigation, locomotor.inst:GetPosition()
    local goal = Vector3(locomotor.dest:GetPoint())
    return DistanceSq(start, goal) <= locomotor.arrive_dist ^ 2
        and InteractionClear(state.context, start, goal)
end

local function RouteClear(locomotor)
    local state, start = locomotor._ac_navigation, locomotor.inst:GetPosition()
    if not InRange(state.context, start) then return false end
    if AtGoal(locomotor) then return true end
    local nextpoint = NextPoint(locomotor)
    if not InRange(state.context, start) or nextpoint == nil then return false end
    local platform = state.context.platform
    local localstart, localnext = LocalPoint(platform, start), LocalPoint(platform, nextpoint)
    local segment = state.segment
    if segment ~= nil and segment.context == state.context and DistanceSq(segment.finish, localnext) < .00000001 then
        local dx, dz = segment.finish.x - segment.start.x, segment.finish.z - segment.start.z
        local length_sq = dx * dx + dz * dz
        local t = length_sq > 0
            and ((localstart.x - segment.start.x) * dx + (localstart.z - segment.start.z) * dz) / length_sq or 0
        local nearest = { x = segment.start.x + t * dx, z = segment.start.z + t * dz }
        -- Reuse a validated segment only while physics follows that exact line.
        -- A new waypoint, obstacle snapshot or sideways displacement rechecks it.
        if t >= 0 and t <= 1 and DistanceSq(nearest, localstart) < .00000001 then return true end
    end
    local clear = SegmentClear(state.context, start, nextpoint)
    state.segment = clear and { context = state.context, start = localstart, finish = localnext } or nil
    return clear
end

local function Advance(locomotor, dt)
    local state, path = locomotor._ac_navigation, locomotor.path
    if path == nil or path.steps == nil or AtGoal(locomotor) then return end
    local start = locomotor.inst:GetPosition()
    local speed = locomotor.wantstorun and locomotor:GetRunSpeed() or locomotor:GetWalkSpeed()
    local tolerance = math.max(.15, speed * (dt or 0))
    while state.step < #path.steps - 1
        and DistanceSq(start, path.steps[state.step]) <= tolerance ^ 2
        and SegmentClear(state.context, start, path.steps[state.step + 1]) do
        state.step = state.step + 1
    end
    path.currentstep = state.step
end

function M.Attach(inst)
    local locomotor = inst.components.locomotor
    if locomotor._ac_navigation_attached then return end
    locomotor._ac_navigation_attached = true
    local onupdate, stop = locomotor.OnUpdate, locomotor.Stop
    local clear, wants_to_move_forward = locomotor.Clear, locomotor.WantsToMoveForward
    local set_move_dir, set_motor_speed = locomotor.SetMoveDir, locomotor.SetMotorSpeed
    locomotor.FindPath = FindPath
    locomotor.Stop = function(self, ...)
        CancelSearch(self._ac_navigation)
        self._ac_navigation = nil
        self._ac_steer_point = nil
        self._ac_navigation_paused = nil
        return stop(self, ...)
    end
    locomotor.Clear = function(self, ...)
        CancelSearch(self._ac_navigation)
        self._ac_navigation, self._ac_navigation_paused = nil, nil
        return clear(self, ...)
    end
    if wants_to_move_forward ~= nil then
        locomotor.WantsToMoveForward = function(self, ...)
            return not self._ac_navigation_paused and wants_to_move_forward(self, ...)
        end
    end
    locomotor.SetMoveDir = function(self, direction, ...)
        if self._ac_steer_point ~= nil then
            local point = self._ac_steer_point
            -- Native path steps are coordinate tables without Vector3 methods.
            direction = inst:GetAngleToPoint(point.x, point.y or 0, point.z)
        end
        return set_move_dir(self, direction, ...)
    end
    locomotor.SetMotorSpeed = function(self, speed)
        local state = self._ac_navigation
        if self._ac_navigation_paused or (state ~= nil and state.searching) then speed = 0 end
        if speed > 0 and state ~= nil and self.dest ~= nil and not AtGoal(self) then
            local point = NextPoint(self)
            if point ~= nil then
                local distance = math.sqrt(DistanceSq(inst:GetPosition(), point))
                speed = math.min(speed, distance / math.max(state.dt or FRAMES, FRAMES))
            end
        end
        -- WalkForward on animation-cycle re-entry uses this same cap, so it
        -- cannot undo the near-corner speed limit after locomotor's update.
        return set_motor_speed(self, speed)
    end
    locomotor.OnUpdate = function(self, dt, arrive_check_only)
        PumpSearches()
        local state = self._ac_navigation
        if state ~= nil and self.dest ~= nil then
            if not self.dest:IsValid() then inst.components.ac_worker:Cancel(true, "target_changed") return end
            if state.searching then PauseMovement(self) return end
            if state.context == nil then self:Clear() return end
            if state.failed then Reject(self, state.failure_reason) return end
            state.dt = math.max(dt or 0, FRAMES)
            local platform = state.context.platform
            if inst:GetCurrentPlatform() ~= platform
                or (platform ~= nil and not platform:IsValid()) then Reject(self, "platform_changed") return end
            if platform ~= nil and self.path ~= nil then
                state.context.home = inst.components.ac_worker:GetHome()
                for _, blocker in ipairs(state.context.blockers) do
                    local point = WorldPoint(platform, blocker.localpos)
                    blocker.x, blocker.z = point.x, point.z
                end
                for i, point in ipairs(state.localsteps) do
                    self.path.steps[i] = WorldPoint(platform, point)
                end
            end
            local time = GetTime()
            if state.validate or (not arrive_check_only and time >= state.nextcheck) then
                if not state.validate then state.context = Context(inst, state.radius, state.target) end
                state.validate = nil
                state.nextcheck = time + RECHECK
                local point = LocalPoint(platform, inst:GetPosition())
                local moved = DistanceSq(point, state.progress) >= .1 ^ 2
                local stuck = not moved and time - state.progress_time >= STUCK_TIME
                if moved then state.progress, state.progress_time = point, time end
                local goal = LocalPoint(platform, Vector3(self.dest:GetPoint()))
                if stuck or DistanceSq(goal, state.goal) > .25 ^ 2 or not RouteClear(self) then
                    if stuck then
                        state.retries = state.retries + 1
                        state.progress_time = time
                    end
                    if state.retries > 2 then Reject(self, "stuck") return end
                    FindPath(self)
                    if self._ac_navigation.searching then PauseMovement(self) return end
                    if self._ac_navigation.failed then Reject(self) return end
                    state = self._ac_navigation
                end
            end
            Advance(self, dt)
            if not RouteClear(self) then
                if time < state.nextplan then PauseMovement(self) return end
                FindPath(self)
                if self._ac_navigation.searching then PauseMovement(self) return end
                if self._ac_navigation.failed then Reject(self) return end
            end
            if self._ac_navigation_paused then
                self._ac_navigation_paused = nil
                inst:PushEvent("locomote")
            end
            if not AtGoal(self) then self._ac_steer_point = NextPoint(self) end
        end
        local arrive_dist = self.arrive_dist
        -- Do not let distance alone interact through water or a nearby obstacle.
        local goal = self.dest ~= nil and Vector3(self.dest:GetPoint()) or nil
        local native_arrive = math.max(arrive_dist or 0, self:GetRunSpeed() * (dt or 0) * .5)
        local defer_arrival = self._ac_navigation ~= nil and goal ~= nil
            and DistanceSq(inst:GetPosition(), goal) <= native_arrive ^ 2
            and not InteractionClear(self._ac_navigation.context, inst:GetPosition(), goal)
        if defer_arrival then self.arrive_dist = 0 end
        onupdate(self, defer_arrival and 0 or dt, arrive_check_only)
        self.arrive_dist = arrive_dist
        local steer = self._ac_steer_point
        self._ac_steer_point = nil
        state = self._ac_navigation
        if state ~= nil and self.dest ~= nil and self.path ~= nil then
            -- Native .7-unit corner skipping must not replace our safe waypoint.
            self.path.currentstep = state.step
            if steer ~= nil and not arrive_check_only and inst.sg:HasStateTag("moving") then
                local speed = self.wantstorun and self:GetRunSpeed() or self:GetWalkSpeed()
                local distance = math.sqrt(DistanceSq(inst:GetPosition(), steer))
                self:SetMotorSpeed(math.min(speed, distance / math.max(dt or 0, FRAMES)))
            end
        end
    end
end

return M
