-- AgroTrader — buying.
--
-- Hands an advert to the VANILLA config screen and the vanilla purchase path, so money, slots,
-- spawn placement, licence plates and multiplayer all keep working exactly as Giants wrote them.
-- We change two things and nothing else: the configuration controls are suppressed, and dirt is
-- applied on top of the damage and wear vanilla already handles.
--
-- Route in (all verified in 1.21 source):
--   g_shopController:buyVehicle(storeItem, saleItem, price, false, nil)   ShopController.lua:809
--     -> switchToConfigurationCallback                                    ShopController.lua:818
--     -> ShopMenu:showConfigurationScreen                                 ShopMenu.lua:376
--          changeScreen, setStoreItem, setCallbacks
--   [player clicks Buy]  -> onClickBuy -> YesNoDialog -> onYesNoBuy
--     -> ShopConfigScreen:onCallback                                      ShopConfigScreen.lua:~1900
--          builds BuyVehicleData with our saleItem and totalPrice
--     -> ShopMenu:setConfigurations -> g_shopController:setConfigurations
--     -> BuyVehicleData:buy -> VehicleLoadingData                         BuyVehicleData.lua:101
--
-- ⚠ Those callbacks are wired by ShopMenu:initializePages, called from
-- ShopMenu:onLoadMapFinished (ShopMenu.lua:86-87) — i.e. at map load, NOT when the shop is first
-- opened. That is what makes it safe to buy without ever having opened the shop.

Purchase = {}

--- Marks a sale item as ours. Vanilla sale items never carry this, so every hook below can tell
--- our adverts from the base game's five used-vehicle slots and leave those completely alone.
Purchase.MARKER = "agroTraderKey"

local market = nil

function Purchase.setMarket(marketInstance)
	market = marketInstance
end

--- The machine's factory specification, in the shape vanilla's `boughtConfigurations` uses:
--- `{ [configName] = { [index] = true } }`.
---
--- Built from `storeItem.defaultConfigurationIds`, which is exactly the set ShopConfigScreen puts
--- into `self.configurations` for a sale item (ShopConfigScreen.lua:934-957) — and `getBuyPrice`
--- iterates that same table, so the two line up entry for entry and nothing is left to be charged
--- as an upgrade.
---
--- Note the config-SET application that vanilla would normally do afterwards
--- (ShopConfigScreen.lua:1287-1289) never runs for our adverts, because the suppression below
--- takes the no-configurations branch. So the defaults really are the whole picture.
function Purchase.getFactoryConfiguration(storeItem)
	local bought = {}
	if storeItem == nil or storeItem.defaultConfigurationIds == nil then
		return bought
	end
	for name, index in pairs(storeItem.defaultConfigurationIds) do
		bought[name] = { [index] = true }
	end
	return bought
end

