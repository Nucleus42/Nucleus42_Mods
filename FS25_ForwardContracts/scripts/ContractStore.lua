-- Forward Contracts — ContractStore
--
-- Owns every signed contract: quotas, delivery progress, the annual reckoning, and
-- persistence. Server-side only; clients receive state once the network layer exists.
--
-- This is the provider Settlement talks to (see the seam documented at the top of
-- Settlement.lua). It deliberately knows nothing about how a contract was negotiated or
-- how it got onto the board — Offers and Negotiation own that.
--
-- Design reference: HANDOFF.md §4.2 (contract types), §4.5 (reputation consequences),
-- §4.6 (animal contracts).

ContractStore = {}

local ContractStore_mt = Class(ContractStore)

-- A supply contract is an annual quota over N years. A spot order is a single premium
-- delivery with a short expiry. Both settle through the same path.
ContractStore.KIND_SUPPLY = "supply"
ContractStore.KIND_SPOT = "spot"

-- Litre contracts settle through DeliveryWatch/Settlement. Head contracts are livestock
-- and are fulfilled deliberately through Realistic Livestock's own sell events by the
-- Animals module — they must never be matched by getActiveContract.
ContractStore.UNIT_LITRES = "litres"
ContractStore.UNIT_HEAD = "head"

-- Missing a year costs a share of that year's contract value, scaled by how badly you
-- missed. A near miss stings; walking away from the whole quota is expensive.
ContractStore.SHORTFALL_PENALTY_FACTOR = 0.35

-- Punishing but survivable after one bad harvest. Two in a row ends the agreement.
ContractStore.MAX_CONSECUTIVE_MISSES = 2

ContractStore.SAVEGAME_FILENAME = "forwardContracts.xml"

function ContractStore.new()
	local self = setmetatable({}, ContractStore_mt)

	self.contracts = {}
	self.nextId = 1
	self.reputation = nil -- set via setReputationProvider; optional until written

	-- TWO ARGUMENTS, TWO DIFFERENT JOBS, and confusing them put a raw l10n key on screen.
	--
	--   * `statistic` must be an EXISTING FarmStats name — `changeFinanceStats` silently
	--     drops an unknown one (FarmStats.lua:187-189) and the entry never reaches the
	--     finances screen. So these stay "soldMaterials" and "other".
	--   * `title` is an l10n key rendered by the money-change HUD as
	--     `g_i18n:getText(moneyType.title, moneyType.customEnv)` (gui/hud/HUD.lua:297).
	--     Because we pass our own mod as `customEnv`, the lookup happens in OUR l10n — so
	--     naming a base-game key like "finance_soldMaterials" does NOT inherit the base
	--     game's text, it just fails to resolve and prints the key.
	--
	-- Reported from play 2026-07-29: selling chickens against a contract popped a
	-- notification quoting the bare key. Our own keys, defined in modDesc, fix it and read
	-- better besides — the player sees "Contract bonus", not "finance_soldMaterials".
	self.moneyTypeBonus = MoneyType.register("soldMaterials", "fc_finance_bonus",
		ForwardContracts.MOD_NAME)
	self.moneyTypePenalty = MoneyType.register("other", "fc_finance_penalty",
		ForwardContracts.MOD_NAME)

	return self
end

function ContractStore:setReputationProvider(provider)
	self.reputation = provider
end

--- Called as `callback(target, contract)` the moment a contract completes in good standing,
--- while the contract still exists. See settleContractYear for why the timing is not optional.
function ContractStore:setRenewalHandler(target, callback)
	self.renewalHandler = { target = target, callback = callback }
end

function ContractStore:subscribe()
	g_messageCenter:subscribe(MessageType.YEAR_CHANGED, self.onYearChanged, self)
	g_messageCenter:subscribe(MessageType.DAY_CHANGED, self.onDayChanged, self)
end

function ContractStore:unsubscribe()
	g_messageCenter:unsubscribeAll(self)
end

-- ---------------------------------------------------------------------------
-- Calendar helpers
-- ---------------------------------------------------------------------------

--- Total in-game days in a year. Month length is a game setting, so nothing may assume
--- a fixed number of days (HANDOFF.md §4.2 — always work in days, never months).
function ContractStore:getDaysPerYear()
	local environment = g_currentMission.environment
	return (environment.daysPerPeriod or 1) * Environment.PERIODS_IN_YEAR
end

function ContractStore:getDayOfYear()
	local environment = g_currentMission.environment
	local daysPerPeriod = environment.daysPerPeriod or 1
	return (environment.currentPeriod - 1) * daysPerPeriod + (environment.currentDayInPeriod or 1)
end

--- Fraction of the current year still to run, in (0, 1].
function ContractStore:getYearFractionRemaining()
	local daysPerYear = self:getDaysPerYear()
	local remaining = daysPerYear - self:getDayOfYear() + 1
	return math.max(remaining, 1) / daysPerYear
end

-- ---------------------------------------------------------------------------
-- Signing
-- ---------------------------------------------------------------------------

