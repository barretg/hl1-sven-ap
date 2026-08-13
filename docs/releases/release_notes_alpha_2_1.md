# Half-Life (Sven Co-op) Archipelago Alpha v0.2.1
Note that this is a very early build of the apworld. Please report any problems in Discord or the Issues page on github (with reproduction steps please and thank you!)

Sven Co-op's Half-Life campaign is meant to be played in multiplayer. No support will be offered to players attempting to circumvent this restriction.

## Bug fixes
* Fixed the goal trigger for opposing force since there's no geneworm in sven.

## Setup
As the game host:
Install the apworld by downloading and double clicking (or placing it in your custom_worlds folder)
Open the Half-Life (Sven Co-op) Client and select your install directory
Run /install in the client
Connect the client to the multiworld, and open a server on the map -sp_campaign_lobby
Once your friends are in game with you (they can just join!), you can type !ap to see unlocked missions in the console, and !warp to change maps to the unlocked mission. (The in-game panels also work)

## Known Issues
* Sound cacheing bug: sometimes when another player joins the lobby, their sounds are all mixed up. This will self resolve once you get into a mission. I am under the impression that if they install the plugin too that helps, but I'm unsure. This one is kind of complicated to diagnose.
* Occasional random weapon location checks sent out on the mission where they're found on loading/unloading that mission.