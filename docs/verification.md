# Verification

## What has been verified

| Area | How | Status |
| --- | --- | --- |
| Bridge protocol | `pytest tests/test_bridge.py` | passing |
| Data consistency (`data/` ↔ `checkdata.txt`) | `pytest tests/test_campaign_data.py` | passing |
| Suspension data and its checkdata records | `pytest tests/test_suspension_data.py` | passing |
| AngelScript source rules (API calls, record guards, exemptions that regressed) | `pytest tests/test_plugin_source.py` | passing |
| Suspension generation | `ArchipelagoGenerate` at the easy cap and at the insane cap with classanity, platinum and priority medals, including a seed with no class in the starting inventory so the explosives gate binds | passing |
| Suspension in-game | — | reaching it and reading a round pass; the locks, the medals and the clear are still open |
| World generation, AP 0.6.7 | `ArchipelagoGenerate` on real seeds | passing |
| Option matrix | `missions_required` 1 / 8 / 17, strict + loose, suit and long jump on and off, 3-slot multiworld | passing |
| Campaign matrix | all four enabled, Opposing Force alone, They Hunger alone, every campaign switched off, and a pre-campaign YAML | passing |
| AngelScript plugin | in-game checklist below | passing except the boxes under "Still open" |

Ready-made YAMLs for the remaining items are in
[examples/verification/](../examples/verification/) — five seeds, each one
covering a group of the unchecked boxes below, with the unlocks and weapons they
need already in the starting inventory.

A lot of what is left waits on an item arriving. Rather than play until it does,
send it to yourself from the Archipelago server console:

```
/send <slot name> HEV Suit
```

The location and item tables are derived from the shipped `.bsp` files rather
than written by hand, so "does this entity exist in this map" is verified by
construction.

## In-game checklist

The AngelScript half has been written against the API as documented and as used
by Sven Co-op's own shipped scripts, but has not been executed. Work through this
in order — each step depends on the one above it.

### 0. Campaigns, first

Everything below assumes a Half-Life seed, which is still the default. Do these
first on a seed with **all four campaigns enabled**, because they are the parts
that have never run in-game at all.

- [x] **The consoles go where they say.** This is the one with a real chance of being
  wrong, and it *was* wrong once already: no campaign has a console for its intro
  mission, and wiring them as though it did put every Opposing Force panel a
  mission early, so the one labelled Welcome To Black Mesa opened boot camp.
  Press each Opposing Force console in turn and confirm the mission you arrive in
  is the one on the panel. Blue Shift too. The fix is one line of `consoles=` in
  `tools/campaign_layout.py` followed by a regenerate.
- [x] **The intro missions have no console at all** and are reached only by `!warp`:
  0 Black Mesa Inbound, 18 Incoming, 30 Living Quarters Outbound.
- [x] **Four missions are open at the start**, one per campaign, and `!ap` lists all
  40 missions grouped under campaign headings.
- [x] **Weapons cross over.** This is the untested engine question: receive an
  Opposing Force weapon (displacer, sniper rifle, spore launcher) while standing
  in a Half-Life map and confirm it arrives, draws, and fires rather than erroring
  or dropping the server. Those classnames are all in `server.dll`, so the risk
  is precaching rather than existence: models and sounds a Half-Life map never
  loaded. Test the reverse too, a crossbow or Tau cannon on `of1a1`.
- [x] **They Hunger's weapons deliberately do not cross over.** Receive a tommy gun
  or tesla gun while in Black Mesa: nothing should happen, no error, no crash.
  Warp to a They Hunger episode and it should be in your hands on the next spawn.
  Its arsenal is custom entities its own map scripts register, so asking for one
  elsewhere would ask the engine to build something that does not exist. If one
  *does* arrive on a Half-Life map, the `R` records are not being honoured.
- [x] **A finale ends its campaign, not the run.** Finish one campaign's last mission
  and confirm chat says that campaign is complete, the client logs how many are
  left, and the slot is **not** marked goal-complete. Only the last one should
  send `CLIENT_GOAL`.
- [x] **Blue Shift's ending is sealed as a pair.** Power Struggle has no unlock item
  at all: it opens on `blue_shift_missions_required` like the finale behind it.
  Before the count is met, `!ap` should read `sealed (...)` for both and both
  consoles should refuse, saying "sealed until more missions are done" rather
  than "locked" -- there is no item coming. Meet the count and Power Struggle
  opens; with it still unfinished, A Leap Of Faith should read
  `sealed (finish more missions, including Power Struggle)` however many other
  missions are done. Clear Power Struggle and it opens.
- [x] **The counts stay separate.** With `missions_required: 1` and
  `opposing_force_missions_required: 9`, one Half-Life mission opens Nihilanth
  and does nothing at all for Worlds Collide.
- [x] **A campaign left out of the seed** is absent from `!ap` entirely, campaign
  heading and all, rather than listed as "not in this seed". Its consoles still
  refuse with that message, since there the question was asked directly.
- [x] **Shared weapons still arrive without Half-Life.** On an Opposing Force only
  seed, receive the Shotgun and confirm you can pick one up. Attributing shared
  weapons to whichever campaign declared them left this seed with shotguns and no
  shotgun item, so every one of them was refused for the whole run.
