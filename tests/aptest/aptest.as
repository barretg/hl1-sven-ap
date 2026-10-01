/*
* APTest: an in-game test harness for the Archipelago plugin.
* Installed by tests/install_test_plugin.py.
*
* Stands in for the Python client. Each scenario writes the snapshot the client
* would (ap_in.txt), warps to the map through the hub so the main plugin treats
* the arrival as deliberate, teleports players to the spot, and then watches
* ap_out.txt, marking each CHECK the main plugin sends as expected or not.
*
* Commands (chat with !, or console with .):
*   apt                 list scenarios
*   apt_go <n>          start scenario n
*   apt_next / apt_prev / apt_redo
*   apt_info            repeat the current scenario's steps
*   apt_pass [note]     record this scenario as passed and go to the next
*   apt_fail [note]     record it as failed and go to the next
*   apt_note <text>     record a finding for an investigative scenario and go on
*   apt_status          verdict counts and the first untested scenario
*   apt_give <item>     add an item to the emulated snapshot
*   apt_take <item>     remove one
*   apt_unlock <key>    open a mission the scenario held back
*   apt_unseal <key>    lift a held finale's seal
*   apt_slot <slot>     report a different slot (the plugin resets its run state)
*   apt_reload          reload the current map, keeping the emulated state
*   apt_item <name>     send a filler item event (Medkit, Health Charge ...)
*   apt_hp <hp> [ap]    set every player's health, and armour if given
*   apt_ammo            list held weapons' ammo against half their maximum
*   apt_trap <name>     send a trap event (Bot Swarm Trap, Butterfingers Trap ...)
*   apt_tp              teleport back to the scenario spot
*   apt_spawn <class>   spawn an entity in front of you
*   apt_off             write a disconnected snapshot and stop
*
* Overwrites ap_in.txt; the real client rewrites it when it next connects.
*/

const string APT_DIR = "scripts/plugins/store/archipelago/";
const string APT_CHECKDATA = APT_DIR + "checkdata.txt";
const string APT_IN = APT_DIR + "ap_in.txt";
const string APT_OUT = APT_DIR + "ap_out.txt";
const string APT_STATE = APT_DIR + "aptest_state.txt";
const string APT_RESULTS = APT_DIR + "aptest_results.txt";
const string APT_HUB = "-sp_campaign_portal";
const string APT_ARCADE = "suspension";

// ---------------------------------------------------------------- checkdata

class APTChapter
{
	string key;
	string name;
	string campaign;
	array<string> maps;
}

class APTLoc
{
	string id;
	string map;
	string kind;
	string arg;
	string name;
	string pos;
}

// A mission's first copy of a weapon, from an F record.
class APTSource
{
	string id;      // the weapon check it sends
	string map;
	string pos;     // "" when the weapon is handed over
	string needs;
	bool hostile;   // carried by an enemy, dropped when it is killed
}

array<APTChapter@> g_Chapters;
array<APTLoc@> g_Locs;
dictionary g_CampaignShort;   // campaign key -> short
dictionary g_CampaignIntro;   // campaign key -> "1" / "0"
array<string> g_CampaignOrder;
array<string> g_KeyItems;       // every item name a K record gates on
dictionary g_ClassItem;         // classname -> item name, from K records
array<APTSource@> g_Sources;

void LoadCheckdata()
{
	g_Chapters.resize( 0 );
	g_Locs.resize( 0 );
	g_CampaignOrder.resize( 0 );
	g_KeyItems.resize( 0 );
	g_ClassItem.deleteAll();
	g_Sources.resize( 0 );

	File@ pFile = g_FileSystem.OpenFile( APT_CHECKDATA, OpenFile::READ );
	if( pFile is null || !pFile.IsOpen() )
	{
		Say( "checkdata.txt missing; install the Archipelago plugin first." );
		return;
	}

	while( !pFile.EOFReached() )
	{
		string szLine;
		pFile.ReadLine( szLine );
		array<string>@ f = szLine.Split( "|" );
		if( f.length() < 2 )
			continue;

		if( f[0] == "M" && f.length() >= 6 )
		{
			g_CampaignShort[ f[1] ] = f[4];
			g_CampaignIntro[ f[1] ] = f[5];
			g_CampaignOrder.insertLast( f[1] );
		}
		else if( f[0] == "C" && f.length() >= 7 )
		{
			APTChapter@ c = APTChapter();
			c.key = f[2];
			c.name = f[3];
			c.maps = f[4].Split( "," );
			c.campaign = f[6];
			g_Chapters.insertLast( c );
		}
		else if( f[0] == "K" && f.length() >= 3 )
		{
			if( g_KeyItems.find( f[2] ) < 0 )
				g_KeyItems.insertLast( f[2] );
			g_ClassItem[ f[1] ] = f[2];
		}
		else if( f[0] == "F" && f.length() >= 5 )
		{
			APTSource@ src = APTSource();
			src.id = f[1];
			src.map = f[2];
			src.pos = f[3];
			src.needs = f[4];
			src.hostile = f.length() >= 6 && f[5] == "hostile";
			g_Sources.insertLast( src );
		}
		else if( f[0] == "L" && f.length() >= 6 )
		{
			APTLoc@ l = APTLoc();
			l.id = f[1];
			l.map = f[2];
			l.kind = f[3];
			l.arg = f[4];
			l.name = f[5];
			l.pos = f.length() >= 7 ? f[6] : "";
			g_Locs.insertLast( l );
		}
	}
	pFile.Close();
}

APTChapter@ ChapterOfMap( const string& in szMap )
{
	for( uint i = 0; i < g_Chapters.length(); ++i )
		if( g_Chapters[i].maps.find( szMap ) >= 0 )
			return g_Chapters[i];
	return null;
}

APTLoc@ LocByName( const string& in szName )
{
	for( uint i = 0; i < g_Locs.length(); ++i )
		if( g_Locs[i].name == szName )
			return g_Locs[i];
	return null;
}

APTLoc@ LocById( const string& in szId )
{
	for( uint i = 0; i < g_Locs.length(); ++i )
		if( g_Locs[i].id == szId )
			return g_Locs[i];
	return null;
}

// What `!warp <short> <n>` should land on, for the relative warp scenario.
string RelativeTarget( const string& in szCampaign, int n )
{
	array<APTChapter@> list;
	for( uint i = 0; i < g_Chapters.length(); ++i )
		if( g_Chapters[i].campaign == szCampaign )
			list.insertLast( g_Chapters[i] );

	string szIntro;
	g_CampaignIntro.get( szCampaign, szIntro );
	int idx = szIntro == "1" ? n : n - 1;
	if( idx < 0 || uint( idx ) >= list.length() )
		return "(out of range: expect an error message)";
	return list[idx].name;
}

// ---------------------------------------------------------------- scenarios

class APTScenario
{
	string title;
	string map;
	string pos;                 // "x y z", or "" to stay at spawn
	string give;                // ";"-separated, added to the base items
	string take;                // ";"-separated, removed from them
	bool legacy = false;        // old seed: no armour table
	bool reached = false;       // every map's "Reached" pre-found, for !warp
	string ungated;
	bool suspension = false;
	string spawn;               // classname put in front of the player on arrival
	string trap;                // trap event sent on arrival
	string expect;              // ";"-separated check names that should fire
	string forbid;              // ";"-separated check names that must not
	bool forbidWeapons = false; // any weapon_pickup check is a failure
	bool forbidAll = false;     // any check at all is a failure
	string steps;               // "\n"-separated lines
	bool note = false;          // investigative: answered with !apt_note
	string hold;                // ";"-separated mission keys locked (and their seals kept)
	string exclude;             // ";"-separated mission keys left out of the seed
	string only;                // a campaign key: every other campaign's checks out of the seed
}

array<APTScenario@> g_Scenarios;

APTScenario@ Add( const string& in szTitle, const string& in szMap )
{
	APTScenario@ s = APTScenario();
	s.title = szTitle;
	s.map = szMap;
	g_Scenarios.insertLast( s );
	return s;
}

