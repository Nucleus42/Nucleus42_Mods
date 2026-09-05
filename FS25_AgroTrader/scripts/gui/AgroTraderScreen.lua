-- AgroTrader — the marketplace screen.
--
-- A standalone ScreenElement, opened from a button appended to the shop's bottom bar.
--
-- Drives the SAME Market:search the console commands do, with the same two-stage filter split:
-- machine filters (type, style, make) prune before any advert is generated; advert filters
-- (distance, hours, price) prune after. That is what keeps a broad search affordable.

AgroTraderScreen = {}

local AgroTraderScreen_mt = Class(AgroTraderScreen, ScreenElement)

AgroTraderScreen.GUI_NAME = "AgroTraderScreen"

-- Filter option values. Index 1 is always "no limit" so a fresh screen shows everything.
AgroTraderScreen.DISTANCE_OPTIONS = { nil, 50, 100, 200, 350 }
AgroTraderScreen.HOURS_OPTIONS = { nil, 50, 100, 200, 400 }
AgroTraderScreen.PRICE_OPTIONS = { nil, 5000, 25000, 100000, 250000, 500000 }

-- Above this, the list is truncated and the count says so. Generation is cheap (a whole-market
-- sweep of ~1,900 adverts measured at 28 ms), but a list nobody can scroll is not a feature.
AgroTraderScreen.MAX_ROWS = 400

function AgroTraderScreen.new(market, rarity)
	local self = ScreenElement.new(nil, AgroTraderScreen_mt)

	self.market = market
	self.rarity = rarity

	self.results = {}
	self.selected = nil

	-- Rebuilt on open, because the store can differ between saves.
	self.styleOptions = {}
	self.styleValues = {}
	self.makeOptions = {}

	self.returnScreenClass = nil

	return self
end

--- Load profiles and the screen itself.
---
--- ⚠ THERE IS NO modDesc HOOK FOR GUI PROFILES IN FS25. Grep scripts/mods.lua for `guiProfiles`
--- and you will find nothing — the only callers of g_gui:loadProfiles in the whole tree are
--- main.lua, two console commands, and the internal Precision Farming mod doing exactly this.
--- So a mod loads its own, guarded on g_gui existing.
function AgroTraderScreen.register(market, rarity)
	if g_gui == nil then
		return nil
	end

	-- g_gui outlives the save: register once per session, and on later save loads just point
	-- the existing screen at the new save's market and rarity.
	if AgroTraderScreen.instance ~= nil then
		AgroTraderScreen.instance.market = market
		AgroTraderScreen.instance.rarity = rarity
		return AgroTraderScreen.instance
	end

	g_gui:loadProfiles(AgroTrader.MOD_DIR .. "gui/guiProfiles.xml")

	local screen = AgroTraderScreen.new(market, rarity)
	-- For the atProbe console command: the live instance, so a probe can inspect the real
	-- elements rather than reasoning about what they ought to be.
	AgroTraderScreen.instance = screen
	-- isFrame = false: this is a screen, not a page inside somebody's tabbed menu
	-- (Gui.lua:198-204).
	g_gui:loadGui(AgroTrader.MOD_DIR .. "gui/AgroTraderScreen.xml",
		AgroTraderScreen.GUI_NAME, screen, false)

	return screen
end

-- ------------------------------------------------------------------- lifecycle

-- ⚠ THERE IS NO onCreate ON ScreenElement OR GuiElement. An earlier version defined one and
-- called `superClass().onCreate(self)`, which is a call to nil — and because the screen is built
-- during map load, that took the whole game down at 89%. ScreenElement's actual lifecycle is
-- onOpen (elements/ScreenElement.lua:14), onClose (:28) and initializeScreen (:22); GuiElement
-- adds only onOpen and onClose. If a hook is needed before first open, override initializeScreen.
-- Do not reintroduce onCreate here or in the screen XML.

function AgroTraderScreen:onOpen()
	AgroTraderScreen:superClass().onOpen(self)

	self:buildFilterOptions()
	self:refresh()

	self.resultsList:setDelegate(self)
	self.resultsList:reloadData()

	if self.balanceText ~= nil then
		self.balanceText:setText(g_i18n:formatMoney(g_currentMission:getMoney(), 0, true, true))
	end
end