--- Convert one advert into the shape the vanilla purchase path expects.
---
--- Vanilla reads exactly these fields: `age` and `operatingTime` are copied onto the spawned
--- vehicle (VehicleLoadingData.lua:482-486); `damage` and `wear` are applied by
--- Wearable:onSaleItemSet (Wearable.lua:110-113); `price` is what EconomyManager:getBuyPrice
--- charges (EconomyManager.lua:398-400).
function Purchase.toSaleItem(listing)
	return {
		-- ⚠ DELIVERY IS FOLDED INTO THE PRICE. The config screen derives its total from
		-- saleItem.price alone, so this is the only way to charge for haulage without
		-- reimplementing the pricing panel. The finished screen will show the two as separate
		-- lines before the player ever gets here — as the vehicle-dealer placeable already does
		-- (VehicleShopDialog.lua:82-85) — but the amount taken is the same either way.
		price = listing.price + listing.deliveryFee,

		age = listing.age,
		operatingTime = listing.operatingTime,
		damage = listing.damage,
		wear = listing.wear,

		-- ⚠ MUST LIST THE MACHINE'S OWN CONFIGURATION. NEITHER NIL NOR EMPTY WILL DO.
		--
		-- This field decides what the player is charged for on top of the advert, and it has bitten
		-- twice for opposite reasons:
		--
		--   nil   -> EconomyManager:getBuyPrice indexes it without a guard the moment a saleItem is
		--            present (`saleItem.boughtConfigurations[name]`), crashing with the name of
		--            whichever configuration it reached first — "attempt to index nil with
		--            'fillUnit'" on a Zetor, naming a field the mod never set.
		--   {}    -> nothing counts as already-owned, so getBuyPrice charges for EVERY default
		--            configuration as though it were an upgrade. A Landini REX 4 GT advertised at
		--            £1,360 cost £4,360, because its default attacherJointConfiguration is priced
		--            at £3,000 (seriesREX4.xml:182). Found by the user checking their balance —
		--            nothing on screen showed it.
		--
		-- Correct is to declare the machine's factory specification as already bought, which is
		-- what bought-as-seen means: the machine comes WITH its configuration, and the player is
		-- buying a machine, not a machine plus options.
		boughtConfigurations = Purchase.getFactoryConfiguration(listing.storeItem),

		-- Ours, and invisible to vanilla. Wearable does not know about dirt, so we apply it
		-- ourselves in the hook below.
		dirt = listing.dirt,
		[Purchase.MARKER] = listing.key,

		-- ⚠ MULTIPLAYER. BuyVehicleData streams the sale id as UInt8 with 0 meaning "no sale item"
		-- (BuyVehicleData.lua:84, 96-98). Adverts are derived, not pooled, so they have no numeric
		-- id — MP needs the key streamed as a string instead. modDesc declares MP unsupported
		-- until that is written.
		id = 0,
	}
end

--- Is this one of ours?
function Purchase.getIsOurs(saleItem)
	return saleItem ~= nil and saleItem[Purchase.MARKER] ~= nil
end

-- --------------------------------------------------------------------- the hooks

--- Bought as seen: no configuring, no respraying, no swapping the wheels.
---
--- ⚠ THE TRICK IS TO MAKE A CONFIGURABLE MACHINE TAKE THE PATH AN UNCONFIGURABLE ONE ALREADY
--- TAKES. Giants' own `else` branch for an item with no configurations does precisely what we
--- want (ShopConfigScreen.lua:1306-1309):
---
---     table.insert(self.configSelection.options, {})
---     self.displayableColorCount = 0
---
--- and `updateConfigOptionsData` then hides the whole panel — title, clippers, slider — because
--- its displayable-option count comes out zero (ShopConfigScreen.lua:1636-1639).
---
--- So rather than hand-building that state afterwards, we hide the item's configurations for the
--- duration of the call and let Giants take their own branch. Building the colour pickers and
--- then discarding the table would leave their GUI elements parented and orphaned; this way they
--- are never created.
---
--- `self.configurations` is set by setStoreItem BEFORE this runs (ShopConfigScreen.lua:934-957),
--- merging the item's defaults with the sale item's bought configurations, and we do not touch
--- it — so the machine still loads as the specific machine advertised.
function Purchase.processStoreItemConfigurations(self, superFunc, storeItem, vehicle, saleItem)
	if not Purchase.getIsOurs(saleItem) then
		return superFunc(self, storeItem, vehicle, saleItem)
	end

	-- Restore even if the call throws: this field is shared mutable state on the store manager's
	-- own item, and leaving it nil would break the shop for the rest of the session.
	local saved = storeItem.configurations
	storeItem.configurations = nil

	local ok, err = pcall(superFunc, self, storeItem, vehicle, saleItem)

	storeItem.configurations = saved

	if not ok then
		Logging.error("[AgroTrader] Config suppression failed: %s", tostring(err))
	end
end