void BuildScenarios()
{
	g_Scenarios.resize( 0 );
	APTScenario@ s;

	@s = Add( "Bot Swarm", "hl_c02_a2" );
	s.trap = "Bot Swarm Trap";
	s.steps =
		"Six crowbar bots appear around you a few seconds after arrival." + "\n"
		+ "Check: models/animations look right, they chase and hit you," + "\n"
		+ "they die normally. Repeat with !apt_trap Bot Swarm Trap." + "\n"
		+ "With 2+ players: bots split round-robin across living players.";

	@s = Add( "Flashlight locked", "hl_c03" );
	s.take = "Flashlight";
	s.steps =
		"Press F: refused with 'You have not found the Flashlight yet.'" + "\n"
		+ "Then !apt_give Flashlight and press F: it works." + "\n"
		+ "Then !apt_take Flashlight: a lit flashlight goes out.";

	@s = Add( "PCV locked (OF)", "of1a1" );
	s.pos = LocPos( "Opposing Force: First PCV" );
	s.take = "PCV";
	s.expect = "Opposing Force: First PCV";
	s.steps =
		"You are on the PCV. Expect the check 'Opposing Force: First PCV'." + "\n"
		+ "No armour yet: !apt_spawn item_battery, armour stays/falls to 0." + "\n"
		+ "Then !apt_give PCV and another battery: armour sticks.";

	@s = Add( "HEV Suit does not count in OF", "of1a3" );
	s.take = "PCV";
	s.spawn = "item_battery";
	s.steps =
		"HEV Suit held, PCV not. Take the battery: armour falls back to 0." + "\n"
		+ "!apt_give PCV, !apt_spawn item_battery, take it: armour sticks.";

	@s = Add( "PCV does not count in HL", "hl_c03" );
	s.take = "HEV Suit";
	s.spawn = "item_battery";
	s.steps =
		"PCV held, HEV Suit not. Take the battery: armour falls back to 0." + "\n"
		+ "!apt_give HEV Suit, !apt_spawn item_battery, take it: armour sticks.";

	@s = Add( "Security Armor locked (BS)", "ba_security2" );
	s.pos = LocPos( "Blue Shift: First Security Armor" );
	s.take = "Security Armor";
	s.expect = "Blue Shift: First Security Armor";
	s.steps =
		"You are at the vest/helmet. Expect 'Blue Shift: First Security Armor'." + "\n"
		+ "No armour from vest/helmet. !apt_give Security Armor: armour sticks.";

	@s = Add( "Old seed armour (no table)", "of1a3" );
	s.legacy = true;
	s.take = "PCV" + ";" + "Security Armor";
	s.spawn = "item_battery";
	s.steps =
		"Emulates a seed from before per-campaign armour: HEV Suit only." + "\n"
		+ "Take the battery in front of you: armour sticks on an OF map.";

	@s = Add( "Melee Throw", "hl_c03" );
	s.take = "Melee Throw";
	s.forbid = "First Crowbar";
	s.steps =
		"Crowbar out, right-click: normal behaviour (no throw)." + "\n"
		+ "!apt_give Melee Throw, right-click: crowbar flies, hurts what it hits," + "\n"
		+ "returns after 10s. Picking the thrown crowbar up sends NO check.";

	@s = Add( "Weapon check: campaign-wide", "hl_c02_a2" );
	s.spawn = "weapon_shotgun";
	s.expect = "First Shotgun";
	s.forbid = "Opposing Force: First Shotgun;Blue Shift: First Shotgun";
	s.steps =
		"A shotgun is spawned in front of you on hl_c02_a2 (anchored hl_c03)." + "\n"
		+ "Expect 'First Shotgun' on sight/pickup, not a per-map name.";

	@s = Add( "Weapon check: per campaign", "ba_security1" );
	s.spawn = "weapon_shotgun";
	s.expect = "Blue Shift: First Shotgun";
	s.forbid = "First Shotgun";
	s.steps =
		"Shotgun spawned on a Blue Shift map." + "\n"
		+ "Expect 'Blue Shift: First Shotgun' only, never Half-Life's.";

	@s = Add( "Hub sends nothing", APT_HUB );
	s.spawn = "weapon_shotgun";
	s.forbidAll = true;
	s.steps =
		"Shotgun spawned in the hub. Walk over it: no check at all.";

	@s = Add( "Suspension sends no weapon check", APT_ARCADE );
	s.suspension = true;
	s.spawn = "weapon_shotgun";
	s.forbidWeapons = true;
	s.steps =
		"Shotgun spawned on the arcade map. Pick it up: no weapon check." + "\n"
		+ "Class loadouts containing weapons must not send checks either.";

	@s = Add( "Granted weapon sends nothing", "hl_c02_a2" );
	s.give = "Shotgun";
	s.forbid = "First Shotgun";
	s.steps =
		"The Shotgun item is held, so it is put in your hands." + "\n"
		+ "Wait ~5s and switch to it: no 'First Shotgun' check.";

	@s = Add( "Butterfingers drop sends nothing", "hl_c02_a2" );
	s.give = "Shotgun";
	s.forbid = "First Shotgun";
	s.steps =
		"Switch to the shotgun, then !apt_trap Butterfingers Trap." + "\n"
		+ "It lands on the floor. Stand by it, pick it up after the" + "\n"
		+ "withhold ends (or wait 30s for reissue): no weapon check.";

	@s = Add( "Player drop (G) sends nothing", "hl_c02_a2" );
	s.give = "Shotgun";
	s.forbid = "First Shotgun";
	s.steps =
		"Switch to the shotgun and press G. Walk off, then pick it up." + "\n"
		+ "No 'First Shotgun'. Then type kill in console holding it;" + "\n"
		+ "after respawn pick up the dropped copy: still no check.";

	@s = Add( "Long Jump at vanilla spot", "hl_c13_a4" );
	s.pos = LocPos( "First Long Jump Module" );
	s.take = "Long Jump Module";
	s.expect = "First Long Jump Module";
	s.steps =
		"On the module. Expect 'First Long Jump Module'; pickup refused." + "\n"
		+ "!apt_give Long Jump Module: it collects and long jump works.";

	@s = Add( "Long Jump old seed (ungated)", "hl_c13_a4" );
	s.pos = LocPos( "First Long Jump Module" );
	s.take = "Long Jump Module";
	s.ungated = "item_longjump";
	s.legacy = true;
	s.steps =
		"Old seed, long jump unshuffled: collects freely, no gating." + "\n"
		+ "(A CHECK line here is ignored by an old seed's client.)";

	@s = Add( "Relative warps", APT_HUB );
	s.reached = true;
	s.steps =
		"!warp of 3 -> " + RelativeTarget( "opposing_force", 3 ) + "\n"
		+ "!warp of 0 -> " + RelativeTarget( "opposing_force", 0 ) + "\n"
		+ "!warp bs 2 -> " + RelativeTarget( "blue_shift", 2 ) + "\n"
		+ "!warp th 1 -> " + RelativeTarget( "they_hunger", 1 ) + "\n"
		+ "!warp th 0 -> " + RelativeTarget( "they_hunger", 0 ) + "\n"
		+ "!warp hl 1 2 -> Anomalous Materials part 2. !apt_redo to come back." + "\n"
		+ "Also try .ap_warp of 3 in console.";

	@s = Add( "Menu and HUD", APT_HUB );
	s.reached = true;
	s.steps =
		"!menu (or .ap_menu): warp by game > mission > part; tracker by" + "\n"
		+ "game > mission > missing checks; pick one to be pointed at it." + "\n"
		+ "!aphud toggles the check counter. Warp somewhere and read it." + "\n"
		+ "Tracker data: map reached checks count as found, rest missing.";

	// One per healing pool, straight from checkdata.
	for( uint i = 0; i < g_Locs.length(); ++i )
	{
		APTLoc@ l = g_Locs[i];
		if( l.kind != "charger" || l.arg.Find( "trigger_hurt" ) != 0 )
			continue;
		@s = Add( "Pool: " + l.name, l.map );
		s.pos = l.pos;
		s.expect = l.name;
		s.steps =
		"You are dropped over the pool. Step in: expect '" + l.name + "'." + "\n"
		+ "If the drop misses, !apt_tp or walk in yourself.";
	}

	// Appended, not slotted in beside the other weapon tests: verdicts are kept
	// by scenario number, and inserting would shift every recorded result.
	@s = Add( "Weapons once per life", "hl_c02_a2" );
	s.give = "Hand Grenade;Shotgun";
	s.forbid = "First Hand Grenade;First Shotgun;First Crowbar";
	s.steps =
		"Throw every grenade, wait 5s: NO new grenade appears." + "\n"
		+ "!apt_trap Butterfingers Trap holding the shotgun: it comes back after the hold." + "\n"
		+ "!apt_give Melee Throw, throw the crowbar, leave it: it comes back after 10s." + "\n"
		+ "Type kill in console: after respawn you have grenades again.";

	BuildDisplacerScenarios();
	BuildDropScenarios();
	BuildSourceScenarios();
	BuildParityScenarios();
}

