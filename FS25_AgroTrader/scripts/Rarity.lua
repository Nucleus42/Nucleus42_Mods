-- AgroTrader — rarity model.
--
-- How often a given machine turns up in the classifieds. DERIVED FROM THE GAME'S OWN DATA,
-- never tabulated: the median price of a category is the rarity signal. Small tractors are
-- cheap for a tractor and turn up constantly; a self-propelled beet harvester is dear for a
-- vehicle and takes finding. That falls out of the prices without anyone writing it down,
-- which also means mod-added machines and categories nobody has ever seen classify themselves.
--
-- ⚠ RANK WITHIN THE MOTORIZED / IMPLEMENT SPLIT, NEVER ACROSS IT.
--
-- The first version of this ranked every category on one price scale and got the answer
-- exactly backwards: tractorsS landed in the rarest-but-one band and tractorsM in the rarest,
-- because a 92k tractor was being ranked against a 1,700 weight bracket. There are far more
-- cheap-implement categories than dear-vehicle ones, so the bands squashed every self-propelled
-- machine into the top and "rarity" quietly became "is it self-propelled". 92k is CHEAP for a
-- tractor and ENORMOUS for a mower; the two do not belong on the same axis. Splitting first
-- fixed it outright. Do not "simplify" this back into a single ranking.
--
-- Verified against base-game data on 2026-08-01, 563 category rows (see plan §1, Stage 1 result):
--   cars 23k (very common) · tractorsS 92.5k · tractorsM 175k (both common)
--   tractorsL 382k · harvesters 307k (rare) · beetHarvesters 685k (very rare)

Rarity = {}
local Rarity_mt = Class(Rarity)

-- Spread between the commonest and rarest category on each side, as a probability multiplier.
--
-- Vehicles get the full range: a beet harvester really should be an event.
--
-- Implements are DELIBERATELY COMPRESSED. Ranking them works, but the range does not — ranked
-- on their own scale the dearest implement band is balersRound, seeders, cutters and augerWagons,
-- which are ubiquitous machines. The real used-implement market is far deeper than the
-- used-vehicle market: a plough is always available somewhere, a self-propelled beet harvester
-- is a phone-around job. So even the priciest implement stays reasonably findable.
-- Settled with the user at Stage 1 review. Do not widen this to match the vehicle side.
Rarity.VEHICLE_FLOOR = 0.10
Rarity.IMPLEMENT_FLOOR = 0.55

-- Second, gentler pass WITHIN a category, so a 695k tractorsL is rarer than a 254k one.
-- Much shallower than the between-category spread — the category is the main signal and this
-- only breaks ties inside it.
Rarity.VEHICLE_ITEM_FLOOR = 0.50
Rarity.IMPLEMENT_ITEM_FLOOR = 0.80

-- Cheapest machine worth advertising.
--
-- ⚠ DELIBERATELY HALF OF VANILLA'S. The base game uses 10,000
-- (VehicleSaleSystem.MINIMUM_ITEM_VALUE, shop/VehicleSaleSystem.lua:2) because its used tab has
-- only five slots — a 600 bucket appearing there would crowd out a tractor. AgroTrader has a
-- large searchable pool where a cheap listing costs nothing and only surfaces if somebody
-- filters for it, so that reasoning does not carry over.
--
-- Measured against base-game data on 2026-08-01: at 10,000 the threshold removed 103 of 548
-- machines (18.8%), including 10 of 11 frontLoaders and 15 of 16 frontLoaderTools. Since
-- "Attachment" is one of the two REQUIRED filters, that made Attachment -> Front Loaders a
-- permanently empty screen. 5,000 still drops weights, teleLoaderTools, levelers and baling
-- miscellany wholesale, which is right — nobody hunts a second-hand weight bracket.
Rarity.MINIMUM_ITEM_VALUE = 5000

function Rarity.new()
	local self = setmetatable({}, Rarity_mt)

	self.weightByItemId = {}   -- storeItem.id -> probability weight
	self.categories = {}       -- diagnostic rows, for the console dump
	self.isBuilt = false

	return self
end

--- Everything AgroTrader will ever consider listing. Mirrors vanilla's own candidate filter
--- (shop/VehicleSaleSystem.lua:240-247) so we never offer something the shop itself would not:
--- vehicles only (which includes implements — species VEHICLE covers a plough), in the store,
--- not a bundle child, worth listing, and not behind locked DLC.
function Rarity.getIsListable(storeItem)
	if storeItem == nil or not StoreItemUtil.getIsVehicle(storeItem) then
		return false
	end
	if not storeItem.showInStore or storeItem.isBundleItem then
		return false
	end
	if (storeItem.price or 0) < Rarity.MINIMUM_ITEM_VALUE then
		return false
	end
	-- Respects the extraContentId unlock gate (shop/StoreManager.lua:456-461).
	return g_storeManager:getIsItemUnlocked(storeItem)
end

--- Self-propelled, or towed/mounted?
---
--- There is NO flag on a store item for this — StoreSpecies.VEHICLE covers ploughs too
--- (shop/StoreSpecies.lua:1-7, StoreItemUtil.lua:2-16). The honest test is the vehicle type's
--- specializations, but that reopens the XML through the type manager for every item. We use the
--- cheaper signal instead: only motorized vehicles declare <specs><power> in their storeData
--- (Motorized.lua:2782-2783 registers the loader; the schema is Motorized.lua:63).
---
--- Safe because getSpecsFromXML runs EVERY vehicle spec type's loadFunc regardless of which
--- specializations the item actually has (StoreItemUtil.lua:145-152), so a nil here genuinely
--- means "the key was absent from the XML", not "we did not look".
function Rarity.getIsMotorized(storeItem)
	StoreItemUtil.loadSpecsFromXML(storeItem)
	return storeItem.specs ~= nil and storeItem.specs.power ~= nil
