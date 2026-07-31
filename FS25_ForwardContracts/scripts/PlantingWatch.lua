-- Forward Contracts — PlantingWatch
--
-- Counts trees the player plants, by species, against live forestry contracts.
--
-- THIS IS THE ONLY THING THAT MAKES THE SPECIES REAL. Woodchips are species-blind at the till:
-- a chipped oak, a chipped wild birch, poplar chips off a field and a sawmill's by-product are
-- one indistinguishable fill type, and there is no `getSplitType` to ask (FORESTRY.md §5.2). So
-- the contract verifies the PLANTING, which IS observable, and never the delivery, which is not.
--
--   * "Plant at least 3 oak"          — real, checkable, and checked here.
--   * "These chips came from those 3" — not knowable, and not attempted.
--
-- The residual loophole — plant N, then deliver chips cut from the map's own forest — stays open
-- DELIBERATELY. §1's framing governs: the mod observes and pays, it does not police.

PlantingWatch = {}

local PlantingWatch_mt = Class(PlantingWatch)

function PlantingWatch.new(contractProvider)
	local self = setmetatable({}, PlantingWatch_mt)

	-- Seam to ContractStore. Anything implementing `creditPlanting(farmId, speciesName)` will do.
	self.contractProvider = contractProvider

	return self
end

function PlantingWatch:setContractProvider(contractProvider)
	self.contractProvider = contractProvider
end

-- ---------------------------------------------------------------------------
-- The hook
-- ---------------------------------------------------------------------------

--- Wrap `TreePlantManager:plantTree` (`misc/TreePlantManager.lua:224`).
---
--- Degrades to SILENCE if the function is missing, exactly as `WoodWatch` does. A forestry
--- contract would then be unfulfillable, so the warning has to be loud in the log — but a
--- missing hook must not take the rest of the mod down with it.
function PlantingWatch:install()
	if self.isInstalled then
		return
	end

	if not g_currentMission:getIsServer() then
		return
	end

	if g_treePlantManager == nil or g_treePlantManager.plantTree == nil then
		Logging.warning("[ForwardContracts] TreePlantManager:plantTree not found; forestry "
			.. "planting cannot be counted and forestry contracts will not complete.")
		return
	end

	local watch = self
	local basePlantTree = g_treePlantManager.plantTree

	-- Wrapped on the INSTANCE, not on the class. `TreePlantManager` is a singleton created
	-- during map load and `g_treePlantManager` is the only reference anything uses.
	g_treePlantManager.plantTree = function(manager, treeTypeIndex, x, y, z, rx, ry, rz,
		growthStateI, variationIndex, isGrowing, nextGrowthTargetHour, existingSplitShapeFileId)

		-- ALL returns, not just the first. `plantTree` returns `treeId, splitShapeFileId`
		-- today, and truncating a wrapped function's returns is the exact fault that once
		-- discarded every delivery in this mod (IMPLEMENTATION.md, landmine 4).
		local results = { pcall(basePlantTree, manager, treeTypeIndex, x, y, z, rx, ry, rz,
			growthStateI, variationIndex, isGrowing, nextGrowthTargetHour,
			existingSplitShapeFileId) }

		if not results[1] then
			Logging.error("[ForwardContracts] TreePlantManager:plantTree failed: %s",
				tostring(results[2]))
			return
		end

		-- Counted only if the tree actually appeared. `plantTree` returns nil when the tree
		-- type is unknown or `loadTreeNode` fails (`:229`, `:233`).
		if results[2] ~= nil then
			watch:onPlanted(manager, treeTypeIndex, growthStateI, isGrowing,
				nextGrowthTargetHour, existingSplitShapeFileId)
		end

		return unpack(results, 2)
	end

	self.isInstalled = true
end

--- ⛔ **LOADING A SAVEGAME REPLAYS `plantTree` FOR EVERY TREE IN IT.**
---
--- `TreePlantManager:loadFromXMLFile` walks `<savegame>/treePlant.xml` and calls `plantTree`
--- once per stored tree (`misc/TreePlantManager.lua:652`). A hook that counted those would
--- credit the entire plantation again on EVERY LOAD — a contract for three oaks would be
--- satisfied by planting one and loading the game three times. Silent, and it would look like
--- the ledger working.
---
--- **Found by reading the load path, not by testing.** A test would have needed a save, a
--- reload and someone thinking to check the number twice.
---
--- Four discriminators, and each one is here because a specific caller needs excluding. Every
--- call site in the game was enumerated to build this list:
---
--- | clause | excludes |
--- | --- | --- |
--- | `existingSplitShapeFileId == nil` | **the load replay.** `saveToXMLFile` ALWAYS writes `#splitShapeFileId` (`:684`, as `tree.splitShapeFileId or -1`), so every replayed tree carries one and no fresh planting does. Bulletproof on its own |
--- | `nextGrowthTargetHour == nil` | the load replay again, for any growing tree (`:681`). A second lock on the fault that matters most |
--- | `isGrowing ~= false` | `ConstructionBrushTree:186` (a bought decorative tree), `DeadwoodMission:421` and `TreeTransportMission:392` (scripted mission spawns — §5.3 caught exactly these in a Highlands save), `WoodHarvesterLight:361`, and the `gsTreeAdd` / `gsTreeLoadAll` console commands (`:888`, `:1006`) |
--- | `growthStateI == 1` | `StumpCutterLight:115`, which plants a stump at stage 0. A stump is not a sapling |
---
--- What survives is `TreePlanter:756` — the tree planter vehicle — and `TreePlantEvent:39`,
--- which is the same action arriving from a client. Which is exactly the set that should count.
function PlantingWatch:onPlanted(manager, treeTypeIndex, growthStateI, isGrowing,
	nextGrowthTargetHour, existingSplitShapeFileId)

	if existingSplitShapeFileId ~= nil or nextGrowthTargetHour ~= nil then
		return
	end

	if isGrowing == false or growthStateI ~= 1 then
		return
	end

	local provider = self.contractProvider
	if provider == nil or provider.creditPlanting == nil then
		return
	end

	local treeType = manager.indexToTreeType ~= nil and manager.indexToTreeType[treeTypeIndex]
		or nil
	if treeType == nil or treeType.name == nil then
		return
	end

	-- BY NAME, UPPER CASE. `registerTreeType` upper-cases on the way in
	-- (`misc/TreePlantManager.lua:181`) and the result equals the split type's name, so one
	-- string identifies a species across the tree registry, the price registry and the
	-- savegame's own `treePlant.xml` (§5.1). Upper-cased again here rather than trusted,
	-- because a mod registering a type by another route is cheaper to tolerate than to debug.
	local speciesName = string.upper(treeType.name)

	-- ⚠ NO farmId REACHES `plantTree`. It is not in the signature, and the tree planter calls
	-- it from a vehicle spec that never passes one down (`TreePlanter.lua:756`). So the local
	-- player's farm is used — correct in single player, which is where this mod lives
	-- (HANDOFF.md: do net zero work toward multiplayer).
	local farmId = g_currentMission:getFarmId()
	if farmId == nil then
		return
	end

	provider:creditPlanting(farmId, speciesName)
end
