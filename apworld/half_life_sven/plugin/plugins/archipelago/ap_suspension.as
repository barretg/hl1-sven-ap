/*
* Suspension: the arcade map.
*
* Not a mission. One map, eight sections, eight classes, a difficulty the lobby
* votes for and a medal scored on the team's total deaths. Everything the plugin
* has to do here is a different shape from the campaigns, so it lives apart from
* them and nothing in ap_hub touches it.
*
* How progress is observed
* ------------------------
* The map announces every step of its own progress by firing entities by name:
* `s3_events` when section 2 falls, `win_red_tickets` when the lobby votes Easy,
* `end_script` when the round is scored. None of that is hookable from a plugin
* -- a multi_manager fires targets, it does not call script functions, and
* `trigger_script` resolves its function against the *map's* script rather than
* ours.
*
* So we piggyback on the names instead. At map start we create our own
* `trigger_changevalue` entities sharing those names, each pointing at a counter
* `info_target` of ours. The map's own multi_managers then advance our counters
* for us, and the think loop reads them. That is exact and event-driven where
* watching player positions would have been neither: sections 7 and 8 occupy the
* same stretch of bridge and cannot be told apart by position at all.
*
* What the plugin decides, and what it does not
* --------------------------------------------
* The client owns the seed. Which tiers are open, which classes are held and
* which medals are checks all arrive in the snapshot; this module only reads
* them. What it decides for itself is what happened in the round: which section
* fell, who was playing what when it did, and how many times the team died.
*/

// --- Checkdata records ----------------------------------------------------

class APArcade
{
	string key;
	string name;
	string map;
	string goalClass;
	string startSignal;
	string endSignal;
}

class APTier
{
	string key;
	string name;
	int tickets = 0;
	string voteButton;
	string ticketSignal;
}

class APSection
{
	string key;
	string name;
	int index = 0;
	// Fired by the map when this section has been cleared. Empty on the last
	// one, which is cleared by the round ending.
	string signal;
}

class APClass
{
	string key;
	string name;
	// What the map sets the player's own targetname to.
	string targetname;
	string signal;
	// The teleport destination this class's lobby portal sends a player to.
	// Locking a class means finding that portal and making it non-solid.
	string portal;
	bool mapGated = false;

	// Only the map-gated class carries these: what to do to a player to grant it
	// without the booth, for the tiers where the booth does nothing.
	int health = 0;
	int maxHealth = 0;
	int armourValue = 0;
	int armourType = 0;
	string model;
	array<string> weapons;
	array<string> ammoNames;
	array<int> ammoCounts;
	bool hasTeleport = false;
	Vector teleport;
}

class APAward
{
	string key;
	string name;
	// Most team deaths a run may have and still earn this.
	int deaths = 0;
}

class APBox
{
	Vector mins;
	Vector maxs;

	bool Contains( const Vector& in vecPoint, float flPad ) const
	{
		return vecPoint.x >= mins.x - flPad && vecPoint.x <= maxs.x + flPad
		    && vecPoint.y >= mins.y - flPad && vecPoint.y <= maxs.y + flPad
		    && vecPoint.z >= mins.z - flPad && vecPoint.z <= maxs.z + flPad;
	}
}

APArcade@ g_pArcade = null;
array<APTier@> g_SusTiers;
array<APSection@> g_SusSections;
array<APClass@> g_SusClasses;
array<APAward@> g_SusAwards;
dictionary g_SusVolumes;       // name -> APBox@
dictionary g_SusSeal;          // part -> "targetname|classname"

// --- Snapshot state -------------------------------------------------------

class APSuspensionState
{
	// Everything here is off until a snapshot says otherwise, so a seed without
	// the map -- or a client too old to mention it -- leaves Suspension alone.
	bool enabled = false;
	bool classanity = false;
	bool rolldown = false;
	// How many Progressive Suspension Difficulty items have arrived, which is the
	// index of the hardest tier that may be voted for.
	int tiersOpen = 0;
	array<string> tiers;
	array<string> awards;
	dictionary heldClasses;

	void SetHeldClasses( const array<string>& in keys )
	{
		heldClasses.deleteAll();
		for( uint i = 0; i < keys.length(); ++i )
			heldClasses[ keys[i] ] = true;
	}

	bool HoldsClass( const string& in szKey ) const
	{
		return heldClasses.exists( szKey );
	}

