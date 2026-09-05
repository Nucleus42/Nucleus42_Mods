-- ImplementDamageSystem breakdown engine - Stage 3.
-- Registry format copied from ADS (GPL-3), effects simplified: instead of ADS's
-- apply/remove EffectApplicators, overwritten vehicle functions read the
-- aggregated spec.activeEffects table and no-op when it is empty.

IDS_Breakdowns = {}

local function log_dbg(...)
    if IDS_Config and IDS_Config.DEBUG then
        local args = {...}
        for i = 1, #args do
            args[i] = tostring(args[i])
        end
        print("[IDS_BREAKDOWNS] " .. table.concat(args, " "))
    end
end

-- ===========================================================
--                        REGISTRY
-- ===========================================================
-- Each stage: severity label, effects table, progressHours = working hours at
-- normal wear until the next stage (nil = final stage), detectionChance = odds
-- an inspection finds it (used by the Stage 4 GUI; idsDump always shows all).

-- symptom: vague player-facing text shown when the fault is NOTICED (%s = machine
-- name). noticeChance: odds the player notices when the stage begins — separate
-- from detectionChance, which is the workshop inspection's odds of finding it.
-- A noticed or inspected fault is "discovered" and becomes repairable.

IDS_Breakdowns.Registry = {

    SNAPPED_TINES = {
        system = "GROUNDTOOL",
        name = "Broken tines",
        repairCostFactor = { 0.004, 0.012, 0.03 },
        isApplicable = function(vehicle)
            local spec = vehicle.spec_ImplementDamageSystem
            local workAreaSpec = vehicle.spec_workArea
            return spec.systems.GROUNDTOOL ~= nil and spec.systems.GROUNDTOOL.enabled
                and workAreaSpec ~= nil and #workAreaSpec.workAreas > 0
        end,
        stages = {
            { severity = "minor",    detectionChance = 0.4, noticeChance = 0.0, progressHours = 2.0,
              effects = {} },
            { severity = "moderate", detectionChance = 0.7, noticeChance = 0.5, progressHours = 3.0,
              symptom = "%s is leaving rough, uneven ground behind",
              effects = { workAreaWidthReduction = 0.25 } },
            { severity = "critical", detectionChance = 1.0, noticeChance = 1.0, progressHours = nil,
              symptom = "%s has broken tines - part of the working width is doing nothing",
              effects = { workAreaWidthReduction = 0.5 } }
        }
    },

    BEARING_SEIZURE = {
        system = "CHASSIS",
        name = "Wheel bearing failure",
        repairCostFactor = { 0.006, 0.018, 0.045 },
        isApplicable = function(vehicle)
            local spec = vehicle.spec_ImplementDamageSystem
            return spec.systems.CHASSIS ~= nil and spec.systems.CHASSIS.enabled
                and vehicle.spec_wheels ~= nil and vehicle.spec_wheels.wheels ~= nil
                and #vehicle.spec_wheels.wheels > 0
        end,
        stages = {
            { severity = "minor",    detectionChance = 0.3, noticeChance = 0.3, progressHours = 1.5,
              symptom = "%s: a wheel is running rough",
              effects = { speedCap = 25 } },
            { severity = "moderate", detectionChance = 0.8, noticeChance = 1.0, progressHours = 2.0,
              symptom = "%s: a wheel bearing is grinding badly - keep the speed down",
              effects = { speedCap = 12 } },
            { severity = "critical", detectionChance = 1.0, noticeChance = 1.0, progressHours = nil,
              symptom = "%s: a wheel bearing has seized",
              effects = { speedCap = 2 } }
        }
    },

    BLUNT_KNIVES = {
        system = "GROUNDTOOL",
        name = "Blunt knives",
        repairCostFactor = { 0.003, 0.008, 0.02 },
        isApplicable = function(vehicle)
            return vehicle.spec_mower ~= nil or vehicle.spec_forageWagon ~= nil
        end,
        stages = {
            { severity = "minor",    detectionChance = 0.5, noticeChance = 0.0, progressHours = 3.0,
              effects = {} },
            { severity = "moderate", detectionChance = 0.8, noticeChance = 0.5, progressHours = 4.0,
              symptom = "%s is tearing rather than cutting - the knives are going blunt",
              effects = { speedCap = 14 } },
            { severity = "critical", detectionChance = 1.0, noticeChance = 1.0, progressHours = nil,
              symptom = "%s: the knives are worn out - it can barely cut at speed",
              effects = { speedCap = 9 } }
        }
    },

    RAM_LEAK = {
        system = "HYDRAULICS",
        name = "Hydraulic ram leak",
        repairCostFactor = { 0.004, 0.01, 0.025 },
        isApplicable = function(vehicle)
            local spec = vehicle.spec_ImplementDamageSystem
            return spec.systems.HYDRAULICS ~= nil and spec.systems.HYDRAULICS.enabled
                and vehicle.spec_foldable ~= nil and vehicle.spec_foldable.foldingParts ~= nil
                and #vehicle.spec_foldable.foldingParts > 0
        end,
        stages = {
            { severity = "minor",    detectionChance = 0.4, noticeChance = 0.2, progressHours = 2.0,
              symptom = "%s is weeping oil from a ram seal",
              effects = {} },
            { severity = "moderate", detectionChance = 0.8, noticeChance = 0.6, progressHours = 2.5,
              symptom = "%s is losing hydraulic oil - the rams are struggling",
              effects = {} },
            { severity = "critical", detectionChance = 1.0, noticeChance = 1.0, progressHours = nil,
              symptom = "%s: a hydraulic ram has failed - it will not fold or unfold",
              effects = { foldBlocked = true } }
        }
    },

    SLIPPED_CHAIN_BELT = {
        system = "DRIVELINE",
        name = "Slipping drive chain/belt",
        repairCostFactor = { 0.002, 0.006, 0.015 },
        isApplicable = function(vehicle)
            local spec = vehicle.spec_ImplementDamageSystem
            return spec.systems.DRIVELINE ~= nil and spec.systems.DRIVELINE.enabled
                and vehicle.getIsTurnedOn ~= nil
        end,
        stages = {
            { severity = "minor",    detectionChance = 0.4, noticeChance = 0.2, progressHours = 1.5,
              symptom = "%s: a drive chain is rattling",
              effects = { cutoutChance = 0.08 } },
            { severity = "moderate", detectionChance = 0.8, noticeChance = 0.8, progressHours = 2.0,
              symptom = "%s keeps slipping its drive - it is cutting out under load",
              effects = { cutoutChance = 0.25 } },
            { severity = "critical", detectionChance = 1.0, noticeChance = 1.0, progressHours = nil,
              symptom = "%s has thrown its drive chain",
              effects = { turnOnBlocked = true } }
        }
    },

    AUGER_WEAR = {
        system = "MATERIALFLOW",
        name = "Worn auger",
        repairCostFactor = { 0.004, 0.012, 0.03 },
        isApplicable = function(vehicle)
            local spec = vehicle.spec_ImplementDamageSystem
            return spec.systems.MATERIALFLOW ~= nil and spec.systems.MATERIALFLOW.enabled
                and vehicle.spec_dischargeable ~= nil
        end,
        stages = {
            { severity = "minor",    detectionChance = 0.5, noticeChance = 0.0, progressHours = 3.0,
              effects = { dischargeFactor = 0.8 } },
            { severity = "moderate", detectionChance = 0.8, noticeChance = 0.6, progressHours = 4.0,
              symptom = "%s is unloading noticeably slower than it should",
              effects = { dischargeFactor = 0.55 } },
            { severity = "critical", detectionChance = 1.0, noticeChance = 1.0, progressHours = nil,
              symptom = "%s: the unloading auger is badly worn - it is barely moving material",
              effects = { dischargeFactor = 0.3 } }
        }
    },

    KNOTTER_FAULT = {
        system = "BINDING",
        name = "Knotter fault",
        repairCostFactor = { 0.003, 0.01, 0.025 },
        isApplicable = function(vehicle)
            local spec = vehicle.spec_ImplementDamageSystem
            return spec.systems.BINDING ~= nil and spec.systems.BINDING.enabled
                and vehicle.spec_baler ~= nil
        end,
        stages = {
            { severity = "minor",    detectionChance = 0.4, noticeChance = 0.0, progressHours = 1.5,
              effects = {} },
            { severity = "moderate", detectionChance = 0.8, noticeChance = 0.7, progressHours = 2.0,
              symptom = "%s: the knotter keeps missing - it is jamming mid-bale",
              effects = { cutoutChance = 0.2 } },
            { severity = "critical", detectionChance = 1.0, noticeChance = 1.0, progressHours = nil,
              symptom = "%s: the knotter has jammed solid",
              effects = { turnOnBlocked = true } }
        }
    },

    SPINNER_BEARING = {
        system = "MATERIALFLOW",
        name = "Spinner disc bearing",
        repairCostFactor = { 0.003, 0.009 },
        isApplicable = function(vehicle)
            return vehicle.spec_sprayer ~= nil and vehicle.spec_workArea ~= nil
                and vehicle.spec_workArea.workAreas ~= nil
                and #vehicle.spec_workArea.workAreas > 0
        end,
        stages = {
            { severity = "minor",    detectionChance = 0.5, noticeChance = 0.3, progressHours = 2.0,
              symptom = "%s: a spinner disc is wobbling - the spread pattern looks off",
              effects = { workAreaWidthReduction = 0.15 } },
            { severity = "critical", detectionChance = 1.0, noticeChance = 1.0, progressHours = nil,
              symptom = "%s: a spinner bearing has collapsed - spread width is badly down",
              effects = { workAreaWidthReduction = 0.35 } }
        }
    },

    DRAWBAR_CRACK = {
        system = "CHASSIS",
        name = "Cracked drawbar/frame",
        repairCostFactor = { 0.008, 0.02, 0.05 },
        isApplicable = function(vehicle)
            local spec = vehicle.spec_ImplementDamageSystem
            return spec.systems.CHASSIS ~= nil and spec.systems.CHASSIS.enabled
        end,
        stages = {
            { severity = "minor",    detectionChance = 0.2, noticeChance = 0.0, progressHours = 2.0,
              effects = {} },
            { severity = "moderate", detectionChance = 0.6, noticeChance = 0.6, progressHours = 1.5,
              symptom = "%s: something in the frame is creaking under load",
              effects = { speedCap = 15 } },
            { severity = "critical", detectionChance = 1.0, noticeChance = 1.0, progressHours = nil,
              symptom = "%s: the drawbar is cracked right through - crawl it home before it lets go",
              effects = { speedCap = 5 } }
        }
    },

    PTO_SHAFT_WEAR = {
        system = "DRIVELINE",
        name = "PTO shaft wear",
        repairCostFactor = { 0.003, 0.009, 0.022 },
        isApplicable = function(vehicle)
            local spec = vehicle.spec_ImplementDamageSystem
            return spec.systems.DRIVELINE ~= nil and spec.systems.DRIVELINE.enabled
        end,
        stages = {
            { severity = "minor",    detectionChance = 0.4, noticeChance = 0.3, progressHours = 2.0,
              symptom = "%s: the PTO shaft is vibrating",
              effects = {} },
            { severity = "moderate", detectionChance = 0.8, noticeChance = 0.8, progressHours = 2.0,
              symptom = "%s: the PTO shaft is knocking hard - it keeps kicking out",
              effects = { cutoutChance = 0.15 } },
            { severity = "critical", detectionChance = 1.0, noticeChance = 1.0, progressHours = nil,
              symptom = "%s: the PTO shaft has sheared",
              effects = { turnOnBlocked = true } }
        }
    },

    BLOCKED_PICKUP = {
        system = "MATERIALFLOW",
        name = "Blocked pickup",
        repairCostFactor = { 0.003, 0.01 },
        isApplicable = function(vehicle)
            local spec = vehicle.spec_ImplementDamageSystem
            return spec.systems.MATERIALFLOW ~= nil and spec.systems.MATERIALFLOW.enabled
                and vehicle.spec_pickup ~= nil
                and vehicle.getCanBeTurnedOn ~= nil
        end,
        stages = {
            { severity = "minor",    detectionChance = 0.5, noticeChance = 0.2, progressHours = 0.5,
              symptom = "%s: the pickup is snatching and feeding unevenly",
              effects = {} },
            { severity = "critical", detectionChance = 1.0, noticeChance = 1.0, progressHours = nil,
              symptom = "%s has blocked up and shut down",
              effects = { turnOnBlocked = true } }
        }
    }
}

