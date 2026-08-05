-- AgroTrader — Console
--
-- Test and inspection commands. All prefixed `at` to avoid colliding with other mods.
--
-- These drive the SAME Market:search the finished screen will, with the same two-stage filter
-- split, so what you see here is what the UI will show. A debug command that took a shortcut past
-- the real code path would prove the debug command works, not the mod.

Console = {}

local Console_mt = Class(Console)

Console.COMMANDS = {
	{ name = "atRarity", desc = "Print the derived rarity table [vehicles|implements]", fn = "consoleRarity" },
	{ name = "atSearch", desc = "Search the market: [type/make/model] [maxMiles] [maxHours]", fn = "consoleSearch" },
	{ name = "atMarket", desc = "Market size and turnover summary", fn = "consoleMarket" },
	{ name = "atBuy", desc = "Buy result N from the last atSearch", fn = "consoleBuy" },
}

-- A broad search can match thousands of adverts. The console is not the place to print them all.
Console.SEARCH_LIMIT = 60

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

--- Print every category with its median price, rarity band and listing weight.
---
--- Prints BOTH sides separately and never interleaved, because the whole point of the model is
--- that the two are ranked on different scales — showing them in one list would recreate exactly
--- the confusion that made the first version wrong (see Rarity.lua's header).
function Console:consoleRarity(filter)
	local rarity = self.mod.rarity
	if rarity == nil or not rarity.isBuilt then
		return "AgroTrader: rarity not built yet."
	end

	local wantVehicles, wantImplements = true, true
	if filter ~= nil and filter ~= "" then
		wantVehicles = filter:lower():sub(1, 1) == "v"
		wantImplements = not wantVehicles
	end

	local function dumpSide(isMotorized, heading)
		local rows = {}
		for _, bucket in ipairs(rarity.categories) do
			if bucket.isMotorized == isMotorized then
				table.insert(rows, bucket)
			end
		end
		table.sort(rows, function(a, b) return a.median < b.median end)

		print("")
		print(string.format("=== %s (%d categories) ===", heading, #rows))
		print(string.format("%-32s %10s %6s %8s   %s", "CATEGORY", "MEDIAN", "N", "WEIGHT", "BAND"))
		for _, bucket in ipairs(rows) do
			print(string.format("%-32s %10d %6d %8.3f   %s",
				bucket.category, bucket.median, #bucket.items, bucket.weight,
				Rarity.getBandName(bucket.weight, isMotorized)))
		end
	end

	if wantVehicles then dumpSide(true, "SELF-PROPELLED") end
	if wantImplements then dumpSide(false, "TOWED / MOUNTED") end

	return string.format("AgroTrader: %d categories, %d machines. Full table in log.txt.",
		#rarity.categories, table.size(rarity.weightByItemId))
end

--- Search the market exactly as the finished screen will.
---
---   atSearch tractor            every tractor advert anywhere
---   atSearch tractorsS 100      small tractors within 100 miles
---   atSearch fendt 400 100      Fendt anything, within 400 miles, under 100 hours
---
--- Run the same search twice and you MUST get identical results — that is the anti-reroll
--- property the whole design rests on, and this is the cheapest way to check it still holds.
function Console:consoleSearch(term, maxMiles, maxHours)
	local market = self.mod.market
	if market == nil then
		return "AgroTrader: no market on this machine."
	end

	local needle = (term ~= nil and term ~= "") and term:lower() or nil
	maxMiles = tonumber(maxMiles)
	maxHours = tonumber(maxHours)

	-- Machine-level: matched against name, category and brand — the three things the finished
	-- Style / Make / Model filters will use.
	local itemFilter = needle == nil and nil or function(storeItem)
		local name = (storeItem.name or ""):lower()
		local category = (storeItem.categoryName or ""):lower()
		local brand = ""
		local brandData = storeItem.brandIndex ~= nil
			and g_brandManager:getBrandByIndex(storeItem.brandIndex) or nil
		if brandData ~= nil and brandData.title ~= nil then
			brand = brandData.title:lower()
		end
		return name:find(needle, 1, true) ~= nil
			or category:find(needle, 1, true) ~= nil
			or brand:find(needle, 1, true) ~= nil
	end

	-- Listing-level: only meaningful once the advert exists.
	local listingFilter = (maxMiles == nil and maxHours == nil) and nil or function(listing)
		if maxMiles ~= nil and listing.miles > maxMiles then
			return false
		end
		if maxHours ~= nil and listing.operatingTime / 3600000 > maxHours then
			return false
		end
		return true
	end

	local results = market:search(itemFilter, listingFilter)
	local found = #results

	if found == 0 then
		return
			"AgroTrader: nothing matches. Try a wider radius, or a category (tractor, plow, baler)."
	end

	-- ⚠ SORT FIRST, THEN CAP. Capping during the search would hand back an arbitrary slice in
	-- store order rather than the cheapest, and a wider search could then LOSE results a narrower
	-- one had shown. See Market:search.
	table.sort(results, function(a, b) return a.price < b.price end)

	local truncated = found > Console.SEARCH_LIMIT
	if truncated then
		for index = found, Console.SEARCH_LIMIT + 1, -1 do
			results[index] = nil
		end
	end

	-- Kept so atBuy can act on what was just listed, exactly as the finished screen will act on
	-- the row the player clicked.
	self.lastResults = results

	print(string.format("%-4s %-26s %-16s %-11s %6s %7s %7s %7s %6s %11s %9s",
		"#", "MACHINE", "CATEGORY", "OWNER", "AGE", "HOURS", "DAMAGE", "PAINT", "MILES",
		"ASKING", "DELIVERY"))

	local byCategory, total = {}, 0
	for index, listing in ipairs(results) do
		local storeItem = listing.storeItem
		local category = storeItem.categoryName or "?"
		byCategory[category] = (byCategory[category] or 0) + 1
		total = total + listing.price

		print(string.format("%-4d %-26s %-16s %-11s %4dm %7.0f %6.0f%% %6.0f%% %6d %11s %9s",
			index,
			(storeItem.name or "?"):sub(1, 26), category:sub(1, 16), listing.archetype,
			listing.age, listing.operatingTime / 3600000,
			listing.damage * 100, listing.wear * 100, listing.miles,
			g_i18n:formatMoney(listing.price, 0, true, true),
			g_i18n:formatMoney(listing.deliveryFee, 0, true, true)))
	end

	local ordered = {}
	for category, count in pairs(byCategory) do
		table.insert(ordered, { category = category, count = count })
	end
	table.sort(ordered, function(a, b)
		if a.count == b.count then return a.category < b.category end
		return a.count > b.count
	end)

	local parts = {}
	for _, row in ipairs(ordered) do
		table.insert(parts, string.format("%s %d", row.category, row.count))
	end
	print("  breakdown: " .. table.concat(parts, ", "))

	return string.format("AgroTrader: %d result(s)%s, average asking %s. Full list in log.txt.",
		found,
		truncated and string.format(" — showing the %d cheapest", Console.SEARCH_LIMIT) or "",
		g_i18n:formatMoney(total / #results, 0, true, true))
end

--- Buy one of the adverts the last search listed.
---
--- Goes through the SAME front door the finished screen will use — g_shopController:buyVehicle —
--- so what this proves is what the button will do, not a parallel path that happens to work.
--- Expect the vanilla config screen with the 3D preview, specs, price and Buy button, and with
--- every configuration control absent.
function Console:consoleBuy(index)
	index = tonumber(index)
	if index == nil then
		return "AgroTrader: usage is atBuy <number from the last atSearch>."
	end

	local results = self.lastResults
	if results == nil or #results == 0 then
		return "AgroTrader: run atSearch first."
	end

	local listing = results[index]
	if listing == nil then
		return string.format("AgroTrader: pick 1 to %d.", #results)
	end

	local ok, reason = Purchase.begin(listing)
	if not ok then
		return string.format("AgroTrader: cannot buy that — %s.", reason)
	end

	return string.format("AgroTrader: %s, %s asking plus %s delivery = %s. Confirm on screen.",
		listing.storeItem.name or "?",
		g_i18n:formatMoney(listing.price, 0, true, true),
		g_i18n:formatMoney(listing.deliveryFee, 0, true, true),
		g_i18n:formatMoney(listing.price + listing.deliveryFee, 0, true, true))
end

--- How big is the market, and how much of it is standing right now.
---
--- Walks every machine and counts its live adverts. Slower than a search because it deliberately
--- filters nothing — this is the number that says whether the marketplace feels populated.
function Console:consoleMarket()
	local market = self.mod.market
	if market == nil then
		return "AgroTrader: no market on this machine."
	end

	local day = Market.getDay()
	local machines, listings, withNone, vehicles, implements = 0, 0, 0, 0, 0

	for _, storeItem in ipairs(g_storeManager:getItems()) do
		if market.rarity:getWeight(storeItem) > 0 then
			machines = machines + 1
			local count = #market:getListingsFor(storeItem, day)
			listings = listings + count
			if count == 0 then
				withNone = withNone + 1
			elseif Rarity.getIsMotorized(storeItem) then
				vehicles = vehicles + count
			else
				implements = implements + count
			end
		end
	end

	print(string.format("AgroTrader market on day %d (period length %d days)",
		day, Market.PERIOD_DAYS))
	print(string.format("  machines that can appear : %d", machines))
	print(string.format("  adverts standing now     : %d", listings))
	print(string.format("  self-propelled / towed   : %d / %d", vehicles, implements))
	print(string.format("  machines with none today : %d (%.0f%%)",
		withNone, 100 * withNone / math.max(machines, 1)))
	print(string.format("  purchases remembered     : %d", table.size(market.purchased)))

	return string.format("AgroTrader: %d adverts across %d machines. Detail in log.txt.",
		listings, machines)
end
