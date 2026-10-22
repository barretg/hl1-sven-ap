/*
* In-game menus and the check counter: the same warp, tracker, find and trace
* as the chat commands, without typing or opening the console.
*
* Sven Co-op gives a plugin two kinds of UI. `CTextMenu` is the numbered menu
* in the corner of the screen, picked with the number keys and paged by itself
* when it runs past a screen; `HudMessage` is free text drawn anywhere on the
* screen for a while. Nothing richer is reachable from a server plugin: no VGUI
* panels, no clickable windows. So the warp is a chain of menus, the tracker is
* menus down to a list of what is left, and the counter is a HUD line.
*
* Laid out page for page like Half-Life: Anniversary's and Half-Life 2's
* `!menu`: the tracker opens on the mission being played, picking a check
* traces a line to it, and the warp lists only what is open.
*
* Menu items are told apart by their text rather than by a payload, one table of
* text -> action per player, so every label in one menu is kept unique.
*/

const int MENU_SLOTS = 33;

array<CTextMenu@> g_Menus( MENU_SLOTS );
array<dictionary> g_MenuActions( MENU_SLOTS );

// Players who have the check counter switched on, by entindex.
dictionary g_HudOn;

// The mission each player's tracker shows, by entindex -> chapter key. Absent
// follows wherever the player is. A key, not an index, like Half-Life 2's.
dictionary g_TrackedMission;

const int HUD_CHANNEL = 3;

/*
* Start a fresh menu for this player. Whatever they had open is replaced, and
* unregistered first: a registered menu nobody holds is a leak in the engine's
* menu table.
*/
CTextMenu@ NewMenu( CBasePlayer@ pPlayer, const string& in szTitle )
{
	int iIndex = pPlayer.entindex();

	if( g_Menus[iIndex] !is null && g_Menus[iIndex].IsRegistered() )
		g_Menus[iIndex].Unregister();

	CTextMenu@ pMenu = CTextMenu( @MenuChosen );
	pMenu.SetTitle( szTitle );
	@g_Menus[iIndex] = pMenu;
	g_MenuActions[iIndex].deleteAll();
	return pMenu;
}

void MenuAdd( CBasePlayer@ pPlayer, CTextMenu@ pMenu, const string& in szLabel,
              const string& in szAction )
{
	// Unique labels, since the label is what comes back. A duplicate gains a
	// trailing space, which reads the same.
	string szText = szLabel;
	while( g_MenuActions[pPlayer.entindex()].exists( szText ) )
		szText += " ";

	g_MenuActions[pPlayer.entindex()][ szText ] = szAction;
	pMenu.AddItem( szText );
}

void MenuOpen( CBasePlayer@ pPlayer, CTextMenu@ pMenu )
{
	pMenu.Register();
	pMenu.Open( 0, 0, pPlayer );
}

void MenuChosen( CTextMenu@ pMenu, CBasePlayer@ pPlayer, int iSlot, const CTextMenuItem@ pItem )
{
	if( pPlayer is null || pItem is null )
		return;

	string szAction;
	if( !g_MenuActions[pPlayer.entindex()].get( pItem.m_szName, szAction ) )
		return;

	// Not from inside the callback: the next menu unregisters this one, and
	// unregistering the menu the engine is still handling crashed the game.
	g_Scheduler.SetTimeout( "RunMenuActionLater", 0.0f, pPlayer.entindex(), szAction );
}

void RunMenuActionLater( int iIndex, string szAction )
{
	CBasePlayer@ pPlayer = g_PlayerFuncs.FindPlayerByIndex( iIndex );
	if( pPlayer is null || !pPlayer.IsConnected() )
		return;
	RunMenuAction( pPlayer, szAction );
}