end

local function median(sorted)
	local n = #sorted
	if n == 0 then
		return 0
	end
	if n % 2 == 1 then
		return sorted[(n + 1) / 2]
	end
	return (sorted[n / 2] + sorted[n / 2 + 1]) * 0.5
end

--- Geometric interpolation from 1 down to `floor` as `rank` runs 0 -> 1.
---
--- Geometric rather than linear because these are probability multipliers: what matters is the
--- RATIO between adjacent bands, not the absolute step. A linear ramp makes the common end
--- almost flat and the rare end fall off a cliff.
local function weightForRank(rank, floor)
	return floor ^ math.clamp(rank, 0, 1)
end

--- Walk the whole store once and work out a listing weight for every machine in it.
---
--- Costs one XML open per vehicle store item, cached thereafter by loadSpecsFromXML's own
--- `if item.specs == nil` guard (shop/StoreItemUtil.lua:129). Vanilla takes the same cost inside
--- calculateSellPrice (Vehicle.lua:1866). Elapsed time is logged rather than assumed — if this
--- ever becomes a load-time problem we will have the number in front of us, not a hunch.
function Rarity:build()
	-- openIntervalTimer returns -1 when no timer is available (async/AsyncTaskManager.lua:104
	-- guards the same way), so the timing is best-effort and must never gate the build itself.
	local timer = openIntervalTimer()

	self.weightByItemId = {}
	self.categories = {}

	-- Bucket every listable item by (side, primary category).
	--
	-- PRIMARY category only (storeItem.categoryName, set to categoryNames[1] at
	-- shop/StoreManager.lua:690). An item can carry several, but rarity has to be ONE number per
	-- machine — counting a tractor in three categories would let it draw three tickets.
	local buckets = {}
	local order = { [true] = {}, [false] = {} }

	for _, storeItem in ipairs(g_storeManager:getItems()) do
		if Rarity.getIsListable(storeItem) then
			local isMotorized = Rarity.getIsMotorized(storeItem)
			local category = storeItem.categoryName or "MISC"
			local key = (isMotorized and "V|" or "I|") .. category

			local bucket = buckets[key]
			if bucket == nil then
				bucket = { category = category, isMotorized = isMotorized, prices = {}, items = {} }
				buckets[key] = bucket
				table.insert(order[isMotorized], bucket)
			end

			table.insert(bucket.prices, storeItem.price)
			table.insert(bucket.items, storeItem)
		end
	end

	-- Rank each side independently. See the header warning — this split is the whole design.
	for _, isMotorized in ipairs({ true, false }) do
		local side = order[isMotorized]

		for _, bucket in ipairs(side) do
			table.sort(bucket.prices)
			bucket.median = median(bucket.prices)
		end

		table.sort(side, function(a, b)
			if a.median == b.median then
				return a.category < b.category   -- stable, so the dump reads the same each run
			end
			return a.median < b.median
		end)

		local categoryFloor = isMotorized and Rarity.VEHICLE_FLOOR or Rarity.IMPLEMENT_FLOOR
		local itemFloor = isMotorized and Rarity.VEHICLE_ITEM_FLOOR or Rarity.IMPLEMENT_ITEM_FLOOR
		local numCategories = #side

		for index, bucket in ipairs(side) do
			-- rank 0 for the cheapest category, 1 for the dearest. Guard the single-category
			-- case, where the division would be 0/0.
			local rank = numCategories > 1 and (index - 1) / (numCategories - 1) or 0
			bucket.rank = rank
			bucket.weight = weightForRank(rank, categoryFloor)

			-- Within the category, dearer machines are rarer than cheaper ones. Ranked by
			-- position in the sorted price list rather than by price ratio, so one 700k outlier
			-- cannot flatten everything below it.
			local numItems = #bucket.items
			table.sort(bucket.items, function(a, b)
				if a.price == b.price then
					return (a.id or 0) < (b.id or 0)
				end
				return a.price < b.price
			end)

			for itemIndex, storeItem in ipairs(bucket.items) do
				local itemRank = numItems > 1 and (itemIndex - 1) / (numItems - 1) or 0
				self.weightByItemId[storeItem.id] = bucket.weight * weightForRank(itemRank, itemFloor)
			end

			table.insert(self.categories, bucket)
		end
	end

	self.isBuilt = true

	local elapsedMs = -1
	if timer ~= -1 then
		elapsedMs = readIntervalTimerMs(timer)
		closeIntervalTimer(timer)
	end

	Logging.info("[AgroTrader] Rarity built: %d categories, %d machines, %.0f ms",
		#self.categories, table.size(self.weightByItemId), elapsedMs)
end

--- Relative likelihood of this machine appearing in the classifieds. Higher is commoner.
--- Returns 0 for anything we would never list, so it can be used as the sole filter.
function Rarity:getWeight(storeItem)
	if storeItem == nil then
		return 0
	end
	return self.weightByItemId[storeItem.id] or 0
end

--- Human-readable band, for the console dump and any future UI. Derived from the weight rather
--- than stored, so it can never disagree with the number that actually drives generation.
function Rarity.getBandName(weight, isMotorized)
	local floor = isMotorized and Rarity.VEHICLE_FLOOR or Rarity.IMPLEMENT_FLOOR
	-- Recover the rank the weight came from, then bucket it into fifths.
	local rank = 0
	if floor > 0 and floor < 1 and weight > 0 then
		rank = math.clamp(math.log(weight) / math.log(floor), 0, 1)
	end
	local names = { "Very common", "Common", "Uncommon", "Rare", "Very rare" }
	return names[math.min(math.floor(rank * 5) + 1, 5)]
end
