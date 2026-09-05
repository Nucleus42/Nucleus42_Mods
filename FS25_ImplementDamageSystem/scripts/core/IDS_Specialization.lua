-- ImplementDamageSystem specialization - Stage 1 skeleton.
-- State model copied from ADS (GPL-3): serviceLevel + per-system condition/stress,
-- weighted into one conditionLevel. Wear drivers are placeholders until Stage 2.

ImplementDamageSystem = {}

local function log_dbg(...)
    if IDS_Config and IDS_Config.DEBUG then
        local args = {...}
        for i = 1, #args do
            args[i] = tostring(args[i])
        end
        print("[IDS_SPEC] " .. table.concat(args, " "))
    end
end

ImplementDamageSystem.SYSTEMS = {
    GROUNDTOOL = "GROUNDTOOL",
    DRIVELINE = "DRIVELINE",
    HYDRAULICS = "HYDRAULICS",
    MATERIALFLOW = "MATERIALFLOW",
    CHASSIS = "CHASSIS",
    BINDING = "BINDING"
}

function ImplementDamageSystem.getSystemWeight(systemName)
    local weights = IDS_Config ~= nil and IDS_Config.SYSTEM_WEIGHTS or nil
    return weights ~= nil and weights[systemName] or 1.0
end

function ImplementDamageSystem.prerequisitesPresent(specializations)
    return true
end

function ImplementDamageSystem.initSpecialization()
    local schemaSavegame = Vehicle.xmlSchemaSavegame
    local baseKey = "vehicles.vehicle(?).ImplementDamageSystem"
    schemaSavegame:register(XMLValueType.FLOAT, baseKey .. "#service", "IDS service level")
    schemaSavegame:register(XMLValueType.STRING, baseKey .. "#systemsState", "IDS per-system condition/stress")
    schemaSavegame:register(XMLValueType.STRING, baseKey .. "#breakdowns", "IDS active breakdowns")
    schemaSavegame:register(XMLValueType.STRING, baseKey .. "#pendingService", "IDS pending workshop order")
    schemaSavegame:register(XMLValueType.STRING, baseKey .. "#maintenanceLog", "IDS maintenance log entries")
end

function ImplementDamageSystem.registerOverwrittenFunctions(vehicleType)
    SpecializationUtil.registerOverwrittenFunction(vehicleType, "getSpeedLimit", IDS_Breakdowns.getSpeedLimit)
    SpecializationUtil.registerOverwrittenFunction(vehicleType, "getCanBeTurnedOn", IDS_Breakdowns.getCanBeTurnedOn)
    SpecializationUtil.registerOverwrittenFunction(vehicleType, "getIsFoldAllowed", IDS_Breakdowns.getIsFoldAllowed)
    SpecializationUtil.registerOverwrittenFunction(vehicleType, "getDischargeNodeEmptyFactor", IDS_Breakdowns.getDischargeNodeEmptyFactor)
    SpecializationUtil.registerOverwrittenFunction(vehicleType, "getSellPrice", IDS_Breakdowns.getSellPrice)
end

function ImplementDamageSystem.registerFunctions(vehicleType)
    SpecializationUtil.registerFunction(vehicleType, "idsUpdateConditionLevel", ImplementDamageSystem.idsUpdateConditionLevel)
    SpecializationUtil.registerFunction(vehicleType, "idsGetIsWorking", ImplementDamageSystem.idsGetIsWorking)
    SpecializationUtil.registerFunction(vehicleType, "idsCollectDrivers", ImplementDamageSystem.idsCollectDrivers)
end

function ImplementDamageSystem.registerEventListeners(vehicleType)
    SpecializationUtil.registerEventListener(vehicleType, "onLoad", ImplementDamageSystem)
    SpecializationUtil.registerEventListener(vehicleType, "onPostLoad", ImplementDamageSystem)
    SpecializationUtil.registerEventListener(vehicleType, "onUpdate", ImplementDamageSystem)
    SpecializationUtil.registerEventListener(vehicleType, "saveToXMLFile", ImplementDamageSystem)
end

-- ===========================================================
--                    SYSTEM DETECTION
-- ===========================================================

