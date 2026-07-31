-- Forward Contracts — ContractBoardFrame
--
-- The board page in the ESC menu. Lists live contracts first, then what is on offer.
-- Reads from ContractStore and Offers; owns no rules of its own.

ContractBoardFrame = {}

local ContractBoardFrame_mt = Class(ContractBoardFrame, TabbedMenuFrameElement)

ContractBoardFrame.ENTRY_CONTRACT = "contract"
ContractBoardFrame.ENTRY_SUPPLY_OFFER = "supplyOffer"
ContractBoardFrame.ENTRY_SPOT_OFFER = "spotOffer"
-- Livestock offers are posted, not negotiated, so they accept like a spot order rather
-- than opening the negotiation dialog.
ContractBoardFrame.ENTRY_ANIMAL_OFFER = "animalOffer"

-- Reputation stages, lowest first. Deliberately words rather than a percentage: the
-- player should know roughly where they stand, not be able to optimise a number.
-- Edit freely — the bar reads whichever labels are here.
ContractBoardFrame.REPUTATION_STAGES = {
	{ from = 0.00, label = "Unknown" },
	{ from = 0.12, label = "A foot in the door" },
	{ from = 0.30, label = "Becoming known" },
	{ from = 0.50, label = "Talked about" },
	{ from = 0.70, label = "Well regarded" },
	{ from = 0.88, label = "The first name they call" },
}

function ContractBoardFrame.new(target, customMt)
	local self = TabbedMenuFrameElement.new(target, customMt or ContractBoardFrame_mt)

	self.entries = {}

	return self
end

-- Note: the frame is constructed and loaded by UI:install, which must control the GUI
-- name so it matches the control id it exposes on the menu controller.

function ContractBoardFrame:initialize()
	self.backButtonInfo = {
		inputAction = InputAction.MENU_BACK,
	}

	self.actionButtonInfo = {
		inputAction = InputAction.MENU_ACCEPT,
		text = g_i18n:getText("fc_button_negotiate"),
		callback = function()
			self:onActivateEntry()
		end,
	}

	-- The bottom button bar is built from menuButtonInfo, and setMenuButtonInfo is what
	-- also flips hasCustomMenuButtons (TabbedMenuFrameElement.lua:25-28). Setting the
	-- backButtonInfo/actionButtonInfo fields alone does nothing — nothing reads them —
	-- and the menu falls back to unlabelled placeholders. Cost a broken button row on
	-- 2026-07-27.
	self:setMenuButtonInfo({ self.backButtonInfo, self.actionButtonInfo })

	self:setTitle(g_i18n:getText("ui_contractBoard"))
end

-- TabbedMenu calls these during its layout pass. They must never throw: an error here
-- aborts the menu's update for EVERY page, which shows up as unlabelled buttons and blank
-- content across the whole ESC menu rather than as a problem with this page.
function ContractBoardFrame:getMainElementSize()
	if self.contractBoard == nil then
		return ContractBoardFrame:superClass().getMainElementSize(self)
	end

	return self.contractBoard.size
end

function ContractBoardFrame:getMainElementPosition()
	if self.contractBoard == nil then
		return ContractBoardFrame:superClass().getMainElementPosition(self)
	end

	return self.contractBoard.absPosition
end

function ContractBoardFrame:onFrameOpen()
	ContractBoardFrame:superClass().onFrameOpen(self)

	self:rebuild()
end

-- ---------------------------------------------------------------------------
-- Data
-- ---------------------------------------------------------------------------

function ContractBoardFrame:getFarmId()
	return g_currentMission:getFarmId()
end

function ContractBoardFrame:rebuild()
	local farmId = self:getFarmId()

	self.entries = {}

	local store = ForwardContracts.contractStore
	if store ~= nil then
		for _, contract in ipairs(store:getContracts(farmId)) do
			table.insert(self.entries, {
				kind = ContractBoardFrame.ENTRY_CONTRACT,
				contract = contract,
			})
		end
	end

	local offers = ForwardContracts.offers
	if offers ~= nil then
		for _, offer in ipairs(offers:getOffers(farmId)) do
			local kind = ContractBoardFrame.ENTRY_SUPPLY_OFFER
			if offer.kind == ContractStore.KIND_SPOT then
				kind = ContractBoardFrame.ENTRY_SPOT_OFFER
			elseif offer.unit == ContractStore.UNIT_HEAD then
				kind = ContractBoardFrame.ENTRY_ANIMAL_OFFER
			end

			table.insert(self.entries, { kind = kind, offer = offer })
		end
	end

	if self.boardList ~= nil then
		self.boardList:reloadData()
	end

	self:updateReputation()
	self:updateDetail()
end

-- ---------------------------------------------------------------------------
-- Reputation header
-- ---------------------------------------------------------------------------

function ContractBoardFrame.getReputationStage(reputation)
	local stage = ContractBoardFrame.REPUTATION_STAGES[1]

	for _, candidate in ipairs(ContractBoardFrame.REPUTATION_STAGES) do
		if reputation >= candidate.from then
			stage = candidate
		end
	end

	return stage