- [x] **A Leap Of Faith is credited when it ends, not when it loads.** Warp in and
  confirm nothing is sent on arrival -- the campaign used to be won by
  connecting, because the outro is one map and arriving on a finale's last map
  is normally the only moment there is. Watch it through to the credits: the
  completion, the goal and the trip back to the hub should all land after the
  map's `game_end`, from the next map load if the server cycled somewhere else.
  Leaving early with `!hub` or `!warp` must credit nothing.
- [x] **Worlds Collide is credited when it ends too.** This port never plays
  `of6a5`: `of6a4b` ends the campaign itself, at the button by the guard before
  the descent, with "Sven Co-op Opposing Force: thanks for playing!" and a
  `game_end` five seconds later. Arriving on `of6a4b` must send its "Part 2
  Reached" and nothing more; press the button and the completion, the goal and
  the return to the hub should all land after the map ends.
- [x] **A finale is not credited on arrival.** Warp into A Leap Of Faith or
  Worlds Collide's last map, then leave with `!hub`: nothing is credited. Play
  it out instead and the credit lands after the map ends.

With `random_starting_weapon: true` and Opposing Force or They Hunger enabled:

- [x] **You spawn holding the rolled weapon**, not a crowbar, and it is the same
  weapon after a map change and after dying.
- [x] **Crowbars are refused.** Walk over one: the `First Crowbar` check still sends,
  the weapon is not kept. That is the point of the swap.
- [x] **The rolled weapon never arrives as an item**, because it left the pool.
- [x] With `allow_restricted_starting_weapon: true` and They Hunger enabled, the
  spanner becomes possible. If it rolls, expect to be **empty-handed outside They
  Hunger** until a weapon arrives: that is the documented rough edge, not a bug.
  Check the medkit is still there.
- [x] With only Half-Life or Blue Shift enabled it is always the crowbar, and the
  seed is indistinguishable from one with the option off.

`!tracker`:

- [x] Prints to console grouped by mission and map, `[x]` for found. The chat line
  reports the same totals.
- [x] Charger lines are absent entirely on a `chargesanity: false` seed, rather than
  listed and permanently unticked. Same for a campaign left out.
- [x] `!tracker hl_c03` and `!tracker office` both narrow it; the totals at the
  bottom stay for the whole seed.
- [x] Send a check and run it again: that location flips to `[x]` without a map
  change, since the client rewrites the snapshot as soon as the check lands.

Console spellings (`~`), which do the same work without opening chat:

- [x] **`.ap`, `.ap_tracker`, `.ap_find`, `.ap_warp`, `.ap_hub`, `.ap_help` — with
  the leading dot.** Sven namespaces a plugin's console commands from
  `concommandns` in `default_plugins.txt`; we set none, so the separator dot
  survives on its own and the bare name is an unknown command. The server prints
  the qualified list at load, and that line is the truth:

  ```
  Angelscript: Adding console command '.ap'
  [AP] console commands ready (6): .ap, .ap_tracker, ...
  ```

- [x] Each must behave exactly as its `!` twin, and `.ap_find hev charger` must take
  the whole phrase rather than only the first word.
- [x] `!` commands work in chat only, `.` commands in the console only. Typing `!ap`
  into the console is an unknown command and always will be.
- [x] They register when the module loads, not per map — and the module only loads
  on server start or `as_reloadplugins`, so copying new script files over a
  running server changes nothing.

`!find`:

- [x] `!find` with no argument names the nearest unfound check on your map, where
  "nearest" counts height several times over: something 800 units above you is a
  hunt for the stairs, not a walk. Ranking by the straight line offered Office
  Complex's shotgun (677 out, 791 up) ahead of two chargers on the player's own
  floor. Stand at the Office Complex spawn and confirm it offers a charger rather
  than the shotgun.
- [x] Walk toward whatever it named and run it again: the distance must fall. That is the whole test of
  whether the coordinates are right, and it is worth doing in one Half-Life map,
  one Opposing Force map and one They Hunger map, since the position comes from
  the BSP rather than anything the game tells us.
- [x] Stand next to a charger and `!find` it: a few dozen units, "right about where
  you are standing", clear line.
- [x] Turn 180 degrees on the spot and run the same `!find`: the distance must not
  change and the bearing must flip to "behind you". Left and right come from your
  own facing, so this is the check that they are not reversed.
- [x] `!find hev charger 3` matches by name; `!find shotgun` on a seed with several
  campaigns lists the matches to console rather than guessing.
- [x] `!find` for something in another mission names the mission and its `!warp`
  number instead of pointing.
- [x] The line is a straight one and will happily point through a wall. "Something
  solid is in the way" is the tracer saying so, and is expected in corridors.

### 1. The plugin loads

- [x] Start a listen server on `-sp_campaign_portal` and check the server console
  for `[AP] loaded 40 chapters, 706 locations`.

```
[AP] loaded 40 chapters, 706 locations
```

706 includes Suspension's 348, which the data file describes whether or not a
seed contains the map. Before the arcade map existed this line read 37 chapters
and 353 locations; if you still see those numbers, the plugin is reading an old
`checkdata.txt`.

If it is missing, the plugin is not registered or `checkdata.txt` is not in
`svencoop/scripts/plugins/store/archipelago/`. The counts are for all four
campaigns, which the data file always describes in full; a seed that leaves some
out says so through `excluded`, not by shrinking this file.

### 1a. Chat output is not truncated

