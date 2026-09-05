-- ImplementDamageSystem workshop flow - Stage 4.
-- Hooks the base workshop screen's repair button (same entry point ADS uses for
-- motorized vehicles) and drives the whole flow through base-game dialogs.
-- Work orders take game time: the implement is locked (no turn-on, crawl speed)
-- until the finish time passes, then the result applies and a notification fires.

IDS_Workshop = {}

IDS_Workshop.ACTIONS = {
    INSPECT = "INSPECT",
    SERVICE = "SERVICE",
    REPAIR = "REPAIR",
    OVERHAUL = "OVERHAUL"
}

-- Game-hours each action takes.
IDS_Workshop.DURATIONS = {
    INSPECT = 0.5,
    SERVICE = 2.0,
    REPAIR_PER_STAGE = 1.5,
    OVERHAUL = 12.0
}

local function log_dbg(...)
    if IDS_Config and IDS_Config.DEBUG then
        local args = {...}
        for i = 1, #args do
            args[i] = tostring(args[i])
        end
        print("[IDS_WORKSHOP] " .. table.concat(args, " "))
    end
end

-- ===========================================================
--                        COSTS
-- ===========================================================

local function getBasePrice(vehicle)
    local price = vehicle.getPrice ~= nil and vehicle:getPrice() or 0
    if price <= 0 then
        local storeItem = g_storeManager:getItemByXMLFilename(vehicle.configFileName)
        price = storeItem ~= nil and storeItem.price or 20000
    end
    return price
end

function IDS_Workshop.getCosts(vehicle)
    local spec = vehicle.spec_ImplementDamageSystem
    local price = getBasePrice(vehicle)

    local repairCost = 0
    local repairStages = 0
    for _, breakdown in ipairs(spec.activeBreakdowns) do
        if breakdown.discovered then
            local def = IDS_Breakdowns.Registry[breakdown.id]
            local factor = def ~= nil and def.repairCostFactor ~= nil and def.repairCostFactor[breakdown.stage] or 0.01
            repairCost = repairCost + price * factor
            repairStages = repairStages + breakdown.stage
        end
    end

    return {
        inspect = 100 + price * 0.001,
        inspectThorough = 400 + price * 0.006,
        service = 50 + price * 0.015 * (1 - spec.serviceLevel),
        repair = repairCost,
        repairStages = repairStages,
        overhaul = price * 0.02 + price * 0.25 * (1 - spec.conditionLevel)
    }
end

-- ===========================================================
--                    WORK ORDER STATE
-- ===========================================================

local function getEnvironmentTime()
    local env = g_currentMission.environment
    return env.currentMonotonicDay or 0, env.dayTime or 0
end

function IDS_Workshop.startOrder(vehicle, action, durationHours, cost)
    local spec = vehicle.spec_ImplementDamageSystem
    local day, dayTime = getEnvironmentTime()
    local finishTime = dayTime + durationHours * 60 * 60 * 1000
    local finishDay = day
    while finishTime >= 24 * 60 * 60 * 1000 do
        finishTime = finishTime - 24 * 60 * 60 * 1000
        finishDay = finishDay + 1
    end
    spec.pendingService = { action = action, finishDay = finishDay, finishTime = finishTime }

    g_currentMission:addMoney(-cost, vehicle:getOwnerFarmId(), MoneyType.VEHICLE_RUNNING_COSTS, true, true)

    if vehicle.getIsTurnedOn ~= nil and vehicle:getIsTurnedOn() then
        vehicle:setIsTurnedOn(false)
    end
    log_dbg("Order started:", vehicle:getFullName(), action, "finish day", finishDay)
end

-- Deadline test uses >= on (day, time): the clock can jump with no DAY_CHANGED.
function IDS_Workshop.updatePendingService(vehicle)
    local spec = vehicle.spec_ImplementDamageSystem
    local pending = spec.pendingService
    if pending == nil then
        return
    end
    local day, dayTime = getEnvironmentTime()
    if day > pending.finishDay or (day == pending.finishDay and dayTime >= pending.finishTime) then
        spec.pendingService = nil
        IDS_Workshop.completeOrder(vehicle, pending.action)
    end
end

-- Public API for other mods (Nucleus Command): finish the running work order
-- immediately, applying its results. Returns false when nothing is pending.
function IDS_Workshop.finishOrderNow(vehicle)
    local spec = vehicle.spec_ImplementDamageSystem
    if spec == nil or spec.pendingService == nil then
        return false
    end
    local action = spec.pendingService.action
    spec.pendingService = nil
    IDS_Workshop.completeOrder(vehicle, action)
    return true
end