local function detectApplicableSystems(vehicle)
    local S = ImplementDamageSystem.SYSTEMS
    local enabled = {}

    -- CHASSIS: every implement has a frame; wheels/bearings where present.
    enabled[S.CHASSIS] = true

    local workAreaSpec = vehicle.spec_workArea
    if workAreaSpec ~= nil and workAreaSpec.workAreas ~= nil and #workAreaSpec.workAreas > 0 then
        enabled[S.GROUNDTOOL] = true
    end

    local ptoSpec = vehicle.spec_powerTakeOffs
    if ptoSpec ~= nil then
        local inputCount = ptoSpec.inputPowerTakeOffs ~= nil and #ptoSpec.inputPowerTakeOffs or 0
        local localCount = ptoSpec.localPowerTakeOffs ~= nil and #ptoSpec.localPowerTakeOffs or 0
        if inputCount > 0 or localCount > 0 then
            enabled[S.DRIVELINE] = true
        end
    end

    local foldableSpec = vehicle.spec_foldable
    if foldableSpec ~= nil and foldableSpec.foldingParts ~= nil and #foldableSpec.foldingParts > 0 then
        enabled[S.HYDRAULICS] = true
    end
    local cylinderedSpec = vehicle.spec_cylindered
    if cylinderedSpec ~= nil and cylinderedSpec.movingTools ~= nil and #cylinderedSpec.movingTools > 0 then
        enabled[S.HYDRAULICS] = true
    end

    if vehicle.spec_pickup ~= nil or vehicle.spec_dischargeable ~= nil then
        enabled[S.MATERIALFLOW] = true
    end
    local fillUnitSpec = vehicle.spec_fillUnit
    if fillUnitSpec ~= nil and fillUnitSpec.fillUnits ~= nil then
        for _, fillUnit in ipairs(fillUnitSpec.fillUnits) do
            if (fillUnit.capacity or 0) > 0 then
                enabled[S.MATERIALFLOW] = true
                break
            end
        end
    end

    if vehicle.spec_baler ~= nil or vehicle.spec_baleWrapper ~= nil then
        enabled[S.BINDING] = true
    end

    return enabled
end

-- ===========================================================
--                       LIFECYCLE
-- ===========================================================

function ImplementDamageSystem:onLoad(savegame)
    local spec = self.spec_ImplementDamageSystem

    spec.serviceLevel = nil
    spec.conditionLevel = 1.0
    spec.systems = {}
    spec.activeBreakdowns = {}
    spec.activeEffects = {}
    for _, systemName in pairs(ImplementDamageSystem.SYSTEMS) do
        spec.systems[systemName] = { enabled = false, condition = 1.0, stress = 0.0 }
    end
end

function ImplementDamageSystem:onPostLoad(savegame)
    local spec = self.spec_ImplementDamageSystem

    -- Runtime train guard: setSplineSpeed only exists on SplineVehicle (train
    -- wagons). Leaving serviceLevel nil keeps every other code path inert.
    if self.setSplineSpeed ~= nil then
        log_dbg("Skipping spline vehicle:", self:getFullName())
        return
    end

    -- Detection runs in onPostLoad: PTO/fill/fold data is not populated during onLoad.
    local enabled = detectApplicableSystems(self)
    local enabledNames = {}
    for systemName, isEnabled in pairs(enabled) do
        if spec.systems[systemName] ~= nil and isEnabled then
            spec.systems[systemName].enabled = true
            table.insert(enabledNames, systemName)
        end
    end
    table.sort(enabledNames)

    -- Reliability derived from list price, not a brand table: cheap kit wears
    -- faster, premium slower. Deterministic, so never saved.
    local price = 0
    if self.getPrice ~= nil then
        price = self:getPrice() or 0
    end
    if price <= 0 then
        local storeItem = g_storeManager:getItemByXMLFilename(self.configFileName)
        price = storeItem ~= nil and storeItem.price or 0
    end
    local priceFactor = math.min(price / IDS_Config.RELIABILITY_PRICE_CAP, 1.0)
    spec.reliability = IDS_Config.RELIABILITY_MIN + (IDS_Config.RELIABILITY_MAX - IDS_Config.RELIABILITY_MIN) * priceFactor

    if savegame ~= nil then
        local key = savegame.key .. ".ImplementDamageSystem"
        spec.serviceLevel = savegame.xmlFile:getValue(key .. "#service")
        local systemsState = savegame.xmlFile:getValue(key .. "#systemsState")
        if systemsState ~= nil then
            for entry in string.gmatch(systemsState, "[^;]+") do
                local systemName, condition, stress = string.match(entry, "([%u_]+)=([%d%.]+):([%d%.]+)")
                if systemName ~= nil and spec.systems[systemName] ~= nil then
                    spec.systems[systemName].condition = math.clamp(tonumber(condition) or 1.0, 0.001, 1.0)
                    spec.systems[systemName].stress = math.max(tonumber(stress) or 0.0, 0.0)
                end
            end
        end
        IDS_Breakdowns.deserialize(self, savegame.xmlFile:getValue(key .. "#breakdowns"))
        local pending = savegame.xmlFile:getValue(key .. "#pendingService")
        if pending ~= nil and pending ~= "" then
            local action, finishDay, finishTime = string.match(pending, "([%u_]+):(%d+):([%d%.]+)")
            if action ~= nil and IDS_Workshop.ACTIONS[action] ~= nil then
                spec.pendingService = { action = action, finishDay = tonumber(finishDay) or 0, finishTime = tonumber(finishTime) or 0 }
            end
        end
        local logValue = savegame.xmlFile:getValue(key .. "#maintenanceLog")
        if logValue ~= nil and logValue ~= "" then
            spec.maintenanceLog = {}
            for entry in string.gmatch(logValue, "[^|]+") do
                table.insert(spec.maintenanceLog, entry)
            end
        end
    end

    -- First adoption: absorb the base-game Wearable damage as our starting state,
    -- same as ADS does for motorized vehicles.
    if spec.serviceLevel == nil then
        local damage = self.getDamageAmount ~= nil and self:getDamageAmount() or 0
        spec.serviceLevel = math.clamp(1.0 - damage, 0.001, 1.0)
        for _, systemData in pairs(spec.systems) do
            if systemData.enabled then
                systemData.condition = math.clamp(1.0 - damage * 0.5, 0.001, 1.0)
            end
        end
    end

    self:idsUpdateConditionLevel()
    log_dbg("Tracking", self:getFullName(), "systems:", table.concat(enabledNames, ","),
        string.format("service=%.3f condition=%.3f", spec.serviceLevel, spec.conditionLevel))
