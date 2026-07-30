-- Forward Contracts — FeedLedger
--
-- A record of every fill type this farm has actually put into a husbandry.
--
-- WHY THIS EXISTS, and it is the user's idea (2026-07-29): the mod wants to suggest a
-- species the player is partly equipped for already, and the honest way to know what they
-- are equipped for is to watch what they have DONE — not to infer it from what animals they
-- happen to own.
--
--   *"Would it make sense to implement a backend system that monitors what we have fed the
--   animals previously, so the mod can look and go 'hey that's a match in equipment for some
--   part of this other species'?"*
--
-- Feeding wheat proves a combine, a trailer and a way to unload. Feeding hay proves a mower,
-- a tedder, a rake and a baler. Nothing else in the game states that as plainly, and no
-- amount of reasoning about which animals are in the pen gets at it — a player may buy feed,
-- inherit a herd, or grow crops they never feed to anything.
--
-- **The link is meant to be loose.** The point is not that one species' chain matches
-- another's, it is that the player is not starting from zero. See Animals.getFeedAffinity.

FeedLedger = {}

local FeedLedger_mt = Class(FeedLedger)

FeedLedger.SAVEGAME_FILENAME = "forwardContractsFeed.xml"

function FeedLedger.new()
	local self = setmetatable({}, FeedLedger_mt)

	-- [farmId] = { [fillTypeName] = litresFedTotal }
	--
	-- Keyed by NAME, never index. Fill type indices are assigned at load and shift when the
	-- mod set changes — the same rule §7 already fixed for contracts.
	self.byFarm = {}

	return self
end

-- ---------------------------------------------------------------------------
-- Observation
-- ---------------------------------------------------------------------------

--- Observe `addFood`, which carries the farm id directly (PlaceableHusbandryFood.lua:398)
--- and fires on the deliberate act of putting food in rather than on the animals eating it.
---
--- **A PLACEABLE SPECIALIZATION CANNOT BE HOOKED BY REPLACING THE TABLE FUNCTION AT RUNTIME.**
--- Tried first and it silently did nothing: `addFood` is copied onto every husbandry TYPE by
--- `SpecializationUtil.registerFunction` during type registration
--- (PlaceableHusbandryFood.lua:8), which happens well before `loadMap`. Reassigning
--- `PlaceableHusbandryFood.addFood` afterwards changes a table nothing reads again. The
--- savegame proved it: `forwardContractsFeed.xml` was written and empty after a feed run.
---
--- The sanctioned route is to append to `registerOverwrittenFunctions` at FILE SCOPE, so the
--- override is registered onto each type as it is built. RL does exactly this for
--- `updateInputAndOutput` (RealisticLivestock_PlaceableHusbandryFood.lua) — the pattern was
--- sitting in the file that was read to rule RL out as the cause.
---
--- Contrast `DeliveryWatch`, which wraps `SellingStation.sellFillType` at runtime and works
--- fine: that is an ordinary class method, not a specialization function. **The two need
--- different techniques and the difference is invisible until it fails.**
function FeedLedger.onAddFood(placeable, superFunc, farmId, delta, fillTypeIndex, ...)
	local result = superFunc(placeable, farmId, delta, fillTypeIndex, ...)

	local ledger = ForwardContracts ~= nil and ForwardContracts.feedLedger or nil

	-- Record what was actually ACCEPTED, not what was offered — a full trough takes nothing,
	-- and that is not evidence of anything.
	if ledger ~= nil and type(result) == "number" and result > 0 then
		ledger:record(farmId, fillTypeIndex, result)
	end

	return result
end

function FeedLedger.registerOverwrittenFunctions(placeableType)
	SpecializationUtil.registerOverwrittenFunction(placeableType, "addFood", FeedLedger.onAddFood)
end

--- Kept so main.lua's call site stays honest, but the real work happens at file scope below.
function FeedLedger:install()
	if PlaceableHusbandryFood == nil then
		Logging.warning("[ForwardContracts] PlaceableHusbandryFood missing — feed ledger inactive.")
	end
end

