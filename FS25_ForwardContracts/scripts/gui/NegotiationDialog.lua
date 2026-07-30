-- Forward Contracts — NegotiationDialog
--
-- Drives Negotiation round by round. All the decision logic lives in Negotiation.lua;
-- this only presents it and reports the outcome back.
--
-- Two controls, both discrete rather than free sliders — the steps make the trade
-- readable, and there is no fiddly dragging:
--
--   ask  — what you are asking for the whole contract, from the client's opening offer
--          up past their patience. Reaching for the top steps risks them walking.
--   mix  — how much of the value you take as a guaranteed rate versus an annual
--          completion bonus (HANDOFF.md §4.4). Bonus-weighted deals are worth more in
--          total because the client only pays out if you actually deliver.

NegotiationDialog = {}

-- DialogElement, NOT MessageDialog — the same base Nucleus Command's dialogs use.
--
-- MessageDialog:onOpen reassigns the profiles of any element it finds under the ids
-- `dialogBg` and `dialogElement` to the base game's own dialog profiles
-- (scripts/gui/dialogs/MessageDialog.lua:60-73), which would silently discard our panel
-- styling the moment we gave those elements their (required) ids.
--
-- It also sets dialogType = TYPE_WARNING in onCreate (:48) and plays the ERROR sample on
-- every open (:53-56) — so opening a negotiation was beeping like a failure. DialogElement
-- gives us close() and onClickBack() with none of that.
local NegotiationDialog_mt = Class(NegotiationDialog, DialogElement)

NegotiationDialog.ASK_STEPS = 9
NegotiationDialog.MIX_STEPS = { 0, 0.25, 0.5, 0.75, 1 }

function NegotiationDialog.new(target, customMt)
	local self = DialogElement.new(target, customMt or NegotiationDialog_mt)

	self.offer = nil
	self.round = 1
	self.askValues = {}
	self.lastCounter = nil
	self.callback = nil

	return self
end

function NegotiationDialog.register()
	local dialog = NegotiationDialog.new()

	g_gui:loadGui(ForwardContracts.MOD_DIR .. "gui/NegotiationDialog.xml",
		"FCNegotiationDialog", dialog)

	NegotiationDialog.INSTANCE = dialog

	return dialog
end

--- Open the dialog for an offer. `callback(result)` fires once, where result is
--- { signed = bool, agreedValue = number, mix = number, pushedTooHard = bool }.
function NegotiationDialog.show(offer, callback)
	local dialog = NegotiationDialog.INSTANCE
	if dialog == nil then
		return
	end

	dialog:setOffer(offer, callback)
	g_gui:showDialog("FCNegotiationDialog")
end

-- ---------------------------------------------------------------------------
-- Setup
-- ---------------------------------------------------------------------------

function NegotiationDialog:setOffer(offer, callback)
	self.offer = offer
	self.callback = callback
	self.round = 1
	self.lastCounter = offer.profile.anchorValue
	self.resolved = false

	self:buildAskSteps()
	self:updateTexts()
end

--- Ask steps run from the client's opening offer up to just past the point where they
--- stop listening. The last two steps are deliberately beyond reach — the risk has to be
--- visible and reachable, or walking away would never happen by choice.
function NegotiationDialog:buildAskSteps()
	local profile = self.offer.profile
	local low = profile.anchorValue
	local high = profile.walkawayValue * 1.05

	self.askValues = {}
	local texts = {}

	for index = 1, NegotiationDialog.ASK_STEPS do
		local t = (index - 1) / (NegotiationDialog.ASK_STEPS - 1)
		local value = low + (high - low) * t

		self.askValues[index] = value
		texts[index] = g_i18n:formatMoney(value, 0, true, true)
	end

	if self.askOption ~= nil then
		self.askOption:setTexts(texts)
		-- Open just above their opening offer, not mid-range. Starting in the middle put
		-- the default ask inside the accept band, so the first click always signed and the
		-- negotiation never happened.
		self.askOption:setState(3)
	end

	local mixTexts = {}
	for index, mix in ipairs(NegotiationDialog.MIX_STEPS) do
		mixTexts[index] = string.format("%d%% bonus", math.floor(mix * 100 + 0.5))
	end

	if self.mixOption ~= nil then
		self.mixOption:setTexts(mixTexts)
		self.mixOption:setState(1)
	end
end

function NegotiationDialog:getAskValue()
	local state = self.askOption ~= nil and self.askOption:getState() or 1
	return self.askValues[state] or 0
end

function NegotiationDialog:getMix()
	local state = self.mixOption ~= nil and self.mixOption:getState() or 1
	return NegotiationDialog.MIX_STEPS[state] or 0
end

-- ---------------------------------------------------------------------------
-- Presentation
-- ---------------------------------------------------------------------------