end

function ImplementDamageSystem:saveToXMLFile(xmlFile, key, usedModNames)
    local spec = self.spec_ImplementDamageSystem
    if spec == nil or spec.serviceLevel == nil then
        return
    end
    xmlFile:setValue(key .. "#service", spec.serviceLevel)
    local parts = {}
    for systemName, systemData in pairs(spec.systems) do
        if systemData.enabled then
            table.insert(parts, string.format("%s=%.4f:%.4f", systemName, systemData.condition, systemData.stress))
        end
    end
    table.sort(parts)
    xmlFile:setValue(key .. "#systemsState", table.concat(parts, ";"))
    xmlFile:setValue(key .. "#breakdowns", IDS_Breakdowns.serialize(spec))
    if spec.pendingService ~= nil then
        xmlFile:setValue(key .. "#pendingService", string.format("%s:%d:%.0f",
            spec.pendingService.action, spec.pendingService.finishDay, spec.pendingService.finishTime))
    end
    if spec.maintenanceLog ~= nil and #spec.maintenanceLog > 0 then
        xmlFile:setValue(key .. "#maintenanceLog", table.concat(spec.maintenanceLog, "|"))
    end
end

-- ===========================================================
--                    STATE UPDATES
-- ===========================================================

function ImplementDamageSystem:idsGetIsWorking()
    if self.getIsTurnedOn ~= nil and self:getIsTurnedOn() then
        return true
    end
    -- The attacher joint's moveDown state persists while parked, so "lowered"
    -- only counts as work when the machine is actually travelling.
    local isMoving = self.getLastSpeed ~= nil and self:getLastSpeed() > 0.5
    if isMoving then
        if self.getIsImplementChainLowered ~= nil and self:getIsImplementChainLowered() then
            return true
        end
        if self.getIsLowered ~= nil and self:getIsLowered() then
            return true
        end
    end
    return false
end

-- ===========================================================
--                      WEAR DRIVERS
-- ===========================================================

local function getIsUnderRoof(vehicle)
    local mission = g_currentMission
    if mission ~= nil and mission.indoorMask ~= nil and mission.indoorMask.getIsIndoorAtWorldPosition ~= nil then
        local node = vehicle.rootNode
        if node ~= nil and node ~= 0 then
            local x, _, z = getWorldTranslation(node)
            return mission.indoorMask:getIsIndoorAtWorldPosition(x, z) == true
        end
    end
    return false
end

