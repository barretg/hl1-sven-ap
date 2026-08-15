# Half-Life (Sven Co-op) Archipelago Alpha v0.2.1
Note that this is a very early build of the apworld. Please report any problems in Discord or the Issues page on github (with reproduction steps please and thank you!)

Sven Co-op's Half-Life campaign is meant to be played in multiplayer. No support will be offered to players attempting to circumvent this restriction. (The map "Suspension" is an exception to this rule)

**Important**: Run /install to update the plugin after you update your apworld.

## New Features
* Added the map "suspension" as an option to be enabled in the YAML. This is a co-op class-based arcade shooter where you fight your way across a bridge. Quite fun, and works well for archipelago.
* Added new, more refined, deathlink settings.
* Commands now work in console with the . prefix: `.ap`, `.ap_tracker`, `.ap_warp`, etc.

## Bug Fixes/Improvements
* Fixed the completion checks on Blue Shift and OpFor being wonky.
* Chargesanity being off would still display text on the user's screen when interacting with a charger.
* Held weapons no longer send weapon checks if held on the map corresponding to their location.
* Fixed a bug where finishing a mission and having the next mission unlocked would send an extra check that's not meant to be sent until that mission is actually loaded into.
* Fixed a bug where chargesanity being disabled would also block weapon checks from being sent.
* Made receiving ammo for the weapons you receive less annoying.
* Some refinement of what and how information is displayed by commands.
* Disconnecting and reconnecting or changing slots is now handled much more cleanly.
* Game now syncs completion both ways, so collected checks propogate back to the game now.
* Traps now queue up and trigger only after a 5 second gap of stability (not loading or dead).

## Setup
As the game host:
Install the apworld by downloading and double clicking (or placing it in your custom_worlds folder)
Open the Half-Life (Sven Co-op) Client and select your install directory
Run /install in the client
Connect the client to the multiworld, and open a server on the map -sp_campaign_lobby
Once your friends are in game with you (they can just join!), you can type !ap to see unlocked missions in the console, and !warp to change maps to the unlocked mission. (The in-game panels also work)

## Known Issues
* Sound cacheing bug: sometimes when another player joins the lobby, their sounds are all mixed up. This will self resolve once you get into a mission. I am under the impression that if they install the plugin too that helps, but I'm unsure. This one is kind of complicated to diagnose.
* Barnacle Grapple is possibly needed to finish Pit Worm (opfor), which is not modeled by logic.
* There might be 2 health chargers out of bounds on Pit Worm also, need to confirm this.