- [x] Run `!help`: eight lines, ending with "Or press a mission console's button
  in the hub." Nothing ends mid-word.
- [x] `!find` on a long-named location prints the name, the bearing and the line
  of sight as three separate messages, none of them cut off.

The engine's client print buffer is **128 bytes** and cuts a longer message off
without a word, which is why every multi-line message is now one call per line.
Run `!help` and count: eight lines, ending with "Or press a mission console's
button in the hub." Anything ending mid-word means a print grew past the limit
again.

Worth the same glance at `!find` on a location with a long name, since
"They Hunger: Episode 1 - Health Charger 1 (Part 2)" plus a bearing is well over
128 on its own. It prints the name, the bearing and the line of sight as three
separate messages for exactly that reason.

### 2. The bridge round-trips

With the client connected:

- [x] `ap_in.txt` appears in the store folder.
- [x] `!ap` in chat prints the mission list with one mission unlocked.
- [x] `HELLO|<map>` appears in `ap_out.txt`.
- [x] Chat says `[AP] Connected to the multiworld.`

### 3. Weapons are gated

- [x] Walk over a shotgun in Office Complex and note which of the four outcomes
  below happens.
- [x] `hl_c11_a1` equips nine weapons via its `.cfg`; you spawn there with only
  the crowbar.

The riskiest assumption in the plugin is that `Hooks::PickupObject::CanCollect`
fires for weapon entities and not only for item pickups. The outcomes, best
first:

- **Check is sent** (chat shows the location name) — the pickup path works.
- **Weapon is refused** — `CanCollect` covers weapons. Good.
- **Weapon is kept for up to a second, then vanishes** — `CanCollect` does not
  cover weapons and `SweepIllegalWeapons` in `ap_items.as` is doing the work.
  That is the intended fallback; it is worth tightening `SWEEP_INTERVAL`.
- **Weapon is kept permanently** — neither path fired. Check that the classname
  appears as a `K` record in `checkdata.txt`.

### 4. Mission gating and completion

- [x] Press a console button in the portal room. It should warp on the press, with no
  "Access Denied" clip. Pressing a locked mission's console should print the lock
  message instead.
- [x] `!warp` into an unlocked mission, `!warp` into a locked one (must be refused).
- [x] Play a multi-part mission to its end. The completion check should send, the
  next chapter's first map will load briefly, and you should then be returned to
  the hub. That brief load is deliberate: `MapChange` never cancels a transition,
  because doing so and then issuing our own `changelevel` crashed the game.
- [x] Run `restart` mid-mission. Nothing should be sent and nothing should change
  level; a restart re-enters the same map and is not a transition.
- [x] Type `!hub` from the middle of a mission. You should go back to the hub with
  **no** completion check, since you did not leave from the mission's last map.
- [x] Type `!hub` from a **one-map** mission you just warped into (Office Complex).
  Still no completion: a transition we asked for is never a completion, however
  far into the map you got.
- [x] Finish a mission the campaign chains straight into another (Unforeseen
  Consequences runs into Office Complex). Office Complex must send **nothing** —
  no "Reached" on the way through, no "Complete" on the way back to the hub. This
  is the phantom-check regression: reaching a mission you were bounced out of
  used to credit both.
- [x] `MapChange` is observational only. Cancelling a transition with
  `HOOK_HANDLED` and then scheduling our own `changelevel` crashed the game, both
  on `restart` and on genuine mission completion, so the hook now only records
  what happened. Everything acts from `MapStart` on the far side of the
  transition, and `ChangeLevel` queues the command rather than calling
  `ServerExecute` to run it synchronously.
- [x] **A carried-through mission sends nothing, unlocked or not.** Finish
  Unforeseen Consequences with Office Complex already unlocked: no "Reached", no
  weapon checks, and a bounce back to the hub. The only guard used to be the
  locked test, so an unlocked mission counted as played. The console now says
  `carried into <mission> from <mission>; not playing it` when it bounces, and
  `FATAL: could not queue the hub return` if the older file-based guard fails.
- [x] Repeat with the next mission **unlocked**. Still nothing: you were carried
  through it, not playing it.

### 5. DeathLink

With two players in the lobby and two AP slots on DeathLink:

- [x] One player dies → everyone else gibs, and the other slot dies. Exactly one
  DeathLink is sent, not one per player.
- [x] An inbound DeathLink gibs the whole lobby, in the hub and mid-mission.
- [x] No bounce-back loop (watch the client log for a run of alternating deaths).
- [x] Trigger a DeathLink during a map load → it must be ignored on arrival, not
  applied.

With `death_link_amnesty: 2`:

- [x] Die → lobby gibs, chat reads "Amnesty remaining: 1", **no** DeathLink in the
  client log. Die again → "Amnesty remaining: 0", still nothing sent. Die a third
  time → no amnesty line, and one DeathLink goes out.
- [x] The fourth death starts the cycle again at "Amnesty remaining: 1".
- [x] Spend one death, change level, die again → the countdown continues from where
  it was. It lives in `ap_amnesty.txt`, not in a global.
- [x] An inbound DeathLink must not spend amnesty; only local deaths do.
- [x] `/amnesty 0` in the client → the very next death goes straight out.
- [x] Kill four players with one explosion → still exactly one DeathLink.
- [x] **With `death_link: false`, dying takes nobody with you.** The death is
  still reported to the client, which is what lets it decide, but the lobby wipe
  is the DeathLink and a seed without one must not have it.

