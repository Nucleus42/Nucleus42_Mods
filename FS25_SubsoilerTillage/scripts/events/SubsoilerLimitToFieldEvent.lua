--
-- SubsoilerLimitToFieldEvent
--
-- Syncs the create-fields toggle. Modelled on PlowLimitToFieldEvent.
--

SubsoilerLimitToFieldEvent = {}

local SubsoilerLimitToFieldEvent_mt = Class(SubsoilerLimitToFieldEvent, Event)

InitEventClass(SubsoilerLimitToFieldEvent, "SubsoilerLimitToFieldEvent")

function SubsoilerLimitToFieldEvent.emptyNew()
	return Event.new(SubsoilerLimitToFieldEvent_mt)
end

function SubsoilerLimitToFieldEvent.new(vehicle, limitToField)
	local self = SubsoilerLimitToFieldEvent.emptyNew()
	self.vehicle = vehicle
	self.limitToField = limitToField
	return self
end

function SubsoilerLimitToFieldEvent:readStream(streamId, connection)
	self.vehicle = NetworkUtil.readNodeObject(streamId)
	self.limitToField = streamReadBool(streamId)
	self:run(connection)
end

function SubsoilerLimitToFieldEvent:writeStream(streamId, connection)
	NetworkUtil.writeNodeObject(streamId, self.vehicle)
	streamWriteBool(streamId, self.limitToField)
end

function SubsoilerLimitToFieldEvent:run(connection)
	if self.vehicle ~= nil and self.vehicle:getIsSubsoilerPlow() then
		self.vehicle:setSubsoilerLimitToField(self.limitToField, true)
	end

	-- Relay to the other clients when this arrived at the server.
	if not connection:getIsServer() then
		g_server:broadcastEvent(SubsoilerLimitToFieldEvent.new(self.vehicle, self.limitToField), nil, connection, self.vehicle)
	end
end

function SubsoilerLimitToFieldEvent.sendEvent(vehicle, limitToField, noEventSend)
	if noEventSend then
		return
	end

	if g_server ~= nil then
		g_server:broadcastEvent(SubsoilerLimitToFieldEvent.new(vehicle, limitToField), nil, nil, vehicle)
	else
		g_client:getServerConnection():sendEvent(SubsoilerLimitToFieldEvent.new(vehicle, limitToField))
	end
end
