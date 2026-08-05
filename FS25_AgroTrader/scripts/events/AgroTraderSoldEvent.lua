-- AgroTrader — an advert has been sold.
--
-- Server -> all clients, whenever a machine is bought. Without it every other player keeps seeing
-- an advert that no longer exists, and two people can buy the same machine.
--
-- Only the key travels. The advert itself is derived, so a client already knows everything about
-- it and simply needs telling it is gone.

AgroTraderSoldEvent = {}

local AgroTraderSoldEvent_mt = Class(AgroTraderSoldEvent, Event)

-- See AgroTraderStateEvent for why this is InitEventClass and why it must run at compile time.
InitEventClass(AgroTraderSoldEvent, "AgroTraderSoldEvent")

function AgroTraderSoldEvent.emptyNew()
	return Event.new(AgroTraderSoldEvent_mt)
end

function AgroTraderSoldEvent.new(key, period)
	local self = AgroTraderSoldEvent.emptyNew()
	self.key = key
	self.period = period
	return self
end

function AgroTraderSoldEvent:writeStream(streamId, connection)
	streamWriteString(streamId, self.key)
	streamWriteInt32(streamId, self.period or 0)
end

function AgroTraderSoldEvent:readStream(streamId, connection)
	self.key = streamReadString(streamId)
	self.period = streamReadInt32(streamId)
	self:run(connection)
end

function AgroTraderSoldEvent:run(connection)
	-- Server -> client only. A client claiming a sale would otherwise be able to delete adverts
	-- from everyone else's market.
	if not connection:getIsServer() then
		return
	end

	local market = AgroTrader ~= nil and AgroTrader.market or nil
	if market == nil then
		return
	end

	-- noEventSend: we are applying the server's broadcast, not originating one.
	market:markPurchased({ key = self.key, period = self.period }, true)
end
