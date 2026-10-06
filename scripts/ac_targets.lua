local M = {}
local API = require("ac_api")
local Compat = require("ac_compat")
local claims = setmetatable({}, { __mode = "k" })
local EXCLUDE = { "INLIMBO", "FX", "NOCLICK", "DECOR", "fire", "outofreach", "ac_ignore" }
local UNSAFE = { "irreplaceable", "catchable", "trap", "mineactive", "cursed", "spider", "heavy", "storagerobot", "automatic_collector" }

function M.IsAvailable(worker, target)
    local claim = claims[target]
    return claim == nil or claim.owner == worker.inst or not claim.owner:IsValid() or claim.untiltime <= GetTime()
end

function M.Claim(worker, target)
    if not M.IsAvailable(worker, target) then
        return false
    end
    claims[target] = { owner = worker.inst, untiltime = GetTime() + worker.config.action_timeout + 2 }
    return true
end

function M.Release(worker, target)
    if target ~= nil and claims[target] ~= nil and claims[target].owner == worker.inst then
        claims[target] = nil
    end
end

function M.IsSafe(worker, target, radius)
    if target == nil or not target:IsValid() or target == worker.inst or target:HasAnyTag(EXCLUDE) then
        return false
    end
    local item = target.components.inventoryitem
    if item ~= nil and item:IsHeld() then
        return false
    end
    if target.components.burnable ~= nil and target.components.burnable:IsBurning() then
        return false
    end
    local home = worker:GetHome()
    return target:IsOnPassablePoint()
        and target:GetCurrentPlatform() == worker.inst:GetCurrentPlatform()
        and target:GetDistanceSqToPoint(home) <= (radius or worker.radius) ^ 2
end

function M.Kind(worker, target)
    if not M.IsSafe(worker, target, worker.radius + 2) then
        return nil
    end
    local workable = target.components.workable
    if worker:IsHarvestEnabled() and worker.config.hammer_giants and target:HasTag("oversized_veggie")
        and not (target.prefab ~= nil and target.prefab:match("_waxed$")) and workable ~= nil
        and workable:CanBeWorked() and workable:GetWorkAction() == ACTIONS.HAMMER then
        return "hammer", ACTIONS.AC_HAMMER
    end
    local item = target.components.inventoryitem
    if item ~= nil and item.canbepickedup and item.cangoincontainer and not item:IsHeld()
        and not target:HasAnyTag(UNSAFE) and target.components.container == nil
        and target.components.health == nil and target.components.trap == nil
        and (target.components.bait == nil or target.components.bait.trap == nil)
        and (target.components.projectile == nil or not target.components.projectile:IsThrown()) then
        return "pickup", ACTIONS.PICKUP
    end
    if not worker:IsHarvestEnabled() or not worker.config.pick_plants or not M.IsSafe(worker, target) then
        return nil
    end
    local pickable = target.components.pickable
    if pickable ~= nil and pickable:CanBePicked() and pickable.caninteractwith
        and not pickable:IsStuck() and not target:HasTag("skeleton") then
        return "pick", ACTIONS.PICK
    end
    if target.components.crop ~= nil and target.components.crop.matured then
        return "harvest", ACTIONS.HARVEST
    end
    -- Registration maintains stable ordering; candidate scans reuse it without sorting.
    for _, name in ipairs(API.GetAdapterNames()) do
        local adapter = API.adapters[name]
        if adapter.match(worker.inst, target) then
            return "adapter:" .. name, adapter.action(worker.inst, target)
        end
    end
end

function M.IsDeliveryContainer(worker, target)
    if not M.IsSafe(worker, target) or target:HasAnyTag({ "companion", "portablestorage", "mermonly", "mastercookware", "ac_no_delivery" }) then
        return false
    end
    local container = target.components.container
    if container == nil or container.readonlycontainer or not container.canbeopened
        or (container.type ~= "chest" and not target:HasTag("ac_delivery_container"))
        or target.components.stewer ~= nil or target.components.dryingrack ~= nil
        or container:IsRestricted(worker.inst) then
        return false
    end
    return true
end

function M.IsContainer(worker, target)
    -- Native storage robots choose receivers by item acceptance, not openers.
    return M.IsDeliveryContainer(worker, target)
end

function M.IsFarmWork(target, kind)
    return kind ~= "pickup" and kind ~= "hammer" and (
        target:HasTag("farm_plant") or target:HasTag("medal_fruit_tree")
        or target.components.crop ~= nil or target.components.perennialcrop ~= nil
        or target.components.perennialcrop2 ~= nil)
end

function M.GetWorkEntities(worker)
    local x, y, z = worker:GetHome():Get()
    return TheSim:FindEntities(x, y, z, worker.radius + 2, nil, EXCLUDE)
end

function M.CanReceive(worker, target, item, requiredcount)
    if not M.IsContainer(worker, target) then return false end
    local container = target.components.container
    local count = requiredcount or (item.components.stackable ~= nil and item.components.stackable:StackSize() or 1)
    return (not worker.config.matching_only or container:Has(item.prefab, 1))
        and container:CanAcceptCount(item, count) >= count
end

function M.FindContainer(worker, item, requiredcount, allow_waiting)
    local best, bestscore
    for _, target in ipairs(M.GetContainers(worker)) do
        if (not worker:IsCoolingDown(target) or (allow_waiting and worker:IsWaitingForRoute(target)))
            and M.CanReceive(worker, target, item, requiredcount) then
            local container = target.components.container
            local matching = container:Has(item.prefab, 1)
            local score = (matching and 0 or 100000) + worker.inst:GetDistanceSqToInst(target)
            if bestscore == nil or score < bestscore then
                best, bestscore = target, score
            end
        end
    end
    return best
end

