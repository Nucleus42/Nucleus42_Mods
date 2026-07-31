-- Forward Contracts — Offers
--
-- The board. Decides what a farm is offered, how big, how long, and for how long the
-- offer stands. Server-side.
--
-- Two rules run through everything here:
--
--   * Never offer something the map cannot sell. Destination is validated at GENERATION
--     time, not enforced at delivery (HANDOFF.md §2, §4.2). Nobody tries to take wheat to
--     the oil mill, so nothing needs to stop them — the offer simply never exists.
--   * No magic-number tables. The original mod tuned 205 lines of per-fill-type
--     constants and still needed rebalancing twice. Everything here is derived from what
--     is actually on the map.

Offers = {}

local Offers_mt = Class(Offers)

Offers.KIND_SUPPLY = ContractStore.KIND_SUPPLY
Offers.KIND_SPOT = ContractStore.KIND_SPOT

-- Reputation tiers. Low reputation means small, short and few — not because of an
-- artificial gate but because nobody signs a decade-long agreement with a stranger
-- (HANDOFF.md §10: entry contracts are small deliveries, deliberately).
--
-- ⚠ `quotaScale` AND `BASE_ANNUAL_QUOTA` ARE GONE. DO NOT RESTORE THEM. 2026-07-31.
--
-- Crop, PRODUCT and SPOT contracts decided LITRES first — a flat 60,000 l/yr scaled by
-- tier — and let the money fall out of whatever the market happened to pay. That is the
-- SAME FAULT §4.1 rejected for livestock, in a different unit. §4.1 threw out a flat
-- headcount because *"25 head is 25 head whether that is chickens at £25 or horses at
-- £5,229"*; a flat litre quota is identical, because 60,000 l of straw and 60,000 l of
-- honey are "the same contract" and differ by 60:1 in money in a stock game.
--
-- Measured 2026-07-30 at 60,000 l/yr, vanilla, hard economy: STRAW £2,460/yr against
-- OLIVE_OIL £146,400/yr. Both cost one slot of the same budget.
--
-- `annualValue` is now the year's intended GROSS, and litres are derived from it — the
-- same order livestock has always used (`head = money / anchor`). The rungs are SHARED
-- WITH `ANIMAL_TIERS.supplyValue` on purpose: one budget, one pool of slots, so a slot
-- must be worth the same whatever it is spent on. User ruling 2026-07-31.
--
-- Four rungs, not five: tier 4 does not split 4a/4b here because a crop has no genetics
-- to raise the bar with.
--
-- NO WORKLOAD CAP, and the absence is deliberate. `ANIMAL_TIER1_STANDING_CAP` exists
-- because poultry's ENTRY rung came out bigger than its top rung — the ladder inverted.
-- That cannot happen here: `litres = money / rate`, the rate is fixed within a save, and
-- the money climbs, so the litres climb, for every fill type in every economy. A large
-- contract is therefore just a large contract, and judging whether it can be met is the
-- player's job (LIVESTOCK_DESIGN, "do not baby the player").
--
-- NOT SCALED BY ECONOMIC DIFFICULTY EITHER, and that is also a ruling rather than an
-- oversight. `EconomyManager.PRICE_MULTIPLIER` is `{3, 1.8, 1}` for easy/normal/hard and
-- applies to fill types only (`SellingStation.lua:400`) — never to animal sale prices
-- (`AnimalCluster.lua:195`). So on EASY a fixed £ ladder buys a third of the land it buys
-- on HARD. The user's decision, 2026-07-31: *"If someone is playing on easy they either
-- don't want the grind or they are new to the game... this mod should honour that."*
-- The numbers in the design notes were reasoned on HARD.
Offers.TIERS = {
	{ minReputation = 0.00, slots = 1, years = { 1, 2 }, annualValue = 30000 },
	{ minReputation = 0.25, slots = 2, years = { 2, 3 }, annualValue = 42000 },
	{ minReputation = 0.50, slots = 3, years = { 3, 5 }, annualValue = 60000 },
	{ minReputation = 0.75, slots = 4, years = { 4, 8 }, annualValue = 85000 },
}

-- Spread applied to a contract's VALUE, not to its litres. It used to sit on the quota,
-- which re-floated the very number the money ladder exists to fix — two tier-3 offers
-- would have been worth £45k and £75k while both claiming to be the same rung.
--
-- The negotiation needs something to bite on and this is it: the client's reservation is
-- a fraction of market VALUE (`Negotiation.PARAMS.reservation`), so a contract with no
-- value spread would haggle identically every time.
Offers.VALUE_VARIANCE = { 0.75, 1.25 }

-- Units the board may describe a contract's size in, beside its litres. See
-- Offers.getImpliedWorkload.
Offers.WORKLOAD_HECTARES = "hectares"
Offers.WORKLOAD_HEAD = "head"

Offers.MAX_SPOT_OFFERS = 2

-- Quiet days after the board's last spot order leaves — taken or lapsed — before a new batch
-- appears. See Offers:refreshSpotOffers for why this exists at all.
--
-- 3 days, matching OFFER_LIFETIME_DAYS. With a 1-2 day fuse that is a ~4-5 day cycle, so a
-- DEFAULT 12-DAY YEAR sees roughly 2-3 batches — about 5 spot orders a year, at £660-£5,100
-- each. Opportunistic money that shows up now and then, which is the brief.
--
-- **THIS IS A FEEL NUMBER AND IT IS THE USER'S TO SET.** Nothing derives it; it is picked to
-- make the cycle land near a handful a year at default settings, and it scales naturally
-- because a longer daysPerPeriod stretches the year around it.
Offers.SPOT_COOLDOWN_DAYS = 3

-- Spot orders pay above market. Simple raw products sit at the bottom of the band and
-- processed goods at the top — a bale of straw is a phone call, a tank of milk is a
-- logistics problem. Derived, not tabulated: see getComplexity.
Offers.SPOT_PREMIUM = { 0.10, 0.20 }
Offers.SPOT_DURATION_DAYS = { 1, 2 }

-- Share of the RUNG'S ANNUAL VALUE a single spot order is worth. Cut from 0.08-0.20 to
-- 0.02-0.05 on 2026-07-31 — REBASED, not rebalanced, and the distinction matters.
--
-- These constants were calibrated against the old flat 60,000 l quota. Re-pointing them at
-- the money ladder silently inflated them, because 20% of £85,000 is far more than 20% of
-- `60,000 l x 1.6 x £0.337`. A top-rung wheat order went from about £7,800 to £20,400
-- without anybody choosing that.
--
-- The user's ruling, on being shown it: *"They are a 'hey here is a quick way of making a
-- bit of extra money'. They are very opportunistic and should never be used as a concrete
-- income stream."*
--
-- 0.02-0.05 puts a TIER-1 order at £660-£1,800, which is within a whisker of the £623-£1,698
-- the old constants produced at that rung — so the entry feel is restored rather than
-- invented, and only the top of the ladder is flattened. Tier 4 lands at £1,870-£5,100.
--
-- **THE LADDER MUST STAY SHALLOW HERE.** Spot orders sit OUTSIDE the contract budget
-- (see Offers:refresh — the spot loop has no `remaining` check), two stand at once, and they
-- refresh on DAY_CHANGED with a 1-2 day fuse. That is roughly 12-24 offers across a
-- default 12-day year. At the old share a fully-stocked tier-4 farm could clear more from
-- spot orders than from every signed contract combined, which is precisely backwards.
Offers.SPOT_QUOTA_SHARE = { 0.02, 0.05 }

-- How long an offer sits on the board before it lapses.
Offers.OFFER_LIFETIME_DAYS = 3

-- A renewal stands twice as long. It is an invitation from a buyer who already knows you, not
-- a cold approach — and because it costs a contract slot, the player may need time to decide
-- what to let go of first. See Offers:createRenewalOffer.
Offers.RENEWAL_LIFETIME_DAYS = 6

Offers.KIND_ANIMAL = "animal"

--- The breeder ladder, and it runs BACKWARDS on purpose (HANDOFF.md §4.6).
---
--- Volume is the easy early game and quality is the endgame: a beginner is asked for a lot
--- of ordinary animals, a top-tier breeder for five to ten that nobody else can produce.
--- Each rung is a different farming problem rather than the same one scaled up, which is
--- what stops the livestock line being a headcount grind.
---
--- `floor` is a RAW trait value, not an aggregate score, and `traits` says how many of the
--- animal's traits must clear it. `nil` traits means every trait the animal has.
---
--- 1.40 is RL's "Very high" band (§5.2a). It is deliberately hard: purchasable stock tops
--- out near 0.90 and offspring are drawn N(mid-parent, 0.15) clamped to [0.25, 1.75]
--- (BreedingMath.lua:12, 141-166), so clearing it on four or five independent traits at
--- once is a long selective breeding programme and cannot be shopped for.
--- `rateMultiplier` is applied to EACH ANIMAL'S OWN sale value, not to a flat cash sum.
---
--- That distinction is the whole mechanic. Settlement is a hedge — it pays
--- (agreed - realised) per unit — so a fixed cash rate per head would top up LESS the
--- better the animal was, and the player would earn most by delivering their worst stock.
--- That is precisely backwards from what the livestock line is for.
---
--- As a multiplier it compounds instead: a top-tier animal fetches more at the dealer
--- because RL prices genetics, AND carries the better contract multiplier. Breed better,
--- earn more, twice over. That is the cycle §4.6 describes.
---
--- The bottom rung sits below market at 0.90 — an unknown farm trades price for certainty,
--- exactly as §4.3 and §4.5 require. Only the top rung clears market, and reaching it is
--- the reputation climb.
--- `ageSpan` is the window width as a fraction of the species' prime age, so the window
--- scales with the life cycle instead of being a fixed number of months. A cow primes at
--- 24 and a chicken at 6 (§4.6, derived from the sellPrice curve), so the top tier asks
--- for a cow at **24-28 months** and a chicken at 6-8 — the same difficulty expressed in
--- each species' own terms.
---
--- `breed` names a specific subtype drawn from the player's own herd. It appears only at
--- the top two rungs: a beginner is asked for animals, a renowned breeder is asked for a
--- LINE — "Angus at 24-28 months with every trait Very high".
--- `bonusShare` DECLINES as the multiplier rises, and it is what makes the bottom rung
--- signable at all.
---
--- CAUTION — the margin arithmetic below is not the whole value of an entry contract, and
--- reading it as if it were is a mistake this brief has already made once. The user's
--- framing, 2026-07-28: a below-market contract you can rely on beats a better price you
--- cannot. Losing 5-10% of margin to secure years of guaranteed income, a reputation that
--- compounds into larger and better-paid offers, and a breed record that makes repeat
--- offers likelier, is a good trade for a farmer — not a deal to decline and reroll.
--- **Never present or tune a bottom-rung offer as though profit maximisation were the only
--- axis.** The bonus below exists to keep the nominal margin defensible; the contract's real
--- value is certainty plus the ladder.
---
--- Without it the entry contract is strictly bad: at 0.90x, selling 25 animals freely
--- returns 25.0V against 22.5V for signing and honouring the contract, so a thinking
--- player declines every offer and the ladder never starts. The bonus restores the
--- compensation that §4.3 assumes a below-market rate carries — crops get it through
--- negotiation, and livestock is not negotiated, so it is posted instead.
---
--- It also reads right in the fiction: an unknown supplier is paid for SHOWING UP, a
--- renowned breeder is paid for the ANIMALS. By the top rung the multiplier is doing all
--- the work and the bonus is gone.
--- `targetValue` is the contract's intended ANNUAL gross, and headcount is derived from it
--- rather than posted directly.
---
--- A flat headcount is the bug that produced a £274,530 entry contract in play on
--- 2026-07-28: 25 head is 25 head whether that is chickens at £25 or RL horses at £5,229,
--- so the same nominal difficulty spanned a ~200x range in money. The ladder is supposed to
--- measure how hard the ANIMALS are, not which species the roll happened to name.
---
--- `head` is now a clamp, not a range. It keeps the derived count inside something that
--- reads like a farm rather than a spreadsheet — a poultry contract lands at the top of it
--- and a cattle contract near the bottom, which is the correct shape for both.
---
--- THE FIVE RUNGS. Replaces the four-rung table entirely — LIVESTOCK_DESIGN §2.1.
---
--- Tier 4 is **ONE reputation tier with the variant rolled per offer**, 80:20 in favour of 4a.
--- There is no fifth reputation threshold: 4b is a choice the player may decline, not a rank
--- they have to reach. User: *"If they think they can reach Extremely Good then they can choose
--- to. They don't have to take the contract."*
---
--- **THE TWO BAND SCALES ARE DIFFERENT VOCABULARIES AND BOTH ARE RL'S OWN.** `overallBand` is
--- the aggregate (Bad / Average / Good / Very good / Extremely good) on RL's MENU ladder — see
--- `Animals.OVERALL_BANDS` for why the menu ladder and not the HUD one. `qualityBand` and
--- `prodFertBand` are per-trait (Low / Average / High / Very high / Extremely high) against the
--- raw 0.25-1.75 value. Stating each in its own scale's words means the contract and RL's info
--- box say the SAME WORD about the same animal. Never fuse them.
---
--- A **SUPPLY** contract states `overallBand` AND `qualityBand` — two numbers, not five, and
--- NOT a return to the withdrawn all-traits rule (§2.2). The quality floor exists because
--- overall is a mean: without it an animal could sit at quality 0.25 and still read "Good
--- overall", so the contract would ask for good cattle and honestly be worth the price of poor
--- ones — and the player could farm the hedge by delivering high-overall, low-quality stock.
---
--- A **BREEDING** contract states `prodFertBand` on productivity AND fertility, each clearing
--- on its own rather than on average, and states no quality floor at all — the buyer does not
--- care about meat on an animal they intend to milk or shear.
---
--- `supplyValue` / `breedingValue` are the contract's intended ANNUAL gross, and headcount is
--- DERIVED from them (§4.1). A flat headcount is the bug that produced a £274,530 entry
--- contract on 2026-07-28: 25 head is 25 head whether that is chickens or horses, a ~200x range
--- in money for the same nominal difficulty.
---
--- **`breedingPremium` is BORROWED, NOT INVENTED** (§4.7). A breeding contract names
--- `productivity` and `fertility`, and those two traits move the sale price by precisely
--- nothing — so a tier-1 heifer and a tier-4b heifer are worth the same at the dealer, and a
--- static anchor would make the HARDEST breeding contract demand the MOST animals. The premium
--- is the factor the SUPPLY anchor climbs across the same rungs: a better breeding animal is
--- worth more to its buyer in the same proportion that a better meat animal is. No new balance
--- constant is introduced. Recomputed on the menu ladder 2026-07-30 (was 1.00/1.23/1.65/…).
---
--- `years`, `ageSpan`, `rateMultiplier`, `bonusShare`, `minCondition` and `minHealth` are
--- carried over unchanged and are still the measured/settled values — see §3.3, §3.4 and
--- HANDOFF §0.6's re-based condition floors.
Offers.ANIMAL_TIERS = {
	{ key = "1",  minReputation = 0.00, overallBand = 0.20, overallBandKey = "bad",           qualityBand = 0.70, traitBandKey = "low",           prodFertBand = 0.70, supplyValue = 30000, breedingValue = 12000, breedingPremium = 1.00, years = { 1, 3 }, rateMultiplier = { 0.80, 0.90 }, ageSpan = 1.00, bonusShare = 0.15, minCondition = 0.80, minHealth = 0.50 },
	{ key = "2",  minReputation = 0.25, overallBand = 0.40, overallBandKey = "average",       qualityBand = 0.90, traitBandKey = "average",       prodFertBand = 0.90, supplyValue = 42000, breedingValue = 17000, breedingPremium = 1.27, years = { 2, 3 }, rateMultiplier = { 0.95, 1.05 }, ageSpan = 0.60, bonusShare = 0.10, minCondition = 0.95, minHealth = 0.65 },
	{ key = "3",  minReputation = 0.50, overallBand = 0.60, overallBandKey = "good",          qualityBand = 1.10, traitBandKey = "high",          prodFertBand = 1.10, supplyValue = 60000, breedingValue = 24000, breedingPremium = 1.59, years = { 3, 5 }, rateMultiplier = { 1.10, 1.20 }, ageSpan = 0.35, bonusShare = 0.05, minCondition = 1.10, minHealth = 0.80, requiresFullFeed = true },
	{ key = "4a", minReputation = 0.75, overallBand = 0.80, overallBandKey = "veryGood",      qualityBand = 1.40, traitBandKey = "veryHigh",      prodFertBand = 1.40, supplyValue = 85000, breedingValue = 34000, breedingPremium = 2.09, years = { 4, 6 }, rateMultiplier = { 1.25, 1.40 }, ageSpan = 0.17, bonusShare = 0.00, minCondition = 1.25, minHealth = 0.90, requiresFullFeed = true },
	{ key = "4b", minReputation = 0.75, overallBand = 0.95, overallBandKey = "extremelyGood", qualityBand = 1.65, traitBandKey = "extremelyHigh", prodFertBand = 1.65, supplyValue = 85000, breedingValue = 34000, breedingPremium = 2.66, years = { 4, 6 }, rateMultiplier = { 1.25, 1.40 }, ageSpan = 0.17, bonusShare = 0.00, minCondition = 1.25, minHealth = 0.90, requiresFullFeed = true },
}

