local Targets = require("ac_targets")

local Worker = Class(function(self, inst)
    self.inst = inst
    self.config = TUNING.AUTOMATIC_COLLECTOR
    self.radius = self.config.radius
    self.enabled = true
    self.home = nil
    self.homeplatform = nil
    self.homelocal = nil
    self.pending = nil
    self.cooldowns = setmetatable({}, { __mode = "k" })
    self.action_speed = 1
    self.nextscan = 0
    self.blocked = false
    self.task = inst:DoPeriodicTask(.5, function() self:Watchdog() end)
end)

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
end

function Worker:IsCoolingDown(target)
    return (self.cooldowns[target] or 0) > GetTime()
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
    local inventory = self.inst.components.inventory
    if inventory:GetActiveItem() ~= nil then return false end
    if self:GetCargo() == nil then
        return Targets.HasHarvestDestination(self, target)
    end
    -- Giant work produces ground loot rather than adding to the current stack.
    if kind == "hammer" or (target:HasTag("farm_plant") and target.is_oversized) then
        return false
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
    return empty and Targets.HasHarvestDestination(self, target)
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
    self.inst:PerformBufferedAction()
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
    local target = self.pending.claimtarget or action.target
    Targets.Release(self, target)
    if not success and target ~= nil and target:IsValid() then
        self.cooldowns[target] = GetTime() + self.config.retry_delay
    end
    if success and (action.action == ACTIONS.PICK or action.action == ACTIONS.HARVEST) then
        -- Harvest callbacks may give extra seeds or overflow. Keep deliberate
        -- transport within its slot capacity; native DropItem preserves the item.
        local inventory = self.inst.components.inventory
        local extra = inventory:GetActiveItem()
        if extra ~= nil then inventory:DropItem(extra, true) end
    end
    self.pending = nil
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

function Worker:Cancel()
    if self.pending ~= nil then
        local action = self.pending.action
        self:Finish(action, false)
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
    end
    self.inst:PushEvent("ac_enabledchanged", { enabled = self.enabled })
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
            and Targets.IsContainer(self, action.target)
            and Targets.FindContainer(self, action.invobject) == action.target
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
        self:Cancel()
    end
end

function Worker:GetNextAction()
    if not self:IsWorking() or self.pending ~= nil or GetTime() < self.nextscan then
        return nil
    end
    self.nextscan = GetTime() + .5
    if self.home == nil then
        self:SetHome()
    end
    local target, kind, action, cargo
    cargo = self:GetCargo()
    if cargo ~= nil then
        target, kind, action = Targets.FindWork(self)
        if target == nil then
            target = Targets.FindContainer(self, cargo)
            kind, action = "store", ACTIONS.STORE
        end
    else
        target, kind, action = Targets.FindWork(self)
    end
    self:SetBlocked(cargo ~= nil and target == nil)
    if target == nil then
        local home = self:GetHome()
        if cargo == nil and self.inst:GetDistanceSqToPoint(home) > 1 then
            return BufferedAction(self.inst, nil, ACTIONS.WALKTO, nil, home, nil, .5)
        end
        return nil
    end
    if kind ~= "store" and not Targets.Claim(self, target) then
        return nil
    end
    local buffered = BufferedAction(self.inst, target, action, kind == "store" and cargo or nil)
    if kind == "pickup" then
        -- Drive over the item before sinking, without changing global PICKUP.
        buffered.arrivedist = .15
    end
    self.pending = { action = buffered, kind = kind, claimtarget = target, started = GetTime() }
    buffered:AddSuccessAction(function() self:Finish(buffered, true) end)
    buffered:AddFailAction(function() self:Finish(buffered, false) end)
    return buffered
end

function Worker:OnPickup(owner)
    self:Cancel()
    self.home, self.homeplatform, self.homelocal = nil, nil, nil
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
    self.cooldowns = setmetatable({}, { __mode = "k" })
    self.nextscan = GetTime() + .5
    self:SetEnabled(true)
end

function Worker:OnSave()
    local data = { enabled = self.enabled, carryslots = self:GetCarrySlots() }
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
    self.enabled = data.enabled ~= false
    self.inst._ac_enabled:set(self.enabled)
    if data.home ~= nil then
        self.home = Vector3(data.home.x, 0, data.home.z)
    end
end

function Worker:LoadPostPass(ents, data)
    local platform = data ~= nil and data.platform ~= nil and ents[data.platform] or nil
    if platform ~= nil and data.homelocal ~= nil then
        self.homeplatform = platform.entity
        self.homelocal = Vector3(data.homelocal.x, 0, data.homelocal.z)
    end
end

function Worker:OnRemoveFromEntity()
    if self.task ~= nil then self.task:Cancel() end
    if self.pending ~= nil then Targets.Release(self, self.pending.claimtarget or self.pending.action.target) end
end

function Worker:GetDebugString()
    return string.format("enabled=%s cargo=%s job=%s", tostring(self.enabled),
        tostring(self:GetCargo() ~= nil), self.pending ~= nil and self.pending.kind or "idle")
end

return Worker
