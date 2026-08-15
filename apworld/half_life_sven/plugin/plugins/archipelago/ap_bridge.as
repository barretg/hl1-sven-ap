/*
* Archipelago file bridge.
*
* AngelScript has no sockets, but plugins may read and write inside
* scripts/plugins/store/. The Python client owns the connection to the
* Archipelago server and talks to us through two files:
*
*   ap_in.txt   client -> game, a full snapshot, rewritten whenever it changes.
*   ap_out.txt  game -> client, append-only event log.
*
* The snapshot is replayed in full on every map load, which is what makes the
* plugin stateless. Anything that must happen exactly once (an item grant, an
* incoming DeathLink) is carried as a sequenced `event=` line instead; we act on
* it, write back `ACK <seq>`, and the client drops it from the next snapshot.
*/

// The last snapshot text we parsed, so a poll that finds no change can bail out
// without reparsing. Compared in full rather than by size: `connected=1` and
// `connected=0` are the same length, and a size check would silently freeze the
// plugin on a stale snapshot forever.
string g_szLastInput;

// The client stamps each session with an id. When it changes, the client has
// restarted and its event sequence numbers have restarted with it.
string g_szSession;

// Which slot of which seed the client is playing, "<seed>:<slot>". This is what
// says the run has changed underneath us, and it is a different question from
// the session above: a client restarted onto the same slot is a blip and must
// change nothing, while a different slot connected from the same client changes
// everything the plugin remembers.
//
// Only ever set from a snapshot that names one. A disconnected client sends it
// empty, which is no news rather than a new slot.
string g_szSlot;

// The client's wall-clock time when it last wrote the snapshot. Event freshness
// is judged against this, so the two sides never have to agree on a clock.
float g_flSnapshotNow = 0.0f;

/*
* Append one line to the outgoing log.
*
* Opened and closed per write: writes are rare (a handful per minute) and this
* means a crash mid-session never leaves a half-written file behind.
*/
void BridgeSend( const string& in szLine )
{
	File@ pFile = g_FileSystem.OpenFile( AP_OUT, OpenFile::APPEND );

	if( pFile is null || !pFile.IsOpen() )
	{
		APLog( "could not append to " + AP_OUT );
		return;
	}

	pFile.Write( szLine + "\n" );
	pFile.Close();
}

/*
* Refuse to work if our location ids do not mean the same thing as the seed's.
*
* This is the failure that looks like the plugin sending random checks: reaching
* a map fires the right id, but an older seed resolves that id to whatever
* location used to hold it.
*/
void CheckDataVersion( const string& in szClientVersion )
{
	if( szClientVersion.Length() == 0 || g_szDataVersion.Length() == 0 )
		return;

	bool bMismatch = szClientVersion != g_szDataVersion;
	if( bMismatch == g_bDataMismatch )
		return;

	g_bDataMismatch = bMismatch;

	if( bMismatch )
	{
		APLog( "DATA MISMATCH: plugin " + g_szDataVersion + ", client " + szClientVersion );
		// Two calls: 128 bytes is the print buffer, and this pair is over it.
		g_PlayerFuncs.ClientPrintAll( HUD_PRINTTALK,
			"[AP] Plugin and apworld versions do not match. Checks are paused.\n" );
		g_PlayerFuncs.ClientPrintAll( HUD_PRINTTALK,
			"[AP] Reinstall the plugin with /install, or regenerate your seed.\n" );
	}
	else
	{
		APLog( "data version matches the client" );
	}
}

void SendCheck( APLocation@ pLocation )
{
	// Sending here would report a location the seed does not agree with.
	if( g_bDataMismatch )
		return;

	// Not while we are only passing through. Finishing a mission loads the next
	// one for a moment before we bounce back to the hub, and during those few
	// seconds the proximity sweep is perfectly happy to notice the crowbar lying
	// in the map we just arrived in -- which is how "Blue Shift - First Crowbar"
	// arrived for finishing Insecurity, a mission away from where it lives.
	//
	// `g_bMissionActive` is exactly the right question: it is true only on a map
	// we are meant to be playing, and false on the hub, on a mission we never
	// unlocked, and on the one we are bouncing out of.
	if( !g_bMissionActive )
		return;

	string szKey = "" + pLocation.id;
	if( g_SentChecks.exists( szKey ) )
		return;

	g_SentChecks[ szKey ] = true;
	BridgeSend( "CHECK|" + pLocation.id );
	g_PlayerFuncs.ClientPrintAll( HUD_PRINTTALK, "[AP] " + pLocation.name + "\n" );
}