end

--- Read a tier field for this reputation, and the same field at the NEXT tier up.
---
--- Static so the header does not depend on an Offers instance existing. Tier tables are
--- ordered ascending by minReputation, so the first entry the farm has not reached is the
--- next one.
local function tierField(tiers, reputation, field)
	local current, nextAt, nextValue

	for _, tier in ipairs(tiers or {}) do
		if reputation >= tier.minReputation then
			current = tier[field]
		elseif nextAt == nil then
			nextAt = tier.minReputation
			nextValue = tier[field]
		end
	end

	return current, nextAt, nextValue
end

--- What this standing entitles the farm to, and what the next one adds.
---
--- **THE SLOTS WERE COMPLETELY INVISIBLE BEFORE THIS.** A player had no way to learn why a
--- second livestock offer never appeared, or what would change it. Requested by the user
--- 2026-07-29; the whole livestock ladder assumes the player can see the rungs.
---
--- ONE LINE — the profile allows no wrapping and the header container has no room for a
--- second. Keep it terse.
function ContractBoardFrame.describeEntitlement(reputation)
	if Offers == nil or Offers.TIERS == nil or Offers.ANIMAL_TIERS == nil then
		return nil
	end

	-- ONE BUDGET ACROSS EVERY TYPE (§6). This line used to read "up to N crop and M livestock",
	-- which no longer exists — per-type slots were replaced because their SUM had never been
	-- added up and reached 13 contracts worth ~£950,000 a year at tier 4.
	--
	-- The wording has to carry that the allowance is FREELY ALLOCATED, because that choice is
	-- the mechanic: *"A player taking 3 livestock and 2 crop is specialising; one taking 5 crop
	-- is a different farm."* A player who reads "5 contracts" and assumes a fixed split has
	-- misunderstood the only decision the budget asks them to make.
	local budget, nextAt, nextBudget = nil, nil, nil

	if Offers.getContractBudget ~= nil then
		budget = Offers:getContractBudget(reputation)

		for i = 1, #Offers.CONTRACT_BUDGET do
			local threshold = Offers.ANIMAL_TIERS[i] and Offers.ANIMAL_TIERS[i].minReputation
			if threshold ~= nil and reputation < threshold then
				nextAt, nextBudget = threshold, Offers.CONTRACT_BUDGET[i]
				break
			end
		end
	end

	if budget == nil then
		return nil
	end

	-- REPUTATION IS SHOWN AS A PERCENTAGE. User ruling 2026-07-29: *"0.04 should be 4%. It makes
	-- much more sense that way."* Reputation is already a 0-1 fraction, so this is presentation
	-- only — every threshold in Offers.TIERS stays a fraction.
	local parts = {
		string.format("Reputation %d%% — can hold up to %d contract%s at once, in any mix",
			math.floor(reputation * 100 + 0.5), budget, budget == 1 and "" or "s"),
	}

	if nextAt ~= nil and nextBudget ~= nil and nextBudget > budget then
		table.insert(parts, string.format("At %d%%: %d contracts and better terms",
			math.floor(nextAt * 100 + 0.5), nextBudget))
	elseif nextAt ~= nil then
		-- A tier that grants no extra slot still raises the rung every offer is drawn at, so
		-- saying nothing here would read as "there is no point climbing further".
		table.insert(parts, string.format("At %d%%: better terms, though no extra contract",
			math.floor(nextAt * 100 + 0.5)))
	else
		table.insert(parts, "Nothing further to unlock")
	end

	return table.concat(parts, ". ") .. "."
end

function ContractBoardFrame:updateReputation()
	local reputation = 0

	if ForwardContracts.reputation ~= nil then
		reputation = ForwardContracts.reputation:getReputation(self:getFarmId()) or 0
	end

	if self.reputationLabel ~= nil then
		self.reputationLabel:setText(ContractBoardFrame.getReputationStage(reputation).label)
	end

	if self.reputationEntitlement ~= nil then
		self.reputationEntitlement:setText(ContractBoardFrame.describeEntitlement(reputation) or "")
	end

	-- Width comes from the background element rather than a hardcoded number, so the bar
	-- stays correct if the profile size changes. Sizes are normalised, so a plain multiply
	-- is right. A sliver is always drawn at zero so the bar reads as empty, not missing.
	if self.reputationBarFill ~= nil and self.reputationBarBg ~= nil then
		local full = self.reputationBarBg.size[1]
		local fraction = math.max(0, math.min(1, reputation))

		self.reputationBarFill:setSize(math.max(full * fraction, full * 0.004),
			self.reputationBarFill.size[2])
	end
end

-- SmoothListElement's selection getter is getSelectedIndexInSection
-- (scripts/gui/elements/SmoothListElement.lua:1019). There is no getSelectedElementIndex;
-- calling it threw on every mouse move over the page and blanked the whole frame.
-- We use a single section, so the in-section index is the entry index.
function ContractBoardFrame:getSelectedEntry()
	if self.boardList == nil then
		return nil
	end

	local index = self.boardList:getSelectedIndexInSection()
	if index == nil then
		return nil
	end

	return self.entries[index]