local function getIsGroundProcessing(vehicle)
    local workAreaSpec = vehicle.spec_workArea
    if workAreaSpec == nil or vehicle.getIsWorkAreaProcessing == nil then
        return false
    end
    for _, workArea in ipairs(workAreaSpec.workAreas) do
        if vehicle:getIsWorkAreaProcessing(workArea) then
            return true
        end
    end
    return false
end

local function getFillRatio(vehicle)
    local fillUnitSpec = vehicle.spec_fillUnit
    if fillUnitSpec == nil or fillUnitSpec.fillUnits == nil then
        return 0
    end
    local maxRatio = 0
    for _, fillUnit in ipairs(fillUnitSpec.fillUnits) do
        if (fillUnit.capacity or 0) > 0 then
            maxRatio = math.max(maxRatio, (fillUnit.fillLevel or 0) / fillUnit.capacity)
        end
    end
    return maxRatio
end

-- Snapshot of every wear driver for this tick; also feeds idsDump diagnostics.
function ImplementDamageSystem:idsCollectDrivers()
    local isTurnedOn = self.getIsTurnedOn ~= nil and self:getIsTurnedOn()
    local isWorking = self:idsGetIsWorking()
    local speed = self.getLastSpeed ~= nil and self:getLastSpeed() or 0
    local isMoving = speed > 0.5

    local speedLimit = self.speedLimit
    local overspeed = 0
    if isWorking and speedLimit ~= nil and speedLimit > 0 and speedLimit < math.huge then
        overspeed = math.max(speed / speedLimit - 1.0, 0)
    end

    local ptoActive = false
    if self.getIsPowerTakeOffActive ~= nil then
        ptoActive = isWorking and self:getIsPowerTakeOffActive()
    else
        ptoActive = isTurnedOn
    end

    return {
        isTurnedOn = isTurnedOn,
        isWorking = isWorking,
        isMoving = isMoving,
        speed = speed,
        overspeed = overspeed,
        processing = getIsGroundProcessing(self),
        ptoActive = ptoActive,
        fillRatio = getFillRatio(self),
        isRoadTravel = not isWorking and speed > IDS_Config.ROAD_SPEED_THRESHOLD
    }
end

-- Activity level 0..n per system for this tick. 1.0 = full working wear.
local function getSystemActivity(systemName, d)
    local A = IDS_Config.SYSTEM_ACTIVITY
    local S = ImplementDamageSystem.SYSTEMS
    local overspeedMult = 1 + IDS_Config.OVERSPEED_GAIN * d.overspeed

    if systemName == S.GROUNDTOOL then
        return d.processing and overspeedMult or 0
    elseif systemName == S.DRIVELINE then
        return d.ptoActive and overspeedMult or 0
    elseif systemName == S.HYDRAULICS then
        return d.isWorking and A.HYDRAULICS_WORKING or 0
    elseif systemName == S.MATERIALFLOW then
        return d.isTurnedOn and (A.MATERIALFLOW_BASE + A.MATERIALFLOW_FILL * d.fillRatio) or 0
    elseif systemName == S.CHASSIS then
        if d.isMoving then
            return (d.speed / A.CHASSIS_SPEED_NORM) * (A.CHASSIS_BASE + A.CHASSIS_FILL * d.fillRatio)
        end
        return 0
    elseif systemName == S.BINDING then
        return d.isTurnedOn and 1.0 or 0
    end
    return 0
end

-- Catch-up for vehicles whose onUpdate is not running (asleep/out of range).
-- Called from the mod-level HOUR_CHANGED handler; dtRealMs is real elapsed
-- time since the last advance, so awake vehicles (advanced every frame) are
-- never double-counted.
function ImplementDamageSystem.advanceSleeping(vehicle, dtRealMs)
    local spec = vehicle.spec_ImplementDamageSystem
    if spec == nil or spec.serviceLevel == nil then
        return
    end
    if dtRealMs > 0 then
        local hourFraction = dtRealMs / (60 * 60 * 1000)
        local reliability = spec.reliability or 1.0
        spec.isUnderRoof = getIsUnderRoof(vehicle)
        local mult = spec.isUnderRoof and IDS_Config.SERVICE_UNDER_ROOF_MULT or IDS_Config.SERVICE_DOWNTIME_MULT
        spec.serviceLevel = math.max(spec.serviceLevel - IDS_Config.BASE_SERVICE_WEAR * mult / reliability * hourFraction, 0.001)
    end
    spec.idsLastRealTime = g_time
    IDS_Workshop.updatePendingService(vehicle)
end