void SendAck( int iSeq )
{
	BridgeSend( "ACK|" + iSeq );
}

/*
* Read the whole snapshot and rebuild g_State from it.
*
* Recognised keys:
*   chapters=<key>,<key>,...      missions whose unlock item we hold
*   excluded=<key>,<key>,...      missions this seed left out entirely
*   items=<name>;<name>;...       AP item names we hold (weapons, equipment)
*   goal_open=0|1                 enough missions done to enter the goal mission
*   death_link=0|1
*   death_link_amnesty=<n>        deaths forgiven before one is reported out
*   connected=0|1
*   event=<seq>|<kind>|<payload>|<unixtime>
*/
void BridgePoll()
{
	File@ pFile = g_FileSystem.OpenFile( AP_IN, OpenFile::READ );

	if( pFile is null || !pFile.IsOpen() )
		return;

	// Read the whole file first, then decide whether it is worth parsing. The
	// snapshot is a couple of hundred bytes, so this is cheaper than being
	// clever and cannot go stale the way a size comparison can.
	string szInput;
	while( !pFile.EOFReached() )
	{
		string szRaw;
		pFile.ReadLine( szRaw );
		szInput += szRaw + "\n";
	}
	pFile.Close();

	if( szInput == g_szLastInput )
		return;
	g_szLastInput = szInput;

	array<string>@ inputLines = szInput.Split( "\n" );

	dictionary chapters;
	dictionary excluded;
	dictionary items;
	dictionary ungated;
	dictionary goalsOpen;
	dictionary checked;
	dictionary missing;
	array<string> starting;
	bool bGoalOpen = false;
	bool bConnected = false;
	bool bDeathLink = false;
	string szLobbyDeath = "on";
	int iAmnesty = 0;
	array<string> events;

	string szSession;
	string szSlot;
	// Absent entirely from a client too old to send it, which is not the same as
	// a client saying it has no slot: without the field the session is the only
	// signal there is, and the old behaviour is the best available.
	bool bHasSlot = false;

	for( uint iLine = 0; iLine < inputLines.length(); ++iLine )
	{
		string szLine = APTrim( inputLines[iLine] );
		if( szLine.Length() == 0 || szLine.SubString( 0, 1 ) == "#" )
			continue;

		int iSplit = szLine.Find( "=" );
		if( iSplit < 0 )
			continue;

		string szKey = szLine.SubString( 0, iSplit );
		string szValue = szLine.SubString( iSplit + 1, szLine.Length() - iSplit - 1 );

		if( szKey == "chapters" )
		{
			array<string>@ keys = szValue.Split( "," );
			for( uint i = 0; i < keys.length(); ++i )
			{
				string szChapter = APTrim( keys[i] );
				if( szChapter.Length() > 0 )
					chapters[ szChapter ] = true;
			}
		}
		else if( szKey == "goals_open" )
		{
			// One entry per campaign whose finale is unsealed. `goal_open` below
			// is the same thing collapsed to a bool for an older plugin.
			array<string>@ keys = szValue.Split( "," );
			for( uint i = 0; i < keys.length(); ++i )
			{
				string szChapter = APTrim( keys[i] );
				if( szChapter.Length() > 0 )
					goalsOpen[ szChapter ] = true;
			}
		}
		else if( szKey == "excluded" )
		{
			array<string>@ keys = szValue.Split( "," );
			for( uint i = 0; i < keys.length(); ++i )
			{
				string szChapter = APTrim( keys[i] );
				if( szChapter.Length() > 0 )
					excluded[ szChapter ] = true;
			}
		}
		else if( szKey == "items" )
		{
			// Item names contain commas ("Weapon, Mk II" style is possible), so
			// this list is semicolon separated.
			array<string>@ names = szValue.Split( ";" );
			for( uint i = 0; i < names.length(); ++i )
			{
				string szItem = APTrim( names[i] );
				if( szItem.Length() > 0 )
					items[ szItem ] = true;
			}
		}
		else if( szKey == "ungated" )
		{
			// Classnames, so semicolon separated for the same reason `items` is.
			array<string>@ names = szValue.Split( ";" );
			for( uint i = 0; i < names.length(); ++i )
			{
				string szClassname = APTrim( names[i] );
				if( szClassname.Length() > 0 )
					ungated[ szClassname ] = true;
			}
		}
		else if( szKey == "checked" || szKey == "missing" )
		{
			// Location ids, comma separated. Kept as strings: they are only ever
			// looked up by the tracker, never compared as numbers.
			array<string>@ ids = szValue.Split( "," );
			for( uint i = 0; i < ids.length(); ++i )
			{
				string szId = APTrim( ids[i] );
				if( szId.Length() == 0 )
					continue;
				if( szKey == "checked" )
					checked[ szId ] = true;
				else
					missing[ szId ] = true;
			}
		}
		else if( szKey == "starting" )
		{
			array<string>@ names = szValue.Split( ";" );
			for( uint i = 0; i < names.length(); ++i )
			{
				string szClassname = APTrim( names[i] );
				if( szClassname.Length() > 0 )
					starting.insertLast( szClassname );
			}
		}
		else if( szKey == "now" )
			g_flSnapshotNow = atof( szValue );
		else if( szKey == "session" )
			szSession = szValue;
		else if( szKey == "slot" )
		{
			szSlot = szValue;
			bHasSlot = true;
		}
		else if( szKey == "data_version" )
			CheckDataVersion( szValue );
		else if( szKey == "goal_open" )
			bGoalOpen = szValue == "1";
		else if( szKey == "connected" )
			bConnected = szValue == "1";
		else if( szKey == "death_link" )
			bDeathLink = szValue == "1";
		else if( szKey == "death_link_amnesty" )
			iAmnesty = atoi( szValue );
		// Absent from an older client, where the default below stands and means
		// what it has always meant: the lobby goes with you.
		else if( szKey == "lobby_death_link" )
			szLobbyDeath = szValue;
		else if( szKey == "event" )
			events.insertLast( szValue );
		// The arcade map. Absent from a seed that has none, and from a client too
		// old to know about it, in which case every one of these keeps its
		// default and Suspension behaves as an ordinary unmanaged map.
		else if( szKey == "sus_on" )
			g_Suspension.enabled = szValue == "1";
		else if( szKey == "sus_classanity" )
			g_Suspension.classanity = szValue == "1";
		else if( szKey == "sus_rolldown" )
			g_Suspension.rolldown = szValue == "1";
		else if( szKey == "sus_open" )
			g_Suspension.tiersOpen = atoi( szValue );
		else if( szKey == "sus_tiers" )
			g_Suspension.tiers = SplitNonEmpty( szValue, "," );
		else if( szKey == "sus_awards" )
			g_Suspension.awards = SplitNonEmpty( szValue, "," );
		else if( szKey == "sus_classes" )
			g_Suspension.SetHeldClasses( SplitNonEmpty( szValue, "," ) );
	}

	// A restarted client numbers its events from 1 again. Without this, every
	// new event would look like one we had already applied and be ACKed away.
	// That is all the session id is good for.
	bool bNewSession = szSession != g_szSession && g_szSession.Length() > 0;
	if( szSession != g_szSession )
	{
		g_szSession = szSession;
		g_State.lastEventSeq = 0;
	}

	// A player who connects a different slot is playing a different seed, and
	// everything the plugin remembers about the last one -- which checks it has
	// already sent, which mission it thinks is being played -- is now wrong.
	// Reconnecting has to be a safe thing to do, so the whole run state goes and
	// the lobby goes back to the hub.
	//
	// The session id used to stand in for this and was wrong both ways round: it
	// changes when the same slot reconnects from a restarted client, which is a
	// blip and should move nobody, and it does *not* change when a different
	// slot is connected from the client already running, which is the case that
	// matters. An empty slot is a disconnected client rather than a new run, so
	// the last one we were told about stands.
	if( bHasSlot )
	{
		if( szSlot.Length() > 0 && szSlot != g_szSlot )
		{
			bool bWasSlot = g_szSlot.Length() > 0;
			g_szSlot = szSlot;
			if( bWasSlot )
			{
				APLog( "client slot changed; resetting run state" );
				ResetRunState();
			}
		}
	}
	// No slot field at all: an older client, where the session is the only
	// signal there is.
	else if( bNewSession )
	{
		APLog( "client session changed; resetting run state" );
		ResetRunState();
	}

	bool bWasConnected = g_State.connected;

	g_State.unlockedChapters = chapters;
	g_State.excludedChapters = excluded;
	g_State.unlockedItems = items;
	g_UngatedClassnames = ungated;

	// An empty list means the client has nothing to say about it, not that the
	// player should be left with no melee weapon at all, so the data file's own
	// `S` records stand.
	if( starting.length() > 0 )
		g_StartingWeapons = starting;
	else
		g_StartingWeapons = g_DefaultStartingWeapons;

	g_CheckedLocations = checked;
	g_MissingLocations = missing;

	g_State.goalsOpen = goalsOpen;
	g_State.goalOpen = bGoalOpen;
	g_State.connected = bConnected;
	g_State.deathLink = bDeathLink;
	g_State.deathLinkAmnesty = iAmnesty;
	g_State.lobbyDeathLink = szLobbyDeath;

	// An item arriving opens a Suspension tier or class, and the locks are
	// entity state rather than a question asked at press time -- so they have to
	// be brought back in line here, not on the next map load.
	SuspensionSyncLocks();

	if( bConnected && !bWasConnected )
		g_PlayerFuncs.ClientPrintAll( HUD_PRINTTALK,
			"[AP] Connected to the multiworld. Type !help for commands.\n" );
	else if( !bConnected && bWasConnected )
		g_PlayerFuncs.ClientPrintAll( HUD_PRINTTALK, "[AP] Lost the multiworld connection.\n" );

	// The one item whose arrival is otherwise invisible: the suit is never taken
	// away, so nothing on screen changes except that armour starts working.
	int iSuitNow = ClassnameAllowed( SUIT_CLASSNAME ) ? 1 : 0;
	if( iSuitNow == 1 && g_iSuitOwned == 0 )
		g_PlayerFuncs.ClientPrintAll( HUD_PRINTTALK,
			"[AP] HEV suit power restored. Armour works from here on.\n" );
	g_iSuitOwned = iSuitNow;

	// Applying the snapshot may have unlocked a weapon, so refresh loadouts
	// before handling events (an incoming DeathLink should not race a grant).
	ApplyLoadoutToAll();

	for( uint i = 0; i < events.length(); ++i )
		HandleEvent( events[i] );
}

