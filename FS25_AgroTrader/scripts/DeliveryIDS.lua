-- AgroTrader — Implement Damage System overlay for delivered implements.
--
-- Counterpart to DeliveryADS.lua: ADS covers the motorised half of the market, IDS
-- (FS25_ImplementDamageSystem, our own mod) covers implements. The same advert facts —
-- damage, care, service-history tier — decide what the delivered machine is secretly
-- carrying, so a no-history plough is the same gamble a no-history tractor is.
--
-- Two deliberate differences from the ADS file:
--
--  1. NO QUEUE. ADS seeds a used vehicle asynchronously on its first update tick, so
--     DeliveryADS has to watch and overwrite. IDS adopts its state in onPostLoad, which has
--     finished before BuyVehicleData.onBought hands us the spawned vehicle — a direct call
--     lands after the seed by construction.
--
--  2. NO INTERNALS TOUCHED. IDS is ours, so instead of writing its spec fields from here it
--     exports one documented entry point — ImplementDamageSystem.seedFromMarket(vehicle,
--     {care, serviceHistory, damage}) — and this file's whole job is to find it and call it.
--     The tier -> fault mapping lives on the IDS side, next to the registry it draws from.
--
-- The environment rules still apply (see DeliveryADS.lua rule 1): IDS's globals are only
-- reachable through _G["FS25_ImplementDamageSystem"], detection is g_modIsLoaded, and the
-- call is pcall-guarded so an IDS API change costs the overlay and nothing else. Without IDS
-- the graded price floor in Valuation stays the implement's only consequence, exactly as now.
--
-- Server-only, like the ADS overlay: IDS state is authoritative on the server, and
-- Purchase.onBought — the call site — carries the spawned vehicles there.

AgroTraderIDS = {}

AgroTraderIDS.MOD_NAME = "FS25_ImplementDamageSystem"

--- Seed one delivered implement from the advert's facts. Returns true when IDS took it.
function AgroTraderIDS.apply(vehicle, damage, care, historyTier, label)
	if vehicle == nil or vehicle.spec_ImplementDamageSystem == nil then
		-- The normal case for every motorised machine (ADS's side of the fence), and for
		-- implements when IDS is not installed. Not a warning.
		return false
	end

	if g_modIsLoaded == nil or not g_modIsLoaded[AgroTraderIDS.MOD_NAME] then
		return false
	end

	local env = _G[AgroTraderIDS.MOD_NAME]
	local ids = env ~= nil and env.ImplementDamageSystem or nil
	if ids == nil or ids.seedFromMarket == nil then
		Logging.warning("[AgroTrader] IDS is loaded but seedFromMarket is missing — '%s' "
			.. "keeps IDS's own condition instead of the advert's.", tostring(label))
		return false
	end

	local ok, seeded = pcall(ids.seedFromMarket, vehicle, {
		care = care,
		serviceHistory = historyTier,
		damage = damage,
	})

	if not ok then
		Logging.warning("[AgroTrader] IDS overlay on '%s' failed: %s",
			tostring(label), tostring(seeded))
		return false
	end

	if seeded == true then
		Logging.info("[AgroTrader] IDS seeded '%s' from the advert (care %.0f%%, %s history)",
			tostring(label), (care or 0.5) * 100, tostring(historyTier))
	end
	return seeded == true
end
