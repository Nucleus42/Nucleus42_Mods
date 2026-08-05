-- AgroTrader — valuation, condition rolling and delivery.
--
-- ⚠ THE PRICE MATHS IS THE BASE GAME'S, UNMODIFIED. We call Vehicle.calculateSellPrice,
-- Wearable.calculateRepairPrice and Wearable.calculateRepaintPrice directly rather than
-- reimplementing them, so AgroTrader can never drift from what the vanilla shop would say.
--
-- Exactly five things move a used price in FS25, and the source contains nothing else:
--   base price + storeItem.lifetime   (shop/StoreManager.lua:699-710)
--   age in months  -> ageFactor        = min(-0.1*ln(years) + 0.75, 0.85)
--   operating hours -> operatingTimeFactor = 1 - hours^k / lifetime
--   damage  -> subtracted as repair price  = price * damage^1.5 * 0.09
--   wear    -> subtracted as repaint price = price * 0.2 * sqrt(wear)
--                                     (vehicles/Vehicle.lua:1862-1874, Wearable.lua:294-309)
--
-- DIRT IS NOT ONE OF THEM. We roll and apply it so a delivered machine looks its age, but it has
-- no effect on price in vanilla and none here. A wash costs nothing; pricing it would mean
-- inventing economics the game does not have. Do not add a dirt term.

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
	}
end

--- Asking price, using the base game's own arithmetic end to end.
function Valuation.getAskingPrice(storeItem, history)
	-- ⚠ THE EMPTY TABLE IS LOAD-BEARING. NEVER PASS nil HERE.
	--
	-- StoreItemUtil.getCosts guards the wrong table: it tests `storeItem.configurations ~= nil`
	-- and then iterates `pairs(configurations)`, the argument (shop/StoreItemUtil.lua:62-63).
	-- So passing nil crashes on any machine that HAS configurations, which is nearly all of them.
	-- Vanilla never trips this because VehicleSaleSystem always passes a table
	-- (shop/VehicleSaleSystem.lua:301). Cost one game load to find.
	local basePrice = StoreItemUtil.getDefaultPrice(storeItem, {})

	-- Same class of hazard one level down: Vehicle.calculateSellPrice reads `storeItem.specs.power`
	-- straight after calling loadSpecsFromXML (Vehicle.lua:1866-1868), but loadSpecsFromXML leaves
	-- `specs` nil if the XML fails to open (shop/StoreItemUtil.lua:129-134). A machine with an
	-- unreadable xml would take the whole load down. An empty table is what a successful load of a
	-- spec-less item produces anyway, so this only ever substitutes for a failure.
	StoreItemUtil.loadSpecsFromXML(storeItem)
	if storeItem.specs == nil then
		storeItem.specs = {}
	end
	local repairPrice = Wearable.calculateRepairPrice(basePrice, history.damage)
	local repaintPrice = Wearable.calculateRepaintPrice(basePrice, history.wear)

	return math.floor(Vehicle.calculateSellPrice(
		storeItem, history.age, history.operatingTime, basePrice, repairPrice, repaintPrice))
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