--- Sign a negotiated contract.
--
-- `spec` carries what Negotiation agreed:
--   farmId, clientId, kind, unit, fillTypeIndex,
--   rate, completionBonus, quotaPerYear, years,
--   traitFloors (head contracts only), durationDays (spot only)
--
-- The first year is pro-rata. Signing in late autumn must not demand a full year's
-- tonnage before the rollover, and waiting for the next year would leave a fresh
-- contract inert for up to twelve in-game days.
function ContractStore:signContract(spec)
	-- A FORESTRY TERM IS A NUMBER OF DAYS, AND YEARS CANNOT EXPRESS IT.
	--
	-- Terms derive from the species' growth time and land on fractions — oak is 1.98 years of
	-- growth and a 2.18-year term (FORESTRY.md §3-§4.1). The delivery window at the end is
	-- MONTHS: 2.4 of them at tier 1. An integer `years` rounds both away, and settling on
	-- YEAR_CHANGED can only ever judge on a calendar boundary the term does not sit on.
	--
	-- ⚠ **DAYS, NOT YEARS, AND THAT IS NOT ARBITRARY.** Trees grow on `getMonotonicHour()`
	-- (`misc/TreePlantManager.lua:357, :373`), which is absolute game hours and independent of
	-- month length (`environment/Environment.lua:513-515`). A day is always 24 of those hours,
	-- so a term stored in DAYS still means the same amount of tree growth after the player
	-- changes their month length. A term stored in YEARS would silently become a different
	-- commitment, because a year is `daysPerPeriod * 12` days and that is a live setting.
	--
	-- Computed before the contract table so both fields are declared in one place — the
	-- five-list guard reads that table, and a field assigned further down is a field it cannot
	-- see. See `test/field_lists.py`.
	local termDays, deadlineDay

	if spec.isTermQuota then
		-- `spec.termDays` is authoritative. The fallback exists only so a term contract cannot
		-- be created with no deadline at all, which would leave it unsettleable forever.
		termDays = spec.termDays
			or math.max(1, math.floor((spec.years or 1) * self:getDaysPerYear() + 0.5))

		deadlineDay = g_currentMission.environment.currentMonotonicDay + termDays
	end

	local contract = {
		id = self.nextId,
		farmId = spec.farmId,
		clientId = spec.clientId,
		kind = spec.kind or ContractStore.KIND_SUPPLY,
		unit = spec.unit or ContractStore.UNIT_LITRES,
		fillTypeIndex = spec.fillTypeIndex,
		rate = spec.rate,

		-- WHERE TO TAKE IT. The offer named a buyer and the signed contract dropped it, so
		-- the player agreed to deliver 77,038 l of eggs and was then told nothing about where
		-- (reported from play 2026-08-01). **This is the `feedName` bug for the third time** —
		-- a field that exists on the offer, displays correctly there, and was never added to
		-- the hand-written table below.
		--
		-- ADVISORY, NOT A DESTINATION LOCK. Any non-train selling station that buys the fill
		-- type settles the contract, and it makes no financial difference which one you use:
		-- `Settlement.onDelivery` pays `(contract.rate - realisedRate) x litres`, so contracted
		-- litres always net the agreed rate wherever they are sold. This names the best-paying
		-- buyer AT SIGNING, which is the one that matters for anything delivered over quota.
		suggestedStation = spec.suggestedStation,

		-- ONE QUOTA FOR THE WHOLE TERM INSTEAD OF ONE PER YEAR. Forestry only, and it is not a
		-- balance choice — an annual quota makes a tier 2 or 3 forestry contract IMPOSSIBLE TO
		-- COMPLETE.
		--
		-- Those tiers require wood from trees the player planted after signing. Oak matures in
		-- ~2 years and pine in ~10, so years 1 and 2 have nothing to deliver, the contract
		-- misses twice, and `MAX_CONSECUTIVE_MISSES` terminates it before a single tree is ready.
		-- The player did nothing wrong and could not have.
		--
		-- Forestry is also lumpy even at tier 1: you fell a stand, deliver a lot at once, then
		-- there is nothing for a while. Requiring equal litres every year fights the growth
		-- cycle, which is the one thing this contract line is about.
		--
		-- **WHAT IT COSTS, AND IT IS A REAL TRADE.** There is no mid-term pressure and no early
		-- warning: nothing settles until the final year, so a player can ignore the contract for
		-- seven years and dump everything in the eighth. The counterweight is that the shortfall
		-- penalty is charged on the WHOLE TERM'S value, so failing an 8-year deal outright costs
		-- far more than failing one year of it. Judged correct — the player agreed to a term, and
		-- the panel shows delivered-of-total throughout.
		isTermQuota = spec.isTermQuota,

		-- HOW LONG THE TERM IS, AND THE DAY IT IS JUDGED. Both nil for everything else.
		--
		-- `deadlineDay` is what `onDayChanged` settles against, so **losing it on a save/load
		-- leaves a forestry contract that can be completed by delivering but can never fail** —
		-- it would sit on the board forever holding nothing, because nothing else in the mod
		-- would ever look at it again. `load` re-derives one rather than allow that.
		termDays = termDays,
		deadlineDay = deadlineDay,

		-- THE TERM'S QUOTA, KEPT SO `quotaTotal * rate == annualValue` STAYS CHECKABLE rather
		-- than merely true. Same reason `offer.annualValue` exists: the guard written for that
		-- invariant was worthless without a stored target to check against, and a 30% pricing
		-- error fitted comfortably inside the rung's own variance band.
		--
		-- It is also what the board reports progress against — "120,000 of 204,188 delivered"
		-- for the whole term — and `quotaThisYear` is not safe for that job, because
		-- `settleContractYear` rewrites it every year for ordinary contracts.
		quotaTotal = spec.quotaTotal,

		-- FORESTRY. The species the contract names, and how many of them it implies.
		--
		-- ⚠ **BY NAME, NEVER BY INDEX.** Split types are registered at runtime
		-- (`misc/SplitShapeManager.lua:12-53`) so a mod adding species renumbers them, and a
		-- stored index would silently retarget the contract at a different tree. The name is
		-- upper-case and identical in the tree-type registry, the split-type registry and the
		-- savegame's own `treePlant.xml` — one string identifies a species everywhere (§5.1).
		--
		-- `plantingFloor` is stored rather than recomputed: the chip price it was derived at has
		-- moved by the time anyone asks, so re-deriving would state a different number of trees
		-- than the one the player agreed to. Same reason `feedName` is stored.
		speciesName = spec.speciesName,
		plantingFloor = spec.plantingFloor,

		-- TREES OF THAT SPECIES PLANTED SINCE SIGNING. Counted by `PlantingWatch`.
		--
		-- **CUMULATIVE, AND NEVER DECREMENTED WHEN A TREE IS FELLED.** User ruling 2026-08-02.
		-- Felling is the entire point of the contract, so counting SURVIVING trees would be
		-- self-defeating: delivering the quota destroys the evidence that you grew it. This
		-- counts the ACT of planting, which happened and cannot un-happen.
		--
		-- **SINCE SIGNING, so it starts at zero.** Trees already in the ground earn nothing.
		-- That is what makes the derived term honest — the term IS `growth * 1.1`, priced on
		-- the assumption that you plant, wait and fell. Crediting a mature stand planted years
		-- ago would satisfy an eleven-year pine contract on the day it was signed.
		planted = 0,

		-- LIVESTOCK ONLY, AND IT NO LONGER SETTLES ANYTHING. `Offers:createAnimalOffer` rolls it
		-- within the tier's band and `rate` is already `anchor x rateMultiplier`, so this is
		-- kept as the RECORD of how the rate was reached — `ContractBoardFrame.describeMultiplier`
		-- reads it to say "18% ABOVE what a minimum-spec animal fetches at the dealer".
		-- `settleAnimalsAgainst` pays flat `contract.rate` per head (§4.6 reversal, 2026-07-28).
		--
		-- ⛔ **FORESTRY MUST NEVER SET THIS.** It used to, and its presence is the one thing
		-- `Settlement:onDelivery` would have branched on. That branch is deleted (2026-08-02) so
		-- a stray value is now inert rather than dangerous — but set it on a litre contract and
		-- the next person to read this file will believe forestry still has two settlement modes.
		rateMultiplier = spec.rateMultiplier,

		completionBonus = spec.completionBonus or 0,
		quotaPerYear = spec.quotaPerYear,
		years = spec.years or 1,
		traitFloors = spec.traitFloors,

		-- Livestock specification: a named breed and an age window, both nil for crops.
		subTypeName = spec.subTypeName,
		ageMin = spec.ageMin,
		ageMax = spec.ageMax,

		-- And how the animal was KEPT, which is the feed chain showing up in the terms.
		minCondition = spec.minCondition,
		minHealth = spec.minHealth,

		-- THE REBUILD'S SPEC FIELDS. Every one of these must also appear in `save`, `load`,
		-- `Offers:acceptAnimalOffer` and the offer table itself — FIVE hand-written lists, and
		-- omitting one loses the field with no error at all. That has already cost two bugs
		-- (`feedName`, `pendingRemovals`). Grep any one of them and expect five hits.
		--
		-- `contractType` is SUPPLY, BREEDING or PRODUCT. **It must default rather than stay
		-- nil**: contracts signed before the rebuild have none, and every type-aware path would
		-- otherwise skip them silently. See `load`.
		contractType = spec.contractType,

		-- SUPPLY only. The overall genetic band in RL's own aggregate scale, plus the separate
		-- floor on quality — two numbers, and §2.2 explains why one is not enough.
		overallBand = spec.overallBand,
		qualityFloor = spec.qualityFloor,

		-- BREEDING only. Both productivity AND fertility must clear it, never their average.
		prodFertFloor = spec.prodFertFloor,

		-- Gender is usually implied by `subTypeName`, since RL ships males and females as
		-- separate subtypes. Stored anyway so the board and the rejection log can say it.
		gender = spec.gender,

		-- Castration changes both the price (+15%) and how the band is judged: it zeroes
		-- fertility, so `meetsSpec` drops fertility from the overall mean when this is set.
		requiresCastrated = spec.requiresCastrated,

		-- The feed the contract named. Stored because it was ROLLED among several groups and
		-- cannot be recomputed: re-deriving it later would state a different feed than the one
		-- the player agreed to.
		feedName = spec.feedName,

		yearIndex = 1,
		deliveredThisYear = 0,
		consecutiveMisses = 0,
		yearsMet = 0,
		isComplete = false,
	}

	self.nextId = self.nextId + 1

	if contract.kind == ContractStore.KIND_SPOT then
		-- Spot orders ignore the year entirely — they live and die on a day count.
		contract.quotaThisYear = spec.quotaPerYear
		contract.expiryDay = g_currentMission.environment.currentMonotonicDay
			+ (spec.durationDays or 1)
	elseif contract.isTermQuota then
		-- ONE QUOTA FOR THE WHOLE TERM, settled once at the deadline. See the field's comment.
		--
		-- No pro-rata. The term runs from the DAY OF SIGNING, not across calendar years, so
		-- there is no part-year to scale — and scaling would quietly shrink a commitment the
		-- player agreed to in full.
		--
		-- ⚠ **`quotaTotal` IS AUTHORITATIVE AND `quotaPerYear * years` IS NOT.** A forestry
		-- quota is derived straight from money and a FRACTIONAL term — `annualValue * term /
		-- chipPrice` (FORESTRY.md §3) — so `quotaPerYear` and `years` are display companions
		-- rounded off it, not its parts. Multiplying them back together reconstructs a
		-- DIFFERENT number: a 2.18-year oak contract would come out as 2 or 3 years' worth, an
		-- 8-37% error in the workload, and `quota * rate == annualValue` would quietly stop
		-- holding. The fallback is for the pre-day-granularity shape only.
		contract.quotaTotal = contract.quotaTotal or (spec.quotaPerYear * (spec.years or 1))
		contract.quotaThisYear = contract.quotaTotal
	else
		contract.quotaThisYear = math.floor(spec.quotaPerYear * self:getYearFractionRemaining())
	end

	contract.remainingLitres = contract.quotaThisYear

	table.insert(self.contracts, contract)

	return contract
