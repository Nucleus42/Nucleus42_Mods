--
-- SubsoilerPlow
--
-- Makes a subsoiler behave as a plough: it paints PLOWED ground (which resets the
-- vanilla plow counter exactly as a plough does), can create fields, and satisfies
-- ploughing contracts.
--
-- Only activates on implements whose store item is in the "subsoilers" category.
-- On anything else every function here falls straight through to the base game.
--
-- Base game references:
--   Cultivator.lua:88    processCultivatorArea
--   Cultivator.lua:262   onStartWorkAreaProcessing (permission clamp + angle)
--   Plow.lua:250         processPlowArea
--   Plow.lua:558         onRegisterActionEvents
--   PlowPacker.lua:176   precedent for overwriting processCultivatorArea
--   FSDensityMapUtil.lua:988  updatePlowArea
--

SubsoilerPlow = {}

-- Mod specializations are keyed "spec_<modName>.<specName>", not "spec_<specName>".
-- Same pattern as the Precision Farming specs (e.g. ExtendedCombine.lua:2).
SubsoilerPlow.SPEC_TABLE_NAME = "spec_" .. g_currentModName .. ".subsoilerPlow"

SubsoilerPlow.STORE_CATEGORY = "subsoilers"

function SubsoilerPlow.prerequisitesPresent(specializations)
	return SpecializationUtil.hasSpecialization(Cultivator, specializations)
end

function SubsoilerPlow.registerFunctions(vehicleType)
	SpecializationUtil.registerFunction(vehicleType, "getIsSubsoilerPlow", SubsoilerPlow.getIsSubsoilerPlow)
	SpecializationUtil.registerFunction(vehicleType, "setSubsoilerLimitToField", SubsoilerPlow.setSubsoilerLimitToField)
	SpecializationUtil.registerFunction(vehicleType, "getSubsoilerForceLimitToField", SubsoilerPlow.getSubsoilerForceLimitToField)
end

function SubsoilerPlow.registerOverwrittenFunctions(vehicleType)
	SpecializationUtil.registerOverwrittenFunction(vehicleType, "processCultivatorArea", SubsoilerPlow.processCultivatorArea)
	SpecializationUtil.registerOverwrittenFunction(vehicleType, "getCultivatorLimitToField", SubsoilerPlow.getCultivatorLimitToField)
	SpecializationUtil.registerOverwrittenFunction(vehicleType, "updateCultivatorAIRequirements", SubsoilerPlow.updateCultivatorAIRequirements)
end

function SubsoilerPlow.registerEventListeners(vehicleType)
	SpecializationUtil.registerEventListener(vehicleType, "onLoad", SubsoilerPlow)
	SpecializationUtil.registerEventListener(vehicleType, "onPostLoad", SubsoilerPlow)
	SpecializationUtil.registerEventListener(vehicleType, "onReadStream", SubsoilerPlow)
	SpecializationUtil.registerEventListener(vehicleType, "onWriteStream", SubsoilerPlow)
	SpecializationUtil.registerEventListener(vehicleType, "onUpdate", SubsoilerPlow)
	SpecializationUtil.registerEventListener(vehicleType, "onRegisterActionEvents", SubsoilerPlow)
end

function SubsoilerPlow:onLoad(savegame)
	local spec = self[SubsoilerPlow.SPEC_TABLE_NAME]

	spec.isSubsoilerPlow = false
	spec.limitToField = true
	spec.actionEvents = {}

	spec.texts = {}
	spec.texts.allowCreateFields = g_i18n:getText("action_allowCreateFields")
	spec.texts.limitToFields = g_i18n:getText("action_limitToFields")
end

function SubsoilerPlow:onPostLoad(savegame)
	-- Store items are resolved by the time onPostLoad runs, so the category test lives here
	-- rather than in onLoad.
	local spec = self[SubsoilerPlow.SPEC_TABLE_NAME]
	spec.isSubsoilerPlow = SubsoilerPlow.getIsInSubsoilerCategory(self.configFileName)

	if spec.isSubsoilerPlow then
		self:updateCultivatorAIRequirements()
	end
end