/*
* Investigative, not pass/fail: what the displacer's self-teleport reaches on
* the maps nobody has walked with one yet. Record findings with !apt_note.
* Each map's `info_displacer_xen_target`, and the healing pool that data calls
* sealed where there is one, read from the BSPs; the pool is left out of the
* seed until a note here says it can be reached.
*/
void BuildDisplacerScenarios()
{
	// map | Xen target | "sealed" pool centre, or ""
	array<string> rows = {
		"of5a1|2752 2104 -776|2580 1832 -840",
		"of5a2|2556 -2068 1920|2504 -3160 1816",
		"of5a3|2128 2488 1080|",
		"of5a4|3256 2320 -2848|",
		"of6a1|-3072 -3080 -784|-3244 -3352 -840",
		"of6a2|2448 2680 -1032|",
		"of6a3|1528 -2288 -2976|",
		"of6a4|2556 -2068 2944|2504 -3160 2840",
		"of6a4b|2556 -2068 2944|2504 -3160 2840"
	};
	for( uint i = 0; i < rows.length(); ++i )
	{
		array<string>@ f = rows[i].Split( "|" );
		APTChapter@ c = ChapterOfMap( f[0] );
		APTScenario@ s = Add( "Displacer: " + ( c is null ? f[0] : c.name ) + " (" + f[0] + ")", f[0] );
		s.pos = f[1];
		s.note = true;
		s.steps =
			"You are at the displacer's Xen target. Displacer held with 60 ammo." + "\n"
			+ "Look around: pools, chargers, weapons, exits. Walk back out if you can." + "\n"
			+ ( f[2].Length() > 0
			    ? "Data has a 'sealed' healing pool at " + f[2] + ": can you reach it?" + "\n" : "" )
			+ "Also walk from spawn and use secondary fire: note where it lands you." + "\n"
			+ "!apt_note <what you found> records it and moves on.";
	}
}

/*
* Investigative: whether Sven Co-op drops weapons from the dead the way the
* original games do. A drop would be another way to a weapon check.
*/
void BuildDropScenarios()
{
	APTScenario@ s = Add( "Drops: shock trooper", "of5a2" );
	s.note = true;
	s.spawn = "monster_shocktrooper";
	s.steps =
		"A shock trooper is spawned in front of you. Kill it." + "\n"
		+ "Does a shock roach (weapon_shockrifle) or anything else drop?" + "\n"
		+ "!apt_spawn monster_shocktrooper for another. !apt_note the result.";

	@s = Add( "Drops: human grunt", "hl_c04" );
	s.note = true;
	s.spawn = "monster_human_grunt";
	s.take = "MP5;Shotgun";
	s.steps =
		"A human grunt is spawned in front of you. Kill it." + "\n"
		+ "Does its MP5 or shotgun drop, and does touching it send a check?" + "\n"
		+ "!apt_note the result.";

	@s = Add( "Drops: male assassin", "of5a1" );
	s.note = true;
	s.spawn = "monster_male_assassin";
	s.steps =
		"A male assassin is spawned in front of you. Kill it." + "\n"
		+ "Does a weapon (MP5 or sniper rifle) drop? !apt_note the result.";
}

/*
* One per mission's first copy of each weapon, straight from the F records:
* every place logic now accepts for a "First ..." check. Pass if it can be
* reached with the mission's own requirements; fail with what else it needs.
*/
void BuildSourceScenarios()
{
	for( uint i = 0; i < g_Sources.length(); ++i )
	{
		APTSource@ src = g_Sources[i];
		APTLoc@ l = LocById( src.id );
		if( l is null )
			continue;
		APTChapter@ c = ChapterOfMap( src.map );
		APTScenario@ s = Add( "Source: " + l.name + " in " + ( c is null ? src.map : c.name ), src.map );
		s.pos = src.pos;
		s.expect = l.name;
		// Locked, so touching it sends the check and it stays on the floor.
		string szItem;
		if( g_ClassItem.get( l.arg.Split( "," )[0], szItem ) )
			s.take = szItem;
		if( src.hostile )
			s.spawn = "monster_shocktrooper";
		s.steps =
			( src.hostile
			  ? "Carried by an enemy on " + src.map + ": one is spawned in front of you. Kill it, touch the drop." + "\n"
			    + "Also find the map's own trooper: can it be reached and fought?" + "\n"
			  : "" )
			+ ( src.pos.Length() > 0
			  ? "You are dropped at the copy on " + src.map + ". Touch it: expect '" + l.name + "'."
			  : "Handed over on " + src.map + ", not left lying: play to it: expect '" + l.name + "'." ) + "\n"
			+ ( src.needs.Length() > 0 ? "Data says it needs: " + src.needs + "." + "\n" : "" )
			+ "Nothing there? It may come from a monstermaker: find what triggers it." + "\n"
			+ "Could a player walk here from the mission start with only its own" + "\n"
			+ "requirements? !apt_pass, or !apt_fail <what else it needs>.";
	}
}