	// Position of a tier in this seed's ladder, or -1 if the seed excludes it.
	int TierIndex( const string& in szKey ) const
	{
		for( uint i = 0; i < tiers.length(); ++i )
			if( tiers[i] == szKey )
				return int(i);
		return -1;
	}

	bool TierOpen( const string& in szKey ) const
	{
		int iIndex = TierIndex( szKey );
		return iIndex >= 0 && iIndex <= tiersOpen;
	}

	bool AwardWanted( const string& in szKey ) const
	{
		for( uint i = 0; i < awards.length(); ++i )
			if( awards[i] == szKey )
				return true;
		return false;
	}
}

APSuspensionState g_Suspension;

// --- Per-round state ------------------------------------------------------
//
// Rebuilt from nothing at the start of every round. Nothing here outlives a map
// change, which is the same rule the rest of the plugin follows.

bool g_bSusRoundActive = false;
// Tier the lobby voted for, empty until it has.
string g_szSusTier = "";
// Highest section index cleared so far, 0 before the first falls.
int g_iSusCleared = 0;
// Team deaths this round, which is what the medal is scored on.
int g_iSusDeaths = 0;
// Sections each player spent on each class, keyed "<userid>|<class>". The
// majority of these is what a player's clear is credited to.
dictionary g_SusClassSections;
// The one player holding the map-gated class, keyed by userid. Empty when free.
string g_szSusJuggerHolder = "";

// Our counter entities, which the map's own multi_managers drive.
const string SUS_COUNTER_SECTION = "ap_sus_section";
const string SUS_COUNTER_TIER = "ap_sus_tier";
const string SUS_COUNTER_START = "ap_sus_start";
const string SUS_COUNTER_END = "ap_sus_end";

// Trigger kinds, matching tools/build_campaign_data.py.
const string TRIGGER_SUS_SECTION = "suspension_section";
const string TRIGGER_SUS_CLEAR = "suspension_clear";
const string TRIGGER_SUS_AWARD = "suspension_award";

// The portal is a four-unit slab, so a player walking it is tested with a
// generous pad rather than a point-in-box.
const float SUS_PORTAL_PAD = 20.0f;
const float SUS_THINK_INTERVAL = 0.25f;

CScheduledFunction@ g_pSusTimer = null;

// --- Helpers --------------------------------------------------------------

array<string> SplitNonEmpty( const string& in szValue, const string& in szSeparator )
{
	array<string> result;
	array<string>@ parts = szValue.Split( szSeparator );
	for( uint i = 0; i < parts.length(); ++i )
	{
		string szPart = APTrim( parts[i] );
		if( szPart.Length() > 0 )
			result.insertLast( szPart );
	}
	return result;
}

Vector APVectorFromString( const string& in szValue )
{
	array<string> parts = SplitNonEmpty( szValue, " " );
	if( parts.length() < 3 )
		return Vector( 0, 0, 0 );
	return Vector( atof( parts[0] ), atof( parts[1] ), atof( parts[2] ) );
}

/*
* One `E` record: a field of a class's grant table.
*
* Only the map-gated class has any, and only because its booth does nothing on
* the tiers below the map's own, leaving the plugin to do the booth's job.
*/
void ApplyGrantRecord( const string& in szClass, const string& in szField, const string& in szValue )
{
	APClass@ pClass = SuspensionClassByKey( szClass );
	if( pClass is null )
		return;

	if( szField == "health" )
		pClass.health = atoi( szValue );
	else if( szField == "max_health" )
		pClass.maxHealth = atoi( szValue );
	else if( szField == "armorvalue" )
		pClass.armourValue = atoi( szValue );
	else if( szField == "armortype" )
		pClass.armourType = atoi( szValue );
	else if( szField == "model" )
		pClass.model = szValue;
	else if( szField == "weapons" )
		pClass.weapons = SplitNonEmpty( szValue, "," );
	else if( szField == "ammo" )
	{
		array<string> pairs = SplitNonEmpty( szValue, "," );
		for( uint i = 0; i < pairs.length(); ++i )
		{
			array<string>@ pair = pairs[i].Split( ":" );
			if( pair.length() < 2 )
				continue;
			pClass.ammoNames.insertLast( pair[0] );
			pClass.ammoCounts.insertLast( atoi( pair[1] ) );
		}
	}
	else if( szField == "teleport" )
	{
		pClass.teleport = APVectorFromString( szValue );
		pClass.hasTeleport = true;
	}
}