/*
* Actions are `verb|argument`:
*
*   main                 the top menu
*   warp                 the games, when the seed has more than one
*   warpc|<campaign>     one game's open missions
*   warpm|<index>        one mission: its start, or a part already reached
*   go|<index>           warp to a mission
*   gomap|<map>          warp to a part
*   arcade               warp to the arcade map
*   tracker              the tracked mission, or the one being played
*   trackg               the games, to track a mission in
*   trackc|<campaign>    one game's missions, to track one
*   trackset|<key>       track this mission
*   trackp|<map>         one part's checks
*   trackw|<campaign>    one game's weapon checks
*   trace|<id>           say where a check is and trace a line to it
*   near                 point at the nearest check on this map
*   tracenear            trace the nearest check, or stop tracing
*   hub                  back to the hub
*   hud                  the check counter on or off
*/
void RunMenuAction( CBasePlayer@ pPlayer, const string& in szAction )
{
	int iBar = szAction.Find( "|" );
	string szVerb = iBar >= 0 ? szAction.SubString( 0, iBar ) : szAction;
	string szArg = iBar >= 0 ? szAction.SubString( iBar + 1, szAction.Length() - iBar - 1 ) : "";

	if( szVerb == "main" )
		ShowMainMenu( pPlayer );
	else if( szVerb == "warp" )
		ShowWarpCampaigns( pPlayer );
	else if( szVerb == "warpc" )
		ShowWarpMissions( pPlayer, szArg );
	else if( szVerb == "warpm" )
		ShowWarpParts( pPlayer, atoi( szArg ) );
	else if( szVerb == "go" )
		WarpToChapter( pPlayer, atoi( szArg ) );
	else if( szVerb == "gomap" )
		WarpToMap( pPlayer, ChapterForMap( szArg ), szArg );
	else if( szVerb == "arcade" )
		WarpToArcade( pPlayer );
	else if( szVerb == "tracker" )
		ShowTrackerMenu( pPlayer );
	else if( szVerb == "trackg" )
		ShowTrackCampaigns( pPlayer );
	else if( szVerb == "trackc" )
		ShowTrackMissions( pPlayer, szArg );
	else if( szVerb == "trackset" )
	{
		g_TrackedMission[ "" + pPlayer.entindex() ] = szArg;
		ShowTrackerMenu( pPlayer );
	}
	else if( szVerb == "trackp" )
		ShowTrackPart( pPlayer, szArg );
	else if( szVerb == "trackw" )
		ShowTrackWeapons( pPlayer, szArg );
	else if( szVerb == "trace" )
		TraceById( pPlayer, atoi( szArg ) );
	else if( szVerb == "near" )
		FindLocation( pPlayer, "" );
	else if( szVerb == "tracenear" )
		TraceCommand( pPlayer, "" );
	else if( szVerb == "hub" )
	{
		g_PlayerFuncs.ClientPrintAll( HUD_PRINTTALK, "[AP] Returning to the hub...\n" );
		ReturnToHub();
	}
	else if( szVerb == "hud" )
		ToggleCheckHud( pPlayer );
}

APLocation@ LocationById( int iId )
{
	for( uint i = 0; i < g_Locations.length(); ++i )
	{
		if( g_Locations[i].id == iId )
			return g_Locations[i];
	}
	return null;
}

void ShowMainMenu( CBasePlayer@ pPlayer )
{
	CTextMenu@ pMenu = NewMenu( pPlayer, "Archipelago" );
	MenuAdd( pPlayer, pMenu, "Warp to a mission", "warp" );
	MenuAdd( pPlayer, pMenu, "Tracker", "tracker" );
	MenuAdd( pPlayer, pMenu, "Find the nearest check", "near" );
	MenuAdd( pPlayer, pMenu,
		TraceActive( pPlayer ) ? "Stop tracing" : "Trace to the nearest check", "tracenear" );
	MenuAdd( pPlayer, pMenu, "Go to the hub", "hub" );
	MenuAdd( pPlayer, pMenu, "Check counter on/off", "hud" );
	MenuOpen( pPlayer, pMenu );
}