-- ===========================================================
--                     NOTIFICATIONS
-- ===========================================================

function IDS_Breakdowns.notify(text)
    local mission = g_currentMission
    if mission ~= nil and mission.hud ~= nil then
        mission.hud:addSideNotification(FSBaseMission.INGAME_NOTIFICATION_CRITICAL, text, 15000,
            GuiSoundPlayer.SOUND_SAMPLES.NOTIFICATION)
    end
end

-- Rolls whether the player notices this stage starting. Noticed = discovered.
local function rollNotice(vehicle, breakdown, stage)
    if breakdown.discovered then
        if stage.symptom ~= nil then
            IDS_Breakdowns.notify(string.format(stage.symptom, vehicle:getFullName()))
        end
        return
    end
    if math.random() < (stage.noticeChance or 0) and stage.symptom ~= nil then
        breakdown.discovered = true
        IDS_Breakdowns.notify(string.format(stage.symptom, vehicle:getFullName()))
    end
end

-- ===========================================================
--                  EFFECT AGGREGATION
-- ===========================================================

function IDS_Breakdowns.recalculateEffects(vehicle)
    local spec = vehicle.spec_ImplementDamageSystem
    local effects = {
        speedCap = nil,
        turnOnBlocked = false
    }

    local widthReduction = 0
    for _, breakdown in ipairs(spec.activeBreakdowns) do
        local def = IDS_Breakdowns.Registry[breakdown.id]
        local stage = def ~= nil and def.stages[breakdown.stage] or nil
        if stage ~= nil then
            local e = stage.effects
            if e.speedCap ~= nil then
                effects.speedCap = math.min(effects.speedCap or math.huge, e.speedCap)
            end
            if e.turnOnBlocked then
                effects.turnOnBlocked = true
            end
            if e.workAreaWidthReduction ~= nil then
                widthReduction = math.max(widthReduction, e.workAreaWidthReduction)
            end
            if e.foldBlocked then
                effects.foldBlocked = true
            end
            if e.cutoutChance ~= nil then
                effects.cutoutChance = math.max(effects.cutoutChance or 0, e.cutoutChance)
            end
            if e.dischargeFactor ~= nil then
                effects.dischargeFactor = math.min(effects.dischargeFactor or 1, e.dischargeFactor)
            end
        end
    end
    effects.widthReduction = widthReduction

    spec.activeEffects = effects
    IDS_Breakdowns.applyWidthReduction(vehicle, widthReduction)

    if effects.turnOnBlocked and vehicle.isServer and vehicle.getIsTurnedOn ~= nil and vehicle:getIsTurnedOn() then
        vehicle:setIsTurnedOn(false)
    end
