-- Forward Contracts — Settlement
--
-- Consumes delivery events from DeliveryWatch and settles the difference between the
-- rate the contract agreed and the price the market actually paid.
--
-- This is the hedge (HANDOFF.md §4.3). Delivering to a legitimate buyer is a normal sale
-- at market price; settlement then pays or claws back the gap. When the market spikes you
-- are locked in below it and it hurts. When the market falls the contract carries you.
-- That is what a forward contract is for, and it keeps the negotiated rate meaningful for
-- years after signing.
--
-- The realised price comes from the station's own totals via DeliveryWatch. Do not
-- reimplement getEffectiveFillTypePrice — seasonal factor, price drops, great demand and
-- station multipliers are already baked into what we are handed.

Settlement = {}

local Settlement_mt = Class(Settlement)

function Settlement.new(contractProvider)
	local self = setmetatable({}, Settlement_mt)

	-- Seam to ContractStore (not yet written — HANDOFF.md §7). Anything implementing
	-- this pair of methods will do:
	--
	--   getActiveContract(farmId, fillTypeIndex) -> contract | nil
	--       contract.rate               agreed price per litre
	--       contract.remainingLitres    quota still outstanding this year
	--   recordDelivery(contract, litres, money)
	--
	-- Until it is set, deliveries are observed and ignored rather than erroring.
	self.contractProvider = contractProvider

	-- changeFinanceStats silently drops an unknown statistic (FarmStats.lua:187-189), so
	-- a custom one would never appear in the finances screen. "soldMaterials" is where a
	-- settlement belongs anyway — it is an adjustment to a sale.
	-- `statistic` must be a real FarmStats name or the entry is silently dropped
	-- (FarmStats.lua:187-189); "soldMaterials" is where a settlement belongs anyway, since it
	-- is an adjustment to a sale. `title` is a separate thing entirely — an l10n key the HUD
	-- resolves against our own mod environment (gui/hud/HUD.lua:297), so it must be a key we
	-- actually define. See ContractStore.new for the full account of why.
	self.moneyType = MoneyType.register("soldMaterials", "fc_finance_settlement",
		ForwardContracts.MOD_NAME)

	return self
end

function Settlement:setContractProvider(contractProvider)
	self.contractProvider = contractProvider
end

--- Seam to Animals. Needed only to ask whether a sold animal cleared a contract's genetic
--- floors — Animals owns that knowledge, and Settlement should not learn the genetics
--- model just to pay for it.
function Settlement:setAnimalsProvider(animalsProvider)
	self.animalsProvider = animalsProvider
end

-- ---------------------------------------------------------------------------
-- Delivery handling
-- ---------------------------------------------------------------------------

function Settlement:onDelivery(delivery)
	local provider = self.contractProvider
	if provider == nil then
		return
	end

	local contract = provider:getActiveContract(delivery.farmId, delivery.fillTypeIndex)
	if contract == nil then
		return
	end

	-- Only the outstanding quota settles. Anything delivered beyond it is an ordinary
	-- sale at market price — the client agreed to buy a quantity, not everything you can
	-- grow, and over-delivery must not be an exploit when the contract rate is above
	-- market.
	local countedLitres = math.min(delivery.litres, contract.remainingLitres or 0)
	if countedLitres <= 0 then
		return
	end

	local realisedRate = self:getRealisedRate(delivery)
	local countedMoney = realisedRate * countedLitres
	local adjustment = (contract.rate - realisedRate) * countedLitres

	if adjustment ~= 0 then
		-- addChange = true so it shows in the finance breakdown; force = true so it
		-- applies even when the amount is small.
		g_currentMission:addMoney(adjustment, delivery.farmId, self.moneyType, true, true)
	end

	provider:recordDelivery(contract, countedLitres, countedMoney + adjustment)
end

-- ---------------------------------------------------------------------------
-- Livestock
-- ---------------------------------------------------------------------------

