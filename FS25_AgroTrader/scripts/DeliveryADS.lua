-- AgroTrader — Advanced Damage System overlay for delivered machines.
--
-- The advert shows hours, damage and service history. What it does NOT show is what is actually
-- wrong with the machine — that is the gamble the mod exists to offer: a cheap no-history machine
-- can have next to nothing wrong (a genuine bargain) or a powershift pump on its way out (dearer
-- than the tidy FSH machine two adverts up, once fixed). Some fixes are a few hundred, some are
-- five figures; the service history tier is what caps the roll, which is why FSH commands its
-- price premium.
--
-- Ported from FS25_StartingFleetRandomizer's FleetADS.lua, which earned every scar. The three
-- rules it learned the hard way, kept in full here:
--
--  1. ⚠ ADS'S GLOBALS ARE UNREACHABLE. FS25 gives every mod its own script environment, so
--     `AdvancedDamageSystem`, `ADS_Main`, `ADS_Config` and every enum in them are nil HERE even
--     with ADS running. The only shared surface is the live vehicle object:
--     vehicle.spec_AdvancedDamageSystem and the spec functions copied onto the vehicle
--     (addBreakdown, getRandomBreakdownBySystem, updateConditionLevel). Touch nothing else.
--     Checking `AdvancedDamageSystem ~= nil` to detect ADS is the bug that shipped once already
--     (2026-08-09) — it is ALWAYS nil, and every machine silently kept ADS's own guess.
--
--  2. ⚠ WAIT FOR ADS TO SEED BEFORE OVERWRITING. ADS seeds a used vehicle on its first update
--     tick after registration (ADS_Specialization.lua:2871-2917), gated on hours > 0 and an
--     untouched conditionLevel. Our machines match that gate exactly, so ADS WILL seed them;
--     anything written earlier is overwritten or — worse — suppresses the seeding and leaves a
--     half-initialised vehicle. So this is a queue watched from update(), not a call at spawn.
--     A non-empty maintenanceLog is the "seeded" signal: registerVehicle writes the initial
--     inspection entry in the same call as the seed.
--
--  3. ⚠ CONDITION IS WRITTEN PER SYSTEM, SERVICE THROUGH THE LOG ANCHOR. Forcing every system to
--     one value throws away the interesting part (a sound engine with a shot transmission is a
--     different decision from uniform mediocrity). And spec.serviceLevel alone leaves the
--     workshop screen disagreeing with the HUD — the maintenance log's id==1 entry must be
--     re-anchored to the current hours so getHoursSinceLastMaintenance agrees.
--
-- Implements never carry the spec (ADS registers on motorized types only, ADS_Main.lua:96-105);
-- they are skipped silently, and their bottom-of-market consequence is the graded price floor in
-- Valuation instead.
--
-- Server-only: ADS state is authoritative on the server, and Purchase.onBought — the enqueue
-- point — carries the spawned vehicles there.

AgroTraderADS = {}

-- Give up waiting for ADS to register a machine after this long. Generous — registration follows
-- spawn within a tick or two, so hitting this means ADS is absent or declined the vehicle.
AgroTraderADS.TIMEOUT_MS = 30000

-- Per-system condition never leaves this band: no delivered machine is factory-fresh, and none is
-- delivered already dead on the lorry.
AgroTraderADS.CONDITION_MIN = 0.05
AgroTraderADS.CONDITION_MAX = 0.95

-- Per-system jitter around the advert's damage figure, so the systems spread rather than reading
-- as one number five times.
AgroTraderADS.CONDITION_JITTER = 0.08

AgroTraderADS.pending = {}

-- ------------------------------------------------------------------- the profile

