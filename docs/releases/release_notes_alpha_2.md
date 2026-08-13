# Half-Life (Sven Co-op) Archipelago Alpha v0.2
Note that this is a very early build of the apworld. Please report any problems in Discord or the Issues page on github (with reproduction steps please and thank you!)

Sven Co-op's Half-Life campaign is meant to be played in multiplayer. No support will be offered to players attempting to circumvent this restriction.

## What's New
* Added Blue Shift Campaign
  * NOTE: Host must own the game.
* Added Opposing Force Campaign
  * NOTE: Host must own the game.
* Added They Hunger Campaign
* Various logic and stability improvements
* New YAML Option to disable all intro missions
* Starting weapon is now randomized between all enabled campaign's melee weapons (excludes reskins like the knife, shovel, and umbrella as these are map specific)
* Traps now queue so they always get you even if you're mid level load :)
* New commands: `!tracker <text>` and `!find <text>`
  * The `!tracker` command can be used to display a checklist of checks for all or some missions (matches on the text argument)
  * The `!find` command can be used to see roughly how far you are from the nearest check location within the same map, or a specific location provided by text argument in the same map or another.
* Updated command: `!warp`
  * Now lets you warp back to individual maps you've reached within a chapter so you don't always have to start at the beginning
* Console variants of all commands using `.ap` or `.ap_<cmd>`
* Updated weapon locations and added locations for HEV Suit pickups in all campaigns that have an HEV Suit equivalent
* Universal Tracker integration

## Setup
As the game host:
Install the apworld by downloading and double clicking (or placing it in your custom_worlds folder)
Open the Half-Life (Sven Co-op) Client and select your install directory
Run /install in the client
Connect the client to the multiworld, and open a server on the map -sp_campaign_lobby
Once your friends are in game with you (they can just join!), you can type !ap to see unlocked missions in the console, and !warp to change maps to the unlocked mission. (The in-game panels also work)

## Known Issues
* General instability: expect some crashing or other random issues
* Sound cacheing bug: sometimes when another player joins the lobby, their sounds are all mixed up. This will self resolve once you get into a mission. I am under the impression that if they install the plugin too that helps, but I'm unsure. This one is kind of complicated to diagnose.
* Occasional random weapon location checks sent out on the mission where they're found on loading/unloading that mission.