--- Bought as seen extends to the number plate.
---
--- The plate row is built separately from the configurations, so suppressing the configuration
--- list leaves it behind — which produced a panel headed CONFIGURATIONS containing nothing but
--- LICENSE PLATE, rather undercutting the point. Its gate is (ShopConfigScreen.lua:1614):
---
---     if storeItem.hasLicensePlates and g_licensePlateManager:getAreLicensePlatesAvailable()
---
--- so the same trick works: hide the field for the duration of the call and Giants skip the row
--- themselves. With nothing else left to show, the displayable-option count reaches zero and the
--- whole panel hides.
---
--- ⚠ THIS SUPPRESSES THE EDITOR, NOT THE PLATE. `hasLicensePlates` is restored immediately, and
--- the machine is still given plates at spawn from `self.licensePlateData` — which is what you
--- want for a second-hand machine. It turns up wearing whatever plate it came with; the player
--- simply does not get to choose it in the advert.
function Purchase.updateConfigOptionsData(self, superFunc, storeItem, vehicle, saleItem)
	if not Purchase.getIsOurs(saleItem) then
		return superFunc(self, storeItem, vehicle, saleItem)
	end

	local saved = storeItem.hasLicensePlates
	storeItem.hasLicensePlates = false

	local ok, result = pcall(superFunc, self, storeItem, vehicle, saleItem)

	storeItem.hasLicensePlates = saved

	if not ok then
		Logging.error("[AgroTrader] Plate suppression failed: %s", tostring(result))
		return 0
	end
	return result
end

--- Dirt, which vanilla sale items do not carry.
---
--- Appended to the same hook that applies damage and wear (Wearable.lua:110-113) so a delivered
--- machine arrives looking its age. Guarded because Washable and Wearable are SEPARATE
--- specialisations — a vehicle can have one without the other, and ShopConfigScreen guards the
--- identical call the same way (ShopConfigScreen.lua:760-763).
function Purchase.onSaleItemSet(self, saleItem)
	if not Purchase.getIsOurs(saleItem) or saleItem.dirt == nil then
		return
	end
	if self.setDirtAmount == nil then
		return
	end
	self:setDirtAmount(saleItem.dirt)
end

--- Take the advert off the market once the money has actually changed hands.
---
--- Appended to BuyVehicleData:onBought, which is where vanilla debits the player and retires its
--- own sale item (BuyVehicleData.lua:112-137). Doing it here rather than at the click means a
--- failed spawn or a cancelled dialog leaves the advert standing.
---
--- Vanilla will also call vehicleSaleSystem:onVehicleBought with our sale item. That is harmless:
--- removeSale looks the item up in its own list, does not find it, and returns
--- (VehicleSaleSystem.lua:322-334).
function Purchase.onBought(self, vehicles, loadingState)
	if market == nil or not Purchase.getIsOurs(self.saleItem) then
		return
	end
	if loadingState ~= VehicleLoadingState.OK then
		return
	end

	market:markPurchased({
		key = self.saleItem[Purchase.MARKER],
		period = self.saleItem.agroTraderPeriod or 0,
	})
end

-- ------------------------------------------------------------------- delivery
--
-- The machine is DELIVERED — it turns up where the player is, not at the dealership. That is what
-- the haulage fee is for, and until now the fee bought nothing visible.
--
-- Vanilla spawns into `g_currentMission.storeSpawnPlaces`, a list of place records loaded from the
-- map's i3d (PlacementUtil.loadPlaceFromNode). BuyVehicleData:buy takes that list as its first
-- argument (BuyVehicleData.lua:101-106) and PlaceableVehicleBuyingStation proves a non-shop source
-- is fine — it passes its own (PlaceableVehicleBuyingStation.lua:189).
--
-- ⚠ THE PLACE IS BUILT BY loadPlaceFromNode FROM TWO REAL TRANSFORM NODES, NOT HAND-ASSEMBLED.
-- A place carries a dozen coupled fields — startX/Y/Z, width, dirX/Y/Z, dirPerpX/Y/Z, rotX/Y/Z,
-- yOffset, max* — and getPlace uses nearly all of them together (PlacementUtil.lua:5-33). Filling
-- them in by hand means re-deriving Giants' own basis maths and getting the machine's facing
-- subtly wrong. Positioning two nodes and letting their function do the rest cannot drift.

-- Metres in front of the player the delivery bay sits, and how wide it is. The bay is a line the
-- spawner walks along looking for a clear spot, so width is really "how many machines could line
-- up here" — generous, because a blocked bay means the purchase silently fails.
Purchase.DELIVERY_DISTANCE = 9
Purchase.DELIVERY_BAY_WIDTH = 26

local deliveryStartNode, deliveryEndNode = nil, nil