-- Public API: remaining game-hours on the running order, or nil when idle.
function IDS_Workshop.getRemainingHours(vehicle)
    local spec = vehicle.spec_ImplementDamageSystem
    if spec == nil or spec.pendingService == nil then
        return nil
    end
    local day, dayTime = getEnvironmentTime()
    local remainingMs = (spec.pendingService.finishDay - day) * 24 * 60 * 60 * 1000
        + (spec.pendingService.finishTime - dayTime)
    return math.max(remainingMs / (60 * 60 * 1000), 0), spec.pendingService.action
end

function IDS_Workshop.completeOrder(vehicle, action)
    local spec = vehicle.spec_ImplementDamageSystem
    local name = vehicle:getFullName()

    if action == IDS_Workshop.ACTIONS.SERVICE then
        spec.serviceLevel = 1.0
        IDS_Workshop.addLogEntry(vehicle, "Serviced")
        IDS_Breakdowns.notify(string.format("%s: service complete", name))
    elseif action == IDS_Workshop.ACTIONS.REPAIR then
        for i = #spec.activeBreakdowns, 1, -1 do
            if spec.activeBreakdowns[i].discovered then
                local def = IDS_Breakdowns.Registry[spec.activeBreakdowns[i].id]
                IDS_Workshop.addLogEntry(vehicle, "Repaired: " .. (def ~= nil and def.name or spec.activeBreakdowns[i].id))
                table.remove(spec.activeBreakdowns, i)
            end
        end
        IDS_Breakdowns.recalculateEffects(vehicle)
        IDS_Breakdowns.notify(string.format("%s: repairs complete", name))
    elseif action == IDS_Workshop.ACTIONS.OVERHAUL then
        spec.serviceLevel = 1.0
        for _, systemData in pairs(spec.systems) do
            if systemData.enabled then
                systemData.condition = math.min(systemData.condition + 0.6, 1.0)
                systemData.stress = 0.0
            end
        end
        vehicle:idsUpdateConditionLevel()
        IDS_Workshop.addLogEntry(vehicle, "Overhauled")
        IDS_Breakdowns.notify(string.format("%s: overhaul complete", name))
    end
end

-- ===========================================================
--                    MAINTENANCE LOG
-- ===========================================================

function IDS_Workshop.addLogEntry(vehicle, text)
    local spec = vehicle.spec_ImplementDamageSystem
    spec.maintenanceLog = spec.maintenanceLog or {}
    local day = getEnvironmentTime()
    table.insert(spec.maintenanceLog, 1, string.format("Day %d: %s", day, text))
    while #spec.maintenanceLog > 12 do
        table.remove(spec.maintenanceLog)
    end
end

-- ===========================================================
--                        DIALOGS
-- ===========================================================

local function money(amount)
    return g_i18n:formatMoney(amount, 0, true, true)
end

function IDS_Workshop.doInspect(vehicle, cost, thorough)
    local spec = vehicle.spec_ImplementDamageSystem
    g_currentMission:addMoney(-cost, vehicle:getOwnerFarmId(), MoneyType.VEHICLE_RUNNING_COSTS, true, true)

    local found = {}
    local missed = 0
    for _, breakdown in ipairs(spec.activeBreakdowns) do
        local def = IDS_Breakdowns.Registry[breakdown.id]
        local stage = def ~= nil and def.stages[breakdown.stage] or nil
        if breakdown.discovered then
            table.insert(found, string.format("- %s (%s)",
                def ~= nil and def.name or breakdown.id,
                stage ~= nil and stage.severity or "unknown"))
        elseif stage ~= nil and (thorough or math.random() < stage.detectionChance) then
            breakdown.discovered = true
            table.insert(found, string.format("- %s (%s) - NEW", def.name, stage.severity))
        else
            missed = missed + 1
        end
    end

    IDS_Workshop.addLogEntry(vehicle, thorough and "Inspected (thorough)" or "Inspected")

    local lines = {
        string.format("%s report - %s", thorough and "Thorough inspection" or "Inspection", vehicle:getFullName()),
        "",
        string.format("Service level: %d%%", spec.serviceLevel * 100),
        string.format("Overall condition: %d%%", spec.conditionLevel * 100),
        ""
    }
    if #found > 0 then
        table.insert(lines, "Faults found:")
        for _, line in ipairs(found) do
            table.insert(lines, line)
        end
    else
        table.insert(lines, "No faults found.")
    end
    if missed > 0 then
        table.insert(lines, "")
        table.insert(lines, "The mechanic isn't fully happy but couldn't pin anything down.")
    end
    InfoDialog.show(table.concat(lines, "\n"))
end