end

-- ---------------------------------------------------------------------------
-- List callbacks
-- ---------------------------------------------------------------------------

function ContractBoardFrame:getNumberOfItemsInSection(list, section)
	return #self.entries
end

function ContractBoardFrame:populateCellForItemInSection(list, section, index, cell)
	local entry = self.entries[index]
	if entry == nil then
		return
	end

	local title, subtitle = self:describeEntry(entry)

	cell:getAttribute("title"):setText(title)
	cell:getAttribute("subtitle"):setText(subtitle)
end

function ContractBoardFrame:onListSelectionChanged()
	self:updateDetail()
end

function ContractBoardFrame:onListDoubleClick()
	self:onActivateEntry()
end

-- ---------------------------------------------------------------------------
-- Presentation
-- ---------------------------------------------------------------------------

local function productName(fillTypeIndex)
	local fillType = g_fillTypeManager:getFillTypeByIndex(fillTypeIndex)
	return fillType ~= nil and fillType.title or "?"
end

--- Time left on a spot order, as hours rather than whole days.
---
--- "1 day(s)" reads as a rounding, not a deadline, and does not change as the clock runs.
--- Hours make the urgency legible — and on a 1-day month a spot order really is a matter
--- of hours.
local function formatDeadline(expiryDay)
	local environment = g_currentMission.environment
	local hours = (expiryDay - environment.currentMonotonicDay) * 24 - (environment.currentHour or 0)

	if hours <= 0 then
		return g_i18n:getText("fc_deadline_expired")
	end

	if hours < 24 then
		return string.format(g_i18n:getText("fc_deadline_hours"), math.floor(hours))
	end

	return string.format(g_i18n:getText("fc_deadline_daysHours"),
		math.floor(hours / 24), math.floor(hours % 24))
end

function ContractBoardFrame:describeEntry(entry)
	if entry.kind == ContractBoardFrame.ENTRY_CONTRACT then
		local contract = entry.contract
		local delivered = contract.quotaThisYear - contract.remainingLitres

		-- Livestock counts in head, not litres, so formatVolume would read "20,000 l" for
		-- twenty cows. It also has no fill type to name.
		if contract.unit == ContractStore.UNIT_HEAD then
			return string.format("%s — %s", ContractBoardFrame.describeContractType(contract),
					g_i18n:getText("fc_entry_active")),
				string.format("%d of %d animals this year · year %d of %d",
					delivered, contract.quotaThisYear, contract.yearIndex, contract.years)
		end

		if contract.kind == ContractStore.KIND_SPOT then
			return string.format("%s — %s", productName(contract.fillTypeIndex),
					g_i18n:getText("fc_entry_spotActive")),
				string.format("%s of %s · %s",
					g_i18n:formatVolume(delivered),
					g_i18n:formatVolume(contract.quotaThisYear),
					formatDeadline(contract.expiryDay))
		end

		return string.format("%s — %s", productName(contract.fillTypeIndex),
				g_i18n:getText("fc_entry_active")),
			string.format("%s of %s this year · year %d of %d",
				g_i18n:formatVolume(delivered),
				g_i18n:formatVolume(contract.quotaThisYear),
				contract.yearIndex, contract.years)
	end

	local offer = entry.offer

	if entry.kind == ContractBoardFrame.ENTRY_SPOT_OFFER then
		return string.format("%s — %s", productName(offer.fillTypeIndex),
				g_i18n:getText("fc_entry_spot")),
			string.format("%s · %s · %d%% above market · %s",
				g_i18n:formatVolume(offer.quotaPerYear),
				formatDeadline(offer.expiryDay),
				math.floor(offer.premium * 100 + 0.5), offer.client.name)
	end

	if offer.unit == ContractStore.UNIT_HEAD then
		-- Labelled by whether the farm has any equipment crossover at all. Both kinds appear
		-- with equal likelihood; the label only says which kind of decision this is.
		return string.format("%s — %s", ContractBoardFrame.describeContractType(offer),
				g_i18n:getText(offer.hasCrossover and "fc_entry_recommendation"
					or "fc_entry_opportunity")),
			-- Cash per head, not a multiplier. The price is flat, so "0.87x value" would
			-- invite the player to read it as a share of whatever they deliver.
			string.format("%d animals per year for %d years · %s per head · %s",
				offer.quotaPerYear, offer.years,
				g_i18n:formatMoney(offer.rate or 0, 0, true, true),
				offer.client.name)
	end

	-- A PRODUCT offer shares the crop kind, unit and settlement path, so only `contractType`
	-- distinguishes it. Labelling it as produce tells the player it comes off their animals
	-- rather than out of a field.
	if offer.contractType == "PRODUCT" then
		return string.format("%s — %s", ContractBoardFrame.describeContractType(offer),
				productName(offer.fillTypeIndex)),
			string.format("%s per year for %d years · %s",
				g_i18n:formatVolume(offer.quotaPerYear), offer.years, offer.client.name)
	end

	return string.format("%s — %s", productName(offer.fillTypeIndex),
			g_i18n:getText("fc_entry_offer")),
		string.format("%s per year for %d years · %s",
			g_i18n:formatVolume(offer.quotaPerYear), offer.years, offer.client.name)