--- Where the player actually is.
---
--- Fallback chain lifted from FS25_NucleusCommand's Summon, which is proven in play: the camera
--- node is the most reliable, graphicsRootNode next, rootNode last. `g_currentMission.player` and
--- `g_localPlayer` are both checked because which one is populated varies.
local function getPlayerNode()
	local player = (g_currentMission ~= nil and g_currentMission.player) or g_localPlayer
	if player == nil then
		return nil
	end
	if player.camera ~= nil and player.camera.cameraNode ~= nil then
		return player.camera.cameraNode
	end
	if player.graphicsComponent ~= nil and player.graphicsComponent.graphicsRootNode ~= nil then
		return player.graphicsComponent.graphicsRootNode
	end
	return player.rootNode
end

--- A one-entry place list: a delivery bay laid across the player's view, a few metres ahead.
---
--- Returns nil if the player cannot be located, and the caller then falls back to the dealership —
--- a machine delivered to the wrong place is a bug, a machine at the shop is merely disappointing.
--- Where the buying player is, as plain numbers.
---
--- ⚠ CAPTURED ON THE CLIENT, AT THE MOMENT OF BUYING. The server cannot work this out: a
--- dedicated server has no local player at all, and with several connected there is no such thing
--- as "the" player. So it is read here, where the buyer IS the local player, and streamed with the
--- purchase.
function Purchase.captureDeliveryOrigin()
	local node = getPlayerNode()
	if node == nil or node == 0 then
		return nil
	end

	local px, _, pz = getWorldTranslation(node)
	local fx, _, fz = localDirectionToWorld(node, 0, 0, 1)
	if px == nil or fx == nil then
		return nil
	end

	return { x = px, z = pz, dirX = fx, dirZ = fz }
end

--- Build the bay from an explicit origin rather than from whoever happens to be local.
function Purchase.getDeliveryPlaces(origin)
	if origin == nil then
		-- Singleplayer, or a listen-server host buying for themselves.
		origin = Purchase.captureDeliveryOrigin()
	end
	if origin == nil then
		return nil
	end

	local px, pz = origin.x, origin.z
	local fx, fz = origin.dirX, origin.dirZ

	-- Right-hand vector on the ground plane, from the facing. Derived rather than read off a node
	-- because on the server there is no node to read — but it is the same basis
	-- localDirectionToWorld(node, 1, 0, 0) would have given.
	local rx, rz = fz, -fx

	local half = Purchase.DELIVERY_BAY_WIDTH * 0.5
	local cx = px + fx * Purchase.DELIVERY_DISTANCE
	local cz = pz + fz * Purchase.DELIVERY_DISTANCE

	local sx, sz = cx - rx * half, cz - rz * half
	local ex, ez = cx + rx * half, cz + rz * half

	-- Created once and moved thereafter. Creating a pair per purchase would leak transform groups
	-- for the life of the session.
	if deliveryStartNode == nil then
		deliveryStartNode = createTransformGroup("agroTraderDeliveryStart")
		deliveryEndNode = createTransformGroup("agroTraderDeliveryEnd")
		link(getRootNode(), deliveryStartNode)
		link(getRootNode(), deliveryEndNode)
	end

	setWorldTranslation(deliveryStartNode, sx,
		getTerrainHeightAtWorldPos(g_terrainNode, sx, 300, sz), sz)
	setWorldTranslation(deliveryEndNode, ex,
		getTerrainHeightAtWorldPos(g_terrainNode, ex, 300, ez), ez)

	-- start -> end runs left to right across the player's view. loadPlaceFromNode aims the start
	-- node along that line and then rotates it -90 degrees about Y, which leaves the place's
	-- "perpendicular" — the direction the delivered machine faces — pointing the same way the
	-- player is. So it arrives ready to drive away rather than nose-on. Swap the two nodes to have
	-- them face the player instead.
	local place = PlacementUtil.loadPlaceFromNode(deliveryStartNode, deliveryEndNode, false)
	if place == nil then
		return nil
	end

	return { place }
end

