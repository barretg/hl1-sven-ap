/*
* `!trace`: a line on the ground from a player to a check.
*
* `!find` says which way something is in words; this draws it. A beam from the
* player's feet to the check, redrawn each second until the check is sent, the
* player says `!trace` again, or the map changes. Per player, so everyone in the
* lobby can follow their own.
*
* Straight, not routed: a plugin cannot reach the node graph, so the line goes
* through walls exactly as `!find`'s bearing does. Run `!find` for the height
* and the words.
*
* A part's "Reached" and a mission's "Complete" are not places, but the way to
* them is: the changelevel on this map that leads on (`T` records). So those
* trace, and `!find` points, at the exit instead.
*/

const string TRACE_SPRITE = "sprites/laserbeam.spr";

// Precached in MapInit, the only place that is allowed. 0 after a plugin
// reload mid-map, in which case nothing is drawn until the next map.
int g_iTraceSprite = 0;

// Player entindex -> the location id their line goes to.
dictionary g_TraceTargets;

// Tenths of a second. A little longer than the sweep that redraws it, so the
// line never blinks out between frames.
const int TRACE_LIFE = 12;
const int TRACE_WIDTH = 12;

void PrecacheTrace()
{
	g_iTraceSprite = g_Game.PrecacheModel( TRACE_SPRITE );
}

void ClearTraces()
{
	g_TraceTargets.deleteAll();
}

bool TraceActive( CBasePlayer@ pPlayer )
{
	return g_TraceTargets.exists( "" + pPlayer.entindex() );
}

void StopTrace( CBasePlayer@ pPlayer, bool bQuiet = false )
{
	g_TraceTargets.delete( "" + pPlayer.entindex() );
	if( !bQuiet )
		g_PlayerFuncs.ClientPrint( pPlayer, HUD_PRINTTALK, "[AP] Trace off.\n" );
}

/*
* The changelevel on this map that leads toward a check of the mission being
* played: the next part's for a part not reached yet, the way out forward for
* the mission's Complete. Nearest to the player when there are several.
*/
bool WayOn( CBasePlayer@ pPlayer, APLocation@ pLocation, Vector &out vecWay )
{
	APChapter@ pChapter = g_CurrentChapter;
	if( pChapter is null || g_Exits.length() == 0 )
		return false;

	int iHere = pChapter.maps.find( g_szCurrentMap );
	if( iHere < 0 )
		return false;

	bool bOut = false;
	if( pLocation.kind == TRIGGER_CHAPTER_COMPLETE )
	{
		if( pLocation.arg != pChapter.key )
			return false;
		bOut = uint( iHere ) == pChapter.maps.length() - 1;
	}
	else
	{
		// A later part of this mission: its Reached, or anything standing on it.
		int iThere = pChapter.maps.find( pLocation.map );
		if( iThere <= iHere )
			return false;
	}

	string szNext = bOut ? "" : pChapter.maps[iHere + 1];
	bool bFound = false;
	float flBest = 0.0f;

	for( uint i = 0; i < g_Exits.length(); ++i )
	{
		APExit@ pExit = g_Exits[i];
		if( pExit.map != g_szCurrentMap )
			continue;
		// Out of the mission means anywhere it does not own: going back into
		// one of its own earlier parts is not the way on.
		if( bOut ? pChapter.HasMap( pExit.to ) : pExit.to != szNext )
			continue;

		float flScore = TravelScore( pPlayer, pExit.position );
		if( !bFound || flScore < flBest )
		{
			vecWay = pExit.position;
			flBest = flScore;
			bFound = true;
		}
	}

	return bFound;
}

/* Where on this map a line to this check should end, if anywhere. */
bool TraceTargetFor( CBasePlayer@ pPlayer, APLocation@ pLocation, Vector &out vecTarget )
{
	APSource@ pSource = SourceHere( pLocation );
	if( pSource !is null && pSource.hasPosition )
	{
		vecTarget = pSource.position;
		return true;
	}

	if( pLocation.map == g_szCurrentMap && pLocation.hasPosition )
	{
		vecTarget = pLocation.position;
		return true;
	}

	return WayOn( pPlayer, pLocation, vecTarget );
}