### 4b. HEV suit

With `shuffle_hev_suit: true` and the item not yet received:

- [x] The weapon HUD is present and weapons can be switched with the number keys and
  the mouse wheel. This is the regression that made an unsuited run unplayable.
- [x] Armour reads 0 on spawn even though the campaign's own loadout grants some.
- [x] Pick up a battery → armour stays 0.
- [x] Hold use on an HEV charge panel → the number does not climb.
- [x] An `Armor Battery` filler grant → chat says it arrived, armour stays 0.
- [x] Walk over the suit pickup in Anomalous Materials → refused, with the usual
  "you have not found the HEV Suit yet".

Then receive the item:

- [x] Chat announces the suit, and armour starts accumulating from all four sources.
- [x] Cross a map boundary → no second announcement.

With `shuffle_hev_suit: false`, armour must work from the first spawn. This used
to be gated on an item the seed never sends, leaving the player with no armour
for the entire run.

`shuffle_longjump: false` is deliberately *not* the same. The module is left to
the campaign rather than granted, so on a seed with it off:

- [x] Anomalous Materials through Surface Tension: no long jump. Granting it here was
  the bug this split fixed, and it looked like the module being permanently on.
- [x] Xen (`hl_c14`) and everything after: the module works, from
  the map's own `.cfg`, with nothing from us. The pickup itself is in Lambda
  Core (`hl_c13_a4`), the only map that has an `item_longjump` entity at all;
  `hl_c14`, `hl_c15`, `hl_c16_a1`-`a4` and `hl_c17` are the maps whose `.cfg`
  equips one.
- [x] Check `ungated=item_longjump` is in `ap_in.txt`, and that it is absent with
  `shuffle_longjump: true`.

### 5a. Weapon pickups

- [x] Walk over a weapon you have **not** been granted, in the mission that holds its
  vanilla first copy: the check sends and the centre-screen "you have not found
  the X yet" still appears.
- [x] Walk over the same weapon type in **any other** mission: nothing sends. The
  check belongs to one place in the campaign, not to the weapon.
- [x] Walk over a weapon you already own: the check still sends. The engine's pickup
  hook does not fire for a duplicate, so this is the proximity sweep doing it.
- [x] `First Crowbar`, the case that only the sweep can send, since the crowbar is
  never collectable. Stand next to Half-Life's crowbar and wait a second.
- [x] With `chargesanity: false`, charger presses send nothing and the client logs no
  rejected checks.
- [x] **Holding a weapon does not send its check.** Stand anywhere in the mission
  a weapon's check is anchored to while carrying that weapon: nothing sends.
  Walk over the copy lying in the world: it sends.
- [x] **Being given a weapon does not send its check either.** Warp into Office
  Complex with the Shotgun in the starting inventory (seed 1): nothing sends on
  spawn. Then walk over the map's own shotgun and First Shotgun lands. Same test
  with the item arriving mid-map from `/send`: the grant is silent, the copy on
  the floor is not.
- [x] **Loadout ammo arrives in one step**, at half of each weapon's maximum, and
  a respawn is one pickup sound per weapon rather than a long crawl.
- [x] **Standing still costs nothing.** Fire a few shots, then stand about for a
  minute, then reload. No ammo arrives. Two separate faults did this:
  the loadout topped up every weapon held rather than the ones it had just
  granted, and it asked whether a player held a gun by one classname when the
  gun has two — so the Glock, MP5 and SAW were handed over again every sweep,
  each grant bringing a clip with it. The glock's tell was 17 rounds at a time
  up to its 250 cap, and a refill the moment it was fired.
  A burst of ammo out of nowhere is now either a run of `Ammo Cache` filler
  draining from the event backlog, which is what that item does, or one of
  these regressing.

### 5b. Chargers

- [x] **`ba_canal1`'s two health chargers.** They are built from one brush, `*196`,
  with the second shifted 80 units, so they are the only pair in the game the
  model alone cannot tell apart. Drink from both: each must send its own check,
  and neither may send the other's. If the second sends nothing, the engine is
  not reporting the `origin` the generator wrote into its key.
- [x] Press use on a health charger and an HEV charger; each sends its own check
  once, and pressing it again sends nothing.
- [x] ~~An empty charger still sends its check.~~ Sven appears to have no empty
  chargers, so there is nothing here to test.
- [x] Chargers in a mission you re-enter later do not resend.
- [x] Press use on ordinary buttons, doors and levers → no checks, no log spam.

### 5c. Traps

With the long jump module already received, spring any trap and watch the floor:
no module should appear. The loadout is reapplied on every snapshot change, and a
trap arriving is one, so this used to drop a module each time.

Check the module itself still works, since it is now switched on directly rather
than by handing over a pickup: with it received, duck-jump should long jump. With
`shuffle_longjump: true` and the item not yet received, it should not — including
on a map whose own .cfg hands one out.

The case that matters most is a map change, and `hl_c14` onward is where to test
it, since those maps hand a module out themselves. Long jump on one of them with
the item still locked, then cross a map boundary: the jump must be gone on the
far side. The player's flag is reset by the new map but the physics key the
engine actually reads is not, so a module picked up on one map can otherwise
follow the player into the next.


