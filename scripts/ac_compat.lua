-- Read third-party metadata only. Harvesting always goes through native PICK.
local M = {}

local function Info(product, count, products)
    return { product = product, count = count, products = products or { product } }
end

function M.IsGiantPlant(target)
    local crop = target.components.perennialcrop
    return (target:HasTag("farm_plant") and target.is_oversized)
        or (crop ~= nil and crop.ishuge)
end

function M.HarvestInfo(target)
    local crop = target.components.perennialcrop
    if crop ~= nil then
        local product = crop.product or "cutgrass"
        if crop.ishuge then
            if crop.isrotten then
                return Info("spoiled_food", nil, crop.loot_huge_rot
                    or { "spoiled_food", crop.seed or "seeds" })
            end
            -- A matching ordinary fruit sample also permits harvesting its giant.
            return Info(crop.product_huge or product, nil,
                { product, crop.product_huge or product, crop.seed or "seeds" })
        end
        if crop.stage < crop.stage_max then
            return crop.isrotten and Info("spoiled_food", 1) or Info(nil, nil, {})
        end
        local count = (crop.num_perfect or 0) >= 5 and 3
            or ((crop.num_perfect or 0) >= 3 and 2 or 1)
        if crop.pollinated ~= nil and crop.pollinated_max ~= nil
            and crop.pollinated >= crop.pollinated_max then count = count + 1 end
        return Info(crop.isrotten and "spoiled_food" or product, count)
    end

    crop = target.components.perennialcrop2
    if crop ~= nil then
        if crop.fn_loot == nil and crop.stage ~= crop.stage_max
            and (crop.level == nil or crop.level.pickable ~= 1) then
            if crop.isflower and not crop.isrotten then return Info("petals", 3) end
            if crop.stage > 1 then
                return Info(crop.isrotten and "spoiled_food" or "cutgrass", 1)
            end
            return Info(nil, nil, {})
        end
        local product = crop.isrotten and "spoiled_food" or crop.cropprefab
        -- These custom crops change their main yield with the harvest stage.
        if crop.cropprefab == "mandrake" and crop.isrotten then
            product = "livinglog"
        elseif crop.cropprefab == "log" then
            product = "log"
        elseif crop.cropprefab == "berries" and not crop.isrotten
            and crop.stage ~= crop.stage_max then
            product = "berries_juicy"
        end
        local products = { product }
        for _, loot in ipairs(crop.lootothers or {}) do
            table.insert(products, crop.isrotten and (loot.name_rot or "spoiled_food") or loot.name)
        end
        if crop.isflower and not crop.isrotten then table.insert(products, "petals") end
        if crop.fn_loot ~= nil and not crop.isrotten then
            if crop.cropprefab == "berries" then
                table.insert(products, product == "berries" and "berries_juicy" or "berries")
            elseif crop.cropprefab == "carrot" and (crop.cluster or 0) >= 50 then
                table.insert(products, "lance_carrot_l")
            elseif crop.cropprefab == "cactus_meat" and crop.stage == crop.stage_max then
                table.insert(products, "cactus_flower")
            end
        end
        local count
        -- Callback-defined yields are not predicted or invoked during scanning.
        if crop.fn_loot == nil and crop.fn_lootset == nil and crop.fn_pick == nil then
            count = (crop.cluster or 0) + (crop.numfruit or 1)
            if crop.pollinated ~= nil and crop.pollinated_max ~= nil
                and crop.pollinated >= crop.pollinated_max then
                count = count + math.max(math.floor((crop.cluster or 0) * .1), 1)
            end
        end
        return Info(product, count, products)
    end

    if target:HasTag("medal_fruit_tree") and target.fruit_tree_def ~= nil then
        -- Yield is randomized and affected by tree level. Only inspect the fruit.
        return Info(target.fruit_tree_def.product, nil)
    end
    if target.prefab == "monstrain" then
        return Info("squamousfruit", 1, { "squamousfruit", "monstrain_leaf" })
    end
end

return M