function ImplementDamageSystem:onUpdate(dt, isActiveForInput, isActiveForInputIgnoreSelection, isSelected)
    if not self.isServer then
        return
    end
    local spec = self.spec_ImplementDamageSystem
    if spec == nil or spec.serviceLevel == nil then
        return
    end
    spec.idsLastRealTime = g_time

    local d = self:idsCollectDrivers()
    spec.lastDrivers = d
    local hourFraction = dt / (60 * 60 * 1000)
    local reliability = spec.reliability or 1.0

    -- The indoor check reads a density map; refresh it every ~5s, not every frame.
    spec.roofCheckTimer = (spec.roofCheckTimer or 5000) + dt
    if spec.roofCheckTimer >= 5000 then
        spec.roofCheckTimer = 0
        spec.isUnderRoof = getIsUnderRoof(self)
    end

    local serviceRate
    if d.isWorking then
        serviceRate = IDS_Config.BASE_SERVICE_WEAR * (1 + IDS_Config.OVERSPEED_GAIN * d.overspeed)
    elseif d.isRoadTravel then
        serviceRate = IDS_Config.BASE_SERVICE_WEAR * IDS_Config.SERVICE_ROAD_MULT
    elseif spec.isUnderRoof then
        serviceRate = IDS_Config.BASE_SERVICE_WEAR * IDS_Config.SERVICE_UNDER_ROOF_MULT
    else
        serviceRate = IDS_Config.BASE_SERVICE_WEAR * IDS_Config.SERVICE_DOWNTIME_MULT
    end
    spec.serviceLevel = math.max(spec.serviceLevel - serviceRate / reliability * hourFraction, 0.001)

    local anyChange = false
    for systemName, systemData in pairs(spec.systems) do
        if systemData.enabled then
            local activity = getSystemActivity(systemName, d)
            if activity > 0 then
                local wear = IDS_Config.BASE_SYSTEMS_WEAR * activity / reliability * hourFraction
                systemData.condition = math.clamp(systemData.condition - wear, 0.001, 1.0)
                -- Stress = the part of the wear beyond normal working rate (abuse:
                -- overspeed, overfill). Feeds breakdown probability in Stage 3.
                if activity > 1.0 then
                    systemData.stress = systemData.stress + IDS_Config.BASE_SYSTEMS_WEAR * (activity - 1.0) * hourFraction
                end
                anyChange = true
            end
        end
    end

    local chassis = spec.systems[ImplementDamageSystem.SYSTEMS.CHASSIS]
    if chassis ~= nil and chassis.enabled and d.isMoving and d.fillRatio > IDS_Config.OVERFILL_THRESHOLD then
        local overfill = (d.fillRatio - IDS_Config.OVERFILL_THRESHOLD) / (1 - IDS_Config.OVERFILL_THRESHOLD)
        chassis.stress = chassis.stress + IDS_Config.BASE_SYSTEMS_WEAR * IDS_Config.OVERFILL_STRESS_GAIN * overfill * hourFraction
    end

    if anyChange then
        self:idsUpdateConditionLevel()
    end

    IDS_Breakdowns.update(self, dt, d.isWorking)
    IDS_Workshop.updatePendingService(self)
end

-- ===========================================================
--              MARKET SEEDING (used-machinery bridge)
-- ===========================================================
-- Public entry point for used-machinery mods. FS25_AgroTrader calls it at delivery via
-- _G["FS25_ImplementDamageSystem"].ImplementDamageSystem.seedFromMarket(vehicle, info) with
--   info = { care = 0..1, serviceHistory = "full"|"part"|"none", damage = 0..1 }
-- so the advert's facts, not the base-game damage figure, decide what a delivered implement
-- is secretly carrying. Everything here goes through IDS's own registry and state; the caller
-- never pokes internals. Safe to call once, right after purchase, on the server.
--
-- Tier mapping mirrors AgroTrader's ADS profile (DeliveryADS.rollProfile): full history caps
-- the gamble at one minor visible fault and buys a fresh service; part history is the honest
-- middle; no history always hides something, possibly advanced.

ImplementDamageSystem.SEED_CONDITION_MIN = 0.05
ImplementDamageSystem.SEED_CONDITION_MAX = 0.95
ImplementDamageSystem.SEED_CONDITION_JITTER = 0.08