--- Substitute the delivery bay for the dealership's spawn points, for our adverts only.
---
--- Hooked at BuyVehicleData:buy rather than further down, because this is the last point where the
--- places are still an argument — VehicleLoadingData has already consumed them by the next call.
--- A fresh `usedPlaces` table is passed since ours is a fresh bay each time.
function Purchase.buy(self, superFunc, storePlaces, usedStorePlaces, callback, callbackTarget, callbackArguments)
	if Purchase.getIsOurs(self.saleItem) then
		-- agroTraderDelivery is set on the client at Purchase.begin and arrives over the wire in
		-- multiplayer; in singleplayer the same field is already on the table by reference.
		local places = Purchase.getDeliveryPlaces(self.saleItem.agroTraderDelivery)
		if places ~= nil then
			return superFunc(self, places, {}, callback, callbackTarget, callbackArguments)
		end
		Logging.warning(
			"[AgroTrader] Could not locate the player; delivering to the dealership instead.")
	end

	return superFunc(self, storePlaces, usedStorePlaces, callback, callbackTarget, callbackArguments)
end

-- --------------------------------------------------------------- the wire

--- Send our advert alongside vanilla's sale-item byte.
---
--- ⚠ THIS IS WHY MULTIPLAYER WAS OFF. BuyVehicleData streams a sale item as a single UInt8 — its
--- id — which the far side looks up in vanilla's own vehicleSaleSystem. Our adverts are derived,
--- have no numeric id, and are not in that system, so we stream 0, which is the sentinel for
--- "no sale item". The server then resolves saleItem to nil, updatePrice charges FULL LIST PRICE,
--- and the machine spawns brand new with no hours, damage or wear — while the advert stays on the
--- market. Roughly 29x the advertised price, silently.
---
--- Singleplayer never showed it because a local connection runs the event without serialising, so
--- the table survives by reference.
---
--- Appended AFTER vanilla's own payload, never in place of it, so vanilla's used sales are
--- untouched and a stream we did not write still parses.
function Purchase.writeStream(self, superFunc, streamId, connection)
	superFunc(self, streamId, connection)

	local key = Purchase.getIsOurs(self.saleItem) and self.saleItem[Purchase.MARKER] or nil
	streamWriteBool(streamId, key ~= nil)

	if key ~= nil then
		streamWriteString(streamId, key)

		-- Where the buyer is standing, so the server can deliver to THEM. It cannot work this out
		-- itself: on a dedicated server there is no local player, and with several connected there
		-- is no such thing as "the" player. Captured at Purchase.begin, not now, so it is where
		-- they were when they chose to buy.
		local delivery = self.saleItem.agroTraderDelivery
		streamWriteBool(streamId, delivery ~= nil)
		if delivery ~= nil then
			streamWriteFloat32(streamId, delivery.x)
			streamWriteFloat32(streamId, delivery.z)
			streamWriteFloat32(streamId, delivery.dirX)
			streamWriteFloat32(streamId, delivery.dirZ)
		end
	end
end

--- Rebuild our advert on the far side — from the SERVER'S market, never from the wire.
---
--- Only the key crosses. `Market:getListingByKey` regenerates the advert from the server's own
--- salt and clock and refuses anything that is not a real, current, unsold advert, so a modified
--- client cannot invent a zero-hours machine at scrap price.
---
--- ⚠ A KEY THAT DOES NOT RESOLVE MUST LEAVE saleItem nil AND BE REFUSED LATER. Do not "helpfully"
--- fall through — a nil sale item is exactly the full-price-brand-new-machine bug above.
function Purchase.readStream(self, superFunc, streamId, connection)
	superFunc(self, streamId, connection)

	if not streamReadBool(streamId) then
		return
	end

	local key = streamReadString(streamId)

	local delivery = nil
	if streamReadBool(streamId) then
		delivery = {
			x = streamReadFloat32(streamId),
			z = streamReadFloat32(streamId),
			dirX = streamReadFloat32(streamId),
			dirZ = streamReadFloat32(streamId),
		}
	end

	-- ⚠ ONLY RESOLVE WHEN WE ARE THE SERVER RECEIVING FROM A CLIENT.
	--
	-- The same BuyVehicleData travels back the other way too — the server echoes it to the buyer
	-- with a result code (BuyVehicleEvent.newServerToClient). By then the advert is marked sold, so
	-- a client re-resolving its own purchase would get nil, log a refusal for a purchase that
	-- SUCCEEDED, and flag a throwaway object as rejected. Every read must still consume the same
	-- bytes, which is why the guard sits here and not around the reads above.
	--
	-- connection:getIsServer() is true when the connection points AT the server, i.e. we are the
	-- client — the same test BuyVehicleEvent:readStream uses to tell the directions apart.
	if connection:getIsServer() then
		return
	end

	local market = AgroTrader ~= nil and AgroTrader.market or nil
	if market == nil then
		Logging.error("[AgroTrader] Purchase arrived with no market to resolve it against.")
		return
	end

	local listing = market:getListingByKey(key)
	if listing == nil then
		-- Already sold, stale period, or fabricated. Flagged so BuyVehicleEvent refuses it.
		Logging.warning("[AgroTrader] Refusing purchase: advert '%s' is not on the market.", key)
		self.agroTraderRejected = true
		return
	end

	self.saleItem = Purchase.toSaleItem(listing)
	self.saleItem.agroTraderDelivery = delivery