/*
* The Half-Life: Anniversary parity changes. Appended last so the scenario
* numbers before them keep their recorded verdicts.
*/
void BuildParityScenarios()
{
	APTScenario@ s;

	@s = Add( "Find: old and new name spellings", "hl_c03" );
	s.steps =
		"!find office complex - health charger 1" + "\n"
		+ "!find office complex: health charger 1" + "\n"
		+ "Both point at the same charger, named 'Office Complex: Health Charger 1'." + "\n"
		+ "!find -  matches nothing (a query with no letters or digits).";

	@s = Add( "Menu: tracker labels", "hl_c03" );
	s.steps =
		"!menu, tracker, Half-Life, Office Complex." + "\n"
		+ "Lines read 'Health Charger 1' and so on, with no 'Office Complex:' in front.";

	@s = Add( "Melee Throw: arc and damage", "hl_c03" );
	s.forbid = "First Crowbar";
	s.steps =
		"Crowbar out, right-click across a long room: it flies fast and flat," + "\n"
		+ "dropping late (speed 1100, low gravity in flight)." + "\n"
		+ "!apt_spawn monster_headcrab: one throw does four swings' damage." + "\n"
		+ "Pick it up, then type drop in console: it falls like any dropped weapon.";

	@s = Add( "Find: walk score", "hl_c03" );
	s.pos = LocPos( "Office Complex: Health Charger 1" );
	s.steps =
		"You are at Health Charger 1. !find office complex: health charger 6" + "\n"
		+ "Straight line is ~1430 units; expect 'About' ~3000 to 3200 units" + "\n"
		+ "(flat distance plus 3x the height), with 'well above you'.";

	@s = Add( "Find: earliest available copy", "hl_c01_a1" );
	s.take = "Shotgun";
	s.only = "half_life";
	s.steps =
		"!find first shotgun" + "\n"
		+ "Expect: 'Any copy on Half-Life's maps sends it.'" + "\n"
		+ "then 'The earliest available is in:', 'In Office Complex (hl_c03).'" + "\n"
		+ "and a !warp line.";

	@s = Add( "Find: earliest in a locked map", "hl_c01_a1" );
	s.take = "Shotgun";
	s.only = "half_life";
	s.hold = "office_complex;weve_got_hostiles;power_up;apprehension;surface_tension;lambda_core";
	s.steps =
		"Every mission with a shotgun is locked. !find first shotgun" + "\n"
		+ "Expect 'The earliest is in a locked map:', 'In Office Complex (hl_c03).'" + "\n"
		+ "and NO !warp line.";

	@s = Add( "Find: earliest needs an item", "of1a1" );
	s.take = "Shotgun;Displacer Cannon";
	s.exclude = "of_we_are_pulling_out;of_friendly_fire;of_we_are_not_alone";
	s.hold = "of_pit_worms_nest;of_the_package";
	s.steps =
		"Only Crush Depth's shotgun is left, behind the Displacer Cannon." + "\n"
		+ "!find opposing force: first shotgun" + "\n"
		+ "Expect 'The earliest needs the Displacer Cannon, which you do not have:'" + "\n"
		+ "then Crush Depth, part 2 (of3a2) and a !warp line, and NO separate" + "\n"
		+ "'Needs the Displacer Cannon to reach.' line.";

	@s = Add( "Duty Calls part 2 barrel", "ba_canal1b" );
	s.note = true;
	s.steps =
		"Investigative. Play to the explosive barrel that opens the way on." + "\n"
		+ "Can it be set off without a gun (crowbar, grenade, satchel)?" + "\n"
		+ "Does the RPG set it off? !apt_note what works.";

	@s = Add( "Shock Roach item grants nothing", "hl_c02_a1" );
	s.take = "Shock Roach";
	s.steps =
		"!apt_give Shock Roach: a 'Received' line, but NO roach in your hands," + "\n"
		+ "now or after kill in console. Weapon switching keeps working.";

	@s = Add( "Shock Roach: trooper drop gated", "of5a2" );
	s.take = "Shock Roach";
	s.spawn = "monster_shocktrooper";
	s.expect = "Opposing Force: First Shock Roach";
	s.steps =
		"A shock trooper is spawned in front of you. Kill it, walk over its roach:" + "\n"
		+ "refused (touch and E), and 'Opposing Force: First Shock Roach' is sent." + "\n"
		+ "!apt_give Shock Roach, press E on it: picked up. Drop it: you can switch again.";

	@s = Add( "Shock Roach: find line", "of5a2" );
	s.take = "Shock Roach";
	s.steps =
		"!find opposing force: first shock roach" + "\n"
		+ "Expect 'Carried by an enemy here, dropped when killed.'";

	@s = Add( "Blue Shift: Half-Life weapons", "ba_security2" );
	s.take = "Tau Cannon;Gluon Gun";
	s.steps =
		"!apt_give Tau Cannon then !apt_give Gluon Gun." + "\n"
		+ "Both arrive with a 'Received' line, draw and fire on this Blue Shift map.";

	@s = Add( "Granted ammo rounds up", "hl_c02_a2" );
	s.steps =
		"Type kill in console. After respawn, before firing or picking up: !apt_ammo" + "\n"
		+ "Every line ends 'ok'. weapon_rpg (odd max) shows owed = half rounded up.";

	@s = Add( "Filler amounts", "hl_c02_a2" );
	s.steps =
		"!apt_hp 50 0 then !apt_item Medkit: health 75." + "\n"
		+ "!apt_hp 50 0 then !apt_item Health Charge: health 65." + "\n"
		+ "!apt_item Armor Battery: armour 15. Each prints '[AP] Received ...'.";

	@s = Add( "Arrival announcements", "hl_c02_a2" );
	s.take = "Tau Cannon";
	s.hold = "on_a_rail;nihilanth";
	s.steps =
		"!apt_give Tau Cannon: '[AP] Received Tau Cannon'." + "\n"
		+ "!apt_unlock on_a_rail: '[AP] On A Rail unlocked. !warp 7 to travel there.'" + "\n"
		+ "!apt_unlock nihilanth: its unlocked line only. !apt_unseal nihilanth:" + "\n"
		+ "'[AP] Nihilanth is open. Finish it to win.' !apt_reload: nothing repeats." + "\n"
		+ "!apt_slot aptest:2: nothing printed. !apt_take HEV Suit, then !apt_give HEV Suit:" + "\n"
		+ "only the armour line, no 'Received HEV Suit'.";

	@s = Add( "Unreached part refused", APT_HUB );
	s.steps =
		"No map is reached. !warp hl 1 2: refused (part 2 never reached)." + "\n"
		+ "!warp hl 1: goes to Anomalous Materials (a mission's first map always works).";

	@s = Add( "Tracker multi-word filter", APT_HUB );
	s.steps =
		"!tracker on a rail : lists only On A Rail's checks." + "\n"
		+ "Compare !tracker on : far more missions match.";

	@s = Add( "Butterfingers reissue message", "hl_c02_a2" );
	s.forbid = "First Shotgun";
	s.steps =
		"Shotgun out, !apt_trap Butterfingers Trap. Leave it 30s: it comes back with" + "\n"
		+ "'[AP] The suit reissues your weapon.' once. Again, but pick the dropped gun up" + "\n"
		+ "after 30s yourself: no message. Again, then kill in console before 30s: no" + "\n"
		+ "message on respawn. !apt_give Melee Throw, throw the crowbar: only" + "\n"
		+ "'Your crowbar comes back to you.'";

	@s = Add( "Bot models from the server", "hl_c02_a2" );
	s.trap = "Bot Swarm Trap";
	s.steps =
		"Needs the real client run once first (it writes bot_models.txt)." + "\n"
		+ "Bots wear varied models, stock or custom, all animating (no T-pose)." + "\n"
		+ "!apt_redo: a different mix. Delete store/archipelago/bot_models.txt and" + "\n"
		+ "!apt_redo: only the six built-in models.";
}

string LocPos( const string& in szName )
{
	APTLoc@ l = LocByName( szName );
	return l is null ? "" : l.pos;
}

// ---------------------------------------------------------------- snapshot

void ApplyItems( APTScenario@ s )
{
	g_Held = Items( s.hold );
	g_HeldGoals = Items( s.hold );
	g_Excluded = Items( s.exclude );
	g_szSlot = "aptest:1";
	g_szOnly = s.only;
	g_Items = BaseItems();
	array<string> take = Items( s.take );
	for( uint i = 0; i < take.length(); ++i )
	{
		int k = g_Items.find( take[i] );
		if( k >= 0 )
			g_Items.removeAt( k );
	}
	array<string> give = Items( s.give );
	for( uint i = 0; i < give.length(); ++i )
		if( g_Items.find( give[i] ) < 0 )
			g_Items.insertLast( give[i] );
}

array<string> Items( const string& in szList )
{
	array<string> result;
	array<string>@ parts = szList.Split( ";" );
	for( uint i = 0; i < parts.length(); ++i )
		if( parts[i].Length() > 0 )
			result.insertLast( parts[i] );
	return result;
}

// Everything a new seed can hand out, weapons included, so nothing is gated
// unless a scenario takes it away.
array<string> BaseItems()
{
	array<string> items = Items( "HEV Suit;PCV;Security Armor;Flashlight;Long Jump Module;Melee Throw" );
	for( uint i = 0; i < g_KeyItems.length(); ++i )
		if( items.find( g_KeyItems[i] ) < 0 )
			items.insertLast( g_KeyItems[i] );
	return items;
}

array<string> g_Items;
bool g_bLegacy = false;
string g_szUngated;
bool g_bSuspension = false;
bool g_bConnected = false;
string g_szSession;
// Checks sent during this scenario, reported back as found the way the client
// would. Cleared on every scenario load, so each test starts from nothing.
dictionary g_Found;
// Whether every map's "Reached" check is reported found. Only the warp and menu
// scenarios need it (a warp needs the map reached); elsewhere it filled the HUD
// with 118 checks nobody made.
bool g_bReached = false;
array<string> g_Held;       // mission keys locked
array<string> g_HeldGoals;  // finale keys whose seal stays on
array<string> g_Excluded;
string g_szSlot = "aptest:1";
string g_szOnly;
int g_iSeq = 0;
array<string> g_Events;    // "<seq>|<kind>|<data>|0"

