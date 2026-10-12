local API = require("ac_api")
local Features = require("ac_features")
local Upgrades = require("ac_upgrades")
local M = { NAMESPACE = "automatic_collector", RANGE = 30 }
local sessions = setmetatable({}, { __mode = "k" })

function M.CanUse(player, target)
    return type(player) == "table" and type(target) == "table"
        and type(player.IsValid) == "function" and type(target.IsValid) == "function"
        and player:IsValid() and target:IsValid()
        and player:HasTag("player") and not player:HasTag("playerghost") and not player:HasTag("corpse")
        and (player.replica == nil or player.replica.health == nil or not player.replica.health:IsDead())
        and target:HasTag("automatic_collector") and Upgrades.IsAdvanced(target)
        and not target:HasTag("INLIMBO") and not target:HasTag("fire")
        and player:GetCurrentPlatform() == target:GetCurrentPlatform()
        and player:GetDistanceSqToInst(target) <= M.RANGE ^ 2
end

local function CanConfigure(player, target)
    if TheWorld == nil or not TheWorld.ismastersim or not M.CanUse(player, target) then return false end
    local item = target.components.inventoryitem
    return item ~= nil and not item:IsHeld() and target.components.ac_worker ~= nil
        and (player.components.health == nil or not player.components.health:IsDead())
end

function M.BeginSession(player, target)
    if not CanConfigure(player, target) or player.userid == nil
        or player:GetDistanceSqToInst(target) > 4 ^ 2 then return false end
    sessions[player] = target
    SendModRPCToClient(GetClientModRPC(M.NAMESPACE, "OpenPanel"), player.userid, target)
    return true
end

function M.EndSession(player, target)
    if player ~= nil and sessions[player] == target then sessions[player] = nil end
end

local function ApplyFeature(player, target, name, value)
    if not CanConfigure(player, target) then
        if player ~= nil then sessions[player] = nil end
        return false
    end
    if sessions[player] ~= target or type(name) ~= "string" or type(value) ~= "boolean"
        or API.features[name] == nil then return false end
    local worker = target.components.ac_worker
    if value and not Features.IsAllowed(name, worker.config) then return false end
    return worker:SetFeatureEnabled(name, value)
end

function M.SetFeature(player, target, name, value, request_id)
    -- Native RPC bool parameters may use nil for false. A numeric wire value
    -- makes both states explicit instead of rejecting a valid off request.
    local enabled = value == 1 or value == true
    local valid_value = value == 0 or value == 1 or type(value) == "boolean"
    local success = valid_value and ApplyFeature(player, target, name, enabled) or false
    if type(request_id) == "number" and request_id == math.floor(request_id)
        and request_id > 0 and request_id <= 2147483647
        and type(name) == "string" and type(player) == "table" and player.userid ~= nil then
        local worker = type(target) == "table" and target.components ~= nil
            and target.components.ac_worker or nil
        local snapshot = worker ~= nil and Features.Encode(worker.feature_enabled, worker.feature_revision) or ""
        SendModRPCToClient(GetClientModRPC(M.NAMESPACE, "FeatureResult"), player.userid,
            target, name, request_id, success and 1 or 0, snapshot)
    end
    return success
end

function M.RequestFeature(target, name, value, request_id)
    SendModRPCToServer(GetModRPC(M.NAMESPACE, "SetFeature"), target, name, value and 1 or 0, request_id)
end

function M.FeatureResult(target, name, request_id, accepted, snapshot)
    if M.screen ~= nil and M.screen.target == target then
        M.screen:ApplyResult(name, request_id, accepted == 1, snapshot)
    end
end

function M.OpenPanel(target)
    if TheNet:IsDedicated() or TheFrontEnd == nil or not M.CanUse(ThePlayer, target) then return end
    if M.screen ~= nil then
        if M.screen.target == target then M.screen:Refresh() return end
        M.screen:Close()
    end
    local Panel = require("screens/ac_controlpanel")
    M.screen = Panel(ThePlayer, target, M.RequestFeature, function(screen)
        if M.screen == screen then M.screen = nil end
        SendModRPCToServer(GetModRPC(M.NAMESPACE, "ClosePanel"), target)
    end)
    TheFrontEnd:PushScreen(M.screen)
end

return M