--- What is wrong with this machine, rolled ONCE at purchase from the advert's own facts.
---
--- The tiers are the design: full history caps the gamble (at most one visible minor fault —
--- that is what the 15% premium buys), part history is an honest middle, no history is the open
--- bet — always something, possibly several, possibly advanced, and half of it hidden until an
--- inspection is paid for. The missing service record IS the hidden fault.
---
--- math.random is fine here, deliberately: adverts must be derived and reproducible, but the
--- machine's secret faults are rolled once at the moment of sale and then live on the vehicle.
--- There is nothing to re-derive and nothing a reroll exploit can reach — the purchase already
--- happened.
function AgroTraderADS.rollProfile(damage, care, historyTier)
	local profile = {
		condition = math.clamp(1 - (damage or 0.5),
			AgroTraderADS.CONDITION_MIN, AgroTraderADS.CONDITION_MAX),
		-- Service bar tracks how the machine was looked after, never quite 0 or 1.
		service = math.clamp((care or 0.5) * 0.9 + 0.05, 0.02, 0.95),
	}

	local count, hiddenChance, stageMax
	if historyTier == "full" then
		count = math.random() < 0.35 and 1 or 0
		hiddenChance = 0.10
		stageMax = 1
	elseif historyTier == "part" then
		count = math.random(0, 2)
		hiddenChance = 0.30
		stageMax = 2
	else
		-- No history: at least one fault, more when the advert already admits heavy damage —
		-- and stage 3 is on the table, which is where the five-figure bills live.
		count = math.random(1, 2)
		if (damage or 0) > 0.5 then
			count = count + math.random(0, 2)
		end
		hiddenChance = 0.50
		stageMax = 3
	end

	profile.breakdowns = { count = count, hidden = hiddenChance, stageMin = 1, stageMax = stageMax }
	return profile
end

-- ----------------------------------------------------------------- applying it

--- Spread the target condition across the machine's ADS systems, worst-first list returned so
--- faults can be aimed at whatever is weakest — the fault list and the condition read-out must
--- tell the same story.
local function applySystemConditions(vehicle, spec, profile)
	local worst = {}

	for key, systemData in pairs(spec.systems or {}) do
		if type(systemData) == "table" and systemData.enabled ~= false then
			local jitter = (math.random() * 2 - 1) * AgroTraderADS.CONDITION_JITTER
			local value = math.clamp(profile.condition + jitter,
				AgroTraderADS.CONDITION_MIN, AgroTraderADS.CONDITION_MAX)

			systemData.condition = value
			systemData.stress = 0
			systemData.persistentWearRateState = 0

			table.insert(worst, { key = key, name = systemData.name, condition = value })
		end
	end

	-- ADS weights systems unevenly; let its own sum produce the overall figure rather than
	-- reproducing the weights here, where they would rot.
	if vehicle.updateConditionLevel ~= nil then
		vehicle:updateConditionLevel()
	end

	table.sort(worst, function(a, b) return a.condition < b.condition end)
	return worst
end

--- Set the service level AND re-anchor the maintenance log's initial entry, so the workshop
--- screen and the service bar tell the same story. The anchor trick (from FleetADS, verified in
--- play): write the CURRENT hours and our service value into the id==1 entry, and ADS's own
--- getHoursSinceLastMaintenance arithmetic collapses to the correct answer without this file ever
--- naming BASE_SERVICE_WEAR, which lives in ADS's unreachable config.
local function applyServiceLevel(vehicle, spec, profile)
	local value = math.clamp(profile.service, 0, 1)
	spec.serviceLevel = value

	if type(spec.maintenanceLog) ~= "table" then
		return
	end

	for index = #spec.maintenanceLog, 1, -1 do
		local entry = spec.maintenanceLog[index]
		if entry ~= nil and entry.id == 1 and type(entry.conditionData) == "table" then
			entry.conditionData.service = value
			entry.conditionData.operatingHours = (spec.realOperatingTime or 0) / (60 * 60 * 1000)
			entry.conditionData.condition = spec.conditionLevel or entry.conditionData.condition
			return
		end
	end
end