bool SuspensionMap()
{
	return g_pArcade !is null && g_szCurrentMap == g_pArcade.map;
}

bool SuspensionManaged()
{
	return SuspensionMap() && g_Suspension.enabled;
}

APClass@ SuspensionClassByTargetname( const string& in szTargetname )
{
	if( szTargetname.Length() == 0 )
		return null;
	for( uint i = 0; i < g_SusClasses.length(); ++i )
		if( g_SusClasses[i].targetname == szTargetname )
			return g_SusClasses[i];
	return null;
}

APClass@ SuspensionClassByKey( const string& in szKey )
{
	for( uint i = 0; i < g_SusClasses.length(); ++i )
		if( g_SusClasses[i].key == szKey )
			return g_SusClasses[i];
	return null;
}

APTier@ SuspensionTierByKey( const string& in szKey )
{
	for( uint i = 0; i < g_SusTiers.length(); ++i )
		if( g_SusTiers[i].key == szKey )
			return g_SusTiers[i];
	return null;
}

// The class a player is holding right now, read from their own targetname. The
// map sets it at the booth and it is single-valued, which the map's own
// class_counter entities are not.
APClass@ SuspensionClassOf( CBasePlayer@ pPlayer )
{
	if( pPlayer is null || !pPlayer.IsConnected() )
		return null;
	return SuspensionClassByTargetname( string( pPlayer.pev.targetname ) );
}

string SuspensionPlayerKey( CBasePlayer@ pPlayer )
{
	return "" + g_EngineFuncs.GetPlayerUserId( pPlayer.edict() );
}

int SuspensionCounter( const string& in szName )
{
	CBaseEntity@ pEntity = g_EntityFuncs.FindEntityByTargetname( null, szName );
	if( pEntity is null )
		return 0;
	return int( pEntity.pev.frags );
}

// --- Setting up the map ---------------------------------------------------

/*
* Create one counter and the trigger_changevalue entities that drive it.
*
* Every signal is a name the map already fires. Ours simply answers to the same
* name, so the map advances our counter as a side effect of doing what it was
* always going to do. Nothing about the map is modified.
*/
void SuspensionCreateCounter( const string& in szCounter )
{
	dictionary keys;
	keys[ "targetname" ] = szCounter;
	g_EntityFuncs.CreateEntity( "info_target", keys, true );
}

void SuspensionCreateSignal( const string& in szSignal, const string& in szCounter, int iValue )
{
	if( szSignal.Length() == 0 )
		return;

	dictionary keys;
	keys[ "targetname" ] = szSignal;
	keys[ "target" ] = szCounter;
	keys[ "m_iszValueName" ] = "frags";
	keys[ "m_iszNewValue" ] = "" + iValue;
	// 0 is "set to", not "add": sections arrive in order and the counter should
	// hold where we are rather than a running total.
	keys[ "m_iszValueType" ] = "0";
	g_EntityFuncs.CreateEntity( "trigger_changevalue", keys, true );
}

/*
* Forget the round in progress. Every one of these is per round and none of it
* means anything once the map reloads or the slot changes.
*/
void SuspensionResetRound()
{
	g_bSusRoundActive = false;
	g_szSusTier = "";
	g_iSusCleared = 0;
	g_iSusDeaths = 0;
	g_SusClassSections.deleteAll();
	g_szSusJuggerHolder = "";
}

void SuspensionMapStart()
{
	SuspensionResetRound();

	if( !SuspensionManaged() )
		return;

	SuspensionCreateCounter( SUS_COUNTER_SECTION );
	SuspensionCreateCounter( SUS_COUNTER_TIER );
	SuspensionCreateCounter( SUS_COUNTER_START );
	SuspensionCreateCounter( SUS_COUNTER_END );

	// A section's signal fires when *it* has been cleared, so the counter holds
	// the number of sections down.
	for( uint i = 0; i < g_SusSections.length(); ++i )
		SuspensionCreateSignal(
			g_SusSections[i].signal, SUS_COUNTER_SECTION, g_SusSections[i].index );

	for( uint i = 0; i < g_SusTiers.length(); ++i )
		SuspensionCreateSignal(
			g_SusTiers[i].ticketSignal, SUS_COUNTER_TIER, int(i) + 1 );

	SuspensionCreateSignal( g_pArcade.startSignal, SUS_COUNTER_START, 1 );
	SuspensionCreateSignal( g_pArcade.endSignal, SUS_COUNTER_END, 1 );

	SuspensionSyncLocks();
	SuspensionEnsureScheduled();
	SuspensionAnnounce();

	APLog( "suspension: managing " + g_pArcade.map + ", "
	     + g_Suspension.tiers.length() + " tiers, "
	     + ( g_Suspension.classanity ? "classanity" : "shared sections" ) );
}

