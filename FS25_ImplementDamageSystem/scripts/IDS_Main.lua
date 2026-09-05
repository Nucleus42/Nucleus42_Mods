-- FS25_ImplementDamageSystem - registration entry point.
-- Pattern copied from ADS (GPL-3): inject the spec into finalized vehicle types,
-- but filtered to attachable AND NOT motorized, so ADS and IDS never share a vehicle.

IDS_Main = {}

local modDirectory = g_currentModDirectory

IDS_Config = {
    DEBUG = false,

    -- Rates are per real hour, anchored to ADS (0.1 service/hr working, 5% drain
    -- parked outside, 0% under roof). Implements run slightly slower than engines.
    BASE_SERVICE_WEAR = 0.08,
    BASE_SYSTEMS_WEAR = 0.01,
    SERVICE_ROAD_MULT = 0.3,
    SERVICE_DOWNTIME_MULT = 0.05,
    SERVICE_UNDER_ROOF_MULT = 0.0,

    -- Extra wear per fraction of speed over the implement's own speedLimit.
    OVERSPEED_GAIN = 3.0,
    -- Fill ratio above which CHASSIS takes overload stress while moving.
    OVERFILL_THRESHOLD = 0.9,
    OVERFILL_STRESS_GAIN = 1.5,
    -- km/h above which raised transport counts as road travel.
    ROAD_SPEED_THRESHOLD = 18,

    -- Reliability derived from price: cheap kit 0.8, premium 1.2. Wear divides by this.
    RELIABILITY_MIN = 0.8,
    RELIABILITY_MAX = 1.2,
    RELIABILITY_PRICE_CAP = 200000,

    SYSTEM_ACTIVITY = {
        HYDRAULICS_WORKING = 0.3,
        MATERIALFLOW_BASE = 0.4,
        MATERIALFLOW_FILL = 0.6,
        CHASSIS_SPEED_NORM = 30,
        CHASSIS_BASE = 0.3,
        CHASSIS_FILL = 0.7
    },

    -- Breakdown rolls: once per interval (real ms) while working.
    -- chance/hr = CONDITION_GAIN*(1-cond)^2 + STRESS_GAIN*stress, times the
    -- service multiplier once service drops under the risk threshold.
    -- At condition 0.5 that is ~0.13/hr; near 1.0 it is effectively zero.
    BREAKDOWN_ROLL_INTERVAL = 60 * 1000,
    BREAKDOWN_CONDITION_GAIN = 0.5,
    BREAKDOWN_STRESS_GAIN = 2.0,
    BREAKDOWN_SERVICE_GAIN = 3.0,
    SERVICE_RISK_THRESHOLD = 0.5,

    SYSTEM_WEIGHTS = {
        GROUNDTOOL = 3.0,
        DRIVELINE = 2.0,
        HYDRAULICS = 1.5,
        MATERIALFLOW = 2.0,
        CHASSIS = 2.0,
        BINDING = 1.5
    }
}

local function log_dbg(...)
    if IDS_Config.DEBUG then
        local args = {...}
        for i = 1, #args do
            args[i] = tostring(args[i])
        end
        print("[IDS_MAIN] " .. table.concat(args, " "))
    end
end

function IDS_Main.initSpec()
    source(modDirectory .. "scripts/core/IDS_Breakdowns.lua")
    source(modDirectory .. "scripts/IDS_Workshop.lua")
    g_specializationManager:addSpecialization("ImplementDamageSystem", "ImplementDamageSystem", modDirectory .. "scripts/core/IDS_Specialization.lua", "")
    TypeManager.finalizeTypes = Utils.appendedFunction(TypeManager.finalizeTypes, IDS_Main.registerSpecializationToVehicles)
end

local EXCLUDED_TYPE_PATTERNS = {
    "handtool", "pushable", "portable", "locomotive", "pallet"
}

local function isExcludedType(vehicleTypeName)
    local lowerName = string.lower(vehicleTypeName)
    for _, pattern in ipairs(EXCLUDED_TYPE_PATTERNS) do
        if string.find(lowerName, pattern, 1, true) then
            return true
        end
    end
    return false
end

function IDS_Main.registerSpecializationToVehicles()
    local specName = "ImplementDamageSystem"
    local count = 0
    for vehicleTypeName, vehicleType in pairs(g_vehicleTypeManager.types) do
        if vehicleType ~= nil and not isExcludedType(vehicleTypeName) then
            local isAttachable = false
            local isMotorized = false
            local isSplineVehicle = false
            local hasIDS = false
            for name, _ in pairs(vehicleType.specializationsByName) do
                if name == "attachable" then
                    isAttachable = true
                elseif name == "motorized" then
                    isMotorized = true
                elseif name == "splineVehicle" then
                    -- Train wagons: attachable, not motorized, but run on rails.
                    isSplineVehicle = true
                elseif name == specName then
                    hasIDS = true
                end
            end
            if isAttachable and not isMotorized and not isSplineVehicle and not hasIDS then
                local specObject = g_specializationManager:getSpecializationObjectByName(specName)
                if specObject then
                    vehicleType.specializationsByName[specName] = specObject
                    table.insert(vehicleType.specializationNames, specName)
                    table.insert(vehicleType.specializations, specObject)
                    count = count + 1
                end
            end
        end
    end
    log_dbg("Specialization applied to", count, "vehicle types")
