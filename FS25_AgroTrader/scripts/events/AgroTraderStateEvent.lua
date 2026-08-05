-- AgroTrader — join sync.
--
-- Server -> one client, once, when they join. Carries the ENTIRE market in a few dozen bytes,
-- because the market is derived rather than stored: give a client the salt and it regenerates the
-- same ~1,900 adverts the server has, advert for advert, without another packet.
--
-- So this sends exactly two things:
--   the salt          — without it the client derives a completely different market
--   the purchased set — which adverts are already sold
--
-- ⚠ NEVER ADD ADVERTS TO THIS EVENT. If a future change makes it tempting to stream listings,
-- something has broken the determinism that makes the whole design work, and THAT is the bug to
-- fix. Streaming 1,900 adverts on every join would be a self-inflicted wound.

AgroTraderStateEvent = {}

local AgroTraderStateEvent_mt = Class(AgroTraderStateEvent, Event)

-- ⚠ InitEventClass, NOT InitStaticEventClass. The static variant assigns a fixed auto-incrementing
-- id (network/EventIds.lua:22-30), which is fine for the base game where the load order is known
-- and would collide between mods. InitEventClass registers by name instead
-- (network/EventIds.lua:11-21).
--
-- ⚠ AND IT MUST RUN AT COMPILE TIME. Both variants print an error and refuse if g_currentMission
-- (or g_server/g_client) already exists — so this file has to be `source`d from main.lua at load,
-- which it is. Calling it later silently leaves the event unregistered.
InitEventClass(AgroTraderStateEvent, "AgroTraderStateEvent")

-- The purchased set is pruned to the live period on save (Market:prunePurchased), so it stays
-- small. This cap is a wire-safety backstop, not an expected limit; it is logged if it ever bites.
AgroTraderStateEvent.MAX_KEYS = 2000

function AgroTraderStateEvent.emptyNew()
	return Event.new(AgroTraderStateEvent_mt)
end

function AgroTraderStateEvent.new(salt, purchased)
	local self = AgroTraderStateEvent.emptyNew()
	self.salt = salt
	self.purchased = purchased
	return self
end

function AgroTraderStateEvent:writeStream(streamId, connection)
	streamWriteInt32(streamId, self.salt or 1)

	local keys = {}
	for key, period in pairs(self.purchased or {}) do
		table.insert(keys, { key = key, period = period })
		if #keys >= AgroTraderStateEvent.MAX_KEYS then
			Logging.warning("[AgroTrader] Purchase set exceeded %d on join sync; truncating.",
				AgroTraderStateEvent.MAX_KEYS)
			break
		end
	end

	streamWriteUInt16(streamId, #keys)
	for _, entry in ipairs(keys) do
		streamWriteString(streamId, entry.key)
		streamWriteInt32(streamId, entry.period)
	end
end

function AgroTraderStateEvent:readStream(streamId, connection)
	self.salt = streamReadInt32(streamId)

	self.purchased = {}
	local count = streamReadUInt16(streamId)
	for _ = 1, count do
		local key = streamReadString(streamId)
		local period = streamReadInt32(streamId)
		self.purchased[key] = period
	end

	self:run(connection)
end

function AgroTraderStateEvent:run(connection)
	-- Client-side only: this travels one way. Guarding on it means a malicious client cannot push
	-- a salt at the server and silently reshape everyone's market.
	if not connection:getIsServer() then
		return
	end

	local market = AgroTrader ~= nil and AgroTrader.market or nil
	if market == nil then
		Logging.error("[AgroTrader] Market state arrived before the market existed.")
		return
	end

	market:setNetworkState(self.salt, self.purchased)
end
