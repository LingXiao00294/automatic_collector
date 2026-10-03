local Upgrades = require("ac_upgrades")

local UpgradeItem = Class(function(self, inst)
    self.inst = inst
end)

local function ValidTarget(target)
    return target ~= nil and target:IsValid() and target:HasTag("automatic_collector")
        and not target:HasTag("INLIMBO") and target.components.ac_worker ~= nil
        and target.components.ac_upgradable ~= nil and target.components.inventoryitem ~= nil
        and not target.components.inventoryitem:IsHeld()
end

function UpgradeItem:CanInstall(doer, target)
    if not ValidTarget(target) then return false, "INVALID_TARGET" end
    if target.components.ac_upgradable:GetLevel(Upgrades.CHASSIS) > 0 then
        return false, "ALREADY_UPGRADED"
    end
    local item = self.inst
    if doer == nil or not doer:IsValid() or not doer:HasTag("player")
        or doer:HasTag("playerghost") or doer.components.inventory == nil
        or (doer.components.health ~= nil and doer.components.health:IsDead())
        or not item:IsValid() or item.components.inventoryitem == nil
        or item.components.inventoryitem:GetGrandOwner() ~= doer
        or item.components.inventoryitem.islockedinslot
        or (item.components.stackable ~= nil and item.components.stackable:StackSize() < 1)
        or doer:GetDistanceSqToInst(target) > 16 then
        return false, "INVALID_TARGET"
    end
    return true
end

function UpgradeItem:Install(doer, target)
    if not TheWorld.ismastersim then return false end
    local valid, reason = self:CanInstall(doer, target)
    if not valid then return false, reason end
    if self.installing or target._ac_installing then return false, "BUSY" end
    self.installing, target._ac_installing = true, true
    local upgrade = target.components.ac_upgradable
    local worker = target.components.ac_worker
    local locomotor = target.components.locomotor
    local old_move = locomotor.walkspeed
    local old_action = worker.action_speed
    local old_applied = upgrade.applied[Upgrades.CHASSIS]
    local portion, applied
    -- One synchronous commit; never yield between detaching one item and applying the level.
    local ok, success, failure = pcall(function()
        worker:Cancel(true)
        target.components.inventory:CloseAllChestContainers()
        local still_valid, why = self:CanInstall(doer, target)
        if not still_valid then return false, why end
        portion = doer.components.inventory:RemoveItem(self.inst, false)
        if portion == nil or not portion:IsValid() or portion.components.inventoryitem:IsHeld()
            or (portion.components.stackable ~= nil and portion.components.stackable:StackSize() ~= 1) then
            return false, "INSTALL_FAILED"
        end
        portion.Transform:SetPosition(doer.Transform:GetWorldPosition())
        if not ValidTarget(target) or upgrade:GetLevel(Upgrades.CHASSIS) > 0 then
            return false, "INVALID_TARGET"
        end
        applied = true -- SetLevel may throw after partially applying or dispatching an event.
        if not upgrade:SetLevel(Upgrades.CHASSIS, 1) then return false, "INSTALL_FAILED" end
        if not ValidTarget(target) or upgrade:GetLevel(Upgrades.CHASSIS) ~= 1 then
            return false, "INVALID_TARGET"
        end
        portion:Remove()
        return true
    end)
    -- Remove callbacks can throw after removal. A consumed item and applied level are a commit.
    local committed = applied and portion ~= nil and not portion:IsValid()
        and upgrade:GetLevel(Upgrades.CHASSIS) == 1
    local recovered, recovery_error = pcall(function()
        if committed then return end
        if applied then
            upgrade.levels[Upgrades.CHASSIS] = nil
            upgrade.applied[Upgrades.CHASSIS] = old_applied
            if target:IsValid() then
                local restored, err = pcall(Upgrades.Apply, target, 0)
                if not restored then print("[automatic_collector] Upgrade rollback: " .. tostring(err)) end
            end
            locomotor.walkspeed = old_move
            worker.action_speed = old_action
        end
        if portion ~= nil and portion:IsValid() and not portion.components.inventoryitem:IsHeld() then
            -- Native inventory returns leftovers to the ground if no slot is available.
            if doer:IsValid() then
                local returned, err = pcall(function()
                    doer.components.inventory:GiveItem(portion, nil, doer:GetPosition())
                end)
                if not returned then print("[automatic_collector] Returning upgrade kit: " .. tostring(err)) end
            end
        end
    end)
    self.installing, target._ac_installing = nil, nil
    if not recovered then print("[automatic_collector] Upgrade recovery: " .. tostring(recovery_error)) end
    if not ok then print("[automatic_collector] Upgrade installation: " .. tostring(success)) end
    if not committed then return false, (ok and failure) or "INSTALL_FAILED" end
    worker.nextscan = 0
    if target:IsValid() then
        local shown, err = pcall(function() target.sg:GoToState("upgrade") end)
        if not shown then print("[automatic_collector] Upgrade feedback: " .. tostring(err)) end
    end
    return true
end

return UpgradeItem