Generate with `trap_percentage: 100` for a seed that is nothing but traps.

- [x] Scientist Trap: four scientists appear around **every** living player, and each
  set is four *different* scientists rather than four of the same model.
- [x] Headcrab Trap: four headcrabs per player, same placement.
- [x] With two players standing apart, both get their own four. Standing together,
  they get eight between them — that is intended, not a bug.
- [x] Neither should spawn inside geometry. Stand with your back to a wall, in a
  corridor, and in a lift, and check nothing arrives stuck. Some bearings finding
  no room is expected and fine; all four failing is not.
- [x] Butterfingers: every living player's held weapon lands on the floor, and stays
  there. Watch for a full second — the loadout sweep must not put it back.
- [x] Wait thirty seconds without touching it: the weapon is reissued.
- [x] Spring Butterfingers, then change level before the timer runs out. The weapon
  comes back on the new map rather than being withheld against a clock that
  restarted.
- [x] Spring Butterfingers, then die. The weapon comes back on respawn.
- [x] Springing any trap with nobody alive must not error; the trap is simply spent.

### 6. Goal

On a short test seed with `missions_required: 1`:

- [x] Nihilanth stays sealed until one mission is complete.
- [x] It opens once that mission is done.
- [x] Killing Nihilanth sends `GOAL` and the client reports the goal to the
  server.

### 7. Suspension

- [x] **Suspension is a seed of its own.** With every campaign off and
  `suspension: true`, the seed contains the bridge and nothing else.
- [x] **You can get there at all.** `!ap` lists Suspension under an Arcade
  heading with `!warp suspension` beside it, and that warp works from the hub.
  It is not a mission and has no console, so this is the only way in. On a seed
  without it the heading is absent entirely — `!warp suspension` is the one place
  that still answers "not in this seed", because there it is a direct question.
- [x] **The counters.** The plugin creates `trigger_changevalue` entities answering
  to names the map already fires (`s3_events`, `win_red_tickets`,
  `start_events`, `end_script`) and reads its own `info_target` counters. If a
  plugin-created entity is *not* fired by the map's own multi_managers, nothing
  about a round is observed and no Suspension check ever sends. Symptom: the
  round plays normally and the log never says "suspension: tier voted". This is
  the load-bearing assumption of the whole module.
- [x] **The class names match the lobby signs.** Assault, Grenadier, Pointman,
  Support, Sniper, Medic, Engineer, Juggernaut. The map's entities are named
  differently (`shotty` is Pointman) and the checks must read as the signs do.

The rest of the arcade map is below the divider.

---

## Still open — 08/14/26

Everything above has been run in game and passed. Everything below has not, or
failed when it was tried and has been changed since. An item moves up the moment
it passes, so this section only ever shrinks, and each one keeps the heading it
belongs to.

Use [examples/verification/](../examples/verification/) — five seeds, each
covering a group of these, with the unlocks and weapons already in the starting
inventory. Suspension is seed 5, which now contains nothing but the bridge.

### What changed since the first pass

Every fault found so far and what was done about it, in the order they were
found. Most have since been retested and their boxes are above; the ones that
have not are the boxes below.

- Class names were invented from entity names and are now the lobby's own:
  Assault, Grenadier, Pointman, Support.
- `!ap` never listed Suspension and `!warp suspension` did not exist. Both work.
- No class booth or vote button was ever locked. Both lock now by going
  non-solid, because refusing at PlayerUse printed the message and let the press
  through underneath it.
- Non-solid was not enough either, found on the second pass: the difficulty vote
  still went through. A locked button now has its `target` blanked as well, which
  leaves it firing nothing however it is pressed, restored from what the map had
  when the item arrives. The whole set of locks is also reasserted once a second,
  because the map kills all four buttons by wildcard (`kill_vote_button`) and a
  lock applied once at map load is only as good as whatever the map does next.
- Making them vanish also meant they refused in silence, and the fix for that
  was to stop touching their solidity at all. A locked button is left where the
  map put it, so the use trace lands on it and PlayerUse answers the press with
  a sentence; the cut wire is what makes answering it safe.
- **`SOLID_BSP WITHOUT MOVE_PUSH` — twice, from two different causes.** The
  engine checks `solid` against `movetype` every time it links an entity, and
  the pair being wrong is fatal rather than cosmetic. First it was a relink of
  our own (`SetOrigin` to the origin the entity already had) revalidating a
  button; that is gone, and no map entity is ever relinked now. Then it turned
  out the Juggernaut's seal had been wrong all along: the seal is a
  `func_wall_toggle` **and** a `trigger_hurt`, and sealing set SOLID_BSP on both
  — legal for the wall, fatal for the trigger the next time anything linked it,
  which is why it landed on a respawn in the lobby rather than at the moment the
  seal was set. Switching an entity on now asks what it is: a pusher gets
  SOLID_BSP, everything else SOLID_TRIGGER.

  Worth writing down, since it looked like a spawn-room fault: that `trigger_hurt`
  is `*310`, at the Juggernaut booth doorway (6260..6277, -6064..-6000), not in
  the spawn area. Seven other entities share the name `jugger` — five
  `trigger_changevalue`, a `trigger_changemodel` and a `game_player_equip` — so
  the seal has always had to filter by classname as well as by name, and the
  filter is what kept it down to two.
