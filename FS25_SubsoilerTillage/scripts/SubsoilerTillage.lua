--
-- SubsoilerTillage
--
-- Mod entry point. Two jobs:
--   1. Attach the SubsoilerPlow specialization to every vehicle type that has Cultivator.
--   2. Let subsoilers work an active ploughing contract.
--

SubsoilerTillage = {}

SubsoilerTillage.MOD_NAME = g_currentModName
SubsoilerTillage.SPEC_NAME = "subsoilerPlow"

-- ---------------------------------------------------------------------------------------------
-- 1. Specialization injection
-- ---------------------------------------------------------------------------------------------

--- Adds the spec to every vehicle type carrying Cultivator. The spec itself is inert on
--- anything outside the "subsoilers" store category, so a blanket attach is safe and is what
--- lets mod subsoilers work without knowing their type names in advance.
---
--- Hooked on TypeManager:validateTypes (TypeManager.lua:161) because that runs once after every
--- mod has registered its vehicle types, which is the only point where the full list is known.
--- Same hook and guard Precision Farming uses (PrecisionFarming.lua:373-378); g_iconGenerator
--- is non-nil during store icon generation, where none of this is wanted.
local function validateTypes(self)
	if self.typeName ~= "vehicle" or g_iconGenerator ~= nil then
		return
	end

	local specName = SubsoilerTillage.MOD_NAME .. "." .. SubsoilerTillage.SPEC_NAME
	local count = 0

	for typeName, typeEntry in pairs(self:getTypes()) do
		if SpecializationUtil.hasSpecialization(Cultivator, typeEntry.specializations) then
			g_vehicleTypeManager:addSpecialization(typeName, specName)
			count = count + 1
		end
	end

	Logging.info("[%s] Attached '%s' to %d cultivator vehicle type(s).", SubsoilerTillage.MOD_NAME, SubsoilerTillage.SPEC_NAME, count)
end

TypeManager.validateTypes = Utils.prependedFunction(TypeManager.validateTypes, validateTypes)

-- ---------------------------------------------------------------------------------------------
-- 2. Ploughing contracts
-- ---------------------------------------------------------------------------------------------

--- AbstractFieldMission:getIsWorkAllowed (AbstractFieldMission.lua:394) rejects any work area
--- type not listed in mission.workAreaTypes, and PlowMission lists only WorkAreaType.PLOW
--- (PlowMission.lua:13). A subsoiler's work areas are WorkAreaType.CULTIVATOR, so it would be
--- refused on contract land.
---
--- This widens the gate for exactly one case: a ploughing contract being worked by a vehicle
--- that this mod has classed as a subsoiler. Ordinary cultivators are unaffected.
---
--- Contract completion needs no change — PlowMission:createModifier counts PLOWED ground
--- pixels (PlowMission.lua:17), which is what SubsoilerPlow:processCultivatorArea now paints.
local function getIsWorkAllowed(self, superFunc, farmId, x, z, workAreaType, vehicle)
	if superFunc(self, farmId, x, z, workAreaType, vehicle) then
		return true
	end

	if workAreaType ~= WorkAreaType.CULTIVATOR then
		return false
	end

	if not self:getIsRunning() then
		return false
	end

	if self.getMissionTypeName == nil or self:getMissionTypeName() ~= PlowMission.NAME then
		return false
	end

	if vehicle == nil or vehicle.getIsSubsoilerPlow == nil or not vehicle:getIsSubsoilerPlow() then
		return false
	end

	return true
end

AbstractFieldMission.getIsWorkAllowed = Utils.overwrittenFunction(AbstractFieldMission.getIsWorkAllowed, getIsWorkAllowed)