--- Seed the faults the seller did not mention.
local function applyBreakdowns(vehicle, spec, profile, worstSystems)
	local wanted = profile.breakdowns or {}
	local count = wanted.count or 0

	if count <= 0 or vehicle.addBreakdown == nil then
		return 0, 0
	end

	local added, hidden = 0, 0

	for index = 1, count do
		local id = nil

		-- Aim at the weakest systems first; fall back to a free draw when a system has no
		-- applicable breakdown left.
		local target = worstSystems[((index - 1) % math.max(#worstSystems, 1)) + 1]
		if target ~= nil and vehicle.getRandomBreakdownBySystem ~= nil then
			id = vehicle:getRandomBreakdownBySystem(target.name)
		end
		if id == nil and vehicle.getRandomBreakdown ~= nil then
			id = vehicle:getRandomBreakdown()
		end

		if id == nil then
			break
		end

		local isHidden = math.random() < (wanted.hidden or 0)

		vehicle:addBreakdown(id, {
			stage = math.random(wanted.stageMin or 1, wanted.stageMax or 1),
			isVisible = not isHidden,
			isSelectedForRepair = true,
			isActive = true,
		})

		added = added + 1
		if isHidden then
			hidden = hidden + 1
		end
	end

	if vehicle.recalculateAndApplyIndicators ~= nil then
		vehicle:recalculateAndApplyIndicators()
	end

	return added, hidden
end

--- Overwrite ADS's own used-vehicle guess with what the advert actually promised.
function AgroTraderADS.apply(vehicle, profile, label)
	local spec = vehicle.spec_AdvancedDamageSystem
	if spec == nil then
		return false
	end

	if spec.isExcludedVehicle then
		-- Electric machines and a handful of named vehicles opt out of ADS entirely; writing to
		-- them would fill fields nothing reads.
		return false
	end

	local worstSystems = applySystemConditions(vehicle, spec, profile)
	applyServiceLevel(vehicle, spec, profile)
	local added, hidden = applyBreakdowns(vehicle, spec, profile, worstSystems)

	if vehicle.raiseDirtyFlags ~= nil and spec.adsDirtyFlag_wear ~= nil then
		vehicle:raiseDirtyFlags(spec.adsDirtyFlag_wear)
	end

	Logging.info("[AgroTrader] ADS on '%s': condition %.0f%%, service %.0f%%, %d fault(s), %d hidden",
		tostring(label), (spec.conditionLevel or 0) * 100, (spec.serviceLevel or 0) * 100,
		added, hidden)

	return true
end

-- -------------------------------------------------------------------- the queue

--- Has ADS finished registering and seeding this vehicle? Watched off the vehicle, because ADS's
--- own bookkeeping is in an unreachable environment. A non-empty maintenance log, or a
--- conditionLevel moved off its baseline, means the seeder has run and it is safe to overwrite.
function AgroTraderADS.getIsSeeded(vehicle)
	local spec = vehicle.spec_AdvancedDamageSystem
	if spec == nil then
		return false
	end

	if type(spec.maintenanceLog) == "table" and #spec.maintenanceLog > 0 then
		return true
	end

	return spec.conditionLevel ~= nil and spec.baseConditionLevel ~= nil
		and spec.conditionLevel ~= spec.baseConditionLevel
end

--- Queue one delivered machine. Called from Purchase.onBought with the advert's facts.
function AgroTraderADS.enqueue(vehicle, damage, care, historyTier, label)
	if vehicle == nil then
		return
	end

	if vehicle.spec_AdvancedDamageSystem == nil then
		-- The normal case for every implement, and for motorised machines when ADS is not
		-- installed — in both, the graded price floor is the consequence instead. Not a warning.
		return
	end

	table.insert(AgroTraderADS.pending, {
		vehicle = vehicle,
		profile = AgroTraderADS.rollProfile(damage, care, historyTier),
		label = label or tostring(vehicle.configFileName),
		waited = 0,
	})
end

--- Driven from AgroTrader:update every frame. Cheap when idle — one nil-check on an empty table.
function AgroTraderADS.update(dt)
	if #AgroTraderADS.pending == 0 then
		return
	end

	local stillWaiting = {}

	for _, entry in ipairs(AgroTraderADS.pending) do
		local vehicle = entry.vehicle

		if vehicle == nil or vehicle.isDeleted then
			-- Gone before we got to it; nothing to say.
		elseif AgroTraderADS.getIsSeeded(vehicle) then
			local ok, err = pcall(AgroTraderADS.apply, vehicle, entry.profile, entry.label)
			if not ok then
				Logging.warning("[AgroTrader] ADS overlay on '%s' failed: %s",
					tostring(entry.label), tostring(err))
			end
		else
			entry.waited = entry.waited + (dt or 0)
			if entry.waited >= AgroTraderADS.TIMEOUT_MS then
				-- Say so: a machine that keeps ADS's own seed is far healthier than the advert
				-- implied, and silent means it reads as a balance problem for a fortnight.
				Logging.warning("[AgroTrader] ADS never registered '%s' after %.0fs — it keeps "
					.. "ADS's own used-vehicle condition instead of the advert's.",
					tostring(entry.label), AgroTraderADS.TIMEOUT_MS / 1000)
			else
				table.insert(stillWaiting, entry)
			end
		end
	end

	AgroTraderADS.pending = stillWaiting
end