end

-- Physically narrows every work area by moving its width node toward its start
-- node. Works on single-area tools, where disabling whole areas cannot.
-- Backups are keyed per node so repeated recalcs always scale from original.
function IDS_Breakdowns.applyWidthReduction(vehicle, fraction)
    local workAreaSpec = vehicle.spec_workArea
    if workAreaSpec == nil or workAreaSpec.workAreas == nil then
        return
    end
    local spec = vehicle.spec_ImplementDamageSystem
    spec.idsWidthBackup = spec.idsWidthBackup or {}

    for _, workArea in ipairs(workAreaSpec.workAreas) do
        local node = workArea.width
        if node ~= nil and node ~= 0 and workArea.start ~= nil and workArea.start ~= 0 then
            local backup = spec.idsWidthBackup[node]
            if fraction > 0 then
                if backup == nil then
                    backup = { getTranslation(node) }
                    spec.idsWidthBackup[node] = backup
                end
                setTranslation(node, backup[1], backup[2], backup[3])
                local sx, sy, sz = getWorldTranslation(workArea.start)
                local wx, wy, wz = getWorldTranslation(node)
                local nx = sx + (wx - sx) * (1 - fraction)
                local ny = sy + (wy - sy) * (1 - fraction)
                local nz = sz + (wz - sz) * (1 - fraction)
                setTranslation(node, worldToLocal(getParent(node), nx, ny, nz))
            elseif backup ~= nil then
                setTranslation(node, backup[1], backup[2], backup[3])
                spec.idsWidthBackup[node] = nil
            end
        end
    end
