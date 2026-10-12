local API = require("ac_api")
local M = {}

function M.Defaults(enabled)
    local values = {}
    for _, name in ipairs(API.GetFeatureNames()) do
        values[name] = enabled ~= false and API.features[name].default ~= false
    end
    return values
end

-- The restricted identifiers make this wire format unambiguous. Unknown saved
-- preferences survive when an extension is temporarily absent.
function M.Encode(values, revision)
    local names, encoded = {}, {}
    for name, value in pairs(values) do
        if API.IsFeatureName(name) and type(value) == "boolean" then table.insert(names, name) end
    end
    table.sort(names)
    for _, name in ipairs(names) do
        table.insert(encoded, name .. "=" .. (values[name] and "1" or "0"))
    end
    local snapshot = table.concat(encoded, ";")
    return revision ~= nil and tostring(revision) .. ":" .. snapshot or snapshot
end

function M.GetRevision(encoded)
    return tonumber(encoded:match("^(%d+):")) or 0
end

function M.Decode(encoded)
    local values = {}
    for key, value in encoded:gmatch("([a-z][a-z0-9_]*)=([01])") do values[key] = value == "1" end
    return values
end

function M.GetValue(values, name)
    local definition = API.features[name]
    if definition == nil then return false end
    local value = values[name]
    return value == nil and definition.default ~= false or value == true
end

function M.GetPreference(inst, name)
    local definition = API.features[name]
    if definition == nil then return false end
    local encoded = inst._ac_features ~= nil and inst._ac_features:value() or ""
    if inst._ac_feature_snapshot ~= encoded then
        inst._ac_feature_snapshot = encoded
        inst._ac_feature_values = M.Decode(encoded)
    end
    return M.GetValue(inst._ac_feature_values, name)
end

function M.IsAllowed(name, config)
    local definition = API.features[name]
    return definition ~= nil and (definition.config_key == nil or config[definition.config_key] ~= false)
end

return M