void SuspensionEnsureScheduled()
{
	if( g_pSusTimer !is null )
	{
		g_Scheduler.RemoveTimer( g_pSusTimer );
		@g_pSusTimer = null;
	}

	@g_pSusTimer = g_Scheduler.SetInterval(
		"SuspensionThink", SUS_THINK_INTERVAL, g_Scheduler.REPEAT_INFINITE_TIMES );
}

// --- Locking what the seed has not opened ---------------------------------
//
// Everything here works by making an entity non-solid rather than by refusing
// the press afterwards. Refusing at PlayerUse was not enough: the message
// printed and the vote went through anyway, because the button had already been
// used by the time our trace agreed it was the thing being looked at.
//
// A non-solid brush cannot be traced against, touched or used, so a locked tier
// or class is simply not there. Both are restored the moment the item arrives,
// which is why nothing is ever removed.

void SuspensionSetSolid( CBaseEntity@ pEntity, bool bSolid, int iSolidType )
{
	if( pEntity is null )
		return;
	pEntity.pev.solid = bSolid ? iSolidType : SOLID_NOT;
	if( bSolid )
		pEntity.pev.effects &= ~EF_NODRAW;
	else
		pEntity.pev.effects |= EF_NODRAW;
}

/*
* The teleport a class's lobby portal uses, found by where it sends people.
*
* By destination rather than by targetname because the portals have none: the
* map identifies them only by the `pick_<class>` they point at, and those are
* spelled inconsistently enough (`pick_engi`, `pick_GLsoldier`) that they are
* carried in the data rather than derived.
*/
CBaseEntity@ SuspensionPortalOf( APClass@ pClass )
{
	if( pClass is null || pClass.portal.Length() == 0 )
		return null;

	CBaseEntity@ pEntity = null;
	while( ( @pEntity = g_EntityFuncs.FindEntityByClassname(
		pEntity, "trigger_teleport" ) ) !is null )
	{
		if( string( pEntity.pev.target ) == pClass.portal )
			return pEntity;
	}
	return null;
}

/*
* Bring every lock in line with what the client says the seed has opened.
*
* Called on map start and whenever a snapshot changes something, so an item
* arriving mid-round opens its booth without waiting for a map load.
*/
void SuspensionSyncLocks()
{
	if( !SuspensionManaged() )
		return;

	for( uint i = 0; i < g_SusTiers.length(); ++i )
	{
		APTier@ pTier = g_SusTiers[i];
		CBaseEntity@ pButton = g_EntityFuncs.FindEntityByTargetname( null, pTier.voteButton );
		// func_button is a brush entity, so SOLID_BSP is what it goes back to.
		SuspensionSetSolid( pButton, g_Suspension.TierOpen( pTier.key ), SOLID_BSP );
	}

	for( uint i = 0; i < g_SusClasses.length(); ++i )
	{
		APClass@ pClass = g_SusClasses[i];
		bool bOpen = g_Suspension.HoldsClass( pClass.key );
		// The map-gated class has a seal of its own on top of the portal, and
		// only one player may hold it at a time.
		if( pClass.mapGated )
		{
			bOpen = bOpen && g_szSusJuggerHolder.Length() == 0;
			SuspensionSealJuggernaut( !bOpen );
		}
		SuspensionSetSolid( SuspensionPortalOf( pClass ), bOpen, SOLID_TRIGGER );
	}
}