void WriteSnapshot()
{
	array<string> chapters;
	for( uint i = 0; i < g_Chapters.length(); ++i )
		if( g_Held.find( g_Chapters[i].key ) < 0 && g_Excluded.find( g_Chapters[i].key ) < 0 )
			chapters.insertLast( g_Chapters[i].key );

	// Only what this scenario sent counts as found, plus every map's
	// "Reached" for the scenarios that warp; everything else is missing.
	array<string> checked;
	array<string> missing;
	for( uint i = 0; i < g_Locs.length(); ++i )
	{
		if( g_szOnly.Length() > 0 )
		{
			APTChapter@ c = ChapterOfMap( g_Locs[i].map );
			if( c is null || c.campaign != g_szOnly )
				continue;
		}
		if( ( g_bReached && g_Locs[i].kind == "map_reached" ) || g_Found.exists( g_Locs[i].id ) )
			checked.insertLast( g_Locs[i].id );
		else
			missing.insertLast( g_Locs[i].id );
	}

	array<string> goals;
	for( uint i = 0; i < g_CampaignOrder.length(); ++i )
	{
		for( uint j = g_Chapters.length(); j > 0; --j )
		{
			if( g_Chapters[j - 1].campaign == g_CampaignOrder[i] )
			{
				if( g_HeldGoals.find( g_Chapters[j - 1].key ) < 0 )
					goals.insertLast( g_Chapters[j - 1].key );
				break;
			}
		}
	}

	string s = "# Written by APTest.\n";
	s += "session=" + g_szSession + "\n";
	s += "slot=" + g_szSlot + "\n";
	s += "data_version=\n";
	s += "connected=" + ( g_bConnected ? "1" : "0" ) + "\n";
	s += "goal_open=1\n";
	s += "death_link=0\n";
	s += "lobby_death_link=off\n";
	s += "death_link_amnesty=0\n";
	s += "goals_open=" + Join( goals, "," ) + "\n";
	s += "chapters=" + Join( chapters, "," ) + "\n";
	s += "excluded=" + Join( g_Excluded, "," ) + "\n";
	s += "items=" + Join( g_Items, ";" ) + "\n";
	s += "ungated=" + g_szUngated + "\n";
	s += "starting=\n";
	s += "checked=" + Join( checked, "," ) + "\n";
	s += "missing=" + Join( missing, "," ) + "\n";
	if( !g_bLegacy )
		s += "armour=blue_shift:Security Armor;half_life:HEV Suit;"
		     "opposing_force:PCV;they_hunger:HEV Suit\n";
	if( g_bSuspension )
	{
		s += "sus_on=1\nsus_classanity=0\nsus_rolldown=0\n";
		s += "sus_tiers=easy,medium,hard,insane\nsus_awards=\nsus_open=3\n";
		s += "sus_classes=soldier,gl_soldier,shotty,saw,sniper\n";
	}
	for( uint i = 0; i < g_Events.length(); ++i )
		s += "event=" + g_Events[i] + "\n";

	File@ pFile = g_FileSystem.OpenFile( APT_IN, OpenFile::WRITE );
	if( pFile is null || !pFile.IsOpen() )
	{
		Say( "could not write ap_in.txt" );
		return;
	}
	pFile.Write( s );
	pFile.Close();
}

void SendEvent( const string& in szKind, const string& in szData )
{
	++g_iSeq;
	g_Events.insertLast( "" + g_iSeq + "|" + szKind + "|" + szData + "|0" );
	WriteSnapshot();
}

// ---------------------------------------------------------------- ap_out

int g_iOutRead = 0;
bool g_bWatching = false;
int g_iPass = 0;
int g_iFail = 0;
dictionary g_Seen;

array<string> ReadOut()
{
	array<string> lines;
	File@ pFile = g_FileSystem.OpenFile( APT_OUT, OpenFile::READ );
	if( pFile is null || !pFile.IsOpen() )
		return lines;
	while( !pFile.EOFReached() )
	{
		string szLine;
		pFile.ReadLine( szLine );
		if( szLine.Length() > 0 )
			lines.insertLast( szLine );
	}
	pFile.Close();
	return lines;
}

void SkipOut()
{
	g_iOutRead = int( ReadOut().length() );
}

void PollOut()
{
	array<string> lines = ReadOut();
	// The client truncates it on a new session; start over if it shrank.
	if( int( lines.length() ) < g_iOutRead )
		g_iOutRead = 0;

	bool bAcked = false;
	bool bFound = false;
	for( uint i = uint( g_iOutRead ); i < lines.length(); ++i )
	{
		array<string>@ f = lines[i].Split( "|" );
		if( f[0] == "ACK" && f.length() >= 2 )
		{
			for( uint j = g_Events.length(); j > 0; --j )
			{
				if( g_Events[j - 1].Split( "|" )[0] == f[1] )
				{
					g_Events.removeAt( j - 1 );
					bAcked = true;
				}
			}
		}
		else if( f[0] == "CHECK" && f.length() >= 2 )
		{
			if( !g_Found.exists( f[1] ) )
			{
				g_Found[ f[1] ] = true;
				bFound = true;
			}
			if( g_bWatching )
				JudgeCheck( f[1] );
		}
	}
	g_iOutRead = int( lines.length() );

	if( bAcked || bFound )
		WriteSnapshot();
}

void JudgeCheck( const string& in szId )
{
	APTScenario@ s = Current();
	APTLoc@ l = LocById( szId );
	string szName = l is null ? "id " + szId : l.name;
	if( s is null )
		return;

	// The mission's own "reached" check is noise for every scenario here.
	if( l !is null && l.kind == "map_reached" )
		return;

	bool bBad = s.forbidAll || ( s.forbidWeapons && l !is null && l.kind == "weapon_pickup" )
	    || Items( s.forbid ).find( szName ) >= 0;
	bool bExpected = Items( s.expect ).find( szName ) >= 0;

	if( bBad )
	{
		++g_iFail;
		Say( "FAIL: unexpected check '" + szName + "'" );
	}
	else if( bExpected )
	{
		if( !g_Seen.exists( szName ) )
			++g_iPass;
		Say( "PASS: '" + szName + "'" );
	}
	else
		Say( "note: other check '" + szName + "'" );

	g_Seen[ szName ] = true;
}

// ---------------------------------------------------------------- flow

int g_iCurrent = -1;
// "" idle, "hub" on the way through the hub, "target" on the way in.
string g_szPhase;

APTScenario@ Current()
{
	if( g_iCurrent < 0 || uint( g_iCurrent ) >= g_Scenarios.length() )
		return null;
	return g_Scenarios[g_iCurrent];
}

void SaveState()
{
	File@ pFile = g_FileSystem.OpenFile( APT_STATE, OpenFile::WRITE );
	if( pFile is null || !pFile.IsOpen() )
		return;
	pFile.Write( "" + g_iCurrent + "\n" + g_szPhase + "\n" + ( g_bConnected ? "1" : "0" ) + "\n" );
	pFile.Close();
}

void LoadState()
{
	File@ pFile = g_FileSystem.OpenFile( APT_STATE, OpenFile::READ );
	if( pFile is null || !pFile.IsOpen() )
		return;
	string a, b, c;
	pFile.ReadLine( a );
	pFile.ReadLine( b );
	pFile.ReadLine( c );
	pFile.Close();
	g_iCurrent = atoi( a );
	g_szPhase = b;
	g_bConnected = c == "1";
}

void StartScenario( int iIndex )
{
	if( iIndex < 0 || uint( iIndex ) >= g_Scenarios.length() )
	{
		Say( "no scenario " + iIndex + ". !apt lists them." );
		return;
	}

	g_iCurrent = iIndex;
	APTScenario@ s = Current();

	ApplyItems( s );

	g_bLegacy = s.legacy;
	g_bReached = s.reached;
	g_szUngated = s.ungated;
	g_bSuspension = s.suspension;
	g_bConnected = true;
	g_Events.resize( 0 );
	g_bWatching = false;
	g_Seen.deleteAll();
	g_Found.deleteAll();
	WriteSnapshot();

	Say( "Scenario " + iIndex + ": " + s.title + " -> " + s.map );

	// Straight in from the hub, or a reload of the same map or mission; the
	// main plugin accepts both. Anything else goes through the hub first so
	// the arrival is not mistaken for the campaign carrying us onward.
	string szHere = string( g_Engine.mapname );
	APTChapter@ pHere = ChapterOfMap( szHere );
	APTChapter@ pThere = ChapterOfMap( s.map );
	bool bDirect = szHere == APT_HUB || s.map == APT_HUB
	    || ( pHere !is null && pHere is pThere );

	g_szPhase = bDirect ? "target" : "hub";
	SaveState();
	g_Scheduler.SetTimeout( "DoChangeLevel", 1.0f, bDirect ? s.map : APT_HUB );
}

int g_iHopTries = 0;

