-- Forward Contracts
-- Entry point. See HANDOFF.md for the design and the research behind it.

ForwardContracts = {}

ForwardContracts.MOD_NAME = g_currentModName
ForwardContracts.MOD_DIR = g_currentModDirectory
-- Printed to the log on load. Read from modDesc.xml so it can never disagree with the mod list.
ForwardContracts.VERSION = (function()
	local mod = g_modManager ~= nil and g_modManager:getModByName(g_currentModName) or nil
	return mod ~= nil and mod.version or "unknown"
end)()

-- Order matters: Offers reads constants off ContractStore at source time.
source(ForwardContracts.MOD_DIR .. "scripts/DeliveryWatch.lua")
source(ForwardContracts.MOD_DIR .. "scripts/WoodWatch.lua")
source(ForwardContracts.MOD_DIR .. "scripts/PlantingWatch.lua")
source(ForwardContracts.MOD_DIR .. "scripts/Animals.lua")
source(ForwardContracts.MOD_DIR .. "scripts/Settlement.lua")
source(ForwardContracts.MOD_DIR .. "scripts/ContractStore.lua")
source(ForwardContracts.MOD_DIR .. "scripts/Negotiation.lua")
source(ForwardContracts.MOD_DIR .. "scripts/ClientRegistry.lua")
source(ForwardContracts.MOD_DIR .. "scripts/Reputation.lua")
source(ForwardContracts.MOD_DIR .. "scripts/FeedLedger.lua")
source(ForwardContracts.MOD_DIR .. "scripts/Offers.lua")
source(ForwardContracts.MOD_DIR .. "scripts/Console.lua")
source(ForwardContracts.MOD_DIR .. "scripts/gui/ContractBoardFrame.lua")
source(ForwardContracts.MOD_DIR .. "scripts/gui/NegotiationDialog.lua")
source(ForwardContracts.MOD_DIR .. "scripts/UI.lua")

ForwardContracts.REQUIRED_MOD = "FS25_RealisticLivestockRM"

-- Hard dependency (HANDOFF.md §5). Realistic Livestock supplies the genetics model the
-- animal contracts are built on. There is deliberately no fallback path, so fail loud and
-- stay disabled rather than half-working.
--
-- Detect via g_modIsLoaded, the same way the base game tests for a mod
-- (scripts/gui/InGameMenuSettingsFrame.lua:367). Do NOT test for one of RL's globals:
-- every mod runs in its own script environment, so RL's classes are invisible from here
-- no matter the load order. Animal INSTANCES reached through husbandry objects at runtime
-- still carry their methods and are callable — it is only the class global that does not
-- cross the boundary.
function ForwardContracts:checkDependencies()
	if not g_modIsLoaded[ForwardContracts.REQUIRED_MOD] then
		Logging.error("[ForwardContracts] Realistic Livestock not found. This mod requires " ..
			"%s and will stay disabled.", ForwardContracts.REQUIRED_MOD)
		return false
	end
	return true
end

