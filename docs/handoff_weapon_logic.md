# Handoff: per-mission weapon logic and displacer gates

For the agent working on hl1-anniversary-ap (the retail, non-Sven world). The
Sven Co-op world (hl1-sven-ap) made these changes on 2026-09-30. Port the same
logic model; the Opposing Force findings below came from play in Sven Co-op and
need confirming against the retail maps before they are copied over.

## 1. The problem

Each campaign has one "First <weapon>" check per weapon. It was anchored, for
logic, to the earliest map in campaign order that holds that weapon, and placed
in that map's region.

Missions are unlocked by items and played in any order, so "earliest in campaign
order" says nothing about which copy a player meets first. A player who starts
in Vicarious Reality picks up a Glock there, and the check fires (any copy on the
campaign's maps sends it), but logic thought the check needed Missing In Action.
Logic was stricter than the game, and it also dropped the check from any seed
that left the anchor mission out.

## 2. The new model

A weapon check has **sources**: for every mission, the first map in that mission
(in the mission's own map order) holding a copy of the weapon. The check is
reachable if **any** source is reachable:

```
First X  =  OR over sources s of ( can_reach_region(s.map) AND s.gates )
            AND the location's own gates, if any
```

- `can_reach_region(s.map)` already includes the mission unlock, the mission
  door gates and any map-seam gate inside the mission (for example Pit Worm's
  Nest part 4 needing the grapple).
- `s.gates` is an extra, per-copy requirement in the same `{"strict": [...],
  "always": [...]}` shape as mission gates, for a copy that sits past something
  its mission does not ask for (a displacer teleport, the grapple).
- The location is placed in the Hub region, since it no longer belongs to one
  map. Its rule reaches into map regions with `state.can_reach_region`.
  Location rules are re-evaluated every sweep, so no indirect conditions are
  needed (they are only needed for entrances).
- Sources in excluded missions are dropped. The check stays in the seed while
  any source's mission is included. Anything that asks whether a location is in
  the seed (vanilla placements, for instance) must use that rule, not the anchor
  mission.
- The earliest source still gives the location its `map`/`chapter` and its
  display position, so location IDs and names do not change. IDs are keyed on
  campaign plus weapon, not on map.

## 3. Data shape

Each `weapon_pickup` location gains a `sources` list; the first element is the
anchor:

```json
{
  "id": 7720294,
  "name": "Opposing Force: First Glock",
  "chapter": "of_missing_in_action",
  "map": "of1a5",
  "trigger": {"type": "weapon_pickup", "map": "of1a5", "classnames": ["weapon_glock", "weapon_9mmhandgun"]},
  "position": [1824, -3456, 1339],
  "sources": [
    {"chapter": "of_missing_in_action", "map": "of1a5", "position": [1824, -3456, 1339]},
    {"chapter": "of_we_are_not_alone",  "map": "of2a4", "position": [-1008, -382, 172]},
    {"chapter": "of_vicarious_reality", "map": "of3a4", "position": [-904, -232, 40]},
    {"chapter": "of_pit_worms_nest",    "map": "of4a4", "position": [-300, -912, 416],
     "gates": {"always": ["displacer_cannon"]}}
  ]
}
```

(The `gates` on the last source is illustrative only; no weapon source is gated
yet.) `position` is absent for a weapon handed over by an NPC, which has no
entity. The data version fingerprint covers IDs only, so adding `sources`
changes no IDs and does not by itself break existing seeds.

## 4. Generator changes (`tools/build_campaign_data.py`)

`weapon_sources(campaign, chapters, entities, item, classnames)` replaces the
single `earliest_map_with` anchor:

1. For each mission in campaign order, walk its maps in order and take the
   first entity that holds the weapon. Stop at that mission's first hit.
2. **Count spawners.** `holds_weapon(entity, wanted)` is true for a placed
   `weapon_*` entity *or* a `monstermaker` whose `monstertype` is the weapon.
   Crush Depth part 2 (`of3a2`) hands the displacer over through a
   `monstermaker` named `drop_weapon` at (424, 884, 1040); there is no
   `weapon_displacer` entity in the map until it fires. The old anchor skipped
   it and landed on a prop in Vicarious Reality. Use `holds_weapon` everywhere a
   weapon's presence is tested (the anchor search and "which campaigns hold this
   weapon" alike).
3. **Unreachable copies.** A per-campaign `unreachable_copies: {item: [maps]}`
   lists maps whose copies do not count; the mission moves on to its next map.
   Sven entries: Opposing Force Tripmine on `of2a4` (beside Sven's easter-egg
   minigun, past a skylight, reachable only by stacking players) and Shotgun on
   `of2a4` (same room); Glock on `of1a5` (out of bounds, so Missing In Action's
   source moves to `of1a5b`); Displacer Cannon on `of3a5` (a prop in a
   self-teleport area). Check whether retail has the same props; the minigun
   room is Sven-only, and the `of1a5` Glock may be Sven's placement.
4. **Hand-placed anchors** (`weapon_anchors: {item: map}`, e.g. Blue Shift's
   Glock on `ba_security2`, handed over by the range guard) stand in for their
   own mission's source with no position. Other missions still contribute theirs.
5. **Per-source gates.** `weapon_source_gates: {map: {item: gates}}`, copied onto
   the source record. Sven entries, both `{"always": ["displacer_cannon"]}`:
   Crush Depth's Shotgun (`of3a2`) and The Package's Hand Grenade (`of6a2`).

## 5. Displacer-gated locations (Opposing Force)

Added as location gates (`LOCATION_GATES`, `{"always": ["displacer_cannon"]}`,
with a one-item requirement group `displacer_cannon: ["Displacer Cannon"]`):

| Location | Map | Entity |
| --- | --- | --- |
| Crush Depth - Health Charger (Part 2) | of3a2 | `func_healthcharger *39` |
| Vicarious Reality - Healing Pool (Part 1) | of3a4 | `trigger_hurt *247` |
| Pit Worm's Nest - Healing Pool (Part 1) | of4a1 | `trigger_hurt *10` |
| Foxtrot Uniform - Healing Pool (Part 1) | of5a1 | `trigger_hurt *160` |
| Foxtrot Uniform - Healing Pool (Part 2) | of5a2 | `trigger_hurt *101` |
| The Package - Healing Pool (Part 1) | of6a1 | `trigger_hurt *45` |
| Worlds Collide - Healing Pool (Part 1) | of6a4 | `trigger_hurt *78` |
| Worlds Collide - Healing Pool (Part 2) | of6a4b | `trigger_hurt *115` |

**Important for the anniversary world:** the Pit Worm's Nest pool (`of4a1 *10`)
was on the unreachable list as one of "Opposing Force's sealed healing volumes",
a finding that came from flood fill in the *retail* maps in hl1-anniversary-ap.
It is not sealed: it is the displacer's Xen room. Every map's
`info_displacer_xen_target` sits about 320 units from that prefab pool (`of4a1`,
`of5a1`, `of6a1`) or about 1100 units from it (`of5a2`, `of6a4`, `of6a4b`). The
displacer's secondary fire teleports you there. A flood fill from the player
start cannot see a teleport, which is why they read as sealed. In-game
investigation in Sven confirmed every one of them is reached with the
displacer, so all six are now displacer-gated checks (table above). Expect the
same in retail, and treat any flood-fill "sealed" verdict on a map that has an
`info_displacer_xen_target` as suspect.

Vicarious Reality itself is traversable without the displacer in Sven Co-op, so
the mission is not gated; only the spots above are. Verify for retail.

Displacer ammo: the self-teleport costs 60 uranium. The Sven plugin grants the
displacer with at least 60 ammo on any map that has an
`info_displacer_xen_target`, so a displacer-gated check is never a dead end for
a player who just received it. The retail game side needs the equivalent.

## 6. Game-side changes (Sven plugin, for reference)

- `checkdata.txt` gained `F|<location id>|<map>|<x y z>|<needs>` records, one
  per source, right after their `L` record, and an optional eighth `L` field
  `<needs>` naming what an `always` gate requires (for example "Displacer
  Cannon"). Both are appended, so an older reader ignores them.
- `!find` points at the copy on the current map when the check has a source
  there, and prints "Needs the X to reach." for gated checks and sources.

## 7. Weapon drops

Not modelled. The original games drop weapons from dead soldiers (grunt MP5 or
shotgun, the shock trooper's shock roach). Sven Co-op findings: the shock trooper
drops a shock roach that can be picked up, the human grunt dropped his MP5, the
male assassin dropped nothing. If
retail drops do fire weapon checks, they are an extra way in that logic ignores,
which is safe (logic only ever under-promises). Do not add drops as sources
unless the drop is guaranteed.

## 8. Tests worth porting

- A weapon check is reachable holding only the unlock of a later mission that
  has a copy (OF First Glock with only Vicarious Reality open).
- It is not reachable holding only a mission with no copy (Crush Depth).
- Every `weapon_pickup` location has `sources`, and `sources[0].map` equals its
  `map`.
- Each displacer-gated location is unreachable without the Displacer Cannon and
  reachable with it.

## 9. Verification in game

The Sven harness (`tests/aptest/aptest.as`) builds one "Source:" scenario per
`F` record: it teleports to the copy with the weapon locked, expects the check,
and asks whether the copy is reachable using only its mission's requirements.
Failures name the extra requirement, which becomes a `weapon_source_gates` or
`unreachable_copies` entry. The retail world needs the same sweep; 153 sources
across the four Sven campaigns, of which Half-Life and Opposing Force are the
retail-relevant part.