- Locked class booths, three wrong answers deep. The portals are 64x64 slabs four
  units thick standing in the booth doorways, so a player is never *in* a booth:
  walking into one teleports them past it. Switching the teleport off did not
  close the booth, it opened a room whose only way out was the teleport that had
  just been disabled, and players stuck. Pointing the teleport at an
  `info_target` on the map's first spawn point instead teleported them inside a
  wall. Making the slab itself solid is the fatal pair above, since a trigger is
  no pusher. What is there now is a `func_wall` of ours across the doorway, built
  by the engine from the portal's own brush so it is spawned legally and is the
  right size by construction, and removed rather than disabled when the item
  arrives. The map's own portal is not touched at all.
- Neither lock said anything. A locked booth is a wall and a wall cannot be
  pressed, so the refusal is on proximity: walk up to one and the centre of the
  screen reads "You have not found the Sniper yet", the same sentence in the
  same place as a weapon that has not been granted.
- Then the vote refusal said it several times a second. `Hooks::Player::PlayerUse`
  fires every frame for every player rather than on a press, so looking at a
  locked button from across the lobby was enough to answer it over and over. It
  now waits for `IN_USE`, and both refusals repeat at most once every four
  seconds per player.
- The booth wall was the worst of the four attempts. A `func_wall` of ours, built
  from the portal's brush, stayed standing after its class had been earned: the
  `EHandle` to it came back null while the entity did not, so unlocking removed
  nothing and the guard that explains a shut booth skipped it for the same
  reason — no message, no way in, until the map reloaded. A `restart` while one
  stood crashed the game outright, with no error line to go on. The plugin no
  longer creates anything on this map: a locked portal is switched off, and a
  player who walks through a switched-off doorway is put back at their own last
  position outside it. Blaming the crash on the wall is a suspicion rather than
  a diagnosis — it is what changed, and it is what a `restart` retest settles.
- The goal changed shape. It was "a run cleared as the Juggernaut at the capped
  tier", with the Juggernaut itself an item in the pool — which was wrong twice
  over: the map already gates that class behind clearing with the other seven,
  so the item unlocked something the map would open anyway, and being handed it
  early skipped the map's own rule. The Juggernaut is out of the pool entirely
  and the goal is now a run cleared with **all eight classes at the capped
  tier**, with `suspension_goal_requires_award` deciding whether those clears
  must earn the seed's medal as well. Both are counted from checked locations by
  the client, so the plugin no longer sends a goal for the arcade at all.
- The round loop never stopped. Our counters latch, so consuming the end signal
  without spending it let the think loop end the round, restart it on the start
  signal still standing, and end it again four times a second. Both counters are
  zeroed as they are read.
- A medal was only sent if the run scored *exactly* one the seed contains, so a
  five-death gold on a bronze-capped ladder sent nothing. Every medal the deaths
  earned is sent now, and the bottom rung is always earned.
- The Juggernaut's placeholder icon flashed. The reveal is a multi_manager fire
  and the seal is reapplied by the one-second lock sweep, so it was fired again
  every second; it is applied only on a change now.
- The arcade ends its own map, and the server followed its map cycle into a map
  the seed knows nothing about. A scored round warps back to the bridge.
- `!warp` matched a mission on any part of its name but the arcade map only on
  the whole of it, so `!warp susp` found nothing and Suspension was the one
  place in the command that had to be typed out. It now takes a fragment like
  everything else, and appears in the "be more specific" list when a fragment
  matches it and a mission both.
- The Juggernaut icon drew on top of the placeholder instead of replacing it.
- Weapons and equipment were still being gated on the arcade map through
  `PickupCanCollect` and the weapon sweep, which also meant a class loadout's
  shotgun could send Half-Life's First Shotgun from the bridge.
- Loadout ammo arrived one grant at a time at each weapon's uneven default.
  Every held weapon is now topped up to half its maximum in one step.
- The weapon sweep counted the weapon in your own hands. A carried weapon is
  still an entity of that classname and its origin is your origin, so holding a
  shotgun anywhere in the map its check is anchored to sent that check. Only
  copies lying in the world count now.
- The other half of the same fault, found on the second pass: being *handed* a
  weapon sent its check too. `GiveNamedItem` builds the weapon and touches the
  player with it before it returns, so the loadout's own grant reached the
  pickup hook indistinguishable from walking over one — arriving in Office
  Complex with the Shotgun already received sent First Shotgun on spawn. Our
  grants now raise a flag the hook reads, and anything else built at the
  player's own origin (a map `.cfg` loadout, `game_player_equip`) is refused a
  check by where it is.
- Missions the seed left out are no longer listed at all.
- Releasing a mission's completion from the server did nothing in game. The
  client now rebuilds finished missions from the server's checked locations.
- The other half of that, found on the second pass: the seal counted a released
  completion but `!ap` did not show it. The list decided a mission was complete
  by asking whether every location in it had been found, which a released
  completion does not make true, so the mission read "unlocked" while the finale
  behind it had already counted it. `!ap` now reads the mission's own completion
  check as well as the all-found sum.
- Reconnecting kept the previous slot's state. A changed client session now
  clears everything and returns the lobby to the hub.