/* Campaign keys this seed contains, in data order. */
array<string> SeedCampaigns()
{
	array<string> keys;
	for( uint i = 0; i < g_Chapters.length(); ++i )
	{
		APChapter@ pChapter = g_Chapters[i];
		if( g_State.ChapterExcluded( pChapter.key ) )
			continue;
		if( keys.find( pChapter.campaign ) < 0 )
			keys.insertLast( pChapter.campaign );
	}
	return keys;
}

string CampaignDisplay( const string& in szKey )
{
	string szName = szKey;
	g_CampaignNames.get( szKey, szName );
	return szName;
}

void ShowWarpCampaigns( CBasePlayer@ pPlayer )
{
	array<string> keys = SeedCampaigns();

	// One campaign: straight to its missions, since a menu with one choice is a
	// key press for nothing.
	if( keys.length() == 1 && !( g_pArcade !is null && g_Suspension.enabled ) )
	{
		ShowWarpMissions( pPlayer, keys[0] );
		return;
	}

	CTextMenu@ pMenu = NewMenu( pPlayer, "Warp to a mission" );
	for( uint i = 0; i < keys.length(); ++i )
		MenuAdd( pPlayer, pMenu, CampaignDisplay( keys[i] ), "warpc|" + keys[i] );
	if( g_pArcade !is null && g_Suspension.enabled )
		MenuAdd( pPlayer, pMenu, g_pArcade.name, "arcade" );
	MenuOpen( pPlayer, pMenu );
}

/*
* What `!ap` says, in a word, and "(Remote Complete)" after it for a mission
* only the server finished.
*/
string ChapterMenuStatus( APChapter@ pChapter )
{
	string szStatus;
	if( ChapterDoneHere( pChapter ) )
		szStatus = "done";
	else if( ChapterPlayable( pChapter ) )
		szStatus = "open";
	else if( pChapter.isGoal || ChapterIsSealed( pChapter.key ) )
		szStatus = "sealed";
	else
		szStatus = "locked";
	return "[" + szStatus + "]" + RemoteNote( pChapter );
}

/* Only the missions that can be entered now: the rest are a key press for a refusal. */
void ShowWarpMissions( CBasePlayer@ pPlayer, const string& in szCampaign )
{
	string szTitle = "Warp to a mission";
	if( SeedCampaigns().length() > 1 )
		szTitle += ": " + CampaignDisplay( szCampaign );

	array<APChapter@> open;
	for( uint i = 0; i < g_Chapters.length(); ++i )
	{
		APChapter@ pChapter = g_Chapters[i];
		if( pChapter.campaign == szCampaign && !g_State.ChapterExcluded( pChapter.key )
		    && ChapterPlayable( pChapter ) )
			open.insertLast( pChapter );
	}

	if( open.length() == 0 )
		szTitle += "\n(nothing open yet)";

	CTextMenu@ pMenu = NewMenu( pPlayer, szTitle );
	for( uint i = 0; i < open.length(); ++i )
	{
		APChapter@ pChapter = open[i];
		int iRelative = RelativeNumber( pChapter );
		string szNumber = iRelative >= 0 ? "" + iRelative + ". " : "";
		MenuAdd( pPlayer, pMenu,
			szNumber + pChapter.name + " " + ChapterMenuStatus( pChapter ),
			"warpm|" + pChapter.index );
	}
	if( open.length() == 0 )
		MenuAdd( pPlayer, pMenu, "Back", "main" );

	MenuOpen( pPlayer, pMenu );
}

