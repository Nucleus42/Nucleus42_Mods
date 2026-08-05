-- AgroTrader — the way in.
--
-- Adds an AgroTrader button to the shop menu's bottom bar.
--
-- ⚠ DELIBERATELY A BUTTON, NOT A TAB. Injecting a page into ShopMenu is possible — it is what
-- FS25_ForwardContracts does to the ESC menu — but TabbedMenu:addPage is unusable from a mod:
-- it registers the frame's first CHILD as the page element while rebuildTabList looks the page up
-- by the FRAME, so for a mod frame every tab after ours maps to the wrong page. The hand-rolled
-- alternative works but keeps three parallel lists in step by hand, and if it drifts it takes the
-- WHOLE SHOP with it — in a mod whose entire purpose is buying things.
--
-- Appending to menuButtonInfo is a table insert. The worst it can do is nothing.

ShopHook = {}

local screen = nil

--- The bottom bar is data-driven: TabbedMenu:assignMenuButtonInfo walks plain Lua tables of
--- { inputAction, text, callback } and binds each to a ButtonElement (base/TabbedMenu.lua:191-235).
--- `inputAction` is REQUIRED — an entry whose action does not resolve is skipped silently
--- (TabbedMenu.lua:198-200).
---
--- MENU_EXTRA_1 rather than EXTRA_2, because the shop already uses EXTRA_2 for its own search
--- dialog on the brands and categories pages (ShopMenu.lua:136).
function ShopHook.makeButtonInfo()
	return {
		inputAction = InputAction.MENU_EXTRA_1,
		text = g_i18n:getText("agroTrader_title"),
		callback = ShopHook.onClickAgroTrader,
	}
end

--- Add the button to every bar variant the shop swaps between.
---
--- ⚠ CALLED DIRECTLY, NOT APPENDED TO setupMenuButtonInfo. That function runs EXACTLY ONCE, from
--- TabbedMenu:onGuiSetupFinished (base/TabbedMenu.lua:37-40), when the shop GUI is built at game
--- startup — long before any mod's loadMap. An appendedFunction registered at loadMap would be
--- installed too late ever to fire, and the button would simply never appear.
---
--- The shop keeps several of these tables and picks one per page (ShopMenu:getPageButtonInfo,
--- ShopMenu.lua:548-560), so the button has to go into each set it should show on — adding it to
--- one puts it on one page only. DLC pages are deliberately left out; a used marketplace has no
--- business on them.
---
--- ⚠ IDEMPOTENT ON PURPOSE. g_shopMenu is built once per SESSION, but loadMap runs once per SAVE
--- LOAD — so returning to the main menu and loading a second save would otherwise append a second
--- button, and a third, and so on.
function ShopHook.onSetupMenuButtonInfo(shopMenu)
	local sets = {
		shopMenu.shopMenuButtonInfo,
		shopMenu.shopMenuButtonInfoBrands,
		shopMenu.shopMenuButtonInfoCategories,
		shopMenu.shopMenuButtonsInfoOthers,
	}

	local added, alreadyPresent = 0, 0
	for _, set in ipairs(sets) do
		if type(set) == "table" then
			local present = false
			for _, info in ipairs(set) do
				if info.callback == ShopHook.onClickAgroTrader then
					present = true
					break
				end
			end

			if present then
				alreadyPresent = alreadyPresent + 1
			else
				table.insert(set, ShopHook.makeButtonInfo())
				added = added + 1
			end
		end
	end

	if alreadyPresent > 0 then
		Logging.info("[AgroTrader] Shop button already present in %d set(s), not duplicated",
			alreadyPresent)
	end

	-- Logged positively, because silence here is ambiguous: the failure mode is a button that
	-- simply never appears, with nothing in the log to say whether the hook ran, found no tables
	-- to append to, or appended to tables the shop does not use. Giants may also rename these
	-- fields in a patch, which would show up as `0 of 4` rather than a mystery.
	Logging.info("[AgroTrader] Shop button added to %d of %d button sets", added, #sets)
end

function ShopHook.onClickAgroTrader()
	if screen == nil then
		Logging.warning("[AgroTrader] Screen not registered; cannot open.")
		return
	end

	-- Come back to the shop when the marketplace closes, the way the config screen does
	-- (ShopMenu.lua:384).
	screen:setReturnScreenClass(ShopMenu)
	g_gui:changeScreen(nil, AgroTraderScreen)
end

--- Build the screen and wire the button.
---
--- ⚠ MUST RUN AFTER ShopMenu HAS BEEN CONSTRUCTED. g_shopMenu is created at main.lua:523 during
--- startup, and setupMenuButtonInfo runs from TabbedMenu:onGuiSetupFinished — so by loadMap the
--- tables exist and appending to them is safe. Doing this at source time would append to nothing.
function ShopHook.install(market, rarity)
	if g_gui == nil then
		return
	end

	screen = AgroTraderScreen.register(market, rarity)
	if screen == nil then
		Logging.error("[AgroTrader] Could not load the marketplace screen.")
		return
	end

	-- Populate the cyclers that have fixed contents. The ones built from the store are filled on
	-- open, when the store is guaranteed loaded.
	screen:onCreateFilters()

	if g_shopMenu ~= nil then
		ShopHook.onSetupMenuButtonInfo(g_shopMenu)

		-- Rebuild the bar if the shop is already showing, otherwise it picks this up on the next
		-- page change (TabbedMenu:updateButtonsPanel).
		if g_shopMenu.currentPage ~= nil then
			g_shopMenu:updateButtonsPanel(g_shopMenu.currentPage)
		end
	else
		Logging.warning("[AgroTrader] Shop menu not available; button not added.")
	end
end
