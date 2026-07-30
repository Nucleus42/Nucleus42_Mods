-- Forward Contracts — ClientRegistry
--
-- The people you deal with. Persistent across the save: they remember you, they come back,
-- and they grow.
--
-- This is the spine of the design (HANDOFF.md §4.1). Two contracts with one client is
-- worth more than two with strangers, and that is not a bonus bolted on top — it falls out
-- of `relationship` feeding straight into the negotiation profile.

ClientRegistry = {}

local ClientRegistry_mt = Class(ClientRegistry)

ClientRegistry.SAVEGAME_FILENAME = "forwardContractsClients.xml"

-- How often an offer comes from someone you already know rather than a stranger. High
-- enough that relationships actually accumulate within a playthrough.
ClientRegistry.REUSE_CHANCE = 0.55

-- Never let the roster sprawl. A farm deals with a handful of buyers, not a directory.
ClientRegistry.MAX_CLIENTS = 12

-- Clients grow as you do. Size multiplies the quota they ask for, so a long relationship
-- means bigger commitments — the narrative of a business expanding alongside your farm.
ClientRegistry.SIZE_GROWTH_PER_CONTRACT = 0.08
ClientRegistry.MAX_SIZE = 1.8

local PLACES = {
	"Ashcombe", "Bramfield", "Kirkby", "Halstead", "Denby", "Ravensworth",
	"Thornleigh", "Marsden", "Ellerby", "Wexford", "Cranmere", "Fenwick",
	"Ottery", "Skelton", "Whitmoor", "Harlow", "Netherby", "Cawdor",
	"Aldbourne", "Pemberton", "Hollingworth", "Stanbridge", "Yarrow", "Cadwell",
}

-- Suffixes are split so a buyer of raw crops reads like a merchant and a buyer of
-- processed goods reads like a manufacturer. Cheap, but it makes the board feel authored.
local RAW_SUFFIXES = {
	"Grain Co.", "Mill", "Merchants", "Trading Co.", "Provisions",
	"Agricultural", "Produce", "Market Co.",
}

local PROCESSED_SUFFIXES = {
	"Foods", "Creamery", "Brewing Co.", "Kitchens", "Fine Foods",
	"Wholesale", "Packing Co.", "Preserves",
}

local FAMILY_FORMS = {
	"%s & Sons", "%s Bros.", "%s & Daughters", "Old %s Farm",
}

function ClientRegistry.new()
	local self = setmetatable({}, ClientRegistry_mt)

	self.clients = {}
	self.nextId = 1

	return self
end

-- ---------------------------------------------------------------------------
-- Creation
-- ---------------------------------------------------------------------------