function ForwardContracts:loadMap(name)
	self.isEnabled = self:checkDependencies()
	if not self.isEnabled then
		return
	end

	-- Server-authoritative (HANDOFF.md §4.7). The station totals DeliveryWatch reads are
	-- never streamed to clients, so all of this is server-side. Clients will render
	-- contract state pushed to them once the network layer exists.
	if g_currentMission:getIsServer() then
		self.clientRegistry = ClientRegistry.new()
		self.reputation = Reputation.new(self.clientRegistry)

		self.contractStore = ContractStore.new()
		self.deliveryWatch = DeliveryWatch.new()
		self.woodWatch = WoodWatch.new()

		-- The planting ledger. Its provider is the store itself — `creditPlanting` lives there
		-- because completing a contract is the store's business, and a tree can be the LAST
		-- thing a forestry contract was waiting for.
		self.plantingWatch = PlantingWatch.new(self.contractStore)

		self.animals = Animals.new()
		self.feedLedger = FeedLedger.new()
		self.settlement = Settlement.new(self.contractStore)
		self.offers = Offers.new(self.contractStore)

		-- Reputation owns every mutation of both scores, so it is wired in as the single
		-- listener for both the contract lifecycle and negotiation outcomes.
		self.contractStore:setReputationProvider(self.reputation)
		self.offers:setReputationProvider(self.reputation)
		self.offers:setClientProvider(self.clientRegistry)

		self.deliveryWatch:addListener(self.settlement, Settlement.onDelivery)

		-- Species reaches settlement as an ANNOTATION on the ordinary delivery event, not as a
		-- parallel count. WoodWatch parks the tree in flight; DeliveryWatch consumes it when the
		-- sale actually books, so the two can never disagree about how much wood was sold.
		self.deliveryWatch:setWoodWatch(self.woodWatch)

		-- A contract completing in good standing brings its buyer straight back. Wired as a
		-- handler because ContractStore must not learn how the board works — and it has to
		-- fire during settlement, since the completed contract is pruned moments later.
		self.contractStore:setRenewalHandler(self.offers, Offers.createRenewalOffer)

		-- Livestock rides the same settlement rails as everything else: Animals observes
		-- and judges, Settlement pays. It needs the genetics provider because judging an
		-- animal against a contract's trait floors is Animals' knowledge, not its own.
		self.settlement:setAnimalsProvider(self.animals)
		self.animals:addListener(self.settlement, Settlement.onAnimalSale)
		self.offers:setAnimalsProvider(self.animals)

		-- Install the hook now so no sale can slip past, but seed the station snapshots
		-- later — selling stations are not all registered yet at this point.
		self.deliveryWatch:install()
		self.woodWatch:install()

		-- ⚠ INSTALLED HERE, WHICH IS BEFORE `contractStore:load()` IN `onFinishedLoading`.
		-- That ordering is deliberate and harmless: loading a savegame replays `plantTree` for
		-- every stored tree (`misc/TreePlantManager.lua:652`), and those replays are rejected
		-- by `PlantingWatch:onPlanted`'s own discriminators. There are also no contracts to
		-- credit yet at that point. Two independent reasons, and only one of them is ordering.
		self.plantingWatch:install()
		self.animals:install()
		self.feedLedger:install()
		self.contractStore:subscribe()
		self.offers:subscribe()

		self.console = Console.new(self)
		self.console:register()

		-- saveSavegame returns nothing (FSBaseMission.lua:2161-2169), so the return value
		-- Utils.appendedFunction discards does not matter here. Where it does matter,
		-- DeliveryWatch uses a return-preserving wrapper instead.
		FSBaseMission.saveSavegame = Utils.appendedFunction(
			FSBaseMission.saveSavegame, ForwardContracts.onSaveSavegame)

	end

	-- The board is client-side: it renders whatever state it can reach. In singleplayer
	-- server and client are the same process, so it sees everything. On a remote client
	-- it will sit empty until the network layer exists — empty, not broken.
	if g_currentMission:getIsClient() then
		self.ui = UI.new()
	end

	FSBaseMission.onFinishedLoading = Utils.appendedFunction(
		FSBaseMission.onFinishedLoading, ForwardContracts.onFinishedLoading)

	Logging.info("[ForwardContracts] v%s loaded from %s", self.VERSION, self.MOD_DIR)
end

