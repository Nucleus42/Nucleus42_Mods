-- AgroTrader — the market.
--
-- ⚠ LISTINGS ARE NOT STORED. THEY ARE DERIVED FROM A SEED, ON DEMAND.
--
-- This replaces an earlier design that kept a fixed pool of 60 adverts in the savegame. That pool
-- was wrong for the job: 60 adverts drawn from ~750 machines meant searching for a specific model
-- almost never found it, which makes a searchable marketplace pointless. It optimised against an
-- exploit at the cost of the entire feature.
--
-- Here, the adverts for a machine are a pure function of
--     (save salt, machine, period, index)
-- so they can be generated the moment somebody searches, and thrown away afterwards.
--
-- THE EXPLOIT DIES BECAUSE THERE IS NOTHING TO RE-ROLL. Searching for the same machine twice in
-- the same period returns byte-identical adverts — same hours, same damage, same price — because
-- the same seed produces the same numbers. Closing the menu, reloading the save, or restarting
-- the game changes nothing. The player cannot shop for a better random number, because the random
-- number is a property of the world and not of the act of looking.
--
-- It is also cheaper than the pool it replaces: nothing to churn each hour, nothing to stream to
-- clients (they derive the same adverts themselves), and no 255-id wire ceiling.
--
-- The only thing that needs saving is which adverts have been BOUGHT, so they stop appearing.

Market = {}

local Market_mt = Class(Market)

if MessageType.AGROTRADER_MARKET_CHANGED == nil then
	-- `nextMessageTypeId()` is the global Giants' own MessageType table is built from
	-- (scripts/MessageType.lua:1-5), so registering here can never collide with theirs.
	MessageType.AGROTRADER_MARKET_CHANGED = nextMessageTypeId()
end

-- How long an advert stands before the market moves on.
Market.PERIOD_DAYS = 2

-- Adverts for a single machine in one period. There is never an unlimited number of anything.
Market.MAX_PER_ITEM = 5

-- Adverts a maximally common machine attracts. Rarity scales this down, so a very rare machine
-- averages well under one — meaning it is simply absent most periods, and finding one is an
-- event. Total market across every machine is roughly (sum of weights) x this.
Market.LISTINGS_SCALE = 4.5

-- ------------------------------------------------------------------ determinism
--
-- Hand-rolled hash and PRNG rather than math.random, for two reasons that both matter:
--
--  1. math.random is global mutable state. Seeding it here would disturb every other consumer in
--     the game, and its sequence is not guaranteed stable across platforms or Lua builds — so an
--     advert could differ between the server and a client, or between two loads of one save.
--  2. FS25 runs Lua 5.1, which has NO bitwise operators, so the usual FNV/xorshift constructions
--     do not compile. Everything below is plain multiply-add arithmetic, kept well inside the
--     53-bit range a double represents exactly (worst case 2^31 * 16807 ~= 3.6e13).

local PRIME = 2147483647   -- 2^31 - 1

local function hashString(str, seed)
	local h = (seed or 2166136261) % PRIME
	for i = 1, #str do
		h = (h * 31 + str:byte(i)) % PRIME
	end
	return h
end

--- Park-Miller minimal standard generator. Deterministic, portable, no global state.
local function makeRng(seed)
	local state = seed % PRIME
	if state <= 0 then
		state = state + PRIME - 1
	end
	return function()
		state = (state * 16807) % PRIME
		return state / PRIME
	end
end

function Market.new(rarity)
	local self = setmetatable({}, Market_mt)

	self.rarity = rarity

	-- Distinguishes one savegame's market from another's, so two saves started on the same day do
	-- not show identical adverts. Generated once and persisted.
	self.salt = nil

	-- Adverts the player has bought, as a set of listing keys. Pruned when their period lapses.
	self.purchased = {}

	return self
end

-- ---------------------------------------------------------------------- periods

--- The in-game day, from the clock that only ever counts up.
---
--- ⚠ MUST BE currentMonotonicDay, NOT currentDay. `currentDay` is RESCALED whenever the player
--- changes days-per-period (environment/Environment.lua:362), which would silently reshuffle
--- every advert in the market. `currentMonotonicDay` only ever increments (Environment.lua:338).
function Market.getDay()
	local environment = g_currentMission ~= nil and g_currentMission.environment or nil
	if environment == nil or environment.currentMonotonicDay == nil then
		return 1
	end
	return environment.currentMonotonicDay
end

--- Which period this machine is currently in.
---
--- The per-machine offset staggers turnover: without it every advert in the game would expire on
--- the same morning, which reads as the world blinking rather than a market moving.
function Market:getPeriod(storeItem, day)
	day = day or Market.getDay()
	local offset = hashString(storeItem.xmlFilename, 7919) % Market.PERIOD_DAYS
	return math.floor((day + offset) / Market.PERIOD_DAYS)
end

--- Stable identity for one advert. Survives save/load because every part of it does.
function Market.getKey(storeItem, period, index)
	return string.format("%s|%d|%d", storeItem.xmlFilename, period, index)
