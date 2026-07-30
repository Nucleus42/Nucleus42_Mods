-- Forward Contracts — Negotiation
--
-- Haggling over a contract's terms. Pure logic: no GUI, no world state, no side effects.
-- The UI drives it round by round and applies the outcome.
--
-- Modelled on the shape used by Farmland Market's negotiation engine — anchor, hidden
-- reservation, decaying stubbornness, convergence split, last-ditch offer on a late walk.
-- Written fresh from that concept, not copied (HANDOFF.md §6.1).
--
-- Direction matters: the client is BUYING from you. They anchor low, hold a hidden
-- maximum, and walk if you ask absurdly above it. You are pushing the number up.
--
-- What is actually negotiated is the contract's TOTAL VALUE (HANDOFF.md §4.4). How that
-- total is split between per-litre rate and annual completion bonus is a separate choice
-- the player makes with one lever — see splitValue below.

Negotiation = {}

Negotiation.MAX_ROUNDS = 3

Negotiation.OUTCOME_ACCEPTED = "accepted"
Negotiation.OUTCOME_COUNTERED = "countered"
Negotiation.OUTCOME_CONVERGED = "converged"
Negotiation.OUTCOME_WALKED = "walked"
Negotiation.OUTCOME_LAST_DITCH = "lastDitch"

Negotiation.PARAMS = {
	-- Client's opening offer, as a fraction of the contract's market value.
	anchor = { 0.58, 0.70 },

	-- Hidden maximum they will pay, BEFORE reputation and relationship are added.
	--
	-- This base range must stay below 1.0. An unknown farm trades price for guaranteed
	-- offtake — that is what makes the contract a hedge (HANDOFF.md §4.2, §4.3). An early
	-- version had this at 0.98–1.14 and every mid-range ask was accepted instantly, paying
	-- above spot for the whole term and quietly destroying the premise.
	--
	-- Rising above market is EARNED, not given: see the reputation and relationship
	-- bonuses below, which is the only route past 1.0.
	reservation = { 0.84, 0.94 },

	-- Ask beyond reservation × this and they stop negotiating entirely.
	walkawayMultiple = 1.12,

	-- How hard they cling to their anchor. Decays each round: nobody holds the line
	-- forever, and a client who never moves is not a negotiation.
	stubbornness = { base = 0.52, range = 0.20 },
	decay = 0.55,

	-- Counters wobble so the same contract does not play out identically twice.
	counterNoise = 0.035,

	-- Within this fraction of reservation, split the difference rather than grind out
	-- another round over pennies.
	convergenceThreshold = 0.025,

	-- Walking in the final round while close can draw them back out.
	lastDitchChance = 0.35,
	lastDitchProximity = 0.97,

	-- Relationship (0..1) softens everything. A client who knows you opens better and
	-- argues less — this is what makes repeat business worth more than a new client
	-- (HANDOFF.md §4.1).
	relationshipAnchorBonus = 0.10,
	relationshipReservationBonus = 0.10,
	relationshipStubbornnessRelief = 0.30,

	-- Reputation (0..1) lifts the ceiling. Being known to deliver is worth real money.
	reputationReservationBonus = 0.08,

	-- These two are the ONLY route above market. Worked through:
	--
	--   unknown farm      0.84 – 0.94   always below spot, as intended
	--   maxed rep + rel   1.02 – 1.12   2% to 12% ABOVE spot
	--
	-- So a proven supplier with a standing relationship commands a genuine premium, and
	-- even an unlucky roll beats market — which is the right reward for years of clean
	-- delivery against contracts that have also grown harder to fill (Offers.TIERS scales
	-- quota with reputation at the same time).
	--
	-- Note this compounds with the bonus-weighted mix: a maxed-out, bonus-heavy deal can
	-- reach roughly 1.12 x 1.18 of market. That is contingent money — miss a year and you
	-- lose the bonus AND pay the shortfall penalty — but it is the number to watch if the
	-- late game ever starts to feel too rich.
}

-- How the one lever behaves. A completion bonus is contingent — the client only pays it
-- if you actually finish the year — so they will commit MORE total value when more of it
-- sits in the bonus. Guaranteed money is worth less; risk is worth a premium.
Negotiation.BONUS_RISK_PREMIUM = 0.18
Negotiation.BONUS_SHARE_MAX = 0.35

-- ---------------------------------------------------------------------------
-- Local helpers
-- ---------------------------------------------------------------------------

local function randomInRange(low, high)
	return low + math.random() * (high - low)
end

local function gaussian(mean, deviation)
	local u1 = math.max(math.random(), 1e-10)
	local u2 = math.random()
	return mean + math.sqrt(-2 * math.log(u1)) * math.cos(2 * math.pi * u2) * deviation
end

local function clamp(value, low, high)
	return math.max(low, math.min(high, value))
end

-- ---------------------------------------------------------------------------
-- Profile
-- ---------------------------------------------------------------------------

