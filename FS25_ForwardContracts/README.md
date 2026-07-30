# Forward Contracts

A forward contract is the real agricultural term for agreeing a price now for delivery later,
and that is what this mod adds to Farming Simulator 25: long-term supply agreements with named
buyers, negotiated up front, paid at the agreed rate for years afterwards whatever the market
does.

You are the supplier, not the empire. A contract is a stable income, not a way to get rich.

## What it offers

| Type | You supply |
| --- | --- |
| **Crop** | A volume of a crop, every year, for the term |
| **PRODUCT** | A volume of an animal's output — milk, wool, eggs |
| **SUPPLY** | Live animals for slaughter, to a genetic and condition specification |
| **BREEDING** | Live animals bred to do a job, at breeding age |
| **Spot** | A one-off order at above market price, short fuse, no haggling |

Every contract is sized from **money first**: the rung decides what the year is worth, and the
quantity — litres, or head — is derived from what the thing is actually worth on your map, in
your economy, at your difficulty. Nothing is hard-coded per crop, so a crop or animal added by
another mod prices itself.

Contracts state their terms and nothing more. They do not check whether you can meet them, warn
you that you are behind, or advise you what to do. Missing one costs money, reputation and the
buyer's goodwill; missing two ends the agreement.

## Requirements

- Farming Simulator 25
- [Realistic Livestock](https://github.com/rittermod/FS25_RealisticLivestockRM) for the animal
  contract types. Crop, product and spot contracts work without it.

The balance figures were reasoned against **hard** economic difficulty. Easier settings pay up to
three times as much per litre, so crop and product contracts will ask for proportionally less
work — which is the intent. Animal sale prices are not affected by the difficulty setting at all,
so livestock contracts are the same size on every setting.

## Known incompatibility

**`FS25_AnimalProducts_AutoShipping` — deliveries made through it will not count.**

That mod is a `productionPoint` placeable, not a selling station. Setting its output to *Selling*
pays you through `ProductionPoint:directlySellOutputs`, which credits your account directly and
never reaches `SellingStation:sellFillType` — the till this mod watches. Tipping product *into*
it does not register either, because a production point suppresses the sale for its owning farm.

If you want to fulfil a PRODUCT contract, haul the pallets to a real buyer.

## Credits

Realistic Livestock by **Ritter**, whose animal model the livestock contracts are built on.

## Licence

See `LICENSE`. Use it, do not redistribute it.
