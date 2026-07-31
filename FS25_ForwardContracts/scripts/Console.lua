-- Forward Contracts — Console
--
-- Test commands. The reputation and relationship curves are designed to take many in-game
-- years to climb, which is right for play and useless for testing, so these exist to jump
-- the system to a state worth looking at.
--
-- Everything here goes through the SAME public methods the game uses. Nothing pokes at
-- internal state directly — a test command that bypasses the real code path proves the
-- test command works, not the mod.
--
-- All commands are prefixed `fc` to avoid colliding with other mods' console commands.

Console = {}

local Console_mt = Class(Console)

Console.COMMANDS = {
	{ name = "fcStatus", desc = "List contracts, offers, clients and reputation", fn = "consoleStatus" },
	{ name = "fcComplete", desc = "Complete a contract's current year in full [index]", fn = "consoleComplete" },
	{ name = "fcRegenerate", desc = "Clear the board and generate fresh offers", fn = "consoleRegenerate" },
	{ name = "fcReputation", desc = "Change reputation by an amount, e.g. 0.2 or -0.1 [value]", fn = "consoleReputation" },
	{ name = "fcRelationship", desc = "Change a client's relationship [name or id] [value]", fn = "consoleRelationship" },
	{ name = "fcAnimals", desc = "List this farm's animals with their genetic bands", fn = "consoleAnimals" },
	{ name = "fcFood", desc = "Show each species' food groups, effort rating and contract scale", fn = "consoleFood" },
	{ name = "fcOffer", desc = "Force an offer: [supply|breeding|product] [species or fillType] [client] [tier]", fn = "consoleOffer" },
	{ name = "fcFeed", desc = "Show what this farm has fed and the equipment it proves. 'clear' wipes it", fn = "consoleFeed" },
	{ name = "fcSellable", desc = "List every fill type the board may contract, with its rate and best buyer [filter]", fn = "consoleSellable" },
	{ name = "fcWood", desc = "Log every wood delivery's species, litres and realised rate. 'off' stops it", fn = "consoleWood" },
}

function Console.new(mod)
	local self = setmetatable({}, Console_mt)

	self.mod = mod

	return self
end

function Console:register()
	for _, command in ipairs(Console.COMMANDS) do
		addConsoleCommand(command.name, command.desc, command.fn, self)
	end
end

function Console:unregister()
	for _, command in ipairs(Console.COMMANDS) do
		removeConsoleCommand(command.name)
	end
end

local function farmId()
	return g_currentMission:getFarmId()
end

--- What this contract or offer is for, in one word.
---
--- Livestock has no fill type — getFillTypeNameByIndex(nil) returns nil safely
--- (FillTypeManager.lua:303-305), so this is about readability rather than crash safety:
--- a herd contract printing "?" tells the tester nothing.
local function productLabel(entry)
	if entry.unit == ContractStore.UNIT_HEAD then
		return "livestock"
	end

	return g_fillTypeManager:getFillTypeNameByIndex(entry.fillTypeIndex) or "?"
end

-- ---------------------------------------------------------------------------
-- fcStatus
-- ---------------------------------------------------------------------------

function Console:consoleStatus()
	local mod = self.mod
	local lines = {}

	local reputation = mod.reputation:getReputation(farmId())
	table.insert(lines, string.format("Reputation: %.3f", reputation))

	table.insert(lines, "-- Contracts --")
	local contracts = mod.contractStore:getContracts(farmId())
	if #contracts == 0 then
		table.insert(lines, "  (none)")
	end
	for index, contract in ipairs(contracts) do
		local fillTypeName = productLabel(contract)
		table.insert(lines, string.format(
			"  [%d] %s %s | rate %.3f | bonus %.0f | %.0f of %.0f this year | year %d/%d | client %d",
			index, contract.kind, fillTypeName or "?", contract.rate, contract.completionBonus,
			contract.quotaThisYear - contract.remainingLitres, contract.quotaThisYear,
			contract.yearIndex, contract.years, contract.clientId or 0))
	end

	table.insert(lines, "-- Offers --")
	local offers = mod.offers:getOffers(farmId())
	if #offers == 0 then
		table.insert(lines, "  (none)")
	end
	for index, offer in ipairs(offers) do
		-- Livestock quotas are head, so formatVolume would render "8 l" for eight cows.
		local amount = offer.unit == ContractStore.UNIT_HEAD
			and string.format("%d animals", offer.quotaPerYear)
			or g_i18n:formatVolume(offer.quotaPerYear)

		table.insert(lines, string.format("  [%d] %s %s | %s | client %s",
			index, offer.kind, productLabel(offer), amount, offer.client.name))
	end

	table.insert(lines, "-- Clients --")
	if #mod.clientRegistry.clients == 0 then
		table.insert(lines, "  (none)")
	end
	for _, client in ipairs(mod.clientRegistry.clients) do
		table.insert(lines, string.format(
			"  id %d | %s | relationship %.3f | size %.2f | %d completed, %d failed",
			client.id, client.name, client.relationship, client.size,
			client.completed, client.failed))
	end

	return table.concat(lines, "\n")
