-- AgroTrader
-- Entry point. See README.md for the design and the research behind it.

AgroTrader = {}

AgroTrader.MOD_NAME = g_currentModName
AgroTrader.MOD_DIR = g_currentModDirectory
-- Printed to the log on load. Keep in step with <version> in modDesc.xml — a tester reading the
-- log against the mod list is exactly who notices when these disagree.
AgroTrader.VERSION = "1.0.0.0"

-- Order matters: Market reads constants off Valuation and Rarity at call time, and Market
-- registers its own MessageType at source time.
source(AgroTrader.MOD_DIR .. "scripts/Rarity.lua")
source(AgroTrader.MOD_DIR .. "scripts/Valuation.lua")
source(AgroTrader.MOD_DIR .. "scripts/Market.lua")
-- ⚠ EVENT CLASSES MUST BE REGISTERED AT COMPILE TIME. InitEventClass refuses to run once
-- g_currentMission exists (network/EventIds.lua:11-21), so these are sourced here at load rather
-- than created later — a late registration fails silently and every send is a no-op.
source(AgroTrader.MOD_DIR .. "scripts/events/AgroTraderStateEvent.lua")
source(AgroTrader.MOD_DIR .. "scripts/events/AgroTraderSoldEvent.lua")

source(AgroTrader.MOD_DIR .. "scripts/Purchase.lua")
source(AgroTrader.MOD_DIR .. "scripts/gui/AgroTraderScreen.lua")
source(AgroTrader.MOD_DIR .. "scripts/ShopHook.lua")
source(AgroTrader.MOD_DIR .. "scripts/Console.lua")

function AgroTrader:loadMap(name)
	-- ⚠ RARITY AND MARKET ARE BUILT ON BOTH SIDES, ON PURPOSE.
	--
	-- Both are DERIVED, so a client can reconstruct them without being told: rarity walks
	-- g_storeManager, which is identical everywhere, and the market is a pure function of
	-- (salt, machine, period, index). Give a client the salt and it produces the same ~1,900
	-- adverts the server has, advert for advert.
	--
	-- So the only thing that crosses the wire is the salt and the set of adverts already sold.
	-- Building these server-only was the bug: the screen is created under getIsClient and would
	-- have opened against a nil market on every joining player.
	self.rarity = Rarity.new()
	self.market = Market.new(self.rarity)

	Purchase.setMarket(self.market)

	-- Genuinely server-only: the savegame is the server's, and the console commands read and
	-- mutate authoritative state.
	if g_currentMission:getIsServer() then
		self.console = Console.new(self)
		self.console:register()

		-- saveSavegame returns nothing (FSBaseMission.lua:2161-2169), so the return value
		-- Utils.appendedFunction discards does not matter here.
		FSBaseMission.saveSavegame = Utils.appendedFunction(
			FSBaseMission.saveSavegame, AgroTrader.onSaveSavegame)

		-- Hand the joining client the salt and the sold set. Appended so every base-game system
		-- that syncs here keeps doing so (FSBaseMission.lua:754-773).
		FSBaseMission.sendInitialClientState = Utils.appendedFunction(
			FSBaseMission.sendInitialClientState, AgroTrader.onSendInitialClientState)
	end

	-- Outside the isServer block on purpose: these patch the config SCREEN and the vehicle spawn
	-- path, both of which are client-side work. Installed once, and only once — Utils
	-- .overwrittenFunction stacks, so calling this twice would run the suppression twice.
	Purchase.install()

	FSBaseMission.onFinishedLoading = Utils.appendedFunction(
		FSBaseMission.onFinishedLoading, AgroTrader.onFinishedLoading)

	Logging.info("[AgroTrader] v%s loaded from %s", self.VERSION, self.MOD_DIR)
end

--- Appended to FSBaseMission.onFinishedLoading — note this is NOT called with our mod as self,
--- so go through the global.
---
--- ⚠ THE RARITY BUILD MUST NOT RUN EARLIER THAN THIS. It walks g_storeManager:getItems(), and
--- map- and mod-supplied store items are still being registered during loadMap
--- (shop/StoreManager.lua:108-119 loads them from the map and from mods). Building at loadMap
--- would silently produce a table missing exactly the modded machines the derivation exists to
--- classify — and it would look like it worked.
---
--- The market must load AFTER rarity for the same reason: how many adverts a machine attracts is
--- read straight off its rarity weight, and an empty weight table would silently produce an empty
--- marketplace that looked like it was working.
function AgroTrader.onFinishedLoading()
	local mod = AgroTrader
	if mod.rarity == nil then
		return
	end

	mod.rarity:build()

	-- ⚠ ONLY THE SERVER READS THE SAVEGAME. A client's salt arrives over the wire via
	-- AgroTraderStateEvent; calling load() there would roll a fresh random salt and give that
	-- player a market nobody else can see — every advert different, every purchase refused.
	if g_currentMission:getIsServer() then
		mod.market:load()
	end

	-- The screen and its shop button go in last, because the screen's filters are built from the
	-- rarity weights and the market it will search. Installing earlier would give a marketplace
	-- that opens and shows nothing.
	if g_currentMission:getIsClient() then
		ShopHook.install(mod.market, mod.rarity)
	end
end

--- Appended to FSBaseMission:sendInitialClientState, so it is called with the MISSION as self.
--- Hands the joining client the two pieces of state it cannot derive.
function AgroTrader.onSendInitialClientState(mission, connection, user, farm)
	local mod = AgroTrader
	if mod.market == nil or connection == nil then
		return
	end

	connection:sendEvent(AgroTraderStateEvent.new(mod.market.salt, mod.market.purchased))
end

function AgroTrader.onSaveSavegame()
	local mod = AgroTrader
	if mod.market ~= nil then
		mod.market:save()
	end
end

function AgroTrader:deleteMap()
	-- The market subscribes to nothing and ticks on nothing — adverts are derived on demand, so
	-- there is no pool to tear down. Dropping the reference is the whole of it.
	self.market = nil

	if self.console ~= nil then
		self.console:unregister()
		self.console = nil
	end

	self.rarity = nil
end

function AgroTrader:update(dt) end
function AgroTrader:draw() end
function AgroTrader:mouseEvent(posX, posY, isDown, isUp, button) end
function AgroTrader:keyEvent(unicode, sym, modifier, isDown) end

addModEventListener(AgroTrader)