void HopWhenReady( string szMap )
{
	if( FirstAlive() is null && ++g_iHopTries < 120 )
	{
		g_Scheduler.SetTimeout( "HopWhenReady", 0.5f, szMap );
		return;
	}
	g_Scheduler.SetTimeout( "DoChangeLevel", 2.0f, szMap );
}

void DoChangeLevel( string szMap )
{
	g_EngineFuncs.ServerCommand( "changelevel " + szMap + "\n" );
}

void MapInit()
{
	g_flClientInAt = -1.0f;
	g_bInfoPending = false;
	if( g_pPoll !is null )
		g_Scheduler.RemoveTimer( g_pPoll );
	@g_pPoll = g_Scheduler.SetInterval( "PollOut", 0.25f, g_Scheduler.REPEAT_INFINITE_TIMES );
}

void MapStart()
{
	LoadCheckdata();
	BuildScenarios();
	LoadState();

	APTScenario@ s = Current();
	if( s is null || g_szPhase.Length() == 0 )
		return;

	string szHere = string( g_Engine.mapname );

	if( g_szPhase == "hub" && szHere == APT_HUB )
	{
		g_szPhase = "target";
		SaveState();
		// Not until someone is in the game. A changelevel while the listen
		// server's own client is still connecting has ended in svc_bad and a
		// Host_Error on a precache (sprites/voiceicon.spr).
		g_iHopTries = 0;
		g_Scheduler.SetTimeout( "HopWhenReady", 1.0f, s.map );
		return;
	}

	if( g_szPhase == "target" && szHere == s.map )
	{
		g_szPhase = "";
		SaveState();
		// Snapshot items and events live in globals; rebuild them from the
		// scenario in case the plugin was reloaded mid-trip.
		RestoreSnapshotFor( s );
		g_iArriveTries = 0;
		g_Scheduler.SetTimeout( "Arrive", 2.0f );
	}
}

void RestoreSnapshotFor( APTScenario@ s )
{
	ApplyItems( s );
	g_bLegacy = s.legacy;
	g_bReached = s.reached;
	g_szUngated = s.ungated;
	g_bSuspension = s.suspension;
	WriteSnapshot();
}

int g_iArriveTries = 0;

void Arrive()
{
	APTScenario@ s = Current();
	if( s is null )
		return;

	CBasePlayer@ pPlayer = FirstAlive();
	if( pPlayer is null )
	{
		// Still loading in.
		if( ++g_iArriveTries < 240 )
			g_Scheduler.SetTimeout( "Arrive", 0.5f );
		return;
	}

	// Checks from the trip here are not this scenario's.
	SkipOut();
	g_bWatching = true;

	Teleport();

	if( s.spawn.Length() > 0 )
		g_Scheduler.SetTimeout( "SpawnScenarioThing", 1.0f );
	if( s.trap.Length() > 0 )
		g_Scheduler.SetTimeout( "SendScenarioTrap", 4.0f );

	// Not until the client is actually in the game (see ShowInfoWhenIn): a
	// player counts as alive well before their client is drawing chat.
	g_bInfoPending = true;
	g_iInfoTries = 0;
	g_Scheduler.SetTimeout( "ShowInfoWhenIn", 1.0f );
}

// Set by ClientPutInServer, the engine's word that a client has finished
// loading the map. Cleared each map.
float g_flClientInAt = -1.0f;
bool g_bInfoPending = false;
int g_iInfoTries = 0;

HookReturnCode ClientPutInServer( CBasePlayer@ pPlayer )
{
	g_flClientInAt = g_Engine.time;
	return HOOK_CONTINUE;
}

void ShowInfoWhenIn()
{
	if( !g_bInfoPending )
		return;

	// 3s after the client is in, or give up waiting for the signal after 30s.
	bool bIn = g_flClientInAt >= 0.0f && g_Engine.time - g_flClientInAt >= 3.0f;
	if( !bIn && ++g_iInfoTries < 60 )
	{
		g_Scheduler.SetTimeout( "ShowInfoWhenIn", 0.5f );
		return;
	}

	g_bInfoPending = false;
	ShowInfo();
}

void SpawnScenarioThing()
{
	APTScenario@ s = Current();
	if( s !is null )
		SpawnInFront( FirstAlive(), s.spawn );
}

void SendScenarioTrap()
{
	APTScenario@ s = Current();
	if( s !is null )
		SendEvent( "TRAP", s.trap );
}

void Teleport()
{
	APTScenario@ s = Current();
	if( s is null || s.pos.Length() == 0 )
		return;

	array<string>@ p = s.pos.Split( " " );
	if( p.length() < 3 )
		return;
	Vector vec = FindStandSpot( Vector( atof( p[0] ), atof( p[1] ), atof( p[2] ) ) );

	for( int i = 1; i <= g_Engine.maxClients; ++i )
	{
		CBasePlayer@ pPlayer = g_PlayerFuncs.FindPlayerByIndex( i );
		if( pPlayer is null || !pPlayer.IsConnected() || !pPlayer.IsAlive() )
			continue;
		g_EntityFuncs.SetOrigin( pPlayer, vec );
		pPlayer.pev.velocity = g_vecZero;
	}
}

/*
* Somewhere a standing player fits, as near the point as possible. Item origins
* sit in lockers, on shelves and against walls, and dropping a player on the
* exact spot put them inside the geometry. Rings outward and upward, each spot
* checked with the player hull and then settled onto the floor below it.
*/
bool HullFree( const Vector& in vec )
{
	TraceResult tr;
	g_Utility.TraceHull( vec, vec, ignore_monsters, human_hull, null, tr );
	return tr.fStartSolid == 0 && tr.fAllSolid == 0;
}

Vector FindStandSpot( const Vector& in vecPoint )
{
	// The hull centre sits 36 above the feet; start with the feet on the point.
	Vector vecBase = vecPoint + Vector( 0, 0, 37 );
	array<float> heights = { 0.0f, 16.0f, 32.0f, 64.0f };
	for( int ring = 0; ring <= 6; ++ring )
	{
		float r = ring * 24.0f;
		int iSteps = ring == 0 ? 1 : 8 * ring;
		for( uint h = 0; h < heights.length(); ++h )
		{
			for( int k = 0; k < iSteps; ++k )
			{
				Math.MakeVectors( Vector( 0.0f, 360.0f * k / iSteps, 0.0f ) );
				Vector vec = vecBase + g_Engine.v_forward * r + Vector( 0, 0, heights[h] );
				if( !HullFree( vec ) )
					continue;
				// Nothing solid between the point and here, or it is the next room.
				TraceResult trSeen;
				g_Utility.TraceLine( vecPoint + Vector( 0, 0, 8 ), vec, ignore_monsters, null, trSeen );
				if( trSeen.flFraction < 1.0f )
					continue;
				// Down onto the floor, so nobody lands from a height.
				TraceResult trDown;
				g_Utility.TraceHull( vec, vec - Vector( 0, 0, 128 ), ignore_monsters, human_hull,
				                     null, trDown );
				return trDown.fStartSolid == 0 ? trDown.vecEndPos : vec;
			}
		}
	}
	Say( "no open space found near the spot; dropping you on it anyway (!apt_tp to retry)." );
	return vecPoint + Vector( 0, 0, 48 );
}

void SpawnInFront( CBasePlayer@ pPlayer, const string& in szClassname )
{
	if( pPlayer is null || szClassname.Length() == 0 )
		return;

	Math.MakeVectors( Vector( 0.0f, pPlayer.pev.v_angle.y, 0.0f ) );
	Vector vecStart = pPlayer.pev.origin + Vector( 0.0f, 0.0f, 16.0f );
	Vector vecEnd = vecStart + g_Engine.v_forward * 96.0f;

	// Short of any wall in the way.
	TraceResult tr;
	g_Utility.TraceLine( vecStart, vecEnd, ignore_monsters, pPlayer.edict(), tr );
	Vector vecAt = vecStart + ( tr.vecEndPos - vecStart ) * 0.8f;

	CBaseEntity@ pEntity = g_EntityFuncs.Create( szClassname, vecAt, g_vecZero, false );
	if( pEntity is null )
		Say( "could not spawn " + szClassname );
	else
		Say( "spawned " + szClassname + " in front of you" );
}

