-- Forward Contracts — UI
--
-- Puts the board into the ESC menu and owns the GUI lifecycle.
--
-- =============================================================================
-- Why this does NOT use TabbedMenu:addPage
-- =============================================================================
--
-- addPage looks like the sanctioned API and is not usable from a mod. It registers
-- `pageFrameElement.elements[1]` — the frame's first CHILD — as the page element
-- (scripts/gui/base/TabbedMenu.lua:450-457), but rebuildTabList then looks the page up by
-- the FRAME itself via pagingElement:getPageIdByElement (:142). For base-game pages those
-- two happen to be the same object. For a mod frame they are not, the lookup fails, and
-- every tab after ours maps to the wrong page — which wrecks the entire ESC menu, not just
-- our page. Confirmed in game on 2026-07-27: duplicated tab icons, blank pages,
-- unlabelled button bar.
--
-- The working approach registers the frame itself as the page element and keeps the three
-- parallel lists in step by hand. It is the technique the mod community settled on;
-- FS25_EnhancedLoanSystem is a known-good example. Written fresh from the technique.
--
-- The three lists that must agree, or tabs desync from pages:
--   pagingElement.elements    the child GUI elements
--   pagingElement.pages       the page records
--   TabbedMenu.pageFrames     the frame controllers
--
-- See HANDOFF.md §4.8.

UI = {}

local UI_mt = Class(UI)

UI.PAGE_NAME = "FCContractBoardPage"

-- Where the tab sits in the ribbon. Safe to choose freely because all three lists are
-- reordered to match.
UI.PAGE_POSITION = 5

-- Icon UVs normalise against a 1024x1024 reference (GuiUtils.lua:164-166). The whole
-- image is {0, 0, 1024, 1024}; {0, 0, 1, 1} would request a single pixel.
UI.ICON_UVS = { 0, 0, 1024, 1024 }

function UI.new()
	local self = setmetatable({}, UI_mt)

	self.boardFrame = nil
	self.isInstalled = false

	return self
end

function UI:install()
	if self.isInstalled or g_gui == nil then
		return
	end

	local inGameMenu = g_gui.screenControllers[InGameMenu]
	if inGameMenu == nil then
		Logging.warning("[ForwardContracts] In-game menu not available; board page not installed.")
		return
	end

	g_gui:loadProfiles(ForwardContracts.MOD_DIR .. "gui/guiProfiles.xml")

	self.boardFrame = ContractBoardFrame.new()
	g_gui:loadGui(ForwardContracts.MOD_DIR .. "gui/ContractBoardFrame.xml",
		UI.PAGE_NAME, self.boardFrame, true)

	NegotiationDialog.register()

	self:attachPage(inGameMenu, self.boardFrame)

	-- initialize() after attaching: it sets the menu button info and the page title, both
	-- of which belong to a page that is already wired in.
	self.boardFrame:initialize()

	self.isInstalled = true
end

function UI:attachPage(inGameMenu, frame)
	local pageName = UI.PAGE_NAME
	local position = UI.PAGE_POSITION

	-- Clear any stale control id of this name so exposeControlsAsFields does not warn.
	inGameMenu.controlIDs[pageName] = nil

	inGameMenu[pageName] = frame
	inGameMenu.pagingElement:addElement(frame)

	-- Binds the frame's id'd child elements onto the controller. Without this the page's
	-- elements are unreachable and layout calls dereference nil.
	inGameMenu:exposeControlsAsFields(pageName)

	UI.moveToPosition(inGameMenu.pagingElement.elements, position, function(entry)
		return entry == frame
	end)

	UI.moveToPosition(inGameMenu.pagingElement.pages, position, function(entry)
		return entry.element == frame
	end)

	inGameMenu.pagingElement:updateAbsolutePosition()
	inGameMenu.pagingElement:updatePageMapping()

	inGameMenu:registerPage(frame, position, function()
		return ForwardContracts.isEnabled == true
	end)

	-- Tab glyph, NOT the mod badge. Menu tab icons must be white line art on transparency
	-- so the menu can tint them for the selected state; the badge is opaque artwork and
	-- renders as a dark square. icon_ForwardContracts.dds stays the mod-selection image.
	inGameMenu:addPageTab(frame,
		ForwardContracts.MOD_DIR .. "icon_tab_ForwardContracts.dds",
		GuiUtils.getUVs(UI.ICON_UVS))

	UI.moveToPosition(inGameMenu.pageFrames, position, function(entry)
		return entry == frame
	end)

	inGameMenu:rebuildTabList()
end

--- Move the first entry matching `predicate` to `position`, leaving the rest in order.
function UI.moveToPosition(list, position, predicate)
	if list == nil then
		return
	end

	for index = 1, #list do
		if predicate(list[index]) then
			local entry = table.remove(list, index)
			table.insert(list, math.min(position, #list + 1), entry)
			return
		end
	end
end

function UI:uninstall()
	self.boardFrame = nil
	self.isInstalled = false
end