end

-- ---------------------------------------------------------------------------
-- Settlement provider interface
-- ---------------------------------------------------------------------------

--- Settlement calls this on every observed delivery.
---
--- Head contracts are excluded — livestock never settles through the selling-station
--- path. Completed and exhausted contracts are excluded so Settlement's clamp is never
--- handed a zero quota.
function ContractStore:getActiveContract(farmId, fillTypeIndex)
	for _, contract in ipairs(self.contracts) do
		if contract.farmId == farmId
			and contract.fillTypeIndex == fillTypeIndex
			and contract.unit == ContractStore.UNIT_LITRES
			and not contract.isComplete
			and (contract.remainingLitres or 0) > 0 then
			return contract
		end
	end

	return nil
end

--- The farm's active livestock contract, if any.
---
--- Head contracts have no fill type — the product is an animal meeting a genetic
--- specification, not a commodity — so they cannot be found by the fill-type lookup above
--- and get their own accessor rather than an overloaded one.
---
--- Only one head contract can be active per farm at a time. That is deliberate: a breeder
--- works a line, and two simultaneous genetic specifications would just be a spreadsheet.
--- Offers must not generate a second while one is live.
--- Every live livestock contract for this farm.
---
--- Livestock used to be capped at ONE contract per farm, permanently, while crops scaled
--- 2-5 slots with reputation. The user's objection, 2026-07-29: a farm that grows its
--- infrastructure should be able to supply more, and chickens and cattle share no barn, no
--- feed chain and no gene pool.
---
--- The cap is now the single CONTRACT BUDGET (§6) plus one line per species, so a
--- second species unlocks only at tier 3. The part of §4.6 that survives is one contract per
--- species: two competing genetic specifications on one herd is incoherent, and that is a
--- real constraint rather than an arbitrary one.
--- How many contracts this farm holds against its BUDGET (LIVESTOCK_DESIGN §6).
---
--- **SPOT ORDERS ARE DELIBERATELY EXCLUDED.** They are 1-2 day one-off hauls and sit outside
--- the budget entirely — making a sixteen-hour slurry run compete with a four-year cattle
--- agreement would mean nobody ever took one. The user's framing: they are *"the 'happy little
--- extras'... the 'we can't plan the margins on them but if we can do them then bonus' type of
--- contracts."*
---
--- Counts EVERY other type together — crop, supply, breeding, product. §6 replaced the
--- per-type slot tables because nobody had ever added them up: on per-type slots a tier-4 farm
--- could hold 13 contracts worth ~£950,000 a year, which is the mega-farm the mod exists not to
--- create. Every individual figure was defensible; the sum was not.
function ContractStore:getActiveContractCount(farmId)
	local count = 0

	for _, contract in ipairs(self.contracts) do
		if contract.farmId == farmId
			and not contract.isComplete
			and contract.kind ~= ContractStore.KIND_SPOT then
			count = count + 1
		end
	end

	return count