function ImplementDamageSystem.seedFromMarket(vehicle, info)
    if vehicle == nil or type(info) ~= "table" then
        return false
    end
    local spec = vehicle.spec_ImplementDamageSystem
    if spec == nil or spec.serviceLevel == nil then
        -- No IDS state on this vehicle (spline vehicle, or onPostLoad has not run).
        return false
    end

    local care = math.clamp(info.care or 0.5, 0, 1)
    local damage = math.clamp(info.damage or 0.5, 0, 1)
    local tier = info.serviceHistory or "part"

    -- Service tracks how the machine was looked after; a full history means it left the
    -- seller freshly serviced on top of a life of good care.
    spec.serviceLevel = math.clamp(care * 0.9 + 0.05, 0.02, 0.95)
    if tier == "full" then
        spec.serviceLevel = math.max(spec.serviceLevel, 0.85)
        IDS_Workshop.addLogEntry(vehicle, "Serviced (sold with full service history)")
    else
        IDS_Workshop.addLogEntry(vehicle, "Purchased used - "
            .. (tier == "none" and "no" or "partial") .. " service history")
    end

    -- Per-system condition spread around the advert's damage figure, jittered so the systems
    -- tell a story rather than reading as one number repeated. Worst-first list kept so the
    -- faults below land on whatever is weakest.
    local target = math.clamp(1 - damage,
        ImplementDamageSystem.SEED_CONDITION_MIN, ImplementDamageSystem.SEED_CONDITION_MAX)
    local worst = {}
    for systemName, systemData in pairs(spec.systems) do
        if systemData.enabled then
            local jitter = (math.random() * 2 - 1) * ImplementDamageSystem.SEED_CONDITION_JITTER
            systemData.condition = math.clamp(target + jitter,
                ImplementDamageSystem.SEED_CONDITION_MIN, ImplementDamageSystem.SEED_CONDITION_MAX)
            systemData.stress = 0
            table.insert(worst, { name = systemName, condition = systemData.condition })
        end
    end
    table.sort(worst, function(a, b) return a.condition < b.condition end)
    vehicle:idsUpdateConditionLevel()

    -- The faults the seller did not mention. The history tier caps the roll; a hidden fault
    -- stays undiscovered until the player notices a symptom or pays for an inspection.
    local count, hiddenChance, stageMax
    if tier == "full" then
        count = math.random() < 0.35 and 1 or 0
        hiddenChance = 0.10
        stageMax = 1
    elseif tier == "none" then
        count = math.random(1, 2)
        if damage > 0.5 then
            count = count + math.random(0, 2)
        end
        hiddenChance = 0.50
        stageMax = 3
    else
        count = math.random(0, 2)
        hiddenChance = 0.30
        stageMax = 2
    end

    -- Candidate faults, aimed at the weakest systems first.
    local candidates = {}
    for _, entry in ipairs(worst) do
        for id, def in pairs(IDS_Breakdowns.Registry) do
            if def.system == entry.name and def.isApplicable(vehicle) then
                table.insert(candidates, { id = id, stages = #def.stages })
            end
        end
    end

    local added = 0
    for _, candidate in ipairs(candidates) do
        if added >= count then
            break
        end
        local stage = math.random(1, math.min(stageMax, candidate.stages))
        if IDS_Breakdowns.addBreakdown(vehicle, candidate.id, stage) then
            added = added + 1
            if math.random() >= hiddenChance then
                -- Visible fault: the seller admitted it, or it is obvious on the lorry.
                -- addBreakdown starts everything undiscovered and rolls the notice itself;
                -- this only ever upgrades to discovered, never hides a noticed fault.
                local breakdown = spec.activeBreakdowns[#spec.activeBreakdowns]
                if breakdown ~= nil and breakdown.id == candidate.id then
                    breakdown.discovered = true
                end
            end
        end
    end

    log_dbg("Market seed:", vehicle:getFullName(),
        string.format("tier=%s service=%.3f condition=%.3f faults=%d", tier,
            spec.serviceLevel, spec.conditionLevel, added))
    return true
end

function ImplementDamageSystem:idsUpdateConditionLevel()
    local spec = self.spec_ImplementDamageSystem
    local weightedCondition = 0
    local totalWeight = 0
    for systemName, systemData in pairs(spec.systems) do
        if systemData.enabled then
            local weight = ImplementDamageSystem.getSystemWeight(systemName)
            weightedCondition = weightedCondition + systemData.condition * weight
            totalWeight = totalWeight + weight
        end
    end
    if totalWeight > 0 then
        spec.conditionLevel = math.clamp(weightedCondition / totalWeight, 0.001, 1.0)
    else
        spec.conditionLevel = 1.0
    end
end
