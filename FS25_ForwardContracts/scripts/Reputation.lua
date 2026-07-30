-- Forward Contracts — Reputation
--
-- Two scores, deliberately not merged (HANDOFF.md §4.5):
--
--   reputation   global, per farm. Gates the board — how many offers, how long, how
--                large, how serious the client.
--   relationship per client, held by ClientRegistry. Improves that client's terms.
--
-- This module owns every mutation of both, so the rules live in one place rather than
-- being scattered across whoever happened to notice the event.
--
-- Reputation is slow to earn and quick to lose. That asymmetry is the point: it makes the
-- climb to above-market contracts (§4.5) mean something, and it makes a walked negotiation
-- hurt for longer than the deal you lost.

Reputation = {}

local Reputation_mt = Class(Reputation)

Reputation.SAVEGAME_FILENAME = "forwardContractsReputation.xml"

-- All deltas are on the 0..1 reputation scale.
Reputation.DELTA = {
	-- Earned slowly.
	quotaMet = 0.04,
	contractCompleted = 0.08,
	spotDelivered = 0.02,

	-- Lost quickly.
	quotaMissedBase = 0.03, -- plus up to quotaMissedScaled, by how badly you missed
	quotaMissedScaled = 0.05,
	contractTerminated = 0.12,
	spotExpired = 0.05,
	negotiationPushedTooHard = 0.02,

	-- The worst thing you can do. They conceded, you repeated your number, they left.
	-- Deliberately larger than a terminated contract: failing to deliver is a bad year,
	-- but negotiating in bad faith is a statement about who you are.
	negotiationBadFaith = 0.15,
}

-- Relationship moves further than reputation on the same event — the client who was
-- actually in the room takes it more personally than the wider trade does.
Reputation.RELATIONSHIP_MULTIPLIER = 1.5

function Reputation.new(clientRegistry)
	local self = setmetatable({}, Reputation_mt)

	self.clientRegistry = clientRegistry
	self.byFarm = {}

	-- [farmId][subTypeName] = completed years in that breed. A track record: prove you can
	-- deliver Black Welsh Mountain sheep and the market starts asking you for them.
	self.breedRecord = {}

	return self
end

-- ---------------------------------------------------------------------------
-- Breed track record
-- ---------------------------------------------------------------------------

--- A year met on a livestock contract counts toward that breed's record.
---
--- This is what makes investing in a species pay forward: Offers weights its breed choice
--- by this record, so completing a bottom-tier sheep contract markedly raises the chance
--- the next offer is for the same sheep. Without it, building a husbandry for one contract
--- is a gamble that the market never rewards, and the sensible play would be to ignore
--- livestock entirely.
function Reputation:recordBreedSuccess(farmId, subTypeName)
	if farmId == nil or subTypeName == nil then
		return
	end

	local farm = self.breedRecord[farmId]
	if farm == nil then
		farm = {}
		self.breedRecord[farmId] = farm
	end

	farm[subTypeName] = (farm[subTypeName] or 0) + 1
end

function Reputation:getBreedRecord(farmId)
	return self.breedRecord[farmId] or {}
end

function Reputation:getReputation(farmId)
	return self.byFarm[farmId] or 0
end

function Reputation:adjust(farmId, delta)
	local current = self.byFarm[farmId] or 0
	self.byFarm[farmId] = math.max(0, math.min(1, current + delta))
end

--- Apply a reputation change and the matching relationship change together, so the two
--- can never drift apart.
function Reputation:applyEvent(contractOrOffer, delta)
	if contractOrOffer == nil then
		return
	end

	self:adjust(contractOrOffer.farmId, delta)

	local clientId = contractOrOffer.clientId
		or (contractOrOffer.client ~= nil and contractOrOffer.client.id or nil)

	if clientId ~= nil and self.clientRegistry ~= nil then
		self.clientRegistry:adjustRelationship(clientId, delta * Reputation.RELATIONSHIP_MULTIPLIER)
	end
end

-- ---------------------------------------------------------------------------
-- ContractStore callbacks
-- ---------------------------------------------------------------------------

function Reputation:onQuotaMet(contract)
	self:applyEvent(contract, Reputation.DELTA.quotaMet)

	-- Credited per YEAR met rather than per contract completed, so a long agreement builds
	-- the line faster than a short one — which is the right incentive, and means the record
	-- grows during a multi-year contract instead of only at the very end.
	self:recordBreedSuccess(contract.farmId, contract.subTypeName)
end

function Reputation:onQuotaMissed(contract, shortfallFraction, penalty)
	local delta = Reputation.DELTA.quotaMissedBase
		+ Reputation.DELTA.quotaMissedScaled * (shortfallFraction or 1)

	self:applyEvent(contract, -delta)
end