end

function ContractStore:getActiveHeadContracts(farmId)
	local result = {}

	for _, contract in ipairs(self.contracts) do
		if contract.farmId == farmId
			and contract.unit == ContractStore.UNIT_HEAD
			and not contract.isComplete
			and (contract.remainingLitres or 0) > 0 then
			table.insert(result, contract)
		end
	end

	return result
end

--- Which live contract, if any, this particular animal can be delivered against.
---
--- **Settlement must never just take the first head contract.** With more than one live, the
--- first-match approach would credit a cattle sale to a chicken contract — the delivery
--- accounting would corrupt silently, which is worse than the cap it replaced. Matching on
--- the full spec is what makes lifting the cap safe.
---
--- Ties break toward the contract with the least still outstanding, so a nearly finished
--- agreement is closed out before a fresh one is started. That is the order a supplier would
--- choose, and it minimises the chance of finishing a year with two part-filled quotas and
--- two penalties instead of one completion and one miss.
function ContractStore:getHeadContractForAnimal(farmId, snapshot, animals)
	local best = nil

	for _, contract in ipairs(self:getActiveHeadContracts(farmId)) do
		if animals == nil or animals:meetsSpec(snapshot, contract) then
			if best == nil or (contract.remainingLitres or 0) < (best.remainingLitres or 0) then
				best = contract
			end
		end
	end

	return best
end

function ContractStore:getActiveHeadContract(farmId)
	for _, contract in ipairs(self.contracts) do
		if contract.farmId == farmId
			and contract.unit == ContractStore.UNIT_HEAD
			and not contract.isComplete
			and (contract.remainingLitres or 0) > 0 then
			return contract
		end
	end

	return nil
end

--- Record litres delivered against a contract. `money` is what the farm actually
--- received for them, market price plus our settlement adjustment.
---
--- For head contracts the unit is animals rather than litres; the field keeps its name
--- because the quota arithmetic, the year reckoning and the savegame schema are all
--- identical and a parallel set of fields would be duplication for the sake of a noun.
function ContractStore:recordDelivery(contract, litres, money)
	contract.deliveredThisYear = contract.deliveredThisYear + litres
	contract.remainingLitres = math.max(0, contract.remainingLitres - litres)

	if contract.kind == ContractStore.KIND_SPOT and contract.remainingLitres <= 0 then
		self:completeSpotOrder(contract)
	elseif contract.isTermQuota then
		self:tryCompleteTermContract(contract)
	end
end

--- A forestry contract needs BOTH its litres and its trees. Complete it only when it has both.
---
--- **THE PLANTING FLOOR IS A HARD GATE ON COMPLETION.** User ruling 2026-08-02, and it is what
--- makes the species mean anything: chips are species-blind at the till, so without this gate
--- "an oak contract" is a word on a board and all four tiers are the same contract.
---
--- Called from BOTH sides, because either can be the last one to land:
---
---   * `recordDelivery` — the chips arrive and the trees were already in the ground.
---   * `creditPlanting` — the chips arrived long ago and the player is still planting.
---
--- Checking only on delivery would strand a contract whose quota was met first: nothing else
--- would ever look at it again and it would sit holding a slot until its deadline, for a reason
--- the player had already fixed.
function ContractStore:tryCompleteTermContract(contract)
	if contract.isComplete or (contract.remainingLitres or 0) > 0 then
		return false
	end

	if not self:hasMetPlantingFloor(contract) then
		return false
	end

	self:completeTermContract(contract)

	return true
end

--- Whether the contract's planting floor is satisfied. True when it has no floor at all, so
--- every non-forestry contract passes and this can be asked unconditionally.
function ContractStore:hasMetPlantingFloor(contract)
	local floor = contract.plantingFloor or 0

	return floor <= 0 or (contract.planted or 0) >= floor
end

--- A tree of some species was planted. Credit every live contract that named it.
---
--- **EVERY MATCHING CONTRACT, not the first.** One tree serves whichever agreements wanted that
--- species — the same reasoning that lets one animal sale settle against two livestock
--- contracts. In practice they cannot collide: tiers 1-3 hold one contract, and tier 4's two
--- are one 4a and one 4b, which draw from disjoint species bands by construction (§4.4).
---
--- Species is matched BY NAME. See `signContract`.
function ContractStore:creditPlanting(farmId, speciesName)
	if farmId == nil or speciesName == nil then
		return 0
	end

	local credited = 0

	for _, contract in ipairs(self.contracts) do
		if contract.farmId == farmId
			and not contract.isComplete
			and contract.speciesName == speciesName then

			contract.planted = (contract.planted or 0) + 1
			credited = credited + 1

			-- The trees may be the LAST thing outstanding — see `tryCompleteTermContract`.
			if contract.isTermQuota then
				self:tryCompleteTermContract(contract)
			end
		end
	end

	return credited
end

--- A TERM CONTRACT IS A DEADLINE, NOT A DURATION. Meeting the quota finishes it there and then.
---
--- *"It should also be a 'within x years' rather than 'x volume per year for x years'."* — and
--- "within" is the whole point: a contract that stayed open until its final year would leave a
--- player who delivered everything early holding a dead slot for years, punishing exactly the
--- efficiency the contract is meant to reward.
---
--- **This is what makes the long forestry terms affordable.** A 4-year contract is a 4-year
--- WORST CASE, not a 4-year lockup: plant well, harvest early, and the slot comes back. That
--- was the open worry about tying up half a tier-1 board, and it answers it without an extra
--- slot or any change to the budget.
---
--- `getActiveContractCount` already filters on `isComplete`, so the slot frees the same instant
--- rather than at the next year change. `pruneCompleted` tidies the record later.
---
--- Deliberately mirrors the SUCCESS path in `settleContractYear` and nothing else: there is no
--- early failure. A term contract can only be judged short at its deadline.
function ContractStore:completeTermContract(contract)
	contract.isComplete = true
	contract.didFulfilTerm = true

	-- Bonus, `yearsMet` and `reputation:onQuotaMet` — the same call the final year would make.
	self:onYearMet(contract)

	-- Renewal fires HERE for the same reason it fires inside settleContractYear: `didFulfilTerm`
	-- is not persisted and `pruneCompleted` deletes the contract at the next year change, so
	-- this is the moment or never. See settleContractYear.
	if self.renewalHandler ~= nil then
		self.renewalHandler.callback(self.renewalHandler.target, contract)
	end

	if self.reputation ~= nil then
		self.reputation:onContractCompleted(contract)
	end