end

-- ---------------------------------------------------------------------------
-- fcComplete
-- ---------------------------------------------------------------------------

--- Fill a contract's outstanding quota and settle it, exactly as delivering would.
---
--- Pays the agreed rate for the litres, then runs the same year-end settlement the
--- calendar would — so the completion bonus, reputation and relationship all move through
--- their normal paths.
function Console:consoleComplete(indexArg)
	local mod = self.mod
	local contracts = mod.contractStore:getContracts(farmId())

	if #contracts == 0 then
		return "No active contracts."
	end

	local index = tonumber(indexArg) or 1
	local contract = contracts[index]

	if contract == nil then
		return string.format("No contract at index %d. Run fcStatus to list them.", index)
	end

	local litres = contract.remainingLitres or 0
	local money = litres * contract.rate

	if litres > 0 then
		g_currentMission:addMoney(money, contract.farmId,
			mod.contractStore.moneyTypeBonus, true, true)
		mod.contractStore:recordDelivery(contract, litres, money)
	end

	local fillTypeName = productLabel(contract)

	-- Spot orders finish inside recordDelivery. Supply contracts settle at the year end,
	-- so trigger that here rather than duplicating the logic.
	if contract.kind ~= ContractStore.KIND_SPOT then
		mod.contractStore:settleContractYear(contract)
		mod.contractStore:pruneCompleted()
	end

	local amount = contract.unit == ContractStore.UNIT_HEAD
		and string.format("%d animals", litres)
		or g_i18n:formatVolume(litres)

	return string.format(
		"Completed %s %s: %s delivered for %s. Reputation now %.3f.",
		contract.kind, fillTypeName or "?", amount,
		g_i18n:formatMoney(money, 0, true, true),
		mod.reputation:getReputation(farmId()))
end

-- ---------------------------------------------------------------------------
-- fcRegenerate
-- ---------------------------------------------------------------------------