end

--- Refuse a purchase whose advert did not resolve.
---
--- isValid is the hook vanilla already consults before charging anyone (BuyVehicleEvent:run), and
--- failing it produces STATE_FAILED_TO_LOAD — an error the player actually sees, rather than a
--- silent full-price sale.
function Purchase.isValid(self, superFunc)
	if self.agroTraderRejected then
		return false
	end
	return superFunc(self)
end

function Purchase.install()
	ShopConfigScreen.processStoreItemConfigurations = Utils.overwrittenFunction(
		ShopConfigScreen.processStoreItemConfigurations, Purchase.processStoreItemConfigurations)

	ShopConfigScreen.updateConfigOptionsData = Utils.overwrittenFunction(
		ShopConfigScreen.updateConfigOptionsData, Purchase.updateConfigOptionsData)

	Wearable.onSaleItemSet = Utils.appendedFunction(
		Wearable.onSaleItemSet, Purchase.onSaleItemSet)

	BuyVehicleData.onBought = Utils.appendedFunction(
		BuyVehicleData.onBought, Purchase.onBought)

	BuyVehicleData.buy = Utils.overwrittenFunction(
		BuyVehicleData.buy, Purchase.buy)

	BuyVehicleData.writeStream = Utils.overwrittenFunction(
		BuyVehicleData.writeStream, Purchase.writeStream)

	BuyVehicleData.readStream = Utils.overwrittenFunction(
		BuyVehicleData.readStream, Purchase.readStream)

	BuyVehicleData.isValid = Utils.overwrittenFunction(
		BuyVehicleData.isValid, Purchase.isValid)
end

-- ------------------------------------------------------------------- the front door

--- Put an advert in front of the player, exactly as the shop would.
---
--- Returns false and a reason rather than throwing, because the caller is a console command today
--- and a GUI button tomorrow, and both want to say something useful.
function Purchase.begin(listing)
	if listing == nil or listing.storeItem == nil then
		return false, "no such listing"
	end

	if g_shopController == nil or g_shopController.switchToConfigurationCallback == nil then
		-- Only possible if the shop menu has not finished loading, which should not happen once
		-- the map is in. Fail loudly rather than silently doing nothing.
		return false, "the shop is not ready yet"
	end

	-- Same guard the shop applies before opening the config screen (ShopMenu.lua:377-380).
	if g_currentMission.slotSystem ~= nil
		and not g_currentMission.slotSystem:hasEnoughSlots(listing.storeItem) then
		return false, "not enough slots on this farm"
	end

	local saleItem = Purchase.toSaleItem(listing)
	saleItem.agroTraderPeriod = listing.period

	-- Captured HERE, on the buying client, while the local player really is the buyer. Streamed
	-- with the purchase so a dedicated server can deliver to the right person.
	saleItem.agroTraderDelivery = Purchase.captureDeliveryOrigin()

	g_shopController:buyVehicle(listing.storeItem, saleItem, saleItem.price, false, nil)
	return true
end