/*
* Say what is open, since a locked booth is now simply absent and a player
* standing in front of a gap deserves to be told why.
*/
void SuspensionAnnounce()
{
	if( !SuspensionManaged() )
		return;

	string szTiers;
	for( uint i = 0; i < g_Suspension.tiers.length(); ++i )
	{
		if( !g_Suspension.TierOpen( g_Suspension.tiers[i] ) )
			continue;
		APTier@ pTier = SuspensionTierByKey( g_Suspension.tiers[i] );
		if( pTier is null )
			continue;
		szTiers += ( szTiers.Length() > 0 ? ", " : "" ) + pTier.name;
	}

	string szClasses;
	for( uint i = 0; i < g_SusClasses.length(); ++i )
	{
		if( !g_Suspension.HoldsClass( g_SusClasses[i].key ) )
			continue;
		szClasses += ( szClasses.Length() > 0 ? ", " : "" ) + g_SusClasses[i].name;
	}

	g_PlayerFuncs.ClientPrintAll( HUD_PRINTTALK,
		"[AP] Suspension difficulties: " + ( szTiers.Length() > 0 ? szTiers : "none" ) + "\n" );
	g_PlayerFuncs.ClientPrintAll( HUD_PRINTTALK,
		"[AP] Suspension classes: " + ( szClasses.Length() > 0 ? szClasses : "none" ) + "\n" );
}

// --- The Juggernaut -------------------------------------------------------

/*
* Is the map-gated class open to this lobby?
*
* Its item has to have arrived, which in logic stands behind every other class.
* The in-game rule is stricter and lives with the client: it is handed out once
* a run has been cleared with each of the other seven at this tier.
*/
bool SuspensionJuggernautAllowed()
{
	if( g_pArcade is null )
		return false;
	return g_Suspension.enabled && g_Suspension.HoldsClass( g_pArcade.goalClass );
}

/*
* Open or shut the portal the map keeps the Juggernaut behind.
*
* Two entities share the class's name -- a `func_wall_toggle` across the portal
* and a lethal `trigger_hurt` behind it -- so they are found by name *and*
* classname. Sealing is the one thing here that touches the map's own entities,
* and it is reversible: nothing is created or removed.
*/
void SuspensionSealJuggernaut( bool bSealed )
{
	SuspensionSetSealPart( "wall", bSealed );
	SuspensionSetSealPart( "hurt", bSealed );

	if( !bSealed )
	{
		// Reveal the icon, which the map only does on its hardest tier.
		string szReveal;
		if( g_SusSeal.get( "reveal", szReveal ) && szReveal.Length() > 0 )
		{
			array<string>@ parts = szReveal.Split( "|" );
			g_EntityFuncs.FireTargets( parts[0], null, null, USE_ON );
		}
	}
}

void SuspensionSetSealPart( const string& in szPart, bool bSealed )
{
	string szSpec;
	if( !g_SusSeal.get( szPart, szSpec ) )
		return;

	array<string>@ parts = szSpec.Split( "|" );
	if( parts.length() < 2 || parts[0].Length() == 0 )
		return;

	CBaseEntity@ pEntity = null;
	while( ( @pEntity = g_EntityFuncs.FindEntityByTargetname( pEntity, parts[0] ) ) !is null )
	{
		if( pEntity.GetClassname() != parts[1] )
			continue;
		pEntity.pev.solid = bSealed ? SOLID_BSP : SOLID_NOT;
		if( bSealed )
			pEntity.pev.effects &= ~EF_NODRAW;
		else
			pEntity.pev.effects |= EF_NODRAW;
	}
}

