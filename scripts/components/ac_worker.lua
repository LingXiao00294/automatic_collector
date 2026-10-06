local Targets = require("ac_targets")
local Upgrades = require("ac_upgrades")
local SCAN_INTERVAL = .5
-- A failed plan says nothing about the target itself, so it starts on a short
-- backoff and only reaches retry_delay after repeated failures.
local PATH_RETRY_DELAY = .5
-- Only a plan that found no route at all. A stuck or displaced car already
-- re-planned internally, or left the target's platform behind.
local PATH_FAILURES = { unreachable = true }
local NAVIGATION_FAILURES = { unreachable = true, stuck = true, search_timeout = true }

local Worker = Class(function(self, inst)
    self.inst = inst
    self.config = TUNING.AUTOMATIC_COLLECTOR
    self.radius = self.config.radius
    self.enabled = true
    self.harvest_enabled = true
    self.home = nil
    self.homeplatform = nil
    self.homelocal = nil
    self.pending = nil
    self.cooldowns = setmetatable({}, { __mode = "k" })
    self.pathfails = setmetatable({}, { __mode = "k" })
    self.navigation_failures = setmetatable({}, { __mode = "k" })
    self.action_speed = 1
    self.nextscan = 0
    self.nextreturn = 0
    self.blocked = false
    self.farm_count = 0
    self.farm_draining = false
    self:RefreshWatchdog()
end)

function Worker:RefreshWatchdog()
    local period = self.pending ~= nil and .1 or SCAN_INTERVAL
    if self.task ~= nil and self.taskperiod == period then return end
    if self.task ~= nil then self.task:Cancel() end
    self.taskperiod = period
    -- Active jobs validate faster; idle patrol bounds native brain wakeup.
    local initialdelay = self.pending ~= nil and period or nil
    self.task = self.inst:DoPeriodicTask(period, function() self:Watchdog() end, initialdelay)
end

function Worker:WakeBrain()
    local brain = self.inst.brain
    if brain ~= nil and not brain.stopped and not brain.paused and self:IsWorking() then
        brain:ForceUpdate()
    end
end

function Worker:SetDebugEnabled(value)
    self.debug_enabled = value == true
    self.next_debug_scan = 0
    self:Trace("debug_enabled")
end

function Worker:Trace(event, target, detail)
    if not self.debug_enabled then return end
    print(string.format("[automatic_collector] car=%s event=%s target=%s detail=%s %s",
        tostring(self.inst.GUID), event, target ~= nil and tostring(target.prefab) or "none",
        tostring(detail or ""), self:GetDebugString()))
end

function Worker:GetHome()
    if self.homeplatform ~= nil and self.homeplatform:IsValid() and self.homelocal ~= nil then
        return Vector3(self.homeplatform.entity:LocalToWorldSpace(self.homelocal:Get()))
    end
    return self.home or self.inst:GetPosition()
end

function Worker:SetHome()
    self.home = self.inst:GetPosition()
    self.homeplatform = self.inst:GetCurrentPlatform()
    self.homelocal = self.homeplatform ~= nil
        and Vector3(self.homeplatform.entity:WorldToLocalSpace(self.home:Get())) or nil
    self:SyncHome()
end

-- Coordinates are local to the boat when a platform is present.
function Worker:SyncHome()
    local inst = self.inst
    if inst._ac_home_valid == nil then return end
    local home = self.homelocal or self.home
    inst._ac_home_valid:set(home ~= nil)
    inst._ac_home_platform:set(self.homeplatform)
    inst._ac_home_x:set(home ~= nil and home.x or 0)
    inst._ac_home_z:set(home ~= nil and home.z or 0)
    inst._ac_radius:set(self.radius)
end

function Worker:IsCoolingDown(target)
    return (self.cooldowns[target] or 0) > GetTime()
end

function Worker:IsWaitingForRoute(target)
    return self.navigation_failures[target] == true and self:IsCoolingDown(target)
end

function Worker:BackoffHome()
    self.homepathfails = math.min((self.homepathfails or 0) + 1, 6)
    self.nextreturn = GetTime() + math.min(self.config.retry_delay, PATH_RETRY_DELAY * 2 ^ (self.homepathfails - 1))
