-- Forward Contracts — Animals
--
-- The Realistic Livestock bridge. Enumerates a farm's animals, judges them against a
-- contract's per-trait genetic floors, and observes RL's own sales so a delivery is
-- counted without this mod ever touching a herd.
--
-- See HANDOFF.md §4.6 (the breeder ladder), §5 (verified RL API surface), §5.2a (the
-- per-trait band ladder, which is NOT the aggregate one) and §5.2b (enumeration,
-- identity and observation).
--
-- ---------------------------------------------------------------------------
-- THE RULE THAT SHAPES THIS WHOLE FILE
-- ---------------------------------------------------------------------------
--
-- RL's classes are invisible to us. Every mod runs in its own script environment, so
-- `Animal`, `AnimalSellEvent` and `RLAnimalUtil` cannot be named from here at any load
-- order (HANDOFF.md §5). Animal *instances* reached through husbandry objects carry their
-- own methods and are callable normally — it is only the class globals that do not cross.
--
-- So: reach RL through live objects and base-game globals only. Never construct one of
-- its events, never call one of its classes. This module reads and observes; it never
-- mutates a herd. That is also §2's no-world-mutation rule, and it is what the original
-- mod got catastrophically wrong (§9.3 — it decremented cluster counts by hand and
-- table.remove'd while iterating with ipairs).

Animals = {}

local Animals_mt = Class(Animals)

-- ---------------------------------------------------------------------------
-- Genetics model
-- ---------------------------------------------------------------------------

-- The five traits. `productivity` exists only on some animal types (cows have it, others
-- do not) — always nil-check it. VERIFIED at RealisticLivestock_Animal.lua:429-434, 520.
Animals.TRAITS = { "metabolism", "health", "fertility", "quality", "productivity" }

--- The one trait that moves the sale price. VERIFIED: `Animal:getSellPrice` reads
--- `self.genetics.quality` and nothing else from the genetics table
--- (RealisticLivestock_Animal.lua:1302). The other four matter to breeding and husbandry,
--- never to what the dealer pays — so a contract's cash value can only be anchored on this
--- one. Named rather than spelled inline because pricing depends on it.
Animals.TRAIT_QUALITY = "quality"

--- PER-TRAIT band ladder. Read from Animal:showGeneticsInfo
--- (RealisticLivestock_Animal.lua:795-891), where all five traits share one identical
--- ladder against the RAW trait value in roughly 0.25–1.75.
---
--- CRITICAL: this is NOT the ladder in HANDOFF §5.2. That one bands the *aggregate*
--- geneticsFactor (0–1) with good/bad words. Per trait, RL shows low/high words against
--- the raw value. Fusing the two is the mistake §5.2a was written to prevent: "very good"
--- at 0.8 is an aggregate threshold, while the band the player actually reads on a single
--- trait at that level is "Very high", which is >= 1.40.
Animals.BANDS = {
	{ threshold = 1.65, key = "extremelyHigh", label = "Extremely high" },
	{ threshold = 1.40, key = "veryHigh",      label = "Very high" },
	{ threshold = 1.10, key = "high",          label = "High" },
	{ threshold = 0.90, key = "average",       label = "Average" },
	{ threshold = 0.70, key = "low",           label = "Low" },
	{ threshold = 0.35, key = "veryLow",       label = "Very low" },
	{ threshold = -math.huge, key = "extremelyLow", label = "Extremely low" },
}

--- Fertility alone gains a seventh band at exactly zero
--- (RealisticLivestock_Animal.lua:846-849). No other trait has it.
Animals.BAND_INFERTILE = { key = "infertile", label = "Infertile" }

--- RL's mod name, for reading its l10n. g_i18n:getText(name, customEnv) resolves through
--- I18N.modEnvironments (I18N.lua:170-177), so another mod's texts ARE reachable — unlike
--- its globals. This is how §4.6's "use RL's own vocabulary" is honoured: a contract reads
--- in exactly the words the player sees in the RL menu.
Animals.RL_MOD_NAME = "FS25_RealisticLivestockRM"

--- Trait display names are TYPE-DEPENDENT (RealisticLivestock_Animal.lua:855, 871,
--- 893-896): `quality` reads as Meat, and `productivity` as Milk on cows, Milk or Wool on
--- sheep depending on subtype, and Eggs on chickens.
Animals.TRAIT_L10N = {
	metabolism = "rl_ui_metabolism",
	health = "rl_ui_health",
	fertility = "rl_ui_fertility",
	quality = "rl_ui_meat",
}

Animals.TRAIT_FALLBACK = {
	metabolism = "Metabolism",
	health = "Health",
	fertility = "Fertility",
	quality = "Meat",
	productivity = "Productivity",
}

function Animals.new()
	local self = setmetatable({}, Animals_mt)

	-- [husbandry] = { [animalKey] = snapshot }, refreshed on every cluster update.
	self.herdSnapshot = {}

	-- Removals seen on the most recent cluster update, awaiting confirmation that they
	-- were a sale rather than a death. See onClusterUpdate / onMoney.
	self.pendingRemovals = {}

	self.listeners = {}
	self.isInstalled = false

	return self
end

-- ---------------------------------------------------------------------------
-- Enumeration — base-game globals only
-- ---------------------------------------------------------------------------

--- Every husbandry this farm owns.
---
--- getPlaceablesByFarm already filters on getOwnerFarmId (HusbandrySystem.lua:38-46), so
--- farm attribution is free and we never have to infer ownership.
function Animals:getHusbandries(farmId)
	local result = {}
	local system = g_currentMission.husbandrySystem

	if system == nil or system.getPlaceablesByFarm == nil then
		return result
	end

	for _, placeable in ipairs(system:getPlaceablesByFarm(farmId)) do
		if placeable.getClusterSystem ~= nil then
			local clusterSystem = placeable:getClusterSystem()

			-- getAnimals is installed by RL onto the BASE AnimalClusterSystem class
			-- (RealisticLivestock_AnimalClusterSystem.lua:43-47). Its absence means RL is
			-- not actually managing this herd, so this doubles as a behavioural dependency
			-- check alongside main.lua's g_modIsLoaded test.
			if clusterSystem ~= nil and clusterSystem.getAnimals ~= nil then
				table.insert(result, { placeable = placeable, clusterSystem = clusterSystem })
			end
		end
	end

	return result
end

--- Every individually tracked animal this farm owns, flattened across husbandries.
function Animals:getAnimals(farmId)
	local result = {}

	for _, entry in ipairs(self:getHusbandries(farmId)) do
		local ok, animals = pcall(entry.clusterSystem.getAnimals, entry.clusterSystem)

		if ok and animals ~= nil then
			for _, animal in ipairs(animals) do
				table.insert(result, {
					animal = animal,
					husbandry = entry.placeable,
				})
			end
		end
	end

	return result
end

-- ---------------------------------------------------------------------------
-- Identity
-- ---------------------------------------------------------------------------

--- RL keys an animal on (farmId, uniqueId, birthday.country) —
--- RLAnimalUtil.toKeyFromIdentifiers (scripts/utils/RLAnimalUtil.lua:121-131).
---
--- DO NOT use animal.id. RL's own comment at :134-141 records that it is a never-updated
--- placeholder "0-0" on every animal, so a lookup by it resolves the first match.
---
--- All three parts are plain fields on the live object, so they cross the environment
--- boundary and are safe to persist in a contract.
function Animals.getKey(animal)
	if animal == nil then
		return nil
	end

	local country = animal.birthday ~= nil and animal.birthday.country or nil
	if country == nil or animal.uniqueId == nil then
		return nil
	end

	return string.format("%s|%s|%s", tostring(animal.farmId), tostring(animal.uniqueId),
		tostring(country))
end

--- The ear tag exactly as RL prints it, so a contract can name an animal in the string
--- written on it.
---
--- The accessor is `Animal:getIdentifiers()` (RealisticLivestock_Animal.lua:1526-1528),
--- which returns "<areaCode> <farmId> <uniqueId>". Do not confuse it with
--- RLAnimalUtil.toKeyFromIdentifiers, which takes a TABLE of the same three parts — the
--- names are similar and the types are not.
---
--- pcall'd because it dereferences RLConstants.AREA_CODES[country] with no nil guard, so
--- an animal carrying an unexpected country would otherwise take the whole board down.
function Animals.getEarTag(animal)
	if animal == nil then
		return "?"
	end

	if animal.getIdentifiers ~= nil then
		local ok, tag = pcall(animal.getIdentifiers, animal)
		if ok and type(tag) == "string" then
			return tag
		end
	end

	return string.format("%s %s", tostring(animal.farmId), tostring(animal.uniqueId))
end

-- ---------------------------------------------------------------------------
-- Banding
-- ---------------------------------------------------------------------------

--- The band a raw trait value falls in. `trait` matters only for fertility, which alone
--- has an "infertile" band at exactly zero.
function Animals.getBand(value, trait)
	if value == nil then
		return nil
	end

	if trait == "fertility" and value <= 0 then
		return Animals.BAND_INFERTILE
	end

	for _, band in ipairs(Animals.BANDS) do
		if value >= band.threshold then
			return band
		end
	end

	return Animals.BANDS[#Animals.BANDS]
end

--- Read a text out of RL's own l10n, falling back to our English if RL's entry is missing.
--- I18N returns a "Missing '<key>' in l10n..." string rather than nil when it cannot
--- resolve (I18N.lua:180-185), so the fallback has to test for that rather than for nil.
function Animals.getRLText(key, fallback)
	if g_i18n == nil then
		return fallback
	end

	local ok, text = pcall(g_i18n.getText, g_i18n, key, Animals.RL_MOD_NAME)

	if not ok or text == nil or text:find("^Missing ") ~= nil then
		return fallback
	end

	return text
end

--- The band's name in RL's own words, e.g. "Very high".
function Animals.getBandName(band)
	if band == nil then
		return "?"
	end

	return Animals.getRLText("rl_ui_genetics_" .. band.key, band.label)
end

-- ---------------------------------------------------------------------------
-- The OVERALL band — a second, separate vocabulary
-- ---------------------------------------------------------------------------

--- RL's aggregate genetics ladder, in good/bad words rather than high/low.
---
--- **RL SHIPS TWO LADDERS THAT DISAGREE, AND THIS IS THE ONE THE PLAYER READS.**
--- `Animal:showGeneticsInfo` (RealisticLivestock_Animal.lua:779-790) uses Good >= 0.65 and
--- Average >= 0.35, and it is called from exactly one place: the in-world HUD box when you
--- look at an animal (RealisticLivestock_PlayerHUDUpdater.lua:129).
---
--- `Animal:addGeneticsInfo` (:914-926) uses **Good >= 0.60 and Average >= 0.40**, and THREE
--- UI paths read it — AnimalInfoDialog.lua:599, RealisticLivestock_AnimalScreen.lua:1911 and
--- the tabbed menu via RLGeneticsFormatter.lua:53
--- (`OVERALL_TIER_THRESHOLDS = { 0.95, 0.8, 0.6, 0.4, 0.2, 0.05 }`).
---
--- LIVESTOCK_DESIGN.md §2.1's whole justification is that the contract and RL say the SAME
--- WORD about the same animal, so it has to be the ladder the menu shows. Under the HUD
--- figures an animal RL labels "Good" at 0.62 would be rejected by a Good contract with no
--- explanation on screen — the exact trap the design exists to avoid. User ruling
--- 2026-07-30: use the menu ladder. **Do not "correct" this back to 0.65/0.35.**
Animals.OVERALL_BANDS = {
	{ threshold = 0.95, key = "extremelyGood", label = "Extremely good" },
	{ threshold = 0.80, key = "veryGood",      label = "Very good" },
	{ threshold = 0.60, key = "good",          label = "Good" },
	{ threshold = 0.40, key = "average",       label = "Average" },
	{ threshold = 0.20, key = "bad",           label = "Bad" },
	{ threshold = 0.05, key = "veryBad",       label = "Very bad" },
	{ threshold = -math.huge, key = "extremelyBad", label = "Extremely bad" },
}

--- Overall band by key, so a tier table can name a rung in words and be resolved once.
function Animals.getOverallBandByKey(key)
	if key == nil then
		return nil
	end

	for _, band in ipairs(Animals.OVERALL_BANDS) do
		if band.key == key then
			return band
		end
	end

	return nil
end

--- RL's `geneticsFactor` — the unweighted mean of every trait the animal HAS, expressed as
--- a fraction of the maximum. VERIFIED, RealisticLivestock_Animal.lua:910-913:
---
--- ```lua
--- overallGenetics = metabolism + quality + health + fertility + (productivity or 0)
--- bestGenetics    = 1.75 * (productivity ~= nil and 5 or 4)
--- ```
---
--- **A MEAN DOES NOT CARE HOW MANY DRAWS IT AVERAGES** — LIVESTOCK_DESIGN §2.3 measured the
--- band probabilities for four-trait and five-trait species and they are identical to within
--- 0.4%. The 4-vs-5 asymmetry is closed; do not reopen it.
---
--- @param excludeFertility boolean|nil drop fertility from BOTH sums. Set when the contract
---   asked for castrated stock: `AnimalCastrateEvent.lua:64` sets `fertility = 0` along with
---   `isCastrated`, which costs a five-trait animal up to 0.19 of its overall factor — enough
---   to knock a Very good bull below Good the moment the player does what the contract asked.
---   User ruling 2026-07-30: judge the band on what the buyer actually cares about, and never
---   penalise a husbandry choice the contract itself demanded.
function Animals.getOverallFactor(genetics, excludeFertility)
	if type(genetics) ~= "table" then
		return nil
	end

	local sum, count = 0, 0

	for _, trait in ipairs(Animals.TRAITS) do
		local value = genetics[trait]

		if value ~= nil and not (excludeFertility and trait == "fertility") then
			sum = sum + value
			count = count + 1
		end
	end

	if count == 0 then
		return nil
	end

	return sum / (Animals.QUALITY_MAX * count)
end

--- Slack on a band threshold, to stop floating-point error deciding a contract.
---
--- **THIS IS NOT DEFENSIVE PADDING — WITHOUT IT AN EXACTLY-ON-BAND ANIMAL FAILS.** Five traits
--- at exactly 1.40 sum to 5.6000000000000005 in doubles and divide by 7.0 to
--- **0.79999999999999993**, a hair under the 0.80 "Very good" threshold. So the player who
--- does exactly what LIVESTOCK_DESIGN §2.1 promises — *"most players are going to aim for the
--- same value in all stats"*, and §2.1's own table says all-Very-high reads Very good at
--- 100% — would be rejected by the contract, with the board and RL's info box both saying
--- Very good and no explanation anywhere on screen.
---
--- Caught by the offline harness before it ever reached play. 1e-6 is some four orders of
--- magnitude below the smallest genetic difference RL stores, so it can only ever rescue the
--- boundary case it exists for.
Animals.BAND_EPSILON = 1e-6

--- Which overall band a factor lands in.
function Animals.getOverallBand(factor)
	if factor == nil then
		return nil
	end

	for _, band in ipairs(Animals.OVERALL_BANDS) do
		if factor >= band.threshold - Animals.BAND_EPSILON then
			return band
		end
	end

	return Animals.OVERALL_BANDS[#Animals.OVERALL_BANDS]
end

--- The overall band's name in RL's own words, e.g. "Very good".
---
--- Shares `rl_ui_genetics_<key>` with the per-trait ladder because RL does — the two
--- vocabularies live in one l10n namespace and only the keys differ.
function Animals.getOverallBandName(band)
	if band == nil then
		return "?"
	end

	return Animals.getRLText("rl_ui_genetics_" .. band.key, band.label)
end

--- What this trait is called for THIS animal. Type-dependent for productivity:
--- Milk on cows, Milk or Wool on sheep by subtype, Eggs on chickens
--- (RealisticLivestock_Animal.lua:893-896).
function Animals.getTraitLabel(animal, trait)
	local fallback = Animals.TRAIT_FALLBACK[trait] or trait

	if trait ~= "productivity" then
		return Animals.getRLText(Animals.TRAIT_L10N[trait], fallback)
	end

	local typeIndex = animal ~= nil and animal.animalTypeIndex or nil

	if AnimalType ~= nil and typeIndex ~= nil then
		if typeIndex == AnimalType.COW then
			return Animals.getRLText("rl_ui_milk", "Milk")
		elseif typeIndex == AnimalType.SHEEP then
			local subType = animal.subType
			if subType == "GOAT" or subType == "RAM_GOAT" then
				return Animals.getRLText("rl_ui_milk", "Milk")
			end
			return Animals.getRLText("rl_ui_wool", "Wool")
		elseif typeIndex == AnimalType.CHICKEN then
			return Animals.getRLText("rl_ui_eggs", "Eggs")
		end
	end

	return fallback
end

-- ---------------------------------------------------------------------------
-- Age
-- ---------------------------------------------------------------------------

--- Age in WHOLE MONTHS. VERIFIED: Animal:getAge returns self.age
--- (RealisticLivestock_Animal.lua:522), which increments once per in-game period on the
--- animal's birthday (:1213-1220), and is compared directly against the subtype's
--- reproductionMinAgeMonth (:1295). At 1-day months, one month is one in-game day.
function Animals.getAgeMonths(animal)
	if animal == nil then
		return nil
	end

	-- Snapshots carry the value directly; live animals expose the accessor.
	if animal.ageMonths ~= nil then
		return animal.ageMonths
	end

	if animal.getAge ~= nil then
		local ok, age = pcall(animal.getAge, animal)
		if ok and type(age) == "number" then
			return age
		end
	end

	return nil
end

--- The species' breeding maturity in months, used as the reference an age window is
--- expressed against.
---
--- Derived per species rather than hardcoded, because a fixed "12-18 months" is sensible
--- for cattle and nonsense for chickens. `Animal:getSubType()` resolves through
--- `g_currentMission.animalSystem` (RealisticLivestock_Animal.lua:11, 1291), so it is
--- reachable on a live instance even though RL's subtype tables are not.
function Animals.getReproductionAge(animal)
	if animal == nil or animal.getSubType == nil then
		return nil
	end

	local ok, subType = pcall(animal.getSubType, animal)

	if ok and type(subType) == "table" and type(subType.reproductionMinAgeMonth) == "number"
		and subType.reproductionMinAgeMonth > 0 then
		return subType.reproductionMinAgeMonth
	end

	return nil
end

--- Sample how many months, at most, is worth looking at. Horses reach their best at 60,
--- which is the slowest species in the base data.
Animals.MAX_SAMPLE_AGE = 84

--- The earliest age at which this species is worth (near) full price — its prime.
---
--- DERIVED FROM THE GAME'S OWN PRICE CURVE, not from a table of ages. `subType.sellPrice`
--- is queried by age (`:get(age)`, RealisticLivestock_Animal.lua:1292), and the base data
--- states each species' life cycle plainly. From `data/maps/mapUS/config/animals.xml`:
---
---   dairy cow   0:150  24:2000  36:2000  60:1000   -- rises, plateaus, then declines
---   angus       0:230  24:3000  36:3500            -- rises to 36
---   pig         0:100  24:2500                     -- rises to 24
---   sheep/goat  0:100  36:1000                     -- rises to 36
---   chicken     0:2     6:25                       -- rises to 6
---   horse       0:400  36:10000  60:15000          -- rises to 60
---
--- So "prime" is the point the curve reaches its maximum, which is 6 months for a chicken
--- and 60 for a horse. A fixed "12-18 months" would be meaningless across that range;
--- this scales itself, and adapts to any map or mod that ships its own animal config.
function Animals.getPrimeAge(animal)
	if animal == nil or animal.getSubType == nil then
		return nil
	end

	local ok, subType = pcall(animal.getSubType, animal)
	if not ok or type(subType) ~= "table" then
		return Animals.getReproductionAge(animal)
	end

	return Animals.getPrimeAgeForSubType(subType)
end

--- As getPrimeAge, but from a SUBTYPE rather than a live animal.
---
--- This is the form that matters for offer generation: a contract must be offerable to a
--- farmer who owns no animals at all, so nothing here may depend on having one to sample.
function Animals.getPrimeAgeForSubType(subType)
	if type(subType) ~= "table" or subType.sellPrice == nil
		or subType.sellPrice.get == nil then
		-- Breeding maturity is the only other age reference available.
		if type(subType) == "table" and type(subType.reproductionMinAgeMonth) == "number" then
			return subType.reproductionMinAgeMonth, nil
		end
		return nil, nil
	end

	local curve = subType.sellPrice
	local best, bestAge = nil, nil
	local samples = {}

	for age = 0, Animals.MAX_SAMPLE_AGE do
		local sampled, value = pcall(curve.get, curve, age)

		if sampled and type(value) == "number" then
			samples[age] = value
			if best == nil or value > best then
				best, bestAge = value, age
			end
		end
	end

	if best == nil or best <= 0 then
		if type(subType.reproductionMinAgeMonth) == "number" then
			return subType.reproductionMinAgeMonth, nil
		end
		return nil, nil
	end

	-- The EARLIEST age within 5% of the peak, not the peak itself. On a plateau (dairy
	-- cattle hold 2000 from 24 to 36) the animal is already fully valuable at the start of
	-- it, and asking the player to hold stock through a flat stretch would be busywork.
	local primeStart, primeEnd = nil, nil

	for age = 0, Animals.MAX_SAMPLE_AGE do
		if samples[age] ~= nil and samples[age] >= best * 0.95 then
			if primeStart == nil then
				primeStart = age
			end
			primeEnd = age
		elseif primeStart ~= nil then
			-- Value has fallen away and will not recover: the prime is over. This is the
			-- dairy-cow case (2000 at 24-36, 1000 by 60) and it is deliberately kept —
			-- a declining species means the player must watch their stock and sell in the
			-- window, rather than breeding once and harvesting whenever convenient.
			break
		end
	end

	if primeStart == nil then
		return bestAge, nil
	end

	-- A prime running to the end of the sample never actually declines (pigs, sheep,
	-- chickens, beef cattle all hold their top value), so there is no upper bound to
	-- impose — those species are forgiving by nature and should stay that way.
	if primeEnd ~= nil and primeEnd >= Animals.MAX_SAMPLE_AGE then
		primeEnd = nil
	end

	return primeStart, primeEnd
end

--- Every breed on this map that a farmer could realistically build a line in.
---
--- Enumerated from the base game's own registry (`g_currentMission.animalSystem.subTypes`,
--- AnimalSystem.lua:15, 425) rather than from the player's herd, because **a livestock
--- contract must be offerable to someone who owns no animals at all.** That is the point of
--- the bottom rung: it names a species and invites the farmer to decide whether to build
--- the infrastructure and get into breeding.
---
--- Filtered to subtypes that can reproduce and have a price curve — that drops roosters
--- (no breeding age) and anything without a sale value, neither of which could sustain a
--- breeding contract.
function Animals:getBreedableSubTypes()
	local result = {}
	local system = g_currentMission.animalSystem

	if system == nil or system.subTypes == nil then
		return result
	end

	for _, subType in ipairs(system.subTypes) do
		if type(subType) == "table"
			and subType.supportsReproduction
			and subType.sellPrice ~= nil
			and subType.name ~= nil then
			table.insert(result, subType)
		end
	end

	return result
end

--- Which traits this subtype's animals carry.
---
--- `productivity` exists only on types that produce something — milk, wool, eggs — and RL
--- displays it only for cows, sheep and chickens (RealisticLivestock_Animal.lua:893-896).
--- Asking for a productivity floor on a pig would be an unsatisfiable contract.
function Animals.getTraitsForSubType(subType)
	local traits = { "metabolism", "health", "fertility", "quality" }

	local typeIndex = type(subType) == "table" and subType.typeIndex or nil

	if AnimalType ~= nil and typeIndex ~= nil
		and (typeIndex == AnimalType.COW or typeIndex == AnimalType.SHEEP
			or typeIndex == AnimalType.CHICKEN) then
		table.insert(traits, "productivity")
	end

	return traits
end

--- Typical sale value of this breed at its prime, with no herd required.
---
--- Derived from the game's own price curve, so it is the standard value for the species
--- rather than an average of whatever the player happens to own. Genetics variation then
--- shows up naturally in what each individual animal actually fetches at the dealer.
function Animals.getPrimeValueForSubType(subType, primeAge)
	if type(subType) ~= "table" or subType.sellPrice == nil or subType.sellPrice.get == nil then
		return nil
	end

	local ok, value = pcall(subType.sellPrice.get, subType.sellPrice, primeAge or 0)

	if ok and type(value) == "number" and value > 0 then
		return value
	end

	return nil
end

--- RL's hard bounds on a genetics trait. VERIFIED against two independent places in RL:
--- the dealer rolls `math.clamp(math.random(mod - 300, mod + 300) / 1000, 0.25, 1.75)`
--- (RealisticLivestock_AnimalSystem.lua:1525) and inheritance clamps to the same range by
--- default (BreedingMath.lua:143-144). 0.25 is therefore the worst animal that can exist,
--- not merely the worst commonly seen.
--- How long removals keep accumulating into one pending sale, in ms.
---
--- RL removes animals and books the money synchronously in a single call, so every cluster
--- flush belonging to one sale lands in the same frame. This only has to be wide enough to
--- span that, and narrow enough that an unrelated death minutes later starts a fresh batch.
Animals.SALE_BATCH_WINDOW_MS = 250

Animals.QUALITY_MIN = 0.25
Animals.QUALITY_MAX = 1.75

--- What an animal of this breed, this age and this genetic quality is actually worth at
--- RL's dealer — as opposed to the raw price curve, which is only RL's starting point.
---
--- PORT OF `Animal:getSellPrice` (RealisticLivestock_Animal.lua:1290-1315) and, for horses,
--- `AnimalHorse.getHorseSellPrice` (AnimalHorse.lua:153). Read from RL rather than guessed,
--- because the curve value alone is not the sale price and using it understated the spread
--- between a poor animal and a good one — which is the number every livestock balance
--- constant rests on.
---
--- **Only `genetics.quality` moves the price.** Fertility, metabolism and health-as-a-trait
--- do not appear in the formula at all; they matter to breeding and husbandry, not to what
--- the dealer pays. That is worth knowing before any balance figure is set against them.
---
--- Assumptions, all stated because none of them is observable from a subtype alone:
---   * weight == `subType.targetWeight` — a well-kept mature animal
---   * health 1.0, not pregnant, not lactating, not castrated, no disease
---   * horses untrained and clean (riding 0, fitness 0, dirt 0), which is their FLOOR;
---     a trained horse is worth up to ~60% more through the same expression
---
--- So this is the value of a well-kept animal with nothing else going for it but its
--- genetics — the right anchor for pricing a contract, and deliberately not the best case.
--- @param condition number|nil RL's weightFactor. Omit for an animal at full target weight.
function Animals.getSellPriceForSubType(subType, age, quality, condition)
	if type(subType) ~= "table" or subType.sellPrice == nil or subType.sellPrice.get == nil then
		return nil
	end

	local ok, base = pcall(subType.sellPrice.get, subType.sellPrice, age or 0)
	if not ok or type(base) ~= "number" or base <= 0 then
		return nil
	end

	quality = quality or 1.0

	local targetWeight = subType.targetWeight
	local minWeight = subType.minWeight

	-- Without the weight fields the genetics terms still apply; only the weight factor is
	-- unavailable. Degrade to the quality-adjusted price rather than returning nothing.
	if type(targetWeight) ~= "number" or targetWeight <= 0 or type(minWeight) ~= "number"
		or targetWeight <= minWeight then
		return base + base * 0.25 * (quality - 1)
	end

	-- :1296-1300. Past breeding age the age term saturates, so the expected weight for age
	-- settles at 85% of the mature gain. A mature animal at target weight therefore sits
	-- ABOVE it, which is why this factor is greater than 1.
	local expectedWeight = (targetWeight - minWeight) * 0.85

	-- `condition` IS RL's weightFactor — the same number Animals.getConditionFactor returns
	-- and the same one the contract's minCondition is stated in. Omitting it prices an animal
	-- at full target weight, which is what this function has always assumed and what the
	-- 20-animal validation in §0.6 was measured against. **Do not change the default.**
	--
	-- Passing it lets a contract be priced at the condition its stated FEED can actually
	-- produce: RL grows an animal at `math.min(foodFactor * 1.25, 1)` of full rate
	-- (RealisticLivestock_Animal.lua:1145), so a grass-fed cow at foodFactor 0.40 grows at
	-- half speed and is genuinely worth less at the dealer. The contract that asked only for
	-- grass must pay accordingly, or it would be pricing an animal it never required.
	local weightFactor = condition or (1 + (targetWeight - expectedWeight) / expectedWeight)

	-- :1304 then :1306. RL scales the second term by weight/targetWeight. At the default
	-- condition this ratio is exactly 1 and the term reduces to the flat 0.6 coefficient the
	-- validated port used, so nothing moves unless a condition is passed.
	local weightRatio = weightFactor * expectedWeight / targetWeight

	local price = base + base * 0.25 * (quality - 1)
	price = math.max(price + price * 0.6 * weightRatio * (quality - 1), 0.5)

	if Animals.isHorseSubType(subType) then
		-- AnimalHorse.lua:153. Quality is applied a SECOND time here, on top of the two
		-- terms above — which is why horses have a far steeper genetics spread than any
		-- other animal. Untrained and clean is the floor of the training bracket.
		return math.max(price * quality * weightFactor * (0.3 + 0.5 * 1.0), price * 0.05)
	end

	-- :1313-1315, at full health and neither pregnant nor lactating.
	return math.max(price * 0.6 + price * 0.4 * weightFactor * 0.75, price * 0.05)
end

-- ---------------------------------------------------------------------------
-- GROWTH, PEAK AGE AND THE BAND ANCHOR
-- ---------------------------------------------------------------------------
--
-- getSellPriceForSubType above prices an animal ALREADY AT its target weight. That is the
-- right anchor for a mature animal and it is validated against 20 live ones (HANDOFF §0.6),
-- but it cannot answer "at what age is this animal worth most", because it has no idea how
-- heavy the animal is at a given age. Everything in this section exists to supply that.
--
-- IT IS A PORT, NOT A MODEL OF OUR OWN. `Animal:updateWeight`
-- (RealisticLivestock_Animal.lua:1135-1160) is integrated forward from `minWeight` exactly as
-- RL runs it, and the result is fed through the same `Animal:getSellPrice` expression.
--
-- **VALIDATED against LIVESTOCK_DESIGN §3.2's anchor ladder, which this reproduces to the
-- pound**: Angus 2547/3135/4204/5328/6768, Limousin 2699/3320/4444/5629/7147, Pig Landrace
-- 954/1216/1554/2006/2609, Chicken 17/21/28/36/47, Horse 1682/3561/7353/11353/16933. If a
-- change here stops reproducing those figures, the change is wrong.

--- The individual's own target weight. `:195` verbatim — metabolism scales it, which is the
--- entire reason metabolism reaches the sale price at all (HANDOFF §0.5).
---
---   targetWeight = subType.targetWeight * (0.6 + 0.4 * metabolism)
---
--- written in RL's own algebraic form so it stays recognisable against the source.
function Animals.getTargetWeight(subType, metabolism)
	if type(subType) ~= "table" or type(subType.targetWeight) ~= "number" then
		return nil
	end

	local base = subType.targetWeight
	metabolism = metabolism or 1.0

	return base + (((base * metabolism) - base) / 2.5)
end

--- How heavy an animal of this subtype is at each age, integrated hour by hour.
---
--- Returns a 0..MAX_SAMPLE_AGE array of weights, plus the target weight it is climbing to.
---
--- **THE HOURLY STEP IS NOT PEDANTRY.** RL applies a decay of `(weight - target) / (met * 25)`
--- PER HOUR once the animal is over its target, so a well-fed animal settles slightly ABOVE
--- target at the point growth and decay balance rather than clamping to it. Closed-form
--- integration with a hard cap understates a mature animal by 3-5%, rising with metabolism —
--- which is exactly the residual that stopped an earlier reconstruction reproducing §3.2.
---
--- `daysPerPeriod` is read live. Growth per MONTH is invariant to it (RL divides the hourly
--- increase by `24 * daysPerPeriod` and there are `24 * daysPerPeriod` hours in a month), but
--- the decay term is not — so a player on 3-day months genuinely grows animals that overshoot
--- less and are genuinely worth a little less. The contract should price what that player can
--- actually produce, not what a 1-day-month player can.
---
--- Assumes full feed (`foodFactor = 1`, so the `math.min(foodFactor * 1.25, 1)` term is 1),
--- not lactating, and health irrelevant — weight and health are separate in RL.
function Animals.getWeightCurve(subType, metabolism, isCastrated)
	if type(subType) ~= "table" then
		return nil, nil
	end

	local minWeight = subType.minWeight
	local breedingAge = subType.reproductionMinAgeMonth
	local target = Animals.getTargetWeight(subType, metabolism)

	if type(minWeight) ~= "number" or type(breedingAge) ~= "number" or breedingAge <= 0
		or target == nil or target <= minWeight then
		return nil, nil
	end

	metabolism = metabolism or 1.0

	-- :1141. The age at which growth is expected to have completed.
	local adultMonth = breedingAge * 1.5

	local environment = g_currentMission ~= nil and g_currentMission.environment or nil
	local daysPerPeriod = 1

	if environment ~= nil and type(environment.daysPerPeriod) == "number"
		and environment.daysPerPeriod > 0 then
		daysPerPeriod = environment.daysPerPeriod
	end

	local hoursPerMonth = 24 * daysPerPeriod

	-- :1143. Male growth is 1.0 against the female 0.6 — the single biggest reason males
	-- outsell females across every species (ANIMAL_RESEARCH §6).
	local genderFactor = (subType.gender == "male") and 1.0 or 0.6
	local castrationFactor = isCastrated and 1.15 or 1.0

	local baseIncrease = ((target - minWeight) / adultMonth) / hoursPerMonth
	local weight = minWeight
	local curve = {}

	for month = 0, Animals.MAX_SAMPLE_AGE do
		curve[month] = weight

		for hour = 1, hoursPerMonth do
			local age = month + hour / hoursPerMonth
			local increase = baseIncrease * genderFactor * (1 + ((adultMonth - age) / 75))

			-- :1146. Past `adultMonth + 75` the term goes negative and RL INVERTS the
			-- metabolism multiplier, so a high-metabolism animal wastes away faster than a
			-- low-metabolism one. Kept because it is what the game does.
			if increase < 0 then
				increase = increase * (1 + (1 - metabolism))
			else
				increase = increase * metabolism
			end

			increase = increase * castrationFactor

			local decrease = 0
			if weight > target then
				decrease = (weight - target) / (metabolism * 25)
			end

			weight = math.max(weight + increase - decrease, 0.001)
		end
	end

	return curve, target
end

--- What an animal of this subtype is worth at a GIVEN AGE, weight included.
---
--- The same `Animal:getSellPrice` expression as `getSellPriceForSubType`, but taking the
--- animal's modelled weight at that age rather than assuming it is grown. Both must agree on
--- a mature animal; this one is the only form that can be asked about a young one.
---
--- @param weight number the animal's weight at `age`, from `getWeightCurve`
--- @param target number the animal's own target weight, from the same call
function Animals.getPriceAtAge(subType, age, quality, weight, target, isCastrated)
	if type(subType) ~= "table" or subType.sellPrice == nil or subType.sellPrice.get == nil then
		return nil
	end

	local ok, base = pcall(subType.sellPrice.get, subType.sellPrice, math.max(age or 0, 0))
	if not ok or type(base) ~= "number" or base <= 0 then
		return nil
	end

	local minWeight = subType.minWeight
	local subTypeWeight = subType.targetWeight
	local breedingAge = subType.reproductionMinAgeMonth

	if type(minWeight) ~= "number" or type(subTypeWeight) ~= "number"
		or type(breedingAge) ~= "number" or breedingAge <= 0
		or type(weight) ~= "number" or type(target) ~= "number" then
		return nil
	end

	quality = quality or 1.0

	-- :1295-1297. Note this reads the ANIMAL's target weight and the line below reads the
	-- SUBTYPE's — two different weights, one line apart, and conflating them was a real bug
	-- (HANDOFF §0.6).
	local adultMonth = breedingAge * 1.5
	local expected = ((target - minWeight) / adultMonth)
		* math.min(math.max(age or 0, 0) + 1.5, adultMonth) * 0.85

	if expected <= 0 then
		return nil
	end

	local weightFactor = weight / expected

	-- :1302-1304.
	local price = base + base * 0.25 * (quality - 1)
	price = math.max(price + ((price * 0.6) / subTypeWeight) * weight * (quality - 1), 0.5)

	-- :1306. RL applies this BEFORE the health/weight stage, so it compounds rather than
	-- being a flat 15% on the final figure.
	if isCastrated then
		price = price * 1.15
	end

	if Animals.isHorseSubType(subType) then
		-- AnimalHorse.lua:153, at the untrained and clean floor (riding 0, fitness 0,
		-- dirt 0), which is 0.3 + 0.5 * health. See getSellPriceForSubType for why the
		-- training terms are deliberately not modelled.
		return math.max(price * quality * weightFactor * 0.8, price * 0.05)
	end

	-- :1313-1315, at full health and neither pregnant nor lactating.
	return math.max(price * 0.6 + price * 0.4 * weightFactor * 0.75, price * 0.05)
end

--- The age at which this subtype is actually worth the most.
---
--- **PEAK IS NOT PRIME AND getPrimeAgeForSubType MUST NOT BE REPURPOSED.** Prime is the 95%
--- crossing of the raw `sellPrice` CURVE and is validated against RL's own figures (horse 47,
--- chicken 6, sheep 35, pig 23). Peak is the argmax of the REALISED price, which includes
--- weight — and for two species the gap is severe (ANIMAL_RESEARCH §9):
---
---   * a chicken's curve tops out at 6 months and is flat forever after, so the curve argmax
---     is 6 — but the bird keeps GAINING WEIGHT, and its realised value climbs to 19.
---   * a stallion's curve rises monotonically to 60, so the curve argmax is 60 — but male
---     growth at 1.0 puts him at target weight long before that, after which
---     `targetWeightForAge` keeps climbing and `weightFactor` erodes.
---
--- **Computed at metabolism 1.0 and quality 1.0, ONE age per subtype.** Peak genuinely moves
--- with genetics — a chicken's runs 9 to 19 across the rungs — but pricing every band at a
--- single age is what `LIVESTOCK_DESIGN` §3.1's anchor does, and it is what reproduces §3.2
--- exactly. A window that slid up the ladder would also be unpredictable to the player.
---
--- Derived rather than tabulated, so a map or animal mod adding a species classifies itself.
--- Supersedes §2.4's written table, which recorded one band's answer as though it were fixed:
--- this returns goat 42, chicken 19 and stallion 36 where that table says 36, 15 and 29.
--- User ruling 2026-07-30. Cattle 36, pig 24, sheep 36 and mare 60 are unchanged.
function Animals.getPeakAge(subType)
	if type(subType) ~= "table" or subType.name == nil then
		return nil
	end

	Animals.peakAgeCache = Animals.peakAgeCache or {}

	local cached = Animals.peakAgeCache[subType.name]
	if cached ~= nil then
		return cached.age, cached.value
	end

	local curve, target = Animals.getWeightCurve(subType, 1.0, false)

	if curve == nil then
		-- Without weight data the curve argmax is the only answer available. It is the wrong
		-- number for chickens and stallions, but a wrong age beats no contract at all.
		local age = Animals.getPrimeAgeForSubType(subType)
		Animals.peakAgeCache[subType.name] = { age = age, value = nil }
		return age, nil
	end

	local bestAge, bestValue = nil, nil

	for age = 0, Animals.MAX_SAMPLE_AGE do
		local value = Animals.getPriceAtAge(subType, age, 1.0, curve[age], target, false)

		if value ~= nil and (bestValue == nil or value > bestValue) then
			bestAge, bestValue = age, value
		end
	end

	Animals.peakAgeCache[subType.name] = { age = bestAge, value = bestValue }

	return bestAge, bestValue
end

--- What a contract should pay per head for an animal sitting exactly on a rung's band.
---
--- LIVESTOCK_DESIGN §3.1. **The anchor animal has every trait at `1.75 * overallBandFactor`,
--- with quality raised to its own band floor if that is higher.** Concretely, on the menu
--- ladder this mod now uses:
---
---   | rung | overall factor | traits at | quality at |
---   | 1    | 0.20           | 0.350     | 0.70 (floor binds) |
---   | 2    | 0.40           | 0.700     | 0.90 (floor binds) |
---   | 3    | 0.60           | 1.050     | 1.10 (floor binds) |
---   | 4a   | 0.80           | 1.400     | 1.40 |
---   | 4b   | 0.95           | 1.6625    | 1.6625 |
---
--- **THIS IS NOT THE THEORETICAL WORST ANIMAL THAT WOULD CLEAR THE SPEC, AND THAT WAS
--- DELIBERATE.** §3.1 abandoned the theoretical worst — quality 1.10 with metabolism bred
--- down to 0.25 — because rungs 1 to 3 then differed by only 18%, and because the strategy is
--- reachable from RL's source but not from playing the game. Do not reinstate it.
---
--- Priced at `getPeakAge`, at full feed, with the subtype's own gender.
---
--- @param overallFactor number the rung's band threshold, e.g. 0.60 for Good
--- @param qualityFloor number the rung's per-trait quality band, e.g. 1.10 for High
--- @param age number|nil override the age; defaults to peak
function Animals.getBandAnchorValue(subType, overallFactor, qualityFloor, age, isCastrated)
	if type(subType) ~= "table" or type(overallFactor) ~= "number" then
		return nil
	end

	local traitValue = Animals.QUALITY_MAX * overallFactor
	local quality = math.max(traitValue, qualityFloor or 0)

	-- Metabolism IS the trait value: the anchor animal sits on the band in everything, and
	-- metabolism is the trait that drives the weight curve.
	local curve, target = Animals.getWeightCurve(subType, traitValue, isCastrated)

	if age == nil then
		age = Animals.getPeakAge(subType)
	end

	if curve == nil or age == nil then
		-- Degrade to the grown-animal price rather than refusing to quote.
		return Animals.getSellPriceForSubType(subType, age, quality)
	end

	return Animals.getPriceAtAge(subType, age, quality, curve[age], target, isCastrated)
end

--- How many offspring one breeding female of this species yields in a year.
---
--- This is the mod's measure of EFFORT, as distinct from money. A contract for 45 pigs and
--- one for 30 cattle cost the same in cash and nothing like the same in farm: the pig
--- contract is about two sows, the cattle contract is a twenty-five-cow herd.
---
--- VERIFIED, and it settles a design question §4.6 got backwards. RL's
--- `generateRandomOffspring` (AnimalReproduction.lua:637) makes better animals produce
--- MORE offspring, not fewer — `fertility` gates conception outright, and
--- `factor = 0.75 + fertility / 4` widens the litter draw. Fertility is itself inherited
--- (:538), so output compounds alongside quality. A breeder's herd grows as it improves;
--- it never shrinks. **Do not build a ladder that assumes scarcity at the top.**
---
--- `animalType.pregnancy` is RL's own extension and does not exist in the base game
--- (checked: no hits in D:\FS25_GameSource\scripts). RL is a hard dependency (§2), but this
--- degrades to a single offspring per cycle rather than erroring if it is ever absent.
function Animals.getAnnualOffspringPerFemale(subType)
	if type(subType) ~= "table" then
		return 1.0
	end

	local gestation = subType.reproductionDurationMonth
	if type(gestation) ~= "number" or gestation <= 0 then
		return 1.0
	end

	local litter = 1.0
	local system = g_currentMission ~= nil and g_currentMission.animalSystem or nil

	if system ~= nil and system.getTypeByIndex ~= nil and subType.typeIndex ~= nil then
		local ok, animalType = pcall(system.getTypeByIndex, system, subType.typeIndex)

		if ok and type(animalType) == "table" and type(animalType.pregnancy) == "table"
			and type(animalType.pregnancy.average) == "number"
			and animalType.pregnancy.average > 0 then
			litter = animalType.pregnancy.average
		end
	end

	-- THE RECOVERY PERIOD, AND LEAVING IT OUT OVERSTATED EVERY SHORT-GESTATION SPECIES.
	--
	-- This used to return `litter * (12 / gestation)` — one cycle per gestation, back to back.
	-- RL does not allow that. `AnimalReproduction.getCanReproduce` (:291) gates on
	-- `animal.monthsSinceLastBirth > 2` for any female that has already given birth, so she
	-- cannot conceive again until three months after the last litter:
	--
	--     birth -> 3 months recovery -> conceive -> `gestation` months -> birth
	--
	-- The cycle is therefore `gestation + 3`, not `gestation`. It barely touches cattle and
	-- horses, and it halves or worse the fast breeders:
	--
	--   | species | was    | actual |
	--   | chicken | 30 /yr | **12** |
	--   | pig     | 36 /yr | **21** |
	--   | sheep   | 4.8/yr | **3.0**|
	--   | cow     | 1.2/yr | 0.92   |
	--   | horse   | 1.1/yr | 0.86   |
	--
	-- Found 2026-07-30 when the user's own arithmetic for a poultry contract — 750 birds a
	-- year needs ~62 breeding hens — disagreed with this function by a factor of 2.5. **Their
	-- figure was the right one.** 750 / 12 = 62.
	--
	-- The 12/yr is still the OPTIMISTIC ceiling: it assumes a male is present and in range
	-- every time she becomes eligible (`hasMaleAnimalInPen`, same function), and that
	-- conception succeeds. For chickens conception is effectively certain up to ~5 years —
	-- `fertilityValue = fertility * (animalType.fertility:get(age) / 100)` is 0.35 x 5.0 = 1.75
	-- at the tier-1 band, and the test is `math.random() >= fertilityValue`, so it cannot fail
	-- while that product is >= 1. For slower species with lower fertility curves it can.
	--
	-- Litter size is `animalType.pregnancy.average` and is drawn exactly 75% of the time
	-- (`generateRandomOffspring`, :649 — `if math.random() >= 0.25 then return average`), so
	-- the average is very close to the realised mean.
	local RECOVERY_MONTHS = 3.0

	return litter * (12.0 / (gestation + RECOVERY_MONTHS))
end

--- How much farm a species demands, beyond the animals themselves.
---
--- The user's ranking, 2026-07-28: **chickens and sheep/goats easy, cows hard, pigs
--- extremely hard.** The reason is not the animals — it is the FEED CHAIN behind them.
--- Chickens want grain and nothing else. Pigs want grain AND root crops AND protein, each a
--- separate crop, a separate harvester and a separate store. That is hundreds of thousands
--- in equipment before a single animal is sold.
---
--- DERIVED, not tabulated, from the game's own food data
--- (`AnimalFoodSystem:getAnimalFood`, AnimalFoodSystem.lua:277) so it holds for any species
--- a map or mod adds:
---
---   * `#groups` — how many distinct food groups the species eats.
---   * `consumptionType` — and this is the lever that matters. PARALLEL requires EVERY group
---     at once (`consumeFoodParallelly`, :314), so every group is a production chain the
---     player must actually build. SERIAL eats whichever group is available (:301), so one
---     crop is enough and the others are optional variety.
---
--- Calibrated to land on the user's ranking: chicken (1 group) = 1.0, sheep (2, serial)
--- = 1.5, cow (3, serial) = 2.0, pig (4, parallel) = 4.0.
---
--- `animalFood.xml` lives inside encrypted `dataS` and cannot be read offline, so the group
--- counts above are EXPECTED rather than verified. `fcFood` prints the live data — run it
--- and correct these notes before treating this function as settled.
Animals.EFFORT_MIN = 1.0
Animals.EFFORT_MAX = 4.0

function Animals.getHusbandryEffort(subType)
	if type(subType) ~= "table" or subType.typeIndex == nil then
		return Animals.EFFORT_MIN
	end

	local mission = g_currentMission
	local foodSystem = mission ~= nil and mission.animalFoodSystem or nil

	if foodSystem == nil or foodSystem.getAnimalFood == nil then
		return Animals.EFFORT_MIN
	end

	local ok, food = pcall(foodSystem.getAnimalFood, foodSystem, subType.typeIndex)

	if not ok or type(food) ~= "table" or type(food.groups) ~= "table" then
		return Animals.EFFORT_MIN
	end

	local groups = #food.groups
	if groups <= 1 then
		return Animals.EFFORT_MIN
	end

	-- Each group beyond the first adds half a unit of effort, doubled when the species needs
	-- them all at once rather than any one of them.
	local perGroup = 0.5
	if food.consumptionType == AnimalFoodSystem.FOOD_CONSUME_TYPE_PARALLEL then
		perGroup = perGroup * 2
	end

	local effort = 1.0 + (groups - 1) * perGroup

	return math.max(Animals.EFFORT_MIN, math.min(Animals.EFFORT_MAX, effort))
end

--- Every fill type a species eats, as a set.
function Animals.getFeedFillTypes(subType)
	local result = {}

	if type(subType) ~= "table" or subType.typeIndex == nil then
		return result
	end

	local mission = g_currentMission
	local foodSystem = mission ~= nil and mission.animalFoodSystem or nil

	if foodSystem == nil or foodSystem.getAnimalFood == nil then
		return result
	end

	local ok, food = pcall(foodSystem.getAnimalFood, foodSystem, subType.typeIndex)

	if ok and type(food) == "table" and type(food.groups) == "table" then
		for _, group in ipairs(food.groups) do
			for _, fillTypeIndex in pairs(group.fillTypes or {}) do
				result[fillTypeIndex] = true
			end
		end
	end

	return result
end

--- How much of `candidate`'s feed the farm is ALREADY set up to produce, given the species
--- it keeps. 0 means a wholly new supply chain; 1 means everything it eats is grown here.
---
--- This is the mod's answer to a suggestion the user made on 2026-07-29, and it replaces
--- a purely random invitation with an argued one. Their example: *"You already have a very
--- good chicken operation. They eat grain and you feed them yourself — why not look at
--- horses? They eat oats, the same infrastructure as wheat or barley, and need straw, so you
--- could expand into them without much trouble."*
---
--- The alternative — a random species the player has no setup for — invites the absurd
--- version, a chicken farmer told to take up pigs with no root-crop chain at all.
---
--- DERIVED from the game's own food groups, so it holds for any species a map or mod adds
--- and needs no table of our own.
--- The equipment categories that plant a crop, and those that harvest it.
---
--- **Growing a crop takes BOTH, and the two are independent.** Wheat, barley, oat and canola
--- are sown with a SOWINGMACHINE; sorghum, maize, soybean, sunflower and sugar beet need a
--- PLANTER; carrots, parsnips and beetroot a PLANTER_SMALL. Potatoes have dedicated kit of
--- their own and appear in no category at all, which is correct — the user, 2026-07-29:
--- *"Potatoes have their own planters and harvesters. They are basically a specialty crop."*
---
--- This is the dimension the first two versions of the affinity measure both missed. The
--- user's correction: *"Wheat and oats need a seeder, sorghum needs a planter."* Chickens eat
--- wheat, barley AND sorghum — so treating "chickens eat sorghum" as evidence the farm could
--- grow sorghum was wrong. What the farm proved by feeding WHEAT is a seeder, and a seeder
--- cannot plant sorghum.
---
--- It is exactly what makes the user's original example true: a wheat-feeding chicken farm
--- can already grow **oats** (seeder + grain header, both owned) — the whole of a horse's
--- staple — but cannot grow **maize or sorghum**, which is the whole of a pig's staple.
Animals.PLANTING_CATEGORIES = { "SOWINGMACHINE", "PLANTER", "PLANTER_SMALL", "SUGARCANE_PLANTER" }
-- **MOWER IS DELIBERATELY ABSENT, AND IT USED TO BE HERE.** Bug found in play 2026-07-29:
-- feeding nothing but wheat reported `MOWER` proven, which made hay, silage and grass
-- reachable and turned every species into a crossover. `fcFeed` printed all five as "foot in
-- the door" and the label stopped meaning anything.
--
-- The cause is in the game's own data, not ours — maps_fruitTypes.xml:42 reads
-- `MOWER: GRASS WHEAT BARLEY OAT CANOLA SOYBEAN`, because a mower CAN cut standing grain
-- (the converter two lines down turns WHEAT into STRAW). So wheat legitimately sits in the
-- MOWER category and the generic loop below was right to fire.
--
-- But mowing wheat for straw is not a forage operation. The grass chain is a mower AND a
-- tedder AND a rake AND a baler, and the only honest evidence of it is having fed something
-- that could not have come from anywhere else. That inference lives in getProvenEquipment
-- against FORAGE_FEEDS, and it is now the ONLY route to a proven mower.
Animals.HARVEST_CATEGORIES = { "GRAINHEADER", "MAIZEHEADER", "DIRECTCUTTER", "TOPLIFTINGHARVESTER" }

--- [categoryName] = { [fillTypeIndex] = true }, built once from the live fruit type manager.
function Animals.getEquipmentCategories()
	if Animals.equipmentCategoryCache ~= nil then
		return Animals.equipmentCategoryCache
	end

	local cache = {}

	local function collect(name)
		local set = {}

		if g_fruitTypeManager ~= nil
			and g_fruitTypeManager.getFillTypeIndicesByFruitTypeCategoryName ~= nil then
			local ok, indices = pcall(
				g_fruitTypeManager.getFillTypeIndicesByFruitTypeCategoryName, g_fruitTypeManager, name)

			if ok and type(indices) == "table" then
				for _, fillTypeIndex in ipairs(indices) do
					set[fillTypeIndex] = true
				end
			end
		end

		cache[name] = set
	end

	for _, name in ipairs(Animals.PLANTING_CATEGORIES) do
		collect(name)
	end

	for _, name in ipairs(Animals.HARVEST_CATEGORIES) do
		collect(name)
	end

	Animals.equipmentCategoryCache = cache

	return cache
end

--- Processed and windrowed feeds that prove a FORAGE operation.
---
--- **The one place in this file that is a list rather than a derivation, and it has to be.**
--- Hay, silage, TMR and chaff are not fruit types — they are processed from grass, so they
--- appear in no `fruitTypeCategory` and nothing links them back to the machinery that made
--- them. Everything else here is read from `g_fruitTypeManager`.
---
--- The user's ruling, 2026-07-29: *"If a farmer has sheep or cows then they obviously have
--- the means to do grass work. The system can just assume this and link appropriately."*
--- Quite right — a farm with cattle is mowing, tedding, raking and baling by definition,
--- whether or not we watched it happen. Assuming it is more accurate than refusing to.
---
--- Kept as fill type NAMES so a map that renames an index cannot break it.
Animals.FORAGE_FEEDS = {
	"GRASS_WINDROW", "DRYGRASS_WINDROW", "SILAGE", "CHAFF", "FORAGE", "FORAGE_MIXING", "STRAW",
}

--- Which equipment categories a farm has PROVEN it owns, by having fed the crops they make.
---
--- Feeding wheat proves a seeder and a grain header. Feeding hay or silage proves the grass
--- chain — a mower at minimum, and in practice the tedder, rake and baler behind it.
function Animals.getProvenEquipment(fedFillTypes)
	local categories = Animals.getEquipmentCategories()
	local proven = {}

	for name, fillTypes in pairs(categories) do
		for fillTypeIndex in pairs(fedFillTypes or {}) do
			if fillTypes[fillTypeIndex] then
				proven[name] = true
				break
			end
		end
	end

	-- Anything out of a forage chain proves the forage chain, since nothing else could have
	-- produced it. This is what lets a cattle or sheep farm count as equipped for hay without
	-- ever having been observed cutting a field.
	for _, name in ipairs(Animals.FORAGE_FEEDS) do
		local index = g_fillTypeManager:getFillTypeIndexByName(name)

		if index ~= nil and (fedFillTypes or {})[index] then
			proven["MOWER"] = true
			break
		end
	end

	return proven
end

--- Can this farm grow this crop with equipment it has already proven?
---
--- Needs BOTH halves: something that plants it and something that harvests it. A crop in no
--- category at all — potatoes — is never reachable, which is the conservative and correct
--- reading for a specialty crop with dedicated machinery.
function Animals.canGrow(fillTypeIndex, proven)
	local categories = Animals.getEquipmentCategories()

	-- Forage feeds are MADE, not grown, so they belong to no planting or harvest category.
	-- A proven mower is the whole qualification: a farm that cuts grass can make hay, and
	-- that is what puts horses within reach of a cattle or sheep farm.
	for _, name in ipairs(Animals.FORAGE_FEEDS) do
		if g_fillTypeManager:getFillTypeIndexByName(name) == fillTypeIndex then
			return proven["MOWER"] == true
		end
	end

	local function anyOwned(names)
		for _, name in ipairs(names) do
			if proven[name] and categories[name][fillTypeIndex] then
				return true
			end
		end

		return false
	end

	return anyOwned(Animals.PLANTING_CATEGORIES) and anyOwned(Animals.HARVEST_CATEGORIES)
end

--- What the farm can demonstrably already produce: everything it has ever fed, plus
--- everything its current animals eat.
---
--- The ledger is the stronger half. Feeding wheat proves a combine and a way to move grain;
--- feeding hay proves a mower, tedder, rake and baler. What animals a farm happens to own
--- proves much less — stock can be bought, inherited, or fed from purchased feed.
function Animals.getFarmFeedCapability(farmId, keptSubTypes)
	local have = {}

	local ledger = ForwardContracts ~= nil and ForwardContracts.feedLedger or nil
	if ledger ~= nil and farmId ~= nil then
		for fillTypeIndex in pairs(ledger:getFedFillTypes(farmId)) do
			have[fillTypeIndex] = true
		end
	end

	for _, kept in ipairs(keptSubTypes or {}) do
		for fillTypeIndex in pairs(Animals.getFeedFillTypes(kept)) do
			have[fillTypeIndex] = true
		end
	end

	return have
end

--- How much of a head start the farm has on feeding `candidate`.
---
--- **DELIBERATELY LOOSE.** An earlier version scored the fraction of a species' feed the farm
--- already produced, and it was too absolute — the user's correction, 2026-07-29:
---
---   *"This doesn't mean we have everything for horses, it just means we are not starting
---   from net zero and there is a crossover between chickens and horses in equipment we
---   already own. Don't think too absolute — the idea is there is a LINK between them, not a
---   full-blown chain that matches species to species."*
---
--- So this asks a softer question: **of the food groups this species eats, how many contain
--- something the farm can already produce?** One group in three is a real foot in the door
--- and scores 0.33, even though two whole chains are still missing.
---
--- Serial species need only ONE group satisfied to be fed at all (`consumeFoodSerially`,
--- AnimalFoodSystem.lua:301), so any overlap at all is most of the battle and scores high.
--- Parallel species need every group (`:314`), so partial overlap is genuinely partial.
--- Does this farm have a foot in the door with this species — anything at all?
---
--- **BINARY, AND DELIBERATELY SO.** An earlier version scored the fraction of a species' diet
--- the farm could already produce and used it to weight the draw. The user's ruling,
--- 2026-07-29, and it removed a whole layer of machinery:
---
---   *"I don't want anything favoured. Recommendations are not favoured, simply offered
---   because you already have a foot in the door. The script should not discriminate based
---   on percentage of this. It is a straight 50-50."*
---
--- If you keep sheep you can make grass and hay, so cows AND horses both become sensible
--- things to be offered — equally. Neither is more recommended; both are simply viable, and
--- which one suits the farm is the player's judgement, not the mod's.
---
--- Any crossover counts, however small. A farm that grows only carrots has a real if thin
--- link to pigs, and **it is the player's job to notice how thin it is.** The mod offers the
--- opportunity; researching whether it is a good one is the farming.
function Animals.hasFeedCrossover(candidate, keptSubTypes, farmId)
	if type(candidate) ~= "table" or candidate.typeIndex == nil then
		return false
	end

	local have = Animals.getFarmFeedCapability(farmId, keptSubTypes)
	local proven = Animals.getProvenEquipment(have)

	for fillTypeIndex in pairs(Animals.getFeedFillTypes(candidate)) do
		if have[fillTypeIndex] or Animals.canGrow(fillTypeIndex, proven) then
			return true
		end
	end

	return false
end

--- Retained for diagnostics only (`fcFeed`). NOTHING in offer generation may use this —
--- see hasFeedCrossover for why weighting by it was removed.
function Animals.getFeedAffinity(candidate, keptSubTypes, farmId)
	if type(candidate) ~= "table" or candidate.typeIndex == nil then
		return 0
	end

	local mission = g_currentMission
	local foodSystem = mission ~= nil and mission.animalFoodSystem or nil

	if foodSystem == nil or foodSystem.getAnimalFood == nil then
		return 0
	end

	local ok, food = pcall(foodSystem.getAnimalFood, foodSystem, candidate.typeIndex)

	if not ok or type(food) ~= "table" or type(food.groups) ~= "table" or #food.groups == 0 then
		return 0
	end

	local have = Animals.getFarmFeedCapability(farmId, keptSubTypes)
	local proven = Animals.getProvenEquipment(have)

	-- WEIGHTED BY `productionWeight`, NOT BY GROUP COUNT.
	--
	-- Groups are wildly unequal: root crops are 5% of both a pig's and a horse's output, while
	-- a horse's oats are 57%. Counting groups equally made a 5% side dish look like a third of
	-- the problem.
	--
	-- Production weight rather than `eatWeight` (ration share) — the user's example is the
	-- argument. A horse's hay is 71% of the volume but only 38% of the output; the oats are
	-- 24% of the volume and 57% of the output. "Can I grow the staple" is the question a
	-- farmer actually asks, and the staple is defined by what it contributes, not by how many
	-- litres it takes to shovel.
	local covered, total = 0, 0

	for _, group in ipairs(food.groups) do
		local weight = group.productionWeight or 0
		total = total + weight

		for _, fillTypeIndex in pairs(group.fillTypes or {}) do
			-- Either the farm already produces this exact crop, or it owns the equipment to
			-- plant AND harvest it. The second is the point: a wheat farmer has never grown
			-- oats but plainly could.
			if have[fillTypeIndex] or Animals.canGrow(fillTypeIndex, proven) then
				covered = covered + weight
				break
			end
		end
	end

	if total <= 0 or covered <= 0 then
		return 0
	end

	local fraction = covered / total

	-- A serial eater is fed the moment ONE group is covered (consumeFoodSerially,
	-- AnimalFoodSystem.lua:301), so partial cover is nearly the whole story. A parallel eater
	-- needs every group (:314), so partial really is partial.
	if food.consumptionType ~= AnimalFoodSystem.FOOD_CONSUME_TYPE_PARALLEL then
		return math.min(1.0, 0.7 + 0.3 * fraction)
	end

	return fraction
end

--- The overlap in plain words, for the offer panel. Nil when there is nothing to say.
function Animals.describeFeedAffinity(candidate, keptSubTypes, farmId)
	local affinity = Animals.getFeedAffinity(candidate, keptSubTypes, farmId)

	if affinity <= 0 then
		return nil
	end

	local wanted = Animals.getFeedFillTypes(candidate)
	local have = Animals.getFarmFeedCapability(farmId, keptSubTypes)

	-- Name the crops the farm can already put in the ground, since that is the concrete
	-- reason this species is a small step rather than a new venture. Includes crops never
	-- grown but plainly growable with the equipment already proven — a wheat farmer has
	-- never sown oats, and that is exactly the suggestion worth making.
	local proven = Animals.getProvenEquipment(have)
	local names = {}

	for fillTypeIndex in pairs(wanted) do
		if have[fillTypeIndex] or Animals.canGrow(fillTypeIndex, proven) then
			local title = g_fillTypeManager:getFillTypeTitleByIndex(fillTypeIndex)
			if title ~= nil then
				table.insert(names, title)
			end
		end
	end

	if #names == 0 then
		return nil
	end

	table.sort(names)

	local list = #names == 1 and names[1]
		or (table.concat(names, ", ", 1, #names - 1) .. " and " .. names[#names])

	if affinity >= 0.99 then
		return string.format(
			"They eat %s — everything you already grow for your own stock. No new crop, no new machinery.",
			list)
	end

	return string.format(
		"They eat %s, which you already grow for your own stock, so this is an expansion rather than a fresh start.",
		list)
end

-- ---------------------------------------------------------------------------
-- CLASSIFICATION — meat animal or job animal, and what each one produces
-- ---------------------------------------------------------------------------

--- The fill type this subtype produces, and the curve giving its daily yield by age.
---
--- VERIFIED, AnimalSystem.lua:279-288 in the base game (RL wraps this loader rather than
--- replacing it): a subtype carries `output.milk` and/or `output.pallets`, each
--- `{ fillType = index, curve = AnimCurve }`. Manure and liquid manure are plain curves with
--- no fill type and are deliberately ignored — every animal makes muck, so it classifies
--- nothing.
---
--- Reading it this way means milk→cattle, wool→sheep, eggs→chickens, goat milk→goats and
--- buffalo milk→water buffalo all fall out of `animals.xml`, and **an animal mod adding a
--- producing species registers itself** (LIVESTOCK_DESIGN §5.4).
function Animals.getProductOutput(subType)
	if type(subType) ~= "table" or type(subType.output) ~= "table" then
		return nil, nil
	end

	for _, slot in ipairs({ "milk", "pallets" }) do
		local entry = subType.output[slot]

		if type(entry) == "table" and entry.fillType ~= nil and entry.curve ~= nil then
			return entry.fillType, entry.curve
		end
	end

	return nil, nil
end

--- What one DAY of this animal's output is worth at its best, at the fill type's market price.
---
--- VERIFIED that the curve is a per-DAY rate, not per hour: `PlaceableHusbandryMilk`
--- (D:\FS25_GameSource\scripts\animals\husbandry\placeables\PlaceableHusbandryMilk.lua:164-166)
--- reads `litersPerDay = milk.curve:get(age) * cluster:getNumAnimals()` and only then divides
--- by 24 to get its hourly rate.
---
--- **PEAK DAILY YIELD, NOT A LIFETIME INTEGRAL, AND THAT IS THE WHOLE POINT.** A lifetime
--- figure has to pick a horizon, and the horizon is a balance knob wearing a measurement's
--- clothes: wool holds 85 l/day flat forever, so choosing 144 months over 120 moves every
--- sheep's score by 20% and can flip a breed across the line. Peak daily yield needs no
--- horizon, needs no `daysPerPeriod`, and answers the same question.
---
--- Used only to CLASSIFY (see isJobAnimal). It is deliberately NOT a pricing input: RL never
--- pays it, because `AnimalItemNew:getPrice` is the animal's own sell price plus 7.5% and the
--- `buyPrice` curve is not used at all (LIVESTOCK_DESIGN §1.8). A dairy heifer is anchored on
--- the same sale price as everything else, so the 5-15x lifetime product value never enters.
function Animals.getPeakDailyProductValue(subType)
	local fillTypeIndex, curve = Animals.getProductOutput(subType)

	if fillTypeIndex == nil or curve == nil or curve.get == nil then
		return 0
	end

	local fillType = g_fillTypeManager ~= nil
		and g_fillTypeManager:getFillTypeByIndex(fillTypeIndex) or nil

	local pricePerLiter = type(fillType) == "table" and fillType.pricePerLiter or nil

	if type(pricePerLiter) ~= "number" or pricePerLiter <= 0 then
		return 0
	end

	local best = 0

	for age = 0, Animals.MAX_SAMPLE_AGE * 2 do
		local ok, rate = pcall(curve.get, curve, age)

		if ok and type(rate) == "number" and rate > best then
			best = rate
		end
	end

	return best * pricePerLiter
end

--- How many days of output it takes to equal the carcass, below which the animal is kept
--- for its JOB rather than for itself.
---
--- **THE GAP IN THE MEASURED DATA IS EMPTY BETWEEN 30 AND 23 DAYS**, and 25 sits inside it
--- with ~20% clearance either side. Highland is the fastest-paying meat animal at 30 days;
--- Ram Swiss Mountain the slowest-paying job animal at 23.
Animals.JOB_ANIMAL_PAYBACK_DAYS = 25

--- Animal TYPES that take SUPPLY contracts however their output scores.
---
--- **THIS IS A RULING, NOT A DERIVATION, AND IT IS THE ONLY ONE IN THIS FILE.** Everything
--- else here classifies itself from the game's data; this does not, and saying so plainly is
--- the point.
---
--- The payback rule is SCALE-BLIND, and for poultry that breaks it. A hen's carcass is worth
--- £24, so five eggs a day pays it back in 4.4 days and she scores as a job animal more
--- emphatically than a Holstein does. By the letter of §1.2's rule she IS one.
---
--- LIVESTOCK_DESIGN §1.2 rules chickens are meat animals, and its stated reason — *"eggs are a
--- `<pallets fillType="EGG">` output, not a priced liquid, so the ratio is 0"* — is simply
--- wrong: EGG carries `pricePerLiter` 1.12, and §5.2 says so itself while counting WOOL, also
--- a pallet output, for every sheep in the same table. **Do not repair §1.2 by reinstating
--- that reason.** The ruling stands; the reason given for it does not.
---
--- User ruling 2026-07-30, resolving the contradiction: poultry is a meat-and-eggs species.
--- Chickens take SUPPLY contracts (§4.6's ~1,780 birds at tier 4) and EGG PRODUCT contracts,
--- and never BREEDING. PRODUCT eligibility is a separate test (§5.3/§5.4) that this does not
--- touch, so nothing here costs poultry its egg contracts.
Animals.SUPPLY_ONLY_TYPES = { CHICKEN = true }

--- Is this animal kept to DO something, or to be sold as an animal?
---
--- ```
--- paybackDays = peak sale value / peak daily product value
--- job animal   = paybackDays < JOB_ANIMAL_PAYBACK_DAYS
--- ```
---
--- **DERIVED, AND IT REPRODUCES THE USER'S OWN LIST WITHOUT BEING TOLD IT.** They said
--- *"Limousin, Angus and highland are the main beef cattle in game. All other cattle are dairy
--- cows"*, and cutting at the empty gap gives exactly that:
---
---   | Limousin 40d, Angus 33d, Highland 30d          | MEAT |
---   | --- gap --- |
---   | Ram Swiss Mtn 23d, Swiss Mtn 20d, Hereford 15d | JOB  |
---   | Waterbuffalo 14d, Steinschaf 14d, Goat 14d     | JOB  |
---   | Swiss Brown 13d, Holstein 9d, Landrace 7d      | JOB  |
---
--- The point of deriving it is that a map or animal mod adding a breed classifies itself and
--- we never maintain a list. Same rule that fixed the feed affinity and the species weighting.
---
--- A job animal gets BREEDING and PRODUCT contracts; a meat animal gets SUPPLY (§1.1). Pigs
--- and horses have no output at all, so they never pay back and are always meat.
---
--- **MALES WITH NO OUTPUT ARE MEAT ANIMALS**, including bulls of dairy breeds. That is correct
--- rather than an oversight — you cannot milk a bull, `animals.xml` gives him no `<milk>`
--- block, and §1.5's "BREEDING cattle is female only" falls out of it for free. Sheep are the
--- exception worth knowing: rams DO carry a `<pallets fillType="WOOL">` block, so a ram
--- classifies as a job animal exactly as a ewe does — and is then excluded from BREEDING
--- anyway by `supportsReproduction`, which RL sets false on every male.
function Animals.isJobAnimal(subType)
	if type(subType) ~= "table" then
		return false
	end

	local system = g_currentMission ~= nil and g_currentMission.animalSystem or nil
	local typeName = system ~= nil and subType.typeIndex ~= nil and system.typeIndexToName ~= nil
		and system.typeIndexToName[subType.typeIndex] or nil

	if typeName ~= nil and Animals.SUPPLY_ONLY_TYPES[tostring(typeName):upper()] then
		return false
	end

	local dailyValue = Animals.getPeakDailyProductValue(subType)

	if dailyValue <= 0 then
		return false
	end

	local _, peakValue = Animals.getPeakAge(subType)

	if type(peakValue) ~= "number" or peakValue <= 0 then
		return false
	end

	return (peakValue / dailyValue) < Animals.JOB_ANIMAL_PAYBACK_DAYS
end

--- Peak LITRES A DAY one animal of this fill type's best producer makes.
---
--- The counterpart of getPeakDailyProductValue with the price taken back out, because
--- `Offers.getLitresPerAnimalYear` needs the volume rather than the money. Static and
--- price-free, so it does not move when the economy does.
---
--- The BEST producer, not an average: a contract naming MILK is judgeable against the herd
--- a player would actually keep for it, and stating the figure for the worst dairy breed on
--- the map would understate every sensible herd.
---
--- Curves are per DAY — `PlaceableHusbandryPallets.lua:239` and
--- `PlaceableHusbandryFood.lua:509` both take `litersPerDay` and divide by 24.
function Animals.getPeakOutputPerDay(fillTypeIndex)
	if fillTypeIndex == nil then
		return 0
	end

	local system = g_currentMission ~= nil and g_currentMission.animalSystem or nil

	if system == nil or system.subTypes == nil then
		return 0
	end

	local best = 0

	for _, subType in ipairs(system.subTypes) do
		local produced, curve = Animals.getProductOutput(subType)

		if produced == fillTypeIndex and curve ~= nil and curve.get ~= nil then
			for age = 0, Animals.MAX_SAMPLE_AGE * 2 do
				local ok, rate = pcall(curve.get, curve, age)

				if ok and type(rate) == "number" and rate > best then
					best = rate
				end
			end
		end
	end

	return best
end

--- Every subtype that produces this fill type, for gating PRODUCT offers.
function Animals:getProducingSubTypes(fillTypeIndex)
	local result = {}

	if fillTypeIndex == nil then
		return result
	end

	local system = g_currentMission ~= nil and g_currentMission.animalSystem or nil

	if system == nil or system.subTypes == nil then
		return result
	end

	for _, subType in ipairs(system.subTypes) do
		local produced = Animals.getProductOutput(subType)

		if produced == fillTypeIndex then
			table.insert(result, subType)
		end
	end

	return result
end

-- ---------------------------------------------------------------------------
-- PRODUCT contracts — what a farm can actually MAKE
-- ---------------------------------------------------------------------------

--- Every fill type any animal on this map produces, as a set.
---
--- The mod had **no capability check anywhere** before this. `Offers:getSellableFillTypes`
--- admits every fill type any non-train selling station buys, which already included MILK,
--- WOOL, EGG, GOATMILK and BUFFALOMILK — so the board could offer a dairy contract to a farm
--- with no cattle. The file header promised *"never offer something the map cannot sell"*; it
--- validated the DESTINATION and never asked whether the farm could MAKE the thing.
---
--- Harmless for crops — you can buy a field — and not harmless for milk.
function Animals.getAllProductFillTypes()
	if Animals.productFillTypeCache ~= nil then
		return Animals.productFillTypeCache
	end

	local result = {}
	local system = g_currentMission ~= nil and g_currentMission.animalSystem or nil

	if system == nil or system.subTypes == nil then
		return result
	end

	for _, subType in ipairs(system.subTypes) do
		local fillTypeIndex = Animals.getProductOutput(subType)

		if fillTypeIndex ~= nil then
			result[fillTypeIndex] = true
		end
	end

	Animals.productFillTypeCache = result

	return result
end

-- **THERE IS NO CAPABILITY GATE ON PRODUCT CONTRACTS, AND THERE MUST NOT BE ONE.**
--
-- `keepsProducerOf`, `canSupplyProduct`, `getKeptSubTypesFor` and `getAnnualProduction` were
-- built here on 2026-07-30 and removed the same day. They gated a milk contract on whether the
-- farm already kept cattle, and fed a "your herd produces about X a year" warning to the board.
--
-- User ruling, reversing their own §5.3 and §5.5: *"This mod is supposed to offer opportunities
-- and it is up to the user to research if they can meet the requirements for the opportunities.
-- If they sign and fail they get punished."*
--
-- **ONLY ANIMAL contracts are gated**, by feed crossover, because building a species' whole
-- feed chain is a genuine barrier to entry. A field can be bought and a factory can be built,
-- so crops, animal products and production goods are all offered freely.
--
-- `getAllProductFillTypes` above stays: it LABELS a product offer as produce, which is a fact
-- about the contract. It does not decide whether the player may see it.

--- The age at which this subtype can first breed — where a BREEDING contract's window opens.
---
--- **NOT PRIME AND NOT PEAK.** LIVESTOCK_DESIGN §2.4: "prime" is a carcass-value concept, so
--- timing a dairy heifer by it means timing her by how good she would be as beef, which is the
--- one thing her buyer explicitly does not care about. A breeding window runs UP FROM this
--- age, because the buyer is paying for the productive years ahead of her.
function Animals.getBreedingAge(subType)
	if type(subType) ~= "table" or type(subType.reproductionMinAgeMonth) ~= "number"
		or subType.reproductionMinAgeMonth <= 0 then
		return nil
	end

	return subType.reproductionMinAgeMonth
end

--- The age at which this SPECIES is grown, taken from whichever of its subtypes can breed.
---
--- **NOT `subType.reproductionMinAgeMonth` — THAT IS THE WRONG NUMBER FOR MALES.** A male's
--- figure is when he may SIRE, not when he is mature, and the two diverge badly:
---
---   | species | female | male |
---   | horse   | **22** | **36** |
---   | pig     | 6      | 8    |
---   | sheep   | 8      | 5    |
---   | cow     | 12     | 12   |
---
--- A stallion's 36 is also his peak age, so using it as the floor of a SUPPLY window collapsed
--- that window to the two-month minimum — a tier-3 stallion contract read "34 to 36 months",
--- which is a flip rather than a husbandry job. Seen on the board 2026-07-30.
---
--- The female's figure is the honest marker of when the species is a finished animal, it is
--- gender-neutral, and it is what RL itself uses to decide the species has grown up. Horses are
--- the only case where this changes anything: their window becomes 24-36 at tier 3, and RL's own
--- `averageBuyAge` for horses is 24 — so the player buys a yearling and raises it for a year.
function Animals.getSpeciesBreedingAge(subType)
	if type(subType) ~= "table" then
		return nil
	end

	local system = g_currentMission ~= nil and g_currentMission.animalSystem or nil

	if system == nil or system.subTypes == nil or subType.typeIndex == nil then
		return Animals.getBreedingAge(subType)
	end

	local best

	for _, candidate in ipairs(system.subTypes) do
		if candidate.typeIndex == subType.typeIndex
			and candidate.supportsReproduction
			and type(candidate.reproductionMinAgeMonth) == "number"
			and candidate.reproductionMinAgeMonth > 0
			and (best == nil or candidate.reproductionMinAgeMonth < best) then
			best = candidate.reproductionMinAgeMonth
		end
	end

	return best or Animals.getBreedingAge(subType)
end

--- Does this species cost the player real time EVERY DAY, per animal?
---
--- VERIFIED, and derived rather than named. `AnimalClusterHorse`
--- (D:\FS25_GameSource\scripts\animals\husbandry\cluster\AnimalClusterHorse.lua:10-12) adds
--- exactly three fields over the standard `AnimalCluster` — `fitness`, `riding` and `dirt` —
--- and those are precisely the three terms in `AnimalHorse.getHorseSellPrice`. They are
--- per-animal state that only moves through player ACTION, and no other species has any of it.
--- `xml/animals.xml` declares the class per animal type, and RL honours it
--- (RealisticLivestock_AnimalSystem.lua:346).
---
--- **The rule: a species whose animal type declares a non-default cluster class carries
--- per-animal daily labour.** A mod adding another rideable species must declare its own
--- cluster class too, so it is caught automatically.
---
--- LIVESTOCK_DESIGN §4.5: **it is a FLAG, not a divisor.** `getHusbandryEffort` measures
--- INFRASTRUCTURE — a fixed cost of entry — and cannot see labour that scales with headcount.
--- The answer is the hard cap on head, not a multiplier. Detect the flag, apply the cap.
function Animals.hasPerAnimalLabour(subType)
	if type(subType) ~= "table" or subType.typeIndex == nil then
		return false
	end

	local system = g_currentMission ~= nil and g_currentMission.animalSystem or nil

	if system == nil or system.getTypeByIndex == nil then
		return false
	end

	local ok, animalType = pcall(system.getTypeByIndex, system, subType.typeIndex)

	if not ok or type(animalType) ~= "table" or animalType.clusterClass == nil then
		return false
	end

	return animalType.clusterClass ~= AnimalCluster
end

--- Every subtype a contract of this kind may name.
---
--- **MALE AND FEMALE ARE SEPARATE SUBTYPES IN RL, NOT A FLAG ON ONE.** `xml/animals.xml`
--- ships `COW_ANGUS` and `BULL_ANGUS` as distinct entries with their own weights and price
--- curves — 24 female and 24 male in all. So the contract states gender simply by naming the
--- subtype, and LIVESTOCK_DESIGN §1.5's "headcount adjusts so the two are worth roughly the
--- same" needs no machinery at all: a bull is worth 10-35% more, and headcount is derived from
--- money (§4.1), so the count falls out.
---
--- **EVERY MALE SUBTYPE CARRIES `<reproduction supported="false"/>`**, which is why
--- `getBreedableSubTypes` excluded all of them and why no male contract has ever been
--- offerable. That is right for BREEDING — you cannot supply breeding stock the game says
--- cannot breed — and wrong for SUPPLY, where a bull calf is the natural product of a cow
--- herd. User ruling 2026-07-30: admit males to SUPPLY only.
---
--- @param kind string "SUPPLY", "BREEDING" or nil for the old breedable-only set
function Animals:getContractableSubTypes(kind)
	local result = {}
	local system = g_currentMission ~= nil and g_currentMission.animalSystem or nil

	if system == nil or system.subTypes == nil then
		return result
	end

	for _, subType in ipairs(system.subTypes) do
		if type(subType) == "table" and subType.sellPrice ~= nil and subType.name ~= nil then
			local admissible

			if kind == "SUPPLY" then
				-- Meat animals of either gender. A job animal is never SUPPLIED (§1.1), but
				-- its MALES score 0 on the product ratio and so are meat animals in their own
				-- right — a Holstein bull is beef, and correctly contractable as such.
				admissible = not Animals.isJobAnimal(subType)
			elseif kind == "BREEDING" then
				-- Job animals that can actually reproduce, which excludes every male.
				admissible = subType.supportsReproduction and Animals.isJobAnimal(subType)
			else
				admissible = subType.supportsReproduction
			end

			if admissible then
				table.insert(result, subType)
			end
		end
	end

	return result
end

--- Horses price through a different expression, so they have to be told apart.
---
--- Matched on the animal TYPE name rather than the breed, because RL ships eight horse
--- breeds and any of them could be renamed by another mod.
function Animals.isHorseSubType(subType)
	if type(subType) ~= "table" then
		return false
	end

	local system = g_currentMission ~= nil and g_currentMission.animalSystem or nil

	if system ~= nil and subType.typeIndex ~= nil and system.typeIndexToName ~= nil then
		local typeName = system.typeIndexToName[subType.typeIndex]
		if typeName ~= nil then
			return tostring(typeName):upper() == "HORSE"
		end
	end

	return false
end

--- A subtype's display name, from its own fill type — already localised by the base game.
function Animals.getSubTypeBreedName(subType)
	if type(subType) ~= "table" then
		return "?"
	end

	if subType.fillTypeIndex ~= nil then
		local title = g_fillTypeManager:getFillTypeTitleByIndex(subType.fillTypeIndex)
		if title ~= nil then
			return title
		end
	end

	return subType.name or "?"
end

--- A breed's display name, e.g. "Angus".
---
--- `subType.fillTypeIndex` gives the breed its own fill type, whose title is already
--- localised by the base game — so this needs no l10n of our own and reads correctly in
--- any language.
function Animals.getBreedName(animal)
	if animal == nil or animal.getSubType == nil then
		return animal ~= nil and animal.subType or "?"
	end

	local ok, subType = pcall(animal.getSubType, animal)

	if ok and type(subType) == "table" and subType.fillTypeIndex ~= nil then
		local title = g_fillTypeManager:getFillTypeTitleByIndex(subType.fillTypeIndex)
		if title ~= nil then
			return title
		end
	end

	return animal.subType or "?"
end

--- Resolve a subtype from the name a contract stored.
function Animals.getSubTypeByName(name)
	if name == nil then
		return nil
	end

	local system = g_currentMission.animalSystem
	if system == nil or system.getSubTypeByName == nil then
		return nil
	end

	local ok, subType = pcall(system.getSubTypeByName, system, name)

	if ok and type(subType) == "table" then
		return subType
	end

	return nil
end

--- The whole requirement in one sentence — breed, age window and genetic floors.
---
--- Resolved from the SPEC rather than from a sampled animal, so it reads correctly for a
--- farmer who owns none of the breed. That is the normal case for a bottom-tier offer,
--- which exists precisely to invite someone into a species they do not yet keep.
function Animals:describeSpec(spec)
	if spec == nil then
		return "Any animal from your herd."
	end

	local subType = Animals.getSubTypeByName(spec.subTypeName)
	local parts = {}

	if subType ~= nil then
		table.insert(parts, Animals.getSubTypeBreedName(subType))
	end

	local age = Animals.describeAgeWindow(spec)
	if age ~= nil then
		table.insert(parts, age)
	end

	-- THE GENETIC REQUIREMENT, AND LEAVING IT OUT WAS A TRAP RATHER THAN AN OMISSION.
	--
	-- The rebuild replaced `traitFloors` with `overallBand` / `qualityFloor` / `prodFertFloor`,
	-- and this function still only read the old field — so the board showed breed, age and feed
	-- and **said nothing about genetics at all**, while `meetsSpec` went on enforcing them. A
	-- player would sign, deliver, and have animals rejected on a requirement never stated.
	-- Caught 2026-07-30 from a screenshot of a live tier-3 stallion offer.
	--
	-- Same principle this file already applies to the condition clause: an unstated requirement
	-- that fails a delivery is a trap rather than a contract.
	--
	-- **BOTH SCALES IN RL'S OWN WORDS** (§2.1). Overall uses the aggregate vocabulary
	-- (Bad/Average/Good/Very good/Extremely good); a single trait uses Low/Average/High/Very
	-- high/Extremely high. Saying each in its own scale is what makes the contract and RL's info
	-- box agree about the same animal.
	local genetics = Animals.describeGeneticSpec(spec, subType)
	if genetics ~= nil then
		table.insert(parts, genetics)
	end

	-- Castration is stated because it is a stated REQUIREMENT the player must act on, and RL
	-- pays 15% for it. Gender needs no clause — RL ships males and females as separate subtypes,
	-- so the breed name above already reads "Landrace Boar" or "Chestnut Stallion".
	if spec.requiresCastrated ~= nil then
		table.insert(parts, spec.requiresCastrated and "castrated" or "not castrated")
	end

	local floors = self:describeFloorsForSubType(spec.traitFloors, subType)
	if floors ~= nil then
		table.insert(parts, floors)
	end

	-- The condition clause must appear, because it is the one requirement the player cannot
	-- satisfy by shopping — it is earned by feeding the animal properly for its whole life,
	-- and an unstated requirement that fails a delivery is a trap rather than a contract.
	local condition = Animals.describeCondition(spec, subType)
	if condition ~= nil then
		table.insert(parts, condition)
	end

	if #parts == 0 then
		return "Any animal from your herd."
	end

	return table.concat(parts, ", ") .. "."
end

--- The growth rate RL actually achieves on a feed of this production weight.
---
--- VERIFIED, RealisticLivestock_Animal.lua:1145:
---
--- ```lua
--- increase = baseIncrease * genderFactor * ageFactor * math.min(foodFactor * 1.25, 1)
--- ```
---
--- **There is a hard shoulder at 0.80.** Any feed at or above 80% production weight grows the
--- animal at full speed; below that it falls away linearly. Weight drives RL's `weightFactor`,
--- which is exactly what this mod calls condition and what the contract checks.
---
--- The consequence, against the measured `fcFood` ladder: a cow's TMR (100), hay (80) and
--- silage (80) are IDENTICAL in the animal's eyes, and only grass (40) is genuinely poorer at
--- half the growth rate. The contract still names all four, because the player is entitled to
--- know which one was asked for — but the three that behave alike are priced alike, and any
--- other treatment would be inventing a difference the game does not make.
function Animals.getGrowthRateForProduction(productionWeight)
	return math.min((productionWeight or 0) * 1.25, 1)
end

--- Every feed group this species can be offered a contract against.
---
--- Serial eaters choose ONE group and are fed by it alone (`consumeFoodSerially`,
--- AnimalFoodSystem.lua:301), so each group is a genuine alternative specification.
---
--- Parallel eaters need every group at once (`:314`), so there is nothing to choose: the
--- specification is the whole ration and the only honest growth rate is the full one. Returns
--- a single entry covering the lot.
function Animals.getFeedOptions(subType)
	if type(subType) ~= "table" or subType.typeIndex == nil then
		return {}
	end

	local mission = g_currentMission
	local foodSystem = mission ~= nil and mission.animalFoodSystem or nil

	if foodSystem == nil or foodSystem.getAnimalFood == nil then
		return {}
	end

	local ok, food = pcall(foodSystem.getAnimalFood, foodSystem, subType.typeIndex)

	if not ok or type(food) ~= "table" or type(food.groups) ~= "table" or #food.groups == 0 then
		return {}
	end

	local function describe(group)
		local names = {}

		for _, fillTypeIndex in pairs(group.fillTypes or {}) do
			local fillType = g_fillTypeManager:getFillTypeByIndex(fillTypeIndex)

			if fillType ~= nil and fillType.title ~= nil then
				table.insert(names, fillType.title)
			end
		end

		table.sort(names)

		return names
	end

	-- A PARALLEL eater needs EVERY group at once, so there is no group to choose between — but
	-- listing every fill type of every group produces nonsense. A pig contract read:
	--
	--   "kept on Maize, Sorghum, Barley, Wheat, OSR, Soybeans, Sunflowers, Carrots, Parsnips,
	--    Potatoes, Red Beet and Sugar Beet"
	--
	-- which is twelve crops and states no actual ration. **ONE FOOD FROM EACH GROUP** is the
	-- honest shape of the requirement: a concrete ration the player can go and produce.
	--
	-- The game is more lenient than this — `consumeFoodParallelly` (AnimalFoodSystem.lua:314) is
	-- satisfied by ANY fill type within each group, so a pig fed sorghum instead of maize still
	-- eats. The contract names one anyway, and the user's ruling is that discovering the latitude
	-- is the player's business: *"up to the user to discover this does NOT necessarily get tracked
	-- this way."*
	if food.consumptionType == AnimalFoodSystem.FOOD_CONSUME_TYPE_PARALLEL then
		local names = {}

		for _, group in ipairs(food.groups) do
			local options = describe(group)

			if #options > 0 then
				-- **THE FIRST, NOT A RANDOM ONE.** `describe` sorts alphabetically, so this is
				-- stable: two offers for the same species now name the same example ration.
				--
				-- It used to pick at random per group, which re-rolled between offers — one
				-- stallion contract read "Sorghum, Hay and Carrots" and the next "Sorghum, Hay
				-- and Red Beet". Since `feedName` is persisted at signing, a contract then stated
				-- one interchangeable crop as though it were the requirement, for its whole term.
				--
				-- A parallel eater needs SOMETHING from every group and does not care which, so
				-- these are examples and `describeFeedOption` now says so in as many words.
				table.insert(names, options[1])
			end
		end

		return { { names = names, growth = 1, parallel = true } }
	end

	local options = {}

	for _, group in ipairs(food.groups) do
		local names = describe(group)

		if #names > 0 then
			table.insert(options, {
				names = names,
				growth = Animals.getGrowthRateForProduction(group.productionWeight),
			})
		end
	end

	return options
end

--- Name a feed option the way the contract states it — explicitly, never "or better".
---
--- User ruling, 2026-07-29: *"Explicitly state food type. The contract value and per head
--- value of the contract is then calculated at that. If the user opts for better feed that is
--- on them. They won't get better prices."*
function Animals.describeFeedOption(option)
	if type(option) ~= "table" or type(option.names) ~= "table" or #option.names == 0 then
		return nil
	end

	local names = option.names

	if #names == 1 then
		return names[1]
	end

	-- Within a SERIAL group the fill types are alternatives — a chicken group holds Wheat,
	-- Barley and Sorghum and any one of them feeds the bird. A PARALLEL species needs all of
	-- them, so the conjunction has to change or the contract would read as a choice when it
	-- is a shopping list.
	local joiner = option.parallel and " and " or " or "
	local list = table.concat(names, ", ", 1, #names - 1) .. joiner .. names[#names]

	-- SERIAL eaters genuinely choose ONE group and are fed by it alone, so "Grass or Hay" is an
	-- exact statement of the contract's terms and the alternatives are real.
	if not option.parallel then
		return list
	end

	-- PARALLEL eaters have no choice: they need every group at once, and any crop WITHIN a group
	-- serves. Naming one per group is the right length — listing them all gave pigs a wall of
	-- twelve crop names — but stating them bare implied those exact crops were required, which
	-- they never were. **"including" is doing real work**: it tells the player which production
	-- chains they must build without overstating the specification.
	return "a full ration including " .. list
end

--- The best feed this species can be given, named in the player's own vocabulary.
---
--- **DERIVED, because the alternative was wrong in play.** Until 2026-07-29 the condition
--- clause said "a full mixed ration" for every species at the top condition band, and a
--- CHICKEN contract duly demanded one. Chickens eat wheat, barley and sorghum; total mixed
--- ration is a cow feed and nothing else touches it. The requirement named an action the
--- player could not take.
---
--- The ladder is read from `productionWeight`, which §0.9 established IS the effectiveness
--- scale — it is the percentage the husbandry panel itself shows. The highest-weighted group
--- is therefore the best feed by the game's own reckoning, for any species including ones
--- this mod has never seen.
---
--- Returns nil for a PARALLEL eater, deliberately. A pig needs every group at once
--- (`consumeFoodParallelly`, AnimalFoodSystem.lua:314), so naming its best single group
--- would tell the player to do a fraction of what the contract actually requires.
function Animals.describeBestFeed(subType)
	if type(subType) ~= "table" or subType.typeIndex == nil then
		return nil
	end

	local mission = g_currentMission
	local foodSystem = mission ~= nil and mission.animalFoodSystem or nil

	if foodSystem == nil or foodSystem.getAnimalFood == nil then
		return nil
	end

	local ok, food = pcall(foodSystem.getAnimalFood, foodSystem, subType.typeIndex)

	if not ok or type(food) ~= "table" or type(food.groups) ~= "table" or #food.groups == 0 then
		return nil
	end

	if food.consumptionType == AnimalFoodSystem.FOOD_CONSUME_TYPE_PARALLEL then
		return nil
	end

	local best

	for _, group in ipairs(food.groups) do
		if best == nil or (group.productionWeight or 0) > (best.productionWeight or 0) then
			best = group
		end
	end

	if best == nil then
		return nil
	end

	local names = {}

	for _, fillTypeIndex in pairs(best.fillTypes or {}) do
		local fillType = g_fillTypeManager:getFillTypeByIndex(fillTypeIndex)

		if fillType ~= nil and fillType.title ~= nil then
			table.insert(names, fillType.title)
		end
	end

	-- Sorted so the same group always reads the same way; `fillTypes` is a plain table and
	-- its order is not guaranteed between loads.
	table.sort(names)

	if #names == 0 then
		return nil
	elseif #names == 1 then
		return names[1]
	end

	return table.concat(names, ", ", 1, #names - 1) .. " or " .. names[#names]
end

--- The condition requirement in plain words rather than as a ratio.
---
--- Deliberately phrased as husbandry ("well fed", "on a full ration") rather than as a
--- number, because that is the action the player has to take. The underlying figure is RL's
--- weightFactor and means nothing to anyone who has not read `getSellPrice`.
function Animals.describeCondition(spec, subType)
	if spec == nil then
		return nil
	end

	local condition = spec.minCondition
	if condition == nil then
		return nil
	end

	-- THE CONTRACT'S OWN FEED, named exactly as it was rolled. Never "or better" — the player
	-- may feed better and will not be paid more for it, and saying "or better" would imply
	-- the contract cared.
	--
	-- Falls back to the species' best feed for contracts signed before feeds were stated, and
	-- to wording that names no feed at all when even that is unavailable.
	local feed = spec.feedName or Animals.describeBestFeed(subType)

	if feed ~= nil then
		return string.format("kept on %s, and never left short", feed)
	end

	if condition >= 1.05 then
		-- Parallel eaters and anything we could not read land here. "Every part of their
		-- ration" is the honest phrasing for a pig, which needs all four groups at once.
		return "in prime condition — every part of their ration, never left short"
	elseif condition >= 0.95 then
		return "well fed and in good condition"
	end

	return "fed and kept in fair condition"
end

--- The genetic requirement in RL's own vocabulary, for whichever contract type this is.
---
--- SUPPLY states TWO numbers and both must appear (§2.2): the overall band, and the separate
--- floor on quality — which RL's own UI calls "Meat". One without the other is not the spec.
--- The user's wording is the model: *"'Good overall, and at least Good meat quality' absolutely
--- YES."*
---
--- BREEDING states productivity and fertility, and the productivity label is TYPE-DEPENDENT —
--- Milk on cows, Wool or Milk on sheep by subtype, Eggs on chickens — so it resolves through
--- `getTraitLabelForSubType` rather than being spelled.
function Animals.describeGeneticSpec(spec, subType)
	if spec == nil then
		return nil
	end

	if spec.prodFertFloor ~= nil then
		local band = Animals.getBandName(Animals.getBand(spec.prodFertFloor))
		local product = Animals.getTraitLabelForSubType(subType, "productivity")
		local fertility = Animals.getTraitLabelForSubType(subType, "fertility")

		return string.format("at least %s in both %s and %s", band, product, fertility)
	end

	if spec.overallBand == nil and spec.qualityFloor == nil then
		return nil
	end

	local parts = {}

	if spec.overallBand ~= nil then
		local band = Animals.getOverallBandName(Animals.getOverallBand(spec.overallBand))
		table.insert(parts, string.format("%s overall genetics", band))
	end

	if spec.qualityFloor ~= nil then
		local band = Animals.getBandName(Animals.getBand(spec.qualityFloor))
		local label = Animals.getTraitLabelForSubType(subType, Animals.TRAIT_QUALITY)
		table.insert(parts, string.format("at least %s %s", band, label))
	end

	return table.concat(parts, " and ")
end

--- Floor clause only, phrased for a subtype rather than a live animal.
function Animals:describeFloorsForSubType(floors, subType)
	if floors == nil or next(floors) == nil then
		return nil
	end

	local byBand, order = {}, {}

	for _, trait in ipairs(Animals.TRAITS) do
		local floor = floors[trait]
		if floor ~= nil then
			local name = Animals.getBandName(Animals.getBand(floor, trait))

			if byBand[name] == nil then
				byBand[name] = {}
				table.insert(order, name)
			end

			table.insert(byBand[name], Animals.getTraitLabelForSubType(subType, trait))
		end
	end

	local parts = {}

	for _, bandName in ipairs(order) do
		local traits = byBand[bandName]
		local list = #traits == 1 and traits[1]
			or (table.concat(traits, ", ", 1, #traits - 1) .. " and " .. traits[#traits])

		table.insert(parts, string.format("minimum %s in %s", bandName, list))
	end

	return table.concat(parts, "; ")
end

--- Trait display name from a subtype, mirroring getTraitLabel's animal-based form.
function Animals.getTraitLabelForSubType(subType, trait)
	local fallback = Animals.TRAIT_FALLBACK[trait] or trait

	if trait ~= "productivity" then
		return Animals.getRLText(Animals.TRAIT_L10N[trait], fallback)
	end

	local typeIndex = type(subType) == "table" and subType.typeIndex or nil

	if AnimalType ~= nil and typeIndex ~= nil then
		if typeIndex == AnimalType.COW then
			return Animals.getRLText("rl_ui_milk", "Milk")
		elseif typeIndex == AnimalType.SHEEP then
			local name = type(subType.name) == "string" and subType.name or ""
			if name:find("GOAT") ~= nil then
				return Animals.getRLText("rl_ui_milk", "Milk")
			end
			return Animals.getRLText("rl_ui_wool", "Wool")
		elseif typeIndex == AnimalType.CHICKEN then
			return Animals.getRLText("rl_ui_eggs", "Eggs")
		end
	end

	return fallback
end

--- The contract's age window in words, for the board.
function Animals.describeAgeWindow(spec)
	if spec == nil or (spec.ageMin == nil and spec.ageMax == nil) then
		return nil
	end

	if spec.ageMin ~= nil and spec.ageMax ~= nil then
		return string.format("aged %d to %d months", spec.ageMin, spec.ageMax)
	end

	if spec.ageMin ~= nil then
		return string.format("aged %d months or older", spec.ageMin)
	end

	return string.format("aged %d months or younger", spec.ageMax)
end

-- ---------------------------------------------------------------------------
-- Eligibility
-- ---------------------------------------------------------------------------

--- Does this animal clear every floor the contract sets?
---
--- PER-TRAIT, never the aggregate (HANDOFF §4.6). RL's geneticsFactor sums the traits and
--- divides by the max (§5.2), so an animal can read "very good" overall while carrying one
--- weak trait — high metabolism and quality, poor fertility. That defeats the fiction of
--- being a top-tier breeder, so every named trait must clear on its own.
---
--- A floor naming a trait this animal does not have (productivity on a type without it)
--- FAILS rather than passing silently. Offers must not set such a floor in the first
--- place, but a contract signed before a herd changed type should not become trivially
--- satisfiable.
---
--- Accepts either a LIVE animal or one of our snapshots — both expose `.genetics` with the
--- same field names, and Settlement necessarily judges after the animal is gone.
---
--- `spec` is anything carrying `traitFloors`, `ageMin` and `ageMax` — a contract or an
--- offer both qualify, so callers pass the whole record rather than unpacking it.
---
--- AGE IS A HARD GATE and is checked first, because it is the one an animal can fail
--- through inaction: an animal that ages past the window is lost to the contract whatever
--- its genetics. That is the point of the window (it stops prize stock being hoarded
--- indefinitely) and it is also the failure the UI most needs to explain.
---
--- Returns: eligible, failureReason, failureValue
function Animals:meetsSpec(animal, spec)
	if animal == nil then
		return false, nil, nil
	end

	if spec == nil then
		return true, nil, nil
	end

	-- Breed is checked first: it is the flattest, cheapest test and the one the player can
	-- see at a glance. A top-tier contract names a line ("Angus at 24-28 months, every
	-- trait Very high"), so an animal of the wrong breed is simply not the product.
	if spec.subTypeName ~= nil and animal.subType ~= spec.subTypeName then
		return false, "wrongBreed", animal.subType
	end

	-- GENDER. Almost always redundant — male and female are separate subtypes in RL, so
	-- `wrongBreed` above has usually caught it already — but a contract that names a species
	-- without pinning the breed (horses, §1.3) still has to be able to say "stallions".
	if spec.gender ~= nil and animal.gender ~= nil and animal.gender ~= spec.gender then
		return false, "wrongGender", animal.gender
	end

	-- CASTRATION, both ways round. RL pays +15% for a castrated animal
	-- (RealisticLivestock_Animal.lua:1306), so a buyer who wants one and a buyer who does not
	-- are asking for genuinely different goods and the contract priced whichever it named.
	if spec.requiresCastrated ~= nil and animal.isCastrated ~= nil then
		local castrated = animal.isCastrated == true

		if spec.requiresCastrated and not castrated then
			return false, "notCastrated", castrated
		elseif not spec.requiresCastrated and castrated then
			return false, "castrated", castrated
		end
	end

	-- PREGNANT AND LACTATING ARE ALWAYS REFUSED (§1.6), whatever the contract says, because
	-- RL pays +25% and +15% for them. Without this the player earns most by shipping the
	-- in-calf cows their own herd is built on, and the flat contract price is anchored on an
	-- animal nobody intended to buy.
	if animal.isPregnant == true then
		return false, "pregnant", true
	end

	if animal.isLactating == true then
		return false, "lactating", true
	end

	local age = Animals.getAgeMonths(animal)

	if spec.ageMin ~= nil and (age == nil or age < spec.ageMin) then
		return false, "tooYoung", age
	end

	if spec.ageMax ~= nil and (age == nil or age > spec.ageMax) then
		return false, "tooOld", age
	end

	-- CONDITION IS PART OF THE SPEC, not a bonus. Genetics say what the animal could be;
	-- condition says whether it was actually fed and kept well enough to become it. A client
	-- buying breeding stock cares about both, and without this the flat contract price would
	-- pay the same for a prize-bred animal kept on grass as for one raised properly — which
	-- would remove every reason to invest in the feed chain the tier is priced around.
	if spec.minCondition ~= nil then
		local condition = animal.conditionFactor

		-- A live animal carries no snapshot field, so derive it. Missing data passes rather
		-- than fails: a contract must never reject an animal because we could not measure it.
		if condition == nil and animal.weight ~= nil then
			condition = Animals.getConditionFactor(animal)
		end

		if condition ~= nil and condition < spec.minCondition then
			return false, "underweight", condition
		end
	end

	if spec.minHealth ~= nil then
		local health = animal.healthFactor

		if health == nil and animal.getHealthFactor ~= nil then
			local ok, factor = pcall(animal.getHealthFactor, animal)
			if ok and type(factor) == "number" then
				health = factor
			end
		end

		if health ~= nil and health < spec.minHealth then
			return false, "poorHealth", health
		end
	end

	local floors = spec.traitFloors
	local hasBandSpec = spec.overallBand ~= nil or spec.qualityFloor ~= nil
		or spec.prodFertFloor ~= nil

	if not hasBandSpec and (floors == nil or next(floors) == nil) then
		return true, nil, nil
	end

	local genetics = animal.genetics
	if genetics == nil then
		return false, nil, nil
	end

	-- THE OVERALL BAND — SUPPLY contracts. LIVESTOCK_DESIGN §1.4/§2.1: the contract states the
	-- band in RL's own overall vocabulary so it and RL say the same word about the same animal.
	--
	-- `excludeFertility` is set when the contract asked for CASTRATED stock, because castration
	-- zeroes fertility (AnimalCastrateEvent.lua:64) and would otherwise knock the animal below
	-- the very band the contract demanded. §1.5's amendment.
	if spec.overallBand ~= nil then
		local factor = Animals.getOverallFactor(genetics, spec.requiresCastrated == true)

		-- Missing data passes rather than fails, as everywhere else here.
		if factor ~= nil and factor < spec.overallBand - Animals.BAND_EPSILON then
			return false, "overallBand", factor
		end
	end

	-- THE QUALITY FLOOR — SUPPLY contracts, and it is why a supply spec states TWO numbers.
	--
	-- §2.2: overall is a MEAN, so an animal can sit at quality 0.25 and still clear "Good
	-- overall" on the strength of the other four traits. The mod prices a contract on an animal
	-- sitting ON the band and settlement counts the cheapest qualifying animals, so without
	-- this the player could systematically deliver high-overall / low-quality stock, realise
	-- less at the dealer than the flat rate, and collect the difference from the hedge —
	-- turning insurance into an income stream. Quality is also the one trait RL genuinely pays
	-- for, and RL's own UI calls it "Meat".
	if spec.qualityFloor ~= nil then
		local quality = genetics.quality

		if quality ~= nil and quality < spec.qualityFloor - Animals.BAND_EPSILON then
			return false, "quality", quality
		end
	end

	-- BREEDING contracts: `productivity` AND `fertility`, both clearing the band on their own
	-- rather than on average. §2.1, and the user's reason is the whole point of the type —
	-- *"No buyer would accept mediocre when they are looking for something so specific."*
	--
	-- Nothing else is checked. A breeding buyer does not care about meat on an animal they
	-- intend to milk or shear, so BREEDING states no quality floor and no overall band.
	if spec.prodFertFloor ~= nil then
		for _, trait in ipairs({ "productivity", "fertility" }) do
			local value = genetics[trait]

			if value ~= nil and value < spec.prodFertFloor - Animals.BAND_EPSILON then
				return false, trait, value
			end
		end
	end

	if floors == nil or next(floors) == nil then
		return true, nil, nil
	end

	-- LEGACY per-trait floors. `pickFloorTraits` no longer produces these, but contracts
	-- signed before the rebuild carry them and must keep being judged on what they agreed to.
	for trait, floor in pairs(floors) do
		local value = genetics[trait]

		if value == nil or value < floor then
			return false, trait, value
		end
	end

	return true, nil, nil
end

--- Every animal on this farm that would satisfy the contract, with the herd total for
--- context. The UI wants both — "3 of 47 qualify" tells a breeder far more than "3".
function Animals:getEligible(farmId, spec)
	local eligible = {}
	local all = self:getAnimals(farmId)

	for _, entry in ipairs(all) do
		local ok = self:meetsSpec(entry.animal, spec)
		if ok then
			table.insert(eligible, entry)
		end
	end

	return eligible, #all
end

--- Human-readable floor description, in RL's vocabulary.
--- e.g. "minimum Very high in Metabolism, Health, Fertility and Meat".
---
--- Uses a sample animal to resolve the type-dependent trait names; without one it falls
--- back to the generic labels.
function Animals:describeFloors(floors, sampleAnimal)
	if floors == nil or next(floors) == nil then
		return "No genetic requirement."
	end

	-- Group by band so the common case — one floor across every trait — reads as a single
	-- clause rather than a list repeating the same words.
	local byBand = {}
	local order = {}

	for _, trait in ipairs(Animals.TRAITS) do
		local floor = floors[trait]
		if floor ~= nil then
			local band = Animals.getBand(floor, trait)
			local name = Animals.getBandName(band)

			if byBand[name] == nil then
				byBand[name] = {}
				table.insert(order, name)
			end

			table.insert(byBand[name], Animals.getTraitLabel(sampleAnimal, trait))
		end
	end

	local parts = {}

	for _, bandName in ipairs(order) do
		local traits = byBand[bandName]
		local list

		if #traits == 1 then
			list = traits[1]
		else
			list = table.concat(traits, ", ", 1, #traits - 1) .. " and " .. traits[#traits]
		end

		table.insert(parts, string.format("minimum %s in %s", bandName, list))
	end

	return table.concat(parts, "; ") .. "."
end

-- ---------------------------------------------------------------------------
-- Sale observation
-- ---------------------------------------------------------------------------

--- Install the observers. Server-side only, like everything else that owns state.
---
--- Two signals, both base-game globals, because RL's own event classes are unreachable:
---
--- 1. AnimalClusterUpdateEvent — RL publishes it with (husbandry, animals) after every
---    cluster flush (RealisticLivestock_AnimalClusterSystem.lua:241, 597). The class is a
---    base global (InitStaticEventClass, AnimalClusterUpdateEvent.lua:3), so
---    g_messageCenter:subscribe reaches it normally. Diffing successive publishes tells us
---    which animals left.
---
--- 2. FSBaseMission:addMoney with MoneyType.SOLD_ANIMALS (MoneyType.lua:45) — RL's
---    AnimalSellEvent books the proceeds through it exactly like the base game.
---
--- Why both: a removal alone does not mean a sale. Animals also leave by dying, being
--- butchered, or being moved out. RL's sell path removes the animals FIRST
--- (addPendingRemoveCluster + updateNow, which publishes the cluster event) and pays
--- SECOND, synchronously in the same call. So we stash removals as pending and only
--- confirm them when the money follows.
function Animals:install()
	if self.isInstalled then
		return
	end

	if not g_currentMission:getIsServer() then
		return
	end

	local animals = self

	if AnimalClusterUpdateEvent ~= nil then
		g_messageCenter:subscribe(AnimalClusterUpdateEvent, self.onClusterUpdate, self)
	else
		Logging.warning("[ForwardContracts] AnimalClusterUpdateEvent not found; animal "
			.. "deliveries cannot be observed.")
	end

	-- Return-preserving wrapper, for the same reason DeliveryWatch uses one: appended
	-- functions discard the wrapped return (Utils.lua:491-500) and we must never change
	-- what the game sees from a money call.
	local baseAddMoney = FSBaseMission.addMoney
	FSBaseMission.addMoney = function(mission, amount, farmId, moneyType, addChange, forceShow)
		local results = { baseAddMoney(mission, amount, farmId, moneyType, addChange, forceShow) }

		if moneyType == MoneyType.SOLD_ANIMALS then
			animals:onAnimalsSold(farmId, amount)
		end

		return unpack(results)
	end

	self.isInstalled = true
end

--- How well an animal has been KEPT, as a ratio of its weight to what its age warrants.
---
--- This is RL's own `weightFactor`, lifted from `getSellPrice`
--- (RealisticLivestock_Animal.lua:1296-1300) rather than invented, so a contract judging on
--- it judges on exactly what the dealer pays on. 1.0 is an animal at the weight its age
--- implies; below 1.0 has been underfed; a well-fed mature animal runs comfortably above it.
---
--- Feed quality is what moves this. A cow on total mixed ration gains faster than one on
--- grass alone, which is the mechanic the user asked to have reach contract value.
function Animals.getConditionFactor(animal)
	if type(animal) ~= "table" or type(animal.weight) ~= "number" then
		return nil
	end

	local ok, subType = pcall(animal.getSubType, animal)
	if not ok or type(subType) ~= "table" then
		return nil
	end

	-- THE ANIMAL'S OWN TARGET WEIGHT, NOT THE SUBTYPE'S. RL scales it by metabolism
	-- genetics, so a high-metabolism sheep is aiming at 57 kg where its subtype says 45.
	--
	-- Measured 2026-07-29: using the subtype's figure over-valued high-metabolism animals by
	-- ~13% and under-valued low-metabolism ones by ~10%, with the error tracking metabolism
	-- almost perfectly. `getSellPrice` reads `self.targetWeight` here
	-- (RealisticLivestock_Animal.lua:1296) and `subType.targetWeight` in the price term two
	-- lines later (:1306) — two different weights, one line apart, and conflating them is
	-- the easiest mistake in this formula to make.
	local targetWeight = animal.targetWeight
	if type(targetWeight) ~= "number" or targetWeight <= 0 then
		targetWeight = subType.targetWeight
	end

	local minWeight = subType.minWeight
	local breedingAge = subType.reproductionMinAgeMonth

	if type(targetWeight) ~= "number" or type(minWeight) ~= "number"
		or type(breedingAge) ~= "number" or breedingAge <= 0 then
		return nil
	end

	local age = Animals.getAgeMonths(animal) or 0
	local span = breedingAge * 1.5

	-- :1296-1298 verbatim: the expected-weight curve rises to 85% of the mature gain and
	-- then saturates, so a grown animal is measured against a flat expectation.
	local expected = ((targetWeight - minWeight) / span) * math.min(age + 1.5, span) * 0.85

	if expected <= 0 then
		return nil
	end

	return animal.weight / expected
end

--- Snapshot key for one animal, capturing everything a contract needs to judge it AFTER
--- it has left the herd. Genetics are copied by value: once the animal is gone the live
--- object is not safe to hold.
function Animals.snapshot(animal)
	local genetics = animal.genetics or {}

	-- Captured while the animal is alive because Settlement needs it after the sale, to
	-- work out the qualifying animals' share of a mixed batch's payment.
	-- Animal:getSellPrice is at RealisticLivestock_Animal.lua:1290.
	local sellPrice = 0
	if animal.getSellPrice ~= nil then
		local ok, price = pcall(animal.getSellPrice, animal)
		if ok and type(price) == "number" then
			sellPrice = price
		end
	end

	-- CONDITION, and it is why feeding matters to a contract at all.
	--
	-- RL prices an animal on how it was KEPT as well as how it was bred: `getSellPrice`
	-- scales by `weightFactor` and `getHealthFactor()` (RealisticLivestock_Animal.lua:1300,
	-- :1313), both of which follow from feed. A cow on total mixed ration outweighs one on
	-- grass alone and is worth more for it.
	--
	-- Without capturing this the contract would pay a FLAT price for any animal clearing its
	-- genetic floors, and settlement would top up the shortfall on a badly-kept animal — so
	-- the contract would insulate the player from feed quality entirely, which is precisely
	-- backwards. Condition is therefore part of the SPEC, exactly as genetics are.
	local weight = type(animal.weight) == "number" and animal.weight or nil
	local healthFactor = nil

	if animal.getHealthFactor ~= nil then
		local ok, factor = pcall(animal.getHealthFactor, animal)
		if ok and type(factor) == "number" then
			healthFactor = factor
		end
	end

	return {
		key = Animals.getKey(animal),
		earTag = Animals.getEarTag(animal),
		name = animal.name,
		sellPrice = sellPrice,
		ageMonths = Animals.getAgeMonths(animal),
		weight = weight,
		healthFactor = healthFactor,
		conditionFactor = Animals.getConditionFactor(animal),
		genetics = {
			metabolism = genetics.metabolism,
			health = genetics.health,
			fertility = genetics.fertility,
			quality = genetics.quality,
			productivity = genetics.productivity,
		},
		animalTypeIndex = animal.animalTypeIndex,
		subType = animal.subType,

		-- THE FOUR FIELDS WITHOUT WHICH meetsSpec CANNOT ASK THE QUESTION AT ALL.
		--
		-- The animal is gone by settlement, so anything not captured here can never be
		-- checked — and the failure is SILENT, because no rejection is logged when no test
		-- runs. Without these, `meetsSpec` would pass a pregnant cow, a female against a male
		-- contract and an uncastrated bull against a castrated requirement, and the
		-- diagnostic line would report a clean delivery.
		--
		-- VERIFIED against RealisticLivestock_Animal.lua:62, 73, 81-82 (constructor) and
		-- :384-406 (RL's own serialisation, so the names are stable). `gender` is the STRING
		-- "male" or "female"; the other three are booleans.
		--
		-- Pregnancy and lactation are captured to REJECT on, not to reward: RL pays +25% and
		-- +15% for them (:1315), which would make it profitable to ship the animals the
		-- player's own herd depends on. LIVESTOCK_DESIGN §1.6 rules both out.
		gender = animal.gender,
		isCastrated = animal.isCastrated,
		isPregnant = animal.isPregnant,
		isLactating = animal.isLactating,
	}
end

--- RL published a cluster change. Diff against our last view of this husbandry and stash
--- anything that disappeared as a candidate sale.
function Animals:onClusterUpdate(husbandry, animalList)
	if husbandry == nil or animalList == nil then
		return
	end

	local previous = self.herdSnapshot[husbandry]
	local current = {}

	for _, animal in ipairs(animalList) do
		local key = Animals.getKey(animal)
		if key ~= nil then
			current[key] = Animals.snapshot(animal)
		end
	end

	self.herdSnapshot[husbandry] = current

	if previous == nil then
		-- First sighting of this husbandry — nothing to diff against. A herd that exists
		-- at load must not read as a mass sale.
		return
	end

	local removed = {}
	local farmId = husbandry.getOwnerFarmId ~= nil and husbandry:getOwnerFarmId() or nil

	for key, snapshot in pairs(previous) do
		if current[key] == nil then
			table.insert(removed, snapshot)
		end
	end

	if #removed == 0 then
		return
	end

	-- ACCUMULATE WITHIN A SALE, DISCARD ACROSS SALES.
	--
	-- This used to overwrite outright, on the reasoning that only the most recent batch can
	-- belong to a following payment. **That loses animals**, because RL publishes
	-- `AnimalClusterUpdateEvent` after EVERY cluster flush
	-- (RealisticLivestock_AnimalClusterSystem.lua:241, 597) and clusters are split by age,
	-- gender and subtype — so one sale of a mixed batch fires several updates before the
	-- money arrives, and every batch but the last was thrown away.
	--
	-- Reported from play 2026-07-29: 87 birds loaded, 85 counted.
	--
	-- The original concern was real, though: an old death must not be attributed to a later
	-- sale. RL removes and pays SYNCHRONOUSLY in one call, so batches belonging to the same
	-- sale arrive in the same frame. Accumulate while that holds and start fresh once time
	-- has moved on, which keeps the "silence means not-a-sale" default intact.
	local key = farmId or 0
	local now = g_currentMission ~= nil and g_currentMission.time or 0
	local pending = self.pendingRemovals[key]

	if pending ~= nil and pending.husbandry == husbandry
		and (now - (pending.time or 0)) <= Animals.SALE_BATCH_WINDOW_MS then
		for _, snapshot in ipairs(removed) do
			table.insert(pending.animals, snapshot)
		end

		pending.time = now
	else
		self.pendingRemovals[key] = {
			animals = removed,
			husbandry = husbandry,
			time = now,
		}
	end
end

--- Money was booked as SOLD_ANIMALS, so the removals we just saw for this farm were a
--- sale. Consume them and tell the listeners.
function Animals:onAnimalsSold(farmId, amount)
	local pending = self.pendingRemovals[farmId or 0]

	if pending == nil or #pending.animals == 0 then
		return
	end

	self.pendingRemovals[farmId or 0] = nil

	self:notify({
		farmId = farmId,
		animals = pending.animals,
		husbandry = pending.husbandry,
		money = amount,
	})
end

-- ---------------------------------------------------------------------------
-- Listeners
-- ---------------------------------------------------------------------------

function Animals:addListener(target, callback)
	table.insert(self.listeners, { target = target, callback = callback })
end

function Animals:notify(sale)
	for _, listener in ipairs(self.listeners) do
		listener.callback(listener.target, sale)
	end
end