--- Tests the store category of a config file. Compared case-insensitively because
--- StoreManager normalises category names against the registered category list
--- (StoreManager.lua:676), and the registered casing is not guaranteed to match the XML.
function SubsoilerPlow.getIsInSubsoilerCategory(configFileName)
	if configFileName == nil then
		return false
	end

	local storeItem = g_storeManager:getItemByXMLFilename(configFileName)
	if storeItem == nil then
		return false
	end

	local target = SubsoilerPlow.STORE_CATEGORY:lower()

	-- categoryNames is the validated list; a vehicle may sit in several categories,
	-- e.g. the Disc-O-Vigne is "subsoilers grapeTools".
	if storeItem.categoryNames ~= nil then
		for _, name in ipairs(storeItem.categoryNames) do
			if name:lower() == target then
				return true
			end
		end
	end

	if storeItem.categoryName ~= nil and storeItem.categoryName:lower() == target then
		return true
	end

	return false
end

function SubsoilerPlow:getIsSubsoilerPlow()
	return self[SubsoilerPlow.SPEC_TABLE_NAME].isSubsoilerPlow
end

--- Mirrors Plow:getPlowForceLimitToField (Plow.lua:366) — some platforms disable field creation
--- outright.
function SubsoilerPlow:getSubsoilerForceLimitToField()
	return not Platform.gameplay.canCreateFields
end

--- Cultivator:onStartWorkAreaProcessing reads this and applies the createFields permission
--- clamp itself (Cultivator.lua:263-268), so no permission logic is needed here.
function SubsoilerPlow:getCultivatorLimitToField(superFunc)
	local spec = self[SubsoilerPlow.SPEC_TABLE_NAME]
	if not spec.isSubsoilerPlow then
		return superFunc(self)
	end

	if self:getSubsoilerForceLimitToField() then
		return true
	end

	return spec.limitToField
end

function SubsoilerPlow:setSubsoilerLimitToField(limitToField, noEventSend)
	local spec = self[SubsoilerPlow.SPEC_TABLE_NAME]
	if spec.limitToField == limitToField then
		return
	end

	SubsoilerLimitToFieldEvent.sendEvent(self, limitToField, noEventSend)
	spec.limitToField = limitToField

	local actionEvent = spec.actionEvents[InputAction.IMPLEMENT_EXTRA3]
	if actionEvent ~= nil then
		local text = limitToField and spec.texts.allowCreateFields or spec.texts.limitToFields
		g_inputBinding:setActionEventText(actionEvent.actionEventId, text)
	end
end

--- Replaces the cultivator/disc-harrow density map pass with the plough one.
--- Structure follows Cultivator:processCultivatorArea (Cultivator.lua:88) so that the
--- work area accounting, sounds and client update radius behave identically.
---
--- updatePlowArea is called with its default resetPlowLevel (true), which is what sets
--- the vanilla plow counter to max — exactly what a plough does. We therefore do NOT
--- call FSDensityMapUtil.updateSubsoilerArea, which would do the same job redundantly.
function SubsoilerPlow:processCultivatorArea(superFunc, workArea, dt)
	local spec = self[SubsoilerPlow.SPEC_TABLE_NAME]
	if not spec.isSubsoilerPlow then
		return superFunc(self, workArea, dt)
	end

	local cultivatorSpec = self.spec_cultivator
	local realArea, area = 0, 0

	local xs, _, zs = getWorldTranslation(workArea.start)
	local xw, _, zw = getWorldTranslation(workArea.width)
	local xh, _, zh = getWorldTranslation(workArea.height)

	FSDensityMapUtil.eraseTireTrack(xs, zs, xw, zw, xh, zh)

	if not self.isServer and Cultivator.CLIENT_DM_UPDATE_RADIUS < self.currentUpdateDistance then
		return 0, 0
	end

	if cultivatorSpec.isEnabled then
		local params = cultivatorSpec.workAreaParameters

		realArea, area = FSDensityMapUtil.updatePlowArea(xs, zs, xw, zw, xh, zh, not params.limitToField, params.limitFruitDestructionToField, params.angle)
		realArea = realArea + FSDensityMapUtil.updateVineCultivatorArea(xs, zs, xw, zw, xh, zh, true)

		params.lastChangedArea = params.lastChangedArea + realArea
		params.lastStatsArea = params.lastStatsArea + realArea
		params.lastTotalArea = params.lastTotalArea + area
	end

	cultivatorSpec.isWorking = 0.5 < self:getLastSpeed()

	return realArea, area