end

-- ---------------------------------------------------------------------------
-- Spot orders
-- ---------------------------------------------------------------------------

function ContractStore:completeSpotOrder(contract)
	contract.isComplete = true

	if contract.completionBonus > 0 then
		g_currentMission:addMoney(contract.completionBonus, contract.farmId,
			self.moneyTypeBonus, true, true)
	end

	if self.reputation ~= nil then
		self.reputation:onContractCompleted(contract)
	end
end

function ContractStore:onDayChanged()
	local today = g_currentMission.environment.currentMonotonicDay

	for _, contract in ipairs(self.contracts) do
		if contract.isComplete then
			-- Nothing to do. Guarded once here rather than in each branch below.
		elseif contract.kind == ContractStore.KIND_SPOT then
			if contract.expiryDay ~= nil and today >= contract.expiryDay then
				-- An expired spot order is a missed commitment, not a quiet disappearance.
				contract.isComplete = true

				if self.reputation ~= nil then
					self.reputation:onSpotOrderExpired(contract)
				end
			end
		elseif contract.isTermQuota then
			-- FORESTRY'S DEADLINE. Judged HERE and never on YEAR_CHANGED, because a 2.18-year
			-- term does not land on a calendar boundary. `expiryDay` and `deadlineDay` are
			-- deliberately different fields: a spot order lapses, a term contract is JUDGED,
			-- and one of the two charges a penalty.
			if contract.deadlineDay ~= nil and today >= contract.deadlineDay then
				self:settleTermContract(contract)
			end
		end
	end

	self:pruneCompleted()
end

--- The deadline arrived. A term contract is judged ONCE, here, on the whole term.
---
--- Deliberately the mirror of `settleContractYear`'s FINAL-year branch and of nothing else —
--- there is no early failure and no mid-term pressure, because the trees the contract requires
--- have not grown yet for most of it (see `signContract`).
---
--- The success path is `completeTermContract`, which `recordDelivery` already calls the instant
--- the quota is met. So a contract that finished early never reaches here at all: it was
--- pruned, and its slot came back years ago. **"Within X years" is a deadline, not a duration.**
function ContractStore:settleTermContract(contract)
	local quota = contract.quotaThisYear or 0
	local delivered = contract.deliveredThisYear or 0

	-- ⚠ **THE PLANTING FLOOR IS PART OF THE DEADLINE TEST, NOT ONLY OF EARLY COMPLETION.**
	--
	-- Without this clause a contract that delivered every litre but planted nothing would fall
	-- into the success branch here, and the gate in `tryCompleteTermContract` would have bought
	-- exactly nothing: it would delay completion to the deadline and then grant it anyway. The
	-- species would still mean nothing — it would just mean nothing later.
	local metFloor = self:hasMetPlantingFloor(contract)

	if metFloor and (quota <= 0 or delivered >= quota) then
		self:completeTermContract(contract)
		return
	end

	-- ⚠ **THE PENALTY IS CHARGED ON THE LITRE SHORTFALL, AND A TREE SHORTFALL IS NOT ONE.**
	--
	-- A player who delivered everything and planted too few has `delivered >= quota`, so
	-- `onYearMissed` would compute a shortfall fraction of zero or less, charge nothing, and
	-- call `onQuotaMissed` with a meaningless number. The contract still FAILS — they did not
	-- honour its terms — but it fails without a fine, because the quota they agreed to in
	-- litres was met. Reputation still takes the hit through `onContractUnfulfilled` below.
	--
	-- Ruled this way rather than inventing a tree-denominated penalty: the mod observes and
	-- pays, and there is no honest price for a tree that was never planted.
	if delivered >= quota then
		Logging.info("[ForwardContracts] Contract %d delivered %d of %d l but planted %d of %d "
			.. "%s. Unfulfilled, no penalty.", contract.id, delivered, quota,
			contract.planted or 0, contract.plantingFloor or 0,
			tostring(contract.speciesName))

		contract.isComplete = true
		contract.didFulfilTerm = false
		contract.consecutiveMisses = (contract.consecutiveMisses or 0) + 1

		if self.reputation ~= nil then
			self.reputation:onContractUnfulfilled(contract)
		end

		return
	end

	-- The penalty is charged on the WHOLE TERM'S value, because `quotaThisYear` is the term's
	-- quota. That is the counterweight to there being no mid-term pressure: ignoring an 8-year
	-- deal costs far more than failing one year of a crop contract. See `signContract`.
	self:onYearMissed(contract, quota, delivered)

	-- `onYearMissed` only completes a contract on the SECOND consecutive miss, and a term
	-- contract is judged exactly once — so it falls through with `consecutiveMisses` at 1 and
	-- must be closed explicitly. Without this it stays alive past its own deadline, holding a
	-- slot nothing can ever free.
	if not contract.isComplete then
		contract.isComplete = true
		contract.didFulfilTerm = false

		if self.reputation ~= nil then
			-- Against the CLIENT only. `onQuotaMissed` inside `onYearMissed` has already
			-- charged the reputation, and charging again would penalise one failure twice.
			self.reputation:onContractUnfulfilled(contract)
		end
	end
end

-- ---------------------------------------------------------------------------
-- The annual reckoning
-- ---------------------------------------------------------------------------

function ContractStore:onYearChanged()
	for _, contract in ipairs(self.contracts) do
		if contract.kind == ContractStore.KIND_SUPPLY and not contract.isComplete then
			self:settleContractYear(contract)
		end
	end

	self:pruneCompleted()
end

--- Days still to run before a term contract is judged. Negative once the deadline has passed
--- and the day tick has not caught it yet, which is at most one game day.
---
--- The BOARD's number, and the reason it is days rather than years: the whole tension of a
--- forestry contract is the delivery window at the end — 2.4 months at tier 1, 12 at tier 4
--- (FORESTRY.md §3, §8) — and "0.2 years left" is not a thing anyone can plan a haulage run
--- around.
function ContractStore:getDaysRemaining(contract)
	if contract == nil or contract.deadlineDay == nil then
		return nil
	end

	return contract.deadlineDay - g_currentMission.environment.currentMonotonicDay
end