end

function Worker:GetCargo()
    return self.inst.components.inventory:GetFirstItemInAnySlot() or self.inst.components.inventory:GetActiveItem()
end

function Worker:GetCarrySlots()
    return self.inst.components.inventory.maxslots
end

-- Called by future registered capacity upgrades; lowering capacity never drops cargo.
function Worker:SetCarrySlots(count)
    if type(count) ~= "number" or count ~= count or count == math.huge or count == -math.huge then
        return false
    end
    count = math.max(1, math.min(8, math.floor(count)))
    local inventory = self.inst.components.inventory
    for slot in pairs(inventory.itemslots) do
        if slot > count then return false end
    end
    inventory.maxslots = count
    return true
end

-- Fill a single native stack at a time. Never use the temporary active-item slot
-- to deliberately overflow transport capacity, or collect cargo we cannot deliver.
function Worker:GetPickupCount(target)
    local inventory = self.inst.components.inventory
    if target == nil or not target:IsValid() or inventory:GetActiveItem() ~= nil then
        return 0
    end
    local stack = target.components.stackable
    local count = stack ~= nil and stack:StackSize() or 1
    local room = math.min(count, inventory:CanAcceptCount(target))
    local carried, carriedcount = nil, 0
    if stack ~= nil then
        room = math.min(room, stack.originalmaxsize or stack.maxsize)
        for slot = 1, inventory.maxslots do
            local cargo = inventory:GetItemInSlot(slot)
            local existing = cargo ~= nil and cargo.components.stackable or nil
            if existing ~= nil and not existing:IsFull() and existing:CanStackWith(target) then
                carried, carriedcount = cargo, existing:StackSize()
                room = math.min(room, existing:RoomLeft())
                break
            end
        end
    end
    if room <= 0 then return 0 end
    local capacity = Targets.DeliveryCapacity(self, carried or target, carriedcount + room)
    return math.max(0, math.floor(math.min(room, capacity - carriedcount)))
end

function Worker:CanHarvest(target, kind)
    if not self:IsHarvestEnabled() then return false end
    if kind == "hammer" then return self:GetCargo() == nil end
    if Targets.IsFarmWork(target, kind) then
        -- Products are harvested to the ground. Only real pickup/delivery checks
        -- capacity; unknown yields and a full matching chest cannot block a crop.
        return not self.farm_draining and self:GetCargo() == nil
    end
    local inventory = self.inst.components.inventory
    if inventory:GetActiveItem() ~= nil then return false end
    if self:GetCargo() == nil then
        return Targets.HasHarvestDestination(self, target, kind)
    end
    local product, count = Targets.HarvestProduct(self, target, kind)
    if type(product) ~= "string" or type(count) ~= "number" or count ~= count
        or count <= 0 or count == math.huge then return false end
    count = math.ceil(count)
    local empty = false
    for slot = 1, inventory.maxslots do
        local cargo = inventory:GetItemInSlot(slot)
        if cargo == nil then
            empty = true
        elseif cargo.prefab == product and cargo.skinname == nil
            and cargo.stackable_CanStackWithFn == nil then
            local stack = cargo.components.stackable
            if stack ~= nil and stack:RoomLeft() >= count
                and Targets.FindContainer(self, cargo, stack:StackSize() + count) ~= nil then
                return true
            end
        end
    end
    -- A future capacity upgrade may start another known product group.
    return empty and Targets.HasHarvestDestination(self, target, kind)
end

function Worker:DropHarvestCargo()
    local inventory = self.inst.components.inventory
    local items = {}
    for _, item in pairs(inventory.itemslots) do table.insert(items, item) end
    local active = inventory:GetActiveItem()
    if active ~= nil then table.insert(items, active) end
    for _, item in ipairs(items) do inventory:DropItem(item, true) end
end

