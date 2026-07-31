-- Forward Contracts — WoodWatch
--
-- Recovers the ONE thing a wood delivery loses on its way to the till: what species it was.
--
-- FORESTRY.md §1.4. `WoodUnloadTrigger:getTargetFillType` returns a flat `FillType.WOOD`
-- (`triggers/WoodUnloadTrigger.lua:116-118`), so by the time `SellingStation:sellFillType`
-- books the sale — which is where `DeliveryWatch` listens — oak and cherry are the same
-- product. Tier 1 does not care. Tiers 2 and 3 are defined by the difference.
--
-- ⚠ **THIS IS AN ANNOTATION LAYER, NOT A SECOND COUNTING PATH, AND THAT IS DELIBERATE.**
--
-- The obvious build is to total litres per species here and settle contracts from it. That
-- would give the mod two independent ledgers for the same event, and they WILL drift — a tree
-- rejected because the station was full, a mod overriding the trigger, a sale that reaches
-- `sellFillType` by some route we did not wrap. Whichever ledger is wrong, the player sees a
-- contract that disagrees with their bank balance.
--
-- So nothing here counts anything. It parks the species of the tree currently being processed,
-- and `DeliveryWatch` consumes it when the sale actually books. **If the sale does not happen,
-- the species is discarded.** One event, one count, species attached.
--
-- ---------------------------------------------------------------------------
-- Why these two hooks and no others
-- ---------------------------------------------------------------------------
--
--   * `calculateWoodBaseValue` (`:130-135`) is where species is knowable — it resolves
--     `g_splitShapeManager:getSplitTypeByIndex(getSplitType(objectId))` and returns the
--     litres and the per-litre price alongside. **It has exactly one caller in the whole
--     game** (`:86`, inside `processWood`), so every call is a real delivery attempt and
--     wrapping it cannot pick up HUD previews or price displays.
--
--   * `processWood` (`:73`) is wrapped only to bracket the window and supply `farmId`, which
--     `calculateWoodBaseValue` does not receive. Same technique DeliveryWatch already uses to
--     recognise a train sale — see its `inTrainSale` flag.
--
-- The two are strictly interleaved inside processWood's loop: calculate, add, sell, calculate,
-- add, sell. So "the pending species" is always the tree currently in flight, and a tree that
-- is rejected for want of capacity (`:89`, the `isFull` branch) is simply overwritten by the
-- next one and never consumed.
--
-- Server-side only, for the same reason DeliveryWatch is: the sale is booked on the server.

WoodWatch = {}

local WoodWatch_mt = Class(WoodWatch)

function WoodWatch.new()
	local self = setmetatable({}, WoodWatch_mt)

	-- The tree currently in flight: { speciesName, litres, ratePerLitre, maxSize, farmId }.
	-- Never a list. See the header — this parks one tree, it does not accumulate.
	self.pending = nil

	-- True only while WoodUnloadTrigger:processWood is running, so a WOOD sale arriving by any
	-- other route is not silently given the wrong species.
	self.inWoodSale = false

	self.isInstalled = false
	self.logDeliveries = false

	return self
end

-- ---------------------------------------------------------------------------
-- Hook installation
-- ---------------------------------------------------------------------------

--- Append to a function while preserving its return values.
---
--- `Utils.appendedFunction` drops the result (`scripts/utils/Utils.lua:491-500`), and
--- `calculateWoodBaseValue` returns the litres and price that `processWood` immediately uses.
--- Losing them would stop every wood sale on the map dead. DeliveryWatch carries the same
--- helper and the same warning; duplicated rather than shared because the two modules are
--- installed independently and neither should be able to break the other by being absent.
local function appendPreservingReturn(oldFunc, newFunc)
	if oldFunc == nil then
		return newFunc
	end

	return function(...)
		local results = { oldFunc(...) }
		newFunc(unpack(results), ...)
		return unpack(results)
	end
end

function WoodWatch:install()
	if self.isInstalled then
		return
	end

	if not g_currentMission:getIsServer() then
		return
	end

	if WoodUnloadTrigger == nil or WoodUnloadTrigger.processWood == nil
		or WoodUnloadTrigger.calculateWoodBaseValue == nil then
		-- Degrade to silence, not to an error. Tier 1 needs none of this — it is an ordinary
		-- FillType.WOOD contract on rails that already work — so a missing hook must cost the
		-- species tiers and nothing else.
		Logging.warning("[ForwardContracts] WoodUnloadTrigger hooks not found; forestry "
			.. "species tracking is disabled. Tier 1 wood contracts are unaffected.")
		return
	end

	local watch = self

	-- Bracket the window and capture the farm. Ordered so the flag always clears even if the
	-- base call errors — DeliveryWatch learned this the hard way: a stuck flag would silently
	-- mis-attribute every later delivery rather than failing loudly.
	local baseProcessWood = WoodUnloadTrigger.processWood
	WoodUnloadTrigger.processWood = function(trigger, farmId, ...)
		watch.inWoodSale = true
		watch.saleFarmId = farmId
		watch.pending = nil

		local ok, result = pcall(baseProcessWood, trigger, farmId, ...)

		watch.inWoodSale = false
		watch.saleFarmId = nil
		watch.pending = nil

		if not ok then
			Logging.error("[ForwardContracts] WoodUnloadTrigger:processWood failed: %s",
				tostring(result))
			return
		end

		return result
	end

	WoodUnloadTrigger.calculateWoodBaseValue = appendPreservingReturn(
		WoodUnloadTrigger.calculateWoodBaseValue,
		function(litres, ratePerLitre, maxSize, trigger, objectId)
			watch:onWoodValued(litres, ratePerLitre, maxSize, objectId)
		end)

	self.isInstalled = true
