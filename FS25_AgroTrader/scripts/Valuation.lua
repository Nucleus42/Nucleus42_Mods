-- AgroTrader — valuation, condition rolling and delivery.
--
-- ⚠ OVERTURNED (2026-08-30): v1.0 priced adverts with the vanilla maths, unmodified, on the
-- principle that AgroTrader should never drift from what the shop would say. Play testing killed
-- that principle: an entire arable fleet — two tractors, combine, telehandler, sprayer, tanker,
-- spreader, roller, seeder — came to £30-40k, because Vehicle.calculateSellPrice is a TRADE-IN
-- penalty function, not a market price. It multiplies the age factor by the hours factor (double
-- depreciation for the same underlying use), has no residual floor, and subtracts full repair and
-- repaint costs even on implements, which never need repairing and lose nothing by being scruffy.
--
-- The asking price is now the mod's own model, built with the user against real English used
-- machinery prices (see README research):
--
--   asking = newPrice x residual(lifeUsed)      hours-primary threshold curve — value holds to
--                                               ~40% life, drops steeply to ~80% ("overhaul
--                                               looming"), floors near scrap-plus-utility
--          x ageAdjust                          mild: hours trump years in farm machinery
--          x historyFactor                      full service history commands 12-18% real premium
--          x brandFactor                        tier-1 ranges hold value; derived from store data
--          x marketIndex                        crop price seasonality moves farm incomes
--          - conditionCost                      full repair+repaint on motorised (ADS makes it
--                                               real), a quarter of it on implements (cosmetic)
--
-- Vanilla's calculateSellPrice is UNTOUCHED as the sell-back value, so the buy/sell spread stays
-- punishing and buy-then-resell always loses money.
--
-- The vanilla condition formulas (Wearable.calculateRepairPrice / calculateRepaintPrice) are
-- still called for the condition term, so that term can never drift from what a repair would
-- actually cost.
--
-- DIRT IS STILL NEVER PRICED. We roll and apply it so a delivered machine looks its age, but a
-- wash costs nothing; pricing it would mean inventing economics the game does not have.

Valuation = {}

-- ---------------------------------------------------------------- previous owners
--
-- Vanilla couples hours to age trivially — operatingTime = age_months * U(0.5, 1.3)
-- (shop/VehicleSaleSystem.lua:300) — so every machine of a given age has much the same hours.
-- Instead each listing gets a previous owner, and the owner decides how hard it was worked.
--
-- ⚠ WHAT IS ROLLED IS `u`, THE FRACTION OF THE MACHINE'S LIFE CONSUMED — NEVER HOURS DIRECTLY.
--
-- Hours are then back-solved from that item's own curve (see getHoursForLifeUsed). Rolling hours
-- directly cannot work: the implement exponent of 1.3 means an implement is scrap at ~137 hours
-- where a tractor survives to 600, so any shared hours figure would hand out free ploughs while
-- barely denting tractor prices. Rolling `u` makes operatingTimeFactor come out as exactly 1-u
-- for BOTH types — identical value loss, no special cases, and the worthless cliff becomes
-- unreachable by construction rather than something we clamp against.
--
-- `rate` is life consumed per month of age.
Valuation.ARCHETYPES = {
	{
		id = "estate",
		-- Big fleet, many machines sharing the work, so any one of them does little.
		rateMin = 0.0020, rateMax = 0.0035,
	},
	{
		id = "family",
		-- A mixed farm with enough kit to spread the load. Roughly vanilla's behaviour.
		rateMin = 0.0040, rateMax = 0.0065,
	},
	{
		id = "contractor",
		-- Solo operator or contractor: one or two machines doing every job, worked hard.
		-- These are the cheap ones with a catch.
		rateMin = 0.0075, rateMax = 0.0110,
	},
}

-- Age of the machines that turn up. Vanilla uses 6-40 months; a marketplace worth searching needs
-- to go further, so up to ten years.
Valuation.AGE_MIN_MONTHS = 6
Valuation.AGE_MAX_MONTHS = 120

-- Bounds on life consumed. The upper bound is what makes genuinely beaten machinery findable —
-- "if they are desperate and it is all they can afford". Safe because Giants already punishes
-- high-hours machines: Wearable:updateDamageAmount scales damage accumulation by up to 5x
-- (EconomyManager.MAX_DAILYUPKEEP_MULTIPLIER = 4, LIFETIME_OPERATINGTIME_RATIO = 0.08333) and
-- repairs are charged against the machine's NEW price, not what the player paid. Cheap to buy,
-- punishing to keep — it balances itself.
--
-- ⚠ THE LOWER BOUND MUST STAY WELL UNDER THE ARCHETYPE RATES, OR IT HIDES THEM. At 0.10 every
-- machine under about three years old clamped to the same value, so a one-year-old estate
-- machine and a one-year-old contractor machine priced identically — the archetypes were
-- invisible on exactly the young stock a player looks at most. Measured and fixed 2026-08-01.
Valuation.LIFE_USED_MIN = 0.02
Valuation.LIFE_USED_MAX = 0.90

-- ---------------------------------------------------------------------- distance
--
-- Four tiers, EQUAL CHANCE EACH. Rarity governs how often a machine appears at all; it
-- deliberately does not also push rare machines further away. Two independent mechanics.
Valuation.DISTANCE_TIERS = {
	{ tier = 1, minMiles = 5,   maxMiles = 50 },
	{ tier = 2, minMiles = 51,  maxMiles = 100 },
	{ tier = 3, minMiles = 101, maxMiles = 200 },
	{ tier = 4, minMiles = 201, maxMiles = 350 },
}

-- Delivery is haulage, priced on real UK rates supplied by the user.
--
-- ⚠ RATES ARE PER MILE, BANDED BY WEIGHT — NOT PER TONNE PER MILE.
--
-- This is the correction that matters. An earlier version multiplied a per-tonne-per-mile rate by
-- the machine's weight, which is not how haulage is sold and overcharged a 7.5 t tractor over 200
-- miles by roughly fourteen times (£6,300 against a real ~£450). Weight does not scale the price;
-- it decides which LORRY is needed, and each class of lorry has its own per-mile rate. Do not
-- reintroduce a multiply-by-tonnage term.
--
-- Bands, from UK haulage rate guidance:
--   up to 3 t   standard flatbed or 7.5 t lorry      £1.50 - £2.20 / mile
--   3 - 10 t    18 t or 26 t rigid                   £2.00 - £2.50 / mile
--   10 - 24 t   44 t artic or low loader             £2.75 - £3.00+ / mile
--   24 t plus   STGO abnormal load                   £2.50 - £6.00+ / mile
--
-- The rate is rolled once per listing within its band, because two hauliers quote differently for
-- the same job — and it is then stored, so an advert's price never changes while it stands.
Valuation.HAULAGE_BANDS = {
	{ maxTonnes = 3,          minRate = 1.50, maxRate = 2.20, surcharge = 0 },
	{ maxTonnes = 10,         minRate = 2.00, maxRate = 2.50, surcharge = 0 },
	{ maxTonnes = 24,         minRate = 2.75, maxRate = 3.00, surcharge = 0 },
	-- Over 24 t the load exceeds standard road weight rules and moves under STGO: route planning,
	-- permits and sometimes escort vehicles. That is a real fixed cost on top of the mileage,
	-- which is why the band carries a surcharge the others do not.
	{ maxTonnes = math.huge,  minRate = 2.50, maxRate = 6.00, surcharge = 500 },
}

-- No haulier turns out for the price of four miles. A minimum job charge is what actually gets
-- quoted for a short local move, and without it tier 1 would cost almost nothing.
Valuation.DELIVERY_MINIMUM = 175

-- Used when the machine declares no weight spec at all. Deliberately crude: it only has to be
-- better than charging nothing. 3 t sits on the small/medium boundary.
Valuation.DELIVERY_FALLBACK_TONNES = 3.0

-- ------------------------------------------------------------------ pricing model
--
-- Residual value against life consumed, as piecewise-linear knots. The shape is the real used
-- market's: hours trump years, value holds while plenty of working life remains, then drops
-- steeply once major overhauls loom (the 6,000-8,000 hour cliff on a real tractor), and floors at
-- scrap-plus-utility — a machine that works is never nearly free. Calibrated 2026-08-30 against
-- English used prices supplied by the user: a mid-life 150hp tractor at ~55-60% of new, a
-- thrashed ex-contractor one still ~£15-20k against £100k new.
Valuation.RESIDUAL_KNOTS = {
	{ 0.00, 0.90 },
	{ 0.20, 0.80 },
	{ 0.40, 0.62 },
	{ 0.60, 0.40 },
	{ 0.80, 0.25 },
	{ 1.00, 0.18 },
}

-- Age matters far less than hours for an income-generating asset — a 5-year-old tractor with
-- 2,000 hours outvalues a 2-year-old with 6,500. A mild drift downward, capped.
Valuation.AGE_DISCOUNT_PER_YEAR = 0.015
Valuation.AGE_FACTOR_FLOOR = 0.85

-- Service history, read off the rolled `care`. A fully documented machine commands a 12-18% real
-- premium; no history knocks value off. The thresholds also label the advert, so the premium is
-- something the player can see they are paying for.
Valuation.HISTORY_FULL_MIN_CARE = 0.75   -- "Full service history"
Valuation.HISTORY_NONE_MAX_CARE = 0.40   -- below this: "No service history"
Valuation.HISTORY_FULL_FACTOR = 1.15
Valuation.HISTORY_PART_FACTOR = 1.00
Valuation.HISTORY_NONE_FACTOR = 0.90

-- ⚠ THE CONDITION DISCOUNT IS MOSTLY WITHHELD FROM IMPLEMENTS, ON PURPOSE. Attachments are never
-- repaired in FS25 and lose nothing by being damaged — the game charges no consequence at all. So
-- a discount for implement damage is free money, and it was the single biggest hole in v1.0: a
-- £400 plough that works forever. Motorised machines keep the full discount because ADS makes
-- their damage genuinely expensive. The residual quarter kept for implements is cosmetic — a
-- tatty machine should still list slightly under a clean one.
Valuation.IMPLEMENT_CONDITION_SHARE = 0.25

-- A used machine, however good, sits under new; and a working one, however bad, never reaches
-- vanilla's near-zero. Both as fractions of the new price.
Valuation.PRICE_CEILING = 0.92
Valuation.PRICE_FLOOR = 0.12

-- Brand strength: derived, never tabulated. The breadth of a brand's store range is the proxy for
-- "tier-1 with a parts network behind it" — the full-line brands (John Deere, New Holland, Case,
-- Fendt, Claas...) carry the widest ranges in the game's own data and hold their value; a brand
-- with three products depreciates hard. A deliberately narrow swing: it colours prices, it does
-- not drive them.
Valuation.BRAND_FACTOR_MIN = 0.94
Valuation.BRAND_FACTOR_MAX = 1.06

-- Market mood: when crop prices are up, farm incomes are up and used kit is bid up. Derived from
-- the game's own seasonal price factors across every fill type it shows on the price table —
-- deterministic (catmullRom over fixed per-period factors, EconomyManager.lua:440-448), so server
-- and client always agree without anything crossing the wire. SWING scales how hard the crop
-- seasonality moves machinery; the clamp bounds the whole effect.
Valuation.MARKET_SWING = 0.8
Valuation.MARKET_INDEX_MIN = 0.88
Valuation.MARKET_INDEX_MAX = 1.12

-- ------------------------------------------------------------------------ helpers

local function lerp(a, b, t)
	return a + (b - a) * t
end

--- Uniform random in [lo, hi]. Injectable so the offline harness can be deterministic.
function Valuation.range(lo, hi, rng)
	return lo + ((rng or math.random)() * (hi - lo))
end

--- Motorized machines wear their value on hours more slowly than implements do.
--- Mirrors Giants' own test exactly (Vehicle.lua:1866-1869): the factor is 1.3 when the store
--- item declares no <specs><power>. Kept in one place so ours can never disagree with theirs.
function Valuation.getMotorizedFactor(storeItem)
	StoreItemUtil.loadSpecsFromXML(storeItem)
	if storeItem.specs ~= nil and storeItem.specs.power ~= nil then
		return 1.0
	end
	return 1.3
end

function Valuation.getLifetime(storeItem)
	-- 600 months is both the schema default (shop/StoreManager.lua:706) and the value every
	-- single base-game machine actually declares — 561 of 561 measured on 2026-08-01.
	return storeItem.lifetime or 600
end

--- Hours that consume fraction `u` of this machine's usable life.
---
--- Inverts Giants' own operatingTimeFactor. Substituting the result back gives
--- `1 - hours^k / lifetime == 1 - u`, so two machines at the same `u` have lost exactly the same
--- share of their value regardless of type — while an implement shows roughly a quarter to a
--- third of the hours a tractor would, which is the real-world ratio. Giants' 1.3 exponent
--- already encodes "an implement does fewer hours than the tractor pulling it"; this just
--- reads it back out.
function Valuation.getHoursForLifeUsed(storeItem, lifeUsed)
	local k = Valuation.getMotorizedFactor(storeItem)
	local lifetime = Valuation.getLifetime(storeItem)
	return (lifetime * lifeUsed) ^ (1 / k)
end

-- ------------------------------------------------------------------ rolling a listing

--- Roll the history of one machine: how old, who owned it, how hard it was worked, how well it
--- was looked after.
---
--- ⚠ CONDITION IS DECOUPLED FROM HOURS ON PURPOSE. `care` is rolled independently of the
--- archetype, so a high-hours machine that was properly maintained is a genuine find and a
--- low-hours neglected one is a genuine trap. Tying damage to hours in lockstep would make every
--- listing at a given age interchangeable, which is the vanilla behaviour we are replacing.
function Valuation.rollHistory(storeItem, rng)
	rng = rng or math.random

	-- Drawn from the injected stream like everything else, so a seeded rng reproduces the whole
	-- listing. Do not reach for math.random directly anywhere in here.
	local archetype = Valuation.ARCHETYPES[
		math.min(#Valuation.ARCHETYPES, math.floor(rng() * #Valuation.ARCHETYPES) + 1)]

	local ageMonths = math.floor(Valuation.range(
		Valuation.AGE_MIN_MONTHS, Valuation.AGE_MAX_MONTHS, rng) + 0.5)

	local rate = Valuation.range(archetype.rateMin, archetype.rateMax, rng)
	local lifeUsed = math.clamp(ageMonths * rate,
		Valuation.LIFE_USED_MIN, Valuation.LIFE_USED_MAX)

	-- 0 = neglected, 1 = cherished.
	local care = rng()
	local ageYears = ageMonths / 12

	-- Damage tracks life used, but how strongly depends on care, plus a neglect term that does
	-- not depend on hours at all — that second term is what makes a low-hours trap possible.
	local damage = math.clamp(
		lifeUsed * lerp(0.90, 0.20, care) + (1 - care) * 0.30 * rng(), 0.02, 0.95)

	-- Paint is different: it fades with age and weather whatever the owner does, so it carries an
	-- age term that care cannot fully offset.
	local wear = math.clamp(
		lifeUsed * lerp(1.00, 0.35, care) + ageYears * 0.03, 0.02, 1.00)

	-- Cosmetic only. Never priced.
	local dirt = math.clamp(rng() * 0.5 + (1 - care) * 0.5, 0.05, 1.00)

	local hours = Valuation.getHoursForLifeUsed(storeItem, lifeUsed)

	return {
		archetype = archetype.id,
		age = ageMonths,
		lifeUsed = lifeUsed,
		operatingTime = hours * 3600000,   -- ms, the unit Vehicle/VehicleLoadingData expect
		damage = damage,
		wear = wear,
		dirt = dirt,
		-- Kept on the history because the service-history tier is priced AND shown; deriving the
		-- label from damage instead would let the two disagree.
		care = care,
	}
end

-- ------------------------------------------------------------------ pricing terms

--- Residual share of new price for a machine with fraction `u` of its life consumed.
--- Piecewise-linear over RESIDUAL_KNOTS.
function Valuation.getResidual(u)
	local knots = Valuation.RESIDUAL_KNOTS
	u = math.clamp(u, 0, 1)
	for i = 2, #knots do
		local a, b = knots[i - 1], knots[i]
		if u <= b[1] then
			local t = (u - a[1]) / (b[1] - a[1])
			return lerp(a[2], b[2], t)
		end
	end
	return knots[#knots][2]
end

--- Service history tier for a rolled care value: "full", "part" or "none".
function Valuation.getServiceHistory(care)
	if care >= Valuation.HISTORY_FULL_MIN_CARE then
		return "full"
	end
	if care < Valuation.HISTORY_NONE_MAX_CARE then
		return "none"
	end
	return "part"
end

function Valuation.getHistoryFactor(care)
	local tier = Valuation.getServiceHistory(care)
	if tier == "full" then
		return Valuation.HISTORY_FULL_FACTOR
	end
	if tier == "none" then
		return Valuation.HISTORY_NONE_FACTOR
	end
	return Valuation.HISTORY_PART_FACTOR
end

-- ------------------------------------------------------------------ brand strength

-- storeItem.brandIndex -> price factor. Built once after the store is complete, alongside the
-- rarity build; empty until then, and getBrandFactor answers 1.0 for anything unknown, so the
-- worst failure mode is "brand has no effect".
Valuation.brandFactorByIndex = {}

--- Walk the store once and rank every brand by the breadth of its listable range.
---
--- ⚠ MUST RUN AFTER onFinishedLoading, like Rarity:build and for the same reason — mod and map
--- store items are still registering during loadMap, and a brand table built early would misrank
--- exactly the modded brands it exists to classify.
function Valuation.buildBrandStrength()
	Valuation.brandFactorByIndex = {}

	local countByBrand = {}
	for _, storeItem in ipairs(g_storeManager:getItems()) do
		if Rarity.getIsListable(storeItem) and storeItem.brandIndex ~= nil then
			countByBrand[storeItem.brandIndex] = (countByBrand[storeItem.brandIndex] or 0) + 1
		end
	end

	local brands = {}
	for brandIndex, count in pairs(countByBrand) do
		table.insert(brands, { index = brandIndex, count = count })
	end
	-- Ties broken on index so the ranking is stable run to run.
	table.sort(brands, function(a, b)
		if a.count == b.count then
			return a.index < b.index
		end
		return a.count < b.count
	end)

	local n = #brands
	for rankPos, brand in ipairs(brands) do
		local rank = n > 1 and (rankPos - 1) / (n - 1) or 0.5
		Valuation.brandFactorByIndex[brand.index] =
			lerp(Valuation.BRAND_FACTOR_MIN, Valuation.BRAND_FACTOR_MAX, rank)
	end

	Logging.info("[AgroTrader] Brand strength built: %d brands ranked", n)
end

function Valuation.getBrandFactor(storeItem)
	if storeItem.brandIndex == nil then
		return 1.0
	end
	return Valuation.brandFactorByIndex[storeItem.brandIndex] or 1.0
end

-- ------------------------------------------------------------------- market index

--- The market's mood right now, as a price multiplier for the whole used market.
---
--- Averages the game's own seasonal price factor across every fill type it shows on the price
--- table, at the CURRENT PERIOD with a fixed mid-period alpha — so the index moves only when the
--- in-game month turns, never mid-advert-view within a month. Deterministic on both sides of a
--- connection: the factors are fixed data (FillTypeDesc.lua:76-85) and currentPeriod is synced
--- game state, so nothing needs streaming.
---
--- A price can still legitimately move if the month turns while an advert stands — that is the
--- market moving, and the server's regenerated price at purchase is always the one charged.
function Valuation.getMarketIndex()
	if g_currentMission == nil or g_currentMission.economyManager == nil
		or g_currentMission.environment == nil or g_fillTypeManager == nil then
		-- Offline harness, or too early in load. A neutral market, never an error.
		return 1.0
	end

	local period = g_currentMission.environment.currentPeriod
	if period == nil then
		return 1.0
	end

	local total, count = 0, 0
	for _, fillType in ipairs(g_fillTypeManager:getFillTypes()) do
		if fillType.showOnPriceTable and (fillType.pricePerLiter or 0) > 0 then
			total = total + g_currentMission.economyManager:getFillTypeSeasonalFactor(
				fillType, period, 0.5)
			count = count + 1
		end
	end
	if count == 0 then
		return 1.0
	end

	local index = 1 + (total / count - 1) * Valuation.MARKET_SWING
	return math.clamp(index, Valuation.MARKET_INDEX_MIN, Valuation.MARKET_INDEX_MAX)
end

--- Asking price. The mod's own market model — see the header for what replaced vanilla and why.
function Valuation.getAskingPrice(storeItem, history)
	-- ⚠ THE EMPTY TABLE IS LOAD-BEARING. NEVER PASS nil HERE.
	--
	-- StoreItemUtil.getCosts guards the wrong table: it tests `storeItem.configurations ~= nil`
	-- and then iterates `pairs(configurations)`, the argument (shop/StoreItemUtil.lua:62-63).
	-- So passing nil crashes on any machine that HAS configurations, which is nearly all of them.
	-- Vanilla never trips this because VehicleSaleSystem always passes a table
	-- (shop/VehicleSaleSystem.lua:301). Cost one game load to find.
	local basePrice = StoreItemUtil.getDefaultPrice(storeItem, {})

	-- loadSpecsFromXML leaves `specs` nil if the XML fails to open (shop/StoreItemUtil.lua:129-134),
	-- and getMotorizedFactor reads it. An empty table is what a successful load of a spec-less item
	-- produces anyway, so this only ever substitutes for a failure.
	StoreItemUtil.loadSpecsFromXML(storeItem)
	if storeItem.specs == nil then
		storeItem.specs = {}
	end

	-- The market's view of the machine: what life it has left, mildly how old it is, whether its
	-- paperwork is in order, whose badge it wears, and how flush farming feels this month.
	local ageFactor = math.max(
		1 - (history.age / 12) * Valuation.AGE_DISCOUNT_PER_YEAR, Valuation.AGE_FACTOR_FLOOR)

	local asking = basePrice
		* Valuation.getResidual(history.lifeUsed)
		* ageFactor
		* Valuation.getHistoryFactor(history.care or 0.5)
		* Valuation.getBrandFactor(storeItem)
		* Valuation.getMarketIndex()

	-- Condition costs the buyer only what fixing it will actually cost THEM — the vanilla repair
	-- and repaint formulas in full for motorised machines (where ADS collects), a quarter for
	-- implements (see IMPLEMENT_CONDITION_SHARE).
	local conditionCost = Wearable.calculateRepairPrice(basePrice, history.damage)
		+ Wearable.calculateRepaintPrice(basePrice, history.wear)
	if Valuation.getMotorizedFactor(storeItem) ~= 1.0 then
		conditionCost = conditionCost * Valuation.IMPLEMENT_CONDITION_SHARE
	end
	asking = asking - conditionCost

	return math.floor(math.clamp(asking,
		basePrice * Valuation.PRICE_FLOOR, basePrice * Valuation.PRICE_CEILING))
end

-- ----------------------------------------------------------------------- delivery

function Valuation.rollDistance(rng)
	rng = rng or math.random
	-- Equal chance per tier, as specified. Do not weight these by rarity.
	local index = math.min(#Valuation.DISTANCE_TIERS,
		math.floor(rng() * #Valuation.DISTANCE_TIERS) + 1)
	local tier = Valuation.DISTANCE_TIERS[index]
	return {
		tier = tier.tier,
		miles = math.floor(Valuation.range(tier.minMiles, tier.maxMiles, rng) + 0.5),
	}
end

--- Shipping weight in tonnes.
---
--- getSpecValueWeight returns nil when the item declares no weight, and it indexes
--- storeItem.specs unguarded (Vehicle.lua:1877), so specs must be loaded first or it errors.
function Valuation.getTonnes(storeItem)
	StoreItemUtil.loadSpecsFromXML(storeItem)
	if storeItem.specs == nil then
		return Valuation.DELIVERY_FALLBACK_TONNES
	end

	local tonnes = Vehicle.getSpecValueWeight(storeItem, nil, nil, nil, true)
	if tonnes == nil or tonnes <= 0 then
		return Valuation.DELIVERY_FALLBACK_TONNES
	end
	return tonnes
end

--- Which lorry this machine needs, and what that class of lorry costs per mile.
function Valuation.getHaulageBand(tonnes)
	for _, band in ipairs(Valuation.HAULAGE_BANDS) do
		if tonnes <= band.maxTonnes then
			return band
		end
	end
	return Valuation.HAULAGE_BANDS[#Valuation.HAULAGE_BANDS]
end

--- Cost to bring this machine home.
---
--- `rate` is passed in when replaying a stored listing so the quote never drifts; omit it and a
--- fresh one is rolled within the band.
function Valuation.getDeliveryFee(storeItem, miles, rate, rng)
	local tonnes = Valuation.getTonnes(storeItem)
	local band = Valuation.getHaulageBand(tonnes)

	if rate == nil then
		rate = Valuation.range(band.minRate, band.maxRate, rng)
	end

	local fee = miles * rate + band.surcharge
	return math.floor(math.max(fee, Valuation.DELIVERY_MINIMUM)), rate
end