--- An RL sale completed. Same hedge as a crop delivery: the market paid what it paid, and
--- the contract settles the gap to the agreed per-head rate.
---
--- Only animals that clear EVERY trait floor count (HANDOFF §4.6). Selling ineligible
--- stock in the same batch is an ordinary sale and is simply ignored here — which is also
--- what makes the top tier hard: the herd is not the contract, the qualifying animals are.
function Settlement:onAnimalSale(sale)
	local provider = self.contractProvider
	local animals = self.animalsProvider

	if provider == nil or animals == nil or sale == nil or sale.animals == nil then
		return
	end

	-- ONE BATCH MAY SERVE SEVERAL CONTRACTS. Since livestock is no longer capped at one live
	-- contract per farm (2026-07-29), a trailer can legitimately carry animals belonging to
	-- two different agreements — or animals matching one and not the other.
	--
	-- Each animal is allocated to AT MOST ONE contract, matched on its full spec rather than
	-- by taking whichever contract came first. Taking the first would let a cattle sale tick
	-- down a chicken contract, corrupting the delivery ledger silently — worse than the cap
	-- this replaced.
	local contracts = provider.getActiveHeadContracts ~= nil
		and provider:getActiveHeadContracts(sale.farmId)
		or { provider:getActiveHeadContract(sale.farmId) }

	if contracts == nil or #contracts == 0 or contracts[1] == nil then
		return
	end

	-- Settle each contract against the animals it can actually claim, removing them from the
	-- pool as it goes so nothing is counted twice.
	local remaining = {}
	for _, snapshot in ipairs(sale.animals) do
		table.insert(remaining, snapshot)
	end

	for _, contract in ipairs(contracts) do
		remaining = self:settleAnimalsAgainst(contract, remaining, sale, animals, provider)
	end
end