/*
* One mission. With nothing but its start reached, that is a warp and no menu;
* otherwise its start and every part already stood in, with what each still has.
*/
void ShowWarpParts( CBasePlayer@ pPlayer, int iIndex )
{
	APChapter@ pChapter = null;
	for( uint i = 0; i < g_Chapters.length(); ++i )
		if( g_Chapters[i].index == iIndex )
			@pChapter = g_Chapters[i];
	if( pChapter is null )
		return;

	array<string> reached;
	for( uint i = 1; i < pChapter.maps.length(); ++i )
	{
		if( MapReached( pChapter.maps[i] ) )
			reached.insertLast( pChapter.maps[i] );
	}

	if( reached.length() == 0 || !ChapterPlayable( pChapter ) )
	{
		WarpToChapter( pPlayer, iIndex );
		return;
	}

	CTextMenu@ pMenu = NewMenu( pPlayer, pChapter.name );
	MenuAdd( pPlayer, pMenu, "From the start", "go|" + iIndex );
	for( uint i = 0; i < reached.length(); ++i )
	{
		uint uiFound, uiTotal;
		PartCounts( reached[i], uiFound, uiTotal );
		MenuAdd( pPlayer, pMenu,
			PartLabel( pChapter, reached[i] ) + " (" + uiFound + "/" + uiTotal + " found)",
			"gomap|" + reached[i] );
	}
	MenuOpen( pPlayer, pMenu );
}

/*
* Weapon checks are tracked per game, not per mission: any mission's copy sends
* one, so the mission its earliest copy sits in is not where it belongs.
*/
bool IsWeaponCheck( APLocation@ pLocation )
{
	return pLocation.kind == TRIGGER_WEAPON_PICKUP;
}

/* The game a weapon check belongs to, by the map its earliest copy is on. */
string WeaponCampaign( APLocation@ pLocation )
{
	APChapter@ pChapter = ChapterForMap( pLocation.map );
	return pChapter is null ? "" : pChapter.campaign;
}

/* Found and in-seed counts for a game's weapon checks. */
void WeaponCounts( const string& in szCampaign, uint& out uiFound, uint& out uiTotal )
{
	uiFound = 0;
	uiTotal = 0;

	for( uint i = 0; i < g_Locations.length(); ++i )
	{
		APLocation@ pLocation = g_Locations[i];
		if( !IsWeaponCheck( pLocation ) || !LocationInSeed( pLocation )
		    || WeaponCampaign( pLocation ) != szCampaign )
			continue;
		++uiTotal;
		if( LocationFound( pLocation ) )
			++uiFound;
	}
}

/* Found and in-seed counts for one part's checks, weapons apart. */
void PartCounts( const string& in szMap, uint& out uiFound, uint& out uiTotal )
{
	uiFound = 0;
	uiTotal = 0;

	for( uint i = 0; i < g_Locations.length(); ++i )
	{
		APLocation@ pLocation = g_Locations[i];
		if( IsWeaponCheck( pLocation ) || pLocation.map != szMap || !LocationInSeed( pLocation ) )
			continue;
		++uiTotal;
		if( LocationFound( pLocation ) )
			++uiFound;
	}
}

/* Found and in-seed counts for a mission, by map membership like `!tracker`. */
void ChapterCounts( APChapter@ pChapter, uint& out uiFound, uint& out uiTotal )
{
	uiFound = 0;
	uiTotal = 0;

	for( uint i = 0; i < pChapter.maps.length(); ++i )
	{
		uint uiF, uiT;
		PartCounts( pChapter.maps[i], uiF, uiT );
		uiFound += uiF;
		uiTotal += uiT;
	}
}

bool TrackerReady( CBasePlayer@ pPlayer )
{
	if( g_CheckedLocations.getSize() > 0 || g_MissingLocations.getSize() > 0 )
		return true;

	g_PlayerFuncs.ClientPrint( pPlayer, HUD_PRINTTALK,
		"[AP] No location data yet; check the client.\n" );
	return false;
}

/* The mission this player's tracker shows: the one they chose, or where they are. */
APChapter@ TrackedChapter( CBasePlayer@ pPlayer )
{
	string szKey;
	if( g_TrackedMission.get( "" + pPlayer.entindex(), szKey ) )
	{
		APChapter@ pChosen = ChapterByKey( szKey );
		if( pChosen !is null && !g_State.ChapterExcluded( pChosen.key ) )
			return pChosen;
	}
	return g_CurrentChapter;
}

