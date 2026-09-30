/*
* In-game menus and the check counter: the same warp and tracker as the chat
* commands, without typing or opening the console.
*
* Sven Co-op gives a plugin two kinds of UI. `CTextMenu` is the numbered menu
* in the corner of the screen, picked with the number keys and paged by itself
* when it runs past a screen; `HudMessage` is free text drawn anywhere on the
* screen for a while. Nothing richer is reachable from a server plugin: no VGUI
* panels, no clickable windows. So the warp is a chain of menus, the tracker is
* menus down to a list of what is left, and the counter is a HUD line.
*
* Menu items are told apart by their text rather than by a payload, one table of
* text -> action per player, so every label in one menu is kept unique.
*/

const int MENU_SLOTS = 33;

array<CTextMenu@> g_Menus( MENU_SLOTS );
array<dictionary> g_MenuActions( MENU_SLOTS );

// Players who have the check counter switched on, by entindex.
dictionary g_HudOn;

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

	RunMenuAction( pPlayer, szAction );
}

/*
* Actions are `verb|argument`:
*
*   main                 the top menu
*   warp                 the campaigns
*   warpc|<campaign>     one campaign's missions
*   warpm|<index>        one mission: its start, or a part already reached
*   go|<index>           warp to a mission
*   gomap|<map>          warp to a part
*   arcade               warp to the arcade map
*   track                the campaigns, with counts
*   trackc|<campaign>    one campaign's missions, with counts
*   trackm|<index>       what is left in one mission
*   find|<id>            point at one location
*   near                 point at the nearest check on this map
*   hub                  back to the hub
*   hud                  the check counter on or off
*/
void RunMenuAction( CBasePlayer@ pPlayer, const string& in szAction )
{
	int iBar = szAction.Find( "|" );
	string szVerb = iBar >= 0 ? szAction.SubString( 0, iBar ) : szAction;
	string szArg = iBar >= 0 ? szAction.SubString( iBar + 1 ) : "";

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
	else if( szVerb == "track" )
		ShowTrackCampaigns( pPlayer );
	else if( szVerb == "trackc" )
		ShowTrackMissions( pPlayer, szArg );
	else if( szVerb == "trackm" )
		ShowTrackMission( pPlayer, atoi( szArg ) );
	else if( szVerb == "find" )
	{
		APLocation@ pLocation = LocationById( atoi( szArg ) );
		if( pLocation !is null )
			DescribeLocation( pPlayer, pLocation );
	}
	else if( szVerb == "near" )
		FindLocation( pPlayer, "" );
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
	MenuAdd( pPlayer, pMenu, "Tracker", "track" );
	MenuAdd( pPlayer, pMenu, "Nearest check here", "near" );
	MenuAdd( pPlayer, pMenu, "Check counter on/off", "hud" );
	MenuAdd( pPlayer, pMenu, "Return to the hub", "hub" );
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

	CTextMenu@ pMenu = NewMenu( pPlayer, "Warp: which game?" );
	for( uint i = 0; i < keys.length(); ++i )
		MenuAdd( pPlayer, pMenu, CampaignDisplay( keys[i] ), "warpc|" + keys[i] );
	if( g_pArcade !is null && g_Suspension.enabled )
		MenuAdd( pPlayer, pMenu, g_pArcade.name, "arcade" );
	MenuOpen( pPlayer, pMenu );
}

/* A short status for a menu line: what `!ap` says, in a word. */
string ChapterMenuStatus( APChapter@ pChapter )
{
	if( ChapterFinished( pChapter ) )
		return "done";
	if( ChapterPlayable( pChapter ) )
		return "open";
	if( pChapter.isGoal || ChapterIsSealed( pChapter.key ) )
		return "sealed";
	return "locked";
}

void ShowWarpMissions( CBasePlayer@ pPlayer, const string& in szCampaign )
{
	CTextMenu@ pMenu = NewMenu( pPlayer, "Warp: " + CampaignDisplay( szCampaign ) );

	for( uint i = 0; i < g_Chapters.length(); ++i )
	{
		APChapter@ pChapter = g_Chapters[i];
		if( pChapter.campaign != szCampaign || g_State.ChapterExcluded( pChapter.key ) )
			continue;

		int iRelative = RelativeNumber( pChapter );
		string szNumber = iRelative >= 0 ? "" + iRelative + ". " : "";
		MenuAdd( pPlayer, pMenu,
			szNumber + pChapter.name + " [" + ChapterMenuStatus( pChapter ) + "]",
			"warpm|" + i );
	}

	MenuOpen( pPlayer, pMenu );
}