function Console:consoleRegenerate()
	local mod = self.mod

	for index = #mod.offers.offers, 1, -1 do
		if mod.offers.offers[index].farmId == farmId() then
			table.remove(mod.offers.offers, index)
		end
	end

	-- Prices move daily and the cache is keyed to that, so drop it too.
	mod.offers.sellableCache = nil
	mod.offers:refresh(farmId())

	return string.format("Board regenerated: %d offer(s).", #mod.offers:getOffers(farmId()))
end

-- ---------------------------------------------------------------------------
-- fcReputation
-- ---------------------------------------------------------------------------

function Console:consoleReputation(valueArg)
	local delta = tonumber(valueArg)

	if delta == nil then
		return "Usage: fcReputation <amount>   e.g. fcReputation 0.25 or fcReputation -0.1"
	end

	local mod = self.mod
	mod.reputation:adjust(farmId(), delta)

	local now = mod.reputation:getReputation(farmId())

	return string.format("Reputation %+.3f -> %.3f (%s)", delta, now,
		ContractBoardFrame.getReputationStage(now).label)
end

-- ---------------------------------------------------------------------------
-- fcRelationship
-- ---------------------------------------------------------------------------

--- Client names contain spaces and the console splits every argument on them, so
--- `fcRelationship Whitmoor Produce 1` arrives as three arguments, not two. Taking only
--- the first two saw the name "Whitmoor" and the amount "Produce" and rejected it —
--- reported from play 2026-07-28. Requiring the player to know to type a single-word
--- fragment is a worse answer than accepting what they naturally typed.
---
--- So: the LAST argument is the amount, and everything before it is re-joined with spaces
--- into the name fragment. Both of these now work, and so does the full name:
---   fcRelationship Kirkby 0.3
---   fcRelationship Whitmoor Produce 1
function Console:consoleRelationship(...)
	local mod = self.mod
	local args = { ... }
	local usage = "Usage: fcRelationship <name fragment or id> <amount>"
		.. "   e.g. fcRelationship Whitmoor Produce 1"

	if #args < 2 then
		return usage
	end

	-- Pop the amount off the end first, so the remainder is unambiguously the name.
	local delta = tonumber(args[#args])
	if delta == nil then
		return string.format("Last argument must be the amount, e.g. 0.3 or -0.2 (got %q).\n%s",
			tostring(args[#args]), usage)
	end
	table.remove(args)

	local nameArg = table.concat(args, " ")

	local client = nil
	local asId = tonumber(nameArg)

	if asId ~= nil then
		client = mod.clientRegistry:getClientById(asId)
	else
		local needle = string.lower(nameArg)
		for _, candidate in ipairs(mod.clientRegistry.clients) do
			if string.find(string.lower(candidate.name), needle, 1, true) ~= nil then
				client = candidate
				break
			end
		end
	end

	if client == nil then
		return string.format("No client matching %q. Run fcStatus to list them.", tostring(nameArg))
	end

	mod.clientRegistry:adjustRelationship(client.id, delta)

	return string.format("%s relationship %+.3f -> %.3f",
		client.name, delta, client.relationship)
end

-- ---------------------------------------------------------------------------
-- fcAnimals
-- ---------------------------------------------------------------------------

--- Lists the farm's herd with each trait's raw value and RL's own band name, plus whether
--- each animal would satisfy the active livestock contract.
---
--- The genetic ladder is designed to take many in-game years to climb, which is right for
--- play and useless for testing. This shows the state the contract is actually judging, so
--- a floor that never seems to be met can be diagnosed rather than guessed at.
--- Force a livestock offer with the species, client and tier pinned.
---
--- A CONTROLLED-EXPERIMENT TOOL. Testing a branch against a different species and client
--- each run measures the generator's variance rather than the branch under test — the user's
--- point, 2026-07-29, and the reason this exists. Everything not pinned still derives
--- normally, so what appears is a real offer and not a fabricated one.
---
--- Tier is worth pinning too: it reaches rungs that would otherwise need a long reputation
--- climb, so the top of the ladder can be tested without grinding to it.
--- `fcOffer product [fillType] [client] [tier 1-4]`.
---
--- Split from `consoleOffer` rather than branching inside it, because almost nothing is shared:
--- the first argument is a fill type, the tier table is the CROP one (four rungs, not five), and
--- the result is negotiated rather than posted.
function Console:consoleProductOffer(farm, fillArg, clientArg, tierArg)
	local mod = self.mod
	local overrides = {}

	-- Which product. Matched on the fill type's own name first, then its localised title, so
	-- both "MILK" and "Milk" work. Only ANIMAL products are listed — a product contract is for
	-- something a herd makes, and offering to force a FABRIC contract here would be a lie about
	-- what this command does.
	local products = Animals.getAllProductFillTypes()

	if fillArg ~= nil and fillArg ~= "" then
		local wanted = tostring(fillArg):upper()
		local match, names = nil, {}

		for fillTypeIndex in pairs(products) do
			local name = tostring(g_fillTypeManager:getFillTypeNameByIndex(fillTypeIndex) or ""):upper()
			local title = tostring(g_fillTypeManager:getFillTypeTitleByIndex(fillTypeIndex) or ""):upper()

			table.insert(names, name)

			if name == wanted or title == wanted
				or name:find(wanted, 1, true) or title:find(wanted, 1, true) then
				match = match or fillTypeIndex
			end
		end

		if match == nil then
			table.sort(names)
			return string.format("No animal product matching '%s'.\nAvailable: %s",
				tostring(fillArg), table.concat(names, ", "))
		end

		overrides.fillTypeIndex = match
	end

	if clientArg ~= nil and clientArg ~= "" and mod.clientRegistry ~= nil then
		local byId = tonumber(clientArg)
		local match = nil

		if byId ~= nil then
			match = mod.clientRegistry:getClientById(byId)
		else
			local wanted = tostring(clientArg):lower()
			for _, client in ipairs(mod.clientRegistry.clients) do
				if string.find(string.lower(client.name), wanted, 1, true) ~= nil then
					match = match or client
				end
			end
		end

		if match == nil then
			return string.format("No client matching %q. Run fcStatus to list them.",
				tostring(clientArg))
		end

		overrides.clientId = match.id
	end

	local tier = tonumber(tierArg)
	if tier ~= nil then
		if Offers.TIERS[tier] == nil then
			return string.format("Product tier must be 1-%d.", #Offers.TIERS)
		end
		overrides.tier = tier
	end

	local reputation = 0
	if mod.reputation ~= nil then
		reputation = mod.reputation:getReputation(farm) or 0
	end

	local offer = mod.offers:forceProductOffer(farm, reputation, overrides)

	if offer == nil then
		return "Could not create a product offer — no station on this map buys an animal product."
	end

	return string.format(
		"Forced offer: PRODUCT %s, %s per year for %d years.\nWorth about %s over the term at today's price.\nSuggested buyer: %s.\nClient: %s.",
		g_fillTypeManager:getFillTypeTitleByIndex(offer.fillTypeIndex) or "?",
		g_i18n:formatVolume(offer.quotaPerYear),
		offer.years,
		g_i18n:formatMoney(offer.marketValue, 0, true, true),
		offer.suggestedStation or "—",
		offer.client ~= nil and offer.client.name or "?")
end

--- Contract types `fcOffer` will accept, in the words a tester would actually type.
Console.OFFER_TYPES = {
	supply = "SUPPLY",
	breeding = "BREEDING",
	product = "PRODUCT",
	meat = "SUPPLY",
	breed = "BREEDING",
}

function Console:consoleOffer(a, b, c, d)
	local mod = self.mod

	if mod.offers == nil or mod.animals == nil then
		return "Offers or Animals module not active."
	end

	local farm = farmId()
	local overrides = { force = true }

	-- THE TYPE IS RECOGNISED IN ANY POSITION, not fixed as a fourth argument.
	--
	-- The common call is `fcOffer breeding` on its own — a tester wanting the BREEDING path
	-- rarely cares which species or client it lands on. Making them type `fcOffer - - - breeding`
	-- to get there would be the sort of friction that stops a path being tested at all, which is
	-- exactly how BREEDING went unexercised in the first place. Species, client and tier are all
	-- distinguishable from a type keyword, so scanning for it costs nothing.
	local positional = {}

	for _, arg in ipairs({ a, b, c, d }) do
		local text = arg ~= nil and tostring(arg) or ""
		local asType = Console.OFFER_TYPES[text:lower()]

		if asType ~= nil then
			overrides.contractType = asType
		elseif text ~= "" then
			table.insert(positional, text)
		end
	end

	local speciesArg, clientArg, tierArg = positional[1], positional[2], positional[3]

	-- Tier may be given anywhere among the remaining arguments too, since it is the only
	-- purely numeric one.
	for i, text in ipairs(positional) do
		if tonumber(text) ~= nil and i > 1 then
			tierArg = text
			table.remove(positional, i)
			speciesArg, clientArg = positional[1], positional[2]
			break
		end
	end

	-- PRODUCT TAKES A DIFFERENT ROUTE ENTIRELY, and its first argument is a FILL TYPE rather
	-- than a species. A product contract names no animal, states no genetics and is negotiated
	-- rather than posted, so it shares nothing with the livestock generator — feeding "MILK" to
	-- the species matcher below would only ever report "no breedable species matching 'MILK'".
	if overrides.contractType == Offers.KIND_ANIMAL_PRODUCT then
		return self:consoleProductOffer(farm, speciesArg, clientArg, tierArg)
	end

	-- Species. Matched against the subtype's own name first, then its display name, so both
	-- "CHICKEN" and "Landrace of Bentheim" work.
	if speciesArg ~= nil and speciesArg ~= "" then
		local wanted = tostring(speciesArg):upper()
		local match, names = nil, {}

		-- BOTH POOLS, so males and job animals are findable. `getBreedableSubTypes` filters on
		-- `supportsReproduction`, which RL sets FALSE on every male subtype — so a tester could
		-- not pin BULL_ANGUS or STALLION_GRAY by name even though supply contracts name them.
		local searchable = {}

		for _, kind in ipairs({ Offers.KIND_ANIMAL_SUPPLY, Offers.KIND_ANIMAL_BREEDING }) do
			for _, subType in ipairs(mod.animals:getContractableSubTypes(kind)) do
				searchable[subType.name] = subType
			end
		end

		for _, subType in pairs(searchable) do
			local name = tostring(subType.name or ""):upper()
			local display = tostring(Animals.getSubTypeBreedName(subType) or ""):upper()

			table.insert(names, subType.name or "?")

			if name == wanted or display == wanted
				or name:find(wanted, 1, true) or display:find(wanted, 1, true) then
				match = match or subType
			end
		end

		if match == nil then
			return string.format("No breedable species matching '%s'.\nAvailable: %s",
				tostring(speciesArg), table.concat(names, ", "))
		end

		overrides.subTypeName = match.name
	end

	-- Client, by id or by a case-insensitive fragment of the name.
	if clientArg ~= nil and clientArg ~= "" and mod.clientRegistry ~= nil then
		local byId = tonumber(clientArg)
		local match = nil

		if byId ~= nil then
			match = mod.clientRegistry:getClientById(byId)
		else
			local wanted = tostring(clientArg):lower()
			for _, client in ipairs(mod.clientRegistry.clients) do
				if string.find(string.lower(client.name), wanted, 1, true) ~= nil then
					match = match or client
				end
			end
		end

		if match == nil then
			return string.format("No client matching %q. Run fcStatus to list them.",
				tostring(clientArg))
		end

		overrides.clientId = match.id
	end

	local tier = tonumber(tierArg)
	if tier ~= nil then
		if Offers.ANIMAL_TIERS[tier] == nil then
			return string.format("Tier must be 1-%d.", #Offers.ANIMAL_TIERS)
		end
		overrides.tier = tier
	end

	local reputation = 0
	if mod.reputation ~= nil then
		reputation = mod.reputation:getReputation(farm) or 0
	end

	local offer = mod.offers:createAnimalOffer(farm, reputation, overrides)

	if offer == nil then
		return "Could not create an offer — no admissible species, or Animals is not wired in."
	end

	-- A forced species and a forced type can disagree — asking for a BREEDING contract on a beef
	-- cow, say. That is ALLOWED, because the point of pinning is to exercise a path, but it must
	-- be said out loud: a breeding spec on an animal with no `productivity` trait is trivially
	-- satisfiable (missing data passes, by design), so a test built on one proves nothing.
	local warning = ""
	local subType = Animals.getSubTypeByName(offer.subTypeName)
	local natural = subType ~= nil and Offers.getAnimalContractKind(subType) or nil

	if offer.contractType ~= nil and natural ~= nil and offer.contractType ~= natural then
		warning = string.format(
			"\nWARNING: %s is naturally a %s animal, forced to %s. Expect a spec it cannot express.",
			offer.subTypeName, natural, offer.contractType)
	end

	return string.format(
		"Forced offer: %s %s, %d head/year for %d years, %s per head (%.3fx), bonus %s.\nClient: %s.\nRequirement: %s%s",
		offer.contractType or "?",
		Animals.getSubTypeBreedName(subType),
		offer.quotaPerYear, offer.years,
		g_i18n:formatMoney(offer.rate, 2, true, true),
		offer.rateMultiplier or 1.0,
		g_i18n:formatMoney(offer.completionBonus or 0, 0, true, true),
		offer.client ~= nil and offer.client.name or "?",
		mod.animals:describeSpec(offer),
		warning)
end

--- Show the feed ledger, the equipment it proves, and what that makes reachable.
---
--- `fcFeed clear` wipes it. **The ledger is cumulative and persists**, which is right for
--- play and wrong for experiments: feeding wheat and then sorghum proves a seeder AND a
--- planter, so a test meant to isolate one would silently measure both.
function Console:consoleFeed(arg)
	local mod = self.mod

	if mod.feedLedger == nil then
		return "Feed ledger not active."
	end

	local farm = farmId()

	if arg ~= nil and tostring(arg):lower() == "clear" then
		mod.feedLedger.byFarm[farm] = nil
		return "Feed ledger cleared for this farm. Equipment must be re-proven by feeding."
	end

	local fed = mod.feedLedger.byFarm[farm] or {}
	local lines = { "Fed by this farm:" }
	local any = false

	for name, litres in pairs(fed) do
		local index = g_fillTypeManager:getFillTypeIndexByName(name)
		local title = index ~= nil and g_fillTypeManager:getFillTypeTitleByIndex(index) or name
		table.insert(lines, string.format("  %s — %s l", tostring(title), g_i18n:formatNumber(litres, 0)))
		any = true
	end

	if not any then
		table.insert(lines, "  (nothing yet — feed something to prove equipment)")
	end

	local proven = Animals.getProvenEquipment(mod.feedLedger:getFedFillTypes(farm))
	local owned = {}

	for name in pairs(proven) do
		table.insert(owned, name)
	end

	table.sort(owned)
	table.insert(lines, "Equipment proven: "
		.. (#owned > 0 and table.concat(owned, ", ") or "none"))

	-- What each species would score, which is the number the recommendation actually uses.
	if mod.animals ~= nil then
		table.insert(lines, "Crossover by species (ledger only, herd excluded):")

		local seen = {}
		for _, subType in ipairs(mod.animals:getBreedableSubTypes()) do
			if subType.typeIndex ~= nil and not seen[subType.typeIndex] then
				seen[subType.typeIndex] = true

				local system = g_currentMission.animalSystem
				local typeName = system ~= nil and system.typeIndexToName ~= nil
					and system.typeIndexToName[subType.typeIndex] or "?"

				-- Yes/no, not a percentage: the mod does not grade crossover, it only
				-- notices whether there is one (see Animals.hasFeedCrossover).
				table.insert(lines, string.format("  %s: %s",
					tostring(typeName),
					Animals.hasFeedCrossover(subType, {}, farm)
						and "foot in the door" or "nothing in common"))
			end
		end
	end

	return table.concat(lines, "\n")
end

--- Prints the live food data behind `Animals.getHusbandryEffort`.
---
--- Exists because `animalFood.xml` sits inside encrypted `dataS` and cannot be read off
--- disk, so the group counts the effort rating is calibrated against are ASSUMPTIONS until
--- this is run. Expected on RL: chicken 1 group, sheep 2 serial, cow 3 serial, pig 4
--- parallel. If the real numbers differ, the calibration in Animals.getHusbandryEffort is
--- what needs correcting, not the ranking it was built to reproduce.
function Console:consoleFood()
	local mod = self.mod

	if mod.animals == nil then
		return "Animals module not active."
	end

	local system = g_currentMission ~= nil and g_currentMission.animalSystem or nil
	local foodSystem = g_currentMission ~= nil and g_currentMission.animalFoodSystem or nil

	if system == nil or foodSystem == nil then
		return "Animal or food system unavailable."
	end

	local lines = { "Species, food chain and contract scale:" }
	local seen = {}

	for _, subType in ipairs(mod.animals:getBreedableSubTypes()) do
		local typeIndex = subType.typeIndex

		if typeIndex ~= nil and not seen[typeIndex] then
			seen[typeIndex] = true

			local typeName = system.typeIndexToName ~= nil
				and system.typeIndexToName[typeIndex] or ("type " .. tostring(typeIndex))

			local groupCount, consumption = 0, "?"
			local ok, food = pcall(foodSystem.getAnimalFood, foodSystem, typeIndex)

			if ok and type(food) == "table" and type(food.groups) == "table" then
				groupCount = #food.groups
				consumption = food.consumptionType == AnimalFoodSystem.FOOD_CONSUME_TYPE_PARALLEL
					and "PARALLEL (needs every group at once)"
					or "serial (any one group will do)"
			end

			table.insert(lines, string.format(
				"  %s: %d food group(s), %s", tostring(typeName), groupCount, consumption))

			-- The fill types are the actual crops the player must grow, which is the thing
			-- the effort rating is really measuring.
			if ok and type(food) == "table" and type(food.groups) == "table" then
				for _, group in ipairs(food.groups) do
					local names = {}

					for _, fillTypeIndex in pairs(group.fillTypes or {}) do
						local title = g_fillTypeManager:getFillTypeTitleByIndex(fillTypeIndex)
						table.insert(names, title or "?")
					end

					-- `productionWeight` IS the effectiveness scale the player sees in the
					-- husbandry panel — PlaceableHusbandryFood renders it as a percentage
					-- (PlaceableHusbandryFood.lua:311), and AnimalFoodSystem normalises the
					-- group weights to sum to 1 (:88-98). `eatWeight` is the share of the
					-- ration a PARALLEL species takes from this group.
					table.insert(lines, string.format("      - %s: %d%% production, %d%% of ration | %s",
						tostring(group.title),
						math.floor((group.productionWeight or 0) * 100 + 0.5),
						math.floor((group.eatWeight or 0) * 100 + 0.5),
						table.concat(names, ", ")))
				end
			end

			table.insert(lines, string.format(
				"    effort %.2f, %.1f offspring per female per year",
				Animals.getHusbandryEffort(subType),
				Animals.getAnnualOffspringPerFemale(subType)))
		end
	end

	return table.concat(lines, "\n")
end

function Console:consoleAnimals()
	local mod = self.mod

	if mod.animals == nil then
		return "Animals module not active."
	end

	local farm = farmId()
	local herd = mod.animals:getAnimals(farm)

	if #herd == 0 then
		return "No animals on this farm. Livestock offers need a herd to price against."
	end

	local contract = mod.contractStore ~= nil
		and mod.contractStore:getActiveHeadContract(farm) or nil

	local lines = {}

	if contract ~= nil then
		table.insert(lines, string.format("Active livestock contract: %d of %d this year. %s",
			contract.quotaThisYear - contract.remainingLitres, contract.quotaThisYear,
			mod.animals:describeSpec(contract)))
	else
		table.insert(lines, "No active livestock contract — showing bands only.")
	end

	local qualifying = 0

	for _, entry in ipairs(herd) do
		local animal = entry.animal
		local genetics = animal.genetics or {}
		local parts = {}

		for _, trait in ipairs(Animals.TRAITS) do
			local value = genetics[trait]
			if value ~= nil then
				local band = Animals.getBand(value, trait)
				table.insert(parts, string.format("%s %.2f (%s)",
					Animals.getTraitLabel(animal, trait), value, Animals.getBandName(band)))
			end
		end

		local ok, failingTrait = mod.animals:meetsSpec(animal, contract)
		if ok then
			qualifying = qualifying + 1
		end

		-- Condition, health and sale value are printed for CALIBRATION as much as diagnosis.
		-- The condition floors in Offers.ANIMAL_TIERS were set without ever having seen RL's
		-- weightFactor in play, and the poor-to-prize value spread is what every livestock
		-- balance constant rests on. Both are read off this line.
		local condition = Animals.getConditionFactor(animal)
		local health = nil

		if animal.getHealthFactor ~= nil then
			local okHealth, factor = pcall(animal.getHealthFactor, animal)
			if okHealth then
				health = factor
			end
		end

		local value = nil
		if animal.getSellPrice ~= nil then
			local okPrice, price = pcall(animal.getSellPrice, animal)
			if okPrice then
				value = price
			end
		end

		table.insert(lines, string.format("  %s %s %s %smo | cond %s, health %s, worth %s | %s%s",
			ok and "[OK]" or "[ - ]",
			Animals.getEarTag(animal),
			Animals.getBreedName(animal),
			tostring(Animals.getAgeMonths(animal) or "?"),
			condition ~= nil and string.format("%.2f", condition) or "?",
			health ~= nil and string.format("%.2f", health) or "?",
			value ~= nil and g_i18n:formatMoney(value, 0, true, true) or "?",
			table.concat(parts, ", "),
			failingTrait ~= nil and (" | fails on " .. failingTrait) or ""))
	end

	table.insert(lines, string.format("%d of %d animals qualify.", qualifying, #herd))

	return table.concat(lines, "\n")
end

--- `fcSellable [filter]` — every fill type `Offers:getSellableFillTypes` will contract, with
--- the rate a delivery REALISES and the best-paying buyer.
---
--- **Written because a play session was spent on a question this answers in a keystroke.** On
--- 2026-08-01 the user was asked to run `fcOffer supply WOOD` to find out whether wood reaches
--- the board. It could never have worked: `Console.OFFER_TYPES.supply` maps to the LIVESTOCK
--- contract type, so that command asked for an animal contract for a species called WOOD and
--- silently did nothing. `fcOffer` has no way to force a crop offer, for any fill type.
---
--- The board picks ONE candidate at random from this pool per slot, so "I have never seen a
--- wheat contract" and "wheat is not contractable" look identical from the outside. This tells
--- them apart, and it does it for every fill type at once rather than one guess at a time.
---
--- Reads the live cache path, so it reflects exactly what the generator would see — including
--- the train-only and owned-production-point exclusions. Not a re-derivation.
function Console:consoleSellable(filterArg)
	local mod = self.mod

	if mod.offers == nil then
		return "Offers module not active."
	end

	local sellable = mod.offers:getSellableFillTypes()
	local filter = filterArg ~= nil and filterArg ~= "" and tostring(filterArg):upper() or nil

	local rows = {}

	for fillTypeIndex, entry in pairs(sellable) do
		local name = tostring(g_fillTypeManager:getFillTypeNameByIndex(fillTypeIndex) or "?")
		local title = tostring(g_fillTypeManager:getFillTypeTitleByIndex(fillTypeIndex) or name)

		if filter == nil or name:find(filter, 1, true) or title:upper():find(filter, 1, true) then
			table.insert(rows, {
				name = name,
				title = title,
				rate = entry.marketRate or 0,
				station = entry.stationName or "—",
			})
		end
	end

	if #rows == 0 then
		return filter ~= nil
			and string.format("Nothing contractable matching '%s'. Run fcSellable with no "
				.. "argument to list everything.", tostring(filterArg))
			or "Nothing on this map is contractable. That is almost certainly a fault."
	end

	-- Dearest first: the expensive end is where a money-first quota gets small, which is where
	-- a wrong rate shows up soonest.
	table.sort(rows, function(a, b) return a.rate > b.rate end)

	local lines = { string.format("%d contractable fill types (dearest first):", #rows) }

	for _, row in ipairs(rows) do
		-- WOOD's rate is deliberately NOT its listed price (Offers.WOOD_BEST_RATE_SCALE), and a
		-- reader comparing this against the in-game price board would otherwise report a bug.
		-- The BASE price is shown, not just the multiplier, because the rate came out at 0.365
		-- rather than the expected 0.367 on the user's save and there was no way to tell from
		-- this screen whether the base was 1.0. Print the input, not only the arithmetic.
		local note = ""
		if FillType ~= nil and row.name == "WOOD" then
			local ft = g_fillTypeManager:getFillTypeByIndex(FillType.WOOD)
			note = string.format("   [base %s x %.1f — best-cut ceiling, not listed]",
				type(ft) == "table" and ft.pricePerLiter ~= nil
					and string.format("%.4f", ft.pricePerLiter) or "?",
				Offers.WOOD_BEST_RATE_SCALE)
		end

		table.insert(lines, string.format("  %-22s %8.3f /l   %s%s",
			row.title, row.rate, row.station, note))
	end

	return table.concat(lines, "\n")
end

--- `fcWood [off]` — print every wood delivery's species, litres, realised rate and implied K.
---
--- Phase 2 of forestry is deliberately invisible: it recovers the species a wood sale loses on
--- its way to the till and hands it to DeliveryWatch, and nothing yet acts on it. This is how
--- the seam gets proven before a contract depends on it.
---
--- It also turns every delivery the player makes into a free K measurement.
--- `Offers.WOOD_BEST_RATE_SCALE` is 1.2, the ceiling any wood can reach; the `K` column here is
--- the same ratio computed on whatever was actually cut, so the constant can be checked against
--- ordinary play rather than a measurement run.
---
--- OFF by default. It writes a line per TREE, and a trailer of logs would flood log.txt.
function Console:consoleWood(arg)
	local watch = self.mod.woodWatch

	if watch == nil then
		return "WoodWatch is not active — server only."
	end

	if not watch.isInstalled then
		return "WoodWatch did not install. WoodUnloadTrigger hooks were not found, so species "
			.. "tracking is off; see log.txt. Tier 1 wood contracts are unaffected."
	end

	if tostring(arg or ""):lower() == "off" then
		watch.logDeliveries = false
		return "Wood delivery logging off."
	end

	watch.logDeliveries = true

	return "Wood delivery logging ON. Tip a tree at a sawmill you do NOT own and read log.txt: "
		.. "one line per tree with species, litres, realised rate and implied K."
end