/*
* `!tracker <mission>` also makes that mission the menu's: the text matched as
* `!warp` matches names, and only an unambiguous match counts.
*/
void TrackMission( CBasePlayer@ pPlayer, const string& in szFilter )
{
	string szWanted = APTrim( szFilter );
	szWanted.ToLowercase();
	if( szWanted.Length() == 0 )
		return;

	array<int> matches;
	MatchChapters( szWanted, matches );
	if( matches.length() != 1 )
		return;

	APChapter@ pChapter = g_Chapters[matches[0]];
	if( g_State.ChapterExcluded( pChapter.key ) )
		return;
	g_TrackedMission[ "" + pPlayer.entindex() ] = pChapter.key;
	g_PlayerFuncs.ClientPrint( pPlayer, HUD_PRINTTALK,
		"[AP] !menu's tracker now follows " + pChapter.name + ".\n" );
}

/*
* The tracked mission: a line per part with checks, "(here)" on the one being
* stood in, the game's weapons, and a way to track another. In the hub with
* nothing chosen there is nothing to follow, so it asks which.
*/
void ShowTrackerMenu( CBasePlayer@ pPlayer )
{
	if( !TrackerReady( pPlayer ) )
		return;

	APChapter@ pChapter = TrackedChapter( pPlayer );
	if( pChapter is null )
	{
		ShowTrackCampaigns( pPlayer );
		return;
	}

	CTextMenu@ pMenu = NewMenu( pPlayer,
		"Tracker: " + pChapter.name + " " + ChapterMenuStatus( pChapter ) );

	for( uint i = 0; i < pChapter.maps.length(); ++i )
	{
		string szMap = pChapter.maps[i];
		uint uiFound, uiTotal;
		PartCounts( szMap, uiFound, uiTotal );
		if( uiTotal == 0 )
			continue;

		string szPart = pChapter.maps.length() > 1 ? "Part " + ( i + 1 ) : "Checks";
		MenuAdd( pPlayer, pMenu,
			szPart + ": " + uiFound + "/" + uiTotal
			+ ( szMap == g_szCurrentMap ? " (here)" : "" ),
			"trackp|" + szMap );
	}

	uint uiWFound, uiWTotal;
	WeaponCounts( pChapter.campaign, uiWFound, uiWTotal );
	if( uiWTotal > 0 )
		MenuAdd( pPlayer, pMenu, "Weapons: " + uiWFound + "/" + uiWTotal,
			"trackw|" + pChapter.campaign );

	MenuAdd( pPlayer, pMenu, "Track another mission", "trackg" );
	MenuOpen( pPlayer, pMenu );
}

void ShowTrackCampaigns( CBasePlayer@ pPlayer )
{
	if( !TrackerReady( pPlayer ) )
		return;

	array<string> keys = SeedCampaigns();
	if( keys.length() == 1 )
	{
		ShowTrackMissions( pPlayer, keys[0] );
		return;
	}

	CTextMenu@ pMenu = NewMenu( pPlayer, "Track a mission" );
	for( uint i = 0; i < keys.length(); ++i )
		MenuAdd( pPlayer, pMenu, CampaignDisplay( keys[i] ), "trackc|" + keys[i] );
	MenuOpen( pPlayer, pMenu );
}

void ShowTrackMissions( CBasePlayer@ pPlayer, const string& in szCampaign )
{
	string szTitle = "Track a mission";
	if( SeedCampaigns().length() > 1 )
		szTitle += ": " + CampaignDisplay( szCampaign );

	CTextMenu@ pMenu = NewMenu( pPlayer, szTitle );

	for( uint i = 0; i < g_Chapters.length(); ++i )
	{
		APChapter@ pChapter = g_Chapters[i];
		if( pChapter.campaign != szCampaign || g_State.ChapterExcluded( pChapter.key ) )
			continue;

		uint uiFound, uiTotal;
		ChapterCounts( pChapter, uiFound, uiTotal );
		MenuAdd( pPlayer, pMenu,
			pChapter.name + ": " + uiFound + "/" + uiTotal
			+ ( pChapter is g_CurrentChapter ? " (here)" : "" ),
			"trackset|" + pChapter.key );
	}

	MenuOpen( pPlayer, pMenu );
}