/*
* One `event=` payload: <seq>|<kind>|<data>|<unixtime>
*
* Anything at or below lastEventSeq has already been applied in this session.
* We still ACK it, because the client only drops a line once we say we have it.
*/
void HandleEvent( const string& in szPayload )
{
	array<string>@ parts = szPayload.Split( "|" );
	if( parts.length() < 4 )
		return;

	int iSeq = atoi( parts[0] );
	string szKind = parts[1];
	string szData = parts[2];
	float flStamp = atof( parts[3] );

	if( iSeq <= g_State.lastEventSeq )
	{
		SendAck( iSeq );
		return;
	}
	g_State.lastEventSeq = iSeq;

	if( szKind == "DEATHLINK" )
		ApplyIncomingDeathLink( szData, flStamp );
	else if( szKind == "ITEM" )
		GrantFillerItem( szData );
	else if( szKind == "TRAP" )
		SpringTrap( szData );
	else if( szKind == "CHAT" )
		g_PlayerFuncs.ClientPrintAll( HUD_PRINTTALK, szData + "\n" );

	SendAck( iSeq );
}

/*
* Announce ourselves. The client uses HELLO to learn which map we are on and to
* re-send the snapshot, which is how a client started after the game catches up.
*/
void BridgeHello()
{
	BridgeSend( "HELLO|" + g_szCurrentMap );
}