function Reputation:onContractCompleted(contract)
	if contract.kind == ContractStore.KIND_SPOT then
		self:applyEvent(contract, Reputation.DELTA.spotDelivered)
	else
		self:applyEvent(contract, Reputation.DELTA.contractCompleted)
	end

	if self.clientRegistry ~= nil then
		self.clientRegistry:onContractCompleted(contract.clientId)
	end
end

function Reputation:onContractTerminated(contract)
	self:applyEvent(contract, -Reputation.DELTA.contractTerminated)

	if self.clientRegistry ~= nil then
		self.clientRegistry:onContractFailed(contract.clientId)
	end
end

--- A contract reached the end of its term without being honoured, but was never terminated
--- outright — one bad year on a short agreement.
---
--- **No reputation change here.** The yearly misses already charged for it, and charging
--- again at the end would double-penalise the same failure. This exists so the CLIENT's
--- record is not silent: without it a contract that ran its full term and delivered nothing
--- left `completed="0" failed="0"`, as though it had never been signed. Clients remember
--- you (§4.1), and they should remember this too.
function Reputation:onContractUnfulfilled(contract)
	if self.clientRegistry ~= nil then
		self.clientRegistry:onContractFailed(contract.clientId)
	end
end

function Reputation:onSpotOrderExpired(contract)
	self:applyEvent(contract, -Reputation.DELTA.spotExpired)

	if self.clientRegistry ~= nil then
		self.clientRegistry:onContractFailed(contract.clientId)
	end
end

-- ---------------------------------------------------------------------------
-- Offers callbacks
-- ---------------------------------------------------------------------------

function Reputation:onNegotiationPushedTooHard(offer)
	self:applyEvent(offer, -Reputation.DELTA.negotiationPushedTooHard)
end

function Reputation:onNegotiationBadFaith(offer)
	self:applyEvent(offer, -Reputation.DELTA.negotiationBadFaith)
end

-- ---------------------------------------------------------------------------
-- Persistence
-- ---------------------------------------------------------------------------

function Reputation:getSavegamePath()
	local missionInfo = g_currentMission.missionInfo
	if missionInfo == nil or missionInfo.savegameDirectory == nil then
		return nil
	end

	return missionInfo.savegameDirectory .. "/" .. Reputation.SAVEGAME_FILENAME
end

function Reputation:save()
	local path = self:getSavegamePath()
	if path == nil then
		return
	end

	local xmlFile = createXMLFile("forwardContractsReputation", path, "forwardContractsReputation")
	if xmlFile == nil or xmlFile == 0 then
		Logging.error("[ForwardContracts] Could not create reputation file at %s", path)
		return
	end

	local index = 0
	for farmId, value in pairs(self.byFarm) do
		local key = string.format("forwardContractsReputation.farm(%d)", index)
		setXMLInt(xmlFile, key .. "#farmId", farmId)
		setXMLFloat(xmlFile, key .. "#value", value)

		local breeds = self.breedRecord[farmId]
		if breeds ~= nil then
			local breedIndex = 0
			for subTypeName, count in pairs(breeds) do
				local breedKey = string.format("%s.breed(%d)", key, breedIndex)
				setXMLString(xmlFile, breedKey .. "#name", subTypeName)
				setXMLInt(xmlFile, breedKey .. "#count", count)
				breedIndex = breedIndex + 1
			end
		end

		index = index + 1
	end

	saveXMLFile(xmlFile)
	delete(xmlFile)
end

function Reputation:load()
	local path = self:getSavegamePath()
	if path == nil or not fileExists(path) then
		return
	end

	local xmlFile = loadXMLFile("forwardContractsReputation", path)
	if xmlFile == nil or xmlFile == 0 then
		return
	end

	self.byFarm = {}
	self.breedRecord = {}

	local index = 0
	while true do
		local key = string.format("forwardContractsReputation.farm(%d)", index)
		if not hasXMLProperty(xmlFile, key) then
			break
		end

		local farmId = getXMLInt(xmlFile, key .. "#farmId")
		local value = getXMLFloat(xmlFile, key .. "#value")

		if farmId ~= nil and value ~= nil then
			self.byFarm[farmId] = value

			local breedIndex = 0
			while true do
				local breedKey = string.format("%s.breed(%d)", key, breedIndex)
				if not hasXMLProperty(xmlFile, breedKey) then
					break
				end

				local name = getXMLString(xmlFile, breedKey .. "#name")
				local count = getXMLInt(xmlFile, breedKey .. "#count")

				if name ~= nil and count ~= nil then
					self.breedRecord[farmId] = self.breedRecord[farmId] or {}
					self.breedRecord[farmId][name] = count
				end

				breedIndex = breedIndex + 1
			end
		end

		index = index + 1
	end

	delete(xmlFile)
end