/*
* Hand the class over ourselves.
*
* The booth does nothing on the tiers below the map's own, so the plugin does
* what the booth would: the targetname the restock stations filter on, the
* stats, the model and the loadout, and the teleport onto the pad the portal
* would have sent them to.
*/
void SuspensionGrantJuggernaut( CBasePlayer@ pPlayer )
{
	APClass@ pClass = SuspensionClassByKey( g_pArcade.goalClass );
	if( pClass is null || pPlayer is null || !pPlayer.IsAlive() )
		return;

	// One at a time, exactly as the map's own seal enforces.
	string szHolder = SuspensionPlayerKey( pPlayer );
	if( g_szSusJuggerHolder.Length() > 0 && g_szSusJuggerHolder != szHolder )
	{
		g_PlayerFuncs.SayText( pPlayer, "[AP] Someone already has the Juggernaut.\n" );
		return;
	}

	// The targetname first and above all: the restock stations along the bridge
	// filter on `target=class_<key>`, so without it a granted Juggernaut would
	// walk the whole map unable to resupply.
	pPlayer.pev.targetname = pClass.targetname;

	if( pClass.maxHealth > 0 )
		pPlayer.pev.max_health = pClass.maxHealth;
	if( pClass.health > 0 )
		pPlayer.pev.health = pClass.health;
	if( pClass.armourValue > 0 )
		pPlayer.pev.armorvalue = pClass.armourValue;
	if( pClass.armourType > 0 )
		pPlayer.pev.armortype = pClass.armourType;
	if( pClass.model.Length() > 0 )
		g_EntityFuncs.SetModel( pPlayer, pClass.model );

	for( uint i = 0; i < pClass.weapons.length(); ++i )
		pPlayer.GiveNamedItem( pClass.weapons[i] );

	// Ammo entities are given one at a time rather than as a count, which is the
	// same thing the map's game_player_equip does and avoids guessing at an
	// ammo-specific signature.
	for( uint i = 0; i < pClass.ammoNames.length(); ++i )
		for( int iGiven = 0; iGiven < pClass.ammoCounts[i]; ++iGiven )
			pPlayer.GiveNamedItem( pClass.ammoNames[i] );

	if( pClass.hasTeleport )
		g_EntityFuncs.SetOrigin( pPlayer, pClass.teleport );

	g_szSusJuggerHolder = szHolder;
	// Shuts the portal behind them, which is what the map does itself on its own
	// tier: one Juggernaut per round.
	SuspensionSyncLocks();
	g_PlayerFuncs.ClientPrintAll( HUD_PRINTTALK,
		"[AP] " + pPlayer.pev.netname + " took the Juggernaut.\n" );
}

/*
* Watch the portal and the pad, because a booth that does nothing fires nothing.
*
* Whichever a player reaches first grants the class; the grant is idempotent, so
* being caught by both is harmless.
*/
void SuspensionWatchJuggernaut()
{
	if( !SuspensionJuggernautAllowed() || g_szSusJuggerHolder.Length() > 0 )
		return;

	array<string>@ names = g_SusVolumes.getKeys();

	for( int i = 1; i <= g_Engine.maxClients; ++i )
	{
		CBasePlayer@ pPlayer = g_PlayerFuncs.FindPlayerByIndex( i );
		if( pPlayer is null || !pPlayer.IsConnected() || !pPlayer.IsAlive() )
			continue;
		if( pPlayer.GetObserver().IsObserver() )
			continue;

		// Already holding it, so there is nothing to grant.
		APClass@ pHeld = SuspensionClassOf( pPlayer );
		if( pHeld !is null && pHeld.key == g_pArcade.goalClass )
			continue;

		for( uint j = 0; j < names.length(); ++j )
		{
			// `get` rather than indexing: indexing a dictionary yields a
			// dictionaryValue, which is not something a handle cast can take.
			APBox@ pBox = null;
			if( !g_SusVolumes.get( names[j], @pBox ) || pBox is null )
				continue;
			if( pBox.Contains( pPlayer.pev.origin, SUS_PORTAL_PAD ) )
			{
				SuspensionGrantJuggernaut( pPlayer );
				return;
			}
		}
	}
}

// --- Sending checks -------------------------------------------------------

/*
* Every tier at or below this one, when rolldown is on; otherwise just this one.
*
* Medals ignore the setting and always roll down -- nobody should have to throw
* a run to collect the bad ones -- so they call this with bAlways.
*/
array<string> SuspensionTiersFor( const string& in szTier, bool bAlways )
{
	array<string> result;
	int iPlayed = g_Suspension.TierIndex( szTier );
	if( iPlayed < 0 )
		return result;

	if( !g_Suspension.rolldown && !bAlways )
	{
		result.insertLast( szTier );
		return result;
	}

	for( int i = 0; i <= iPlayed; ++i )
		result.insertLast( g_Suspension.tiers[i] );
	return result;
}

/*
* Find the location matching one of this map's triggers and send it.
*
* Locations are matched on the `arg` field checkdata.txt carries, which spells
* out the section, class, medal and tier. Anything the seed left out simply has
* no location and is silently skipped, which is how classanity and the medal
* ladder switch whole sets of checks off.
*/
void SuspensionSend( const string& in szKind, const string& in szArg )
{
	for( uint i = 0; i < g_Locations.length(); ++i )
	{
		APLocation@ pLocation = g_Locations[i];
		if( pLocation.kind != szKind || pLocation.arg != szArg )
			continue;
		SendCheck( pLocation );
		return;
	}
}