function NegotiationDialog:updateTexts()
	local offer = self.offer
	if offer == nil then
		return
	end

	local fillType = g_fillTypeManager:getFillTypeByIndex(offer.fillTypeIndex)
	local productName = fillType ~= nil and fillType.title or "?"

	if self.dialogTitle ~= nil then
		self.dialogTitle:setText(string.format("%s — %s", offer.client.name, productName))
	end

	if self.dialogBody ~= nil then
		local roundNote = self.round >= Negotiation.MAX_ROUNDS
			and "Final round — they will take it or leave it."
			or "They will counter before they agree."

		if self.round > 1 then
			roundNote = roundNote .. " Come down, or they walk."
		end

		self.dialogBody:setText(string.format(
			"%s per year for %d years.\nSuggested buyer: %s.\n\nAt today's price that volume is worth %s.\nTheir offer stands at %s.\n\nRound %d of %d. %s",
			g_i18n:formatVolume(offer.quotaPerYear),
			offer.years,
			offer.suggestedStation or "—",
			g_i18n:formatMoney(offer.marketValue, 0, true, true),
			g_i18n:formatMoney(self.lastCounter, 0, true, true),
			self.round,
			Negotiation.MAX_ROUNDS,
			roundNote))
	end

	self:updateTermsPreview()
end

--- Show what the current ask and mix would actually mean, so the lever is legible
--- before signing rather than after.
--- Show what BOTH buttons would actually give you.
---
--- Previously this only previewed the ask, so "Accept counter" signed a number the player
--- had never been shown — you could accept believing you were getting your ask. Both
--- outcomes are now priced side by side before you commit to either.
function NegotiationDialog:updateTermsPreview()
	if self.termsPreview == nil or self.offer == nil then
		return
	end

	local mix = self:getMix()
	local quota, years = self.offer.quotaPerYear, self.offer.years

	local asking = Negotiation.splitValue(self:getAskValue(), mix, quota, years)
	local theirs = Negotiation.splitValue(self.lastCounter, mix, quota, years)

	self.termsPreview:setText(string.format(
		"YOUR ASK — %s: %s per litre, plus %s each year you meet quota.\n" ..
		"THEIR OFFER — %s: %s per litre, plus %s each year you meet quota.",
		g_i18n:formatMoney(asking.totalValue, 0, true, true),
		g_i18n:formatMoney(asking.rate, 3, true, true),
		g_i18n:formatMoney(asking.completionBonus, 0, true, true),
		g_i18n:formatMoney(theirs.totalValue, 0, true, true),
		g_i18n:formatMoney(theirs.rate, 3, true, true),
		g_i18n:formatMoney(theirs.completionBonus, 0, true, true)))
end

function NegotiationDialog:onAskChanged()
	self:updateTermsPreview()
end

function NegotiationDialog:onMixChanged()
	self:updateTermsPreview()
end

-- ---------------------------------------------------------------------------
-- Rounds
-- ---------------------------------------------------------------------------

function NegotiationDialog:onClickOffer()
	local askValue = self:getAskValue()
	local result = Negotiation.evaluateAsk(self.offer.profile, askValue, self.round)

	if result.outcome == Negotiation.OUTCOME_ACCEPTED
		or result.outcome == Negotiation.OUTCOME_CONVERGED then
		self:finish(true, result.value)
		return
	end

	if result.outcome == Negotiation.OUTCOME_WALKED then
		self:finish(false, nil, result.pushedTooHard, result.badFaith)
		return
	end

	self.lastCounter = result.counter
	self.round = self.round + 1
	self:updateTexts()
	self:updateTermsPreview()
end

--- Take the client's current counter and be done with it.
function NegotiationDialog:onClickAcceptCounter()
	self:finish(true, self.lastCounter)
end

function NegotiationDialog:onClickWalk()
	local result = Negotiation.evaluateWalkaway(self.offer.profile, self:getAskValue(), self.round)

	if result.outcome == Negotiation.OUTCOME_LAST_DITCH then
		-- They came back with something. Take it or leave it.
		self.lastCounter = result.value
		self.round = Negotiation.MAX_ROUNDS
		self:updateTexts()

		if self.dialogBody ~= nil then
			self.dialogBody:setText(string.format(
				"They stopped you on the way out.\n\nFinal offer: %s. Accept it or leave.",
				g_i18n:formatMoney(result.value, 0, true, true)))
		end

		return
	end

	self:finish(false)
end

function NegotiationDialog:finish(signed, agreedValue, pushedTooHard, badFaith)
	if self.resolved then
		return
	end

	self.resolved = true

	local callback = self.callback
	local payload = {
		signed = signed,
		agreedValue = agreedValue,
		mix = self:getMix(),
		pushedTooHard = pushedTooHard or false,
		badFaith = badFaith or false,
	}

	self:close()

	if callback ~= nil then
		callback(payload)
	end
end

function NegotiationDialog:onClickBack()
	self:finish(false)
	return true
end