function IDS_Workshop.openMenu(vehicle)
    local spec = vehicle.spec_ImplementDamageSystem

    if spec.pendingService ~= nil then
        local day, dayTime = getEnvironmentTime()
        local remainingMs = (spec.pendingService.finishDay - day) * 24 * 60 * 60 * 1000
            + (spec.pendingService.finishTime - dayTime)
        local remainingHours = math.max(remainingMs / (60 * 60 * 1000), 0)
        InfoDialog.show(string.format("%s is in the workshop.\n\n%s in progress - about %.1f game hours remaining.",
            vehicle:getFullName(), spec.pendingService.action, remainingHours))
        return
    end

    local costs = IDS_Workshop.getCosts(vehicle)
    local knownFaults = 0
    for _, breakdown in ipairs(spec.activeBreakdowns) do
        if breakdown.discovered then
            knownFaults = knownFaults + 1
        end
    end

    local options = {
        string.format("Inspect (%s)", money(costs.inspect)),
        string.format("Thorough inspection (%s)", money(costs.inspectThorough)),
        string.format("Service (%s)", money(costs.service)),
        knownFaults > 0 and string.format("Repair %d known fault(s) (%s)", knownFaults, money(costs.repair))
            or "Repair (no known faults)",
        string.format("Overhaul (%s)", money(costs.overhaul)),
        "Maintenance log"
    }
    local statusText = string.format("%s\nService %d%% | Condition %d%% | Known faults: %d",
        vehicle:getFullName(), spec.serviceLevel * 100, spec.conditionLevel * 100, knownFaults)

    OptionDialog.show(function(idx)
        if idx == 1 then
            IDS_Workshop.doInspect(vehicle, costs.inspect, false)
        elseif idx == 2 then
            IDS_Workshop.doInspect(vehicle, costs.inspectThorough, true)
        elseif idx == 3 then
            IDS_Workshop.startOrder(vehicle, IDS_Workshop.ACTIONS.SERVICE, IDS_Workshop.DURATIONS.SERVICE, costs.service)
            InfoDialog.show(string.format("%s booked in for a service (%.0f game hours).", vehicle:getFullName(), IDS_Workshop.DURATIONS.SERVICE))
        elseif idx == 4 then
            if knownFaults == 0 then
                InfoDialog.show("No known faults. Book an inspection if something feels off.")
            else
                local hours = IDS_Workshop.DURATIONS.REPAIR_PER_STAGE * costs.repairStages
                IDS_Workshop.startOrder(vehicle, IDS_Workshop.ACTIONS.REPAIR, hours, costs.repair)
                InfoDialog.show(string.format("%s booked in for repairs (%.1f game hours).", vehicle:getFullName(), hours))
            end
        elseif idx == 5 then
            IDS_Workshop.startOrder(vehicle, IDS_Workshop.ACTIONS.OVERHAUL, IDS_Workshop.DURATIONS.OVERHAUL, costs.overhaul)
            InfoDialog.show(string.format("%s booked in for a full overhaul (%.0f game hours).", vehicle:getFullName(), IDS_Workshop.DURATIONS.OVERHAUL))
        elseif idx == 6 then
            local logEntries = spec.maintenanceLog or {}
            if #logEntries == 0 then
                InfoDialog.show("No maintenance history.")
            else
                InfoDialog.show("Maintenance log - " .. vehicle:getFullName() .. "\n\n" .. table.concat(logEntries, "\n"))
            end
        end
    end, statusText, "Implement Workshop", options)
end

-- ===========================================================
--                  WORKSHOP SCREEN HOOK
-- ===========================================================

-- ADS appends its own hook to setVehicle BEFORE ours (alphabetical load order)
-- and re-decides the button on every vehicle change. So: install our callback
-- only for IDS implements, and on other vehicles restore ONLY if the button
-- still holds OUR callback — if ADS (or anyone) overwrote it since, leave it.
function IDS_Workshop.hookRepairButton(screenInstance, vehicle)
    if screenInstance.repairButton == nil then
        return
    end
    local button = screenInstance.repairButton
    local spec = vehicle ~= nil and vehicle.spec_ImplementDamageSystem or nil
    if spec ~= nil and spec.serviceLevel ~= nil then
        if button.onClickCallback ~= screenInstance.ids_callback then
            screenInstance.ids_prevCallback = button.onClickCallback
        end
        screenInstance.ids_callback = function()
            IDS_Workshop.openMenu(vehicle)
        end
        button.onClickCallback = screenInstance.ids_callback
        button:setText("Workshop")
        button:setDisabled(false)
    elseif screenInstance.ids_callback ~= nil and button.onClickCallback == screenInstance.ids_callback then
        button.onClickCallback = screenInstance.ids_prevCallback
        screenInstance.ids_callback = nil
    end
end

WorkshopScreen.setVehicle = Utils.appendedFunction(WorkshopScreen.setVehicle, IDS_Workshop.hookRepairButton)