local function pick(list)
	return list[math.random(#list)]
end

function ClientRegistry:generateName(isProcessed)
	local place = pick(PLACES)

	-- Occasionally a family business rather than a company.
	if math.random() < 0.22 then
		return string.format(pick(FAMILY_FORMS), place)
	end

	local suffix = isProcessed and pick(PROCESSED_SUFFIXES) or pick(RAW_SUFFIXES)

	return string.format("%s %s", place, suffix)
end

function ClientRegistry:createClient(isProcessed)
	local client = {
		id = self.nextId,
		name = self:generateName(isProcessed),
		isProcessed = isProcessed == true,
		size = 1.0,
		relationship = 0,
		completed = 0,
		failed = 0,
	}

	self.nextId = self.nextId + 1
	table.insert(self.clients, client)

	return client
end

-- ---------------------------------------------------------------------------
-- Offer provider interface
-- ---------------------------------------------------------------------------

--- Who is making this offer.
---
--- Weighted toward clients you already have a relationship with, because repeat business
--- is the mechanic. A stranger is always possible — that is how the roster grows.
function ClientRegistry:getClientForOffer(farmId, isProcessed)
	local pool = {}

	for _, client in ipairs(self.clients) do
		-- Prefer buyers of the right kind of product, so a creamery does not start
		-- contracting for wheat.
		if client.isProcessed == (isProcessed == true) then
			table.insert(pool, client)
		end
	end

	local canReuse = #pool > 0 and math.random() < ClientRegistry.REUSE_CHANCE
	local mustReuse = #self.clients >= ClientRegistry.MAX_CLIENTS and #pool > 0

	if canReuse or mustReuse then
		return self:pickWeighted(pool)
	end

	return self:createClient(isProcessed)
end

--- Weighted by relationship, with a floor so a neglected client is never impossible.
function ClientRegistry:pickWeighted(pool)
	local total = 0
	for _, client in ipairs(pool) do
		total = total + 0.2 + client.relationship
	end

	local roll = math.random() * total
	local running = 0

	for _, client in ipairs(pool) do
		running = running + 0.2 + client.relationship
		if roll <= running then
			return client
		end
	end

	return pool[#pool]
end

function ClientRegistry:getClientById(clientId)
	for _, client in ipairs(self.clients) do
		if client.id == clientId then
			return client
		end
	end

	return nil
end

-- ---------------------------------------------------------------------------
-- Relationship
-- ---------------------------------------------------------------------------

function ClientRegistry:adjustRelationship(clientId, delta)
	local client = self:getClientById(clientId)
	if client == nil then
		return
	end

	client.relationship = math.max(0, math.min(1, client.relationship + delta))
end

--- A contract ran its full term. They grow, and they want more next time.
function ClientRegistry:onContractCompleted(clientId)
	local client = self:getClientById(clientId)
	if client == nil then
		return
	end

	client.completed = client.completed + 1
	client.size = math.min(ClientRegistry.MAX_SIZE,
		client.size + ClientRegistry.SIZE_GROWTH_PER_CONTRACT)
end

function ClientRegistry:onContractFailed(clientId)
	local client = self:getClientById(clientId)
	if client == nil then
		return
	end

	client.failed = client.failed + 1
end

-- ---------------------------------------------------------------------------
-- Persistence
-- ---------------------------------------------------------------------------

function ClientRegistry:getSavegamePath()
	local missionInfo = g_currentMission.missionInfo
	if missionInfo == nil or missionInfo.savegameDirectory == nil then
		return nil
	end

	return missionInfo.savegameDirectory .. "/" .. ClientRegistry.SAVEGAME_FILENAME
end

function ClientRegistry:save()
	local path = self:getSavegamePath()
	if path == nil then
		return
	end

	local xmlFile = createXMLFile("forwardContractsClients", path, "forwardContractsClients")
	if xmlFile == nil or xmlFile == 0 then
		Logging.error("[ForwardContracts] Could not create client file at %s", path)
		return
	end

	setXMLInt(xmlFile, "forwardContractsClients#nextId", self.nextId)

	for index, client in ipairs(self.clients) do
		local key = string.format("forwardContractsClients.client(%d)", index - 1)

		setXMLInt(xmlFile, key .. "#id", client.id)
		setXMLString(xmlFile, key .. "#name", client.name)
		setXMLBool(xmlFile, key .. "#isProcessed", client.isProcessed)
		setXMLFloat(xmlFile, key .. "#size", client.size)
		setXMLFloat(xmlFile, key .. "#relationship", client.relationship)
		setXMLInt(xmlFile, key .. "#completed", client.completed)
		setXMLInt(xmlFile, key .. "#failed", client.failed)
	end

	saveXMLFile(xmlFile)
	delete(xmlFile)
end

function ClientRegistry:load()
	local path = self:getSavegamePath()
	if path == nil or not fileExists(path) then
		return
	end

	local xmlFile = loadXMLFile("forwardContractsClients", path)
	if xmlFile == nil or xmlFile == 0 then
		return
	end

	self.clients = {}
	self.nextId = getXMLInt(xmlFile, "forwardContractsClients#nextId") or 1

	local index = 0
	while true do
		local key = string.format("forwardContractsClients.client(%d)", index)
		if not hasXMLProperty(xmlFile, key) then
			break
		end

		local client = {
			id = getXMLInt(xmlFile, key .. "#id") or index + 1,
			name = getXMLString(xmlFile, key .. "#name") or "Unknown buyer",
			isProcessed = getXMLBool(xmlFile, key .. "#isProcessed") or false,
			size = getXMLFloat(xmlFile, key .. "#size") or 1,
			relationship = getXMLFloat(xmlFile, key .. "#relationship") or 0,
			completed = getXMLInt(xmlFile, key .. "#completed") or 0,
			failed = getXMLInt(xmlFile, key .. "#failed") or 0,
		}

		table.insert(self.clients, client)
		self.nextId = math.max(self.nextId, client.id + 1)

		index = index + 1
	end

	delete(xmlFile)
end