function ContractStore:settleContractYear(contract)
	-- A TERM-QUOTA CONTRACT IS NEVER SETTLED BY THE CALENDAR. It is judged once, on its own
	-- deadline day, by `settleTermContract`.
	--
	-- > # ⚠ THIS GUARD WAS `yearIndex < years` UNTIL 2026-08-02. IT IS NOW UNCONDITIONAL.
	-- >
	-- > The old form let the FINAL year fall through and settle the term on the calendar
	-- > rollover. That worked only while terms were whole numbers of years. They are not — oak
	-- > runs 2.18 years — so a term now expires mid-year and the year boundary is the wrong
	-- > event entirely. `onYearChanged` no longer offers term contracts to this function at
	-- > all; this is the second lock, not the first.
	--
	-- Returning BEFORE `onYearMet`/`onYearMissed` is what makes it safe: those two are the only
	-- places reputation moves and the only place the penalty is charged, so a calendar rollover
	-- cannot score a term contract, cannot penalise it and cannot terminate it.
	--
	-- `yearIndex` is still advanced so the board's "year N of M" line keeps counting.
	if contract.isTermQuota then
		contract.yearIndex = (contract.yearIndex or 1) + 1
		return
	end

	local quota = contract.quotaThisYear or 0
	local delivered = contract.deliveredThisYear or 0

	if quota <= 0 or delivered >= quota then
		self:onYearMet(contract)
	else
		self:onYearMissed(contract, quota, delivered)
	end

	contract.yearIndex = contract.yearIndex + 1

	if contract.yearIndex > contract.years and not contract.isComplete then
		contract.isComplete = true

		-- RUNNING OUT THE CLOCK IS NOT COMPLETING A CONTRACT.
		--
		-- This used to award `onContractCompleted` to ANY contract that reached the end of
		-- its term without being terminated, and termination only happens on the SECOND
		-- consecutive miss. So a 1-year contract you failed outright scored -0.08 for the
		-- miss and +0.08 for "completing" it — a net zero, with the client recording a
		-- successful contract and liking you more for it. Found by reading the path before
		-- testing the miss branch, 2026-07-29.
		--
		-- A contract is honoured if it delivered at least one year AND finished in good
		-- standing. The final-year test is what keeps "one bad harvest is survivable" true
		-- (§4.5) — an early miss recovered from still completes — while a contract that ends
		-- mid-failure does not.
		contract.didFulfilTerm = (contract.yearsMet or 0) > 0
			and contract.consecutiveMisses == 0

		-- RENEWAL FIRES HERE, AND IT HAS TO. `didFulfilTerm` is written on this line and
		-- `pruneCompleted` deletes the contract eleven lines later in `onYearChanged` — the
		-- flag is never persisted and cannot be read afterwards by anything. So renewal is not
		-- "something reads the flag", it is "this moment, before the record is gone".
		--
		-- Called through a handler rather than by reaching for Offers directly: ContractStore
		-- deliberately knows nothing about how a contract got onto the board (see the file
		-- header), and renewal must not be the thing that breaks that.
		if contract.didFulfilTerm and self.renewalHandler ~= nil then
			self.renewalHandler.callback(self.renewalHandler.target, contract)
		end

		if self.reputation ~= nil then
			if contract.didFulfilTerm then
				self.reputation:onContractCompleted(contract)
			else
				-- Records the failure against the CLIENT only — the yearly misses have
				-- already charged the reputation, and charging again here would penalise the
				-- same failure twice.
				self.reputation:onContractUnfulfilled(contract)
			end
		end
	else
		-- Later years are always full — only the first is pro-rata.
		contract.quotaThisYear = contract.quotaPerYear
		contract.remainingLitres = contract.quotaPerYear
		contract.deliveredThisYear = 0
	end
end

function ContractStore:onYearMet(contract)
	contract.consecutiveMisses = 0

	-- Counted so the end of the term can tell an honoured contract from one that merely ran
	-- out the clock. See settleContractYear.
	contract.yearsMet = (contract.yearsMet or 0) + 1

	if contract.completionBonus > 0 then
		g_currentMission:addMoney(contract.completionBonus, contract.farmId,
			self.moneyTypeBonus, true, true)
	end

	if self.reputation ~= nil then
		self.reputation:onQuotaMet(contract)
	end
end

function ContractStore:onYearMissed(contract, quota, delivered)
	local shortfallFraction = (quota - delivered) / quota
	local annualValue = quota * contract.rate
	local penalty = annualValue * shortfallFraction * ContractStore.SHORTFALL_PENALTY_FACTOR

	if penalty > 0 then
		g_currentMission:addMoney(-penalty, contract.farmId, self.moneyTypePenalty, true, true)
	end

	contract.consecutiveMisses = contract.consecutiveMisses + 1

	if self.reputation ~= nil then
		self.reputation:onQuotaMissed(contract, shortfallFraction, penalty)
	end

	-- One bad harvest is survivable. Two in a row ends it.
	if contract.consecutiveMisses >= ContractStore.MAX_CONSECUTIVE_MISSES then
		contract.isComplete = true
		contract.wasTerminated = true

		if self.reputation ~= nil then
			self.reputation:onContractTerminated(contract)
		end
	end
end

function ContractStore:pruneCompleted()
	for i = #self.contracts, 1, -1 do
		if self.contracts[i].isComplete then
			table.remove(self.contracts, i)
		end
	end
end

-- ---------------------------------------------------------------------------
-- Queries
-- ---------------------------------------------------------------------------

function ContractStore:getContracts(farmId)
	local result = {}

	for _, contract in ipairs(self.contracts) do
		if contract.farmId == farmId then
			table.insert(result, contract)
		end
	end

	return result
end

-- ---------------------------------------------------------------------------
-- Persistence
-- ---------------------------------------------------------------------------

function ContractStore:getSavegamePath()
	local missionInfo = g_currentMission.missionInfo
	if missionInfo == nil or missionInfo.savegameDirectory == nil then
		return nil
	end

	return missionInfo.savegameDirectory .. "/" .. ContractStore.SAVEGAME_FILENAME
end