end

-- ===========================================================
--              OVERWRITTEN VEHICLE FUNCTIONS
-- ===========================================================

function IDS_Breakdowns.getSpeedLimit(vehicle, superFunc, onlyIfWorking)
    local speed, doCheckSpeedLimit = superFunc(vehicle, onlyIfWorking)
    local spec = vehicle.spec_ImplementDamageSystem
    if spec ~= nil and spec.pendingService ~= nil then
        return 0.5, true
    end
    local cap = spec ~= nil and spec.activeEffects ~= nil and spec.activeEffects.speedCap or nil
    if cap ~= nil then
        -- A seized bearing caps you on the road too, so the limit always counts.
        return math.min(speed, cap), true
    end
    return speed, doCheckSpeedLimit
end

function IDS_Breakdowns.getCanBeTurnedOn(vehicle, superFunc)
    local spec = vehicle.spec_ImplementDamageSystem
    if spec ~= nil and (spec.pendingService ~= nil or (spec.activeEffects ~= nil and spec.activeEffects.turnOnBlocked)) then
        return false
    end
    return superFunc(vehicle)
end

function IDS_Breakdowns.getIsFoldAllowed(vehicle, superFunc, direction, onAiTurnOn)
    local spec = vehicle.spec_ImplementDamageSystem
    if spec ~= nil and spec.activeEffects ~= nil and spec.activeEffects.foldBlocked then
        return false, "A hydraulic ram has failed"
    end
    return superFunc(vehicle, direction, onAiTurnOn)