/* Red for chargers and pools, orange for weapons, blue for the rest. */
void TraceColour( APLocation@ pLocation, int &out r, int &out g, int &out b )
{
	if( pLocation.kind == TRIGGER_CHARGER )
	{
		r = 255; g = 50; b = 40;
	}
	else if( pLocation.kind == TRIGGER_WEAPON_PICKUP )
	{
		r = 255; g = 150; b = 0;
	}
	else
	{
		r = 60; g = 140; b = 255;
	}
}

void DrawTrace( CBasePlayer@ pPlayer, APLocation@ pLocation, const Vector& in vecTarget )
{
	if( g_iTraceSprite == 0 )
		return;

	// From the feet rather than the eyes, so it reads as a path on the floor and
	// does not sit in the middle of the view.
	Vector vecStart = pPlayer.pev.origin - Vector( 0.0f, 0.0f, 28.0f );
	int r, g, b;
	TraceColour( pLocation, r, g, b );

	NetworkMessage message( MSG_ONE_UNRELIABLE, NetworkMessages::SVC_TEMPENTITY, pPlayer.edict() );
	message.WriteByte( TE_BEAMPOINTS );
	message.WriteCoord( vecStart.x );
	message.WriteCoord( vecStart.y );
	message.WriteCoord( vecStart.z );
	message.WriteCoord( vecTarget.x );
	message.WriteCoord( vecTarget.y );
	message.WriteCoord( vecTarget.z );
	message.WriteShort( g_iTraceSprite );
	message.WriteByte( 0 );      // starting frame
	message.WriteByte( 10 );     // frame rate
	message.WriteByte( TRACE_LIFE );
	message.WriteByte( TRACE_WIDTH );
	message.WriteByte( 0 );      // noise
	message.WriteByte( r );
	message.WriteByte( g );
	message.WriteByte( b );
	message.WriteByte( 200 );    // brightness
	message.WriteByte( 10 );     // scroll speed
	message.End();
}

/*
* Start a line to one check. Says where it is first, as `!find` would, so the
* words and the line agree.
*/
void TraceTo( CBasePlayer@ pPlayer, APLocation@ pLocation )
{
	DescribeLocation( pPlayer, pLocation );

	if( LocationFound( pLocation ) )
	{
		StopTrace( pPlayer, true );
		return;
	}

	Vector vecTarget;
	if( !TraceTargetFor( pPlayer, pLocation, vecTarget ) )
	{
		StopTrace( pPlayer, true );
		g_PlayerFuncs.ClientPrint( pPlayer, HUD_PRINTTALK,
			"[AP] Nothing on this map to draw a line to.\n" );
		return;
	}

	g_TraceTargets[ "" + pPlayer.entindex() ] = pLocation.id;
	DrawTrace( pPlayer, pLocation, vecTarget );
	g_PlayerFuncs.ClientPrint( pPlayer, HUD_PRINTTALK,
		"[AP] Tracing. !trace again to stop.\n" );
}

/* The nearest unfound check this map has a line to, or null. */
APLocation@ NearestTraceable( CBasePlayer@ pPlayer )
{
	APLocation@ pNearest = null;
	float flNearest = 0.0f;

	for( uint i = 0; i < g_Locations.length(); ++i )
	{
		APLocation@ pLocation = g_Locations[i];
		if( !LocationInSeed( pLocation ) || LocationFound( pLocation ) )
			continue;

		Vector vecAt;
		if( !TraceTargetFor( pPlayer, pLocation, vecAt ) )
			continue;

		float flScore = TravelScore( pPlayer, vecAt );
		if( pNearest is null || flScore < flNearest )
		{
			@pNearest = pLocation;
			flNearest = flScore;
		}
	}

	return pNearest;
}

