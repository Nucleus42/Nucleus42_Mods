# Nucleus42 Mods — Farming Simulator 25

Mods by **Nucleus42**.

> **Download only from this repository.** See [LICENSE](LICENSE). Use is free; re-uploading
> anywhere else is not permitted.

---

## FS25_ForwardContracts

Long-term supply agreements for arable and livestock farming. Agree a price now for delivery
later, and hold to it.

Contracts are a **hedge**: you settle the difference between the agreed rate and what the
market actually paid, so a contract is certainty rather than a bonus. Meet your quota and
your reputation grows, which unlocks better terms, larger agreements and more of them at
once. Miss it and you pay a penalty, lose standing with the buyer, and two consecutive
misses end the agreement.

Livestock contracts run on Realistic Livestock's genetics. Early on you supply headcount; as
your reputation grows the numbers fall and the genetic requirements rise, until you are a
breeder shipping a handful of animals a year that nobody else can produce. Contracts state
their requirement in Realistic Livestock's own vocabulary, so what the contract asks for and
what the animal's info panel says are the same words.

It is meant to be demanding. A contract states its terms and does not tell you whether you
can meet them — working that out is the game, and failing has consequences.

### Requirements

| | |
| --- | --- |
| **Farming Simulator 25** | required |
| **[Realistic Livestock](https://github.com/rittermod/FS25_RealisticLivestockRM)** (Ritter version, `FS25_RealisticLivestockRM`) | **required — the mod will not work without it** |

### Installing

1. Install **Realistic Livestock (RM)** first.
2. Download this mod and place the `FS25_ForwardContracts` folder, zipped, into your
   `Documents/My Games/FarmingSimulator2025/mods` folder.
3. Enable both in the in-game mod list.

The contract board is a tab in the ESC menu.

### Status

**In development and not yet released.** Multiplayer is untested. Back up your saves.

---

## FS25_AgroTrader

A searchable classified-ads marketplace for used machinery.

The base game gives you four or five random second-hand machines on one shop tab. You cannot
search it, you cannot filter it, and you cannot go looking for a particular tractor. AgroTrader
is the other thing — you go hunting.

Search by type, make and model. Every listing is a specific machine with its own hours, damage
and paintwork, and an asking price worked out from all three using the game's own valuation
maths — no invented economics. Machines are listed from all over the country, and the further
away one is the more the delivery costs; delivery is haulage, so a heavy machine costs more to
move than a dear one.

Some things are harder to find than others. Small and medium tractors turn up constantly; a
self-propelled beet harvester might take some finding. There is no hand-written table of what is
rare — rarity is derived at load from the median price of whatever is actually installed, so
mod-added machines classify themselves and nothing needs maintaining when a mod pack lands.

> **Everything is bought as seen.** No configuring, no respraying, no swapping the wheels. What is
> in the advert is what arrives on your yard. You are told the hours, the damage and the paint
> condition; what it will cost to put right is your judgement.

Open the shop and use the **AgroTrader** button in the bottom button bar.

### Requirements

Farming Simulator 25. No other mods required.

### Status

**v1.0.0.0, submitted to the ModHub and awaiting testing.** Multiplayer is implemented and
server-authoritative but not yet proven on a real dedicated server.

---

## FS25_SubsoilerTillage

Lets subsoilers do the plough's job.

Any implement in the **Subsoilers** store category gains the three things that previously only
a plough could do:

- Create new fields (toggle with the same key a plough uses)
- Leave **ploughed** ground state, clearing the "needs ploughing" warning
- Count towards ploughing contracts

Nothing else changes. The game still decides when a field needs ploughing; this mod only adds
another implement that can satisfy it.

> **Trade-off:** an affected subsoiler now leaves ploughed ground instead of cultivated ground,
> so it no longer completes cultivating contracts.

### Requirements

Farming Simulator 25. No other mods required.

---

## FS25_DeadwoodPointer

Marks the deadwood trees an active contract actually requires.

Deadwood contracts give you a circle on the map and nothing else — no marker in the world,
unlike rock-clearing contracts, which do get a flag. This fills that gap: every tree the
contract counts gets a marker above it, and trees that are off-screen get an arrow at the edge
of the screen pointing the way. A readout shows how many are left and how far the nearest one is.

Only trees belonging to a contract you are actually running are marked, and a tree's marker
disappears the moment you finish the cut. Trees that merely look dead — and normal trees standing
among them — are ignored, because ownership is read from the contract itself rather than guessed
from the tree.

Toggle with **Ctrl+D**.

### Requirements

Farming Simulator 25. Singleplayer.

---

## FS25_AutoDrive_FieldLoops

Generates two-way AutoDrive ring routes around fields, so you don't have to drive every headland
by hand.

| Command | Effect |
|---|---|
| `adfl [offset] [spacing] [mode]` | Ring around the field you are standing in |
| `adflAll [offset] [spacing] [mode]` | Ring around every field on the map |
| `adflRefresh [offset] [spacing] [mode]` | Rebuild the ring for the current field |
| `adflRemove` | Remove the ring for the current field |
| `adflRemoveAll` | Remove every ring this mod created |
| `adflInfo` | Report what is under you and what is generated |

`mode` is either **`map`** — the surveyed field boundary, instant — or **`scan`**, which traces
the ground you have actually ploughed. Scan is slower but picks up field extensions and merged
fields that the surveyed boundary doesn't know about.

### Requirements

| | |
| --- | --- |
| **Farming Simulator 25** | required |
| **[AutoDrive](https://github.com/Stephan-S/FS25_AutoDrive)** (`FS25_AutoDrive`) | **required — the mod will not work without it** |

AutoDrive is the work of its own authors and is licensed separately. This repository contains
none of its code: Field Loops reads AutoDrive's live objects at run time and ships nothing of it.

---

## Credits

**Realistic Livestock** is the work of its own authors and is licensed separately under the
GPL v3. This repository contains none of its code or data — Forward Contracts reads
Realistic Livestock at run time and ships nothing of it.

Used with the kind permission of **Ritter**. The genetics model, breeding simulation and
animal data that Forward Contracts prices its livestock agreements against are all theirs;
this mod is built on top of that work and would not exist without it.

https://github.com/rittermod/FS25_RealisticLivestockRM