function FeedLedger:record(farmId, fillTypeIndex, litres)
	if farmId == nil or fillTypeIndex == nil then
		return
	end

	local fillType = g_fillTypeManager:getFillTypeByIndex(fillTypeIndex)
	if fillType == nil or fillType.name == nil then
		return
	end

	local farm = self.byFarm[farmId]
	if farm == nil then
		farm = {}
		self.byFarm[farmId] = farm
	end

	farm[fillType.name] = (farm[fillType.name] or 0) + (litres or 0)
end

-- ---------------------------------------------------------------------------
-- Queries
-- ---------------------------------------------------------------------------

--- Fill type INDICES this farm has fed, as a set.
---
--- Resolved from names at call time so a fill type that no longer exists simply drops out
--- rather than poisoning the set with a stale index.
function FeedLedger:getFedFillTypes(farmId)
	local result = {}

	for name in pairs(self.byFarm[farmId] or {}) do
		local index = g_fillTypeManager:getFillTypeIndexByName(name)
		if index ~= nil then
			result[index] = true
		end
	end

	return result
end

function FeedLedger:hasFed(farmId, fillTypeIndex)
	return self:getFedFillTypes(farmId)[fillTypeIndex] == true
end

-- ---------------------------------------------------------------------------
-- Persistence
-- ---------------------------------------------------------------------------

function FeedLedger:getSavegamePath()
	local missionInfo = g_currentMission.missionInfo

	if missionInfo == nil or missionInfo.savegameDirectory == nil then
		return nil
	end

	return missionInfo.savegameDirectory .. "/" .. FeedLedger.SAVEGAME_FILENAME
end

function FeedLedger:save()
	local path = self:getSavegamePath()
	if path == nil then
		return
	end

	local xmlFile = createXMLFile("forwardContractsFeed", path, "forwardContractsFeed")
	if xmlFile == nil or xmlFile == 0 then
		return
	end

	local farmIndex = 0

	for farmId, fillTypes in pairs(self.byFarm) do
		local farmKey = string.format("forwardContractsFeed.farm(%d)", farmIndex)
		setXMLInt(xmlFile, farmKey .. "#farmId", farmId)

		local index = 0
		for name, litres in pairs(fillTypes) do
			local key = string.format("%s.fed(%d)", farmKey, index)
			setXMLString(xmlFile, key .. "#fillType", name)
			setXMLFloat(xmlFile, key .. "#litres", litres)
			index = index + 1
		end

		farmIndex = farmIndex + 1
	end

	saveXMLFile(xmlFile)
	delete(xmlFile)
end

function FeedLedger:load()
	local path = self:getSavegamePath()
	if path == nil or not fileExists(path) then
		return
	end

	local xmlFile = loadXMLFile("forwardContractsFeed", path)
	if xmlFile == nil or xmlFile == 0 then
		return
	end

	self.byFarm = {}

	local farmIndex = 0
	while true do
		local farmKey = string.format("forwardContractsFeed.farm(%d)", farmIndex)
		if not hasXMLProperty(xmlFile, farmKey) then
			break
		end

		local farmId = getXMLInt(xmlFile, farmKey .. "#farmId")

		if farmId ~= nil then
			local fillTypes = {}
			local index = 0

			while true do
				local key = string.format("%s.fed(%d)", farmKey, index)
				if not hasXMLProperty(xmlFile, key) then
					break
				end

				local name = getXMLString(xmlFile, key .. "#fillType")
				if name ~= nil then
					fillTypes[name] = getXMLFloat(xmlFile, key .. "#litres") or 0
				end

				index = index + 1
			end

			self.byFarm[farmId] = fillTypes
		end

		farmIndex = farmIndex + 1
	end

	delete(xmlFile)
end

-- ---------------------------------------------------------------------------
-- Registration, at FILE SCOPE
-- ---------------------------------------------------------------------------
--
-- Must run as the script is sourced, before placeable types are built. See
-- FeedLedger.onAddFood for why a runtime table swap does not work here.
--
-- `Utils.appendedFunction` is safe in this one place because
-- `registerOverwrittenFunctions` returns nothing — the return-discarding trap that rules it
-- out for `sellFillType` and `addFood` does not apply to a registration hook.
if PlaceableHusbandryFood ~= nil then
	PlaceableHusbandryFood.registerOverwrittenFunctions = Utils.appendedFunction(
		PlaceableHusbandryFood.registerOverwrittenFunctions,
		FeedLedger.registerOverwrittenFunctions)
end
