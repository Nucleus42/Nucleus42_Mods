-- Forward Contracts — DeliveryWatch
--
-- Turns every sale at a selling station into a delivery event carrying farm, fill type,
-- litres, the money actually paid, and the station. Server-side only.
--
-- See HANDOFF.md §3 for the research this is built on. The short version:
--
--   * SellingStation:sellFillType (scripts/objects/SellingStation.lua:365) is the single
--     point where a sale is booked. Every delivery route converges there, including
--     trains, which bypass UnloadTrigger entirely (PlaceableTrainSystem.lua:889). Watch
--     the till, not the doors.
--   * The station keeps cumulative per-fill-type totals — getTotalPaid (:502) and
--     getTotalReceived (:505) — so the money paid for THIS sale is the change in
--     totalPaid since the previous one. That is the real price, including seasonal
--     factor, price drop, great demand and station multipliers. Never re-derive it.
--   * The hook supplies farmId and toolType, which the totals do not record.

DeliveryWatch = {}

local DeliveryWatch_mt = Class(DeliveryWatch)

function DeliveryWatch.new()
	local self = setmetatable({}, DeliveryWatch_mt)

	-- [station][fillTypeIndex] = totalPaid as of the last sale we observed.
	self.paidSnapshot = {}
	self.listeners = {}
	self.isInstalled = false

	-- True only while PlaceableTrainSystem:sellGoods is running. See onSale.
	self.inTrainSale = false

	return self
end

-- ---------------------------------------------------------------------------
-- Hook installation
-- ---------------------------------------------------------------------------

--- Append to a function while preserving its return values.
--
-- Utils.appendedFunction does NOT do this — it calls oldFunc(...) and drops the result
-- (scripts/utils/Utils.lua:491-500). sellFillType returns the price, and Precision
-- Farming's overwrite consumes that return value and multiplies it
-- (internalMods/FS25_precisionFarming/.../EnvironmentalScore.lua:495-496). If our append
-- ended up beneath PF's overwrite, PF would receive nil and error on the arithmetic.
-- So we keep the return value. Costs nothing, removes a whole class of load-order bug.
local function appendPreservingReturn(oldFunc, newFunc)
	if oldFunc == nil then
		return newFunc
	end

	return function(...)
		local results = { oldFunc(...) }
		newFunc(...)
		return unpack(results)
	end
end

function DeliveryWatch:install()
	if self.isInstalled then
		return
	end

	-- Server only: totalReceived/totalPaid are never streamed to clients. SellingStation
	-- readStream/writeStream (:154-210) send prices and pricing trend, nothing else.
	if not g_currentMission:getIsServer() then
		return
	end

	local watch = self

	SellingStation.sellFillType = appendPreservingReturn(
		SellingStation.sellFillType,
		function(station, farmId, fillDelta, fillTypeIndex, toolType, extraAttributes)
			watch:onSale(station, farmId, fillDelta, fillTypeIndex, toolType)
		end)

	-- Bracket the train's own sale so onSale can recognise it. sellGoods loops every
	-- railroad vehicle's fill units straight into the station
	-- (PlaceableTrainSystem.lua:879-891), so one flag covers the whole load.
	--
	-- pcall-free but ordered so the flag always clears: capture, clear, then return. If
	-- sellGoods ever errors the flag would stick and silently stop counting every later
	-- delivery, which is why the flag is cleared before the results are returned rather
	-- than after any of our own work.
	if PlaceableTrainSystem ~= nil and PlaceableTrainSystem.sellGoods ~= nil then
		local baseSellGoods = PlaceableTrainSystem.sellGoods
		PlaceableTrainSystem.sellGoods = function(placeable, ...)
			watch.inTrainSale = true
			local ok, result = pcall(baseSellGoods, placeable, ...)
			watch.inTrainSale = false
			if not ok then
				Logging.error("[ForwardContracts] PlaceableTrainSystem:sellGoods failed: %s",
					tostring(result))
				return
			end
			return result
		end
	else
		Logging.warning("[ForwardContracts] PlaceableTrainSystem:sellGoods not found; "
			.. "train sales will be counted as deliveries.")
	end

	self.isInstalled = true
end