/*
* One mission. With nothing but its start reached, that is a warp and no menu;
* otherwise its start and every part already stood in.
*/
void ShowWarpParts( CBasePlayer@ pPlayer, int iIndex )
{
	if( iIndex < 0 || uint( iIndex ) >= g_Chapters.length() )
		return;

	APChapter@ pChapter = g_Chapters[iIndex];

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
	MenuAdd( pPlayer, pMenu, "Start (" + pChapter.FirstMap() + ")", "go|" + iIndex );
	for( uint i = 0; i < reached.length(); ++i )
	{
		MenuAdd( pPlayer, pMenu,
			PartLabel( pChapter, reached[i] ) + " (" + reached[i] + ")",
			"gomap|" + reached[i] );
	}
	MenuOpen( pPlayer, pMenu );
}

/* Found and in-seed counts for a mission, by map membership like `!tracker`. */
void ChapterCounts( APChapter@ pChapter, uint& out uiFound, uint& out uiTotal )
{
	uiFound = 0;
	uiTotal = 0;

	for( uint i = 0; i < g_Locations.length(); ++i )
	{
		APLocation@ pLocation = g_Locations[i];
		if( !ChapterHasMap( pChapter, pLocation.map ) || !LocationInSeed( pLocation ) )
			continue;
		++uiTotal;
		if( LocationFound( pLocation ) )
			++uiFound;
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

	CTextMenu@ pMenu = NewMenu( pPlayer, "Tracker: which game?" );
	for( uint i = 0; i < keys.length(); ++i )
	{
		uint uiFound = 0;
		uint uiTotal = 0;
		for( uint j = 0; j < g_Chapters.length(); ++j )
		{
			if( g_Chapters[j].campaign != keys[i] || g_State.ChapterExcluded( g_Chapters[j].key ) )
				continue;
			uint uiF, uiT;
			ChapterCounts( g_Chapters[j], uiF, uiT );
			uiFound += uiF;
			uiTotal += uiT;
		}
		MenuAdd( pPlayer, pMenu,
			CampaignDisplay( keys[i] ) + "  " + uiFound + "/" + uiTotal, "trackc|" + keys[i] );
	}
	MenuOpen( pPlayer, pMenu );
}

void ShowTrackMissions( CBasePlayer@ pPlayer, const string& in szCampaign )
{
	CTextMenu@ pMenu = NewMenu( pPlayer, "Tracker: " + CampaignDisplay( szCampaign ) );

	for( uint i = 0; i < g_Chapters.length(); ++i )
	{
		APChapter@ pChapter = g_Chapters[i];
		if( pChapter.campaign != szCampaign || g_State.ChapterExcluded( pChapter.key ) )
			continue;

		uint uiFound, uiTotal;
		ChapterCounts( pChapter, uiFound, uiTotal );
		if( uiTotal == 0 )
			continue;

		MenuAdd( pPlayer, pMenu,
			pChapter.name + "  " + uiFound + "/" + uiTotal
			+ ( uiFound == uiTotal ? " (done)" : "" ),
			"trackm|" + i );
	}

	MenuOpen( pPlayer, pMenu );
}

/* What is left in one mission; picking one points at it, as `!find` would. */
void ShowTrackMission( CBasePlayer@ pPlayer, int iIndex )
{
	if( iIndex < 0 || uint( iIndex ) >= g_Chapters.length() )
		return;

	APChapter@ pChapter = g_Chapters[iIndex];
	CTextMenu@ pMenu = NewMenu( pPlayer, pChapter.name + ": still to find" );

	uint uiShown = 0;
	for( uint i = 0; i < g_Locations.length(); ++i )
	{
		APLocation@ pLocation = g_Locations[i];
		if( !ChapterHasMap( pChapter, pLocation.map ) || !LocationInSeed( pLocation )
		    || LocationFound( pLocation ) )
			continue;

		MenuAdd( pPlayer, pMenu, MenuLocationLabel( pChapter, pLocation ),
			"find|" + pLocation.id );
		++uiShown;
	}

	if( uiShown == 0 )
	{
		g_PlayerFuncs.ClientPrint( pPlayer, HUD_PRINTTALK,
			"[AP] Nothing left to find in " + pChapter.name + ".\n" );
		return;
	}

	MenuOpen( pPlayer, pMenu );
}

/*
* A location's name without its mission, which the menu title already says.
* `Surface Tension - Health Charger (Part 2)` reads as `Health Charger (Part 2)`.
*/
string MenuLocationLabel( APChapter@ pChapter, APLocation@ pLocation )
{
	string szPrefix = pChapter.name + " - ";
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

		if( pLocation.map == g_szCurrentMap )
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
	szText += "Seed: " + uiSeedFound + "/" + uiSeedTotal;

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