/*
* `!trace [text]`. Bare while a line is up turns it off; bare otherwise traces
* the nearest unfound check; with text, the one it names, as `!find` matches.
*/
void TraceCommand( CBasePlayer@ pPlayer, const string& in szQuery )
{
	string szWanted = APTrim( szQuery );

	if( szWanted.Length() == 0 && TraceActive( pPlayer ) )
	{
		StopTrace( pPlayer );
		return;
	}

	if( g_CheckedLocations.getSize() == 0 && g_MissingLocations.getSize() == 0 )
	{
		g_PlayerFuncs.ClientPrint( pPlayer, HUD_PRINTTALK,
			"[AP] No location data yet; check the client.\n" );
		return;
	}

	if( szWanted.Length() == 0 )
	{
		APLocation@ pNearest = NearestTraceable( pPlayer );
		if( pNearest is null )
		{
			g_PlayerFuncs.ClientPrint( pPlayer, HUD_PRINTTALK,
				"[AP] Nothing left to trace to on this map.\n" );
			return;
		}
		TraceTo( pPlayer, pNearest );
		return;
	}

	// Name matching as `!find` does it, preferring an unfound match on this map.
	string szSimple = APSimplify( szWanted );
	APLocation@ pBest = null;
	uint uiMatches = 0;
	for( uint i = 0; i < g_Locations.length() && szSimple.Length() > 0; ++i )
	{
		APLocation@ pLocation = g_Locations[i];
		if( !LocationInSeed( pLocation ) )
			continue;
		if( int( APSimplify( pLocation.name ).Find( szSimple ) ) < 0 )
			continue;
		++uiMatches;

		Vector vecAt;
		bool bHere = !LocationFound( pLocation )
			&& TraceTargetFor( pPlayer, pLocation, vecAt );
		if( pBest is null || bHere )
			@pBest = pLocation;
		if( bHere )
			break;
	}

	if( pBest is null )
	{
		g_PlayerFuncs.ClientPrint( pPlayer, HUD_PRINTTALK,
			"[AP] Nothing in this seed matches \"" + szWanted + "\".\n" );
		return;
	}

	TraceTo( pPlayer, pBest );
}

/* Trace by id, from the tracker menu. */
void TraceById( CBasePlayer@ pPlayer, int iId )
{
	for( uint i = 0; i < g_Locations.length(); ++i )
	{
		if( g_Locations[i].id == iId )
		{
			TraceTo( pPlayer, g_Locations[i] );
			return;
		}
	}
}

/*
* Once a second: redraw every line, and drop any whose check has been sent or
* has nowhere left to point on this map.
*/
void TraceThink()
{
	if( g_TraceTargets.getSize() == 0 )
		return;

	array<string>@ keys = g_TraceTargets.getKeys();
	for( uint i = 0; i < keys.length(); ++i )
	{
		CBasePlayer@ pPlayer = g_PlayerFuncs.FindPlayerByIndex( atoi( keys[i] ) );
		if( pPlayer is null || !pPlayer.IsConnected() )
		{
			g_TraceTargets.delete( keys[i] );
			continue;
		}

		int iId = 0;
		g_TraceTargets.get( keys[i], iId );
		APLocation@ pLocation = null;
		for( uint j = 0; j < g_Locations.length(); ++j )
		{
			if( g_Locations[j].id == iId )
			{
				@pLocation = g_Locations[j];
				break;
			}
		}

		if( pLocation is null )
		{
			g_TraceTargets.delete( keys[i] );
			continue;
		}

		if( LocationFound( pLocation ) || g_SentChecks.exists( "" + iId ) )
		{
			g_TraceTargets.delete( keys[i] );
			g_PlayerFuncs.ClientPrint( pPlayer, HUD_PRINTTALK,
				"[AP] Found it. Trace off.\n" );
			continue;
		}

		Vector vecTarget;
		if( !pPlayer.IsAlive() || !TraceTargetFor( pPlayer, pLocation, vecTarget ) )
			continue;
		DrawTrace( pPlayer, pLocation, vecTarget );
	}
}

void ConsoleTrace( const CCommand@ pArgs )
{
	CBasePlayer@ pPlayer = g_ConCommandSystem.GetCurrentPlayer();
	if( pPlayer !is null )
		TraceCommand( pPlayer, ConsoleArgs( pArgs ) );
}

CClientCommand g_CmdTrace( "ap_trace", "Draw a line to the nearest check, or one you name", @ConsoleTrace );