function AgroTraderScreen:onClose()
	-- Adverts are derived, so there is nothing to release — dropping the references is enough.
	self.results = {}
	self.selected = nil

	AgroTraderScreen:superClass().onClose(self)
end

-- setReturnScreenClass is NOT defined here: ScreenElement already provides it
-- (elements/ScreenElement.lua:149) and it does exactly what ours did. Shadowing a base method
-- with an identical copy is how the two drift apart later.

-- --------------------------------------------------------------------- filters

--- The shop's own display title for a category name — "Combines" for "harvesters" — falling
--- back to the raw name for anything a mod declared without registering.
function AgroTraderScreen.getCategoryTitle(categoryName)
	local category = g_storeManager ~= nil
		and g_storeManager:getCategoryByName(categoryName) or nil
	if category ~= nil and category.title ~= nil and category.title ~= "" then
		return category.title
	end
	return categoryName
end

--- Populate the style and make cyclers from what the market can actually offer.
---
--- Derived from the live store rather than hard-coded, for the same reason the rarity model is:
--- a modded install has categories and brands nobody has ever seen, and a fixed list would show
--- styles that return nothing while hiding ones that would.
function AgroTraderScreen:buildFilterOptions()
	local wantVehicles = self:getWantVehicles()

	local styles, makes = {}, {}
	for _, storeItem in ipairs(g_storeManager:getItems()) do
		if self.rarity:getWeight(storeItem) > 0
			and Rarity.getIsMotorized(storeItem) == wantVehicles then

			local category = storeItem.categoryName
			if category ~= nil then
				styles[category] = true
			end

			local brand = storeItem.brandIndex ~= nil
				and g_brandManager:getBrandByIndex(storeItem.brandIndex) or nil
			if brand ~= nil and brand.title ~= nil and brand.name ~= "NONE" then
				makes[brand.title] = true
			end
		end
	end

	-- Two parallel arrays: what the player reads (the shop's own localized title — "Combines",
	-- not "HARVESTERS") and what the filter compares (the raw categoryName). Index-aligned, with
	-- slot 1 being "Any style" / nil. The split exists because two categories could in principle
	-- share a title, and the filter must never conflate them.
	self.styleOptions = { "Any style" }
	self.styleValues = { false }
	local sortedStyles = {}
	for category in pairs(styles) do
		table.insert(sortedStyles, {
			name = category,
			title = AgroTraderScreen.getCategoryTitle(category),
		})
	end
	table.sort(sortedStyles, function(a, b)
		if a.title == b.title then
			return a.name < b.name
		end
		return a.title < b.title
	end)
	for _, entry in ipairs(sortedStyles) do
		table.insert(self.styleOptions, entry.title)
		table.insert(self.styleValues, entry.name)
	end

	self.makeOptions = { "Any make" }
	for title in pairs(makes) do
		table.insert(self.makeOptions, title)
	end
	table.sort(self.makeOptions, function(a, b)
		if a == "Any make" then return true end
		if b == "Any make" then return false end
		return a < b
	end)

	-- ⚠ RESTORE BY NAME, NOT BY INDEX.
	--
	-- These two lists are rebuilt from the store on every open, and switching TYPE replaces them
	-- wholesale — 42 vehicle categories become 79 implement ones. So index 3 means a different
	-- style before and after, and simply leaving the state alone would silently select something
	-- the player never picked. Looking the remembered NAME back up survives that, and degrades
	-- correctly to "Any" when the old choice is not in the new list.
	--
	-- Note setTexts does NOT reset the state by itself — it clamps with
	-- `state = min(state, #texts)` (MultiTextOptionElement:setTexts). The earlier reset to 1 here
	-- was mine, and it was the whole reason Style and Make forgot themselves while Distance, Hours
	-- and Price did not: those three are only ever set in onCreateFilters, which runs once.
	self.filterStyle:setTexts(self.styleOptions)
	self.filterStyle:setState(AgroTraderScreen.indexOf(self.styleValues, self.rememberedStyle), false)

	self.filterMake:setTexts(self.makeOptions)
	self.filterMake:setState(AgroTraderScreen.indexOf(self.makeOptions, self.rememberedMake), false)
end

--- Position of `value` in `list`, or 1 — which is always the "Any ..." entry.
function AgroTraderScreen.indexOf(list, value)
	if value ~= nil then
		for index, entry in ipairs(list) do
			if entry == value then
				return index
			end
		end
	end
	return 1
