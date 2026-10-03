local API = { VERSION = 1, adapters = {}, upgrades = {} }
local adapter_names = {}

function API.RegisterAdapter(name, adapter)
    assert(type(name) == "string" and type(adapter) == "table", "Invalid collector adapter")
    assert(type(adapter.match) == "function" and type(adapter.action) == "function", "Adapter needs match/action")
    assert(adapter.product == nil or type(adapter.product) == "function", "Adapter product must be a function")
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