end

function IDS_Breakdowns.getDischargeNodeEmptyFactor(vehicle, superFunc, dischargeNode)
    local factor = superFunc(vehicle, dischargeNode)
    local spec = vehicle.spec_ImplementDamageSystem
    local mult = spec ~= nil and spec.activeEffects ~= nil and spec.activeEffects.dischargeFactor or nil
    if mult ~= nil then
        return factor * mult
    end
    return factor
end

-- Condition -> sell-price multiplier. When FS25_AgroTrader is installed, ask ITS valuation
-- curve (live object, pcall-guarded) instead of using our own flat formula. This closes an
-- arbitrage gap: AgroTrader prices its adverts on a steep residual curve (a worn implement
-- lists near its floor), while our flat 0.5+0.5*x pays half price even for a wreck - so a
-- player could buy a clapped-out implement cheap on the market and immediately sell it back
-- to the base shop at a profit. Aligning the two curves means the buy price and the sell
-- price of the same condition can never cross.
local function getConditionSellFactor(conditionLevel)
    if g_modIsLoaded ~= nil and g_modIsLoaded["FS25_AgroTrader"] then
        local env = _G["FS25_AgroTrader"]
        local valuation = env ~= nil and env.Valuation or nil
        if valuation ~= nil and valuation.getConditionPriceMultiplier ~= nil then
            local ok, factor = pcall(valuation.getConditionPriceMultiplier, conditionLevel)
            if ok and type(factor) == "number" then
                return math.clamp(factor, 0, 1)
            end
        end
    end
    -- AgroTrader absent (or its API moved): the original standalone formula.
    return 0.5 + 0.5 * conditionLevel
end

-- Sell price scales with true condition: a clapped-out machine is worth half - or less, on
-- AgroTrader's curve when that mod is present (see getConditionSellFactor).
function IDS_Breakdowns.getSellPrice(vehicle, superFunc)
    local price = superFunc(vehicle)
    local spec = vehicle.spec_ImplementDamageSystem
    if spec ~= nil and spec.conditionLevel ~= nil then
        price = price * getConditionSellFactor(spec.conditionLevel)
    end
    return price
end

-- ===========================================================
--                 ROLL AND PROGRESSION
-- ===========================================================

local function getIsBreakdownActive(spec, id)
    for _, breakdown in ipairs(spec.activeBreakdowns) do
        if breakdown.id == id then
            return true
        end
    end
    return false
end

