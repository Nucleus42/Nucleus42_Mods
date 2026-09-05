-- PrecisionFarmingPlus
-- Improvement addon for FS25_precisionFarming. Patches the live PF module at map load;
-- no PF files are modified. All balance numbers live in PFPlus.CONFIG below.

PFPlus = {}
PFPlus.MOD_NAME = g_currentModName

PFPlus.CONFIG = {
	-- Herbicide score weights (PF stock: spotSpray 1.0, fullSpray 0.6, mechanical 0.75).
	-- Rebalanced 2026-09-04: chemical-free mechanical control now outranks spot spraying.
	-- Set to nil to keep PF stock behaviour.
	herbicideWeights = {
		spotSpray = 0.8,
		fullSpray = 0.55,
		mechanical = 1.0,
	},

	-- Environmental score category weights. PF stock: N 30, herbicide 30, lime 15,
	-- soil sampling 15, tillage 10 (= 100). Rebalanced so ROTATION fits and the
	-- total stays 100 (the sell price factor divides by 100).
	maxScores = {
		NITROGEN = 25,
		HERBICIDE = 25,
		LIME = 15,
		SOIL_SAMPLING = 10,
		TILLAGE = 10,
		ROTATION = 15,
	},

	-- Sell price scaling by total score. Piecewise linear:
	-- score 0 -> minFactor, score 50 -> 1.0, score 100 -> maxFactor.
	sellPrice = {
		minFactor = 0.5,
		maxFactor = 1.2,
	},

	-- Organic sources that should fill nitrogen up to the crop target level in auto
	-- mode instead of applying PF's fixed per-soil rate.
	organicAutoAdjustFillTypes = { "LIQUIDMANURE", "DIGESTATE", "MANURE" },

	-- Variable-rate slurry/digestate needs to know the tank's N content: require a
	-- fitted manure sensor (on the sprayer or its source tanker) for auto-to-target;
	-- without one these fall back to PF's fixed per-soil rate. Solid manure has no
	-- sensor option in PF, so it stays ungated.
	requireManureSensor = true,
	sensorGatedFillTypes = { "LIQUIDMANURE", "DIGESTATE" },

	-- Soil samples go stale: full value for freshYears, then the soil sampling score
	-- decays by decayPerYear until resampled (real practice is every ~4 years).
	soilSampleAging = {
		freshYears = 3,
		decayPerYear = 0.25,
	},

	-- Yearly environmental subsidy, paid at the start of EARLY_SPRING per hectare of
	-- owned field area, scaled by how far the farm's score is above 50 (never negative).
	ecoPayment = {
		ratePerHa = 40,
	},

	-- Extra crops accepted for PF's cover-crop subsidy (standing uncut in late winter).
	-- Only added if the map actually has the fruit type. bonusPerHa by economic difficulty.
	coverCropSubsidyAdditions = {
		{ name = "clover", bonusPerHa = { 200, 150, 100 } },
		{ name = "alfalfa", bonusPerHa = { 200, 150, 100 } },
	},

	-- Crop rotation scoring
	rotation = {
		historyLength = 3, -- harvests remembered per farmland
		minShare = 0.25, -- sown area must cover this share of the field to count as "the crop"
		monocultureScore = 0.15, -- every remembered harvest the same crop
		legumeBonus = 0.1, -- any legume (crop with N target 0) in the history
		coverCropBonus = 0.1, -- a catch crop (PF subsidies list) sown in a remembered cycle
		strawChopBonus = 0.05, -- straw was chopped (not baled) in a remembered cycle
	},
}

local function getPFEnvironment()
	local pfEnv = _G.FS25_precisionFarming
	if pfEnv == nil or pfEnv.g_precisionFarming == nil then
		return nil, nil
	end
	return pfEnv, pfEnv.g_precisionFarming
end

---------------------------------------------------------------------------------------
-- EnvironmentalScoreRotation - new score category, subclass of PF's EnvironmentalScoreValue
---------------------------------------------------------------------------------------