end

function AgroTraderScreen:onCreateFilters()
	self.filterType:setTexts({ "Vehicles", "Attachments" })
	self.filterType:setState(1, false)

	self.filterDistance:setTexts({ "Any distance", "50 miles", "100 miles", "200 miles", "350 miles" })
	self.filterDistance:setState(1, false)

	self.filterHours:setTexts({ "Any hours", "50 hours", "100 hours", "200 hours", "400 hours" })
	self.filterHours:setState(1, false)

	self.filterPrice:setTexts({ "Any price", "5,000", "25,000", "100,000", "250,000", "500,000" })
	self.filterPrice:setState(1, false)
end

function AgroTraderScreen:getWantVehicles()
	return self.filterType == nil or self.filterType:getState() == 1
end

function AgroTraderScreen:onFilterChanged()
	-- Switching between vehicles and attachments changes which styles and makes exist at all, so
	-- those cyclers have to be rebuilt rather than merely re-read.
	local wantVehicles = self:getWantVehicles()
	if wantVehicles ~= self.lastWantVehicles then
		self.lastWantVehicles = wantVehicles
		self:buildFilterOptions()
	end

	self:refresh()
end

--- Reset is the ONLY thing that clears the remembered filters. Everything else — closing the
--- screen, looking at a machine, backing out of a purchase — leaves them exactly as the player
--- set them, which is the whole point of remembering.
function AgroTraderScreen:onClickReset()
	self.rememberedStyle = nil
	self.rememberedMake = nil

	self.filterType:setState(1, false)
	self.filterDistance:setState(1, false)
	self.filterHours:setState(1, false)
	self.filterPrice:setState(1, false)

	-- Style and Make are set inside buildFilterOptions, from the cleared remembered values.
	self:buildFilterOptions()
	self:refresh()
end

-- ---------------------------------------------------------------------- search

function AgroTraderScreen:refresh()
	local wantVehicles = self:getWantVehicles()

	local styleIndex = self.filterStyle:getState()
	-- styleValues, not styleOptions: the filter compares raw category names; the options array
	-- holds the localized titles the player reads.
	local style = styleIndex > 1 and self.styleValues[styleIndex] or nil

	local makeIndex = self.filterMake:getState()
	local make = makeIndex > 1 and self.makeOptions[makeIndex] or nil

	-- Remembered here rather than in the click handler, because this is the one place both values
	-- are already resolved from index to name — and it runs on every change. nil means "Any",
	-- which restores to index 1 on the next open.
	self.rememberedStyle = style
	self.rememberedMake = make

	local maxMiles = AgroTraderScreen.DISTANCE_OPTIONS[self.filterDistance:getState()]
	local maxHours = AgroTraderScreen.HOURS_OPTIONS[self.filterHours:getState()]
	local maxPrice = AgroTraderScreen.PRICE_OPTIONS[self.filterPrice:getState()]

	-- Stage one: properties of the machine. Cheap, and runs before anything is generated.
	local itemFilter = function(storeItem)
		if Rarity.getIsMotorized(storeItem) ~= wantVehicles then
			return false
		end
		if style ~= nil and storeItem.categoryName ~= style then
			return false
		end
		if make ~= nil then
			local brand = storeItem.brandIndex ~= nil
				and g_brandManager:getBrandByIndex(storeItem.brandIndex) or nil
			if brand == nil or brand.title ~= make then
				return false
			end
		end
		return true
	end

	-- Stage two: properties of the advert. Only meaningful once it exists.
	local listingFilter = nil
	if maxMiles ~= nil or maxHours ~= nil or maxPrice ~= nil then
		listingFilter = function(listing)
			if maxMiles ~= nil and listing.miles > maxMiles then
				return false
			end
			if maxHours ~= nil and listing.operatingTime / 3600000 > maxHours then
				return false
			end
			if maxPrice ~= nil and listing.price + listing.deliveryFee > maxPrice then
				return false
			end
			return true
		end
	end

	self.results = self.market:search(itemFilter, listingFilter)

	-- Cheapest first. Sorted AFTER the full search, never during it — capping mid-search would
	-- return an arbitrary slice in store order and a wider search could then lose adverts a
	-- narrower one had shown.
	table.sort(self.results, function(a, b)
		if a.price == b.price then
			return a.miles < b.miles
		end
		return a.price < b.price
	end)

	local found = #self.results
	local truncated = found > AgroTraderScreen.MAX_ROWS
	if truncated then
		for index = found, AgroTraderScreen.MAX_ROWS + 1, -1 do
			self.results[index] = nil
		end
	end

	if self.resultCountText ~= nil then
		-- The whole used market breathes with crop prices (Valuation.getMarketIndex). Saying so is
		-- what turns a dear month from "the mod is broken" into "wait for prices to soften".
		local index = Valuation.getMarketIndex()
		local mood = ""
		if index <= 0.96 then
			mood = " · prices soft — buyer's market"
		elseif index >= 1.04 then
			mood = " · prices firm — seller's market"
		end

		if found == 0 then
			self.resultCountText:setText("No machines match")
		elseif truncated then
			self.resultCountText:setText(string.format("%d found, showing the %d cheapest%s",
				found, AgroTraderScreen.MAX_ROWS, mood))
		else
			self.resultCountText:setText(string.format("%d machine%s for sale%s",
				found, found == 1 and "" or "s", mood))
		end
	end

	if self.emptyText ~= nil then
		self.emptyText:setVisible(found == 0)
		if found == 0 then
			self.emptyText:setText(
				"Nothing on the market matches. Try a wider radius, or fewer restrictions — " ..
				"and check back in a day or two, the market turns over.")
		end
	end

	self.resultsList:reloadData()
	self:setSelected(self.results[1])
