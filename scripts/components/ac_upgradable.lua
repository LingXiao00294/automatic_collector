local API = require("ac_api")

local Upgradable = Class(function(self, inst)
    self.inst = inst
    self.levels = {}
    self.applied = {}
end)

function Upgradable:GetLevel(name)
    return self.levels[name] or 0
end

function Upgradable:Apply(name)
    local upgrade = API.upgrades[name]
    if upgrade == nil then
        return -- Keep unknown saved upgrades, so disabling an extension does not erase them.
    end
    local level = self:GetLevel(name)
    if upgrade.apply ~= nil then
        upgrade.apply(self.inst, level, self.applied[name] or 0)
    end
    self.applied[name] = level
end

function Upgradable:SetLevel(name, level)
    local upgrade = API.upgrades[name]
    if upgrade == nil or type(level) ~= "number" or level ~= level then
        return false
    end
    level = math.max(0, math.min(upgrade.maxlevel or 1, math.floor(level)))
    self.levels[name] = level > 0 and level or nil
    self:Apply(name)
    self.inst:PushEvent("ac_upgradechanged", { name = name, level = level })
    return true
end

function Upgradable:OnSave()
    local levels = {}
    for name, level in pairs(self.levels) do
        levels[name] = level
    end
    return { levels = levels }
end

function Upgradable:OnLoad(data)
    self.levels = {}
    for name, level in pairs(data ~= nil and data.levels or {}) do
        if type(name) == "string" and type(level) == "number" and level == level and level > 0 then
            self.levels[name] = math.floor(level)
        end
    end
    self.inst:DoTaskInTime(0, function()
        for name in pairs(self.levels) do
            local upgrade = API.upgrades[name]
            if upgrade ~= nil then
                self.levels[name] = math.min(self.levels[name], upgrade.maxlevel or 1)
            end
            self:Apply(name)
        end
    end)
end

return Upgradable
