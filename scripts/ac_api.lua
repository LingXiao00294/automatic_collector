local API = { VERSION = 1, adapters = {}, upgrades = {} }

function API.RegisterAdapter(name, adapter)
    assert(type(name) == "string" and type(adapter) == "table", "Invalid collector adapter")
    assert(type(adapter.match) == "function" and type(adapter.action) == "function", "Adapter needs match/action")
    assert(adapter.product == nil or type(adapter.product) == "function", "Adapter product must be a function")
    API.adapters[name] = adapter
end

function API.RegisterUpgrade(name, upgrade)
    assert(type(name) == "string" and type(upgrade) == "table", "Invalid collector upgrade")
    API.upgrades[name] = upgrade
end

return API
