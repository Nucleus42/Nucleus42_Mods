# AgroTrader

A searchable classified-ads marketplace for used machinery in Farming Simulator 25.

The base game gives you four or five random second-hand machines on one shop tab. You cannot
search it, you cannot filter it, and you cannot go looking for a particular tractor. AgroTrader
is the other thing — you go hunting.

## What it does

Search the used market by type, make and model. Every listing is a specific machine with its own
hours, damage and paintwork, and an asking price worked out from all three using the game's own
valuation maths — no invented economics.

**Machines are listed from all over the country.** The further away one is, the more the delivery
costs, and delivery is haulage so a heavy machine costs more to move than a dear one.

**Some things are harder to find than others.** Small and medium tractors turn up constantly. A
large tractor takes longer. A self-propelled beet harvester might take some finding. Implements
are easier to come by across the board, because the real second-hand implement market is deeper
than the vehicle one.

**Every machine has a history.** A previous owner who ran a big fleet lightly, a mixed family
farm, or a contractor who worked it hard — which is why two machines of the same age can have
very different hours, and very different prices.

**Everything is bought as seen.** No configuring, no respraying, no swapping the wheels. What is
in the advert is what arrives on your yard. If you want it changed, that is what the workshop is
for. And you are told the hours, the damage and the paint condition — what it will cost to put
right is your judgement, not ours.

## Requirements

Farming Simulator 25. No other mods required.

## Installing

Place the zipped `FS25_AgroTrader` folder into your `Documents/My Games/FarmingSimulator2025/mods`
folder and enable it in the in-game mod list.

Open the shop and use the **AgroTrader** button in the bottom button bar.

## Status

**v1.0.0.0, submitted to the ModHub and awaiting testing.** Complete and played in singleplayer.

Multiplayer is implemented and server-authoritative — the market is derived rather than streamed, so
every client rebuilds the same list from a shared salt, and the server regenerates a listing from
its key on purchase rather than trusting anything a client sends. It has **not yet been proven on a
real dedicated server**. Back up your saves.

## How rarity works

There is no hand-written table of which machines are rare. The rarity of a category is derived
from the median price of the machines in it, computed at load from whatever is actually
installed — so mod-added machines and categories nobody has ever seen classify themselves, and
nothing needs maintaining when a mod pack lands.

Vehicles and implements are ranked **separately**. Ranking them together produces the wrong
answer: £92,000 is cheap for a tractor and enormous for a mower, and putting both on one scale
turns "rarity" into "is it self-propelled".

Run `atRarity` in the console to print the full derived table for your own installation.

## Credits

Nucleus42. Valuation, depreciation and damage-accumulation maths are the base game's own,
used unchanged.