-- Split only this target at animation contact. Native Stackable:Get preserves
-- perishability/moisture/skin callbacks, and native PICKUP still does the transfer.
function Worker:PerformAction(action)
    if self.pending.kind == "pickup" then
        local target = action.target
        local count = self:GetPickupCount(target)
        if count <= 0 then
            action:Fail()
            self.inst:ClearBufferedAction()
            return
        end
        local stack = target.components.stackable
        if stack ~= nil and count < stack:StackSize() then
            local portion = stack:Get(count)
            portion.Transform:SetPosition(target.Transform:GetWorldPosition())
            action.target = portion
        end
    end
    local pending = self.pending
    pending.executing = true
    self.inst:PerformBufferedAction()
    pending.executing = nil
end

function Worker:IsWorking()
    return self.enabled and not self.inst.components.inventoryitem:IsHeld()
        and not self.inst:IsInLimbo() and not self.inst:IsAsleep()
end

function Worker:SetBlocked(value)
    self.blocked = value
    self.inst._ac_blocked:set(value)
end

function Worker:Finish(action, success)
    if self.pending == nil or self.pending.action ~= action then
        return
    end
    -- Native locomotor may fail first, before the watchdog sees a changed target.
    -- Classify here without failing/clearing the action again inside its callback.
    if not success and not self.pending.replan and not self.pending.executing and self:IsWorking()
        and GetTime() - self.pending.started <= self.config.action_timeout
        and not self:ValidateAction(action) then
        self.pending.replan = true
        self.nextscan = 0
    end
    local target = self.pending.claimtarget or action.target
    Targets.Release(self, target)
    if not success and not self.pending.replan and target ~= nil and target:IsValid() then
        local delay = self.config.retry_delay
        if PATH_FAILURES[self.pending.failure_reason] then
            -- Retry a target the planner could not reach soon after the first
            -- failure, and only back off to retry_delay once it keeps failing.
            local fails = (self.pathfails[target] or 0) + 1
            self.pathfails[target] = fails
            delay = math.min(delay, PATH_RETRY_DELAY * 2 ^ (fails - 1))
        end
        self.cooldowns[target] = GetTime() + delay
        self.navigation_failures[target] = NAVIGATION_FAILURES[self.pending.failure_reason] == true or nil
    elseif success and target ~= nil then
        self.pathfails[target] = nil
        self.navigation_failures[target] = nil
    end
    if not success then
        self.last_failure = self.pending.failure_reason or (self.pending.replan and "target_changed" or "action_failed")
        self.last_failure_time = GetTime()
    end
    self:Trace(success and "job_success" or "job_failed", target, success and "" or self.last_failure)
    if self.pending.farm then
        -- Native/mod callbacks may give products directly to the collector.
        -- Return every real item to the ground before planning the next crop.
        self:DropHarvestCargo()
        if success then
            self.farm_count = self.farm_count + 1
            if self.farm_count >= 5 then self.farm_draining = true end
        end
    elseif success and (action.action == ACTIONS.PICK or action.action == ACTIONS.HARVEST) then
        -- Harvest callbacks may give extra seeds or overflow. Keep deliberate
        -- transport within its slot capacity; native DropItem preserves the item.
        local inventory = self.inst.components.inventory
        local extra = inventory:GetActiveItem()
        if extra ~= nil then inventory:DropItem(extra, true) end
    end
    self.pending = nil
    if success then self.nextscan = 0 end
    self:RefreshWatchdog()
    self:WakeBrain()
    local sg = self.inst.sg
    -- Native STORE opens the target. Successful animated delivery keeps it open
    -- until the store state's onexit; failures and non-animated jobs close now.
    local keep_open = success and action.action == ACTIONS.STORE
        and sg ~= nil and sg.currentstate ~= nil and sg.currentstate.name == "store"
    if self.inst.components.inventory ~= nil and not keep_open then
        self.inst.components.inventory:CloseAllChestContainers()
    end
    self.inst:PushEvent(success and "ac_jobsuccess" or "ac_jobfailed", { target = target, action = action })
end

function Worker:FailAction(action, replan, reason)
    if action == nil then return end
    if self.pending ~= nil and self.pending.action == action and replan then
        self.pending.replan = true
        self.nextscan = 0
    end
    if self.pending ~= nil and self.pending.action == action then self.pending.failure_reason = reason end
    -- Notify native DoAction listeners as well as releasing the worker's job.
    action:Fail()
    self:Finish(action, false)