--- Build the client's negotiating position for one offer.
---
--- `marketValue` is what the whole contract's volume is worth at today's prices.
--- `relationship` and `reputation` are both 0..1 and both optional.
function Negotiation.createProfile(marketValue, relationship, reputation)
	local params = Negotiation.PARAMS

	relationship = clamp(relationship or 0, 0, 1)
	reputation = clamp(reputation or 0, 0, 1)

	local anchorFraction = randomInRange(params.anchor[1], params.anchor[2])
		+ params.relationshipAnchorBonus * relationship

	local reservationFraction = randomInRange(params.reservation[1], params.reservation[2])
		+ params.relationshipReservationBonus * relationship
		+ params.reputationReservationBonus * reputation

	local stubbornness = params.stubbornness.base
		+ randomInRange(-params.stubbornness.range, params.stubbornness.range)
	stubbornness = stubbornness * (1 - params.relationshipStubbornnessRelief * relationship)

	local anchorValue = marketValue * anchorFraction
	local reservationValue = marketValue * reservationFraction

	-- A generous anchor must never exceed the reservation, or round one would accept
	-- anything and the negotiation would be theatre.
	anchorValue = math.min(anchorValue, reservationValue * 0.97)

	return {
		marketValue = marketValue,
		anchorValue = anchorValue,
		reservationValue = reservationValue,
		walkawayValue = reservationValue * params.walkawayMultiple,
		stubbornness = clamp(stubbornness, 0.05, 0.95),
		lastCounter = anchorValue,
	}
end

-- ---------------------------------------------------------------------------
-- Rounds
-- ---------------------------------------------------------------------------

--- Evaluate the player's asking price for one round.
---
--- Returns { outcome = ..., value = <agreed total, when a deal lands>,
---           counter = <client's counter, when they counter> }
function Negotiation.evaluateAsk(profile, askValue, round)
	local params = Negotiation.PARAMS

	-- Pushing this hard ends it. The offer is gone and reputation suffers: nobody wants
	-- to deal with someone who wants everything their own way (HANDOFF.md §4.4).
	if askValue > profile.walkawayValue then
		return { outcome = Negotiation.OUTCOME_WALKED, pushedTooHard = true }
	end

	-- Repeating your number after they have moved is not negotiating, it is waiting for
	-- them to bid against themselves. They will not: they conceded in good faith and got
	-- nothing back, so they leave. This is the worst outcome available and carries the
	-- heaviest reputation cost — worse than pushing too hard, which is at least an
	-- honest attempt at a deal.
	if round > 1 and profile.previousAsk ~= nil and askValue >= profile.previousAsk then
		return { outcome = Negotiation.OUTCOME_WALKED, badFaith = true }
	end

	profile.previousAsk = askValue

	-- Where they stand this round. They concede toward their ceiling, less each round.
	local decay = params.decay ^ (round - 1)
	local gap = profile.reservationValue - profile.anchorValue
	local base = profile.reservationValue - profile.stubbornness * gap * decay
	local counter = clamp(
		gaussian(base, params.counterNoise * profile.marketValue),
		profile.anchorValue,
		profile.reservationValue)

	-- Never counter below what they already offered — moving backwards reads as a bug.
	counter = math.max(counter, profile.lastCounter or profile.anchorValue)
	profile.lastCounter = counter

	-- Asking less than they were about to offer: they take it instantly and keep the
	-- difference. Lowballing yourself is its own punishment.
	if askValue <= counter then
		return { outcome = Negotiation.OUTCOME_ACCEPTED, value = askValue }
	end

	if math.abs(askValue - counter) / profile.reservationValue < params.convergenceThreshold then
		return {
			outcome = Negotiation.OUTCOME_CONVERGED,
			value = (askValue + counter) / 2,
			counter = counter,
		}
	end

	-- Final round: take it or leave it.
	if round >= Negotiation.MAX_ROUNDS then
		if askValue <= profile.reservationValue then
			return { outcome = Negotiation.OUTCOME_ACCEPTED, value = askValue }
		end

		return { outcome = Negotiation.OUTCOME_WALKED, counter = counter }
	end

	-- Rounds 1 and 2: they counter rather than accept, EVEN IF the ask is already within
	-- their ceiling.
	--
	-- Accepting a first reasonable ask outright is what made the whole thing feel broken
	-- in play-testing: no counter ever appeared, so the player learned nothing and could
	-- not tell a good deal from a bad one. A buyer haggles even when your number would
	-- have done. Now each round reveals a little more of their position, and the real
	-- question becomes how far you can push before round three.
	return { outcome = Negotiation.OUTCOME_COUNTERED, counter = counter }
end

--- The player walks away. Sometimes the client comes back.
function Negotiation.evaluateWalkaway(profile, lastAsk, round)
	local params = Negotiation.PARAMS

	if round >= Negotiation.MAX_ROUNDS
		and lastAsk <= profile.reservationValue / params.lastDitchProximity
		and math.random() < params.lastDitchChance then
		return {
			outcome = Negotiation.OUTCOME_LAST_DITCH,
			value = (lastAsk + profile.reservationValue) / 2,
		}
	end

	return { outcome = Negotiation.OUTCOME_WALKED }
end

-- ---------------------------------------------------------------------------
-- The lever
-- ---------------------------------------------------------------------------

--- Split an agreed total value into a per-unit rate and an annual completion bonus.
---
--- `mix` runs 0..1: all guaranteed rate at 0, maximum bonus weighting at 1. Loading the
--- bonus increases the total the client will commit, because they only pay it if you
--- deliver. Steady income, or a bigger number you have to earn.
function Negotiation.splitValue(totalValue, mix, quotaPerYear, years)
	mix = clamp(mix or 0, 0, 1)

	local effectiveTotal = totalValue * (1 + Negotiation.BONUS_RISK_PREMIUM * mix)
	local bonusTotal = effectiveTotal * Negotiation.BONUS_SHARE_MAX * mix
	local rateTotal = effectiveTotal - bonusTotal

	local totalVolume = math.max(quotaPerYear * years, 1)

	return {
		rate = rateTotal / totalVolume,
		completionBonus = bonusTotal / math.max(years, 1),
		totalValue = effectiveTotal,
	}
end

--- What the player would be paid at market, for showing alongside the offer.
function Negotiation.getMarketValue(marketRate, quotaPerYear, years)
	return marketRate * quotaPerYear * years
end
