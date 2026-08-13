# Porting the Half-Life campaign to retail Half-Life

An implementation plan for taking the Half-Life half of this project and making
it run on Valve's Half-Life (GoldSrc) instead of Sven Co-op, keeping the
architecture that already works here: a Python client that owns the Archipelago
connection, a file bridge, generated data derived from the shipped BSPs, and
mission gating with a hub.

The existing vanilla effort at
[GoldSRC-Archipelago/halflife-archipelago](https://github.com/GoldSRC-Archipelago/halflife-archipelago)
takes the APDoom shape: a full HL SDK mod, client dll and server dll, with the
Archipelago connection compiled into the game. Nothing below depends on it, and
none of its code is reused, but its choice of a mod folder as the delivery
vehicle is the same one this plan lands on.

## What carries over unchanged

Roughly 70 percent of the existing work is engine-independent.

| Piece | Status in a vanilla port |
| --- | --- |
| `tools/bsp_entities.py` | unchanged. Sven and retail both ship GoldSrc BSP v30; lump 14 parses identically |
| `tools/build_campaign_data.py` | unchanged. It is already driven entirely by `CAMPAIGNS` plus a maps directory |
| `tools/gen_checkdata.py` | unchanged |
| `client/bridge.py` | unchanged, copied into the new world |
| `client/launcher.py`, `client/settings.py` | ~90 percent unchanged. Paths, the install routine and the game name change |
| `docs/protocol.md` | unchanged as a contract. The game side of it is reimplemented |
| `items.py`, `locations.py`, `regions.py`, `rules.py`, `options.py` | structurally unchanged, minus the three campaigns that do not exist here |
| `tools/campaign_layout.py` | rewritten for one campaign against retail's map names |
| `plugin/*.as`, 4300 lines of AngelScript | fully rewritten in C++ |

So the port is: one new layout table, one new game-side plugin, and packaging.

## Decision 1: how the game gets a hook surface

Retail Half-Life has no scripting API. Three ways in, in order of preference.

Both live in the same place: a `hlap` game directory with `liblist.gam` carrying
`fallback_dir "valve"`, so the player's own install is never touched, all maps
and assets are inherited, and the mod folder gives us somewhere to put a hub map.
The packaging is settled either way; only what sits behind `gamedll` differs.

**A. Server dll built from the official Half-Life SDK (recommended).** Full C++
class access: `GiveNamedItem`, `RemovePlayerItem`, `PlayerUse`, `ItemPreFrame`,
the same surface Sven's AngelScript API wraps, and no third-party dependency.

The objection to this used to be fidelity, on the assumption that the public SDK
was the 2003-era code and a build from it would be "close to retail" rather than
retail. That is no longer true. Valve's
[ValveSoftware/halflife](https://github.com/ValveSoftware/halflife) repository
has been updated with the 25th anniversary changes and tracks the shipped game
as of the October 2024 patch, so a dll built from it is the current game's own
logic. That removes the only real reason to prefer B, and it also removes the
one thing B cannot do (see the note on stripping weapons below).

**B. Metamod plugin, retail's `hl.dll` underneath.** Metamod sits between engine
and game dll, so the game logic is literally Valve's shipped binary: maximum
fidelity, and the plugin is smaller because it only adds behaviour. Still a
reasonable choice, with two caveats found while researching this:

- **Single-player Metamod is a niche path.** It works, and metamod-p's dynamic
  link-entities exist specifically to solve the export problem single-player
  hits, but it is a path kept alive mainly for bots and it is far less trodden
  than the multiplayer case.
- **Anniversary support is probable, not documented.** metamod-p's last release
  was v1.21p109 in May 2024, post-anniversary, described as the first update in
  eight years with expanded game support, and AMX Mod X (a Metamod plugin) is
  reported working on the current build. Nothing states single-player retail
  Half-Life on the anniversary engine specifically. Its own changelog has not
  been updated since 2012.

Metamod also cannot remove a weapon the player already holds without offset
hacks. The design works around that by gating at pickup rather than stripping
after the fact, but the workaround is a constraint the SDK path simply does not
have.

**C. Client-side patching or a custom engine.** Rejected. It is what the other
effort ends up needing, it breaks on every Valve update, and nothing in this
design requires touching the client.

Plan for A. Phase 0 stays as a spike, but its purpose shifts: confirm the SDK
builds and runs against the installed engine, rather than confirming a
dependency exists.

## Decision 2: keep the file bridge and the Python client

Do not compile an Archipelago client into the game dll. The bridge protocol,
the event windowing, the ACK scheme, the DeathLink amnesty rule and Universal
Tracker support are all working and tested here, and `bridge.py` has no game
dependency at all. In C++ the file half of it is easier than it was in
AngelScript, not harder.

Consequences worth stating up front: the player still runs the Archipelago
client alongside the game, and the game side stays stateless across map loads,
which in retail also buys save/load resilience for free.

## Hook mapping, Sven to retail

Every hook the AngelScript plugin registers has a counterpart. This table is the
core feasibility argument, and it is deliberately written against the harder of
the two options: under A, most of these are direct calls into the SDK's own
classes instead (`CBasePlayer::PlayerUse`, `CBasePlayerItem::AddToPlayer`,
`CChangeLevel::ChangeLevelNow`), which is strictly easier. If it works under
Metamod it works under a custom dll.

| Sven hook | Used for | Metamod equivalent |
| --- | --- | --- |
| `MapChange` | choke point for every transition | `pfnChangeLevel` (supercede to redirect), `ServerDeactivate` |
| `MapStart` / `MapInit` | re-read `checkdata.txt`, rebuild charger table | `ServerActivate` |
| `PlayerSpawn` | reapply loadout | `pfnSpawn` on the player, or first `PlayerPostThink` |
| `PlayerUse` | charger checks, hub buttons | `PlayerPostThink`: watch the `IN_USE` edge and trace 64 units forward, then match classname plus `STRING(pev->model)` |
| `PickupCanCollect` | refuse an ungranted weapon | `DispatchTouch`, `RETURN_MRES SUPERCEDE` |
| `PlayerKilled` | DeathLink out | `PlayerPostThink` deadflag edge, or `ClientKill` |
| `ClientSay` | chat commands | `pfnClientCommand` on `say`, plus real registered console commands |
| `MonsterKilled` | disabled location types | `DispatchDamage` / entity death poll, only if those are ever re-enabled |
| `g_Scheduler` | polling, delayed traps | `StartFrame` with a time accumulator |
| `GiveNamedItem` | grant a weapon | `CREATE_NAMED_ENTITY` plus `DispatchSpawn` plus forced `DispatchTouch` (the standard AMXX technique) |
| `ClientPrint` | all player-facing text | `TextMsg` / `SayText` user messages, or `CLIENT_PRINTF` |
| `ChangeLevel` | warps | `SERVER_COMMAND("map <name>\n")` |

The one thing Metamod cannot do without offset hacks is **remove** a weapon the
player already holds. The design does not need it: gate at pickup rather than
strip after the fact, and the player never holds anything they should not.
Note that the HEV suit stays an item in the pool and is granted, never removed,
exactly as here.

## Which build of the game to target, and the backport escape hatch

Target the current build. If it fights us, the older game is one Steam setting
away.

**The legacy build is public and supported.** Valve archived the pre-anniversary
game as a visible beta branch on the Half-Life app: Properties, Betas,
`steam_legacy`, described as "Pre-25th Anniversary Build". It is not a hack, it
needs no key, and Valve's own guidance is to run it if a mod misbehaves on the
default build. So "worst case, have the user backport" is a real fallback and
costs the player about thirty seconds. What they give up is the anniversary
extras (widescreen FOV, the new renderer settings, Steam Deck support), not the
game.

Two things to get right if the port ever leans on it:

- **Build the dll against the matching SDK.** A dll built from the current
  anniversary SDK may call engine functions the legacy engine does not export.
  If legacy is supported at all, it needs its own build from a pre-anniversary
  tag, and that means two binaries to ship and test, not one. Decide whether
  that is worth it before promising it.
- **The maps are not the same on both branches.** This is the finding that
  matters most, and it reaches into the data pipeline rather than the plugin.
  The anniversary update edited and recompiled single-player BSPs: z-fighting
  fixed on a door in `c1a0`, texture mapping in `c1a2b`, a Barney sequence and
  geometry in `c2a2`/`c2a2a`, among others. A recompile can renumber brush
  models, and brush model index is exactly how this project identifies a
  charger. So `checkdata.txt` generated from anniversary maps is not guaranteed
  to be valid against legacy maps, and a mismatch shows up as chargers that
  silently never fire.

The fix is cheap and should go in regardless of whether legacy is ever
supported: **for the vanilla port, key chargers by rounded world-space centre
rather than by brush model index.** The generator already computes that centre,
the plugin can compute the same thing from the live entity's absolute bounding
box, and it survives any recompile that does not physically move the unit. That
makes the data branch-agnostic and drops the `origin`-offset special case that
`ba_canal1` forced on the Sven side. Add a test that diffs the generated data
between both branches' map directories; if it comes out empty, ship one data set
and stop thinking about this.

Note this is a place where the vanilla port should deliberately not copy what is
here. The brush-index scheme exists because Sven's maps are a fixed shipped set
that nobody recompiles. Retail's are not.

## Decision 3: what a mission is, and what happens at its edges

This is the largest behavioural difference and it needs settling before any code
is written.

Sven ships each chapter as a self-contained map series with a hub in front of
it. Retail is one continuous game: `trigger_changelevel` with landmarks,
inventory carried across, level state preserved for the session, and quicksave
everywhere.

Proposed rules, matching what this project already does:

- **Warps use `map`, not `changelevel`.** A clean load, no carried state, no
  landmark. The plugin reapplies the loadout on spawn. This is what makes a
  mission repeatable and independent.
- **Transitions inside a mission stay the game's own.** Do not intercept
  `c1a1` to `c1a1a`. Inventory and level state carry exactly as retail does.
- **A transition that crosses a mission boundary is intercepted.** Supercede the
  engine's `ChangeLevel`, send `COMPLETE|<chapter>`, and return the player to
  the hub. This is the direct analogue of the `MapChange` choke point in
  `ap_hub.as` and inherits its rule: never fight the engine over a changelevel
  that is already in flight.
- **Saves are allowed and are not authoritative.** The plugin holds nothing
  across a load; the client's snapshot is re-applied. A reloaded save can
  re-send a check that is already collected, which the server treats as a no-op.

Health and armour on entering a mission are a design call worth making
explicitly rather than inheriting: retail expects you to arrive from the
previous chapter with whatever you had. Recommend a fixed 100 health, plus armour
if the suit is held, with a YAML option if it plays badly.

## Decision 4: the hub

There is no `-sp_campaign_portal` in retail. Two stages:

- **v1, no hub map.** The hub is a console interface. Register real server
  commands (`ap`, `ap_warp`, `ap_tracker`, `ap_find`, `ap_hub`) rather than the
  dot-prefixed workaround Sven forced on us. Chat commands still work through
  `pfnClientCommand`, but in single-player the console is the primary surface,
  so it should be first class here rather than a fallback. "Returning to the
  hub" in this stage means loading a small idle map and showing the mission list.
- **v2, an authored hub map.** A single room, one labelled button per mission,
  compiled with the standard tools and shipped in the mod folder. The plugin
  reads the button `targetname` through the same `P` records `checkdata.txt`
  already carries, so nothing in the data pipeline changes when it lands. Keep
  the map source in the repo.

v1 is fully playable. Do not let the map block the port.

## Data: what the new layout table has to say

`tools/campaign_layout.py` becomes a one-campaign file against retail map names.
Retail's single-player campaign is roughly 65 to 70 maps against Sven's 35, so
every chapter has more parts and `map_reached` checks get finer grained.

Work items:

1. Author the chapter table: 19 chapters (18 plus the hazard course), each with
   its ordered map list, from `c0a0` through `c5a1`, with `t0a0*` as an
   optional intro-style extra. Sven's chapter keys must **not** be reused; this
   is a different game with its own id space.
2. Re-derive the weapon table. Retail has no `weapon_m16`, no Sven-specific
   spellings, and no script-registered weapons, so `R` records disappear
   entirely and the classname aliasing shrinks to nothing.
3. Regenerate. Chargers, weapon first-locations and positions all fall out of
   the existing generator with no code changes.

Expected shape: about 65 `map_reached`, 19 `chapter_complete`, 90ish `charger`
and 14 `weapon_pickup`, so roughly 190 locations against Half-Life's 173 here.
That is a healthy ratio for the same item pool.

`ENABLED_LOCATION_TYPES` stays off, as it is here, for the same reason.

## Decision 5: one apworld or two

Two. A separate `half_life` world with its own game name, its own id space and
its own client. Sharing an id space with the Sven world would mean a data change
for one game renumbering the other, and the two have different setup, different
install targets and different clients. Copy `bridge.py` rather than importing
across worlds; apworlds are not a reliable import surface for each other.

The generator tooling in `tools/` is the shared part, and it is already
parameterised well enough to serve both.

## Phases

**Phase 0, the spike. Half a week.** A `hlap` mod folder with `fallback_dir
"valve"`, running a dll built unmodified from the current SDK, that does four
things: start a retail single-player map through the fallback, print to the
player, read a file every frame, and refuse a `weapon_shotgun` pickup. If that
works, option A is confirmed and everything else follows. If the SDK build will
not run against the installed engine, try Metamod, and only then consider
`steam_legacy`. This phase exists solely to de-risk the one thing that could
invalidate the plan, and it should also produce the map-diff between the two
branches described above, since that is a generator run and needs no game.

**Phase 1, data.** New layout module, regenerate `campaign.json`, `ids.json` and
`checkdata.txt` against `valve/maps`. Port the test suite. This phase needs no
game running and no C++, and it produces a world that generates seeds.

**Phase 2, the world and client.** Fork the world package, strip the three
campaigns and their options, keep `chargesanity`, `missions_required`,
`random_starting_weapon`, `death_link_amnesty`, `trap_percentage`. Repoint the
client at the mod's store directory and reuse the launcher wholesale. At the end
of this phase the client runs, connects, and writes snapshots that nothing reads
yet.

**Phase 3, the plugin core.** Bridge file I/O, `checkdata.txt` parsing,
`ServerActivate`, the poll loop on `StartFrame`, console commands, and
`map_reached` plus `chapter_complete`. First playable: missions are enterable,
checks flow, nothing is gated yet.

**Phase 4, gating.** Weapon pickup refusal, loadout reapply on spawn, the suit
and long jump module, and the changelevel choke point. This is the phase where
retail's inventory carry-over is fought and won, and it is the one to allow
schedule slack for.

**Phase 5, chargers and the rest.** The `IN_USE` trace, brush model matching,
`!find` positions, DeathLink both directions, traps with their precache
constraint, chat relay.

**Phase 6, hub map and polish.** The authored hub, the setup guide, and an
in-game verification checklist in the shape of `docs/verification.md`.

Phases 1 and 2 are largely mechanical and could be done by someone who never
touches the C++. Phases 3 through 5 are the real work, and they are one person's
job because they are all the same file set.

## Risks, in the order they can hurt

1. **Charger identity across engine branches.** Promoted to the top risk by the
   discovery that the anniversary update recompiled single-player maps. Switch
   to position-based keying in Phase 1 and it disappears; leave it as brush
   index and it surfaces as chargers that quietly never fire on whichever branch
   the data was not generated from, which is the hardest kind of bug to notice.
2. **The build the player is running.** Less dangerous than it looked. The SDK
   tracks the shipped anniversary game, Metamod is a live fallback, and
   `steam_legacy` is a public beta branch behind that. The residual cost is that
   supporting both branches means two dll builds and two test passes, so pick
   one branch as supported and treat the other as best-effort.
3. **Trap spawns and precache.** GoldSrc fatally errors on an unprecached model,
   and the precache table is finite. Traps must precache their fixed set at
   `ServerActivate` or be restricted to entities the current map already has.
   Note that a precache pass was written and reverted once on the Sven side; the
   situation is different here, but treat it as the same class of hazard and get
   agreement before adding one.
4. **`game_player_equip` and code-granted weapons.** Touch supercede does not
   catch a weapon handed over by map logic rather than a pickup. Sweep the
   entity lumps for `game_player_equip` during Phase 1 so the exceptions are
   known before Phase 4 rather than discovered in play.
5. **Mission boundary interception.** Superceding a changelevel the engine is
   already performing is exactly the crash class documented in the AngelScript
   rules here. Same discipline applies: never act inline, always defer a level
   change out of the hook that observed it.
6. **Level state and the save system.** `map` for warps sidesteps most of it.
   The residual case is a player who quicksaves in a mission and quickloads after
   the client has moved on; the stateless design handles it, but it needs
   deliberate testing.
7. **Hazard course.** `t0a0*` is a real map series with chargers in it. Decide
   early whether it is a mission, an excluded intro, or absent.

## Effort

Assuming one developer who knows C++ and has the existing project to copy from,
and treating Phase 0 as a gate:

| Phase | Estimate |
| --- | --- |
| 0, spike | 2 to 3 days |
| 1, data | 3 to 4 days |
| 2, world and client | 2 to 3 days |
| 3, plugin core | 1 to 2 weeks |
| 4, gating | 1 to 2 weeks |
| 5, chargers, DeathLink, traps | 1 week |
| 6, hub map and docs | 1 week |

Call it six to eight weeks part time to a state comparable with where the Sven
world is now, with the first playable at the end of Phase 3.

## What is explicitly not in scope

Opposing Force, Blue Shift and They Hunger. Retail Opposing Force and Blue Shift
are separate games with their own game directories and their own dlls, and each
would need its own mod folder and its own plugin build. The architecture extends
to them the same way it did here, but the Half-Life port has to land first.