end

function ContractBoardFrame:updateDetail()
	local entry = self:getSelectedEntry()

	if entry == nil then
		if self.detailTitle ~= nil then
			self.detailTitle:setText(g_i18n:getText("fc_detail_emptyTitle"))
		end
		if self.detailBody ~= nil then
			self.detailBody:setText(g_i18n:getText("fc_detail_emptyBody"))
		end
		self:setActionText(nil)
		return
	end

	local title, body, action = self:describeDetail(entry)

	if self.detailTitle ~= nil then
		self.detailTitle:setText(title)
	end
	if self.detailBody ~= nil then
		self.detailBody:setText(body)
	end

	self:setActionText(action)
end

--- How you stand with this client, in words rather than a hidden number.
---
--- Where to take it. A signed contract must answer this — reported from play 2026-08-01:
--- *"Agreed contract does not say where to deliver the eggs to. I cannot deliver the eggs
--- until I know where I need to take them."* Four stations on that map buy eggs.
---
--- **THIS IS NOT HAND-HOLDING AND THE LIVESTOCK PANEL ALREADY SETS THE PRECEDENT** — it says
--- "Sell qualifying animals through the dealer as normal". Telling the player the MECHANISM
--- of delivery is not assessing whether they can meet the terms; a contract you cannot fulfil
--- because you were never told where to take the goods is a broken contract, not a hard one.
---
--- States the rule first and the convenience second. Any buyer settles, because
--- `Settlement.onDelivery` pays the gap to the agreed rate wherever the sale happened — so
--- the named station only matters for anything sold OVER quota, which goes at market.
function ContractBoardFrame.describeDelivery(contract)
	local anyBuyer = "\nDeliver to any buyer that takes this product — the agreed rate is paid wherever you sell."

	if contract.suggestedStation == nil then
		return anyBuyer .. "\n"
	end

	return string.format("%s\nBest price when you signed: %s.\n",
		anyBuyer, contract.suggestedStation)
end

--- The coverage nudge, as its own paragraph, or nothing at all.
---
--- Nothing at all is the COMMON case and is deliberate — a contract the farm can comfortably
--- cover says nothing, because there is nothing the player needs prodding about.
---
--- Never add a number here, and never expand this into a sentence that explains itself.
--- See Offers.getCoverageHint for the ruling behind that; the vagueness is the mechanic.
function ContractBoardFrame.describeCoverage(offer)
	if offer.coverageHint == nil then
		return ""
	end

	return "\n\n" .. g_i18n:getText(offer.coverageHint)
end

--- Relationship is doing real work in the negotiation — it lifts their opening offer and
--- their ceiling and softens how hard they argue — so the player has to be able to see
--- that a familiar buyer is worth more than a stranger.
function ContractBoardFrame.describeStanding(client)
	if client == nil or client.id == 0 then
		return "You have not dealt with them before."
	end

	local relationship = client.relationship or 0

	-- Each standing is a COMPLETE SENTENCE, not a noun phrase slotted into "You are %s".
	-- That template produced "You are they trust you completely" as soon as one of the
	-- branches was written as a clause — reported from play 2026-07-28. Keeping every
	-- branch a whole sentence means a new one cannot break the grammar of the others.
	local standing
	if relationship >= 0.75 then
		standing = "They trust you completely."
	elseif relationship >= 0.5 then
		standing = "They treat you as a valued supplier."
	elseif relationship >= 0.25 then
		standing = "You are a known quantity to them."
	elseif relationship > 0 then
		standing = "They barely know you."
	else
		standing = "You are a stranger to them."
	end

	-- Relationship and delivery record are separate things and can disagree: a client can
	-- think well of you with no completed contracts (that is exactly what fcRelationship
	-- produces, and repeat offers can raise it before the first term ends). "No history
	-- with them yet" beside "they trust you completely" read as a bug, so the no-record
	-- wording no longer claims there is no relationship either.
	local history
	if client.completed == 0 and client.failed == 0 then
		if relationship > 0 then
			history = "No completed contracts with them yet."
		else
			history = "No history with them yet."
		end
	elseif client.failed == 0 then
		history = string.format("%d contract(s) completed for them.", client.completed)
	else
		history = string.format("%d completed, %d failed.", client.completed, client.failed)
	end

	return string.format("%s %s Better terms follow better history.", history, standing)
end

--- The genetic specification, in Realistic Livestock's own words.
---
--- Deliberately RL's vocabulary and not a parallel scale (HANDOFF §4.6) — a contract
--- asking for "Very high" reads identically to what the player sees in the RL menu, so
--- there is nothing to explain and nothing to convert.
function ContractBoardFrame:describeAnimalFloors(offer)
	local animals = ForwardContracts.animals

	if animals == nil then
		return "Genetic requirement unavailable."
	end

	-- A sample animal resolves the type-dependent trait names — Meat, and Milk vs Wool vs
	-- Eggs — so the requirement is phrased for the species the player actually keeps.
	return animals:describeSpec(offer)
