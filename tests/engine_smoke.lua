-- Test-only modimport. Never included in the release modmain or runtime package.
local G = GLOBAL
local assert = G.assert
AddPrefabPostInit("world", function(world)
    if not world.ismastersim then return end
    world:DoTaskInTime(3, function()
        local function guard(fn)
            local ok, err = G.xpcall(fn, G.debug.traceback)
            if not ok then
                print("AC_SMOKE FAIL: " .. tostring(err))
                G.c_shutdown(false)
            end
        end
        guard(function()
            local x, z
            for cx = -400, 400, 20 do
                for cz = -400, 400, 20 do
                    local good = true
                    for dx = -16, 16, 4 do
                        for dz = -16, 16, 4 do
                            good = good and world.Map:IsPassableAtPoint(cx + dx, 0, cz + dz)
                                and not world.Map:IsOceanAtPoint(cx + dx, 0, cz + dz)
                        end
                    end
                    if good then x, z = cx, cz break end
                end
                if x ~= nil then break end
            end
            assert(x ~= nil, "No test arena found")
            -- Repeated runs must also remove saved test chests and the loot they drop.
            for pass = 1, 2 do
                for _, e in ipairs(G.TheSim:FindEntities(x, 0, z, 20)) do
                    if e.components.pickable ~= nil or e.components.inventoryitem ~= nil
                        or e.components.container ~= nil then e:Remove() end
                end
            end
            local function spawn(name, dx, dz)
                local e = G.SpawnPrefab(name)
                assert(e ~= nil, "Cannot spawn " .. name)
                e.Transform:SetPosition(x + (dx or 0), 0, z + (dz or 0))
                e.entity:SetCanSleep(false)
                return e
            end
            local collector = spawn("automatic_collector")
            local worker = collector.components.ac_worker
            worker:SetHome()
            local chest = spawn("treasurechest", 5)
            local item = spawn("twigs", 2)
            item.components.stackable:SetStackSize(3)
            local successes = {}
            collector:ListenForEvent("ac_jobsuccess", function(_, data)
                local id = data.action.action.id
                successes[id] = (successes[id] or 0) + 1
                print("AC_SMOKE JOB", id, data.target ~= nil and data.target.prefab or "nil")
            end)
            local function later(seconds, fn)
                world:DoTaskInTime(seconds, function() guard(fn) end)
            end
            print("AC_SMOKE START", x, z, collector.GUID)
            later(20, function()
                local has, count = chest.components.container:Has("twigs", 3)
                assert(has and count == 3, "Ground item transport failed")
                assert(successes.PICKUP == 1 and successes.STORE == 1, "Expected one pickup and one store")
                print("AC_SMOKE PASS ground transport")
                spawn("grass", 2, 2)
            end)
            later(40, function()
                assert(chest.components.container:Has("cutgrass", 1), "Native grass harvest failed")
                print("AC_SMOKE PASS native grass")
                local p = spawn("farm_plant_carrot", 2, -2)
                p.no_oversized = true
                p.components.growable:SetStage(5)
                assert(p.components.pickable ~= nil and p.components.pickable:CanBePicked(), "Crop not mature")
            end)
            later(65, function()
                assert(chest.components.container:Has("carrot", 1), "Native farm crop harvest failed")
                print("AC_SMOKE PASS native crop")
                local p = spawn("farm_plant_carrot", 2, 2)
                p.force_oversized = true
                p.is_oversized = true
                p.components.growable:SetStage(5)
                assert(p.components.pickable ~= nil, "Giant crop not mature")
            end)
            later(115, function()
                assert(chest.components.container:Has("carrot", 4), "Giant harvest, hammer and transport failed")
                assert((successes.AC_HAMMER or 0) >= 1, "No native giant hammer action")
                print("AC_SMOKE PASS giant crop chain")
                worker:SetEnabled(false)
                local paused = spawn("cutgrass", 2, -2)
                later(5, function()
                    assert(paused:IsValid() and not paused.components.inventoryitem:IsHeld(), "Paused robot picked up cargo")
                    worker:SetEnabled(true)
                    print("AC_SMOKE PASS pause")
                end)
            end)
            later(135, function()
                assert(chest.components.container:Has("cutgrass", 2), "Resume failed")
                worker:SetEnabled(false)
                local cargo = spawn("flint", 2)
                cargo.components.stackable:SetStackSize(5)
                collector.components.inventory:GiveItem(cargo)
                local record = collector:GetSaveRecord()
                assert(record.data ~= nil, "Missing save data")
                collector:Remove()
                if cargo:IsValid() then cargo:Remove() end
                collector = G.SpawnSaveRecord(record)
                assert(collector ~= nil, "Could not restore collector")
                collector.entity:SetCanSleep(false)
                worker = collector.components.ac_worker
                assert(not worker.enabled, "Pause flag lost on restore")
                assert(worker:GetCargo() ~= nil and worker:GetCargo().prefab == "flint", "Saved cargo lost")
                assert(worker:GetCargo().components.stackable:StackSize() == 5, "Saved cargo count changed")
                assert(worker:GetHome().x == x and worker:GetHome().z == z, "Work center lost")
                print("AC_SMOKE PASS native save/load with cargo and pause")
                worker:SetEnabled(true)
            end)
            later(150, function()
                assert(chest.components.container:Has("flint", 5), "Restored cargo was not delivered")
                local c = chest.components.container
                for slot = 1, c:GetNumSlots() do
                    if c.slots[slot] == nil then
                        local filler = spawn("rocks")
                        filler.components.stackable:SetStackSize(40)
                        c:GiveItem(filler, slot)
                    end
                end
                assert(c:IsFull(), "Test chest not full")
                local gold = spawn("goldnugget", 2)
                later(5, function()
                    assert(gold:IsValid() and not gold.components.inventoryitem:IsHeld(), "Robot collected without destination")
                    assert(worker:GetCargo() == nil, "Cargo created while destination full")
                    print("AC_SMOKE PASS full container stops new work")
                    local filler = c:RemoveItemBySlot(c:GetNumSlots())
                    if filler ~= nil then filler:Remove() end
                end)
            end)
            later(165, function()
                assert(chest.components.container:Has("goldnugget", 1), "Robot did not resume when capacity restored")
                print("AC_SMOKE PASS capacity restored resumes work")
                print("AC_SMOKE SUCCESS")
                G.c_shutdown(false)
            end)
        end)
    end)
end)