end

function Worker:Cancel(replan, reason)
    if self.pending ~= nil then
        local action = self.pending.action
        self:FailAction(action, replan, reason)
    end
    self.inst.components.locomotor:Stop()
    self.inst.components.locomotor:Clear()
    self.inst:ClearBufferedAction()
    if self.inst.sg ~= nil then
        self.inst.sg:GoToState("idle")
    end
end

function Worker:SetEnabled(value)
    self.enabled = value == true
    self.inst._ac_enabled:set(self.enabled)
    if not self.enabled then
        self:Cancel()
    else
        self.nextscan = 0
        self.nextreturn = 0
        self:WakeBrain()
    end
    self.inst:PushEvent("ac_enabledchanged", { enabled = self.enabled })
end

function Worker:IsHarvestEnabled()
    return Upgrades.IsAdvanced(self.inst) and self.harvest_enabled
end

function Worker:SetHarvestEnabled(value)
    self.harvest_enabled = value == true
    self.inst._ac_harvest_enabled:set(self.harvest_enabled)
    if not self:IsHarvestEnabled() and self.pending ~= nil
        and self.pending.kind ~= "pickup" and self.pending.kind ~= "store" then
        -- Switching collection off releases only unfinished harvesting work.
        self:Cancel(true)
    end
    self.nextscan = 0
    self:WakeBrain()
    self.inst:PushEvent("ac_harvestenabledchanged", { enabled = self.harvest_enabled })
end

-- Upgrade hooks intentionally change timing rather than skip animations.
function Worker:SetActionSpeed(multiplier)
    self.action_speed = math.max(.25, math.min(4, multiplier))
end

function Worker:SetMoveSpeed(multiplier)
    self.inst.components.locomotor.walkspeed = self.config.walkspeed * math.max(.25, math.min(4, multiplier))
end

function Worker:ValidateAction(action)
    if not self:IsWorking() or action == nil or self.pending == nil or self.pending.action ~= action then
        return false
    end
    if self.pending.kind == "store" then
        return action.invobject ~= nil and action.invobject:IsValid()
            and action.invobject.components.inventoryitem.owner == self.inst
            and Targets.CanReceive(self, action.target, action.invobject)
    end
    local kind, nativeaction = Targets.Kind(self, action.target)
    if kind ~= self.pending.kind or nativeaction ~= action.action or not Targets.IsAvailable(self, action.target) then
        return false
    end
    if kind == "pickup" then
        return self:GetPickupCount(action.target) > 0
    end
    return self:CanHarvest(action.target, kind)
end

function Worker:Watchdog()
    if self.pending ~= nil and (not self:IsWorking()
        or GetTime() - self.pending.started > self.config.action_timeout) then
        local navigation = self.inst.components.locomotor._ac_navigation
        local reason = navigation ~= nil and navigation.searching and "search_timeout" or "timeout"
        self:Cancel(false, self:IsWorking() and reason or "inactive")
    elseif self.pending ~= nil and not self:ValidateAction(self.pending.action) then
        -- Targets can be picked, harvested or removed while we are still walking.
        -- Notify DoAction, release the claim and clear movement for every job kind.
        -- Changed world conditions are not a path failure and need no cooldown.
        self:Cancel(true)
    elseif self.pending == nil then
        -- World drops do not send events to nearby brains. Bound idle wakeup
        -- through the native scheduler even when its brain entry is sleeping.
        self:WakeBrain()
    end
end

function Worker:GetHomeAction()
    if not self:IsWorking() or self.pending ~= nil or GetTime() < self.nextreturn then return nil end
    local home = self:GetHome()
    if self.inst:GetDistanceSqToPoint(home) > 1 then
        local action = BufferedAction(self.inst, nil, ACTIONS.WALKTO, nil, home, nil, .5)
        action:AddSuccessAction(function() self.homepathfails, self.nextreturn = nil, 0 end)
        return action
    end
    self.homepathfails = nil
end