end

--- How the rate multiplier is phrased, and it must never read as an addition.
---
--- The multiplier is the TOTAL the player ends up with per qualifying animal, not a bonus
--- paid alongside the dealer — Settlement books `(m - 1) * realised`, so 0.90x is a 10%
--- CLAWBACK off the dealer's price (Settlement.lua:185). An earlier wording said "on top of
--- what the dealer pays", which describes the opposite mechanic and made the entry rung read
--- as free money. Say the direction out loud instead of leaving the player to infer it from
--- a decimal.
function ContractBoardFrame.describeMultiplier(contract, includeLadder)
	local multiplier = contract.rateMultiplier or 1.0
	local rate = contract.rate or 0

	local percent = math.floor(math.abs(multiplier - 1.0) * 100 + 0.5)
	local money = g_i18n:formatMoney(rate, 0, true, true)
	local sentence

	-- The comparison is against a MINIMUM-SPEC animal, because that is what the price is
	-- anchored to. Saying "below market" without saying which animal would be meaningless —
	-- RL's genetics spread is nearly 4x, so there is no single market price for a cow.
	if percent == 0 then
		sentence = string.format(
			"Pays %s per head — what a minimum-spec animal is worth at the dealer.", money)
	elseif multiplier < 1.0 then
		sentence = string.format(
			"Pays %s per head — %d%% BELOW what a minimum-spec animal fetches at the dealer.",
			money, percent)
	else
		sentence = string.format(
			"Pays %s per head — %d%% ABOVE what a minimum-spec animal fetches at the dealer.",
			money, percent)
	end

	-- THE MOST IMPORTANT SENTENCE ON THE PANEL, and it must never be dropped. The price is
	-- flat, so delivering a prize animal is a straight loss against selling it — and a
	-- player who has not been told that will find out by losing money.
	sentence = sentence
		.. "\nThe price is fixed and the requirement is a MINIMUM. A better animal earns no"
		.. " more here, so meet the spec and sell your best elsewhere."

	if not includeLadder then
		return sentence
	end

	-- The pitch only. On a signed contract the player has already made this decision and
	-- does not need selling to.
	-- SAY WHAT THE PLAYER IS ACTUALLY BUYING. A below-market rate looks like a straight loss
	-- if the panel only ever names the discount, and the mod's own §4.3 says the opposite:
	-- the contract is a hedge, and certainty is the thing being sold. A farmer who trades a
	-- few percent of margin for years of guaranteed income and a name worth having has made
	-- a good deal, not a poor one.
	if multiplier < 1.0 then
		return sentence .. "\nNobody has heard of you yet, so you sell at a discount. This"
			.. " price is guaranteed for the whole term whatever the market does, and every"
			.. " year you meet gets your name mentioned — bigger, better-paid offers, and"
			.. " more of them in this breed."
	end

	return sentence .. "\nThis is what a known breeder commands. It was earned."
end

--- Breed, age window and genetics as one sentence, e.g.
--- "Angus, aged 24 to 28 months, minimum Very high in Metabolism, Health, Fertility and Meat."
function ContractBoardFrame.describeAnimalSpec(animals, spec, sample)
	local parts = {}

	if spec.subTypeName ~= nil then
		-- Prefer an animal of the named breed so the display name is resolved from the
		-- right subtype rather than whichever animal happened to be first.
		table.insert(parts, Animals.getBreedName(sample))
	end

	local age = Animals.describeAgeWindow(spec)
	if age ~= nil then
		table.insert(parts, age)
	end

	local floors = animals:describeFloors(spec.traitFloors, sample)
	if floors ~= nil and floors ~= "No genetic requirement." then
		table.insert(parts, (floors:gsub("%.$", "")))
	elseif #parts == 0 then
		return "Any animal from your herd."
	end

	return table.concat(parts, ", ") .. "."
end

--- Why this offer is a recommendation, stated but never explained.
---
--- **THIS MUST APPEAR ON ITS OWN, not folded into the herd line.** It was first written into
--- a branch of `describeAnimalStock` that only ran when the farm had animals AND did not keep
--- this species — so on a farm with no herd, or one already keeping the species, the label
--- said "recommendation" and nothing said why. Reported 2026-07-29.
---
--- It says THAT the farm is part-equipped and never WHAT the equipment is. Naming it would
--- turn the player's research into an instruction, which is precisely what the mod is not for.
function ContractBoardFrame.describeCrossover(offer)
	if offer.hasCrossover then
		return "Recommended: you already own equipment that covers some of what these animals eat."
	end

	return "A new opportunity: nothing you currently run goes toward feeding these."
end