function ContractStore:save()
	local path = self:getSavegamePath()
	if path == nil then
		return
	end

	local xmlFile = createXMLFile("forwardContracts", path, "forwardContracts")
	if xmlFile == nil or xmlFile == 0 then
		Logging.error("[ForwardContracts] Could not create savegame file at %s", path)
		return
	end

	setXMLInt(xmlFile, "forwardContracts#nextId", self.nextId)

	for index, contract in ipairs(self.contracts) do
		local key = string.format("forwardContracts.contract(%d)", index - 1)

		setXMLInt(xmlFile, key .. "#id", contract.id)
		setXMLInt(xmlFile, key .. "#farmId", contract.farmId)
		setXMLInt(xmlFile, key .. "#clientId", contract.clientId or 0)
		setXMLString(xmlFile, key .. "#kind", contract.kind)
		setXMLString(xmlFile, key .. "#unit", contract.unit)

		-- Fill types are stored by name, never by index. Indices shift when the mod list
		-- changes, and a save that silently retargets a contract at a different product
		-- would be worse than one that drops it.
		local fillTypeName = g_fillTypeManager:getFillTypeNameByIndex(contract.fillTypeIndex)
		setXMLString(xmlFile, key .. "#fillType", fillTypeName or "")

		setXMLFloat(xmlFile, key .. "#rate", contract.rate)

		-- Stored as a plain string, not resolved back to a station object. It is a label the
		-- panel prints; a station that has since been demolished must not break a load.
		if contract.suggestedStation ~= nil then
			setXMLString(xmlFile, key .. "#suggestedStation", contract.suggestedStation)
		end

		if contract.rateMultiplier ~= nil then
			setXMLFloat(xmlFile, key .. "#rateMultiplier", contract.rateMultiplier)
		end

		-- Losing this on a save/load turns a forestry contract back into an annual one
		-- mid-term: `settleContractYear` would stop returning early, judge the term total
		-- against one year's deliveries, and terminate a contract whose trees are still
		-- growing. Silent, and unrecoverable.
		if contract.isTermQuota then
			setXMLBool(xmlFile, key .. "#isTermQuota", true)
		end

		-- THE DEADLINE, AND IT IS THE ONE FIELD THAT CAN STRAND A CONTRACT. `onDayChanged` is
		-- the only thing that judges a term contract; without `deadlineDay` it never fires, and
		-- the contract can be COMPLETED by delivering but can never FAIL. It would hold its
		-- place on the board for the rest of the save. `load` re-derives rather than allow it.
		if contract.termDays ~= nil then
			setXMLInt(xmlFile, key .. "#termDays", contract.termDays)
		end
		if contract.deadlineDay ~= nil then
			setXMLInt(xmlFile, key .. "#deadlineDay", contract.deadlineDay)
		end
		if contract.quotaTotal ~= nil then
			setXMLFloat(xmlFile, key .. "#quotaTotal", contract.quotaTotal)
		end

		-- The species BY NAME. An index would retarget the contract at a different tree if the
		-- mod list changed — the same reasoning as `#fillType` above, and for the same reason:
		-- a save that silently swaps the product is worse than one that drops the contract.
		if contract.speciesName ~= nil then
			setXMLString(xmlFile, key .. "#speciesName", contract.speciesName)
		end
		if contract.plantingFloor ~= nil then
			setXMLInt(xmlFile, key .. "#plantingFloor", contract.plantingFloor)
		end

		-- **LOSING THIS RESETS THE LEDGER TO ZERO AND MAKES THE CONTRACT UNFULFILLABLE.** The
		-- trees are already in the ground and cannot be planted again, so a player who did
		-- everything right would fail at the deadline with no way to recover and no error
		-- anywhere. Written unconditionally, including the zero, so a missing attribute on load
		-- is a genuine signal rather than "it happened to be nothing".
		if contract.speciesName ~= nil then
			setXMLInt(xmlFile, key .. "#planted", contract.planted or 0)
		end

		if contract.subTypeName ~= nil then
			setXMLString(xmlFile, key .. "#subTypeName", contract.subTypeName)
		end
		if contract.ageMin ~= nil then
			setXMLInt(xmlFile, key .. "#ageMin", contract.ageMin)
		end
		if contract.ageMax ~= nil then
			setXMLInt(xmlFile, key .. "#ageMax", contract.ageMax)
		end
		if contract.minCondition ~= nil then
			setXMLFloat(xmlFile, key .. "#minCondition", contract.minCondition)
		end
		if contract.minHealth ~= nil then
			setXMLFloat(xmlFile, key .. "#minHealth", contract.minHealth)
		end
		if contract.feedName ~= nil then
			setXMLString(xmlFile, key .. "#feedName", contract.feedName)
		end

		-- List 4 of 5 for the rebuild's spec fields. See signContract.
		if contract.contractType ~= nil then
			setXMLString(xmlFile, key .. "#contractType", contract.contractType)
		end
		if contract.overallBand ~= nil then
			setXMLFloat(xmlFile, key .. "#overallBand", contract.overallBand)
		end
		if contract.qualityFloor ~= nil then
			setXMLFloat(xmlFile, key .. "#qualityFloor", contract.qualityFloor)
		end
		if contract.prodFertFloor ~= nil then
			setXMLFloat(xmlFile, key .. "#prodFertFloor", contract.prodFertFloor)
		end
		if contract.gender ~= nil then
			setXMLString(xmlFile, key .. "#gender", contract.gender)
		end
		if contract.requiresCastrated ~= nil then
			setXMLBool(xmlFile, key .. "#requiresCastrated", contract.requiresCastrated)
		end
		setXMLFloat(xmlFile, key .. "#completionBonus", contract.completionBonus)
		setXMLFloat(xmlFile, key .. "#quotaPerYear", contract.quotaPerYear)
		setXMLFloat(xmlFile, key .. "#quotaThisYear", contract.quotaThisYear)
		setXMLFloat(xmlFile, key .. "#remaining", contract.remainingLitres)
		setXMLFloat(xmlFile, key .. "#deliveredThisYear", contract.deliveredThisYear)
		setXMLInt(xmlFile, key .. "#years", contract.years)
		setXMLInt(xmlFile, key .. "#yearIndex", contract.yearIndex)
		setXMLInt(xmlFile, key .. "#consecutiveMisses", contract.consecutiveMisses)
		setXMLInt(xmlFile, key .. "#yearsMet", contract.yearsMet or 0)

		if contract.expiryDay ~= nil then
			setXMLInt(xmlFile, key .. "#expiryDay", contract.expiryDay)
		end

		if contract.traitFloors ~= nil then
			local floorIndex = 0
			for trait, floor in pairs(contract.traitFloors) do
				local floorKey = string.format("%s.traitFloor(%d)", key, floorIndex)
				setXMLString(xmlFile, floorKey .. "#trait", trait)
				setXMLFloat(xmlFile, floorKey .. "#value", floor)
				floorIndex = floorIndex + 1
			end
		end
	end

	saveXMLFile(xmlFile)
	delete(xmlFile)
end