void ShowInfo()
{
	APTScenario@ s = Current();
	if( s is null )
	{
		Say( "no scenario running. !apt lists them, !apt_go <n> starts one." );
		return;
	}

	Say( "== " + g_iCurrent + "/" + ( g_Scenarios.length() - 1 ) + " " + s.title + " ==" );
	array<string>@ steps = s.steps.Split( "\n" );
	for( uint i = 0; i < steps.length(); ++i )
		Say( steps[i] );
	if( s.expect.Length() > 0 )
		Say( "Expected: " + Join( Items( s.expect ), ", " ) );
	if( s.forbid.Length() > 0 )
		Say( "FAIL if sent: " + Join( Items( s.forbid ), ", " ) );
	if( s.note )
		Say( "Investigative: answer with !apt_note <findings>." );
	if( s.forbidAll )
		Say( "Any check here is a FAIL." );
	else if( s.forbidWeapons )
		Say( "Any weapon check here is a FAIL." );
	Say( "!apt_next when done. Tally so far: " + g_iPass + " pass, " + g_iFail + " fail." );
}

/*
* The latest recorded verdict per scenario index, "PASS" or "FAIL" plus note.
* Read from aptest_results.txt, where a later line overrides an earlier one.
*/
dictionary LoadVerdicts()
{
	dictionary verdicts;
	File@ pFile = g_FileSystem.OpenFile( APT_RESULTS, OpenFile::READ );
	if( pFile is null || !pFile.IsOpen() )
		return verdicts;
	while( !pFile.EOFReached() )
	{
		string szLine;
		pFile.ReadLine( szLine );
		array<string>@ f = szLine.Split( "|" );
		if( f.length() < 5 )
			continue;
		string szNote = f[4];
		verdicts[ f[1] ] = f[0] + ( szNote.Length() > 0 ? " (" + szNote + ")" : "" );
	}
	pFile.Close();
	return verdicts;
}

void ListScenarios( CBasePlayer@ pPlayer )
{
	dictionary verdicts = LoadVerdicts();
	// Console, since the list is long.
	for( uint i = 0; i < g_Scenarios.length(); ++i )
	{
		string szVerdict = "----";
		verdicts.get( "" + i, szVerdict );
		string szMark = int( i ) == g_iCurrent ? ">" : " ";
		g_PlayerFuncs.ClientPrint( pPlayer, HUD_PRINTCONSOLE,
			szMark + " " + i + ": [" + szVerdict + "] " + g_Scenarios[i].title
			+ " (" + g_Scenarios[i].map + ")\n" );
	}
	g_PlayerFuncs.ClientPrint( pPlayer, HUD_PRINTTALK,
		"[APT] " + g_Scenarios.length() + " scenarios listed in console. !apt_go <n>\n" );
	ShowStatus();
}

/* Counts, and the first scenario with no verdict yet. */
void ShowStatus()
{
	dictionary verdicts = LoadVerdicts();
	int iPass = 0;
	int iFail = 0;
	int iNote = 0;
	int iFirstOpen = -1;
	string szFailed;
	for( uint i = 0; i < g_Scenarios.length(); ++i )
	{
		string szVerdict;
		if( !verdicts.get( "" + i, szVerdict ) )
		{
			if( iFirstOpen < 0 )
				iFirstOpen = int( i );
			continue;
		}
		if( szVerdict.SubString( 0, 4 ) == "PASS" )
			++iPass;
		else if( szVerdict.SubString( 0, 4 ) == "NOTE" )
			++iNote;
		else
		{
			++iFail;
			szFailed += ( szFailed.Length() > 0 ? ", " : "" ) + i;
		}
	}
	int iTotal = int( g_Scenarios.length() );
	Say( "Progress: " + ( iPass + iFail + iNote ) + "/" + iTotal + " done, " + iPass + " pass, "
	     + iFail + " fail" + ( iFail > 0 ? " (" + szFailed + ")" : "" ) + ", " + iNote + " noted." );
	if( iFirstOpen >= 0 )
		Say( "First untested: " + iFirstOpen + " " + g_Scenarios[iFirstOpen].title
		     + ". !apt_go " + iFirstOpen );
	else
		Say( "All scenarios have a verdict." );
}

// ---------------------------------------------------------------- commands

void Dispatch( CBasePlayer@ pPlayer, const string& in szCmd, const string& in szArg )
{
	if( szCmd == "apt" )
		ListScenarios( pPlayer );
	else if( szCmd == "apt_go" )
		StartScenario( atoi( szArg ) );
	else if( szCmd == "apt_next" )
		StartScenario( g_iCurrent + 1 );
	else if( szCmd == "apt_prev" )
		StartScenario( g_iCurrent - 1 );
	else if( szCmd == "apt_redo" )
		StartScenario( g_iCurrent < 0 ? 0 : g_iCurrent );
	else if( szCmd == "apt_pass" || szCmd == "apt_fail" )
		RecordResult( szCmd == "apt_pass" ? "PASS" : "FAIL", szArg );
	else if( szCmd == "apt_note" )
		RecordResult( "NOTE", szArg );
	else if( szCmd == "apt_status" )
		ShowStatus();
	else if( szCmd == "apt_info" )
		ShowInfo();
	else if( szCmd == "apt_tp" )
		Teleport();
	else if( szCmd == "apt_spawn" )
		SpawnInFront( pPlayer, szArg );
	else if( szCmd == "apt_trap" )
	{
		SendEvent( "TRAP", szArg );
		Say( "sent trap: " + szArg );
	}
	else if( szCmd == "apt_give" )
	{
		if( g_Items.find( szArg ) < 0 )
			g_Items.insertLast( szArg );
		WriteSnapshot();
		Say( "gave: " + szArg );
	}
	else if( szCmd == "apt_take" )
	{
		int k = g_Items.find( szArg );
		if( k >= 0 )
			g_Items.removeAt( k );
		WriteSnapshot();
		Say( "took: " + szArg );
	}
	else if( szCmd == "apt_unlock" )
	{
		int k = g_Held.find( szArg );
		if( k >= 0 )
			g_Held.removeAt( k );
		WriteSnapshot();
		Say( "unlocked: " + szArg );
	}
	else if( szCmd == "apt_unseal" )
	{
		int k = g_HeldGoals.find( szArg );
		if( k >= 0 )
			g_HeldGoals.removeAt( k );
		WriteSnapshot();
		Say( "unsealed: " + szArg );
	}
	else if( szCmd == "apt_slot" )
	{
		g_szSlot = szArg;
		WriteSnapshot();
		Say( "slot is now: " + szArg );
	}
	else if( szCmd == "apt_reload" )
	{
		// The emulated state lives in globals, which a map change keeps.
		Say( "reloading " + string( g_Engine.mapname ) );
		g_Scheduler.SetTimeout( "DoChangeLevel", 1.0f, string( g_Engine.mapname ) );
	}
	else if( szCmd == "apt_item" )
	{
		SendEvent( "ITEM", szArg );
		Say( "sent item: " + szArg );
	}
	else if( szCmd == "apt_hp" )
		SetHealth( szArg );
	else if( szCmd == "apt_ammo" )
		ListAmmo( pPlayer );
	else if( szCmd == "apt_off" )
	{
		g_bConnected = false;
		g_iCurrent = -1;
		g_szPhase = "";
		g_bWatching = false;
		WriteSnapshot();
		SaveState();
		Say( "stopped; snapshot says disconnected. Start the real client to take over." );
	}
}

HookReturnCode ClientSay( SayParameters@ pParams )
{
	const CCommand@ pArgs = pParams.GetArguments();
	if( pArgs.ArgC() < 1 )
		return HOOK_CONTINUE;

	string szCmd = pArgs[0];
	if( szCmd.Length() < 4 || szCmd.SubString( 0, 4 ) != "!apt" )
		return HOOK_CONTINUE;
	if( szCmd != "!apt" && szCmd.SubString( 0, 5 ) != "!apt_" )
		return HOOK_CONTINUE;

	pParams.ShouldHide = true;
	Dispatch( pParams.GetPlayer(), szCmd.SubString( 1, szCmd.Length() - 1 ), JoinArgs( pArgs ) );
	return HOOK_HANDLED;
}