void SuspensionSendSection( int iSection, const string& in szClass, const string& in szTier )
{
	APSection@ pSection = null;
	for( uint i = 0; i < g_SusSections.length(); ++i )
		if( g_SusSections[i].index == iSection )
			@pSection = g_SusSections[i];
	if( pSection is null )
		return;

	array<string> tiers = SuspensionTiersFor( szTier, false );
	for( uint i = 0; i < tiers.length(); ++i )
		SuspensionSend( TRIGGER_SUS_SECTION,
			pSection.key + ":" + szClass + ":" + tiers[i] );
}

void SuspensionSendClear( const string& in szClass, const string& in szTier )
{
	array<string> tiers = SuspensionTiersFor( szTier, false );
	for( uint i = 0; i < tiers.length(); ++i )
		SuspensionSend( TRIGGER_SUS_CLEAR, szClass + ":" + tiers[i] );
}

void SuspensionSendAward( const string& in szAward, const string& in szTier )
{
	array<string> tiers = SuspensionTiersFor( szTier, true );
	for( uint i = 0; i < tiers.length(); ++i )
		SuspensionSend( TRIGGER_SUS_AWARD, szAward + ":" + tiers[i] );
}

// --- The round ------------------------------------------------------------

void SuspensionBeginRound()
{
	g_bSusRoundActive = true;
	g_iSusCleared = 0;
	g_iSusDeaths = 0;
	g_SusClassSections.deleteAll();

	g_PlayerFuncs.ClientPrintAll( HUD_PRINTTALK,
		"[AP] Suspension: " + g_szSusTier + " underway.\n" );
}

/*
* A section fell. Credit every class in play at this instant.
*
* Dead or alive: deaths are constant here by design, and crediting only the
* survivors would make the check a matter of luck. Credit is per section rather
* than per run, so a player who switches class between sections earns each one
* for whatever they were holding at the time and nothing retroactively.
*/
void SuspensionCreditSection( int iSection )
{
	if( g_szSusTier.Length() == 0 )
		return;

	if( !g_Suspension.classanity )
		SuspensionSendSection( iSection, "", g_szSusTier );

	for( int i = 1; i <= g_Engine.maxClients; ++i )
	{
		CBasePlayer@ pPlayer = g_PlayerFuncs.FindPlayerByIndex( i );
		if( pPlayer is null || !pPlayer.IsConnected() )
			continue;

		APClass@ pClass = SuspensionClassOf( pPlayer );
		if( pClass is null )
			continue;

		if( g_Suspension.classanity )
			SuspensionSendSection( iSection, pClass.key, g_szSusTier );

		// Tallied whether or not classanity is on: the clear is credited to
		// whichever class a player spent most of the run as, and that question is
		// the same either way.
		string szKey = SuspensionPlayerKey( pPlayer ) + "|" + pClass.key;
		int iCount = 0;
		g_SusClassSections.get( szKey, iCount );
		g_SusClassSections[ szKey ] = iCount + 1;
	}
}

/*
* The class a player is credited with clearing the run as.
*
* The majority of the sections they were present for. A dead-even split is
* broken by what they finished as, which is both deterministic and the answer a
* player would give.
*/
string SuspensionMajorityClass( CBasePlayer@ pPlayer )
{
	string szPrefix = SuspensionPlayerKey( pPlayer ) + "|";
	array<string>@ keys = g_SusClassSections.getKeys();

	string szBest = "";
	int iBest = 0;
	for( uint i = 0; i < keys.length(); ++i )
	{
		if( keys[i].SubString( 0, szPrefix.Length() ) != szPrefix )
			continue;
		int iCount = 0;
		g_SusClassSections.get( keys[i], iCount );
		if( iCount > iBest )
		{
			iBest = iCount;
			szBest = keys[i].SubString( szPrefix.Length(),
				keys[i].Length() - szPrefix.Length() );
		}
		else if( iCount == iBest && iBest > 0 )
		{
			// Tied: whatever they are holding now wins, which is what they
			// finished as.
			APClass@ pHeld = SuspensionClassOf( pPlayer );
			if( pHeld !is null )
				szBest = pHeld.key;
		}
	}

	if( szBest.Length() == 0 )
	{
		APClass@ pHeld = SuspensionClassOf( pPlayer );
		if( pHeld !is null )
			szBest = pHeld.key;
	}
	return szBest;
}