--- Record where every existing station's totals currently stand.
--
-- Needed because the totals persist across save/load (SellingStation loadFromXMLFile:271,
-- saveToXMLFile:289). Without seeding, the first sale after loading a savegame would look
-- like a delta covering the entire history of that station.
--
-- Stations built later start their totals at zero, and an unseeded station defaults to
-- zero, so they are handled correctly without any special case.
--
-- Call this once the mission has finished loading, NOT from install(). Placeables — and
-- therefore selling stations — are not all registered while mods are still running their
-- loadMap. Seeding too early would find an empty station list and leave every existing
-- station unseeded, which is exactly the savegame bug this function exists to prevent.
-- No sale can occur before the mission starts, so seeding late is safe.
function DeliveryWatch:seedSnapshots()
	local economyManager = g_currentMission.economyManager
	if economyManager == nil or economyManager.sellingStations == nil then
		return
	end

	for _, entry in ipairs(economyManager.sellingStations) do
		local station = entry.station
		if station ~= nil and station.totalPaid ~= nil then
			local snapshot = {}
			for fillTypeIndex, paid in pairs(station.totalPaid) do
				snapshot[fillTypeIndex] = paid
			end
			self.paidSnapshot[station] = snapshot
		end
	end
end

-- ---------------------------------------------------------------------------
-- Sale observation
-- ---------------------------------------------------------------------------

function DeliveryWatch:onSale(station, farmId, fillDelta, fillTypeIndex, toolType)
	if station == nil or fillTypeIndex == nil then
		return
	end

	-- Keep the snapshot current for every sale, including ones we go on to discard.
	-- Skipping this would fold a rejected sale's money into the next accepted one.
	local paid = self:consumePaidDelta(station, fillTypeIndex)

	if fillDelta == nil or fillDelta <= 0 then
		return
	end

	-- What is excluded is the TRAIN'S OWN sale — the "sell the whole train's load to the
	-- neighbouring town" action — and nothing else (HANDOFF.md §3.7). Delivering to the
	-- train station's silo with a trailer you drove is a legitimate local haul and counts.
	--
	-- Discriminated by wrapping PlaceableTrainSystem:sellGoods and flagging the window,
	-- not by tool type. Tool type cannot express this: sellGoods passes
	-- ToolType.UNDEFINED (PlaceableTrainSystem.lua:889) but so does a player hand-tipping
	-- at a station (Player.lua:1455), which the player did carry there.
	if self.inTrainSale then
		return
	end

	-- SPECIES, if this was wood and WoodWatch saw the tree. Attached to the SAME event rather
	-- than counted separately, so the species tiers can never disagree with the litres the
	-- player was actually paid for — see WoodWatch's header for why that matters.
	--
	-- nil for everything else, and nil for wood that reached the till by a route we did not
	-- wrap. Consumers must treat nil as "unknown species", never as a default one.
	local wood = self.woodWatch ~= nil and self.woodWatch:consumePending() or nil

	self:notify({
		farmId = farmId,
		fillTypeIndex = fillTypeIndex,
		litres = fillDelta,
		money = paid,
		station = station,
		speciesName = wood ~= nil and wood.speciesName or nil,
	})
end

--- Seam to WoodWatch. Optional: without it every delivery simply carries no species, which is
--- exactly the state the mod was in before forestry and is correct for every other fill type.
function DeliveryWatch:setWoodWatch(woodWatch)
	self.woodWatch = woodWatch
end

--- Money paid for this sale = the change in the station's running total since the last
--- sale we saw. Advances the snapshot as a side effect.
function DeliveryWatch:consumePaidDelta(station, fillTypeIndex)
	local snapshot = self.paidSnapshot[station]
	if snapshot == nil then
		snapshot = {}
		self.paidSnapshot[station] = snapshot
	end

	local total = station:getTotalPaid(fillTypeIndex) or 0
	local previous = snapshot[fillTypeIndex] or 0

	snapshot[fillTypeIndex] = total

	return total - previous
end

-- ---------------------------------------------------------------------------
-- Listeners
-- ---------------------------------------------------------------------------

--- Register a callback invoked as callback(target, delivery).
function DeliveryWatch:addListener(target, callback)
	table.insert(self.listeners, { target = target, callback = callback })
end

function DeliveryWatch:notify(delivery)
	for _, listener in ipairs(self.listeners) do
		listener.callback(listener.target, delivery)
	end
end