/*
* A list of checks, unfound first. Found ones follow, marked `[done]`: a text
* menu cannot grey out a single entry, so position and the mark say it.
* Picking any of them says where it is and traces a line to it.
*/
void ShowCheckList( CBasePlayer@ pPlayer, const string& in szTitle,
                    array<APLocation@>@ left, array<APLocation@>@ done, const string& in szPrefix )
{
	CTextMenu@ pMenu = NewMenu( pPlayer, szTitle + ": " + done.length() + "/"
		+ ( left.length() + done.length() ) + " found" );

	for( uint i = 0; i < left.length(); ++i )
		MenuAdd( pPlayer, pMenu, ShortLabel( szPrefix, left[i] ), "trace|" + left[i].id );
	for( uint i = 0; i < done.length(); ++i )
		MenuAdd( pPlayer, pMenu, "[done] " + ShortLabel( szPrefix, done[i] ),
			"trace|" + done[i].id );

	MenuOpen( pPlayer, pMenu );
}

/* One part's checks, weapons apart: they belong to the game, not the map. */
void ShowTrackPart( CBasePlayer@ pPlayer, const string& in szMap )
{
	APChapter@ pChapter = ChapterForMap( szMap );
	if( pChapter is null )
		return;

	array<APLocation@> left;
	array<APLocation@> done;
	for( uint i = 0; i < g_Locations.length(); ++i )
	{
		APLocation@ pLocation = g_Locations[i];
		if( IsWeaponCheck( pLocation ) || pLocation.map != szMap || !LocationInSeed( pLocation ) )
			continue;
		if( LocationFound( pLocation ) )
			done.insertLast( pLocation );
		else
			left.insertLast( pLocation );
	}

	if( left.length() + done.length() == 0 )
	{
		g_PlayerFuncs.ClientPrint( pPlayer, HUD_PRINTTALK,
			"[AP] No checks in " + pChapter.name + ".\n" );
		return;
	}

	string szPart = PartLabel( pChapter, szMap );
	szPart.ToLowercase();
	ShowCheckList( pPlayer,
		pChapter.name + ( szPart.Length() > 0 ? ", " + szPart : "" ),
		left, done, pChapter.name + ": " );
}

/* One game's weapon checks, laid out like a part's. */
void ShowTrackWeapons( CBasePlayer@ pPlayer, const string& in szCampaign )
{
	array<APLocation@> left;
	array<APLocation@> done;
	for( uint i = 0; i < g_Locations.length(); ++i )
	{
		APLocation@ pLocation = g_Locations[i];
		if( !IsWeaponCheck( pLocation ) || !LocationInSeed( pLocation )
		    || WeaponCampaign( pLocation ) != szCampaign )
			continue;
		if( LocationFound( pLocation ) )
			done.insertLast( pLocation );
		else
			left.insertLast( pLocation );
	}

	string szGame = CampaignDisplay( szCampaign );
	if( left.length() + done.length() == 0 )
	{
		g_PlayerFuncs.ClientPrint( pPlayer, HUD_PRINTTALK,
			"[AP] No weapon checks in " + szGame + ".\n" );
		return;
	}

	ShowCheckList( pPlayer, szGame + " weapons", left, done, szGame + ": " );
}

/*
* A location's name without what the menu title already says. `Surface Tension:
* Health Charger (Part 2)` reads as `Health Charger (Part 2)`, and `Opposing
* Force: First Glock` as `First Glock`.
*/
string ShortLabel( const string& in szPrefix, APLocation@ pLocation )
{
	if( pLocation.name.Length() > szPrefix.Length()
	    && pLocation.name.SubString( 0, szPrefix.Length() ) == szPrefix )
		return pLocation.name.SubString( szPrefix.Length() );
	return pLocation.name;
}