--- How the farm's current herd measures up. "3 of 47 qualify" tells a breeder what the
--- contract is actually asking; a bare requirement does not.
function ContractBoardFrame:describeAnimalStock(offer)
	local animals = ForwardContracts.animals

	if animals == nil then
		return ""
	end

	local eligible, herdSize = animals:getEligible(offer.farmId, offer)

	-- A bottom-tier offer is deliberately reachable with no herd at all, so "you own none"
	-- is an invitation rather than an error. Say what it would take.
	if herdSize == 0 then
		return "You have no animals yet. This would mean building a husbandry and starting a line."
	end

	if #eligible == 0 then
		return string.format("Your herd: %d animals, none of which currently qualify.", herdSize)
	end

	return string.format("Your herd: %d of %d animals currently qualify.",
		#eligible, herdSize)
end

--- The panel title for a livestock record, naming WHICH KIND of contract it is.
---
--- SUPPLY, BREEDING and PRODUCT are genuinely different businesses (LIVESTOCK_DESIGN §2.4) —
--- breeding delivers at breeding age for quick money at low margin, supply at peak for slow
--- money at high margin — so calling them all "Livestock" hid the one distinction that decides
--- which a player should take.
---
--- Falls back to the plain label for contracts signed before the rebuild, which carry no type.
function ContractBoardFrame.describeContractType(record)
	local key = "fc_entry_livestock"

	if type(record) == "table" then
		if record.contractType == "BREEDING" then
			key = "fc_entry_livestockBreeding"
		elseif record.contractType == "PRODUCT" then
			key = "fc_entry_livestockProduct"
		elseif record.contractType == "SUPPLY" then
			key = "fc_entry_livestockSupply"
		end
	end

	return g_i18n:getText(key)
end

function ContractBoardFrame:describeDetail(entry)
	if entry.kind == ContractBoardFrame.ENTRY_CONTRACT then
		local contract = entry.contract
		local delivered = contract.quotaThisYear - contract.remainingLitres

		-- Livestock: head not litres, a genetic specification instead of a buyer, and no
		-- fill type to name.
		if contract.unit == ContractStore.UNIT_HEAD then
			local animals = ForwardContracts.animals
			local floors = "Genetic requirement unavailable."
			local stock = ""

			if animals ~= nil then
				local herd = animals:getAnimals(contract.farmId)
				floors = animals:describeSpec(contract)

				local eligible, herdSize = animals:getEligible(contract.farmId, contract)
				stock = string.format("\nYour herd: %d of %d animals currently qualify.",
					#eligible, herdSize)
			end

			return ContractBoardFrame.describeContractType(contract),
				string.format(
					"%s\nCompletion bonus: %s each year you meet the quota.\n\nRequirement: %s%s\n\nThis year: %d delivered of %d.\nTerm: year %d of %d.\nMissed years: %d of %d allowed.\n\nSell qualifying animals through the dealer as normal. Only animals clearing every floor count toward the quota — the rest are an ordinary sale, so a prize animal spent here is a prize animal not sold elsewhere.",
					ContractBoardFrame.describeMultiplier(contract, false),
					g_i18n:formatMoney(contract.completionBonus or 0, 0, true, true),
					floors, stock,
					delivered, contract.quotaThisYear,
					contract.yearIndex, contract.years,
					contract.consecutiveMisses, ContractStore.MAX_CONSECUTIVE_MISSES),
				nil
		end

		-- A spot order has a deadline, not an annual quota. Showing it the supply-contract
		-- text ("year 1 of 1", "missed years") reads as nonsense.
		if contract.kind == ContractStore.KIND_SPOT then
			return productName(contract.fillTypeIndex),
				string.format(
					"Urgent order at %s per litre.\n\nDelivered: %s of %s.\n\nTime remaining: %s.\n%s\nDeliver the full amount before the deadline or the order lapses and the client remembers it.",
					g_i18n:formatMoney(contract.rate, 3, true, true),
					g_i18n:formatVolume(delivered),
					g_i18n:formatVolume(contract.quotaThisYear),
					formatDeadline(contract.expiryDay),
					ContractBoardFrame.describeDelivery(contract)),
				nil
		end

		-- What the whole agreement is worth if it runs clean. Without this the board shows
		-- a rate and a quota and leaves you to do the multiplication yourself.
		local termValue = contract.rate * contract.quotaPerYear * contract.years
			+ contract.completionBonus * contract.years
		local remainingYears = math.max(contract.years - contract.yearIndex + 1, 0)
		local remainingValue = contract.rate * contract.remainingLitres
			+ contract.completionBonus * remainingYears

		return productName(contract.fillTypeIndex),
			string.format(
				"Agreed rate: %s per litre.\nCompletion bonus: %s per year.\n\nFull term value if every year is met: %s.\nStill to earn: %s.\n\nThis year: %s delivered of %s.\nTerm: year %d of %d.\nMissed years: %d of %d allowed.\n%s\nThe rate is fixed. When the market runs above it you are paying for the certainty; when it runs below, the contract is carrying you.",
				g_i18n:formatMoney(contract.rate, 3, true, true),
				g_i18n:formatMoney(contract.completionBonus, 0, true, true),
				g_i18n:formatMoney(termValue, 0, true, true),
				g_i18n:formatMoney(remainingValue, 0, true, true),
				g_i18n:formatVolume(delivered),
				g_i18n:formatVolume(contract.quotaThisYear),
				contract.yearIndex, contract.years,
				contract.consecutiveMisses, ContractStore.MAX_CONSECUTIVE_MISSES,
				ContractBoardFrame.describeDelivery(contract)),
			nil
	end

	local offer = entry.offer

	if entry.kind == ContractBoardFrame.ENTRY_SPOT_OFFER then
		return productName(offer.fillTypeIndex),
			string.format(
				"%s needs %s urgently.\n\nTime remaining: %s.\nPrice: %s per litre, %d%% above market.\nSuggested buyer: %s.\n\nFixed price, no negotiation. Take it or leave it.",
				offer.client.name,
				g_i18n:formatVolume(offer.quotaPerYear),
				formatDeadline(offer.expiryDay),
				g_i18n:formatMoney(offer.rate, 3, true, true),
				math.floor(offer.premium * 100 + 0.5),
				offer.suggestedStation or "—"),
			g_i18n:getText("fc_button_accept")
	end

	-- LIVESTOCK. Counted in HEAD, priced per head, and posted rather than negotiated — so it
	-- shares none of the crop wording below. Reconstructed 2026-07-30 after a scripted edit
	-- overwrote this branch with the product body; the panel read "wants 41 l of ?", the 41
	-- being a headcount run through formatVolume and the "?" a nil fill type.
	if offer.unit == ContractStore.UNIT_HEAD then
		return ContractBoardFrame.describeContractType(offer),
			string.format(
				"%s wants %d animals per year for %d years.\n\n%s\nCompletion bonus: %s each year you meet the quota.\nEverything included, that is roughly %s over the term.\n\nRequirement: %s\n%s\n\n%s\n\n%s\n\nFixed terms, no negotiation. Breeding better does not raise this contract — it raises the next one.",
				offer.client.name,
				offer.quotaPerYear,
				offer.years,

				-- The ladder line included: at an offer this is the player's first sight of why
				-- the rate sits where it does, and §0.6's framing rule says a below-market entry
				-- rung must never read as simply a bad deal.
				ContractBoardFrame.describeMultiplier(offer, true),

				g_i18n:formatMoney(offer.completionBonus or 0, 0, true, true),
				g_i18n:formatMoney(offer.marketValue, 0, true, true),

				-- The genetic specification, in RL's own words. Omitting this was BUG B on the
				-- first run: the contract enforced a band it never stated.
				self:describeAnimalFloors(offer),
				self:describeAnimalStock(offer),
				ContractBoardFrame.describeCrossover(offer),
				ContractBoardFrame.describeStanding(offer.client)),

			-- ACCEPT, not negotiate. Livestock is posted (§3.3) and `onActivateEntry` routes it
			-- to the posted-terms path, so a "negotiate" label here would promise a haggle the
			-- player never gets.
			g_i18n:getText("fc_button_accept")
	end

	-- PRODUCT. Mechanically the crop contract with a different fill type (§5.2) — same kind,
	-- same unit, same negotiation, same settlement — so it uses the crop body and differs only
	-- in naming the product and carrying the produce label.
	if offer.contractType == "PRODUCT" then
		return ContractBoardFrame.describeContractType(offer),
			string.format(
				"%s wants %s of %s per year for %d years.\n\nAt today's price that volume is worth %s over the term.\nSuggested buyer: %s.%s\n\n%s\n\nNegotiate the total, then decide how much of it you take as a guaranteed rate and how much as a completion bonus.",
				offer.client.name,
				g_i18n:formatVolume(offer.quotaPerYear),
				productName(offer.fillTypeIndex),
				offer.years,
				g_i18n:formatMoney(offer.marketValue, 0, true, true),
				offer.suggestedStation or "—",
				ContractBoardFrame.describeCoverage(offer),
				ContractBoardFrame.describeStanding(offer.client)),
			g_i18n:getText("fc_button_negotiate")
	end

	return productName(offer.fillTypeIndex),
		string.format(
			"%s wants %s per year for %d years.\n\nAt today's price that volume is worth %s over the term.\nSuggested buyer: %s.%s\n\n%s\n\nNegotiate the total, then decide how much of it you take as a guaranteed rate and how much as a completion bonus.",
			offer.client.name,
			g_i18n:formatVolume(offer.quotaPerYear),
			offer.years,
			g_i18n:formatMoney(offer.marketValue, 0, true, true),
			offer.suggestedStation or "—",
			ContractBoardFrame.describeCoverage(offer),
			ContractBoardFrame.describeStanding(offer.client)),
		g_i18n:getText("fc_button_negotiate")
end

function ContractBoardFrame:setActionText(text)
	if self.actionButtonInfo == nil then
		return
	end

	-- Drop the action button entirely when there is nothing to do, rather than showing an
	-- unlabelled one.
	if text == nil then
		self:setMenuButtonInfo({ self.backButtonInfo })
	else
		self.actionButtonInfo.text = text
		self:setMenuButtonInfo({ self.backButtonInfo, self.actionButtonInfo })
	end

	self:setMenuButtonInfoDirty()
end

-- ---------------------------------------------------------------------------
-- Actions
-- ---------------------------------------------------------------------------

function ContractBoardFrame:onActivateEntry()
	local entry = self:getSelectedEntry()
	if entry == nil or entry.kind == ContractBoardFrame.ENTRY_CONTRACT then
		return
	end

	local offers = ForwardContracts.offers
	if offers == nil then
		return
	end

	-- AT THE BUDGET, SAY SO. A signing button that quietly does nothing is worse than a refusal:
	-- the player concludes the mod is broken rather than that they are at their allowance, and
	-- §4.9 exists precisely because the ladder was invisible. The offer is deliberately LEFT ON
	-- THE BOARD — they may want to finish a contract and come back to it.
	local function refuseIfOverBudget(farmId)
		local reputation = 0
		if ForwardContracts.reputation ~= nil then
			reputation = ForwardContracts.reputation:getReputation(farmId) or 0
		end

		if offers:getRemainingBudget(farmId, reputation) > 0 then
			return false
		end

		InfoDialog.show(string.format(
			"You are already holding as many contracts as your reputation allows (%d).\n\n"
			.. "Finish or complete one to free a slot, or raise your reputation — the next tier "
			.. "allows more.\n\nSpot orders do not count against this.",
			offers:getContractBudget(reputation)))
		return true
	end

	if entry.kind == ContractBoardFrame.ENTRY_ANIMAL_OFFER then
		local offer = entry.offer

		if refuseIfOverBudget(offer.farmId) then
			return
		end

		offers:acceptAnimalOffer(offer)
		self:rebuild()

		InfoDialog.show(string.format(
			"Contract signed with %s.\n\n%d animals per year for %d years.\n%s\nCompletion bonus: %s each year you meet the quota.\n\nRequirement: %s",
			offer.client.name, offer.quotaPerYear, offer.years,
			ContractBoardFrame.describeMultiplier(offer, false),
			g_i18n:formatMoney(offer.completionBonus or 0, 0, true, true),
			self:describeAnimalFloors(offer)))
		return
	end

	if entry.kind == ContractBoardFrame.ENTRY_SPOT_OFFER then
		local offer = entry.offer
		offers:acceptSpotOffer(offer)
		self:rebuild()

		InfoDialog.show(string.format(
			"Order accepted.\n\n%s of %s at %s per litre.\nTime remaining: %s.",
			g_i18n:formatVolume(offer.quotaPerYear),
			productName(offer.fillTypeIndex),
			g_i18n:formatMoney(offer.rate, 3, true, true),
			formatDeadline(offer.expiryDay)))
		return
	end

	local offer = entry.offer

	-- Checked BEFORE the negotiation opens, not after it succeeds. Letting someone haggle a deal
	-- and then refusing to sign it would be the most annoying possible ordering.
	if refuseIfOverBudget(offer.farmId) then
		return
	end

	-- Signing silently made a successful negotiation look like the dialog had simply
	-- closed. Always say what happened, and on what terms.
	NegotiationDialog.show(offer, function(result)
		if result.signed then
			local contract, terms = offers:acceptSupplyOffer(offer, result.agreedValue, result.mix)
			self:rebuild()

			-- The budget can have been spent between opening the dialog and signing it — the
			-- negotiation is modal but the world is not. Offers.acceptSupplyOffer re-checks and
			-- returns nil, and this is what makes that refusal visible.
			if contract == nil or terms == nil then
				refuseIfOverBudget(offer.farmId)
				return
			end

			InfoDialog.show(string.format(
				"Contract signed with %s.\n\n%s per year for %d years.\nRate: %s per litre.\nCompletion bonus: %s each year you meet quota.\n\nFull term if every year is met: %s.",
				offer.client.name,
				g_i18n:formatVolume(offer.quotaPerYear),
				offer.years,
				g_i18n:formatMoney(terms.rate, 3, true, true),
				g_i18n:formatMoney(terms.completionBonus, 0, true, true),
				g_i18n:formatMoney(terms.totalValue, 0, true, true)))
			return
		end

		offers:abandonOffer(offer, result.pushedTooHard, result.badFaith)
		self:rebuild()

		if result.badFaith then
			InfoDialog.show(string.format(
				"%s walked away.\n\nThey moved and you did not. Repeating your number after a concession is not negotiating, and they will not bid against themselves.\n\nThis will be remembered.",
				offer.client.name))
		elseif result.pushedTooHard then
			InfoDialog.show(string.format(
				"%s walked away.\n\nYou pushed for more than they were ever going to pay, and the offer is gone. Word gets round.",
				offer.client.name))
		else
			InfoDialog.show(string.format(
				"No deal with %s.\n\nThe offer is off the table.",
				offer.client.name))
		end
	end)
end