function IDS_Breakdowns.addBreakdown(vehicle, id, stage)
    local spec = vehicle.spec_ImplementDamageSystem
    local def = IDS_Breakdowns.Registry[id]
    if def == nil or getIsBreakdownActive(spec, id) then
        return false
    end
    stage = math.clamp(stage or 1, 1, #def.stages)
    local breakdown = { id = id, stage = stage, progressHours = 0, discovered = false }
    table.insert(spec.activeBreakdowns, breakdown)
    IDS_Breakdowns.recalculateEffects(vehicle)
    rollNotice(vehicle, breakdown, def.stages[stage])
    log_dbg("Breakdown added:", vehicle:getFullName(), id, "stage", stage)
    return true
end

function IDS_Breakdowns.removeBreakdown(vehicle, id)
    local spec = vehicle.spec_ImplementDamageSystem
    for i, breakdown in ipairs(spec.activeBreakdowns) do
        if breakdown.id == id then
            table.remove(spec.activeBreakdowns, i)
            IDS_Breakdowns.recalculateEffects(vehicle)
            log_dbg("Breakdown removed:", vehicle:getFullName(), id)
            return true
        end
    end
    return false
end

-- Chance per working hour for one breakdown, from its system's state.
-- At condition 0.9 the machine is near-safe; at 0.5 expect trouble most days.
function IDS_Breakdowns.getChancePerHour(vehicle, def)
    local spec = vehicle.spec_ImplementDamageSystem
    local systemData = spec.systems[def.system]
    if systemData == nil or not systemData.enabled then
        return 0
    end
    local conditionRisk = (1 - systemData.condition) ^ 2 * IDS_Config.BREAKDOWN_CONDITION_GAIN
    local stressRisk = systemData.stress * IDS_Config.BREAKDOWN_STRESS_GAIN
    local serviceMult = 1 + IDS_Config.BREAKDOWN_SERVICE_GAIN * math.max(IDS_Config.SERVICE_RISK_THRESHOLD - spec.serviceLevel, 0)
    return (conditionRisk + stressRisk) * serviceMult
end

-- Called from the spec's onUpdate. Rolls new breakdowns once per real minute
-- while the implement is working, and progresses active ones by working time.
function IDS_Breakdowns.update(vehicle, dt, isWorking)
    local spec = vehicle.spec_ImplementDamageSystem
    local hourFraction = dt / (60 * 60 * 1000)

    if isWorking then
        for _, breakdown in ipairs(spec.activeBreakdowns) do
            local def = IDS_Breakdowns.Registry[breakdown.id]
            local stage = def ~= nil and def.stages[breakdown.stage] or nil
            if stage ~= nil and stage.progressHours ~= nil then
                breakdown.progressHours = breakdown.progressHours + hourFraction
                if breakdown.progressHours >= stage.progressHours then
                    breakdown.stage = breakdown.stage + 1
                    breakdown.progressHours = 0
                    IDS_Breakdowns.recalculateEffects(vehicle)
                    rollNotice(vehicle, breakdown, def.stages[breakdown.stage])
                    log_dbg("Breakdown progressed:", vehicle:getFullName(), breakdown.id, "stage", breakdown.stage)
                end
            end
        end
    end

    spec.rollTimer = (spec.rollTimer or 0) + dt
    if spec.rollTimer < IDS_Config.BREAKDOWN_ROLL_INTERVAL then
        return
    end
    spec.rollTimer = 0

    local cutout = spec.activeEffects ~= nil and spec.activeEffects.cutoutChance or nil
    if cutout ~= nil and cutout > 0 and vehicle.getIsTurnedOn ~= nil and vehicle:getIsTurnedOn() then
        if math.random() < cutout then
            vehicle:setIsTurnedOn(false)
            IDS_Breakdowns.notify(string.format("%s cut out - the drive slipped", vehicle:getFullName()))
        end
    end

    if not isWorking then
        return
    end

    local rollHours = IDS_Config.BREAKDOWN_ROLL_INTERVAL / (60 * 60 * 1000)
    for id, def in pairs(IDS_Breakdowns.Registry) do
        if not getIsBreakdownActive(spec, id) and def.isApplicable(vehicle) then
            local chance = IDS_Breakdowns.getChancePerHour(vehicle, def) * rollHours
            if chance > 0 and math.random() < chance then
                IDS_Breakdowns.addBreakdown(vehicle, id, 1)
            end
        end
    end
end

-- ===========================================================
--                     SAVE / LOAD
-- ===========================================================

function IDS_Breakdowns.serialize(spec)
    local parts = {}
    for _, breakdown in ipairs(spec.activeBreakdowns) do
        table.insert(parts, string.format("%s:%d:%.4f:%d", breakdown.id, breakdown.stage, breakdown.progressHours, breakdown.discovered and 1 or 0))
    end
    return table.concat(parts, ";")
end

function IDS_Breakdowns.deserialize(vehicle, value)
    local spec = vehicle.spec_ImplementDamageSystem
    spec.activeBreakdowns = {}
    if value ~= nil and value ~= "" then
        for entry in string.gmatch(value, "[^;]+") do
            local id, stage, progress, discovered = string.match(entry, "([%u_]+):(%d+):([%d%.]+):?(%d?)")
            local def = id ~= nil and IDS_Breakdowns.Registry[id] or nil
            if def ~= nil then
                table.insert(spec.activeBreakdowns, {
                    id = id,
                    stage = math.clamp(tonumber(stage) or 1, 1, #def.stages),
                    progressHours = tonumber(progress) or 0,
                    discovered = discovered == "1"
                })
            end
        end
    end
    IDS_Breakdowns.recalculateEffects(vehicle)
end