function ContractStore:load()
	local path = self:getSavegamePath()
	if path == nil or not fileExists(path) then
		return
	end

	local xmlFile = loadXMLFile("forwardContracts", path)
	if xmlFile == nil or xmlFile == 0 then
		return
	end

	self.contracts = {}
	self.nextId = getXMLInt(xmlFile, "forwardContracts#nextId") or 1

	local index = 0
	while true do
		local key = string.format("forwardContracts.contract(%d)", index)
		if not hasXMLProperty(xmlFile, key) then
			break
		end

		local unit = getXMLString(xmlFile, key .. "#unit")
		local fillTypeName = getXMLString(xmlFile, key .. "#fillType")
		local fillTypeIndex = fillTypeName ~= nil and fillTypeName ~= ""
			and g_fillTypeManager:getFillTypeIndexByName(fillTypeName) or nil

		-- **A HEAD CONTRACT HAS NO FILL TYPE, AND REQUIRING ONE SILENTLY DELETED EVERY
		-- LIVESTOCK CONTRACT ON RELOAD.**
		--
		-- `save` writes `#fillType` as `getFillTypeNameByIndex(nil) or ""`, so a livestock
		-- contract persists an EMPTY STRING; this guard then failed to resolve it and dropped
		-- the contract as though a mod had been removed. Found 2026-07-30 in log.txt after a
		-- restart — two live contracts destroyed, and the only trace was a warning that read
		-- like a missing mod rather than data loss.
		--
		-- It had never been exercised. §0.7 and §0.10 both proved the livestock loop end to end
		-- WITHIN one session, reading the savegame but never reloading it. **Reading the
		-- savegame is not the same test as loading it.**
		local isHeadContract = (unit == ContractStore.UNIT_HEAD)

		if fillTypeIndex == nil and not isHeadContract then
			-- The product no longer exists — a mod was removed. Drop the contract rather
			-- than retarget it, and say so, because it will look like a bug otherwise.
			Logging.warning("[ForwardContracts] Dropping contract %d: unknown fill type %q",
				index, tostring(fillTypeName))
		else
			local contract = {
				id = getXMLInt(xmlFile, key .. "#id") or index + 1,
				farmId = getXMLInt(xmlFile, key .. "#farmId"),
				clientId = getXMLInt(xmlFile, key .. "#clientId"),
				kind = getXMLString(xmlFile, key .. "#kind"),
				unit = getXMLString(xmlFile, key .. "#unit"),
				fillTypeIndex = fillTypeIndex,
				rate = getXMLFloat(xmlFile, key .. "#rate") or 0,
				rateMultiplier = getXMLFloat(xmlFile, key .. "#rateMultiplier"),
				isTermQuota = getXMLBool(xmlFile, key .. "#isTermQuota"),
				termDays = getXMLInt(xmlFile, key .. "#termDays"),
				deadlineDay = getXMLInt(xmlFile, key .. "#deadlineDay"),
				quotaTotal = getXMLFloat(xmlFile, key .. "#quotaTotal"),
				speciesName = getXMLString(xmlFile, key .. "#speciesName"),
				plantingFloor = getXMLInt(xmlFile, key .. "#plantingFloor"),
				planted = getXMLInt(xmlFile, key .. "#planted") or 0,
				suggestedStation = getXMLString(xmlFile, key .. "#suggestedStation"),
				subTypeName = getXMLString(xmlFile, key .. "#subTypeName"),
				ageMin = getXMLInt(xmlFile, key .. "#ageMin"),
				ageMax = getXMLInt(xmlFile, key .. "#ageMax"),
				minCondition = getXMLFloat(xmlFile, key .. "#minCondition"),
				minHealth = getXMLFloat(xmlFile, key .. "#minHealth"),
				feedName = getXMLString(xmlFile, key .. "#feedName"),

				-- List 5 of 5 for the rebuild's spec fields. See signContract.
				--
				-- **BACKWARD COMPATIBILITY: a contract saved before the rebuild has no
				-- `contractType`, and a nil would make it invisible to every type-aware path.**
				-- It defaults to SUPPLY because that is what the old generator produced — the
				-- only livestock contract that ever existed was an animal supply contract.
				-- Crop contracts get it too and simply never read it.
				contractType = getXMLString(xmlFile, key .. "#contractType") or "SUPPLY",
				overallBand = getXMLFloat(xmlFile, key .. "#overallBand"),
				qualityFloor = getXMLFloat(xmlFile, key .. "#qualityFloor"),
				prodFertFloor = getXMLFloat(xmlFile, key .. "#prodFertFloor"),
				gender = getXMLString(xmlFile, key .. "#gender"),
				requiresCastrated = getXMLBool(xmlFile, key .. "#requiresCastrated"),

				completionBonus = getXMLFloat(xmlFile, key .. "#completionBonus") or 0,
				quotaPerYear = getXMLFloat(xmlFile, key .. "#quotaPerYear") or 0,
				quotaThisYear = getXMLFloat(xmlFile, key .. "#quotaThisYear") or 0,
				remainingLitres = getXMLFloat(xmlFile, key .. "#remaining") or 0,
				deliveredThisYear = getXMLFloat(xmlFile, key .. "#deliveredThisYear") or 0,
				years = getXMLInt(xmlFile, key .. "#years") or 1,
				yearIndex = getXMLInt(xmlFile, key .. "#yearIndex") or 1,
				consecutiveMisses = getXMLInt(xmlFile, key .. "#consecutiveMisses") or 0,
				yearsMet = getXMLInt(xmlFile, key .. "#yearsMet") or 0,
				expiryDay = getXMLInt(xmlFile, key .. "#expiryDay"),
				isComplete = false,
			}

			local floorIndex = 0
			while true do
				local floorKey = string.format("%s.traitFloor(%d)", key, floorIndex)
				if not hasXMLProperty(xmlFile, floorKey) then
					break
				end

				local trait = getXMLString(xmlFile, floorKey .. "#trait")
				local value = getXMLFloat(xmlFile, floorKey .. "#value")
				if trait ~= nil and value ~= nil then
					contract.traitFloors = contract.traitFloors or {}
					contract.traitFloors[trait] = value
				end

				floorIndex = floorIndex + 1
			end

			-- A TERM CONTRACT WITH NO DEADLINE CAN NEVER BE JUDGED. `onDayChanged` is the only
			-- thing that settles one, and it needs `deadlineDay`; a nil there produces a
			-- contract that completes if you deliver and simply never ends if you do not.
			-- Silent, permanent, and it holds a slot forever.
			--
			-- Reachable two ways: a savegame written before day granularity landed, or a
			-- `#deadlineDay` that failed to parse. Re-derive from the day the save was loaded
			-- rather than drop the contract — the player is owed the term they signed, and
			-- restarting the clock is the error that favours them.
			if contract.isTermQuota and contract.deadlineDay == nil then
				contract.termDays = contract.termDays
					or math.max(1, math.floor((contract.years or 1) * self:getDaysPerYear() + 0.5))
				contract.deadlineDay = g_currentMission.environment.currentMonotonicDay
					+ contract.termDays

				Logging.warning("[ForwardContracts] Contract %d had no deadline; term restarted "
					.. "at %d days from today", contract.id, contract.termDays)
			end

			table.insert(self.contracts, contract)
			self.nextId = math.max(self.nextId, contract.id + 1)
		end

		index = index + 1
	end

	delete(xmlFile)
end