end

-- ------------------------------------------------------------------ list delegate

function AgroTraderScreen:getNumberOfSections()
	return 1
end

function AgroTraderScreen:getNumberOfItemsInSection(list, section)
	return #self.results
end

function AgroTraderScreen:populateCellForItemInSection(list, section, index, cell)
	local listing = self.results[index]
	if listing == nil then
		return
	end

	local storeItem = listing.storeItem
	local brand = storeItem.brandIndex ~= nil
		and g_brandManager:getBrandByIndex(storeItem.brandIndex) or nil
	local brandTitle = (brand ~= nil and brand.title ~= nil) and brand.title or ""

	-- The "stock photo": the machine's own shop image. It shows the base model — a rolled custom
	-- spec appears in the View-and-buy 3D, exactly as a dealer's catalogue shot works.
	local image = cell:getAttribute("tileImage")
	if image ~= nil and storeItem.imageFilename ~= nil then
		-- A configuration item can carry its own store icon (config.vehicleIcon) — when the
		-- rolled spec has one, the "stock photo" really does show the machine advertised. Same
		-- lookup vanilla's contracts screen does (InGameMenuContractsFrame.lua:273-286).
		local imageFilename = storeItem.imageFilename
		if listing.configurations ~= nil and storeItem.configurations ~= nil then
			for configName, configId in pairs(listing.configurations) do
				local items = storeItem.configurations[configName]
				local config = items ~= nil and items[configId] or nil
				if config ~= nil and config.vehicleIcon ~= nil and config.vehicleIcon ~= "" then
					imageFilename = config.vehicleIcon
					break
				end
			end
		end

		image:setImageFilename(imageFilename)
		-- ⚠ THE ALPHA RESET IS NOT OPTIONAL. A swapped overlay can come back with alpha 0, and
		-- GuiOverlay.renderOverlay skips transparent overlays outright — the photo column
		-- renders as nothing with no error anywhere. Vanilla does exactly this pair of calls
		-- after every swap (InGameMenuContractsFrame.lua:288-289).
		image:setImageColor(nil, nil, nil, nil, 1)

		-- ⚠ AND THE UV RESET IS WHAT ACTUALLY SHOWS THE PHOTO. Found by the atProbe dump, not
		-- theory: a baseReference Bitmap gets its flat colour from a SLICE — a one-pixel patch of
		-- the UI atlas (overlay.sliceId "gui.colorPreset", uvs ~{0.6194, 0.9092, ...}) — and a
		-- filename swap keeps those sliver UVs, so the "photo" renders as one stretched pixel of
		-- itself: invisible against the tile. Base uvs cover every state here (the probe showed no
		-- per-state uvs on this overlay); the sliceId is cleared so nothing re-derives the sliver.
		image.overlay.sliceId = nil
		image.overlay.uvs = table.clone(Overlay.DEFAULT_UVS)
	end

	-- One line, once per session, so a blank photo column diagnoses itself from the log instead
	-- of costing another screenshot round-trip: which part is missing — the element, the
	-- filename, or the overlay the swap should have created.
	if not AgroTraderScreen.tileImageChecked then
		AgroTraderScreen.tileImageChecked = true
		if image == nil then
			Logging.warning("[AgroTrader] Tile has no 'tileImage' attribute — photo column dead.")
		elseif storeItem.imageFilename == nil then
			Logging.warning("[AgroTrader] '%s' has no store image.", tostring(storeItem.name))
		elseif image.overlay == nil or image.overlay.overlay == nil then
			Logging.warning("[AgroTrader] Tile image overlay failed to create for '%s'.",
				tostring(storeItem.imageFilename))
		else
			Logging.info("[AgroTrader] Tile images live (first: %s).",
				tostring(storeItem.imageFilename))
		end
	end

	cell:getAttribute("cellName"):setText(string.format("%s %s", brandTitle, storeItem.name or "?"))
	-- FSH is the abbreviation every real classified uses; "no history" is the warning every real
	-- buyer knows to read. Part history is the unremarkable middle and says nothing.
	local historyTag = ""
	if listing.serviceHistory == "full" then
		historyTag = " · FSH"
	elseif listing.serviceHistory == "none" then
		historyTag = " · no history"
	end
	cell:getAttribute("cellSub"):setText(string.format("%d hrs · %d%% damage%s",
		listing.operatingTime / 3600000, listing.damage * 100, historyTag))
	cell:getAttribute("cellPrice"):setText(g_i18n:formatMoney(listing.price, 0, true, true))
	cell:getAttribute("cellDistance"):setText(string.format("%d miles", listing.miles))