- Except the session was the wrong thing to watch, found on the second pass: it
  is minted once per client launch, so it fired when the same slot reconnected
  from a restarted client and stayed put when a different slot was connected
  from the client already running — which is the one that matters, and the one
  that did nothing. The snapshot now carries `slot=<seed>:<slot number>` and the
  reset hangs off that. An empty slot is a disconnected client, not a new run,
  so a dropped connection on its own moves nobody.
- A finale could be credited on arrival, because the armed-but-unplayed flag
  carried no record of which map armed it and a second `MapStart` on the same
  load consumed what the first had set.
- Being carried into an *unlocked* mission counted as playing it. The pass-through
  guard only ever asked whether a mission was playable, so the lock check caught
  locked ones and nothing caught the rest. It now asks whether we meant to be
  there at all: we asked for the map, it is another part of the same mission, or
  the server started on it.
- That guard then overreached, found on the second pass: warping from inside one
  mission to another arrived and bounced straight to the hub. The return was
  armed by *any* transition that left a mission for a map outside it, ours
  included, so `!warp` and the console buttons queued their own undoing. It is
  armed only for the campaign's own transitions now, and a map we asked for
  outranks a pending return that outlived whatever set it.
- Both pending-state writes now log loudly when they fail. A silent failure of
  the hub-return write is what a phantom check looks like from the outside.
- A death wiped the lobby even with DeathLink switched off. The wipe *is* the
  DeathLink; only the report to the client was ever meant to be unconditional.

### 2. The bridge round-trips

- [x] **Releasing a mission's completion from the server console applies in
  game.** `/send` its "- Complete" location and the mission counts toward the
  seal without the game having played it, **and** `!ap` reads it as `complete`
  straight away, with the rest of its locations still unfound.
- [x] **Reconnecting is safe.** Disconnect, connect a different slot **from the
  same running client**: the lobby returns to the hub, previously sent checks
  are forgotten, and the new slot's first checks send rather than being
  swallowed as duplicates. The server console says `client slot changed`.
- [x] **The same slot never moves you.** Disconnect and reconnect the same slot,
  and restart the client entirely and connect the same slot again: no hub
  return, nothing forgotten, and you stay in whatever mission you were playing.
  A momentary drop is not a new run.

### 5. DeathLink

`lobby_death_link` pulls the two halves of DeathLink apart: the report to the
multiworld, and the lobby going with you. Seed 4 carries `on` for slot A and
`off` for slot B, so one lobby shows both.

- [ ] **`off` still sends.** B dies: nobody else in the lobby is gibbed, and A's
  world still receives the DeathLink. A dies: everyone gibs, as always.
- [ ] **Inbound is not governed by it.** Send B a DeathLink from another world
  with `off` set: the lobby still gibs. Being killed by one is what receiving
  one means, and the slot is the whole lobby.
- [ ] **`death_link: false` overrides it.** With DeathLink off and
  `lobby_death_link: on`, a death takes nobody: the wipe has nothing to be the
  point of. The client resolves that before the game sees it, sending
  `lobby_death_link=off` rather than leaving the plugin to reason about it.
- [ ] **`non_arcade` spares Suspension only.** Die in a campaign mission and the
  lobby gibs; die on the bridge and it does not, while the death still counts
  toward the medal and still reports to the multiworld.

### 4. Mission gating and completion

- [x] **Warping mission to mission stays put.** `!warp` from the middle of one
  mission straight into another, and from a mission's last map into another:
  you arrive and stay, with no "Returning to the hub". Same by console button.
  The bounce belongs to a mission the campaign carried you into, and that case
  has already passed, so this must not have cost it.

### 7. Suspension

Seed 5. Getting there and reading the round is confirmed; nothing past that is.

Two things about the map itself, so neither is mistaken for a plugin fault. The
explosives crates (`restock_explo`) equip **Engineer, Grenadier and Pointman
only** — `class_engineer` gets a satchel and a tripmine, `class_GL_soldier` AR
grenades, `class_shotty` hand grenades. Assault is not on that list and never
was, so the tank is not its fight; take one of those three. And the lobby floor
is four `trigger_push` volumes covering the spawn points, which is why spawning
shoves you into the room. Nothing of ours touches either.

The first of those is now a logic rule: every check from **section 2** onward,
plus the clears and the medals, sits behind holding one of those three class
items. Section 1 alone is open to any class. The entity list would have put this
at section 4, where the named tank fight is; play found armour to deal with in
section 2 as well, which is what the crate in that section is there for, and the
report wins.

- [x] **The gate is real, in both directions.** With only, say, the Sniper and
  the Medic held, a run cannot get past section 2; take the Grenadier and it can.
  If a tank turns out to be killable by gunfire alone — they are 1500 health
  `func_breakable`s, so they are not obviously immune — this rule is stricter
  than the map and should be relaxed, not the other way round.

- [x] **`!warp susp` gets there**, and so does any other part of "Suspension" or
  of the map name. The arcade was only ever compared for equality while every
  mission matched on a fragment, so it alone had to be typed out in full. A
  fragment that matches the arcade *and* a mission now lists both rather than
  guessing.