end

-- ------------------------------------------------------------------- generation

--- How many adverts this machine has standing in this period.
function Market:getListingCount(storeItem, period)
	local weight = self.rarity:getWeight(storeItem)
	if weight <= 0 then
		return 0
	end

	local rng = makeRng(hashString(storeItem.xmlFilename, (self.salt or 1) + period * 31))
	local expected = weight * Market.LISTINGS_SCALE

	-- Whole part guaranteed, fractional part as a probability — so a machine with an expectation
	-- of 0.45 adverts really is absent rather more often than not, instead of being rounded to
	-- either always-there or never-there.
	local count = math.floor(expected)
	if rng() < (expected - count) then
		count = count + 1
	end

	return math.min(count, Market.MAX_PER_ITEM)
end

--- Build one advert. Pure: same inputs, same advert, forever.
function Market:createListing(storeItem, period, index)
	local rng = makeRng(hashString(
		storeItem.xmlFilename .. "#" .. index,
		(self.salt or 1) + period * 7919))

	local history = Valuation.rollHistory(storeItem, rng)
	local distance = Valuation.rollDistance(rng)
	local deliveryFee, haulageRate = Valuation.getDeliveryFee(storeItem, distance.miles, nil, rng)

	return {
		key = Market.getKey(storeItem, period, index),
		storeItem = storeItem,
		xmlFilename = storeItem.xmlFilename,

		archetype = history.archetype,
		age = history.age,
		operatingTime = history.operatingTime,
		damage = history.damage,
		wear = history.wear,
		dirt = history.dirt,

		price = Valuation.getAskingPrice(storeItem, history),
		distanceTier = distance.tier,
		miles = distance.miles,
		deliveryFee = deliveryFee,
		haulageRate = haulageRate,

		period = period,
	}
end

--- Every advert standing for one machine right now.
function Market:getListingsFor(storeItem, day)
	local period = self:getPeriod(storeItem, day)
	local count = self:getListingCount(storeItem, period)

	local listings = {}
	for index = 1, count do
		local key = Market.getKey(storeItem, period, index)
		if self.purchased[key] == nil then
			table.insert(listings, self:createListing(storeItem, period, index))
		end
	end

	return listings
end

-- ----------------------------------------------------------------------- search

--- Search the market.
---
--- Two filters, and the split is deliberate — it is what makes a broad search affordable:
---
---   `itemFilter(storeItem)`   properties of the MACHINE: vehicle or attachment, style, make,
---                             model. Applied BEFORE anything is generated, so narrowing here
---                             costs nothing at all.
---   `listingFilter(listing)`  properties of the ADVERT: distance, hours, condition, price.
---                             These only exist once an advert is built, so they are applied
---                             after — but only across machines that already passed the first
---                             filter.
---
--- The consequence is the one you would expect from a classifieds site: widening the radius from
--- 100 to 400 miles returns more results because fewer adverts are discarded, not because more
--- were created. The adverts beyond 100 miles were always there; you just were not looking.
---
--- ⚠ RETURNS EVERY MATCH. DO NOT ADD A LIMIT HERE — CAP THE DISPLAY INSTEAD.
---
--- An earlier version stopped generating once it had N results. That looks like a harmless
--- optimisation and is not: it truncates in store-item iteration order, BEFORE the caller has had
--- any chance to sort. The player asking for the cheapest tractors within 400 miles got an
--- arbitrary 60 machines that happened to come first in the store, with the rest silently
--- discarded — so widening a search could drop results that a narrower one had shown, which is
--- the one thing a search must never do.
---
--- Generation is cheap enough that this does not matter: a whole-market sweep is ~1,900 adverts,
--- and a real search is a small fraction of that. Measured at 3 ms for a broad category search
--- against 739 machines. The safety ceiling below exists only to bound a pathological case, and
--- reports honestly when it bites.
---
--- Nothing is cached between calls: a cache would be one more thing that could disagree with the
--- seed.
Market.MAX_RESULTS = 5000

function Market:search(itemFilter, listingFilter)
	local results = {}
	local day = Market.getDay()

	for _, storeItem in ipairs(g_storeManager:getItems()) do
		if self.rarity:getWeight(storeItem) > 0
			and (itemFilter == nil or itemFilter(storeItem)) then

			for _, listing in ipairs(self:getListingsFor(storeItem, day)) do
				if listingFilter == nil or listingFilter(listing) then
					table.insert(results, listing)
					if #results >= Market.MAX_RESULTS then
						return results, true
					end
				end
			end
		end
	end

	return results, false
end