/*
* The medal a run earned, scored the way CustomHUD.as scores it: the team's
* total deaths against a ladder of thresholds, easiest last.
*/
string SuspensionAwardFor( int iDeaths )
{
	for( uint i = 0; i < g_SusAwards.length(); ++i )
		if( iDeaths <= g_SusAwards[i].deaths )
			return g_SusAwards[i].key;
	// Past the end of the ladder is the bottom rung, not nothing.
	return g_SusAwards.length() > 0 ? g_SusAwards[ g_SusAwards.length() - 1 ].key : "";
}

void SuspensionEndRound()
{
	if( !g_bSusRoundActive )
		return;
	g_bSusRoundActive = false;

	// The last section has no signal of its own: reaching the end of the round
	// is what clears it.
	if( g_SusSections.length() > 0 )
		SuspensionCreditSection( g_SusSections[ g_SusSections.length() - 1 ].index );

	string szAward = SuspensionAwardFor( g_iSusDeaths );
	if( szAward.Length() > 0 && g_Suspension.AwardWanted( szAward ) )
		SuspensionSendAward( szAward, g_szSusTier );

	// A run was finished at this tier, whoever played what.
	SuspensionSendClear( "", g_szSusTier );

	bool bGoal = false;
	for( int i = 1; i <= g_Engine.maxClients; ++i )
	{
		CBasePlayer@ pPlayer = g_PlayerFuncs.FindPlayerByIndex( i );
		if( pPlayer is null || !pPlayer.IsConnected() )
			continue;

		string szClass = SuspensionMajorityClass( pPlayer );
		if( szClass.Length() == 0 )
			continue;

		SuspensionSendClear( szClass, g_szSusTier );

		// The goal is a run cleared as the map-gated class at the hardest tier
		// this seed contains. The client decides what that means for the slot.
		if( szClass == g_pArcade.goalClass
		 && g_Suspension.TierIndex( g_szSusTier ) == int( g_Suspension.tiers.length() ) - 1 )
			bGoal = true;
	}

	g_PlayerFuncs.ClientPrintAll( HUD_PRINTTALK,
		"[AP] Suspension cleared on " + g_szSusTier + " with "
		+ g_iSusDeaths + " deaths.\n" );

	if( bGoal )
		BridgeSend( "GOAL|" + g_pArcade.key );
}

// --- Hooks ----------------------------------------------------------------

/*
* Refuse a vote for a tier the seed has not opened yet.
*
* The vote buttons are ordinary func_buttons, so PlayerUse is the whole of it.
* Returning HOOK_HANDLED stops the press without touching the map.
*/
bool SuspensionBlockUse( CBasePlayer@ pPlayer, CBaseEntity@ pEntity )
{
	if( !SuspensionManaged() || pEntity is null )
		return false;

	string szName = string( pEntity.pev.targetname );
	for( uint i = 0; i < g_SusTiers.length(); ++i )
	{
		APTier@ pTier = g_SusTiers[i];
		if( pTier.voteButton != szName )
			continue;
		if( g_Suspension.TierOpen( pTier.key ) )
			return false;

		g_PlayerFuncs.SayText( pPlayer,
			"[AP] " + pTier.name + " is locked. Find Progressive Suspension Difficulty.\n" );
		return true;
	}
	return false;
}

void SuspensionCountDeath()
{
	if( SuspensionManaged() && g_bSusRoundActive )
		++g_iSusDeaths;
}

/*
* The think loop. Reads our own counters, which the map advanced for us.
*/
void SuspensionThink()
{
	if( !SuspensionManaged() )
		return;

	int iTier = SuspensionCounter( SUS_COUNTER_TIER );
	if( iTier > 0 && iTier <= int( g_SusTiers.length() ) )
	{
		string szTier = g_SusTiers[ iTier - 1 ].key;
		if( szTier != g_szSusTier )
		{
			g_szSusTier = szTier;
			APLog( "suspension: tier voted " + szTier );
		}
	}

	if( !g_bSusRoundActive && SuspensionCounter( SUS_COUNTER_START ) > 0 )
		SuspensionBeginRound();

	if( g_bSusRoundActive )
	{
		int iCleared = SuspensionCounter( SUS_COUNTER_SECTION );
		while( g_iSusCleared < iCleared )
		{
			++g_iSusCleared;
			SuspensionCreditSection( g_iSusCleared );
		}

		if( SuspensionCounter( SUS_COUNTER_END ) > 0 )
			SuspensionEndRound();
	}

	SuspensionWatchJuggernaut();
}