- [x] **The vote buttons.** With one Progressive Suspension Difficulty item held,
   easy and medium should be pressable and hard and insane should not be there
   at all. The mapping is `vote_button4` easy through `vote_button1` insane —
   backwards from the tier order, so an off-by-one here locks the wrong buttons.

   A locked button is **there, pressable, and refuses out loud**: chat says
   "Hard is locked. Find Progressive Suspension Difficulty." and no vote is
   cast. Making them vanish worked as a lock and was wrong as an answer — a
   button that is not there cannot be pressed, so nothing could be said about
   it, and the tier order made a silent gap easy to mistake for a bug.

   The refusal must be **one line per press, not a stream**. PlayerUse is a
   per-frame hook rather than a per-press one, so the first version answered
   several times a second to anyone merely looking at the button. It now
   requires `IN_USE` and repeats at most every four seconds.

   What holds the lock is that the button's `target` is cut while it is locked,
   so the press fires nothing whatever route reached it. Solidity is left
   exactly as the map built it, which is what gives the use trace something to
   land on and the refusal something to answer.
- [x] **A locked class booth turns you round and says why.** Walk into one whose
  item has not arrived: you are put straight back where you were standing, and
  the centre of the screen reads "You have not found the Sniper yet" — the same
  sentence, in the same place, as a weapon you have not been granted. Then
  receive the class **mid-round** and walk in: the booth must open there and
  then, without a map load.

  Four versions of this have been wrong, each worse than the last. Switching the
  teleport off opened a room whose only way out was the teleport, and players
  stuck inside it. Pointing the teleport at a spawn instead put them inside a
  wall. Making the trigger itself solid is the fatal solid/movetype pair. A
  `func_wall` of ours built from the portal's brush then outlived the class being
  earned — the handle came back null while the brush stood, so the booth stayed
  shut with nothing to say and nothing to remove — and a `restart` with one
  standing crashed the game with no error at all.

  Nothing is built now and nothing of the map's is made solid. The portal is
  switched off, and a player who crosses a switched-off doorway is put back at
  their own last position outside it, which needs nothing known about the map.
- [x] **`restart` on the arcade map does not crash.** With a class locked, with
  one just unlocked, and mid-round. The crash had no error line, so the only
  evidence either way is whether it happens again.
- [x] **The Juggernaut icon replaces the placeholder** rather than drawing on
  top of it, **and neither flashes**. The seal is applied from the one-second
  lock sweep, and firing the reveal is not idempotent — a multi_manager fire
  every second made the placeholder blink over the icon for as long as anyone
  watched. It is applied only when the answer changes now.
- [ ] **One clear line per clear.** Finishing a run said "cleared on easy" and
  "easy underway" alternately, several times a second, for the rest of the map.
  Our counters latch — the map sets a signal once and it stands — so reading the
  end signal without spending it meant the round ended, restarted on the start
  signal still standing, and ended again. Both are zeroed as they are consumed.
- [x] **The map comes back to the bridge.** The arcade ends its own map when the
  bridge is taken, and the server then followed its map cycle into something
  that is not in the seed at all. A scored round now warps back to Suspension on
  the far side of that change. `!hub` is still how to leave.
- [x] **The medals land.** Clear a run and every medal the deaths earned arrives,
  not only the best one: five deaths is a gold, and on a seed whose ladder stops
  at bronze that used to send *nothing at all*, because the one medal the run
  was scored as was not a check in this seed. A won run always earns the bottom
  rung whatever the deaths.
- [x] **Section boundaries.** Confirm each section credit lands as that section
  falls, not one early or one late. `s6` hangs off `s6_captured_text` rather
  than `s7_apc_start`, because the latter is delayed twenty seconds.
- [x] **The Juggernaut is earned, not sent.** It is no longer an item and is not
   in the pool at all: clear a run with each of the other seven, at any tier,
   and the booth opens on its own. Nothing arrives in chat, because nothing was
   sent — the client works it out from the seven clears it has seen checked and
   puts the class in the snapshot.
- [x] **The Juggernaut booth itself.** Below insane the booth is believed to be
   inert, so the plugin watches the portal box and grants the class itself.
   Confirm the portal grants it once it has been earned, that a second player is
   refused, that the restock stations still work for the granted class (they
   filter on `targetname`), and that the model change takes —
   `g_EntityFuncs.SetModel` on a player is the least certain call in the module,
   and if it does nothing the class is still mechanically correct and merely
   looks wrong.
- [x] The medal matches the team's death count.
- [x] Every lesser medal arrives with it.
- [x] Section checks land for the classes in play, and nothing lands for a class
  nobody was holding.
  - [] Test this with a bigger mix of classes
- [x] The clear is credited to the class each player spent most of the run as.
- [ ] **The goal is eight clears at the capped tier.** One per class, the
  Juggernaut included, all at the hardest tier the seed contains. The plugin
  sends no goal for the arcade any more — the condition is a set of checks
  rather than an event, so the client decides it from what the server says is
  checked, which also means releasing those clears counts.
- [ ] **`suspension_goal_classes` shortens that list.** With `[assault, medic]`
  the goal is those two clears at the capped tier and nothing else — the other
  six classes are still items and still have checks, they just are not the
  finish line. Naming the Juggernaut still costs the seven clears the map wants
  before it opens, whether or not those seven are named.
- [ ] **`suspension_goal_requires_award: true` adds the medal**: the same eight
  clears, plus the seed's hardest medal at that tier. Off, deaths do not matter.
- [ ] **Reaching it does not win a seed that has campaigns in it.** On a mixed
  seed, finishing Suspension reports the arcade and nothing else; the slot is
  only marked complete once every campaign's finale has landed too.