--- Settle one contract against a pool of sold animals, returning those it did not claim.
function Settlement:settleAnimalsAgainst(contract, pool, sale, animals, provider)
	local unclaimed = {}

	-- Judge from the snapshot taken while the animal was alive. The live object is gone by
	-- the time this runs — that is the whole reason Animals snapshots genetics by value.
	local eligible = {}
	local totalValue = 0
	local eligibleValue = 0

	-- Why an animal did NOT count is the single most useful thing this mod can say. Without
	-- it, "87 loaded, 85 counted" is unanswerable after the fact — the animals are gone and
	-- the herd cannot be re-inspected. Reported from play 2026-07-29; costs one log line.
	local rejected = {}

	for _, snapshot in ipairs(pool) do
		local price = snapshot.sellPrice or 0
		totalValue = totalValue + price

		local ok, reason, value = animals:meetsSpec(snapshot, contract)

		if ok then
			table.insert(eligible, snapshot)
			eligibleValue = eligibleValue + price
		else
			-- Not this contract's animal. It stays in the pool so a second contract can
			-- still claim it.
			table.insert(unclaimed, snapshot)

			local label = reason or "unknown"
			rejected[label] = (rejected[label] or 0) + 1

			-- Name the first offender of each kind, with the value that failed, so the
			-- number can be checked against the contract's floor directly.
			if rejected[label] == 1 then
				Logging.info("[ForwardContracts] rejected %s (%s): %s = %s",
					tostring(snapshot.earTag or snapshot.key or "?"),
					label,
					label,
					tostring(value))
			end
		end
	end

	local summary = {}
	for label, count in pairs(rejected) do
		table.insert(summary, string.format("%s x%d", label, count))
	end

	Logging.info("[ForwardContracts] animal sale: %d offered, %d qualify%s",
		#pool, #eligible,
		#summary > 0 and (", rejected " .. table.concat(summary, ", ")) or "")

	self:notifySale(contract, #pool, #eligible, rejected)

	local countedHead = math.min(#eligible, contract.remainingLitres or 0)
	if countedHead <= 0 then
		-- Nothing claimed, so every animal offered stays available to the next contract.
		return pool
	end

	-- When more animals qualify than the quota still needs, WHICH ones count is worth money
	-- and must not fall out of table order.
	--
	-- Under a flat agreed price the counted animals are paid `contract.rate` whatever they
	-- were worth, and the uncounted ones keep their market value — so the player is always
	-- better off spending their CHEAPEST qualifying animals on the contract and selling the
	-- rest freely. Resolve it that way on their behalf rather than making the ordering a
	-- hidden tax on not micro-managing which animal walks onto the trailer first.
	table.sort(eligible, function(a, b) return (a.sellPrice or 0) < (b.sellPrice or 0) end)

	-- Value the animals actually counted, not the whole qualifying set — otherwise the
	-- sort above would have no effect on the payment.
	eligibleValue = 0
	for index = 1, countedHead do
		eligibleValue = eligibleValue + (eligible[index].sellPrice or 0)
	end

	-- Qualifying animals BEYOND this contract's outstanding quota are not consumed by it, so
	-- they remain available to another live contract that could also use them.
	for index = countedHead + 1, #eligible do
		table.insert(unclaimed, eligible[index])
	end

	-- The payment covers the whole batch, so attribute the counted animals' share of it by
	-- their own recorded sale values. A contract-grade animal is worth more than a cull, so
	-- a flat per-head average would misprice both.
	local countedMoney
	if totalValue > 0 then
		countedMoney = (sale.money or 0) * (eligibleValue / totalValue)
	else
		countedMoney = (sale.money or 0) * (countedHead / math.max(#pool, 1))
	end

	local realisedPerHead = countedHead > 0 and (countedMoney / countedHead) or 0

	-- A FLAT AGREED PRICE PER HEAD. The contract states a MINIMUM specification, not a
	-- maximum, and it pays that price for anything clearing it — an over-spec animal earns
	-- no more here than one sitting exactly on the floor.
	--
	-- **THIS REVERSES THE MULTIPLIER-ON-REALISED-VALUE RULE THAT §4.6 ARGUED FOR.** User
	-- decision 2026-07-28, and the reasoning is the real world's: a supply contract agrees a
	-- price for goods meeting a spec. A supplier who ships better than the spec has given
	-- away margin — that is the breeder's problem, not the buyer's. The buyer never asked
	-- for it and does not pay for it.
	--
	-- What §4.6 feared — that the player would deliver their worst qualifying stock — is
	-- therefore not a failure mode here, it is the CORRECT PLAY and the intended tension:
	-- meet the spec exactly, sell your best on the open market. Breeding is still rewarded,
	-- but through the ladder rather than per animal — a better herd clears higher floors,
	-- and higher floors are priced against better animals and carry a better multiplier.
	--
	-- `contract.rate` already carries the multiplier (Offers: marketRate * rateMultiplier),
	-- where marketRate is a minimum-spec animal's value at prime age from RL's own pricing
	-- (Animals.getSellPriceForSubType). So the hedge is the ordinary one: pay the gap
	-- between the agreed price and what the dealer actually gave.
	local adjustment = (contract.rate - realisedPerHead) * countedHead

	if adjustment ~= 0 then
		g_currentMission:addMoney(adjustment, sale.farmId, self.moneyType, true, true)
	end

	provider:recordDelivery(contract, countedHead, countedMoney + adjustment)

	return unclaimed
end

--- Tell the player what the contract just did with their animals, and why.
---
--- **THE REASONS WERE ALWAYS COMPUTED AND NEVER SHOWN.** Reported from play 2026-08-01: a
--- tier-4 breeding contract counted 6 of 10 animals and the panel said nothing about the other
--- four. They were underweight, it was in `log.txt`, and nowhere else. A 40% loss with no
--- visible cause is not difficulty, it is a missing instrument.
---
--- States the count and the reasons, and NOTHING ELSE — no target weight, no shortfall, no
--- advice. Same line as the coverage hints: what happened, never what to aim for.
---
--- SILENT WHEN THE POOL IS EMPTY. With multi-contract settlement a batch is offered to each
--- live contract in turn and shrinks as it goes (HANDOFF §0.10), so a second contract routinely
--- sees nothing at all. "0 offered, 0 counted" is noise about a contract that was never
--- involved.
function Settlement:notifySale(contract, offered, counted, rejected)
	if offered <= 0 then
		return
	end

	local name = "Livestock"

	if contract.subTypeName ~= nil and Animals ~= nil
		and Animals.getSubTypeBreedName ~= nil and Animals.getSubTypeByName ~= nil then
		local subType = Animals.getSubTypeByName(contract.subTypeName)
		name = subType ~= nil and Animals.getSubTypeBreedName(subType) or contract.subTypeName
	end

	local reasons = {}

	for reason, count in pairs(rejected or {}) do
		local label = Animals ~= nil and Animals.getRejectionLabel ~= nil
			and Animals.getRejectionLabel(reason) or tostring(reason)

		table.insert(reasons, count > 1 and string.format("%d %s", count, label) or label)
	end

	-- Stable ordering. `pairs` over a hash is arbitrary, so the same sale could otherwise
	-- report its reasons in a different order each time and look like different information.
	table.sort(reasons)

	local text

	if #reasons == 0 then
		text = string.format(g_i18n:getText("fc_sale_counted"), name, offered, counted)
	else
		text = string.format(g_i18n:getText("fc_sale_rejected"), name, offered, counted,
			table.concat(reasons, ", "))
	end

	g_currentMission:addIngameNotification(FSBaseMission.INGAME_NOTIFICATION_INFO, text)
end

--- Price per litre actually received, from the station's own books.
---
--- Falls back to the station's effective price only if the money delta is unusable —
--- which should not happen, but a divide-by-zero here would poison a contract's ledger.
function Settlement:getRealisedRate(delivery)
	if delivery.litres > 0 and delivery.money ~= nil and delivery.money > 0 then
		return delivery.money / delivery.litres
	end

	local station = delivery.station
	if station ~= nil and station.getEffectiveFillTypePrice ~= nil then
		return station:getEffectiveFillTypePrice(delivery.fillTypeIndex, ToolType.UNDEFINED) or 0
	end

	return 0
end