--- Rebuild one advert from its key, or nil if it is not a real, current, unsold advert.
---
--- ⚠ THIS IS THE SERVER'S TRUST BOUNDARY. In multiplayer the key arrives from a client, and a
--- client can send anything. Nothing about the advert is taken from the wire — only the key is —
--- and the advert is REGENERATED here from the server's own salt and clock. A modified client
--- asking for "that tractor, but zero hours at scrap price" gets the server's numbers instead.
---
--- Returning nil must be treated as "no such advert" and refuse the purchase outright. It must
--- never fall through to a sale-item-less buy, because vanilla then charges full list price for a
--- brand new machine (EconomyManager:getBuyPrice with a nil saleItem).
function Market:getListingByKey(key)
	if type(key) ~= "string" then
		return nil
	end

	-- Keys are `xmlFilename|period|index`. Filenames contain no pipe, and the period may be
	-- negative in principle, so anchor on the last two fields.
	local xmlFilename, period, index = key:match("^(.+)|(%-?%d+)|(%d+)$")
	if xmlFilename == nil then
		return nil
	end

	period, index = tonumber(period), tonumber(index)

	-- Lowercased because that is how StoreManager indexes them (shop/StoreManager.lua:449-455),
	-- and how vanilla's own readStream looks an item up.
	local storeItem = g_storeManager:getItemByXMLFilename(xmlFilename:lower())
	if storeItem == nil then
		return nil
	end

	-- Must be the advert standing RIGHT NOW. An old key is a stale screen or a replay attempt.
	if self:getPeriod(storeItem) ~= period then
		return nil
	end

	if index < 1 or index > self:getListingCount(storeItem, period) then
		return nil
	end

	if self.purchased[key] ~= nil then
		return nil
	end

	return self:createListing(storeItem, period, index)
end

--- Take an advert off the market. Called when the player buys.
---
--- `noEventSend` stops a client that is applying the server's own broadcast from echoing it back.
function Market:markPurchased(listing, noEventSend)
	self.purchased[listing.key] = listing.period

	if not noEventSend and g_server ~= nil then
		g_server:broadcastEvent(AgroTraderSoldEvent.new(listing.key, listing.period))
	end

	g_messageCenter:publish(MessageType.AGROTRADER_MARKET_CHANGED)
end

--- Adopt the server's market state on join. The salt is what makes a client derive the same
--- ~1,900 adverts the server has — no advert is ever streamed.
function Market:setNetworkState(salt, purchased)
	self.salt = salt
	self.purchased = purchased or {}

	Logging.info("[AgroTrader] Market state received: salt %d, %d purchase(s)",
		salt, table.size(self.purchased))

	g_messageCenter:publish(MessageType.AGROTRADER_MARKET_CHANGED)
end

-- ------------------------------------------------------------------- persistence

function Market:getSavegamePath()
	local missionInfo = g_currentMission.missionInfo
	if missionInfo == nil or missionInfo.savegameDirectory == nil then
		return nil
	end
	return missionInfo.savegameDirectory .. "/agroTrader.xml"
end

--- Forget purchases whose period has lapsed — those adverts are gone anyway, so the record of
--- having bought them is dead weight. Without this the set grows forever.
function Market:prunePurchased()
	local day = Market.getDay()
	local oldestLivePeriod = math.floor((day - Market.PERIOD_DAYS) / Market.PERIOD_DAYS)

	local removed = 0
	for key, period in pairs(self.purchased) do
		if period < oldestLivePeriod then
			self.purchased[key] = nil
			removed = removed + 1
		end
	end
	return removed
end

function Market:save()
	local path = self:getSavegamePath()
	if path == nil then
		return
	end

	self:prunePurchased()

	local xmlFile = XMLFile.create("agroTraderXML", path, "agroTrader")
	if xmlFile == nil then
		Logging.error("[AgroTrader] Could not write %s", path)
		return
	end

	xmlFile:setInt("agroTrader#salt", self.salt or 1)

	local index = 0
	for key, period in pairs(self.purchased) do
		local entry = string.format("agroTrader.purchased(%d)", index)
		xmlFile:setString(entry .. "#key", key)
		xmlFile:setInt(entry .. "#period", period)
		index = index + 1
	end

	xmlFile:save()
	xmlFile:delete()
end

function Market:load()
	local path = self:getSavegamePath()

	if path == nil or not fileExists(path) then
		-- New save. The salt is what makes two saves started on the same day show different
		-- markets; it is the ONE random thing in the whole system, rolled once and then fixed.
		self.salt = math.random(1, PRIME - 1)
		Logging.info("[AgroTrader] New market, salt %d", self.salt)
		return false
	end

	local xmlFile = XMLFile.load("agroTraderXML", path)
	if xmlFile == nil then
		self.salt = math.random(1, PRIME - 1)
		return false
	end

	self.salt = xmlFile:getInt("agroTrader#salt", math.random(1, PRIME - 1))
	self.purchased = {}

	xmlFile:iterate("agroTrader.purchased", function(_, key)
		local listingKey = xmlFile:getString(key .. "#key")
		if listingKey ~= nil then
			self.purchased[listingKey] = xmlFile:getInt(key .. "#period", 0)
		end
	end)

	xmlFile:delete()

	Logging.info("[AgroTrader] Market restored, salt %d, %d purchase(s) remembered",
		self.salt, table.size(self.purchased))
	return true
end