--- Chance that a tier-4 offer is the rarer, harder 4b variant. §3.4, revised from an earlier
--- 50/50 in the same session — do not restore that.
Offers.ANIMAL_TIER4B_CHANCE = 0.20

--- Reputation tier index -> the two ANIMAL_TIERS rows it may roll between.
--- Tiers 1-3 are single rungs; tier 4 rolls 4a or 4b.
Offers.ANIMAL_TIER4_INDEX = 4

--- The most animals a TIER-1 contract will ever ask a farm to have on the ground at once.
---
--- **THIS EXISTS BECAUSE THE ENTRY RUNG CAME OUT BIGGER THAN THE TOP RUNG FOR POULTRY.**
--- §4.2 set the £30,000 entry target by asking how big a herd a beginner can keep, and answered
--- in cattle — *"14 cattle or 37 pigs is reasonable to start with"*. Applied to a £14 bird the
--- same £30,000 buys 2,132 chickens a year, which is 3,376 birds standing and about 13.5 barns.
--- The user had already endorsed 1,780 birds (11.3 barns) at TIER 4. Poultry therefore had no
--- ladder at all — it opened above where it was meant to finish.
---
--- Standing herd, not headcount, is the measure of work: `head * deliveryAge / 12`, since a
--- supply farm holds every cohort still growing (§4.7's "three cohorts on the ground"). Sheep
--- look alarming at 109 head and are only 73 standing, because they deliver at 8 months.
---
--- **CALIBRATED, AND SAYING SO PLAINLY.** 1,200 is a round number chosen to leave every figure
--- the user endorsed untouched — cattle 42 standing, pigs 74, ewes 73, goats 41 all sit far
--- below it and are completely unaffected — while bringing poultry to ~758 birds a year, which
--- is the 750 they settled on (§4.5a). It binds on exactly one species today and self-applies
--- to any cheap species a mod adds.
Offers.ANIMAL_TIER1_STANDING_CAP = 1200

Offers.KIND_ANIMAL_SUPPLY = "SUPPLY"
Offers.KIND_ANIMAL_BREEDING = "BREEDING"
Offers.KIND_ANIMAL_PRODUCT = "PRODUCT"

--- The age a contract of this kind takes delivery at.
---
--- **DIRECTION IS NOT SYMMETRIC AND THAT IS THE POINT** (§2.4). SUPPLY runs UP TO peak, because
--- value FALLS afterwards — a cow drops from ~2,400 to ~1,400 between 36 and 60 months — so
--- late delivery must be the failure rather than the default. BREEDING runs UP FROM breeding
--- age, because younger is better: the buyer is paying for the productive years ahead of her,
--- and every extra month is life they do not get.
---
--- Timing breeding stock by PRIME would time a dairy heifer by how good she would be as beef,
--- which is the one thing her buyer explicitly does not care about.
function Offers.getAnimalDeliveryAge(subType, kind)
	if kind == Offers.KIND_ANIMAL_BREEDING then
		return Animals.getBreedingAge(subType)
	end

	return (Animals.getPeakAge(subType))
end

--- What one animal on this rung's band is worth, before the contract multiplier.
function Offers.getAnimalAnchor(subType, tier, kind)
	if type(subType) ~= "table" or type(tier) ~= "table" then
		return nil
	end

	if kind ~= Offers.KIND_ANIMAL_BREEDING then
		return Animals.getBandAnchorValue(subType, tier.overallBand, tier.qualityBand)
	end

	-- §4.7: the BREEDING anchor assumes quality and metabolism at Average (1.0), because the
	-- contract names only productivity and fertility and a player selecting for those has no
	-- reason to level the other two. Stage 3's "all traits at the band" logic does not carry
	-- over — it rested on players levelling everything, which they only do when asked to.
	local age = Animals.getBreedingAge(subType)
	if age == nil then
		return nil
	end

	local curve, target = Animals.getWeightCurve(subType, 1.0, false)
	if curve == nil then
		return nil
	end

	local base = Animals.getPriceAtAge(subType, age, 1.0, curve[age], target, false)
	if base == nil then
		return nil
	end

	return base * (tier.breedingPremium or 1.0)
end

--- The annual money target for each of the five rungs, for THIS species and kind.
---
--- Normally this is just the shared ladder off `ANIMAL_TIERS` — 30/42/60/85k for supply,
--- 12/17/24/34k for breeding. It only diverges when the entry rung would put an unreasonable
--- standing herd on the ground, which today means poultry and nothing else.
---
--- When it does bind, tier 1 drops to what the cap allows and the ladder **interpolates
--- geometrically back up to the shared tier-4 figure**, so every species converges on the same
--- top rung and only the entry differs. For chickens that turns a flat, inverted 2,132 -> 1,780
--- into a real climb of ~758 -> ~1,782.
---
--- Returns the five values and whether the species was scaled.
function Offers.getAnimalMoneyLadder(subType, kind)
	local tiers = Offers.ANIMAL_TIERS
	local field = (kind == Offers.KIND_ANIMAL_BREEDING) and "breedingValue" or "supplyValue"

	local money = {}
	for i, tier in ipairs(tiers) do
		money[i] = tier[field]
	end

	local deliveryAge = Offers.getAnimalDeliveryAge(subType, kind)
	local anchor = Offers.getAnimalAnchor(subType, tiers[1], kind)

	if deliveryAge == nil or deliveryAge <= 0 or anchor == nil or anchor <= 0 then
		return money, false
	end

	-- Mid of the rung's multiplier band, so the cap does not move with a lucky roll.
	local band = tiers[1].rateMultiplier
	local perHead = anchor * ((band[1] + band[2]) / 2)

	-- Standing herd = annual head x delivery age in years. Invert it for the head the cap allows.
	local maxHead = Offers.ANIMAL_TIER1_STANDING_CAP * 12 / deliveryAge
	local capped = maxHead * perHead

	if capped >= money[1] then
		return money, false
	end

	-- Geometric so every rung is the same proportional step, matching the shared ladder's own
	-- +41% shape. Rung 4b shares 4a's target (§4.2) and is not interpolated.
	local top = tiers[4][field]
	local ratio = top / capped

	for i = 1, 4 do
		money[i] = capped * ratio ^ ((i - 1) / 3)
	end
	money[5] = tiers[5][field]

	return money, true
end

--- The longest life cycle the mod will ever contract for, in months.
---
--- Set to 84 (7 years) by the user's decision on 2026-07-28, deliberately ABOVE the longest
--- term any tier offers (6 years), so that horses are admitted. RL horses need 80 months to
--- breed from scratch (22 breeding age + 11 gestation + 47 to prime), which a 72-month bar
--- excluded by eight months.
---
--- What that means in play, and it is a real trade the user accepted: a horse contract is
--- won by buying young stock and growing it into the age window, because no single term is
--- long enough to breed one from scratch. The dealer may not be holding suitable young
--- horses when you sign — so it is a gamble, not a guaranteed route. The genetic floors
--- still apply either way, and clearing them on bought stock is no easier.
Offers.ANIMAL_MAX_TERM_MONTHS = 7 * 12

--- Never ask for a window narrower than this. A two-month slot is already tight at 1-day
--- months, and rounding a small prime age down could otherwise produce a single-month
--- window that is missable by one day.
Offers.ANIMAL_MIN_AGE_SPAN = 2

--- Difficulty setting for the top-tier floor. Tunable, but hard out of the box — §4.6 is
--- explicit that it must not be soft by default.
Offers.ANIMAL_FLOOR_SCALE = 1.0

--- Ceiling on livestock OFFERS shown at once, independent of how many may be SIGNED.
--- The signing limit is the single CONTRACT BUDGET (§6); this only stops the board filling
--- with animal offers a farm has no slot for.
Offers.MAX_ANIMAL_OFFERS = 3

function Offers.new(contractStore)
	local self = setmetatable({}, Offers_mt)

	self.contractStore = contractStore
	self.offers = {}
	self.nextOfferId = 1

	self.reputation = nil -- optional, see setReputationProvider
	self.clients = nil    -- optional, see setClientProvider

	self.sellableCache = nil

	-- [farmId] = monotonic day the next batch of spot orders may appear. See refresh.
	-- Not persisted: losing it costs one extra quiet cycle after a load, which is a far
	-- cheaper failure than a save format change.
	self.spotResumeDay = {}

	return self
end

function Offers:setReputationProvider(provider)
	self.reputation = provider
end

--- Seam to Animals. Without it no livestock offers are generated at all — which is the
--- correct degradation, since we would have no way to price or judge them.
function Offers:setAnimalsProvider(provider)
	self.animals = provider
end

function Offers:setClientProvider(provider)
	self.clients = provider
end

function Offers:subscribe()
	g_messageCenter:subscribe(MessageType.DAY_CHANGED, self.onDayChanged, self)
end

function Offers:unsubscribe()
	g_messageCenter:unsubscribeAll(self)
end

-- ---------------------------------------------------------------------------
-- What this map can actually buy
-- ---------------------------------------------------------------------------

--- Stations that exist only as the far end of a train line, keyed by station object.
---
--- On Goldcrest Valley the train's destination is a named selling station like any other,
--- so it turns up in economyManager.sellingStations and was being suggested as a buyer.
--- It is not somewhere you can drive a trailer to — it is the "hire the train and sell the
--- load" endpoint — so suggesting it sends the player somewhere they cannot deliver.
---
--- Resolved two ways because spec.sellingStation is filled in lazily, and only when the
--- train has a limited range (PlaceableTrainSystem.lua:445-452): the already-resolved
--- station if present, otherwise the placeable named by drivingRangeSellingStationId.
---
--- This suppresses the SUGGESTION only. Deliveries are advisory, never enforced (§10), and
--- DeliveryWatch still counts anything genuinely tipped there. What must not count is the
--- train's own sale, and that is excluded at its own source (§3.7).
function Offers:getTrainOnlyStations()
	local excluded = {}

	local placeableSystem = g_currentMission.placeableSystem
	if placeableSystem == nil or placeableSystem.placeables == nil then
		return excluded
	end

	for _, placeable in ipairs(placeableSystem.placeables) do
		local spec = placeable.spec_trainSystem

		if spec ~= nil then
			if spec.sellingStation ~= nil then
				excluded[spec.sellingStation] = true
			elseif spec.drivingRangeSellingStationId ~= nil then
				local target = placeableSystem:getPlaceableByUniqueId(spec.drivingRangeSellingStationId)
				if target ~= nil and target.spec_sellingStation ~= nil then
					excluded[target.spec_sellingStation.sellingStation] = true
				end
			end
		end
	end

	return excluded
end

--- ⚠ WOOD IS THE ONE FILL TYPE WHOSE LISTED PRICE IS A LIE. See FORESTRY.md §1.1-1.2.
---
--- `SellingStation:sellFillType` takes `extraAttributes.price` IN PLACE OF the whole price
--- expression (`objects/SellingStation.lua:374-377`), and `WoodUnloadTrigger:processWood`
--- always supplies one (`triggers/WoodUnloadTrigger.lua:87`) — computed as
--- `splitType.pricePerLiter * qualityScale * defoliageScale * lengthScale` (`:159`).
---
--- So wood delivered through a wood trigger NEVER reaches `getEffectiveFillTypePrice`, and
--- therefore never sees the seasonal factor, the price drop, the station multiplier or
--- `EconomyManager.PRICE_MULTIPLIER`. But `getSellableFillTypes` reads exactly that function,
--- and WOOD is declared at `pricePerLiter="1.0"` with no seasonal factors
--- (`maps_fillTypes.xml:661`). The mod believed wood fetched £1.00/l. It fetches ~£0.367.
---
--- Under money-first that made `quota = annualValue / marketRate` come out THREE TIMES too
--- small, and left `Settlement.onDelivery` topping up 67% of the contract's value every year
--- in one direction. That is not a hedge, it is a subsidy with a delivery requirement.
---
--- **MEASURED IN GAME 2026-08-01, three species, whole trees felled and delivered as-is.**
--- Volumes are the ones already validated to the litre in FORESTRY.md's yield section.
---
---   | species        | income | volume (l) | realised £/l | pricePerLiter |   K   |
---   | oak            | £7,190 |     21,638 |       0.3323 |           0.9 | 0.369 |
---   | lodgepolePine  | £2,061 |      5,325 |       0.3870 |           1.0 | 0.387 |
---   | americanElm    | £4,991 |     20,631 |       0.2419 |           0.7 | 0.346 |
---
--- Spread 1.12x across three price points and a 4x range of tree volume. The threshold
--- registered BEFORE the measurements was "species-specific if more than 25% apart"; it came
--- in at 12%, so this is ONE constant and not a table.
---
--- **This is the deliberate second exception to the no-magic-numbers rule**, alongside the
--- mature-volume table, and for the same reason: it cannot be read at runtime without felling
--- a tree. Unlike that table it is a single scalar and needs no per-species data.
---
--- CAVEAT, RECORDED SO IT IS A CHOICE AND NOT AN OVERSIGHT: taken on HARD — **confirmed by the
--- user 2026-08-01** — where `economicDifficulty / numDifficulties` is 1 and the `MathUtil.lerp`
--- at `WoodUnloadTrigger.lua:155-156` is inert, so the scales are raw. On easier settings the
--- quality and defoliage penalties soften toward 1, so K rises and the derived quota runs
--- slightly high. Consistent with the 2026-07-31 ruling to honour the player's difficulty
--- setting rather than compensate for it.
---
--- ⚠ **A CORRECTION TO A CORRECTION — DO NOT RE-DERIVE THE DIFFICULTY FROM A PRICE.** For a few
--- hours this comment claimed the measurements were taken on EASY, inferred from `fcSellable`
--- reporting wood at 1.101 /l: `1.0 x 3 x 0.367`, and 3 is `PRICE_MULTIPLIER[1]`. **The save is
--- on hard and always was.** The 3x came from somewhere else in `getEffectiveFillTypePrice` —
--- most likely a great demand on WOOD at that station (`EconomyManager.lua:310` calls
--- `setPriceMultiplier` with the demand's own multiplier), which is transient and would have
--- made a wood contract's rate swing by 3x depending on the minute it was generated in.
---
--- **That makes the raw-base fix more necessary, not less.** It also means the old code's fault
--- was never "the difficulty multiplier"; it was "every multiplier", exactly as this comment
--- block said in the first place. One number is not evidence of a setting.
---
--- WOODCHIPS IS NOT AFFECTED and must not be adjusted — chips arrive through an ordinary
--- unload trigger with no `extraAttributes`, so their listed price is the real one.
Offers.WOOD_REALISED_SHARE = 0.367

--- The rate a delivery of this fill type will ACTUALLY realise, given the station's listed
--- price. Identity for everything except WOOD; see WOOD_REALISED_SHARE for why.
---
--- Species-agnostic on purpose. A tier-1 wood contract cannot know what will be felled, so it
--- anchors on WOOD's own declared price. Real species run 0.6-1.2 and the common ones cluster
--- at 0.7-0.9, so the anchor sits ABOVE most timber and the contract quietly pays about 10%
--- over free-market selling — which is precisely the "wood price + a modest %" FORESTRY.md has
--- carried as an untuned constant since 2026-07-28. **It is derived, not tuned.** User ruling
--- 2026-08-01, offered the neutral alternative of averaging every split type at runtime:
--- *"Keep the anchor as is."*
--- ⚠ **IT TAKES THE RAW DECLARED PRICE, NOT THE EFFECTIVE ONE, AND THAT DISTINCTION IS THE
--- WHOLE FUNCTION.** The first version of this multiplied `getEffectiveFillTypePrice` by K and
--- shipped. It was wrong within the hour: `fcSellable` on the user's save reported
--- **1.101 /l** for wood, which is `1.0 x 3 x 0.367` — the difficulty multiplier, applied to a
--- price that never sees it.
---
--- `getEffectiveFillTypePrice` (`SellingStation.lua:388-401`) layers on the seasonal factor,
--- the random delta, the station's great-demand `priceMultipliers` and
--- `EconomyManager.getPriceMultiplier()`. **A wood sale reaches NONE of them**, because
--- `extraAttributes.price` replaces the whole expression at `:374-377`. So scaling the effective
--- price by K carries every one of those multipliers into a number that must not have any.
---
--- On EASY that is a 3x error — worse than the bug phase 0 was written to fix.
---
--- The base price is what `addAcceptedFillType` is seeded from in the first place
--- (`SellingStation.lua:82`: `fillType.pricePerLiter * priceScale`), so this is the same
--- quantity the station starts from, taken before the economy touches it.
---
--- Returns nil when the base price cannot be read, and the caller drops the fill type. Silence
--- beats a wood contract priced off a number we could not verify.
function Offers.getRealisedRate(fillTypeIndex, effectivePrice)
	if FillType == nil or fillTypeIndex ~= FillType.WOOD then
		return effectivePrice
	end

	local fillType = g_fillTypeManager ~= nil
		and g_fillTypeManager:getFillTypeByIndex(fillTypeIndex) or nil
	local base = type(fillType) == "table" and fillType.pricePerLiter or nil

	if type(base) ~= "number" or base <= 0 then
		return nil
	end

	return base * Offers.WOOD_REALISED_SHARE
end

--- Selling stations that belong to a PRODUCTION POINT somebody owns, keyed by station object.
---
--- A production point's selling station is registered like any other
--- (`objects/ProductionPoint.lua:286`), so `getSellableFillTypes` sees every sawmill, bakery
--- and carpenter on the map. But `ProductionPoint.lua:221` overrides `getSkipSell` to return
--- **true** whenever the delivering farm owns or can access the placeable — so `sellFillType`
--- never runs, no money changes hands, and `DeliveryWatch` sees nothing at all.
---
--- Tipping at your OWN production point is feeding it, not selling to it. Counting it as a
--- market meant the board could name a buyer that pays nothing and credits no contract, and
--- could take its `marketRate` from a station that never trades.
---
--- **Found while building forestry, but it was never a wood-only fault.** Every wood
--- destination in vanilla data is a production point (sawmill, carpenter, paper factory) with
--- the sole exception of biomassHeatingPlant, so wood is where it bites hardest — but a farm
--- that owns a bakery had the same hole for FLOUR.
---
--- `AccessHandler.EVERYONE` is 0 (`farms/AccessHandler.lua:2`) and means unowned, which is what
--- every map's default production point is. Those stay in the pool; they are real buyers.
---
--- Farm-agnostic rather than per-farm, because the cache is shared and this mod is single
--- player first (HANDOFF.md). In multiplayer a rival farm's production point would be excluded
--- for everyone, which is wrong but harmless and is NOT worth building for now.
function Offers:getOwnedProductionStations()
	local owned = {}

	local chainManager = g_currentMission.productionChainManager
	if chainManager == nil or chainManager.productionPoints == nil then
		return owned
	end

	for _, productionPoint in ipairs(chainManager.productionPoints) do
		local station = productionPoint.unloadingStation
		local placeable = productionPoint.owningPlaceable

		if station ~= nil and placeable ~= nil and placeable.getOwnerFarmId ~= nil then
			local ownerFarmId = placeable:getOwnerFarmId()

			if ownerFarmId ~= nil and ownerFarmId ~= 0 then
				owned[station] = true
			end
		end
	end

	return owned
end

--- Every fill type some station on this map will pay for, with its best current price.
---
--- Built from the stations themselves, so a map with no oil mill simply never generates
--- sunflower contracts, and a mod that adds a buyer makes its product contractable with
--- no changes here. That also means a buyer BUILT LATER becomes contractable on the next
--- board rebuild with no code change — see the cache note below.
---
--- The rate stored is what a delivery will REALISE, not what the station lists. They are the
--- same number for everything except WOOD — see Offers.getRealisedRate.
function Offers:getSellableFillTypes()
	if self.sellableCache ~= nil then
		return self.sellableCache
	end

	local economyManager = g_currentMission.economyManager
	if economyManager == nil or economyManager.sellingStations == nil then
		return {}
	end

	local sellable = {}
	local trainOnly = self:getTrainOnlyStations()
	local ownedProduction = self:getOwnedProductionStations()

	for _, entry in ipairs(economyManager.sellingStations) do
		local station = entry.station

		if station ~= nil and station.acceptedFillTypes ~= nil and not trainOnly[station]
			and not ownedProduction[station] then
			for fillTypeIndex, _ in pairs(station.acceptedFillTypes) do
				-- Giants uses this same guard when saving station stats: a zero original
				-- price means the station lists the type but does not really trade it.
				local original = station.originalFillTypePrices ~= nil
					and station.originalFillTypePrices[fillTypeIndex] or 0

				local price = original > 0 and Offers.getRealisedRate(fillTypeIndex,
					station:getEffectiveFillTypePrice(fillTypeIndex, ToolType.UNDEFINED) or 0) or nil

				-- A nil rate means we could not establish an honest price — currently only wood
				-- with an unreadable base price. Dropping the fill type is the right
				-- degradation: money-first DIVIDES by this, so a wrong rate is a wrong contract.
				if price ~= nil and price > 0 then
					local existing = sellable[fillTypeIndex]
					if existing == nil then
						sellable[fillTypeIndex] = {
							fillTypeIndex = fillTypeIndex,
							marketRate = price,
							stationName = station:getName(),
						}
					elseif price > existing.marketRate then
						existing.marketRate = price
						existing.stationName = station:getName()
					end
				end
			end
		end
	end

	self.sellableCache = sellable

	return sellable
end

--- Fill types produced by a production point somewhere on this map.
---
--- Stands in for "how complex is this to supply". A product that comes out of a
--- production chain took inputs, a building and time; a product that comes off a field
--- took a harvester. That distinction is readable straight off the map, which is why it
--- is used instead of a hand-tuned complexity table.
function Offers:getProcessedFillTypes()
	local processed = {}

	local chainManager = g_currentMission.productionChainManager
	if chainManager == nil or chainManager.productionPoints == nil then
		return processed
	end

	for _, productionPoint in ipairs(chainManager.productionPoints) do
		if productionPoint.outputFillTypeIds ~= nil then
			for fillTypeIndex, _ in pairs(productionPoint.outputFillTypeIds) do
				processed[fillTypeIndex] = true
			end
		end
	end

	return processed
end

--- 0..1. Raw field products near zero, production outputs near one.
function Offers:getComplexity(fillTypeIndex, processed)
	return processed[fillTypeIndex] and 1 or 0
end

-- ---------------------------------------------------------------------------
-- Generation
-- ---------------------------------------------------------------------------

function Offers:getReputation(farmId)
	if self.reputation == nil then
		return 0
	end

	return self.reputation:getReputation(farmId) or 0
end

function Offers:getTier(reputation)
	local tier = Offers.TIERS[1]

	for _, candidate in ipairs(Offers.TIERS) do
		if reputation >= candidate.minReputation then
			tier = candidate
		end
	end

	return tier
end

function Offers:getClient(farmId, isProcessed)
	if self.clients == nil then
		-- No registry: a transient anonymous client keeps the board functional, with zero
		-- relationship so terms are as cold as they can be.
		return { id = 0, name = "Unknown buyer", relationship = 0, size = 1 }
	end

	return self.clients:getClientForOffer(farmId, isProcessed)
end

--- Top the board back up to the farm's slot allowance.
function Offers:refresh(farmId)
	local reputation = self:getReputation(farmId)
	local tier = self:getTier(reputation)

	local sellable = self:getSellableFillTypes()
	local candidates = {}
	for _, entry in pairs(sellable) do
		table.insert(candidates, entry)
	end

	if #candidates == 0 then
		return
	end

	local processed = self:getProcessedFillTypes()

	-- ANIMAL PRODUCTS ARE NOT CROPS AND MUST NOT SHARE THE POOL (§5.1). Before this split a
	-- farm with no cattle could be handed a milk contract, because the only test was whether
	-- SOME station bought the fill type.
	-- Split so a product offer can be LABELLED as produce, not so it can be gated. Animal
	-- products are offered as freely as crops — only ANIMAL contracts are gated, and by feed
	-- crossover rather than by capability. See the note in Animals.lua.
	local cropCandidates, productCandidates = self:splitCandidates(sellable)

	-- ASSIGNED UNCONDITIONALLY, and it matters. Guarding this on `#cropCandidates > 0` would
	-- leave `candidates` holding the UNSPLIT list on a map that sells nothing but animal
	-- products — so the crop path would go straight back to offering milk to a farm with no
	-- cattle, which is the whole fault being fixed. An empty crop pool must mean no crop offers.
	candidates = cropCandidates

	local supplyCount, spotCount, animalCount, productCount = self:countOffers(farmId)

	-- THE BUDGET BOUNDS EVERY TYPE, and each type is capped against the WHOLE remaining
	-- allowance rather than a share of it. So a farm with two slots left sees both crop and
	-- livestock choices and decides which to spend them on — *"The choice is the point."*
	-- Signing re-checks, so showing more options than the budget can absorb is deliberate and
	-- harmless; carving the allowance up in advance would take the decision off the player.
	--
	-- Spot orders sit outside all of this (§6) and keep their own cap.
	local remaining = self:getRemainingBudget(farmId, reputation)

	while supplyCount < math.min(tier.slots, remaining) do
		self:createSupplyOffer(farmId, candidates, tier, reputation, processed)
		supplyCount = supplyCount + 1
	end

	-- SPOT ORDERS ARRIVE AS A BATCH AND ARE NEVER TOPPED UP. User ruling 2026-07-31:
	-- *"They should only regen when the previous ones have lapsed... These are 'one off'
	-- contracts that are not supposed to add to workload in any meaningful way."*
	--
	-- The old loop refilled to MAX_SPOT_OFFERS every single day, so TAKING one summoned its
	-- replacement the next morning and the board became a conveyor belt. Two always standing,
	-- refreshed daily on a 1-2 day fuse, is 12-24 orders across a default 12-day year — an
	-- income stream by accident, which is exactly what a spot order must not be.
	--
	-- Now: the board empties, a quiet gap follows, then a fresh batch. Accepting and lapsing
	-- are treated identically on purpose — the gap is the point, and making acceptance refill
	-- faster would reward hoovering them up.
	self:refreshSpotOffers(farmId, spotCount, candidates, tier, processed)

	-- OFFERS SHOWN, not contracts signable. How many a farm may hold is the single CONTRACT
	-- BUDGET (§6), checked inside createAnimalOffer against what is actually signed across every
	-- type; this loop only bounds how many livestock choices sit on the board at once.
	-- createAnimalOffer returns nil once the farm is at its limit, so the loop must not retry.
	--
	-- **`ANIMAL_TIERS.livestockSlots` IS GONE** — per-type slots were replaced by the budget, so
	-- the offer cap can no longer be derived from them. It is now the flat `MAX_ANIMAL_OFFERS`,
	-- which is what §6's "still needed" note asks for: a per-type cap on what is DISPLAYED, so a
	-- tier-1 farm never sees six livestock offers and no crops.
	local animalOfferCap = math.min(Offers.MAX_ANIMAL_OFFERS, remaining)

	while animalCount < animalOfferCap do
		if self:createAnimalOffer(farmId, reputation) == nil then
			break
		end
		animalCount = animalCount + 1
	end

	-- PRODUCT offers, capped separately so they cannot crowd the board (§6). The candidate list
	-- is already filtered to what this farm can actually make, so an empty list simply means no
	-- product offers — which is the correct outcome for a farm with no animals and no crossover.
	local productCap = math.min(Offers.MAX_PRODUCT_OFFERS, remaining)

	while productCount < productCap and #productCandidates > 0 do
		if self:createProductOffer(farmId, productCandidates, tier, reputation, processed) == nil then
			break
		end
		productCount = productCount + 1
	end
end

function Offers:countOffers(farmId)
	local supplyCount, spotCount, animalCount, productCount = 0, 0, 0, 0

	for _, offer in ipairs(self.offers) do
		if offer.farmId == farmId then
			if offer.kind == Offers.KIND_SPOT then
				spotCount = spotCount + 1
			elseif offer.kind == Offers.KIND_ANIMAL then
				animalCount = animalCount + 1
			elseif offer.contractType == Offers.KIND_ANIMAL_PRODUCT then
				-- A PRODUCT offer shares the crop KIND and unit, so only `contractType` tells
				-- them apart. Counting it as a crop would let the crop cap suppress it.
				productCount = productCount + 1
			else
				supplyCount = supplyCount + 1
			end
		end
	end

	return supplyCount, spotCount, animalCount, productCount
end

--- Ceiling on PRODUCT offers shown at once. §6's "still needed" note: without a per-type cap on
--- what is DISPLAYED, a dairy farm's board fills with milk offers and shows no crops.
Offers.MAX_PRODUCT_OFFERS = 1

--- Split the sellable fill types into crops and ANIMAL PRODUCTS.
---
--- The two need different treatment and were previously indistinguishable: `getSellableFillTypes`
--- returns everything a station buys, so MILK, WOOL and EGG sat in the crop pool and a farm with
--- no animals could be offered a dairy contract (§5.1).
---
--- Products are identified from `subType.output`, so **an animal mod adding a producing species
--- registers itself** and nothing here needs a list.
function Offers:splitCandidates(sellable)
	local products = Animals.getAllProductFillTypes()
	local crops, animalProducts = {}, {}

	for _, entry in pairs(sellable) do
		if products[entry.fillTypeIndex] then
			table.insert(animalProducts, entry)
		else
			table.insert(crops, entry)
		end
	end

	return crops, animalProducts
end

--- A PRODUCT contract: a volume of an animal's output per year for a term (§5.2).
---
--- **NO ANIMALS CHANGE HANDS AND NO GENETICS ARE STATED.** User: *"They don't care what type of
--- cow is milked, as long as the milk quota is met."*
---
--- Mechanically this IS the crop contract with a different fill type, which is why it delegates
--- rather than duplicating: milk accumulates in the husbandry's own storage, the player hauls it,
--- and it leaves through a selling station exactly as grain does. `DeliveryWatch`'s existing hook
--- on `SellingStation.sellFillType` already catches it, and `ContractStore:getActiveContract`
--- matches on fill type and `UNIT_LITRES` without checking kind — so settlement works untouched.
---
--- Negotiated like crops (§5.6): milk is a commodity with a market price, so the haggle fits and
--- the machinery already exists. This is the opposite of livestock, which is posted and
--- non-negotiable because haggling would sit on top of the breeding minigame.
function Offers:createProductOffer(farmId, candidates, tier, reputation, processed, client)
	-- **NO REACHABILITY CHECK AND NO WARNING.** §5.5 called for one and the user reversed it on
	-- 2026-07-30: *"it is up to the user to research if they can meet the requirements... If they
	-- sign and fail they get punished."* The contract states its quota; working out whether the
	-- herd can cover it is the game, and the penalty, reputation loss and relationship damage for
	-- missing already exist. Do not reinstate the snapshot.
	--
	-- ⚠ PARTLY SUPERSEDED 2026-07-31 — read `Offers.getCoverageHint` before acting on the
	-- paragraph above. The offer now carries a one-line NUDGE ("your current herd can't cover
	-- these numbers") which does read the herd. What stays banned is what was actually
	-- withdrawn: the CALCULATION, and any figure, ratio or shortfall derived from it. The hint
	-- may never say how big the gap is. *"I absolutely must be vague."*
	return self:createSupplyOffer(farmId, candidates, tier, reputation, processed,
		Offers.KIND_ANIMAL_PRODUCT, client)
end

--- Force a PRODUCT offer, for `fcOffer product`. TESTING SEAM — nil in normal play.
---
--- Products arrive through `refresh` only, and `createAnimalOffer` cannot make one: a product
--- names no animal, states no genetics and is negotiated rather than posted, so it shares nothing
--- with the livestock path but the word "livestock" on its label.
---
--- `fillTypeName` pins which product (e.g. "MILK"); `clientId` and `tier` behave as they do for
--- livestock. Every other term still derives normally, so a forced offer is a real offer rather
--- than a fabricated one — a test built from a fake object proves nothing about the object the
--- game actually makes.
function Offers:forceProductOffer(farmId, reputation, overrides)
	overrides = overrides or {}

	local sellable = self:getSellableFillTypes()
	local _, products = self:splitCandidates(sellable)

	if overrides.fillTypeIndex ~= nil then
		local wanted = {}
		for _, entry in ipairs(products) do
			if entry.fillTypeIndex == overrides.fillTypeIndex then
				table.insert(wanted, entry)
			end
		end
		products = wanted
	end

	if #products == 0 then
		return nil
	end

	-- Products scale off the CROP tier table, not ANIMAL_TIERS: four rungs, not five, and
	-- the quota is derived from `annualValue` at the going rate like any other fill type.
	local tier = Offers.TIERS[overrides.tier or 0] or self:getTier(reputation)

	local client
	if overrides.clientId ~= nil and self.clients ~= nil
		and self.clients.getClientById ~= nil then
		client = self.clients:getClientById(overrides.clientId)
	end

	return self:createProductOffer(farmId, products, tier, reputation,
		self:getProcessedFillTypes(), client)
end

-- ---------------------------------------------------------------------------
-- Money first, quantity derived
-- ---------------------------------------------------------------------------

--- The gross this contract intends to be worth in a year, before negotiation.
---
--- Pure, and static rather than a method, so `test/animals_harness.lua` can assert the
--- ladder without a mission.
function Offers.rollAnnualValue(tier, client)
	local low, high = Offers.VALUE_VARIANCE[1], Offers.VALUE_VARIANCE[2]
	local variance = low + math.random() * (high - low)

	return (tier.annualValue or 0) * ((client ~= nil and client.size) or 1) * variance
end

--- Litres a year that gross implies at the going rate. `nil` when the rate is unusable —
--- the caller must not offer a contract it cannot size.
---
--- `marketRate` is the best station's EFFECTIVE price, so the economic difficulty
--- multiplier, the seasonal factor, the station markup and the random drift are all
--- already inside it (`SellingStation.lua:400`). That is deliberate: change the
--- difficulty and every contract re-sizes itself with no table to maintain.
---
--- The seasonal component means the month an offer is generated moves its size — measured
--- 2026-07-31 at 1.21x (milk) to 1.76x (eggs) peak-to-trough. Left in: the design already
--- applies a deliberate 1.67x spread in `VALUE_VARIANCE`, holding out for a seasonal peak
--- costs an idle budget slot, and striking a price at a good moment is what a forward
--- contract IS. Raised as a fault and withdrawn on the numbers — do not "fix" it.
function Offers.deriveQuota(annualValue, marketRate)
	if type(marketRate) ~= "number" or marketRate <= 0 then
		return nil
	end

	local litres = math.floor(annualValue / marketRate)

	return litres > 0 and litres or nil
end

--- What a quota implies the player must farm, in the natural unit of its kind: hectares
--- for a crop, head for an animal product. Returns `nil, nil` when neither applies —
--- processed goods have no land and no herd, and inventing a figure for them would be
--- worse than printing none.
---
--- INFORMATIONAL ONLY. The contract's binding term is LITRES, because litres is all a
--- delivery can be measured in — `DeliveryWatch` sees `fillDelta` at the till and has no
--- idea whose field it came off. This exists so the board can state the size of the job in
--- a unit a human can judge, the way headcount already does for livestock.
---
--- The hectare figure assumes MAXIMUM YIELD, and anything cut more than once a year (grass)
--- is overstated because it counts a single harvest. Label it as approximate.
function Offers.getImpliedWorkload(fillTypeIndex, quotaPerYear)
	if fillTypeIndex == nil or type(quotaPerYear) ~= "number" or quotaPerYear <= 0 then
		return nil, nil
	end

	local litresPerHectare = Offers.getLitresPerHectare(fillTypeIndex)
	if litresPerHectare ~= nil and litresPerHectare > 0 then
		return quotaPerYear / litresPerHectare, Offers.WORKLOAD_HECTARES
	end

	local litresPerAnimal = Offers.getLitresPerAnimalYear(fillTypeIndex)
	if litresPerAnimal ~= nil and litresPerAnimal > 0 then
		return quotaPerYear / litresPerAnimal, Offers.WORKLOAD_HEAD
	end

	return nil, nil
end

--- Litres a hectare yields, from the map's own foliage data.
---
--- `literPerSqm * 10000 * 2` is GIANTS' OWN per-hectare figure, not an invention — see
--- `FruitTypeDesc.lua:755`, where the result is assigned to a local called `literPerHa`,
--- and Precision Farming's `NitrogenMap.lua:1443`, which applies the same doubling.
---
--- DO NOT use `FruitTypeManager:getFillTypeLiterPerSqm` here. It returns the WINDROW rate
--- whenever the fruit type has one, so it answers WHEAT with straw's 3.68 and claims a
--- hectare of wheat yields 73,600 l.
function Offers.getLitresPerHectare(fillTypeIndex)
	local manager = g_fruitTypeManager
	if manager == nil then
		return nil
	end

	local fruitType = manager.getFruitTypeByFillTypeIndex ~= nil
		and manager:getFruitTypeByFillTypeIndex(fillTypeIndex) or nil

	if type(fruitType) == "table" and (fruitType.literPerSqm or 0) > 0 then
		return fruitType.literPerSqm * 10000 * 2
	end

	-- A BYPRODUCT — straw, grass windrow, hay. It is not the harvest of any fruit type, so
	-- the lookup above misses it entirely; it is the `<windrow>` of one. User ruling
	-- 2026-07-31: these stay on the board, because *"a farm still needs infrastructure to
	-- farm these and it is up to the user to identify the easier work."*
	--
	-- The hectares reported are the PARENT crop's, which is the honest number: you do not
	-- grow straw, you get it free with the wheat you were combining anyway.
	if manager.getFruitTypes ~= nil and manager.getWindrowFillTypeIndexByFruitTypeIndex ~= nil then
		for index, candidate in pairs(manager:getFruitTypes()) do
			if manager:getWindrowFillTypeIndexByFruitTypeIndex(index) == fillTypeIndex
				and (candidate.windrowLiterPerSqm or 0) > 0 then
				return candidate.windrowLiterPerSqm * 10000 * 2
			end
		end
	end

	return nil
end

--- Litres one animal produces in a YEAR of this save's calendar.
---
--- A year is `daysPerPeriod * 12` days, NOT 365 — with the default setting that is TWELVE
--- days. The output curves are per DAY (verified: `PlaceableHusbandryPallets.lua:239` and
--- `PlaceableHusbandryFood.lua:509` both divide `litersPerDay` by 24 to get an hourly
--- rate). Using 365 here overstates every herd by about 30x, which is exactly the error
--- that briefly made a wool contract look like it needed two sheep.
function Offers.getLitresPerAnimalYear(fillTypeIndex)
	if Animals == nil or Animals.getPeakOutputPerDay == nil then
		return nil
	end

	local perDay = Animals.getPeakOutputPerDay(fillTypeIndex)
	if type(perDay) ~= "number" or perDay <= 0 then
		return nil
	end

	local environment = g_currentMission ~= nil and g_currentMission.environment or nil
	local daysPerPeriod = (environment ~= nil and environment.daysPerPeriod) or 1

	return perDay * daysPerPeriod * Environment.PERIODS_IN_YEAR
end

-- ---------------------------------------------------------------------------
-- Renewal
-- ---------------------------------------------------------------------------

--- A contract completed in good standing. The same buyer comes back for the same product.
---
--- The user's narrative, 2026-08-01, and it is the design record:
---
---   *"Your eggs are quality and you have never let us down. We have expanded and now need
---   more eggs. Are you up to the task? You haven't let us down so you get first refusal as
---   you are our preferred egg supplier."*
---
--- **NO NEW PRICING, AND THAT IS DELIBERATE.** A renewal is bigger and better paid without a
--- single new constant, because both were already earned when the contract completed:
---
---   * `ClientRegistry:onContractCompleted` added +0.08 to `client.size`, and size scales the
---     money target — so the renewal asks for MORE and pays MORE.
---   * `relationship` lifts their opening anchor, lifts their hidden ceiling by up to 0.10 and
---     softens stubbornness by up to 30% (`Negotiation.createProfile`). A stranger tops out at
---     0.94 of market; a proven supplier reaches 1.02-1.12.
---
--- Paying a renewal premium ON TOP would charge the client twice for the same achievement —
--- the same double-counting error caught on the crop ladder. User: option (a), *"a is the
--- design. Just now it is guaranteed."*
---
--- **WHAT RENEWAL ACTUALLY ADDS IS CERTAINTY AND TIMING.** Without it, whether that buyer
--- returns is `REUSE_CHANCE` — a 55% coin flip, weighted by relationship, that may land days
--- later on a different product. With it, they come back now, for the thing you just proved
--- you could supply.
---
--- Generated with `force`, so it appears even when the board is already full of offers. It is
--- NOT exempt from the contract budget: signing re-checks, so a farm at its limit sees the
--- invitation and must drop something to take it. User: *"This is the 'farmer must make the
--- decision' factor. Their farm, their choice."*
function Offers:createRenewalOffer(contract)
	if contract == nil or contract.farmId == nil then
		return nil
	end

	-- A spot order is a single delivery, not a relationship. There is nothing to renew.
	if contract.kind == ContractStore.KIND_SPOT then
		return nil
	end

	local client = self.clients ~= nil and self.clients.getClientById ~= nil
		and self.clients:getClientById(contract.clientId) or nil

	-- The buyer IS the feature. Falling back to a stranger would quietly turn a renewal into
	-- an ordinary offer wearing a renewal label.
	if client == nil then
		return nil
	end

	local reputation = self:getReputation(contract.farmId)
	local offer

	if contract.unit == ContractStore.UNIT_HEAD then
		offer = self:createAnimalOffer(contract.farmId, reputation, {
			subTypeName = contract.subTypeName,
			contractType = contract.contractType,
			clientId = contract.clientId,
			force = true,
		})
	else
		offer = self:createRenewalSupplyOffer(contract, client, reputation)
	end

	if offer == nil then
		return nil
	end

	offer.isRenewal = true

	-- STANDS TWICE AS LONG as a cold approach. An invitation from a buyer who knows you is not
	-- a three-day ultimatum, and a farm at its budget limit needs room to decide what to drop.
	offer.expiryDay = g_currentMission.environment.currentMonotonicDay
		+ Offers.RENEWAL_LIFETIME_DAYS

	return offer
end

--- The crop and PRODUCT half of renewal: the same fill type, from the same buyer.
function Offers:createRenewalSupplyOffer(contract, client, reputation)
	local sellable = self:getSellableFillTypes()
	local entry = sellable[contract.fillTypeIndex]

	-- The product may simply not be buyable any more — a station demolished, a mod removed.
	-- Silence is the right answer; a renewal for something nobody purchases is worse than none.
	if entry == nil then
		return nil
	end

	return self:createSupplyOffer(contract.farmId, { entry }, self:getTier(reputation),
		reputation, self:getProcessedFillTypes(), contract.contractType, client)
end

-- ---------------------------------------------------------------------------
-- The coverage hint
-- ---------------------------------------------------------------------------

--- ⚠ THIS REVERSES A DO-NOT-RESTORE. Read this before touching it. 2026-07-31.
---
--- §5.5's reachability check was REMOVED on 2026-07-30 under *"state the terms; never assess
--- the player's ability to meet them"*, and `createProductOffer` still carries the words
--- "Do not reinstate the snapshot". This is not that check coming back.
---
--- What was withdrawn was a CALCULATOR — "you produce 412 l/yr and need 1,600" — which did
--- the player's planning for them. What this is, is a NUDGE that refuses to say how big the
--- gap is. The user's ruling, 2026-07-31:
---
---   *"I absolutely must be vague. We want to offer as little as possible so the user has to
---   research and plan before signing the contract... A little nudge in the right direction
---   is fair game."*
---
--- **THE VAGUENESS IS THE MECHANISM, NOT A LIMITATION.** These strings must never carry a
--- number, a ratio, a shortfall or a word of degree. "Considerably more land than you own"
--- was drafted and rejected for exactly that: *"Considerably tells them too much."* If you
--- are ever tempted to make a hint more helpful, that is the signal to leave it alone.
---
--- Returns an l10n key, or nil for "say nothing" — which is the commonest outcome by design.
---
--- SUPPLY and BREEDING contracts get no hint at all. They already name a head count, and the
--- user's reason is the framing: *"They see 'I need to provide 27 Black Pied boars that
--- are… and I'll get paid £x for doing it'."* A number is its own nudge.
Offers.COVERAGE_BANDS = {
	-- Crops, measured against FIELD hectares owned. Ordered worst-first; the first band the
	-- ratio clears wins, and falling through them all means silence.
	hectares = {
		{ ratio = 1.50, key = "fc_hint_land_beyond" },
		{ ratio = 0.75, key = "fc_hint_land_most" },
		{ ratio = 0.25, key = "fc_hint_land_share" },
	},
	-- Animal products, measured against head that produce the fill type.
	head = {
		{ ratio = 2.00, key = "fc_hint_herd_beyond" },
		{ ratio = 1.00, key = "fc_hint_herd_stretch" },
	},
}

function Offers:getCoverageHint(farmId, fillTypeIndex, quotaPerYear)
	local implied, unit = Offers.getImpliedWorkload(fillTypeIndex, quotaPerYear)

	if implied == nil then
		return nil
	end

	local owned

	if unit == Offers.WORKLOAD_HECTARES then
		owned = Offers.getOwnedFieldHectares(farmId)
	elseif unit == Offers.WORKLOAD_HEAD then
		owned = self.animals ~= nil and self.animals:countProducingAnimals(farmId, fillTypeIndex)
			or nil
	end

	if owned == nil then
		return nil
	end

	-- Owning NOTHING is the loudest case and must not divide by zero.
	if owned <= 0 then
		local bands = Offers.COVERAGE_BANDS[unit]
		return bands ~= nil and bands[1] ~= nil and bands[1].key or nil
	end

	local ratio = implied / owned

	for _, band in ipairs(Offers.COVERAGE_BANDS[unit] or {}) do
		if ratio >= band.ratio then
			return band.key
		end
	end

	return nil
end

--- Hectares of FIELD this farm owns.
---
--- Fields, not farmland parcels. `farmland.areaInHa` counts the whole title — woodland, yard
--- and all — so a farm with 200 ha of forest would be told it had plenty of room for wheat.
--- `Field:getAreaHa` and `Field:getOwner` (`field/Field.lua:135`, `:148`) count only what can
--- actually be cropped.
function Offers.getOwnedFieldHectares(farmId)
	local manager = g_fieldManager

	if manager == nil or manager.getFields == nil then
		return nil
	end

	local total = 0

	for _, field in pairs(manager:getFields()) do
		if field ~= nil and field.getOwner ~= nil and field.getAreaHa ~= nil
			and field:getOwner() == farmId then
			total = total + (field:getAreaHa() or 0)
		end
	end

	return total
end

function Offers:createSupplyOffer(farmId, candidates, tier, reputation, processed, contractType,
	forcedClient)
	if #candidates == 0 then
		return nil
	end

	local pick = candidates[math.random(#candidates)]
	local years = math.random(tier.years[1], tier.years[2])

	local isProcessed = processed ~= nil and processed[pick.fillTypeIndex] == true
	-- `forcedClient` is the fcOffer seam. Controlling the client is what makes a comparison
	-- fair: testing against a different buyer each run measures the generator's variance
	-- rather than the thing under test. The negotiation profile is built from it below, so it
	-- has to be settled before that, not swapped in afterwards.
	local client = forcedClient or self:getClient(farmId, isProcessed)

	-- MONEY FIRST, LITRES DERIVED — the same order `createAnimalOffer` has always used.
	-- Client size scales the commitment: a buyer who has grown with you over several
	-- contracts asks for more than a stranger does (HANDOFF.md §4.1).
	local annualValue = Offers.rollAnnualValue(tier, client)
	local quotaPerYear = Offers.deriveQuota(annualValue, pick.marketRate)

	-- No price, no contract. `getEffectiveFillTypePrice` returns a hard 0 when the
	-- seasonal factor is 0 (`SellingStation.lua:396`), and under the old litres-first
	-- code that merely produced a worthless offer. Dividing by it is a different matter.
	if quotaPerYear == nil then
		return nil
	end

	local marketValue = Negotiation.getMarketValue(pick.marketRate, quotaPerYear, years)

	local offer = {
		id = self.nextOfferId,
		farmId = farmId,
		kind = Offers.KIND_SUPPLY,
		unit = ContractStore.UNIT_LITRES,
		fillTypeIndex = pick.fillTypeIndex,
		marketRate = pick.marketRate,
		suggestedStation = pick.stationName,
		quotaPerYear = quotaPerYear,
		years = years,
		client = client,
		profile = Negotiation.createProfile(marketValue, client.relationship, reputation),
		marketValue = marketValue,

		-- nil for an ordinary crop contract, "PRODUCT" for an animal's output. The board and
		-- ContractStore both read it; a crop contract simply never sets it.
		contractType = contractType,

		-- Refreshed daily in onDayChanged, not only here: a player who buys a field or sells
		-- a flock should not be reading a hint from three days ago.
		coverageHint = self:getCoverageHint(farmId, pick.fillTypeIndex, quotaPerYear),

		expiryDay = g_currentMission.environment.currentMonotonicDay + Offers.OFFER_LIFETIME_DAYS,
	}

	self.nextOfferId = self.nextOfferId + 1
	table.insert(self.offers, offer)

	return offer
end

-- ---------------------------------------------------------------------------
-- Forestry offers — POSTED, not negotiated. FORESTRY.md §1.5 rulings 1 and 2.
-- ---------------------------------------------------------------------------

--- The three forestry tiers, which are a `contractType` AXIS and **NOT a fourth money ladder**.
---
--- FORESTRY.md §1.5 ruling 3 and the amendments block: the mod has FOUR reputation rungs
--- (`Offers.TIERS`, £30/42/60/85k, shared with `ANIMAL_TIERS`) and ONE contract budget. Simple /
--- eco / specialist sit alongside SUPPLY / BREEDING / PRODUCT as a kind of contract, gated by
--- reputation rather than being their own ladder. **Do not give these their own annualValue.**
Offers.FORESTRY_SIMPLE = "FORESTRY_SIMPLE"
Offers.FORESTRY_ECO = "FORESTRY_ECO"
Offers.FORESTRY_SPECIALIST = "FORESTRY_SPECIALIST"

--- ⚠ `rateMultiplier` AND `minReputation` HERE ARE UNTUNED FEEL NUMBERS. They are the only
--- invented constants in the forestry line and FORESTRY.md has always said so: *"They are
--- balance constants... set them once the loop has been played, not before."* Everything else
--- in this file's forestry code is derived or measured. Raise them with the user; do not
--- quietly re-tune them here.
---
--- **WHAT THE MULTIPLIER ACTUALLY DOES, AND IT IS EASY TO GET BACKWARDS.** Under money-first
--- the rung fixes the MONEY, so a premium cannot pay more — it can only ask for less. See
--- `Offers.getPostedRate` and the ordering warning in `createForestryOffer`.
---
--- **TIER 1 IS 1.00 ON PURPOSE, AND IT IS STILL NOT NEUTRAL.** Its premium is DERIVED rather
--- than posted: a tier-1 contract cannot know what species will arrive, so it anchors on WOOD's
--- own declared price, which sits above most real timber. That is worth about 10% and it is
--- FORESTRY.md's original "wood price + a modest %". Adding a multiplier on top would be
--- charging that premium twice. See `Offers.getRealisedRate`.
---
--- `minReputation` is a TRUST gate, not a capability one — a buyer wanting provenance-verified
--- timber asks an established supplier, not a stranger. It deliberately does NOT assess whether
--- the player could grow the trees; that is the "never baby the player" rule, and the honest
--- constraint on eco contracts is the TERM, which is derived. See `getForestryTiersFor`.
Offers.FORESTRY_TIERS = {
	{ contractType = Offers.FORESTRY_SIMPLE, minReputation = 0.00, rateMultiplier = 1.00 },
	{ contractType = Offers.FORESTRY_ECO, minReputation = 0.25, rateMultiplier = 1.15 },
	{ contractType = Offers.FORESTRY_SPECIALIST, minReputation = 0.50, rateMultiplier = 1.30 },
}

--- Whether a forestry tier requires the wood to have been planted and grown by the player.
--- Tier 1 takes any wood from any source, including bought logs — FORESTRY.md, DECIDED
--- 2026-07-28: purchased logs cost more than the contract pays, so the economics police it and
--- the mod does not have to.
function Offers.forestryNeedsProvenance(contractType)
	return contractType == Offers.FORESTRY_ECO
		or contractType == Offers.FORESTRY_SPECIALIST
end

--- Whether a forestry tier names specific species. Only the top one does.
function Offers.forestryNeedsSpecies(contractType)
	return contractType == Offers.FORESTRY_SPECIALIST
end

function Offers.isForestryType(contractType)
	return contractType == Offers.FORESTRY_SIMPLE
		or contractType == Offers.FORESTRY_ECO
		or contractType == Offers.FORESTRY_SPECIALIST
end

--- Forestry tiers this reputation may be offered, worst first. Empty is impossible — tier 1
--- gates at zero — so callers may pick from it without a nil check.
function Offers.getForestryTiersFor(reputation)
	local available = {}

	for _, tier in ipairs(Offers.FORESTRY_TIERS) do
		if (reputation or 0) >= tier.minReputation then
			table.insert(available, tier)
		end
	end

	return available
end

--- The price per litre a posted forestry contract pays.
---
--- POSTED, NOT NEGOTIATED. *"Posted. Wood is wood, end of story."* — user, 2026-08-01. So there
--- is no `Negotiation.createProfile` on a forestry offer and no haggling dialog; the buyer
--- states a rate and the player takes it or leaves it, exactly as livestock does.
---
--- Livestock posts a `rateMultiplier` on the CONTRACT because each animal's own sale value
--- differs and a flat cash rate would pay less the better the animal was (see ANIMAL_TIERS).
--- **Wood has no such problem** — a litre is a litre, and the measurement that settled it is in
--- `WOOD_REALISED_SHARE`: a whole tree and a cut log came within 1.13x of each other in play, so
--- there is no "deliver your worst stock" incentive to design against. The multiplier is
--- therefore applied ONCE, here, and baked into a flat `rate`.
---
--- That is why forestry adds no new persisted field. `contractType` already reaches all five
--- hand-written lists; `rate` is an ordinary crop-contract field.
function Offers.getPostedRate(marketRate, rateMultiplier)
	if type(marketRate) ~= "number" or marketRate <= 0 then
		return nil
	end

	return marketRate * (rateMultiplier or 1)
end

--- A forestry offer. Money first, litres derived, terms posted.
---
--- ⚠ **THE QUOTA IS DERIVED AT THE POSTED RATE, NOT THE MARKET RATE, AND THE OTHER WAY ROUND IS
--- A REAL BUG WAITING TO HAPPEN.** Money-first means revenue must come out at `annualValue`:
---
---     quota = annualValue / postedRate   ->  quota * postedRate = annualValue          ✅
---     quota = annualValue / marketRate   ->  quota * postedRate = annualValue * mult   ❌
---
--- The second silently pays a tier-3 contract 30% more than its rung, which is precisely the
--- fault the shared ladder exists to prevent, and it would not show up anywhere except by adding
--- the year's income up. **So the premium buys LESS WORK for the same money, never more money.**
--- A tier-3 contract at 1.30 asks for 23% fewer litres than a tier-1 contract of the same rung.
---
--- Nothing calls this yet — the board is wired up in phase 3. See FORESTRY.md §1.6.
function Offers:createForestryOffer(farmId, candidate, tier, forestryTier, reputation, forcedClient)
	if candidate == nil or tier == nil or forestryTier == nil then
		return nil
	end

	local years = math.random(tier.years[1], tier.years[2])

	-- Wood is not a production output, so it is never "processed" and the client pool is the
	-- ordinary one. Resolved BEFORE the money, because `rollAnnualValue` reads `client.size` and
	-- resolving it afterwards is exactly how livestock lost its loyalty growth (IMPLEMENTATION.md,
	-- 2026-08-01).
	local client = forcedClient or self:getClient(farmId, false)

	local rate = Offers.getPostedRate(candidate.marketRate, forestryTier.rateMultiplier)
	if rate == nil then
		return nil
	end

	local annualValue = Offers.rollAnnualValue(tier, client)
	local quotaPerYear = Offers.deriveQuota(annualValue, rate)

	if quotaPerYear == nil then
		return nil
	end

	local offer = {
		id = self.nextOfferId,
		farmId = farmId,
		kind = Offers.KIND_SUPPLY,
		unit = ContractStore.UNIT_LITRES,
		fillTypeIndex = candidate.fillTypeIndex,
		marketRate = candidate.marketRate,
		suggestedStation = candidate.stationName,
		quotaPerYear = quotaPerYear,
		years = years,
		client = client,

		-- POSTED. The rate is settled here and there is no negotiation profile, which is the
		-- seam the board reads — see `isPosted`.
		rate = rate,
		rateMultiplier = forestryTier.rateMultiplier,
		contractType = forestryTier.contractType,

		-- WHAT THIS CONTRACT IS MEANT TO BE WORTH IN A YEAR, kept so the invariant
		-- `quotaPerYear * rate == annualValue` is CHECKABLE rather than merely true.
		--
		-- Added because the guard written for that invariant was worthless without it: it
		-- compared revenue against the rung's full 0.75-1.25 variance band, and a 30% pricing
		-- error fits comfortably inside a 50% band. Deriving the quota at the market rate
		-- instead of the posted rate passed every check. Found by breaking it on purpose,
		-- 2026-08-01 — the second worthless guard caught that day.
		annualValue = annualValue,

		-- **THE BOARD MUST BRANCH ON THIS, NOT ON A LIST OF TYPES.** ContractBoardFrame currently
		-- decides how to sign by testing entry kinds and falling through to NegotiationDialog,
		-- so a posted offer carrying KIND_SUPPLY would open a haggle for a price that was never
		-- negotiable. A flag says what the offer IS; a type list has to be kept in step with
		-- every type ever added, which is the shape of the five-list bug.
		isPosted = true,

		-- No coverage hint on any forestry tier. FORESTRY.md §1.5 ruling 5: there is no honest
		-- denominator, because any land grows trees. Tier 3's plant-by-date line is the nudge,
		-- and it is a better one. `getImpliedWorkload` already returns nil for WOOD — it is
		-- neither a fruit type nor an animal output — so this is belt and braces.
		coverageHint = nil,

		expiryDay = g_currentMission.environment.currentMonotonicDay + Offers.OFFER_LIFETIME_DAYS,
	}

	self.nextOfferId = self.nextOfferId + 1
	table.insert(self.offers, offer)

	return offer
end

--- Sign a posted forestry offer. No negotiation, so no agreed value and no mix.
---
--- Mechanically a crop contract — KIND_SUPPLY, UNIT_LITRES, settled by `Settlement:onDelivery`
--- against the till like any other litre delivery. Only `contractType` and the posted rate make
--- it forestry, and both already persist.
function Offers:acceptForestryOffer(offer)
	-- Same guard as every other accept path, and for the same reason: an offer outlives the
	-- moment it was generated in. See acceptSupplyOffer.
	if self:getRemainingBudget(offer.farmId, self:getReputation(offer.farmId)) <= 0 then
		return nil, Offers.REFUSED_BUDGET
	end

	local contract = self.contractStore:signContract({
		farmId = offer.farmId,
		clientId = offer.client.id,
		kind = ContractStore.KIND_SUPPLY,
		unit = ContractStore.UNIT_LITRES,
		fillTypeIndex = offer.fillTypeIndex,
		rate = offer.rate,

		-- Posted terms carry no completion bonus. Livestock's exists because its bottom rung
		-- sits BELOW market at 0.90 and would otherwise be strictly bad to sign (see
		-- ANIMAL_TIERS.bonusShare). No forestry rung is below market — the lowest is 1.00
		-- against an anchor already above most timber — so there is nothing to compensate for.
		completionBonus = 0,

		quotaPerYear = offer.quotaPerYear,
		years = offer.years,
		suggestedStation = offer.suggestedStation,
		contractType = offer.contractType,
	})

	self:removeOffer(offer.id)

	return contract
end

-- ---------------------------------------------------------------------------
-- Livestock offers
-- ---------------------------------------------------------------------------

--- The animal tier for a reputation, mirroring getTier but on the inverted ladder.
--- The rung this reputation has reached, with the tier-4 variant rolled.
---
--- 4a and 4b share one reputation threshold (§2.1) — there is no fifth rank. The variant is
--- rolled per offer at 80:20 in favour of 4a, so 4b stays the rare contract without needing any
--- other special handling, and the onus stays with the player. User: *"It is a choice for the
--- user. If they think they can reach Extremely Good then they can choose to. They don't have
--- to take the contract."*
---
--- `forcedIndex` is the `fcOffer` testing seam and skips the roll entirely.
function Offers:getAnimalTier(reputation, forcedIndex)
	if forcedIndex ~= nil and Offers.ANIMAL_TIERS[forcedIndex] ~= nil then
		return Offers.ANIMAL_TIERS[forcedIndex], forcedIndex
	end

	local tier, index = Offers.ANIMAL_TIERS[1], 1

	-- Stop at 4a: 4b is never reached by reputation, only by the roll below.
	for i = 1, Offers.ANIMAL_TIER4_INDEX do
		local candidate = Offers.ANIMAL_TIERS[i]
		if reputation >= candidate.minReputation then
			tier, index = candidate, i
		end
	end

	if index == Offers.ANIMAL_TIER4_INDEX and math.random() < Offers.ANIMAL_TIER4B_CHANCE then
		index = Offers.ANIMAL_TIER4_INDEX + 1
		tier = Offers.ANIMAL_TIERS[index]
	end

	return tier, index
end

--- How many contracts of ALL types this farm may hold at once. §6 — one budget, freely
--- allocated, replacing both `TIERS.slots` and the old `ANIMAL_TIERS.livestockSlots`.
---
--- A player taking 3 livestock and 2 crop is specialising; one taking 5 crop is a different
--- farm. **The choice is the point**, and there is deliberately no per-type restriction: user
--- ruling, *"Don't restrict the contract types, just the number. If the farmer over reaches
--- that is on them."* Planning is the skill the budget tests — do not add guard rails that take
--- the decision back off the player.
Offers.CONTRACT_BUDGET = { 2, 3, 4, 5 }

--- Why a signing was refused. Returned as a second/third value so the UI can SAY SO — a button
--- that silently does nothing is the worst outcome, and the budget is exactly the mechanic §4.9
--- says must be legible rather than discovered.
Offers.REFUSED_BUDGET = "budget"

--- How many more contracts of ANY type this farm may still sign.
---
--- **THE CROP SIDE HAD NO SIGNING LIMIT AT ALL BEFORE THIS.** `refresh` topped the board back up
--- to `TIERS.slots`, and accepting an offer simply removed it and let a replacement generate —
--- so `slots` bounded what was DISPLAYED and nothing bounded what was SIGNED. A patient player
--- could hold an unbounded number of crop contracts. Livestock was capped because
--- `createAnimalOffer` checked its own slot count; crops never did.
---
--- That is the same class of oversight §6 was written about: every individual number looked
--- defensible because nobody had added them up.
function Offers:getRemainingBudget(farmId, reputation)
	if self.contractStore == nil or self.contractStore.getActiveContractCount == nil then
		return math.huge
	end

	local used = self.contractStore:getActiveContractCount(farmId)

	return math.max(0, self:getContractBudget(reputation) - used)
end

function Offers:getContractBudget(reputation)
	local budget = Offers.CONTRACT_BUDGET[1]

	for i = 1, Offers.ANIMAL_TIER4_INDEX do
		if reputation >= Offers.ANIMAL_TIERS[i].minReputation then
			budget = Offers.CONTRACT_BUDGET[i] or budget
		end
	end

	return budget
end

--- SUPPLY or BREEDING for this species (§1.1).
---
--- A meat animal is sold as an animal, so it gets SUPPLY. A job animal is kept to DO something,
--- so it gets BREEDING — its buyer wants it to milk or shear, not to slaughter. The split is
--- derived in `Animals.isJobAnimal`, so a map or animal mod adding a breed classifies itself.
---
--- PRODUCT is not decided here: it names no animal at all and is gated separately (§5.3).
function Offers.getAnimalContractKind(subType)
	if Animals.isJobAnimal(subType) then
		return Offers.KIND_ANIMAL_BREEDING
	end

	return Offers.KIND_ANIMAL_SUPPLY
end

--- Which traits this contract puts a floor on.
---
--- Picked from the traits the farm's own animals actually have, so a chicken farm is never
--- asked for a milk yield it cannot express. `productivity` only exists on some types
--- (§5.2), which is exactly the trap this avoids.
--- THE ENTRY FLOOR IS 0.90, NOT LOWER, and the reason is measured rather than felt. At 0.75
--- the requirement rendered in RL's own vocabulary as "minimum Low in Meat Quality", which
--- reads as a joke against itself. Raising it to 0.90 costs the player nothing but shopping:
--- 57% of dealer animals clear 0.90 on a single trait, and NO breeding is required to reach
--- it — measured against RL's own generator, `createNewSaleAnimal` clamps quality to
--- [0.25, 1.75] centred on the source farm's quality, and farms roll uniformly to 1.75
--- (RealisticLivestock_AnimalSystem.lua:849, :1525).
---
--- So the entry rung stays about VOLUME rather than genetics, exactly as §4.6 requires, and
--- the requirement now reads as a real if modest standard.
---
--- `qualityFloor` is applied SEPARATELY from the other trait floors and is never optional,
--- because it is the trait the contract is priced on (Animals.TRAIT_QUALITY). Leaving it to
--- the random trait draw would mean a contract whose agreed price was anchored to a minimum
--- it had not actually stated — the client would be paying for a spec it never asked for.
---
--- Every other floor is drawn at random from the traits the species carries, and those cost
--- the breeder effort while changing the contract's cash value by nothing, since RL prices
--- on quality alone.
function Offers:pickFloorTraits(subType, count, floor, qualityFloor)
	if qualityFloor ~= nil then
		local floors = self:pickFloorTraits(subType, count, floor) or {}

		-- A stated floor must never be softened by the random draw landing lower.
		local existing = floors[Animals.TRAIT_QUALITY]
		if existing == nil or existing < qualityFloor then
			floors[Animals.TRAIT_QUALITY] = qualityFloor
		end

		return floors
	end

	if floor == nil or count == 0 then
		return nil
	end

	-- Traits come from the SUBTYPE, not from a sampled animal, so a contract can be
	-- generated for a species the farm does not keep. `productivity` exists only on cows,
	-- sheep and chickens, and a floor on a trait the animal has no field for would be
	-- unsatisfiable — Animals.getTraitsForSubType is what prevents that.
	local available = Animals.getTraitsForSubType(subType)

	if #available == 0 then
		return nil
	end

	-- nil count means every trait the animal carries — the top rung.
	if count == nil or count >= #available then
		local floors = {}
		for _, trait in ipairs(available) do
			floors[trait] = floor
		end
		return floors
	end

	-- Otherwise take `count` at random, without replacement.
	local floors = {}
	for _ = 1, count do
		local index = math.random(#available)
		floors[available[index]] = floor
		table.remove(available, index)
	end

	return floors
end

--- REMOVED 2026-07-29: `ANIMAL_BREED_REPEAT_WEIGHT` (2.0) and `ANIMAL_BREED_OWNED_WEIGHT`
--- (0.5). The species draw is flat and has no weights of any kind — see pickWeightedSubType.
--- The comment they carried claimed they were "not so high that the board locks onto one
--- breed forever", and in play they were: one completed chicken contract took 47% of the
--- draw. Left recorded here so the idea is not reinvented.


--- Choose a breed for an invitation offer.
---
--- This is what makes the infrastructure decision rational (§4.6). Building a husbandry for
--- one bottom-tier contract is a gamble if the market never asks again; weighting by record
--- turns "should I get into Black Welsh Mountain sheep?" into a real investment with a
--- payoff, because completing that contract markedly raises the odds the next rung asks
--- for the same animal.
--- The distinct species this farm actually keeps.
---
--- Feeds the crossover test alongside the ledger: keeping sheep proves the grass chain even
--- if we never watched a bale go in, because a farm with sheep is mowing by definition.
function Offers:getKeptSubTypes(farmId)
	local kept, seen = {}, {}

	if self.animals == nil then
		return kept
	end

	for _, entry in ipairs(self.animals:getAnimals(farmId)) do
		local name = entry.animal.subType

		if name ~= nil and not seen[name] then
			seen[name] = true

			local subType = Animals.getSubTypeByName(name)
			if subType ~= nil then
				table.insert(kept, subType)
			end
		end
	end

	return kept
end

--- Draw a breed for an INVITATION offer — a species the farm does not yet keep.
---
--- **FLAT. NO WEIGHTS ANYWHERE.** User ruling, restated 2026-07-29 after the previous
--- session applied it to feed affinity but left the track-record weights in place:
---
---   *"I explicitly stated to the last session that there should be zero weights. Everything
---   is an even split on the recommendation. Recommendations only include new species though,
---   NOT the species already being reared in game."*
---
--- Two rules, and the second is the one that was missing: species the farm already rears are
--- EXCLUDED. An invitation to take up a line you are already running is not an invitation.
--- Contracts for a species you do keep come from the herd-derived path in createAnimalOffer
--- (`tier.breed`), which is a continuation of an existing line rather than a recommendation.
function Offers:pickWeightedSubType(farmId, candidates)
	-- Species the farm already rears, keyed by typeIndex so it excludes the SPECIES rather
	-- than the individual breed. A farm keeping Bentheim pigs should not be invited to take
	-- up Landrace pigs — it is already in pigs.
	local kept = self:getKeptSubTypes(farmId)
	local keptSpecies = {}

	for _, subType in ipairs(kept) do
		local key = subType.typeIndex or subType.name
		keptSpecies[key] = true
	end

	-- CROSSOVER IS A FILTER, NOT A LABEL. Changed 2026-07-29 after the user asked the obvious
	-- question: *"Why would cows or sheep be offered if I have chickens fed on wheat?"*
	--
	-- **This is a fault introduced by removing the affinity weights earlier the same day.** While
	-- `ANIMAL_FEED_AFFINITY_WEIGHT` existed, a fully-overlapping species was ~3.5x likelier and
	-- §0.8's promise that a farm *"should still occasionally be asked for something awkward, just
	-- not by default"* held. Deleting the weights deleted the mechanism and left the comment
	-- describing behaviour that no longer happened: every species became equally likely, so half
	-- the offers pointed at chains the farm had no part of.
	--
	-- The fix keeps the user's "zero weights" ruling LITERALLY — the pool is smaller, the draw
	-- inside it is still perfectly flat. A filter is not a weight.
	--
	-- Evaluated once per SPECIES, not per breed: crossover depends on the species' food groups,
	-- which every breed of it shares.
	local crossoverBySpecies = {}

	local function hasCrossover(subType, key)
		if crossoverBySpecies[key] == nil then
			crossoverBySpecies[key] = Animals.hasFeedCrossover(subType, kept, farmId) == true
		end

		return crossoverBySpecies[key]
	end

	-- PICK THE SPECIES FIRST, THEN THE BREED WITHIN IT. Weighting every breed equally lets
	-- whichever animal happens to ship the most breeds dominate the board, which is an
	-- artefact of RL's content rather than a design decision: on RL the 24 breedable
	-- subtypes are 8 horse, 7 cow, 5 sheep, 3 pig and 1 chicken, so a flat draw makes a
	-- third of all offers horses and 4% of them poultry.
	--
	-- Grouping by `subType.typeIndex` (AnimalSystem.lua:260) gives each species an equal
	-- share and splits the breed roll inside it, so admitting a species to the candidate set
	-- adds it to the draw WITHOUT advantaging it. That was the user's condition for letting
	-- horses back in on 2026-07-28, and it fixes the pre-existing cattle skew at the same
	-- time.
	local groups, order = {}, {}

	local function collect(skipKept, requireCrossover)
		groups, order = {}, {}

		for _, subType in ipairs(candidates) do
			-- Fall back to the breed's own name when typeIndex is missing, which degrades to
			-- the old per-breed behaviour for that entry rather than collapsing every unknown
			-- species into one bucket.
			local key = subType.typeIndex or subType.name
			local eligible = true

			if skipKept and keptSpecies[key] then
				eligible = false
			end

			if eligible and requireCrossover and not hasCrossover(subType, key) then
				eligible = false
			end

			if eligible then
				if groups[key] == nil then
					groups[key] = {}
					table.insert(order, key)
				end

				table.insert(groups[key], subType)
			end
		end
	end

	-- 1. The intended case: a species the farm does NOT keep but has a foot in the door with.
	collect(true, true)

	-- 2. RECRUITMENT. Nothing the farm is part-equipped for, so there is no infrastructure to
	--    build on and the whole roster is fair game. §0.8 already described this case: *"a farm
	--    with no animals sees the whole roster evenly — that rung is recruitment rather than
	--    expansion."* This is also the ONLY path that should ever produce a "new opportunity"
	--    label, which is exactly when starting from nothing is the honest description.
	if #order == 0 then
		collect(true, false)
	end

	-- 3. A farm that already keeps every admissible species has nothing left to be invited into.
	--    Offering it a line it already runs beats offering it nothing.
	if #order == 0 then
		collect(false, false)
	end

	if #order == 0 then
		return nil
	end

	-- **THE TRACK-RECORD AND OWNERSHIP WEIGHTS WERE REMOVED 2026-07-29.** They were
	-- `1 + 2.0 * completions + 0.5 * owned`, which made a single completed chicken contract
	-- worth 47% of every future offer and compounded without limit. That works directly
	-- against the recommendation mechanic: a farm is asked "why not look at horses?" and then
	-- never sees a horse offer.
	--
	-- Experience in a line is still rewarded — through REPUTATION, which raises the rung every
	-- offer is drawn at, and through the herd-derived path at the top rungs. Neither needs the
	-- species draw biased as well.
	--
	-- Species first, then the breed within it. A flat draw over BREEDS would let whichever
	-- animal ships the most breeds dominate, which is an artefact of RL's content rather than
	-- a design decision: RL's 24 breedable subtypes are 8 horse, 7 cow, 5 sheep, 3 pig and
	-- 1 chicken, so a flat breed draw makes a third of all offers horses and 4% poultry.
	local chosen = order[math.random(#order)]
	local breeds = groups[chosen]

	return breeds[math.random(#breeds)]
end

--- Can this species be asked for at all, and can it be asked for over THIS term?
---
--- Fixes a contract seen in play on 2026-07-28: "25 horses aged 47 to 94 months, over 2
--- years". RL horses prime at 47 months, so no animal bred after signing could ever have
--- qualified — the entry rung generated an arithmetically impossible contract, and it did
--- it to exactly the player it exists to recruit.
---
--- Two derived gates, neither of which names a species. Hardcoding "no horses" would be
--- wrong twice over: RL already reprices the base curves (its horses peak at 5,500, not
--- 15,000), and any map or animal mod can add species we have never seen.
---
---   1. BREEDABLE AT ALL — time to breed one from scratch (breeding age + gestation +
---      prime age) must fit inside the longest term any tier offers. A species failing this
---      can never be produced by the player within a contract, so the mod never asks.
---      On RL this drops horses (22 + 11 + 47 = 80 months) and nothing else.
---
---   2. REACHABLE ON THIS TERM — prime age must fit inside this contract's own term, so
---      young stock bought at the dealer can at least be grown into the age window before
---      the contract ends. This is what keeps a 1-year contract to fast species without
---      restricting the long ones.
---
--- Falls back to permitting the species when the life-cycle data is missing, rather than
--- silently emptying the candidate set on a map whose animals we cannot read.
function Offers.isSubTypeAdmissible(subType, termMonths, kind)
	if type(subType) ~= "table" then
		return false
	end

	-- **THE GATE IS THE DELIVERY AGE, NOT PRIME.** This used to read
	-- `getPrimeAgeForSubType` for every contract, which is right for supply and badly wrong
	-- for breeding: a Holstein heifer is delivered at 12 months, and gating her on the 24-month
	-- prime would refuse a perfectly reachable 1-year breeding contract. See §2.4.
	local deliveryAge = Offers.getAnimalDeliveryAge(subType, kind)
	if deliveryAge == nil then
		return true
	end

	if termMonths ~= nil and deliveryAge > termMonths then
		return false
	end

	local breedingAge = subType.reproductionMinAgeMonth
	local gestation = subType.reproductionDurationMonth

	if type(breedingAge) == "number" and type(gestation) == "number" then
		if breedingAge + gestation + deliveryAge > Offers.ANIMAL_MAX_TERM_MONTHS then
			return false
		end
	end

	return true
end

-- ---------------------------------------------------------------------------
-- The animal spec — what the contract asks for
-- ---------------------------------------------------------------------------

--- Chance a MALE supply contract asks for castrated stock.
---
--- UNTUNED. RL pays +15% for a castrated animal and grows it 15% faster, so both forms are
--- genuinely different goods and the contract prices whichever it names (§1.5). Castration is a
--- real player action — a button in RL's own menu (`AnimalCastrateEvent`) — so the requirement
--- is satisfiable. It is deliberately a minority of male contracts: it is a flavour of offer,
--- not the default one.
Offers.ANIMAL_CASTRATED_CHANCE = 0.25

--- Horses are offered at tier 3 and above only (§1.7). There is deliberately **no headcount
--- cap** — see the long note in `createAnimalOffer` for why the old one was removed, and do not
--- put it back.
---
--- The gate survives on its own merits: horses mature slowly (peak 36 months for a stallion, 60
--- for a mare), a single animal is worth several thousand, and a top-tier one is the most
--- valuable animal in the game. Those are reasons to make it a late-game line regardless of how
--- long grooming takes.
---
--- No limit on how OFTEN horse contracts appear — user ruling: *"They shouldn't be limited in how
--- often a horse contract appears, just limited on when and headcount."* The "how often" half of
--- that still stands; the headcount half is now the money ladder's job, as for every species.
Offers.ANIMAL_HORSE_MIN_TIER = 3

--- Everything the contract asks OF THE ANIMAL: age window, genetics, feed and condition.
---
--- Split out of `createAnimalOffer` because that function had grown to 360 lines doing one job.
--- This half answers "what animal?"; the caller answers "how many, for how long, at what price?"
---
--- Returns a table of spec fields, or nil if the species cannot be specified at all.
function Offers:buildAnimalSpec(subType, tier, kind, years)
	local deliveryAge = Offers.getAnimalDeliveryAge(subType, kind)

	if deliveryAge == nil then
		return nil
	end

	-- The window narrows up the ladder, and never below two months — at 1-day months a
	-- two-month slot is already tight, and rounding could otherwise produce a one-month window
	-- missable by a single day.
	local span = math.max(Offers.ANIMAL_MIN_AGE_SPAN,
		math.floor(deliveryAge * (tier.ageSpan or 1.0) + 0.5))

	local ageMin, ageMax

	if kind == Offers.KIND_ANIMAL_BREEDING then
		-- **UP FROM breeding age**: the buyer is paying for the productive years ahead of her,
		-- so every extra month is life they do not get. Younger is strictly better.
		ageMin = deliveryAge
		ageMax = deliveryAge + span
	else
		-- **DOWN TO peak**: value FALLS afterwards — a cow drops from ~2,400 to ~1,400 between
		-- 36 and 60 months — so late delivery must be the failure rather than the default.
		-- Anchoring here is what fixed the chicken and stallion cases in §2.4 without either
		-- needing a special case.
		ageMax = deliveryAge

		-- **THE WINDOW MUST NOT OPEN BELOW BREEDING AGE, AND WITHOUT THIS IT DID.** At tier 1
		-- `ageSpan` is 1.00, so `peak - span` is ZERO: an Angus supply contract read "0 to 36
		-- months" and a NEWBORN CALF qualified.
		--
		-- That is not merely loose, it is an income stream. Settlement pays
		-- `(rate - realised) x head` (§0.5), so delivering a £200 calf against a £2,165 agreed
		-- rate collects £1,965 of pure hedge per animal — the exact failure §2.2 exists to
		-- prevent, reached without needing any genetics at all. It would have been the single
		-- most profitable thing to do in the mod.
		--
		-- Breeding age is the honest floor and it is already derived: it is the age RL itself
		-- treats as grown, and an animal below it is not a finished product by anyone's
		-- reckoning. Caught by the offline harness printing the windows, before it ever ran.
		--
		-- **THE SPECIES' breeding age, NOT THE SUBTYPE'S.** A male's own figure is when he may
		-- SIRE, not when he is grown — a stallion's is 36, which is also his peak, so using it
		-- collapsed the window to the two-month minimum and turned a tier-3 horse contract into
		-- a two-month flip. See Animals.getSpeciesBreedingAge.
		local floorAge = Animals.getSpeciesBreedingAge(subType) or 0
		ageMin = math.max(deliveryAge - span, floorAge)

		-- The floor can collide with peak — a stallion breeds at 36 and peaks at 36 — which
		-- would leave a zero-width window. The minimum span wins.
		if ageMax - ageMin < Offers.ANIMAL_MIN_AGE_SPAN then
			ageMin = math.max(0, ageMax - Offers.ANIMAL_MIN_AGE_SPAN)
		end
	end

	local spec = {
		ageMin = ageMin,
		ageMax = ageMax,
		contractType = kind,
		gender = subType.gender,
	}

	if kind == Offers.KIND_ANIMAL_BREEDING then
		-- BOTH productivity and fertility, each on its own, never their average (§2.1). And no
		-- quality floor at all: the buyer does not care about meat on an animal they intend to
		-- milk or shear.
		spec.prodFertFloor = tier.prodFertBand
	else
		spec.overallBand = tier.overallBand
		spec.qualityFloor = tier.qualityBand

		-- Castration is a SUPPLY-only, male-only requirement. On a female it is meaningless;
		-- on a breeding animal it is a contradiction, since RL zeroes fertility with it.
		if subType.gender == "male" and math.random() < Offers.ANIMAL_CASTRATED_CHANCE then
			spec.requiresCastrated = true
		end
	end

	-- THE CONTRACT NAMES ITS FEED, and is priced at what that feed can actually produce. User
	-- ruling: *"Explicitly state food type. The contract value and per head value of the
	-- contract is then calculated at that. If the user opts for better feed that is on them."*
	--
	-- **POOR FEED IS A LOW-RUNG OFFER ONLY** — *"Tier 3+ only offers high."* A renowned breeder
	-- is not asked for grass-fed cattle. Species with one feed group have no poor variation at
	-- all, which is correct: they are cheaper animals anyway.
	local feedOptions = Animals.getFeedOptions(subType)
	local feedChoices = {}

	for _, option in ipairs(feedOptions) do
		if tier.requiresFullFeed ~= true or option.growth >= 1 then
			table.insert(feedChoices, option)
		end
	end

	-- Nothing clears the tier's bar: fall back to the species' best rather than dropping the
	-- offer. A species whose every group is poor is still worth contracting.
	if #feedChoices == 0 then
		for _, option in ipairs(feedOptions) do
			if feedChoices[1] == nil or option.growth > feedChoices[1].growth then
				feedChoices[1] = option
			end
		end
	end

	-- A species whose food data could not be read states no feed and is priced at full
	-- condition. Missing data must never make a contract cheaper or harder — the same rule
	-- `meetsSpec` follows when it cannot measure an animal.
	local feed = #feedChoices > 0 and feedChoices[math.random(#feedChoices)] or nil

	spec.feedGrowth = feed ~= nil and feed.growth or 1
	spec.feedName = Animals.describeFeedOption(feed)

	-- The tier states the standard of husbandry; the feed caps what that standard can
	-- physically achieve.
	spec.minCondition = (tier.minCondition or 0) * spec.feedGrowth
	spec.minHealth = tier.minHealth

	return spec
end

--- A livestock contract, if this farm is in the livestock business at all.
---
--- Deliberately returns nil rather than generating when:
---   * Animals is not wired in — we could neither price nor judge it.
---   * The farm owns no animals — a breeding contract for someone with no herd is noise.
---   * A head contract is already live — one genetic specification at a time (§4.6 is a
---     breeder working a line, not a checklist).
--- `overrides` is a TESTING seam and is nil in normal play. It carries any of
--- `subTypeName`, `clientId` and `tier`, letting `fcOffer` pin down the parts of an offer
--- that are otherwise random.
---
--- Controlling those three is what makes a comparison fair: testing the miss branch against
--- a different client and species each run measures the generator's variance, not the branch
--- under test. Every other term still derives normally, so a forced offer is a real offer
--- rather than a fabricated one — which matters, because a test built from a fake object
--- proves nothing about the object the game actually makes.
function Offers:createAnimalOffer(farmId, reputation, overrides)
	if self.animals == nil then
		return nil
	end

	overrides = overrides or {}

	local tier, tierIndex = self:getAnimalTier(reputation, overrides.tier)

	-- ONE BUDGET ACROSS EVERY CONTRACT TYPE (§6), replacing the old per-type slot tables.
	--
	-- Those were retired because nobody had ever added them up: with four contract types on
	-- per-type slots a tier-4 farm could hold 13 contracts worth ~£950,000 a year. Every
	-- individual number was defensible and the sum was the mega-farm the mod exists not to
	-- create. Spot orders stay outside it — see getActiveContractCount.
	--
	-- **This deliberately retires §0.8's argument** that a beginner could not realistically run
	-- several animals. Under a budget of 2 they CAN take two livestock contracts and overreach,
	-- and that is allowed: *"If the farmer over reaches that is on them."*
	local held = {}
	local usedBudget = 0

	if self.contractStore ~= nil then
		if self.contractStore.getActiveContractCount ~= nil then
			usedBudget = self.contractStore:getActiveContractCount(farmId)
		end

		if self.contractStore.getActiveHeadContracts ~= nil then
			for _, contract in ipairs(self.contractStore:getActiveHeadContracts(farmId)) do
				if contract.subTypeName ~= nil then
					held[contract.subTypeName] = contract.contractType or Offers.KIND_ANIMAL_SUPPLY
				end
			end
		end
	end

	if not overrides.force and usedBudget >= self:getContractBudget(reputation) then
		return nil
	end

	-- TERM AND SPECIES ARE CHOSEN TOGETHER, because each constrains the other. Picking the
	-- species first and the term afterwards is what allowed a 2-year contract for an animal that
	-- takes 47 months to mature (§0.4's bug 2).
	--
	-- Candidates are admitted against the tier's LONGEST term and the term is then stretched to
	-- fit whichever species is drawn. Filtering against the ROLLED term instead would let a short
	-- roll silently delete the slower half of the roster — on RL a 1-year roll left chickens as
	-- the only legal species, so the entry rung was poultry every single time.
	local minYears = tier.years and tier.years[1] or 1
	local maxYears = tier.years and tier.years[2] or 3
	local years = math.random(minYears, maxYears)
	local maxTermMonths = maxYears * 12

	-- NO HERD REQUIRED. A livestock offer must be able to reach a farmer who owns no animals —
	-- that is the invitation to get into breeding at all. An empty herd makes the contract
	-- harder, not unavailable.
	local herd = self.animals:getAnimals(farmId)

	-- BOTH POOLS AT ONCE, and the kind follows from the species rather than being chosen first.
	-- A meat animal can only ever be a SUPPLY contract and a job animal only ever a BREEDING one
	-- (§1.1), so the two candidate sets are disjoint and their union is simply "every animal that
	-- can be contracted".
	local candidates = {}

	local function admit(candidate, kind)
		if type(candidate) ~= "table" or candidate.name == nil then
			return
		end

		-- ONE LINE PER SPECIES, and it is now CONDITIONAL rather than a flat check (§6).
		-- A farm may hold BREEDING and PRODUCT on one species — complementary, and a dairy
		-- running both is the sustainable business the mod is for. It may NOT hold SUPPLY and
		-- BREEDING together: they compete for one herd with different age targets, peak against
		-- breeding age, and the two specifications are incoherent side by side.
		if held[candidate.name] ~= nil then
			return
		end

		-- HORSES ARE TIER 3 AND ABOVE ONLY (§1.7). Not because of money — because of the
		-- player's real time. Ten real-world minutes per horse per in-game day for riding and
		-- grooming is an effort axis `getHusbandryEffort` cannot see, since that measures
		-- INFRASTRUCTURE and this is per animal, per day, forever.
		if Animals.hasPerAnimalLabour(candidate) and tierIndex < Offers.ANIMAL_HORSE_MIN_TIER then
			return
		end

		if Offers.isSubTypeAdmissible(candidate, maxTermMonths, kind) then
			table.insert(candidates, candidate)
		end
	end

	-- `overrides.contractType` is the `fcOffer` testing seam. Without it both pools are drawn
	-- from and the kind follows the species, which is the normal path. With it the pool is
	-- restricted, so a tester can ask for a BREEDING contract on a farm whose crossover would
	-- otherwise never produce one — the case that left BREEDING unexercised in play.
	local forcedKind = overrides.contractType

	if forcedKind == nil or forcedKind == Offers.KIND_ANIMAL_SUPPLY then
		for _, candidate in ipairs(self.animals:getContractableSubTypes(Offers.KIND_ANIMAL_SUPPLY)) do
			admit(candidate, Offers.KIND_ANIMAL_SUPPLY)
		end
	end

	if forcedKind == nil or forcedKind == Offers.KIND_ANIMAL_BREEDING then
		for _, candidate in ipairs(self.animals:getContractableSubTypes(Offers.KIND_ANIMAL_BREEDING)) do
			admit(candidate, Offers.KIND_ANIMAL_BREEDING)
		end
	end

	-- A forced species skips every filter deliberately: the point of pinning it is to test that
	-- species, and refusing would leave the tester wondering whether the command or the mod was
	-- at fault. The term still stretches to fit it below.
	if overrides.subTypeName ~= nil then
		local forced = Animals.getSubTypeByName(overrides.subTypeName)
		if forced ~= nil then
			candidates = { forced }
		end
	end

	-- Every species is too slow for a term this short, or the farm already runs them all.
	-- No offer is the correct outcome and the caller already treats nil as "stop generating".
	if #candidates == 0 then
		return nil
	end

	local subType = self:pickWeightedSubType(farmId, candidates)

	if subType == nil then
		return nil
	end

	-- A forced kind wins over the derived one. Pinning both a species and a type is deliberately
	-- allowed even where they disagree — the point of forcing is to exercise a path, and refusing
	-- would leave the tester wondering whether the command or the mod was at fault. Console warns
	-- on the mismatch rather than blocking it.
	local kind = forcedKind or Offers.getAnimalContractKind(subType)
	local deliveryAge = Offers.getAnimalDeliveryAge(subType, kind)

	-- STRETCH THE TERM TO THE SPECIES. A slow animal gets the years it needs; a fast one keeps
	-- the short contract it was rolled. This is what lets cattle sit in the basic tier alongside
	-- poultry without dragging every chicken contract out to three years.
	if deliveryAge ~= nil then
		local yearsNeeded = math.ceil(deliveryAge / 12)
		if yearsNeeded > years then
			years = math.min(yearsNeeded, maxYears)
		end
	end

	local spec = self:buildAnimalSpec(subType, tier, kind, years)

	if spec == nil then
		return nil
	end

	-- THE ANCHOR: what an animal sitting exactly on this rung's band is worth (§3.1). Not the
	-- theoretical worst animal that would clear the spec — that was abandoned because it left
	-- rungs 1 to 3 only 18% apart, and because breeding metabolism DOWN to reach it is
	-- discoverable from RL's source but not from playing the game.
	local anchor = Offers.getAnimalAnchor(subType, tier, kind)

	if anchor == nil or anchor <= 0 then
		return nil
	end

	-- A BAND, NOT A FIXED NUMBER, rolled per offer so declining a mean offer and waiting for a
	-- refresh is a real choice; stored at signing so the agreed number holds for the term. Each
	-- rung's band overlaps the next by its own width, so the climb reads as a gradual shift
	-- rather than four fixed prices. With the anchor now climbing properly the multiplier no
	-- longer carries the ladder and returns to its own job: the certainty-versus-price trade.
	local multiplierBand = tier.rateMultiplier
	local rateMultiplier

	if type(multiplierBand) == "table" then
		local low = multiplierBand[1] or 1.0
		local high = multiplierBand[2] or low
		rateMultiplier = low + math.random() * (high - low)
	else
		rateMultiplier = multiplierBand or 1.0
	end

	-- Castration is worth +15% at the dealer (RealisticLivestock_Animal.lua:1306), so a contract
	-- asking for it is asking for a more valuable animal and must pay for it. Without this the
	-- player would do the extra work for nothing.
	if spec.requiresCastrated then
		anchor = anchor * 1.15
	end

	local perHeadPrice = anchor * rateMultiplier

	-- HEADCOUNT IS DERIVED FROM MONEY, never posted directly (§4.1). A flat headcount is the bug
	-- that produced a £274,530 entry contract: 25 head is 25 head whether that is chickens at £25
	-- or horses at £5,229, a ~200x range in money for the same nominal difficulty.
	--
	-- The fecundity blend and the effort divisor that used to sit here are GONE (§4.8, superseded
	-- 2026-07-30). They contradicted §4.1, and §4.2's endorsed figures only reproduce under pure
	-- money: the user's own two calibration points, 14 cattle and 37 pigs, are in a ratio of 2.64
	-- against the two anchors' 2.67. Applying the blend gives 5.8 cattle at tier 1 instead of 14.
	-- RESOLVED BEFORE THE HEADCOUNT, and the order is load-bearing: `client.size` scales the
	-- money target, so working it out afterwards would silently drop the loyalty growth.
	local client

	if overrides.clientId ~= nil and self.clients ~= nil
		and self.clients.getClientById ~= nil then
		client = self.clients:getClientById(overrides.clientId)
	end

	if client == nil then
		client = self:getClient(farmId, true)
	end

	local money = Offers.getAnimalMoneyLadder(subType, kind)

	-- THE LOYALTY BONUS, and livestock went without it until 2026-08-01. `client.size` was
	-- applied only in `rollAnnualValue`, which the crop and product path uses and this one does
	-- not — so a livestock contract was the same size whether the buyer had known you for ten
	-- years or ten minutes. Caught by the user's own renewal test: a renewal from a client with
	-- TWO completed contracts came back SMALLER than the contract it replaced.
	--
	-- It matters more here than for crops, because a livestock contract is POSTED. Crops carry
	-- loyalty twice — through size and through the negotiation premium relationship buys — and
	-- livestock is fixed-terms with no haggling, so size is its ONLY loyalty channel.
	local targetValue = (money[tierIndex] or money[1]) * ((client ~= nil and client.size) or 1)

	local head = math.floor(targetValue / math.max(perHeadPrice, 1) + 0.5)

	-- **THE HORSE HEADCOUNT CAP IS GONE (2026-07-30) AND MUST NOT BE RESTORED.** Horses derive
	-- their headcount from the money ladder exactly like every other species.
	--
	-- It existed because §1.7 costed horses at "ten real-world minutes per horse per in-game day
	-- for riding and grooming". Read from source, that figure is wrong twice over:
	--
	--   1. `AnimalHorse.getDailyRidingTime` is 300000 ms = FIVE minutes to take riding 0->100,
	--      and `Rideable:updateRiding` (Rideable.lua:1104-1116) multiplies by gait — canter x2,
	--      gallop x3. `ridingThresholdFactor` is absent from RL's animals.xml so it defaults to
	--      0.4 (AnimalSystem.lua:299), and only riding >= 40 is needed to HOLD fitness. That is
	--      **40 seconds per horse per day at gallop**, not ten minutes.
	--
	--   2. **None of it is required for a contract anyway.** `AnimalHealth.updateHealth` takes
	--      only `foodFactor` — no fitness, no dirt, no riding — and so does `updateWeight`. Those
	--      two drive `minHealth` and `minCondition`, which are the only husbandry gates a
	--      contract sets. RL's own `getHealthChangeFactor`, the one function that would make dirt
	--      matter, is marked "Currently unused - defined but no callers found".
	--
	-- Riding and grooming are optional upside at the DEALER (up to +62% trained, -25% wholly
	-- neglected) and the contract's flat rate is anchored at the untrained, clean floor — so a
	-- neglected horse realises less and the hedge pays the player MORE, not less.
	--
	-- **The lesson is §3.1's, and it was not applied here: check a concern is REAL before
	-- pricing against it.** The cap came from a tabulated estimate rather than from
	-- `AnimalHorse.lua`, and it cost tier-3 horses a third of their rung.
	--
	-- Horses remain gated to tier 3 and above (§1.7), which the user kept — they mature slowly
	-- and cost a great deal, and that is reason enough on its own.
	head = math.max(1, head)

	-- The flat agreed price per head. Settlement pays the difference between this and what the
	-- dealer actually gave (§0.5), so it is the whole of what a qualifying animal earns. The
	-- contract states a MINIMUM and pays the same for a better animal — meet the spec and sell
	-- your best elsewhere.
	local rate = perHeadPrice

	-- Paid each year the quota is met, on top of the per-head price. It exists to keep the
	-- below-market entry rung signable at all, and correctly disappears once the multiplier
	-- clears market: an unknown supplier is paid for SHOWING UP, a renowned breeder for the
	-- ANIMALS.
	local completionBonus = math.floor(head * anchor * (tier.bonusShare or 0))

	local marketValue = (rate * head + completionBonus) * years

	local offer = {
		id = self.nextOfferId,
		farmId = farmId,
		kind = Offers.KIND_ANIMAL,
		unit = ContractStore.UNIT_HEAD,
		fillTypeIndex = nil,
		marketRate = anchor,
		rate = rate,
		rateMultiplier = rateMultiplier,
		completionBonus = completionBonus,
		quotaPerYear = head,
		years = years,
		client = client,
		subTypeName = subType.name,
		herdSize = #herd,

		-- List 1 of 5 for the rebuild's spec fields (ContractStore:signContract names all
		-- five). A field missing from any one of them is lost with NO error.
		contractType = spec.contractType,
		overallBand = spec.overallBand,
		qualityFloor = spec.qualityFloor,
		prodFertFloor = spec.prodFertFloor,
		gender = spec.gender,
		requiresCastrated = spec.requiresCastrated,

		ageMin = spec.ageMin,
		ageMax = spec.ageMax,
		minCondition = spec.minCondition,
		minHealth = spec.minHealth,

		-- The feed the contract names, stored as TEXT. It is the only part of the spec that
		-- cannot be recomputed later: the roll picked one group among several, and the board and
		-- settlement must state the same one for the whole term.
		feedName = spec.feedName,

		-- The rung, for the board. `tierKey` is "1".."4b" — 4a and 4b share a reputation
		-- threshold, so the index alone would not tell them apart on screen.
		tierIndex = tierIndex,
		tierKey = tier.key,
		overallBandKey = tier.overallBandKey,
		traitBandKey = tier.traitBandKey,

		-- Presentation only. A species the farm is partly equipped for is shown as a
		-- RECOMMENDATION; one it has nothing for is a NEW OPPORTUNITY, and per §5.3a that label
		-- may only appear in recruitment mode. Neither is more likely to be offered.
		hasCrossover = Animals.hasFeedCrossover(subType, self:getKeptSubTypes(farmId), farmId),
		marketValue = marketValue,
		expiryDay = g_currentMission.environment.currentMonotonicDay + Offers.OFFER_LIFETIME_DAYS,
	}

	self.nextOfferId = self.nextOfferId + 1
	table.insert(self.offers, offer)

	return offer
end

--- Accept a livestock offer on its posted terms. No negotiation — see createAnimalOffer.
function Offers:acceptAnimalOffer(offer)
	-- Same guard as the crop path, and for the same reason: an offer outlives the moment it was
	-- generated in. See acceptSupplyOffer.
	if self:getRemainingBudget(offer.farmId, self:getReputation(offer.farmId)) <= 0 then
		return nil, Offers.REFUSED_BUDGET
	end

	local contract = self.contractStore:signContract({
		farmId = offer.farmId,
		clientId = offer.client.id,
		kind = ContractStore.KIND_SUPPLY,
		unit = ContractStore.UNIT_HEAD,
		fillTypeIndex = nil,
		rate = offer.rate,
		rateMultiplier = offer.rateMultiplier,

		-- Posted, not negotiated — see ANIMAL_TIERS.bonusShare for why it exists and why it
		-- shrinks as the multiplier grows.
		completionBonus = offer.completionBonus or 0,

		quotaPerYear = offer.quotaPerYear,
		years = offer.years,
		traitFloors = offer.traitFloors,
		subTypeName = offer.subTypeName,
		ageMin = offer.ageMin,
		ageMax = offer.ageMax,
		minCondition = offer.minCondition,
		minHealth = offer.minHealth,

		-- List 2 of 5 for the rebuild's spec fields, and **THIS IS THE LIST THAT HAS ALREADY
		-- LOST ONE.** `feedName` below was generated, displayed and persisted and still never
		-- reached disk, purely because this table was built field by field and the new field was
		-- never added to it. Nothing in play showed it — the panel reads the OFFER, which still
		-- had the value. It was found by reading the savegame.
		--
		-- Add every new spec field HERE as well as in the offer table, signContract, save and
		-- load. Five places. Grep `qualityFloor` and expect five hits.
		contractType = offer.contractType,
		overallBand = offer.overallBand,
		qualityFloor = offer.qualityFloor,
		prodFertFloor = offer.prodFertFloor,
		gender = offer.gender,
		requiresCastrated = offer.requiresCastrated,

		-- **WAS MISSING UNTIL 2026-07-29 AND THE SAVEGAME IS WHAT EXPOSED IT.** The offer panel
		-- displayed the feed correctly, ContractStore persisted the field, and the accepted
		-- contract still saved without it — because this table is built field by field and the
		-- new one was never added. A signed contract silently forgot which feed it had named.
		--
		-- It cannot be recomputed later: the feed is ROLLED among several groups, so re-deriving
		-- it would state a different feed than the player agreed to.
		feedName = offer.feedName,
	})

	self:removeOffer(offer.id)

	return contract
end

--- Decide whether a new BATCH of spot orders is due, and post it if so.
---
--- Three states, and the middle one is the whole feature:
---
---   * orders still on the board  -> nothing to do, and the timer is cleared so the gap is
---                                   measured from the moment the board actually empties
---   * board just emptied         -> start the cooldown, post nothing
---   * cooldown served            -> post a fresh batch
---
--- Called from refresh on DAY_CHANGED, so "day" is the only resolution available and the
--- only one that matters.
function Offers:refreshSpotOffers(farmId, spotCount, candidates, tier, processed)
	local today = g_currentMission.environment.currentMonotonicDay

	if spotCount > 0 then
		self.spotResumeDay[farmId] = nil
		return
	end

	local resumeDay = self.spotResumeDay[farmId]

	if resumeDay == nil then
		-- FIRST REFRESH AFTER A LOAD POSTS IMMEDIATELY, and this branch exists entirely for
		-- that. Offers are not persisted — `main.lua` regenerates the board on load — so every
		-- restart hands us an empty spot board that is indistinguishable from one that just
		-- emptied in play. Charging the cooldown for it meant NO SPOT ORDERS FOR THREE DAYS
		-- AFTER EVERY RESTART, and a player who saves and quits each session would barely see
		-- one. Found by reading the load path, not in play; it would have looked like the
		-- feature simply not working.
		--
		-- `seenFarm` is what separates the two cases: a farm the board has already served this
		-- session emptied for real and serves the gap.
		self.seenFarm = self.seenFarm or {}

		if self.seenFarm[farmId] then
			-- Emptied during play. Serve the gap.
			self.spotResumeDay[farmId] = today + Offers.SPOT_COOLDOWN_DAYS
			return
		end

		-- First sight of this farm since load. Treat the gap as already served, rather than
		-- leaving resumeDay nil and comparing a number against it below.
		self.seenFarm[farmId] = true
		resumeDay = today
	end

	if today < resumeDay then
		return
	end

	self.spotResumeDay[farmId] = nil

	for _ = 1, Offers.MAX_SPOT_OFFERS do
		self:createSpotOffer(farmId, candidates, tier, processed)
	end
end

--- Spot orders are take-it-or-leave-it: a set price, no haggling, short fuse.
---
--- **NO COVERAGE HINT HERE, AND THAT IS A RULING RATHER THAN AN OVERSIGHT.** User, 2026-08-01:
--- *"Spot orders should not have any coverage hint. These are quick turnaround contracts that
--- are solely up to the user's discretion."*
---
--- The nudge exists on annual contracts because those are multi-year commitments with a
--- penalty, a reputation cost and a termination clause behind them. A spot order is one small
--- delivery on a two-day fuse that you can simply decline. Adding a hint would be the mod
--- having an opinion about a decision that costs nothing to get wrong.
---
--- The harness asserts this function never mentions `coverageHint`.
-- coverageHint
function Offers:createSpotOffer(farmId, candidates, tier, processed)
	local pick = candidates[math.random(#candidates)]
	local complexity = self:getComplexity(pick.fillTypeIndex, processed)

	local premium = Offers.SPOT_PREMIUM[1]
		+ (Offers.SPOT_PREMIUM[2] - Offers.SPOT_PREMIUM[1]) * complexity

	local share = Offers.SPOT_QUOTA_SHARE[1]
		+ math.random() * (Offers.SPOT_QUOTA_SHARE[2] - Offers.SPOT_QUOTA_SHARE[1])

	-- Money first here too. A spot order is a SLICE of what a contract on this rung would be
	-- worth, so it has to be sized off the same ladder — left on litres it would have kept
	-- the exact fault the ladder was introduced to remove, one order of magnitude smaller.
	local quantity = Offers.deriveQuota(tier.annualValue * share, pick.marketRate)

	if quantity == nil then
		return nil
	end

	local duration = math.random(Offers.SPOT_DURATION_DAYS[1], Offers.SPOT_DURATION_DAYS[2])

	local offer = {
		id = self.nextOfferId,
		farmId = farmId,
		kind = Offers.KIND_SPOT,
		unit = ContractStore.UNIT_LITRES,
		fillTypeIndex = pick.fillTypeIndex,
		marketRate = pick.marketRate,
		suggestedStation = pick.stationName,
		quotaPerYear = quantity,
		years = 1,
		client = self:getClient(farmId, complexity > 0),
		rate = pick.marketRate * (1 + premium),
		premium = premium,
		durationDays = duration,
		expiryDay = g_currentMission.environment.currentMonotonicDay + duration,
	}

	self.nextOfferId = self.nextOfferId + 1
	table.insert(self.offers, offer)

	self:notifySpotOffer(offer)

	return offer
end

function Offers:notifySpotOffer(offer)
	local fillType = g_fillTypeManager:getFillTypeByIndex(offer.fillTypeIndex)
	local title = fillType ~= nil and fillType.title or "?"

	g_currentMission:addIngameNotification(FSBaseMission.INGAME_NOTIFICATION_INFO,
		string.format("%s wants %s %s at %d%% above market",
			offer.client.name, g_i18n:formatVolume(offer.quotaPerYear), title,
			math.floor(offer.premium * 100 + 0.5)))
end

-- ---------------------------------------------------------------------------
-- Accepting
-- ---------------------------------------------------------------------------

--- Sign a spot order at its posted price. No negotiation.
function Offers:acceptSpotOffer(offer)
	local contract = self.contractStore:signContract({
		farmId = offer.farmId,
		clientId = offer.client.id,
		kind = ContractStore.KIND_SPOT,
		unit = offer.unit,
		fillTypeIndex = offer.fillTypeIndex,
		rate = offer.rate,
		suggestedStation = offer.suggestedStation,
		completionBonus = 0,
		quotaPerYear = offer.quotaPerYear,
		years = 1,
		durationDays = offer.durationDays,
	})

	self:removeOffer(offer.id)

	return contract
end

--- Sign a supply contract on terms reached through Negotiation.
---
--- `agreedValue` is the total the client accepted; `mix` is the player's rate/bonus lever.
function Offers:acceptSupplyOffer(offer, agreedValue, mix)
	-- THE BUDGET IS ENFORCED HERE, NOT ONLY AT GENERATION, and both are needed. An offer sits on
	-- the board for `OFFER_LIFETIME_DAYS`, so a player can be shown two offers, sign one, and
	-- still be holding the other when they are already at their limit. Generation alone would
	-- let the second through.
	if self:getRemainingBudget(offer.farmId, self:getReputation(offer.farmId)) <= 0 then
		return nil, nil, Offers.REFUSED_BUDGET
	end

	local terms = Negotiation.splitValue(agreedValue, mix, offer.quotaPerYear, offer.years)

	local contract = self.contractStore:signContract({
		farmId = offer.farmId,
		clientId = offer.client.id,
		kind = ContractStore.KIND_SUPPLY,
		unit = offer.unit,
		fillTypeIndex = offer.fillTypeIndex,
		rate = terms.rate,
		completionBonus = terms.completionBonus,
		quotaPerYear = offer.quotaPerYear,
		years = offer.years,

		-- Carried through from the offer. Dropping it is how a signed contract came to say
		-- nothing about where to deliver — see ContractStore:signContract.
		suggestedStation = offer.suggestedStation,

		-- nil on everything except livestock, and ContractStore only persists it when
		-- present — so this carries the genetic specification without the crop path
		-- needing to know livestock exists.
		traitFloors = offer.traitFloors,

		-- "PRODUCT" for an animal's output, nil for an ordinary crop. The crop path has to
		-- carry it because a PRODUCT contract IS a crop contract mechanically (§5.2) — it
		-- shares the kind, the unit and the whole settlement path, and only this field
		-- distinguishes it. Omitting it here is the `feedName` bug's exact shape.
		contractType = offer.contractType,
	})

	self:removeOffer(offer.id)

	return contract, terms
end

--- The client walked, or the player pushed too hard. The offer is gone either way
--- (HANDOFF.md §4.4) — that is what stops negotiation being a slot machine.
function Offers:abandonOffer(offer, pushedTooHard, badFaith)
	self:removeOffer(offer.id)

	if self.reputation == nil then
		return
	end

	-- Bad faith is the heavier penalty: they moved, you did not, and they walked. Pushing
	-- too hard is at least an honest attempt at a deal.
	if badFaith then
		self.reputation:onNegotiationBadFaith(offer)
	elseif pushedTooHard then
		self.reputation:onNegotiationPushedTooHard(offer)
	end
end

function Offers:removeOffer(offerId)
	for index = #self.offers, 1, -1 do
		if self.offers[index].id == offerId then
			table.remove(self.offers, index)
		end
	end
end

-- ---------------------------------------------------------------------------
-- Board upkeep
-- ---------------------------------------------------------------------------

function Offers:onDayChanged()
	local today = g_currentMission.environment.currentMonotonicDay

	for index = #self.offers, 1, -1 do
		if today >= self.offers[index].expiryDay then
			table.remove(self.offers, index)
		end
	end

	-- Station prices move daily, so a cached market rate goes stale.
	self.sellableCache = nil

	-- Re-read the coverage hints. Land and herds change between day changes, and a stale
	-- nudge is worse than none — it would be telling the player something about a farm they
	-- no longer have. Once a day, not per frame: this walks every field and every animal.
	for _, offer in ipairs(self.offers) do
		if offer.quotaPerYear ~= nil and offer.kind ~= Offers.KIND_ANIMAL then
			offer.coverageHint =
				self:getCoverageHint(offer.farmId, offer.fillTypeIndex, offer.quotaPerYear)
		end
	end

	for _, farm in ipairs(g_farmManager:getFarms()) do
		if farm.farmId ~= FarmManager.SPECTATOR_FARM_ID then
			self:refresh(farm.farmId)
		end
	end
end

function Offers:getOffers(farmId)
	local result = {}

	for _, offer in ipairs(self.offers) do
		if offer.farmId == farmId then
			table.insert(result, offer)
		end
	end

	return result
end