end

-- ---------------------------------------------------------------------------
-- Observation
-- ---------------------------------------------------------------------------

--- A tree has been measured and priced, and is about to be tipped.
---
--- The three returns are Giants' own (`WoodUnloadTrigger.lua:159`):
---   litres       = volume * splitType.volumeToLiter
---   ratePerLitre = splitType.pricePerLiter * qualityScale * defoliageScale * lengthScale
---
--- **That rate is the REALISED price, not a listed one**, and it is the same quantity
--- `Offers.WOOD_REALISED_SHARE` was measured against. So every delivery the player makes is a
--- free K measurement, which is why this logs the ratio.
function WoodWatch:onWoodValued(litres, ratePerLitre, maxSize, objectId)
	if not self.inWoodSale then
		return
	end

	local speciesName = WoodWatch.getSpeciesName(objectId)

	if speciesName == nil or type(litres) ~= "number" or litres <= 0 then
		self.pending = nil
		return
	end

	self.pending = {
		speciesName = speciesName,
		litres = litres,
		ratePerLitre = ratePerLitre or 0,
		maxSize = maxSize or 0,
		farmId = self.saleFarmId,
	}

	if self.logDeliveries then
		self:logPending()
	end
end

--- The species of a split shape, BY NAME.
---
--- Names, never indices — the same rule already established for fill types. Split types are
--- registered in `SplitShapeManager:loadMapData` at runtime, so installing a mod that adds
--- species can renumber them and a saved index would silently mean a different tree. The
--- manager supports names directly: `getSplitTypeNameByIndex` / `getSplitTypeIndexByName`
--- (`scripts/misc/SplitShapeManager.lua:89-107`), upper-cased on registration (`:66`).
---
--- Upper-case names also happen to be exactly what `treePlant.xml` persists for a planting
--- (`treeType="OAK"`), so ONE string identifies a species for planting, pricing and delivery.
--- That is what makes the phase 5 ledger a lookup rather than a mapping table.
function WoodWatch.getSpeciesName(objectId)
	if objectId == nil or getSplitType == nil or g_splitShapeManager == nil then
		return nil
	end

	local splitTypeIndex = getSplitType(objectId)
	if splitTypeIndex == nil then
		return nil
	end

	if g_splitShapeManager.getSplitTypeNameByIndex ~= nil then
		local name = g_splitShapeManager:getSplitTypeNameByIndex(splitTypeIndex)
		if name ~= nil then
			return name
		end
	end

	-- Fall back to the split type record itself. Some maps register species without the
	-- name lookup being populated, and a species we can name from either route is still a
	-- species we can hold a contract in.
	local splitType = g_splitShapeManager.getSplitTypeByIndex ~= nil
		and g_splitShapeManager:getSplitTypeByIndex(splitTypeIndex) or nil

	return type(splitType) == "table" and splitType.name or nil
end

--- Take the species of the tree currently in flight, if there is one. Consuming it is the
--- point: a species may be attached to exactly ONE sale, so nothing can be counted twice.
---
--- Called by DeliveryWatch when a WOOD sale books. Returns nil for every non-wood delivery and
--- for any wood that reached the till by a route we did not wrap, which is the honest answer —
--- **an unknown species must never be guessed at.** A tier-3 contract refusing wood it cannot
--- identify is correct; crediting it to whichever species was last seen would not be.
function WoodWatch:consumePending()
	local pending = self.pending
	self.pending = nil

	return pending
end

function WoodWatch:logPending()
	local pending = self.pending
	if pending == nil then
		return
	end

	-- The ratio is K for this delivery. WOOD_REALISED_SHARE is 0.367, measured on three whole
	-- trees; every log line here is another sample, taken on whatever the player actually cut.
	local splitType = nil
	if g_splitShapeManager ~= nil and g_splitShapeManager.getSplitTypeIndexByName ~= nil
		and g_splitShapeManager.getSplitTypeByIndex ~= nil then
		local index = g_splitShapeManager:getSplitTypeIndexByName(pending.speciesName)
		splitType = index ~= nil and g_splitShapeManager:getSplitTypeByIndex(index) or nil
	end

	local listed = type(splitType) == "table" and splitType.pricePerLiter or nil
	local ratio = (listed ~= nil and listed > 0)
		and (pending.ratePerLitre / listed) or nil

	Logging.info("[ForwardContracts] wood: %s, %.0f l at %.4f /l, longest side %.1f m, "
		.. "listed %s, K %s",
		pending.speciesName, pending.litres, pending.ratePerLitre, pending.maxSize,
		listed ~= nil and string.format("%.2f", listed) or "?",
		ratio ~= nil and string.format("%.3f", ratio) or "?")
end