end

--- The cultivator's AI ground types treat PLOWED as still needing work
--- (Cultivator.AI_REQUIRED_GROUND_TYPES_DEEP, Cultivator.lua:3), which would leave a hired
--- helper working ground this implement has already finished. Swap in the plough's list.
---
--- Falls back to the base implementation when a sowing machine is attached, so subsoiler +
--- seeder combinations keep the cultivator's own handling of that case (Cultivator.lua:143).
function SubsoilerPlow:updateCultivatorAIRequirements(superFunc)
	local spec = self[SubsoilerPlow.SPEC_TABLE_NAME]
	if not spec.isSubsoilerPlow then
		return superFunc(self)
	end

	if self.getChildVehicles ~= nil then
		local vehicles = self:getChildVehicles()
		for i = 1, #vehicles do
			if SpecializationUtil.hasSpecialization(SowingMachine, vehicles[i].specializations) then
				return superFunc(self)
			end
		end
	end

	if self.clearAITerrainDetailRequiredRange ~= nil then
		self:clearAITerrainDetailRequiredRange()
		self:addAIGroundTypeRequirements(Plow.AI_REQUIRED_GROUND_TYPES)
	end
end

function SubsoilerPlow:onReadStream(streamId, connection)
	self[SubsoilerPlow.SPEC_TABLE_NAME].limitToField = streamReadBool(streamId)
end

function SubsoilerPlow:onWriteStream(streamId, connection)
	streamWriteBool(streamId, self[SubsoilerPlow.SPEC_TABLE_NAME].limitToField)
end

function SubsoilerPlow:onRegisterActionEvents(isActiveForInput, isActiveForInputIgnoreSelection)
	if not self.isClient then
		return
	end

	local spec = self[SubsoilerPlow.SPEC_TABLE_NAME]
	self:clearActionEventsTable(spec.actionEvents)

	if spec.isSubsoilerPlow and isActiveForInputIgnoreSelection then
		local _, actionEventId = self:addActionEvent(spec.actionEvents, InputAction.IMPLEMENT_EXTRA3, self, SubsoilerPlow.actionEventLimitToField, false, true, false, true, nil)
		g_inputBinding:setActionEventTextPriority(actionEventId, GS_PRIO_NORMAL)
	end
end

--- Mirrors Plow:onUpdate (Plow.lua:225): keeps the prompt text in step and hides the action
--- entirely from players without the createFields permission.
function SubsoilerPlow:onUpdate(dt, isActiveForInput, isActiveForInputIgnoreSelection, isSelected)
	if not self.isClient then
		return
	end

	local spec = self[SubsoilerPlow.SPEC_TABLE_NAME]
	if not spec.isSubsoilerPlow then
		return
	end

	local actionEvent = spec.actionEvents[InputAction.IMPLEMENT_EXTRA3]
	if actionEvent == nil or self:getSubsoilerForceLimitToField() then
		return
	end

	if g_currentMission:getHasPlayerPermission("createFields", self:getOwnerConnection()) then
		g_inputBinding:setActionEventActive(actionEvent.actionEventId, true)

		local text = spec.limitToField and spec.texts.allowCreateFields or spec.texts.limitToFields
		g_inputBinding:setActionEventText(actionEvent.actionEventId, text)
	else
		g_inputBinding:setActionEventActive(actionEvent.actionEventId, false)
	end
end

function SubsoilerPlow:actionEventLimitToField(actionName, inputValue, callbackState, isAnalog)
	local spec = self[SubsoilerPlow.SPEC_TABLE_NAME]
	if not self:getSubsoilerForceLimitToField() then
		self:setSubsoilerLimitToField(not spec.limitToField)
	end
end