function Worker:GetNextAction(allow_return)
    if not self:IsWorking() or self.pending ~= nil or GetTime() < self.nextscan then
        return nil
    end
    self.nextscan = GetTime() + SCAN_INTERVAL
    self.lastscan = GetTime()
    if self.home == nil then
        self:SetHome()
    end
    local target, kind, action, cargo
    cargo = self:GetCargo()
    local entities = Targets.GetWorkEntities(self)
    if self.debug_enabled and GetTime() >= self.next_debug_scan then
        self.next_debug_scan = GetTime() + 1
        self:Trace("scan", nil, "entities=" .. tostring(#entities))
    end
    local harvesting = self:IsHarvestEnabled()
    if harvesting and cargo == nil and not self.farm_draining then
        target, kind, action = Targets.FindWork(self, "farm", entities)
        if target == nil and self.farm_count > 0 then
            -- Finish a short batch when no mature crop remains.
            self.farm_draining = true
        end
    end
    if harvesting and target == nil and self.farm_draining then
        target, kind, action = Targets.FindWork(self, "drain", entities)
        if target == nil and cargo == nil then
            -- Leave currently undeliverable drops on the ground and resume work.
            -- Capacity and target availability are checked again on future scans.
            self.farm_draining, self.farm_count = false, 0
            target, kind, action = Targets.FindWork(self, "farm", entities)
        end
    end
    if target == nil then
        target, kind, action = Targets.FindWork(self,
            (not harvesting or self.farm_draining) and "drain" or "normal", entities)
    end
    if cargo ~= nil then
        if target == nil then
            target = Targets.FindContainer(self, cargo)
            kind, action = "store", ACTIONS.STORE
        end
    end
    if target == nil then
        -- A real receiver still accepts this cargo, but its route failed.
        -- Keep the same entity aboard while retrying, rather than passing it
        -- between nearby cars that each have their own destination cooldowns.
        if cargo ~= nil and Targets.FindContainer(self, cargo, nil, true) ~= nil then
            self:SetBlocked(true)
            return nil
        end
        -- Native storage_robot's GoHomeAction drops one whole cargo stack at
        -- the current position before walking home. Do not keep undeliverable
        -- cargo aboard or discard other groups that may still have a destination.
        if cargo ~= nil then
            self.inst.components.inventory:DropItem(cargo, true, true)
        end
        self:SetBlocked(cargo ~= nil and self:GetCargo() == cargo)
        return allow_return ~= false and self:GetHomeAction() or nil
    end
    self:SetBlocked(false)
    if kind ~= "store" and not Targets.Claim(self, target) then
        return nil
    end
    local buffered = BufferedAction(self.inst, target, action, kind == "store" and cargo or nil)
    if kind == "pickup" then
        -- Winona's storage robot starts pickup from one unit away. Do not force
        -- collectors targeting overlapping drops to squeeze into the same point.
        buffered.arrivedist = 1
    end
    self.pending = { action = buffered, kind = kind, claimtarget = target,
        farm = Targets.IsFarmWork(target, kind), started = GetTime() }
    buffered:AddSuccessAction(function() self:Finish(buffered, true) end)
    buffered:AddFailAction(function() self:Finish(buffered, false) end)
    self:RefreshWatchdog()
    self:Trace("job_selected", target, kind)
    return buffered
end

function Worker:OnPickup(owner)
    self:Cancel()
    self.home, self.homeplatform, self.homelocal = nil, nil, nil
    self.farm_count, self.farm_draining = 0, false
    self:SyncHome()
    local inventory = self.inst.components.inventory
    while self:GetCargo() ~= nil do
        local cargo = inventory:RemoveItem(self:GetCargo(), true)
        if cargo == nil then
            break
        end
        if owner ~= nil and owner.components.inventory ~= nil then
            owner.components.inventory:GiveItem(cargo, nil, self.inst:GetPosition())
        else
            inventory:GiveItem(cargo)
            inventory:DropEverything()
            break
        end
    end
    self:SetBlocked(false)
end

function Worker:OnDropped()
    self:Cancel()
    self:SetHome()
    self.farm_count, self.farm_draining = 0, false
    self.cooldowns = setmetatable({}, { __mode = "k" })
    self.pathfails = setmetatable({}, { __mode = "k" })
    self.navigation_failures = setmetatable({}, { __mode = "k" })
    self.homepathfails = nil
    self.nextscan = 0
    self.nextreturn = 0
    self:SetEnabled(true)
end

function Worker:OnSave()
    local data = { enabled = self.enabled, harvest_enabled = self.harvest_enabled,
        carryslots = self:GetCarrySlots(),
        farm_count = self.farm_count, farm_draining = self.farm_draining }
    if self.home ~= nil then
        data.home = { x = self.home.x, z = self.home.z }
    end
    if self.homeplatform ~= nil and self.homeplatform:IsValid() and self.homelocal ~= nil then
        data.platform = self.homeplatform.GUID
        data.homelocal = { x = self.homelocal.x, z = self.homelocal.z }
        return data, { data.platform }
    end
    return data
end

function Worker:OnPreLoad(data)
    -- Must run before inventory loads, irrespective of component load order.
    self:SetCarrySlots(data ~= nil and data.carryslots or 1)
end

function Worker:OnLoad(data)
    if data == nil then return end
    self:OnPreLoad(data)
    if data.harvest_enabled == nil then
        -- The old player pause becomes a harvest preference; transport resumes.
        self.enabled = true
        self.harvest_enabled = data.enabled ~= false
    else
        self.enabled = data.enabled ~= false
        self.harvest_enabled = data.harvest_enabled ~= false
    end
    local count = data.farm_count
    self.farm_count = type(count) == "number" and count == count
        and math.max(0, math.min(5, math.floor(count))) or 0
    self.farm_draining = data.farm_draining == true or self.farm_count >= 5
    self.inst._ac_enabled:set(self.enabled)
    self.inst._ac_harvest_enabled:set(self.harvest_enabled)
    if data.home ~= nil then
        self.home = Vector3(data.home.x, 0, data.home.z)
    end
    self:SyncHome()
end

function Worker:LoadPostPass(ents, data)
    local platform = data ~= nil and data.platform ~= nil and ents[data.platform] or nil
    if platform ~= nil and data.homelocal ~= nil then
        self.homeplatform = platform.entity
        self.homelocal = Vector3(data.homelocal.x, 0, data.homelocal.z)
        self:SyncHome()
    end
end

function Worker:OnRemoveFromEntity()
    if self.task ~= nil then self.task:Cancel() end
    if self.pending ~= nil then Targets.Release(self, self.pending.claimtarget or self.pending.action.target) end
end

function Worker:GetDebugString()
    local time = GetTime()
    local cooling, retry_in = 0, nil
    for target, untiltime in pairs(self.cooldowns) do
        if target:IsValid() and untiltime > time then
            cooling = cooling + 1
            retry_in = math.min(retry_in or math.huge, untiltime - time)
        end
    end
    local brain, queue = self.inst.brain, "none"
    if brain ~= nil then
        queue = brain.stopped and "stopped" or (brain.paused and "paused" or "active")
        if BrainManager ~= nil and BrainManager.NameList ~= nil and not brain.stopped and not brain.paused then
            queue = BrainManager:NameList(BrainManager.instances[brain])
        end
    end
    local sg = self.inst.sg
    local state = sg ~= nil and sg.currentstate ~= nil and sg.currentstate.name or "none"
    local loco = self.inst.components.locomotor
    local returning = loco ~= nil and loco.bufferedaction ~= nil and loco.bufferedaction.action == ACTIONS.WALKTO
    return string.format("enabled=%s harvest=%s cargo=%s job=%s farm=%d/5 draining=%s state=%s brain=%s scan_age=%.2f scan_in=%.2f returning=%s cooldowns=%d retry_in=%.2f last_failure=%s failure_age=%.2f", tostring(self.enabled),
        tostring(self:IsHarvestEnabled()),
        tostring(self:GetCargo() ~= nil), self.pending ~= nil and self.pending.kind or "idle",
        self.farm_count, tostring(self.farm_draining), state, queue,
        self.lastscan ~= nil and time - self.lastscan or -1, math.max(0, self.nextscan - time),
        tostring(returning), cooling, retry_in or 0, self.last_failure or "none",
        self.last_failure_time ~= nil and time - self.last_failure_time or -1)
end

return Worker