end

--- ⚠ getSelectedIndexInSection, NOT getSelectedElementIndex. The latter does not exist on
--- SmoothListElement and returns nil silently, so selection appears to do nothing.
function AgroTraderScreen:onListSelectionChanged(list, section, index)
	self:setSelected(self.results[index])
end

function AgroTraderScreen:onListDoubleClick()
	if self.selected ~= nil then
		self:onClickBuy()
	end
end

-- ---------------------------------------------------------------------- detail

--- Resize a bar's fill to a 0..1 fraction of its track.
---
--- setSize keeps the existing value for any nil argument (GuiElement.lua:setSize), so passing nil
--- for the height leaves it alone. Sizes and absSize are both in normalised screen units, so a
--- fraction of the parent's absSize is the right width.
---
--- Guarded on the parent chain because this runs from onOpen, and a missing element in the XML
--- would otherwise crash the screen rather than merely losing a bar.
local function setBar(fill, fraction)
	if fill == nil or fill.parent == nil or fill.parent.absSize == nil then
		return
	end
	fill:setSize(math.clamp(fraction, 0.02, 1) * fill.parent.absSize[1], nil)
end

function AgroTraderScreen:setSelected(listing)
	self.selected = listing

	local hasSelection = listing ~= nil
	self.detailPanel:setVisible(hasSelection)
	self.buyButton:setDisabled(not hasSelection)

	if not hasSelection then
		return
	end

	local storeItem = listing.storeItem
	local brand = storeItem.brandIndex ~= nil
		and g_brandManager:getBrandByIndex(storeItem.brandIndex) or nil

	self.detailName:setText(storeItem.name or "?")
	self.detailBrand:setText((brand ~= nil and brand.title or "") .. "  ·  "
		.. AgroTraderScreen.getCategoryTitle(storeItem.categoryName or ""))
	self.detailPrice:setText(g_i18n:formatMoney(listing.price, 0, true, true))

	self.detailStory:setText(AgroTraderScreen.getStory(listing))

	-- The options this machine was ordered with, when it deviates from stock — the reason one
	-- advert is dearer than the next for "the same" model. Stock machines show nothing.
	if self.detailSpec ~= nil then
		local options = Valuation.getNonStockOptions(storeItem, listing.configurations)
		if #options > 0 then
			self.detailSpec:setText("Spec: " .. table.concat(options, " · "))
		else
			self.detailSpec:setText("")
		end
	end

	self.detailHours:setText(string.format("%d hours", listing.operatingTime / 3600000))
	self.detailAge:setText(AgroTraderScreen.formatAge(listing.age))

	self.detailDamage:setText(string.format("%d%%", listing.damage * 100))
	self.detailPaint:setText(string.format("%d%%", listing.wear * 100))
	self.detailDirt:setText(string.format("%d%%", (1 - listing.dirt) * 100))

	-- Bars show CONDITION REMAINING, so a full green bar is a good machine — the opposite of the
	-- damage percentage next to it, which is why both are labelled.
	setBar(self.damageFill, 1 - listing.damage)
	setBar(self.paintFill, 1 - listing.wear)

	self.detailLocation:setText(string.format("%d miles", listing.miles))
	self.detailAsking:setText(g_i18n:formatMoney(listing.price, 0, true, true))
	self.detailDelivery:setText(g_i18n:formatMoney(listing.deliveryFee, 0, true, true))
	self.detailTotal:setText(g_i18n:formatMoney(listing.price + listing.deliveryFee, 0, true, true))