--- Appended to FSBaseMission.onFinishedLoading — note this is NOT called with our mod as
--- self, so go through the global.
function ForwardContracts.onFinishedLoading()
	local mod = ForwardContracts
	if not mod.isEnabled then
		return
	end

	-- Install the menu page once the menu itself exists.
	if mod.ui ~= nil then
		mod.ui:install()
	end

	if mod.contractStore == nil then
		return
	end

	-- Clients and reputation must load BEFORE the board is built: offers are generated
	-- against reputation tiers and pick from the existing client roster.
	mod.clientRegistry:load()
	mod.reputation:load()
	mod.feedLedger:load()
	mod.contractStore:load()
	mod.deliveryWatch:seedSnapshots()

	-- Offers are deliberately not persisted. They lapse in three days anyway, and a board
	-- rebuilt at today's prices is more correct than one restored at last session's.
	for _, farm in ipairs(g_farmManager:getFarms()) do
		if farm.farmId ~= FarmManager.SPECTATOR_FARM_ID then
			mod.offers:refresh(farm.farmId)
		end
	end

	Logging.info("[ForwardContracts] %d contract(s), %d client(s) restored, board built",
		#mod.contractStore.contracts, #mod.clientRegistry.clients)

	mod.registerDeadwoodProvider()
end

-- ---------------------------------------------------------------------------
-- Deadwood Pointer bridge (optional, one-way)
--
-- When FS25_DeadwoodPointer is installed, its in-world markers can carry our contract stands
-- too: every tree PlantingWatch credited against a live forestry contract gets a marker labelled
-- with the species and the planting progress, so the player can find the stand they are growing
-- for the contract. Detection via g_modIsLoaded, reach via _G["FS25_DeadwoodPointer"] live
-- objects at call time — never a mirrored table, never a hard dependency: with the pointer
-- absent nothing here runs, and with us absent the pointer is unchanged.
-- ---------------------------------------------------------------------------

ForwardContracts.DWP_MOD = "FS25_DeadwoodPointer"

--- What the pointer should mark for us right now. Resolves everything through the live
--- ForwardContracts globals at call time, so after deleteMap it degrades to an empty list.
function ForwardContracts.collectContractTrees()
	local mod = ForwardContracts
	local store = mod.contractStore
	local watch = mod.plantingWatch
	if not mod.isEnabled or store == nil or watch == nil then
		return {}
	end

	local out = {}
	for _, contract in ipairs(store.contracts or {}) do
		if not contract.isComplete and contract.speciesName ~= nil then
			local label = string.format("%s %d/%d", contract.speciesName,
				contract.planted or 0, contract.plantingFloor or 0)
			for _, node in ipairs(watch:getPlantedNodes(contract.speciesName)) do
				out[#out + 1] = { node = node, label = label }
			end
		end
	end
	return out
end

--- Called from onFinishedLoading — the pointer registers its own state in loadMap, so by now its
--- registry exists if the mod does. pcall-guarded: a pointer API change costs the markers only.
function ForwardContracts.registerDeadwoodProvider()
	local mod = ForwardContracts
	if mod.dwpProviderRegistered then
		return
	end
	if g_modIsLoaded == nil or not g_modIsLoaded[mod.DWP_MOD] then
		return
	end

	local env = _G[mod.DWP_MOD]
	local pointer = env ~= nil and env.DeadwoodPointer or nil
	if pointer == nil or pointer.registerProvider == nil then
		return
	end

	local ok, registered = pcall(pointer.registerProvider, "forwardContracts",
		ForwardContracts.collectContractTrees)
	if ok and registered == true then
		mod.dwpProviderRegistered = true
		Logging.info("[ForwardContracts] Deadwood Pointer found; contract stand markers on")
	else
		Logging.warning("[ForwardContracts] Deadwood Pointer present but provider registration "
			.. "failed: %s", tostring(registered))
	end
end

function ForwardContracts.onSaveSavegame()
	local mod = ForwardContracts
	if not mod.isEnabled or mod.contractStore == nil then
		return
	end

	mod.contractStore:save()
	mod.clientRegistry:save()
	mod.reputation:save()
	mod.feedLedger:save()
end

function ForwardContracts:deleteMap()
	if self.contractStore ~= nil then
		self.contractStore:unsubscribe()
	end

	if self.offers ~= nil then
		self.offers:unsubscribe()
	end

	if self.ui ~= nil then
		self.ui:uninstall()
		self.ui = nil
	end

	if self.console ~= nil then
		self.console:unregister()
		self.console = nil
	end

	self.contractStore = nil
	self.deliveryWatch = nil
	self.woodWatch = nil
	self.plantingWatch = nil
	self.animals = nil
	self.settlement = nil
	self.offers = nil
	self.clientRegistry = nil
	self.reputation = nil
	self.feedLedger = nil

	-- Cleared so a later save load re-runs checkDependencies rather than trusting this one's.
	self.isEnabled = false
end

function ForwardContracts:update(dt) end
function ForwardContracts:draw() end
function ForwardContracts:mouseEvent(posX, posY, isDown, isUp, button) end
function ForwardContracts:keyEvent(unicode, sym, modifier, isDown) end

addModEventListener(ForwardContracts)