end

-- ===========================================================
--                     CONSOLE COMMANDS
-- ===========================================================

local function getTrackedVehicles()
    local result = {}
    local vehicles = g_currentMission ~= nil and g_currentMission.vehicleSystem ~= nil and g_currentMission.vehicleSystem.vehicles or nil
    if vehicles == nil and g_currentMission ~= nil then
        vehicles = g_currentMission.vehicles
    end
    if vehicles ~= nil then
        for _, vehicle in pairs(vehicles) do
            if vehicle.spec_ImplementDamageSystem ~= nil and vehicle.spec_ImplementDamageSystem.serviceLevel ~= nil then
                table.insert(result, vehicle)
            end
        end
    end
    return result
end

function IDS_Main.consoleDump()
    local tracked = getTrackedVehicles()
    print(string.format("[IDS] %d tracked implement(s):", #tracked))
    for _, vehicle in ipairs(tracked) do
        local spec = vehicle.spec_ImplementDamageSystem
        local systemsInfo = {}
        for systemName, systemData in pairs(spec.systems) do
            if systemData.enabled then
                table.insert(systemsInfo, string.format("%s c=%.4f s=%.4f", systemName, systemData.condition, systemData.stress))
            end
        end
        table.sort(systemsInfo)
        local d = spec.lastDrivers
        local driverInfo = "no update yet"
        if d ~= nil then
            driverInfo = string.format("%s on=%s proc=%s pto=%s road=%s v=%.1f over=%.2f fill=%.2f roof=%s",
                d.isWorking and "WORKING" or "idle", tostring(d.isTurnedOn), tostring(d.processing),
                tostring(d.ptoActive), tostring(d.isRoadTravel), d.speed, d.overspeed, d.fillRatio,
                tostring(spec.isUnderRoof))
        end
        local breakdownInfo = ""
        if spec.pendingService ~= nil then
            breakdownInfo = string.format(" | IN WORKSHOP: %s until day %d", spec.pendingService.action, spec.pendingService.finishDay)
        end
        if #spec.activeBreakdowns > 0 then
            local names = {}
            for _, breakdown in ipairs(spec.activeBreakdowns) do
                table.insert(names, string.format("%s@%d(%.2fh)%s", breakdown.id, breakdown.stage, breakdown.progressHours, breakdown.discovered and " KNOWN" or " hidden"))
            end
            breakdownInfo = breakdownInfo .. " | BREAKDOWNS: " .. table.concat(names, ", ")
        end
        print(string.format("  %s | service=%.4f condition=%.4f rel=%.2f | %s | %s%s",
            vehicle:getFullName(), spec.serviceLevel, spec.conditionLevel, spec.reliability or 1.0,
            table.concat(systemsInfo, " | "), driverInfo, breakdownInfo))
    end
    return "done"
end

local function getControlledImplement()
    local rootVehicle = g_localPlayer ~= nil and g_localPlayer.getCurrentVehicle ~= nil and g_localPlayer:getCurrentVehicle() or nil
    if rootVehicle == nil then
        rootVehicle = g_currentMission ~= nil and g_currentMission.controlledVehicle or nil
    end
    if rootVehicle == nil then
        return nil, "not in a vehicle"
    end
    if rootVehicle.getChildVehicles ~= nil then
        for _, child in ipairs(rootVehicle:getChildVehicles()) do
            if child.spec_ImplementDamageSystem ~= nil then
                return child, nil
            end
        end
    end
    return nil, "no attached implement with IDS spec"
end

function IDS_Main.consoleSet(_, field, value)
    local vehicle, err = getControlledImplement()
    if vehicle == nil then
        return "[IDS] " .. err
    end
    local numValue = tonumber(value)
    if numValue == nil then
        return "[IDS] usage: idsSet <service|condition> <0..1>"
    end
    numValue = math.clamp(numValue, 0.001, 1.0)
    local spec = vehicle.spec_ImplementDamageSystem
    if field == "service" then
        spec.serviceLevel = numValue
    elseif field == "condition" then
        for _, systemData in pairs(spec.systems) do
            if systemData.enabled then
                systemData.condition = numValue
            end
        end
        vehicle:idsUpdateConditionLevel()
    else
        return "[IDS] usage: idsSet <service|condition> <0..1>"
    end
    return string.format("[IDS] %s: %s=%.3f", vehicle:getFullName(), field, numValue)
end

function IDS_Main.consoleBreak(_, id, stage)
    local vehicle, err = getControlledImplement()
    if vehicle == nil then
        return "[IDS] " .. err
    end
    if id == nil or IDS_Breakdowns.Registry[id] == nil then
        local names = {}
        for name, _ in pairs(IDS_Breakdowns.Registry) do
            table.insert(names, name)
        end
        table.sort(names)
        return "[IDS] usage: idsBreak <" .. table.concat(names, "|") .. "> [stage]"
    end
    local def = IDS_Breakdowns.Registry[id]
    if not def.isApplicable(vehicle) then
        return string.format("[IDS] %s is not applicable to %s", id, vehicle:getFullName())
    end
    if IDS_Breakdowns.addBreakdown(vehicle, id, tonumber(stage)) then
        return string.format("[IDS] %s added to %s", id, vehicle:getFullName())
    end
    return string.format("[IDS] %s is already active on %s", id, vehicle:getFullName())
end

function IDS_Main.consoleFix(_, id)
    local vehicle, err = getControlledImplement()
    if vehicle == nil then
        return "[IDS] " .. err
    end
    local spec = vehicle.spec_ImplementDamageSystem
    if id ~= nil then
        if IDS_Breakdowns.removeBreakdown(vehicle, id) then
            return string.format("[IDS] %s fixed on %s", id, vehicle:getFullName())
        end
        return string.format("[IDS] %s is not active on %s", id, vehicle:getFullName())
    end
    local count = #spec.activeBreakdowns
    spec.activeBreakdowns = {}
    IDS_Breakdowns.recalculateEffects(vehicle)
    return string.format("[IDS] fixed %d breakdown(s) on %s", count, vehicle:getFullName())
end

-- Sleeping vehicles get no onUpdate, so parked decay and pending workshop
-- orders would stall forever; catch them up on every hour change. Awake
-- vehicles refresh idsLastRealTime each frame, so they are skipped here.
function IDS_Main:onHourChanged()
    if g_currentMission == nil or not g_currentMission:getIsServer()
        or ImplementDamageSystem == nil or ImplementDamageSystem.advanceSleeping == nil then
        return
    end
    for _, vehicle in ipairs(getTrackedVehicles()) do
        local spec = vehicle.spec_ImplementDamageSystem
        local elapsed = g_time - (spec.idsLastRealTime or g_time)
        if elapsed > 5000 then
            ImplementDamageSystem.advanceSleeping(vehicle, elapsed)
        elseif spec.idsLastRealTime == nil then
            spec.idsLastRealTime = g_time
        end
    end
end

g_messageCenter:subscribe(MessageType.HOUR_CHANGED, IDS_Main.onHourChanged, IDS_Main)

function IDS_Main.consoleStatus()
    local env = g_currentMission.environment
    local day, dayTime = env.currentMonotonicDay or 0, env.dayTime or 0
    local lines = {}
    for _, vehicle in ipairs(getTrackedVehicles()) do
        local spec = vehicle.spec_ImplementDamageSystem
        if spec.pendingService ~= nil then
            local remainingMs = (spec.pendingService.finishDay - day) * 24 * 60 * 60 * 1000
                + (spec.pendingService.finishTime - dayTime)
            table.insert(lines, string.format("  %s - %s, %.1f game hours left",
                vehicle:getFullName(), spec.pendingService.action, math.max(remainingMs / (60 * 60 * 1000), 0)))
        end
        for _, breakdown in ipairs(spec.activeBreakdowns) do
            if breakdown.discovered then
                local def = IDS_Breakdowns.Registry[breakdown.id]
                local stage = def ~= nil and def.stages[breakdown.stage] or nil
                table.insert(lines, string.format("  %s - %s (%s), unrepaired",
                    vehicle:getFullName(), def ~= nil and def.name or breakdown.id,
                    stage ~= nil and stage.severity or "?"))
            end
        end
    end
    if #lines == 0 then
        print("[IDS] Nothing in the workshop, no known faults.")
    else
        print("[IDS] Workshop and known faults:")
        for _, line in ipairs(lines) do
            print(line)
        end
    end
    return "done"
end

addConsoleCommand("idsDump", "Print IDS state for all tracked implements", "consoleDump", IDS_Main)
addConsoleCommand("idsStatus", "List implements in the workshop and known unrepaired faults", "consoleStatus", IDS_Main)
addConsoleCommand("idsBreak", "Force a breakdown on the attached implement. Usage: idsBreak <ID> [stage]", "consoleBreak", IDS_Main)
addConsoleCommand("idsFix", "Remove breakdowns from the attached implement. Usage: idsFix [ID]", "consoleFix", IDS_Main)
addConsoleCommand("idsSet", "Set service/condition on the attached implement. Usage: idsSet <service|condition> <0..1>", "consoleSet", IDS_Main)

IDS_Main.initSpec()