end

function AgroTraderScreen.formatAge(months)
	local years = math.floor(months / 12)
	local remainder = months % 12
	if years == 0 then
		return string.format("%d months", remainder)
	end
	if remainder == 0 then
		return string.format("%d year%s", years, years == 1 and "" or "s")
	end
	return string.format("%dy %dm", years, remainder)
end

--- The previous owner, as a line of flavour. Makes the hours figure read as a story rather than a
--- random number — which is what a real classified ad does.
function AgroTraderScreen.getStory(listing)
	local stories = {
		estate = "Came off a large estate with a big fleet — light work for its age.",
		family = "Owned by a mixed family farm. Steady, unremarkable use.",
		contractor = "Ex-contractor. Worked hard and it shows, but priced accordingly.",
	}
	local histories = {
		full = " Full main-dealer service history.",
		part = " Part service history.",
		none = " No service history — sold as seen.",
	}
	return (stories[listing.archetype] or "") .. (histories[listing.serviceHistory] or "")
end

-- --------------------------------------------------------------------- actions

function AgroTraderScreen:onClickBuy()
	if self.selected == nil then
		return
	end

	local listing = self.selected

	-- Hand off to the vanilla config screen. Purchase.begin sets up the shop controller so the
	-- whole downstream path — money, slots, spawn, plates — stays Giants' own.
	local ok, reason = Purchase.begin(listing)
	if not ok then
		InfoDialog.show(string.format("Cannot buy this machine: %s.", reason))
		return
	end

	-- ⚠ DO NOT CLOSE THIS SCREEN HERE.
	--
	-- Purchase.begin has ALREADY changed the screen: buyVehicle fires the shop's
	-- switchToConfigurationCallback, which is ShopMenu:showConfigurationScreen, which calls
	-- changeScreen(ShopConfigScreen) itself (ShopMenu.lua:376-387). An earlier version called
	-- onClickBack() straight afterwards, which immediately changed screen AGAIN — to the shop —
	-- so clicking Buy appeared to do nothing but dump the player back on the shop page. The
	-- config screen had opened and been thrown away in the same frame.
	--
	-- Send them back HERE rather than to the shop when they finish with it, so backing out of a
	-- purchase returns to the marketplace they were browsing. The screen re-reads the market on
	-- open, so a bought advert is gone by the time they see it again.
	if g_shopConfigScreen ~= nil then
		g_shopConfigScreen:setReturnScreenClass(AgroTraderScreen)
	end
end

--- ⚠ FORCE THE BACK. ScreenElement:onClickBack only acts when `self.isBackAllowed or forceBack`
--- is true (elements/ScreenElement.lua:61-68), and isBackAllowed comes from the screen XML — so
--- without the flag a Back button can silently do nothing. Passing forceBack keeps the base
--- class's own returnScreenClass handling rather than reimplementing it.
function AgroTraderScreen:onClickBack()
	if self.returnScreenClass ~= nil then
		return AgroTraderScreen:superClass().onClickBack(self, true)
	end

	-- Nothing to return to — close the menu entirely. changeScreen(nil, nil) is the sanctioned
	-- way (base/Gui.lua:644): a nil screenClass skips the lookup and clears currentGui.
	g_gui:changeScreen(nil, nil)
	return false
end