// --- the check counter -----------------------------------------------------

void ToggleCheckHud( CBasePlayer@ pPlayer )
{
	string szKey = "" + pPlayer.entindex();
	if( g_HudOn.exists( szKey ) )
	{
		g_HudOn.delete( szKey );
		g_PlayerFuncs.ClientPrint( pPlayer, HUD_PRINTTALK, "[AP] Check counter off.\n" );
	}
	else
	{
		g_HudOn[ szKey ] = true;
		g_PlayerFuncs.ClientPrint( pPlayer, HUD_PRINTTALK, "[AP] Check counter on.\n" );
		UpdateCheckHud();
	}
}

/*
* Redrawn on the one-second sweep, held a little longer than that so it never
* flickers. Three lines: this map, this mission, and the whole seed.
*/
void UpdateCheckHud()
{
	if( g_HudOn.getSize() == 0 )
		return;
	if( g_CheckedLocations.getSize() == 0 && g_MissingLocations.getSize() == 0 )
		return;

	uint uiMapFound = 0, uiMapTotal = 0;
	uint uiSeedFound = 0, uiSeedTotal = 0;

	for( uint i = 0; i < g_Locations.length(); ++i )
	{
		APLocation@ pLocation = g_Locations[i];
		if( !LocationInSeed( pLocation ) )
			continue;

		bool bFound = LocationFound( pLocation );
		++uiSeedTotal;
		if( bFound )
			++uiSeedFound;

		if( pLocation.map == g_szCurrentMap && !IsWeaponCheck( pLocation ) )
		{
			++uiMapTotal;
			if( bFound )
				++uiMapFound;
		}
	}

	string szText;
	if( g_CurrentChapter !is null )
	{
		uint uiFound, uiTotal;
		ChapterCounts( g_CurrentChapter, uiFound, uiTotal );
		szText += "This map: " + uiMapFound + "/" + uiMapTotal + "\n";
		szText += g_CurrentChapter.name + ": " + uiFound + "/" + uiTotal + "\n";
	}
	szText += "Total: " + uiSeedFound + "/" + uiSeedTotal;

	HUDTextParams params;
	params.x = 0.02f;
	params.y = 0.2f;
	params.effect = 0;
	params.r1 = params.r2 = 255;
	params.g1 = params.g2 = 170;
	params.b1 = params.b2 = 0;
	params.a1 = params.a2 = 255;
	params.fadeinTime = 0.0f;
	params.fadeoutTime = 0.0f;
	params.holdTime = 1.5f;
	params.fxTime = 0.0f;
	params.channel = HUD_CHANNEL;

	array<string>@ keys = g_HudOn.getKeys();
	for( uint i = 0; i < keys.length(); ++i )
	{
		CBasePlayer@ pPlayer = g_PlayerFuncs.FindPlayerByIndex( atoi( keys[i] ) );
		if( pPlayer is null || !pPlayer.IsConnected() )
		{
			g_HudOn.delete( keys[i] );
			continue;
		}
		g_PlayerFuncs.HudMessage( pPlayer, params, szText );
	}
}

void ConsoleMenu( const CCommand@ pArgs )
{
	CBasePlayer@ pPlayer = g_ConCommandSystem.GetCurrentPlayer();
	if( pPlayer !is null )
		ShowMainMenu( pPlayer );
}

void ConsoleHud( const CCommand@ pArgs )
{
	CBasePlayer@ pPlayer = g_ConCommandSystem.GetCurrentPlayer();
	if( pPlayer !is null )
		ToggleCheckHud( pPlayer );
}

CClientCommand g_CmdMenu( "ap_menu", "Warp and tracker menus", @ConsoleMenu );
CClientCommand g_CmdHud( "ap_hud", "Toggle the check counter", @ConsoleHud );
