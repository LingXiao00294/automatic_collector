local API = { VERSION = 2, adapters = {}, upgrades = {}, features = {} }
local adapter_names = {}
local feature_names = {}

function API.IsFeatureName(name)
    return type(name) == "string" and #name <= 48 and name:match("^[a-z][a-z0-9_]*$") ~= nil
end

-- Feature definitions must be registered identically on the server and clients.
-- Preferences use one fixed net_string, so adding a feature needs no prefab netvars.
function API.RegisterFeature(name, feature)
    assert(API.IsFeatureName(name) and type(feature) == "table", "Invalid collector feature")
    assert(type(feature.label) == "string", "Feature needs a label")
    assert(feature.description == nil or type(feature.description) == "string", "Invalid feature description")
    assert(feature.default == nil or type(feature.default) == "boolean", "Invalid feature default")
    assert(feature.config_key == nil or type(feature.config_key) == "string", "Invalid feature config")
    assert(feature.order == nil or type(feature.order) == "number"
        and feature.order == feature.order and math.abs(feature.order) < math.huge, "Invalid feature order")
    if API.features[name] == nil then table.insert(feature_names, name) end
    API.features[name] = feature
    table.sort(feature_names, function(a, b)
        local left, right = API.features[a].order or 100, API.features[b].order or 100
        return left == right and a < b or left < right
    end)
end

function API.GetFeatureNames()
    return feature_names
end

API.RegisterFeature("harvest_crops", {
    label = "采集作物", default = true, order = 10, config_key = "pick_plants",
    description = "收获成熟农作物，包含巨大植株；每 5 个集中运输。",
})
API.RegisterFeature("pick_plants", {
    label = "采集植物", default = true, order = 20, config_key = "pick_plants",
    description = "采摘草、树枝、浆果等普通资源。",
})
API.RegisterFeature("hammer_giants", {
    label = "敲巨大作物", default = true, order = 30, config_key = "hammer_giants",
    description = "敲开已经落地的巨大果实；保留打蜡果实。",
})

function API.RegisterAdapter(name, adapter)
    assert(type(name) == "string" and type(adapter) == "table", "Invalid collector adapter")
    assert(type(adapter.match) == "function" and type(adapter.action) == "function", "Adapter needs match/action")
    assert(adapter.product == nil or type(adapter.product) == "function", "Adapter product must be a function")
    assert(adapter.feature == nil or API.IsFeatureName(adapter.feature), "Invalid adapter feature")
    if API.adapters[name] == nil then
        table.insert(adapter_names, name)
        table.sort(adapter_names)
    end
    API.adapters[name] = adapter
end

-- Shared read-only view: registering a new name is the only ordering change.
function API.GetAdapterNames()
    return adapter_names
end

function API.RegisterUpgrade(name, upgrade)
    assert(type(name) == "string" and type(upgrade) == "table", "Invalid collector upgrade")
    API.upgrades[name] = upgrade
end

return API