-- Use the real item (including skin and mod filters) without changing its stack.
function M.DeliveryCapacity(worker, item, maxcount)
    local capacity = 0
    for _, target in ipairs(M.GetContainers(worker)) do
        if M.IsContainer(worker, target) and not worker:IsCoolingDown(target) then
            local container = target.components.container
            if not worker.config.matching_only or container:Has(item.prefab, 1) then
                capacity = math.max(capacity, container:CanAcceptCount(item, maxcount))
            end
        end
    end
    return math.min(capacity, maxcount)
end

function M.GetContainers(worker)
    if worker._containercache == nil or worker._containercache.time < GetTime() then
        local x, y, z = worker:GetHome():Get()
        worker._containercache = {
            time = GetTime(),
            entities = TheSim:FindEntities(x, y, z, worker.radius, { "_container" }, EXCLUDE),
        }
    end
    return worker._containercache.entities
end

-- Describe only the primary yield; do not spawn preview items or run loot callbacks.
function M.HarvestProduct(worker, target, kind)
    if kind ~= nil and kind:sub(1, 8) == "adapter:" then
        local adapter = API.adapters[kind:sub(9)]
        if adapter ~= nil and adapter.product ~= nil then
            return adapter.product(worker.inst, target)
        end
        return nil
    end
    local info = Compat.HarvestInfo(target)
    if info ~= nil then return info.product, info.count end
    if target:HasTag("farm_plant") and target.plant_def ~= nil then
        if target.is_oversized then return nil end
        return target:HasTag("farm_plant_killjoy") and "spoiled_food" or target.plant_def.product, 1
    end
    local pickable, crop = target.components.pickable, target.components.crop
    if pickable ~= nil then
        if not pickable.use_lootdropper_for_product then
            return pickable.product, pickable.numtoharvest or 1
        end
        local lootdropper = target.components.lootdropper
        if lootdropper ~= nil and lootdropper.lootsetupfn == nil
            and lootdropper.chanceloottable == nil and lootdropper.chanceloot == nil
            and (lootdropper.numrandomloot or 0) == 0 then
            local loot = lootdropper.loot or {}
            local product, count = loot[1], 0
            for _, prefab in ipairs(loot) do
                if prefab == product then count = count + 1 end
            end
            return product, count
        end
    elseif crop ~= nil then
        return crop.product_prefab, 1
    end
end

-- A preflight check without spawning fake products or invoking another mod's harvest code.
-- Exact slot filters are evaluated using the real cargo at delivery time.
function M.HasHarvestDestination(worker, target, kind)
    local products = {}
    local pickable, crop = target.components.pickable, target.components.crop
    if pickable ~= nil and pickable.product ~= nil then
        products = { pickable.product }
    elseif crop ~= nil and crop.product_prefab ~= nil then
        products = { crop.product_prefab }
    elseif target.components.lootdropper ~= nil then
        products = target.components.lootdropper.loot or {}
    end
    if target:HasTag("farm_plant") and target.plant_def ~= nil then
        -- Large vegetables are worked on the ground; ordinary crops include seeds.
        products = { target:HasTag("farm_plant_killjoy") and "spoiled_food" or target.plant_def.product }
    end
    local info = Compat.HarvestInfo(target)
    if info ~= nil then products = info.products end
    if kind ~= nil and kind:sub(1, 8) == "adapter:" then
        local product = M.HarvestProduct(worker, target, kind)
        if product ~= nil then products = { product } end
    end
    for _, chest in ipairs(M.GetContainers(worker)) do
        if M.IsContainer(worker, chest) and not worker:IsCoolingDown(chest) then
            local c = chest.components.container
            local matches = not worker.config.matching_only
            if not matches and #products > 0 then
                -- Ground loot is collected and delivered in separate groups.
                -- One known product sample suffices; others may stay on the ground.
                for _, product in ipairs(products) do
                    if c:Has(product, 1) then
                        matches = true
                        break
                    end
                end
            end
            if matches then
                if not c:IsFull() then
                    return true
                end
                for _, item in pairs(c.slots) do
                    if item.components.stackable ~= nil and not item.components.stackable:IsFull() then
                        for _, product in ipairs(products) do
                            if item.prefab == product then
                                return true
                            end
                        end
                    end
                end
            end
        end
    end
    return false
end

function M.FindWork(worker, mode, entities)
    local best, bestkind, bestaction, bestscore
    local priority = { pickup = 0, hammer = 1, pick = 2, harvest = 2 }
    local empty = worker:GetCargo() == nil
    for _, target in ipairs(entities or M.GetWorkEntities(worker)) do
        if M.IsAvailable(worker, target) and not worker:IsCoolingDown(target) then
            local kind, action = M.Kind(worker, target)
            local farm = kind ~= nil and M.IsFarmWork(target, kind)
            local allowed = mode == "farm" and (farm or kind == "hammer")
                or mode == "drain" and (kind == "pickup" or kind == "hammer")
                or mode == "normal" and not farm or mode == nil
            if allowed and kind ~= nil and action ~= nil then
                local destination = kind == "pickup" and worker:GetPickupCount(target) > 0
                    or kind ~= "pickup" and worker:CanHarvest(target, kind)
                if destination then
                    local rank = priority[kind] or 3
                    -- Prepare every available giant before starting a cargo group.
                    -- Once carrying, fill/deliver that group before starting new work.
                    if empty and kind == "hammer" then
                        rank = -2
                    elseif empty and kind == "pick" and Compat.IsGiantPlant(target) then
                        rank = -1
                    end
                    local score = rank * 100000 + worker.inst:GetDistanceSqToInst(target)
                    if bestscore == nil or score < bestscore then
                        best, bestkind, bestaction, bestscore = target, kind, action, score
                    end
                end
            end
        end
    end
    return best, bestkind, bestaction
end

return M