void ConsoleCmd( const CCommand@ pArgs )
{
	CBasePlayer@ pPlayer = g_ConCommandSystem.GetCurrentPlayer();
	string szCmd = pArgs[0];
	// ".apt_go" arrives with its namespace dot.
	if( szCmd.SubString( 0, 1 ) == "." )
		szCmd = szCmd.SubString( 1, szCmd.Length() - 1 );
	Dispatch( pPlayer, szCmd, JoinArgs( pArgs ) );
}

CClientCommand g_C0( "apt", "APTest: list scenarios", @ConsoleCmd );
CClientCommand g_C1( "apt_go", "APTest: start scenario n", @ConsoleCmd );
CClientCommand g_C2( "apt_next", "APTest: next scenario", @ConsoleCmd );
CClientCommand g_C3( "apt_prev", "APTest: previous scenario", @ConsoleCmd );
CClientCommand g_C4( "apt_redo", "APTest: restart scenario", @ConsoleCmd );
CClientCommand g_C5( "apt_info", "APTest: scenario steps", @ConsoleCmd );
CClientCommand g_C6( "apt_tp", "APTest: teleport to the spot", @ConsoleCmd );
CClientCommand g_C7( "apt_spawn", "APTest: spawn <classname>", @ConsoleCmd );
CClientCommand g_C8( "apt_trap", "APTest: send a trap", @ConsoleCmd );
CClientCommand g_C9( "apt_give", "APTest: add an item", @ConsoleCmd );
CClientCommand g_CA( "apt_take", "APTest: remove an item", @ConsoleCmd );
CClientCommand g_CB( "apt_off", "APTest: stop emulating", @ConsoleCmd );
CClientCommand g_CC( "apt_pass", "APTest: mark passed [note]", @ConsoleCmd );
CClientCommand g_CD( "apt_fail", "APTest: mark failed [note]", @ConsoleCmd );
CClientCommand g_CE( "apt_status", "APTest: progress so far", @ConsoleCmd );
CClientCommand g_CF( "apt_note", "APTest: record a finding <text>", @ConsoleCmd );
CClientCommand g_CG( "apt_unlock", "APTest: open a held mission <key>", @ConsoleCmd );
CClientCommand g_CH( "apt_unseal", "APTest: lift a held finale seal <key>", @ConsoleCmd );
CClientCommand g_CI( "apt_slot", "APTest: report a different slot <slot>", @ConsoleCmd );
CClientCommand g_CJ( "apt_reload", "APTest: reload this map, state kept", @ConsoleCmd );
CClientCommand g_CK( "apt_item", "APTest: send a filler item <name>", @ConsoleCmd );
CClientCommand g_CL( "apt_hp", "APTest: set health [armour]", @ConsoleCmd );
CClientCommand g_CM( "apt_ammo", "APTest: held ammo vs half max", @ConsoleCmd );

void SetHealth( const string& in szArg )
{
	array<string>@ f = szArg.Split( " " );
	for( int i = 1; i <= g_Engine.maxClients; ++i )
	{
		CBasePlayer@ pPlayer = g_PlayerFuncs.FindPlayerByIndex( i );
		if( pPlayer is null || !pPlayer.IsConnected() || !pPlayer.IsAlive() )
			continue;
		pPlayer.pev.health = atof( f[0] );
		if( f.length() >= 2 && f[1].Length() > 0 )
			pPlayer.pev.armorvalue = atof( f[1] );
	}
	Say( "health set: " + szArg );
}

/*
* Each held weapon's primary ammo against what a granted weapon is owed: half
* its maximum, rounded up. Read right after a respawn, before firing or picking
* anything up. Weapons sharing an ammo type show the same count.
*/
void ListAmmo( CBasePlayer@ pPlayer )
{
	if( pPlayer is null )
		@pPlayer = FirstAlive();
	if( pPlayer is null )
		return;
	for( size_t iSlot = 0; iSlot < MAX_ITEM_TYPES; ++iSlot )
	{
		CBasePlayerItem@ pItem = pPlayer.m_rgpPlayerItems( iSlot );
		while( pItem !is null )
		{
			CBasePlayerWeapon@ pWeapon = pItem.GetWeaponPtr();
			if( pWeapon !is null && pWeapon.m_iPrimaryAmmoType >= 0 && pWeapon.iMaxAmmo1() > 0 )
			{
				int iMax = pWeapon.iMaxAmmo1();
				int iHeld = pPlayer.m_rgAmmo( pWeapon.m_iPrimaryAmmoType );
				int iWanted = ( iMax + 1 ) / 2;
				Say( pItem.GetClassname() + ": " + iHeld + " of max " + iMax + ", owed " + iWanted
				     + ( iMax % 2 == 1 ? " (odd max)" : "" ) + ( iHeld < iWanted ? " LOW" : " ok" ) );
			}
			@pItem = cast<CBasePlayerItem@>( pItem.m_hNextItem.GetEntity() );
		}
	}
}

/*
* A manual verdict, appended to aptest_results.txt so a whole run can be read
* back afterwards. The file keeps every verdict; the last one per scenario wins.
*/
void RecordResult( const string& in szVerdict, const string& in szNote )
{
	APTScenario@ s = Current();
	if( s is null )
	{
		Say( "no scenario running." );
		return;
	}

	string szLine = szVerdict + "|" + g_iCurrent + "|" + s.title
	    + "|" + g_iPass + " auto pass, " + g_iFail + " auto fail|" + szNote + "\n";

	// Read and rewrite: APPEND is not in every build's OpenFile flags.
	string szOld;
	File@ pIn = g_FileSystem.OpenFile( APT_RESULTS, OpenFile::READ );
	if( pIn !is null && pIn.IsOpen() )
	{
		while( !pIn.EOFReached() )
		{
			string szRow;
			pIn.ReadLine( szRow );
			if( szRow.Length() > 0 )
				szOld += szRow + "\n";
		}
		pIn.Close();
	}

	File@ pOut = g_FileSystem.OpenFile( APT_RESULTS, OpenFile::WRITE );
	if( pOut is null || !pOut.IsOpen() )
	{
		Say( "could not write aptest_results.txt" );
		return;
	}
	pOut.Write( szOld + szLine );
	pOut.Close();

	Say( "Marked " + szVerdict + ": " + s.title );
	StartScenario( g_iCurrent + 1 );
}

// ---------------------------------------------------------------- util

void Say( const string& in szText )
{
	g_PlayerFuncs.ClientPrintAll( HUD_PRINTTALK, "[APT] " + szText + "\n" );
}

string Join( const array<string>@ values, const string& in szSep )
{
	string s;
	for( uint i = 0; i < values.length(); ++i )
	{
		if( i > 0 )
			s += szSep;
		s += values[i];
	}
	return s;
}

string JoinArgs( const CCommand@ pArgs )
{
	string s;
	for( int i = 1; i < pArgs.ArgC(); ++i )
	{
		if( i > 1 )
			s += " ";
		s += pArgs[i];
	}
	return s;
}

CBasePlayer@ FirstAlive()
{
	for( int i = 1; i <= g_Engine.maxClients; ++i )
	{
		CBasePlayer@ pPlayer = g_PlayerFuncs.FindPlayerByIndex( i );
		if( pPlayer !is null && pPlayer.IsConnected() && pPlayer.IsAlive() )
			return pPlayer;
	}
	return null;
}

// ---------------------------------------------------------------- init

CScheduledFunction@ g_pPoll;

void PluginInit()
{
	g_Module.ScriptInfo.SetAuthor( "hl1-sven-ap test" );
	g_Module.ScriptInfo.SetContactInfo( "local" );

	g_Hooks.RegisterHook( Hooks::Player::ClientSay, @ClientSay );
	g_Hooks.RegisterHook( Hooks::Player::ClientPutInServer, @ClientPutInServer );

	g_szSession = "aptest-" + Math.RandomLong( 1, 999999999 );
	LoadCheckdata();
	BuildScenarios();
	LoadState();
	SkipOut();

	// A reload must not leave the main plugin reading a snapshot the previous
	// build of this plugin wrote.
	if( Current() !is null && g_bConnected )
		RestoreSnapshotFor( Current() );

	@g_pPoll = g_Scheduler.SetInterval( "PollOut", 0.25f, g_Scheduler.REPEAT_INFINITE_TIMES );
}