local function createRotationClass(pfEnv)
	local EnvironmentalScoreRotation = {}
	local mt = Class(EnvironmentalScoreRotation, pfEnv.EnvironmentalScoreValue)

	function EnvironmentalScoreRotation.new(pfModule)
		local self = pfEnv.EnvironmentalScoreValue.new(pfModule, mt)
		self.xmlKey = "pfPlusRotation"
		self.legumeFruitIndices = nil
		return self
	end

	function EnvironmentalScoreRotation:initFarmlandData()
		return { history = {}, coverHistory = {}, strawHistory = {}, pending = {}, pendingCoverCrop = false, pendingStrawChop = false }
	end

	-- True catch crops derived from PF's own data: on the subsidies cover-crop list AND
	-- zero yieldPotential on every soil (OILSEEDRADISH on stock). They never enter the
	-- rotation history: they are not a cash crop and their zero N target would otherwise
	-- read as a legume. Sowing one earns a separate bonus. Harvestable subsidy crops
	-- (clover/alfalfa leys) keep their yieldPotential and stay normal rotation crops.
	function EnvironmentalScoreRotation:getIsCoverCrop(fruitTypeIndex)
		if self.coverCropFruitIndices == nil then
			self.coverCropFruitIndices = {}
			local subsidies = self.pfModule.subsidies
			local nitrogenMap = self.pfModule.nitrogenMap
			if subsidies ~= nil and subsidies.coverCropBonusFruitTypes ~= nil then
				for i = 1, #subsidies.coverCropBonusFruitTypes do
					local fruitType = subsidies.coverCropBonusFruitTypes[i]
					if nitrogenMap ~= nil and nitrogenMap.fruitRequirements ~= nil then
						for j = 1, #nitrogenMap.fruitRequirements do
							local requirement = nitrogenMap.fruitRequirements[j]
							if requirement.fruitType.index == fruitType.index then
								local hasYield = false
								for k = 1, #requirement.bySoilType do
									if (requirement.bySoilType[k].yieldPotential or 0) > 0 then
										hasYield = true
										break
									end
								end
								if not hasYield then
									self.coverCropFruitIndices[fruitType.index] = true
								end
								break
							end
						end
					end
				end
			end
		end
		return self.coverCropFruitIndices[fruitTypeIndex] == true
	end

	-- "Wheat < Barley < Maize" (newest first) for the field info box; nil when unknown
	function EnvironmentalScoreRotation:getHistoryText(farmlandId)
		local farmlandData = self:getFarmlandData(farmlandId)
		if farmlandData == nil or #farmlandData.history == 0 then
			return nil
		end
		local names = {}
		for i = 1, #farmlandData.history do
			local fruitType = g_fruitTypeManager:getFruitTypeByIndex(farmlandData.history[i])
			if fruitType ~= nil then
				local fillType = g_fruitTypeManager:getFillTypeByFruitTypeIndex(farmlandData.history[i])
				table.insert(names, fillType ~= nil and fillType.title or fruitType.name)
			end
		end
		if #names == 0 then
			return nil
		end
		return table.concat(names, " < ")
	end

	-- Legumes derived from PF's own data: every soil target level is 0 (soybean, pea, ...)
	function EnvironmentalScoreRotation:getIsLegume(fruitTypeIndex)
		if self.legumeFruitIndices == nil then
			self.legumeFruitIndices = {}
			local nitrogenMap = self.pfModule.nitrogenMap
			if nitrogenMap ~= nil and nitrogenMap.fruitRequirements ~= nil then
				for i = 1, #nitrogenMap.fruitRequirements do
					local requirement = nitrogenMap.fruitRequirements[i]
					local maxTarget = 0
					for j = 1, #requirement.bySoilType do
						maxTarget = math.max(maxTarget, requirement.bySoilType[j].targetLevel or 0)
					end
					if maxTarget == 0 then
						self.legumeFruitIndices[requirement.fruitType.index] = true
					end
				end
			end
		end
		return self.legumeFruitIndices[fruitTypeIndex] == true
	end

	function EnvironmentalScoreRotation:addSownArea(farmlandId, area, fruitTypeIndex)
		if fruitTypeIndex == nil or fruitTypeIndex == FruitType.UNKNOWN then
			return
		end
		local farmlandData = self:getFarmlandData(farmlandId)
		if self:getIsCoverCrop(fruitTypeIndex) then
			farmlandData.pendingCoverCrop = true
			return
		end
		local sqm = MathUtil.areaToHa(area, g_currentMission:getFruitPixelsToSqm()) * 10000
		farmlandData.pending[fruitTypeIndex] = (farmlandData.pending[fruitTypeIndex] or 0) + sqm
	end

	-- Called by PF once per cropping cycle after a farmland was harvested
	function EnvironmentalScoreRotation:onHarvestScoreReset(farmlandId)
		local farmlandData = self:getFarmlandData(farmlandId)
		local bestFruit, bestArea = nil, 0
		for fruitTypeIndex, area in pairs(farmlandData.pending) do
			if bestArea < area then
				bestFruit, bestArea = fruitTypeIndex, area
			end
		end
		if bestFruit ~= nil then
			local farmland = g_farmlandManager:getFarmlandById(farmlandId)
			local fieldSqm = farmland ~= nil and farmland.totalFieldArea ~= nil and farmland.totalFieldArea * 10000 or 0
			if fieldSqm == 0 or bestArea >= fieldSqm * PFPlus.CONFIG.rotation.minShare then
				table.insert(farmlandData.history, 1, bestFruit)
				table.insert(farmlandData.coverHistory, 1, farmlandData.pendingCoverCrop)
				table.insert(farmlandData.strawHistory, 1, farmlandData.pendingStrawChop)
				while #farmlandData.history > PFPlus.CONFIG.rotation.historyLength do
					table.remove(farmlandData.history)
					table.remove(farmlandData.coverHistory)
					table.remove(farmlandData.strawHistory)
				end
				farmlandData.pending = {}
				farmlandData.pendingCoverCrop = false
				farmlandData.pendingStrawChop = false
			end
		end
	end

	function EnvironmentalScoreRotation:getScore(farmlandId)
		local farmlandData = self:getFarmlandData(farmlandId)
		if farmlandData.clientScore ~= nil then
			return farmlandData.clientScore
		end
		local history = farmlandData.history
		if #history < 2 then
			return 0.5
		end
		local seen, distinct = {}, 0
		local hasLegume = false
		for i = 1, #history do
			if not seen[history[i]] then
				seen[history[i]] = true
				distinct = distinct + 1
			end
			if self:getIsLegume(history[i]) then
				hasLegume = true
			end
		end
		local score
		if distinct == 1 then
			score = PFPlus.CONFIG.rotation.monocultureScore
		else
			score = PFPlus.CONFIG.rotation.monocultureScore + (1 - PFPlus.CONFIG.rotation.monocultureScore) * (distinct - 1) / (#history - 1)
		end
		if hasLegume then
			score = score + PFPlus.CONFIG.rotation.legumeBonus
		end
		for i = 1, #farmlandData.coverHistory do
			if farmlandData.coverHistory[i] then
				score = score + PFPlus.CONFIG.rotation.coverCropBonus
				break
			end
		end
		for i = 1, #farmlandData.strawHistory do
			if farmlandData.strawHistory[i] then
				score = score + PFPlus.CONFIG.rotation.strawChopBonus
				break
			end
		end
		return math.clamp(score, 0, 1)
	end

	function EnvironmentalScoreRotation:loadFarmlandData(data, xmlFile, key)
		data.history = {}
		local historyStr = xmlFile:getString(key .. "#history")
		if historyStr ~= nil then
			for name in historyStr:gmatch("[^%s]+") do
				local fruitType = g_fruitTypeManager:getFruitTypeByName(name)
				if fruitType ~= nil then
					table.insert(data.history, fruitType.index)
				end
			end
		end
		data.coverHistory = {}
		local coverStr = xmlFile:getString(key .. "#coverCrops")
		if coverStr ~= nil then
			for flag in coverStr:gmatch("[^%s]+") do
				table.insert(data.coverHistory, flag == "1")
			end
		end
		while #data.coverHistory < #data.history do
			table.insert(data.coverHistory, false)
		end
		data.pendingCoverCrop = xmlFile:getBool(key .. "#pendingCoverCrop", false)
		data.strawHistory = {}
		local strawStr = xmlFile:getString(key .. "#strawChop")
		if strawStr ~= nil then
			for flag in strawStr:gmatch("[^%s]+") do
				table.insert(data.strawHistory, flag == "1")
			end
		end
		while #data.strawHistory < #data.history do
			table.insert(data.strawHistory, false)
		end
		data.pendingStrawChop = xmlFile:getBool(key .. "#pendingStrawChop", false)
		data.pending = {}
		local pendingStr = xmlFile:getString(key .. "#pending")
		if pendingStr ~= nil then
			for name, area in pendingStr:gmatch("([^%s:]+):([%d%.]+)") do
				local fruitType = g_fruitTypeManager:getFruitTypeByName(name)
				if fruitType ~= nil then
					data.pending[fruitType.index] = tonumber(area)
				end
			end
		end
	end

	function EnvironmentalScoreRotation:saveFarmlandData(data, xmlFile, key)
		local names = {}
		for i = 1, #data.history do
			local fruitType = g_fruitTypeManager:getFruitTypeByIndex(data.history[i])
			if fruitType ~= nil then
				table.insert(names, fruitType.name)
			end
		end
		xmlFile:setString(key .. "#history", table.concat(names, " "))
		local coverParts = {}
		for i = 1, #data.coverHistory do
			table.insert(coverParts, data.coverHistory[i] and "1" or "0")
		end
		xmlFile:setString(key .. "#coverCrops", table.concat(coverParts, " "))
		xmlFile:setBool(key .. "#pendingCoverCrop", data.pendingCoverCrop == true)
		local strawParts = {}
		for i = 1, #data.strawHistory do
			table.insert(strawParts, data.strawHistory[i] and "1" or "0")
		end
		xmlFile:setString(key .. "#strawChop", table.concat(strawParts, " "))
		xmlFile:setBool(key .. "#pendingStrawChop", data.pendingStrawChop == true)
		local pendingParts = {}
		for fruitTypeIndex, area in pairs(data.pending) do
			local fruitType = g_fruitTypeManager:getFruitTypeByIndex(fruitTypeIndex)
			if fruitType ~= nil then
				table.insert(pendingParts, string.format("%s:%.1f", fruitType.name, area))
			end
		end
		xmlFile:setString(key .. "#pending", table.concat(pendingParts, " "))
	end

	function EnvironmentalScoreRotation:readFarmlandDataFromStream(data, streamId, connection)
		data.clientScore = MathUtil.round(streamReadUIntN(streamId, 8) / 255, 2)
	end

	function EnvironmentalScoreRotation:writeFarmlandDataToStream(data, streamId, connection)
		streamWriteUIntN(streamId, self:getScore(data.farmlandId) * 255, 8)
	end

	function EnvironmentalScoreRotation:overwriteGameFunctions(pfModule)
		if g_server ~= nil then
			local onSowingArea = function(superFunc, vehicle, ...)
				local realArea, area = superFunc(vehicle, ...)
				if 0 < realArea then
					local x, _, z = getWorldTranslation(vehicle.rootNode)
					local farmlandId = g_farmlandManager:getFarmlandIdAtWorldPosition(x, z)
					if farmlandId ~= nil then
						self:addSownArea(farmlandId, realArea, vehicle.spec_sowingMachine.workAreaParameters.seedsFruitType)
					end
				end
				return realArea, area
			end
			pfModule:overwriteGameFunction(SowingMachine, "processSowingMachineArea", onSowingArea)
			pfModule:overwriteGameFunction(FertilizingSowingMachine, "processSowingMachineArea", onSowingArea)

			-- returns 1,1 only when chopped material actually drops (swath off, straw present)
			pfModule:overwriteGameFunction(Combine, "processCombineChopperArea", function(superFunc, vehicle, workArea)
				local realArea, area = superFunc(vehicle, workArea)
				if realArea ~= nil and 0 < realArea then
					local x, _, z = getWorldTranslation(vehicle.rootNode)
					local farmlandId = g_farmlandManager:getFarmlandIdAtWorldPosition(x, z)
					if farmlandId ~= nil then
						self:getFarmlandData(farmlandId).pendingStrawChop = true
					end
				end
				return realArea, area
			end)
		end
	end

	return EnvironmentalScoreRotation
end

---------------------------------------------------------------------------------------
-- Patches
---------------------------------------------------------------------------------------

-- 1. Grass rolling + mulching count as mechanical weed control
local function hookMechanicalWeedControl(pfEnv, pf)
	if g_server == nil then
		return
	end
	local herbicideScore = pf.environmentalScore.scoreObjects.EnvironmentalScoreHerbicide
	local TYPE_MECHANICAL = pfEnv.EnvironmentalScoreHerbicide.TYPE_MECHANICAL

	-- updateGrassRollerArea only runs for grass rollers on grass, so this is
	-- exactly "rolling grass"; rolling sown fields goes through updateRollerArea instead
	pf:overwriteGameFunction(FSDensityMapUtil, "updateGrassRollerArea", function(superFunc, xs, zs, xw, zw, xh, zh, ...)
		local realArea, totalArea = superFunc(xs, zs, xw, zw, xh, zh, ...)
		if realArea ~= nil and 0 < realArea then
			local farmlandId = g_farmlandManager:getFarmlandIdAtWorldPosition((xw + xh) * 0.5, (zw + zh) * 0.5)
			if farmlandId ~= nil then
				herbicideScore:addWorkedArea(farmlandId, realArea, TYPE_MECHANICAL)
			end
		end
		return realArea, totalArea
	end)

	pf:overwriteGameFunction(Mulcher, "processMulcherArea", function(superFunc, vehicle, ...)
		local realArea, area = superFunc(vehicle, ...)
		if realArea ~= nil and 0 < realArea then
			local x, _, z = getWorldTranslation(vehicle.rootNode)
			local farmlandId = g_farmlandManager:getFarmlandIdAtWorldPosition(x, z)
			if farmlandId ~= nil then
				herbicideScore:addWorkedArea(farmlandId, realArea, TYPE_MECHANICAL)
			end
		end
		return realArea, area
	end)
end

-- 2. Herbicide score weights from config (replaces hardcoded 1.0 / 0.6 / 0.75)
local function patchHerbicideWeights(pfEnv)
	local weights = PFPlus.CONFIG.herbicideWeights
	if weights == nil then
		return
	end
	local HerbicideClass = pfEnv.EnvironmentalScoreHerbicide
	HerbicideClass.getScore = function(self, farmlandId)
		local farmlandData = self:getFarmlandData(farmlandId)
		if farmlandData.clientScore ~= nil then
			return farmlandData.clientScore
		end
		local areaByType = farmlandData.areaByType
		local sum = areaByType[HerbicideClass.TYPE_SPOT_SPRAY] + areaByType[HerbicideClass.TYPE_FULL_SPRAY] + areaByType[HerbicideClass.TYPE_MECHANICAL]
		if sum == 0 then
			return 0.5
		end
		local score = areaByType[HerbicideClass.TYPE_SPOT_SPRAY] / sum * weights.spotSpray
			+ areaByType[HerbicideClass.TYPE_FULL_SPRAY] / sum * weights.fullSpray
			+ areaByType[HerbicideClass.TYPE_MECHANICAL] / sum * weights.mechanical
		return math.clamp(score, 0, 1)
	end
end

-- 3. Inject the crop rotation score category and rebalance category weights
local function injectRotationScore(pfEnv, pf)
	local envScore = pf.environmentalScore
	local rotationObject = PFPlus.rotationObject
	for i = 1, #envScore.scoreValues do
		if envScore.scoreValues[i].id == "ROTATION" then
			return
		end
	end

	local maxScore = PFPlus.CONFIG.maxScores.ROTATION or 15
	table.insert(envScore.scoreValues, {
		id = "ROTATION",
		name = g_i18n:getText("pfPlus_environmentalScore_rotation"),
		maxScore = maxScore,
		curScore = maxScore * 0.5,
		object = rotationObject,
	})

	for i = 1, #envScore.scoreValues do
		local scoreValue = envScore.scoreValues[i]
		local newMax = PFPlus.CONFIG.maxScores[scoreValue.id]
		if newMax ~= nil and newMax ~= scoreValue.maxScore then
			scoreValue.curScore = scoreValue.curScore / scoreValue.maxScore * newMax
			scoreValue.maxScore = newMax
		end
	end
end

-- 4. Sell price 50% .. 100% .. 120% by total score (PF stock: 85% .. 115%)
local function patchSellPriceFactor(pfEnv)
	local sellPrice = PFPlus.CONFIG.sellPrice
	pfEnv.EnvironmentalScore.getSellPriceFactor = function(self, farmId)
		local percentage = self:getTotalScore(farmId) / 100
		local factor
		if percentage <= 0.5 then
			factor = (percentage - 0.5) / 0.5 * (1 - sellPrice.minFactor)
		else
			factor = (percentage - 0.5) / 0.5 * (sellPrice.maxFactor - 1)
		end
		if math.abs(factor) < 0.01 then
			return 0
		end
		return factor
	end
end

-- Manure sensor gating: variable-rate slurry/digestate only with a fitted sensor.
-- Wraps ExtendedSprayer.processSprayerArea (the scope where sub-section targets and
-- nTargetValue are computed) and temporarily reverts the gated fill types to PF's
-- fixed rates when no sensor is present on the rig.
local function hookManureSensorGate(pfEnv, pf)
	if not PFPlus.CONFIG.requireManureSensor then
		return
	end
	local sensorSpecName = pfEnv.ManureSensor.SPEC_TABLE_NAME
	local gatedFillTypes = nil

	local function hasSensor(vehicle)
		local function check(v)
			local spec = v ~= nil and v[sensorSpecName]
			return spec ~= nil and spec.sensorAvailable == true
		end
		if check(vehicle) then
			return true
		end
		return check(pfEnv.ExtendedSprayer.getFillTypeSourceVehicle(vehicle))
	end

	pf:overwriteGameFunction(pfEnv.ExtendedSprayer, "processSprayerArea", function(superFunc, vehicle, superFunc2, workArea, dt)
		if gatedFillTypes == nil then
			gatedFillTypes = {}
			for _, name in ipairs(PFPlus.CONFIG.sensorGatedFillTypes) do
				local index = g_fillTypeManager:getFillTypeIndexByName(name)
				if index ~= nil then
					gatedFillTypes[index] = true
				end
			end
		end
		local nitrogenMap = pf.nitrogenMap
		local fillType = vehicle.spec_sprayer.workAreaParameters.sprayFillType
		local flipped = nil
		if nitrogenMap ~= nil and gatedFillTypes[fillType] and not hasSensor(vehicle) then
			flipped = {}
			for i = 1, #nitrogenMap.applicationRates do
				local rate = nitrogenMap.applicationRates[i]
				if gatedFillTypes[rate.fillTypeIndex] and rate.autoAdjustToFruit then
					rate.autoAdjustToFruit = false
					table.insert(flipped, rate)
				end
			end
			-- sub-section targets are cached per sprayType; force a recompute under the gate
			workArea.lastSprayTypeIndex = nil
		end
		local changedArea, totalArea = superFunc(vehicle, superFunc2, workArea, dt)
		if flipped ~= nil then
			for i = 1, #flipped do
				flipped[i].autoAdjustToFruit = true
			end
			workArea.lastSprayTypeIndex = nil
		end
		return changedArea, totalArea
	end)
end

-- Soil samples age: full value for freshYears after the last sampling on that
-- farmland, then the sampling score decays by decayPerYear until resampled.
local function patchSoilSampleAging(pfEnv, pf)
	local aging = PFPlus.CONFIG.soilSampleAging
	if aging == nil then
		return
	end
	local SampleClass = pfEnv.EnvironmentalScoreSoilSample

	SampleClass.getScore = Utils.overwrittenFunction(SampleClass.getScore, function(self, superFunc, farmlandId)
		local score = superFunc(self, farmlandId)
		local farmlandData = self:getFarmlandData(farmlandId)
		if farmlandData == nil or farmlandData.clientScore ~= nil or farmlandData.samplePercentage < 0 then
			return score
		end
		local currentYear = g_currentMission.environment.currentYear
		if farmlandData.pfPlusLastSampleYear == nil then
			-- pre-addon savegames: treat existing samples as fresh from first sight
			farmlandData.pfPlusLastSampleYear = currentYear
		end
		local age = currentYear - farmlandData.pfPlusLastSampleYear
		if age <= aging.freshYears then
			return score
		end
		local freshness = math.max(1 - (age - aging.freshYears) * aging.decayPerYear, 0)
		return score * freshness
	end)

	SampleClass.loadFarmlandData = Utils.appendedFunction(SampleClass.loadFarmlandData, function(self, data, xmlFile, key)
		data.pfPlusLastSampleYear = xmlFile:getInt(key .. "#pfPlusLastSampleYear")
	end)
	SampleClass.saveFarmlandData = Utils.appendedFunction(SampleClass.saveFarmlandData, function(self, data, xmlFile, key)
		if data.pfPlusLastSampleYear ~= nil then
			xmlFile:setInt(key .. "#pfPlusLastSampleYear", data.pfPlusLastSampleYear)
		end
	end)

end

-- Separate from the class wraps above: this goes through pf:overwriteGameFunction,
-- which PF restores on deleteMap, so it must reinstall every career.
local function hookSoilSampleYearRecording(pf)
	if PFPlus.CONFIG.soilSampleAging == nil then
		return
	end
	if g_server ~= nil then
		pf:overwriteGameFunction(SoilSampler, "processSoilSampling", function(superFunc, vehicle, ...)
			superFunc(vehicle, ...)
			local spec = vehicle[SoilSampler.SPEC_TABLE_NAME]
			if spec ~= nil and spec.samplingNode ~= nil then
				local x, _, z = getWorldTranslation(spec.samplingNode)
				local farmlandId = g_farmlandManager:getFarmlandIdAtWorldPosition(x, z)
				if farmlandId ~= nil then
					local sampleObject = pf.environmentalScore.scoreObjects.EnvironmentalScoreSoilSample
					sampleObject:getFarmlandData(farmlandId).pfPlusLastSampleYear = g_currentMission.environment.currentYear
				end
			end
		end)
	end
end

-- The env score window's GUI XML hardcodes exactly five distribution rows
-- (MapFrameExtensionEnvironmentalScore.xml) and updateUI skips score values with
-- no matching element - so the ROTATION row never rendered. Clone a sixth row at
-- setMapFrame time and respace six rows into the five-row area (27px -> 22.5px
-- steps), leaving the window expansion math and separators untouched.
local function patchEnvScoreWindowSixthRow(pfEnv)
	local EnvScoreClass = pfEnv.EnvironmentalScore
	EnvScoreClass.setMapFrame = Utils.appendedFunction(EnvScoreClass.setMapFrame, function(self, mapFrame)
		local texts = mapFrame.envScoreDistributionText
		if texts == nil or texts[1] == nil or texts[6] ~= nil then
			return
		end
		local _, step = getNormalizedScreenValues(0, 22.5)
		local groups = {
			mapFrame.envScoreDistributionText,
			mapFrame.envScoreDistributionBarBackground,
			mapFrame.envScoreDistributionBar,
			mapFrame.envScoreDistributionValue,
		}
		for _, group in ipairs(groups) do
			if group ~= nil and group[1] ~= nil then
				group[6] = group[1]:clone(group[1].parent)
				for i = 2, 6 do
					if group[i] ~= nil then
						group[i]:setPosition(nil, group[1].position[2] - (i - 1) * step)
					end
				end
			end
		end
	end)
end

-- Yearly eco subsidy: paid per owned field hectare at the start of EARLY_SPRING,
-- scaled by how far the farm's environmental score sits above 50. Never negative.
function PFPlus:onPeriodChanged(currentPeriod)
	if g_server == nil or currentPeriod ~= SeasonPeriod.EARLY_SPRING then
		return
	end
	local _, pf = getPFEnvironment()
	if pf == nil or pf.environmentalScore == nil then
		return
	end
	for _, farm in ipairs(g_farmManager:getFarms()) do
		local farmId = farm.farmId
		if farmId ~= FarmManager.SPECTATOR_FARM_ID then
			local hectares = 0
			for farmlandId, ownerFarmId in pairs(g_farmlandManager.farmlandMapping) do
				if ownerFarmId == farmId then
					local farmland = g_farmlandManager:getFarmlandById(farmlandId)
					if farmland ~= nil and farmland.totalFieldArea ~= nil then
						hectares = hectares + farmland.totalFieldArea
					end
				end
			end
			if 0 < hectares then
				local score = pf.environmentalScore:getTotalScore(farmId)
				local payout = PFPlus.CONFIG.ecoPayment.ratePerHa * hectares * math.max((score - 50) / 50, 0)
				if 1 <= payout then
					g_currentMission:addMoney(payout, farmId, PFPlus.moneyTypeEco, true, true)
				end
			end
		end
	end
end

-- Extra cover-crop subsidy fruits (only if the map has them); PF pays for standing
-- uncut foliage every LATE_WINTER via its FieldGetInfoTask scan.
local function extendCoverCropSubsidies(pf)
	local subsidies = pf.subsidies
	if subsidies == nil or subsidies.coverCropBonusByName == nil then
		return
	end
	for _, entry in ipairs(PFPlus.CONFIG.coverCropSubsidyAdditions) do
		local fruitType = g_fruitTypeManager:getFruitTypeByName(entry.name)
		if fruitType ~= nil and subsidies.coverCropBonusByName[fruitType.name] == nil then
			table.insert(subsidies.coverCropBonusFruitTypes, fruitType)
			subsidies.coverCropBonusByName[fruitType.name] = { fruitType = fruitType.index, bonusPerHa = entry.bonusPerHa }
		end
	end
end

-- Rotation history line in the field info box (on foot and on map hover).
-- Server/SP only: clients receive just the streamed score, not the history.
local function addRotationFieldInfo(pf)
	if PFPlus.fieldInfoAdded or pf.fieldInfoDisplayExtension == nil then
		return
	end
	PFPlus.fieldInfoAdded = true
	pf.fieldInfoDisplayExtension:addFieldInfo(g_i18n:getText("pfPlus_fieldInfo_rotation"), nil, function(object, fieldInfo, worldX, worldZ, isColorBlindMode)
		if PFPlus.rotationObject == nil then
			return nil
		end
		local farmlandId = g_farmlandManager:getFarmlandIdAtWorldPosition(worldX, worldZ)
		if farmlandId == nil then
			return nil
		end
		return PFPlus.rotationObject:getHistoryText(farmlandId)
	end)
end

-- 5. Organic fertilizers fill nitrogen to the crop target in auto mode
local function patchOrganicApplicationRates(pf)
	local nitrogenMap = pf.nitrogenMap
	if nitrogenMap == nil or nitrogenMap.applicationRates == nil then
		Logging.warning("[PFPlus] nitrogenMap application rates not found, organic auto-adjust skipped")
		return
	end
	for _, fillTypeName in ipairs(PFPlus.CONFIG.organicAutoAdjustFillTypes) do
		local fillTypeIndex = g_fillTypeManager:getFillTypeIndexByName(fillTypeName)
		if fillTypeIndex ~= nil then
			for i = 1, #nitrogenMap.applicationRates do
				if nitrogenMap.applicationRates[i].fillTypeIndex == fillTypeIndex then
					nitrogenMap.applicationRates[i].autoAdjustToFruit = true
				end
			end
		end
	end
end

---------------------------------------------------------------------------------------
-- Bootstrap
--
-- Two-stage install, mirroring PF's own timing:
-- 1. TypeManager.validateTypes (before vehicle types capture spec functions):
--    class-level hooks on Mulcher/SowingMachine and class method replacements.
-- 2. loadMap (after PF has parsed PrecisionFarming.xml):
--    insert the rotation score value and flip the organic application rates.
---------------------------------------------------------------------------------------

PFPlus.rotationObject = nil
PFPlus.earlyPatchesApplied = false

local function applyEarlyPatches()
	local pfEnv, pf = getPFEnvironment()
	if pf == nil then
		Logging.warning("[PFPlus] FS25_precisionFarming not loaded, addon disabled")
		return
	end
	PFPlus.earlyPatchesApplied = true
	hookMechanicalWeedControl(pfEnv, pf)
	patchHerbicideWeights(pfEnv)
	patchSellPriceFactor(pfEnv)
	hookManureSensorGate(pfEnv, pf)
	hookSoilSampleYearRecording(pf)
	if not PFPlus.classPatchesApplied then
		-- class-method wraps must not stack across careers
		PFPlus.classPatchesApplied = true
		patchSoilSampleAging(pfEnv, pf)
		patchEnvScoreWindowSixthRow(pfEnv)
	end
	local RotationClass = createRotationClass(pfEnv)
	PFPlus.rotationObject = RotationClass.new(pf)
	PFPlus.rotationObject:loadFromXML(nil, nil, nil, nil, nil) -- initializes farmlandDatas
	PFPlus.rotationObject:overwriteGameFunctions(pf)
	pf.environmentalScore.scoreObjects.EnvironmentalScoreRotation = PFPlus.rotationObject
end

TypeManager.validateTypes = Utils.prependedFunction(TypeManager.validateTypes, function(typeManager)
	if typeManager.typeName == "vehicle" and g_iconGenerator == nil and not PFPlus.earlyPatchesApplied then
		applyEarlyPatches()
	end
end)

function PFPlus:loadMap(filename)
	local pfEnv, pf = getPFEnvironment()
	if pf == nil or not PFPlus.earlyPatchesApplied then
		return
	end
	if pf.environmentalScore == nil or #pf.environmentalScore.scoreValues == 0 then
		Logging.warning("[PFPlus] Precision Farming environmental score not initialized, rotation score skipped")
		return
	end
	injectRotationScore(pfEnv, pf)
	patchOrganicApplicationRates(pf)
	extendCoverCropSubsidies(pf)
	addRotationFieldInfo(pf)
	g_messageCenter:subscribe(MessageType.PERIOD_CHANGED, self.onPeriodChanged, self)
	Logging.info("[PFPlus] Precision Farming Plus active (rolling/mulching credit, rotation score, organic auto-rate, sell price curve, sample aging, eco payment)")
end

-- PF restores every wrapped function and reinstalls its hooks on the next career's
-- validateTypes pass; mirror that so a menu-and-reload gets a clean install.
function PFPlus:deleteMap()
	local _, pf = getPFEnvironment()
	if pf ~= nil and pf.environmentalScore ~= nil then
		for i = #pf.environmentalScore.scoreValues, 1, -1 do
			if pf.environmentalScore.scoreValues[i].id == "ROTATION" then
				table.remove(pf.environmentalScore.scoreValues, i)
			end
		end
		pf.environmentalScore.scoreObjects.EnvironmentalScoreRotation = nil
	end
	PFPlus.rotationObject = nil
	PFPlus.earlyPatchesApplied = false
	g_messageCenter:unsubscribeAll(PFPlus)
end

PFPlus.moneyTypeEco = MoneyType.register("other", "pfPlus_ecoPayment", PFPlus.MOD_NAME)

addModEventListener(PFPlus)
