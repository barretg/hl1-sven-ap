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
	// What the vote button fires when it is pressed, and what it collides as,
	// both read off the map the first time we see it. A locked button has its
	// target taken away and given back, which is what makes the lock hold
	// whatever manages to press it.
	//
	// Nothing about the button's solidity is touched: it stays where the map put
	// it so the use trace has something to land on, and the refusal is a message
	// rather than an absence.
	string voteTarget;
	bool voteTargetKnown = false;
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
	// The teleport destination this class's lobby portal sends a player to, which
	// is also the only thing identifying the portal: the trigger has no name of
	// its own. A locked portal is pointed somewhere else instead, so once we have
	// found one we stamp a name on it and keep a handle, rather than looking for
	// a target that is no longer there.
	string portal;
	bool mapGated = false;
	EHandle hPortal;
	// Our own wall across the doorway while the class is locked, built from the
	// portal's brush. Removed the moment the item arrives.
	EHandle hBlock;

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

/*
* Put a counter back, because the map never will.
*
* Our counters latch: the map sets one once and it stays set for the rest of the
* map. Reading "the round has ended" without clearing it meant the think loop
* ended the round, saw the start signal still standing, began it again, saw the
* end signal still standing... four times a second, for as long as the map ran.
* Every counter we consume is spent here.
*/
void SuspensionSetCounter( const string& in szName, int iValue )
{
	CBaseEntity@ pEntity = g_EntityFuncs.FindEntityByTargetname( null, szName );
	if( pEntity !is null )
		pEntity.pev.frags = iValue;
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
	// A map load starts the engine's clock again, so a deadline left over from
	// the last one would sit in the future forever and the locks would never be
	// reasserted. Zero means "at the next think".
	g_flSusNextLockSync = 0.0f;
}

void SuspensionMapStart()
{
	SuspensionResetRound();

	// The entities here are this map's own, freshly spawned as the map made
	// them, whatever we did to the last copy of them. Forgotten only here: a
	// locked button is one we have already blanked, so forgetting at any other
	// moment would lose the only record of what to put back.
	for( uint i = 0; i < g_SusTiers.length(); ++i )
	{
		g_SusTiers[i].voteTarget = "";
		g_SusTiers[i].voteTargetKnown = false;
	}
	// Both handles point at the last map's entities, and our walls went with it.
	for( uint i = 0; i < g_SusClasses.length(); ++i )
	{
		g_SusClasses[i].hPortal = EHandle();
		g_SusClasses[i].hBlock = EHandle();
	}
	g_flSusBoothWarned.deleteAll();
	g_flSusVoteRefused.deleteAll();
	// This map's seal is whatever the map spawned it as, not what we left the
	// last one in.
	g_iSusSealApplied = -1;

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
// Solidity turned out to be the wrong tool for both of them, in opposite
// directions. A vote button is left exactly as the map built it and has its
// wiring cut instead, so a press is answered with a sentence and fires nothing.
// A class booth cannot be answered that way -- there is nothing to press, only a
// doorway to walk through -- so a wall of ours goes in front of it, and walking
// up to that wall is what prints the sentence.
//
// The map's own entities are never made solid by hand. `SOLID_BSP` is legal
// only on a pusher, the engine checks that pair every time it links an entity,
// and getting it wrong is fatal rather than cosmetic.

/*
* First sight of a vote button: whatever it points at is what the map wired it
* to.
*
* Only ever taken from a button we have not touched, which is why the target is
* only believed while it is non-empty -- a blanked one is our own work, and
* believing it would lose the wiring for good.
*/
void SuspensionRememberVoteButton( CBaseEntity@ pButton, APTier@ pTier )
{
	if( pButton is null || pTier is null )
		return;

	string szTarget = string( pButton.pev.target );
	if( !pTier.voteTargetKnown && szTarget.Length() > 0 )
	{
		pTier.voteTarget = szTarget;
		pTier.voteTargetKnown = true;
	}
}

/*
* Take the wiring out of a vote button, and put it back.
*
* Going non-solid should be enough on its own -- a brush the engine will not
* trace against is a brush nobody can press -- and in game it was not: the vote
* still went through. Rather than work out which of the engine's routes to a
* button survives that, this cuts the wire as well. A `func_button` with nothing
* in `target` fires nothing when it is pressed, however it came to be pressed,
* so a locked tier cannot be voted for by any route at all.
*
* The target is read off the map rather than carried in the data file, so it
* stays right if the map is rebuilt, and it is remembered per tier so that
* unlocking can put back exactly what was there.
*/
void SuspensionSetVoteLive( CBaseEntity@ pButton, APTier@ pTier, bool bLive )
{
	if( pButton is null || pTier is null )
		return;

	string szTarget = string( pButton.pev.target );

	if( bLive )
	{
		if( pTier.voteTargetKnown && szTarget.Length() == 0 )
			pButton.pev.target = pTier.voteTarget;
	}
	else if( szTarget.Length() > 0 )
	{
		pButton.pev.target = "";
	}
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

	// Found once and held, because a locked portal has been pointed away from
	// `pick_<class>` and would no longer answer to the search below.
	CBaseEntity@ pHeld = pClass.hPortal.GetEntity();
	if( pHeld !is null )
		return pHeld;

	CBaseEntity@ pEntity = null;
	while( ( @pEntity = g_EntityFuncs.FindEntityByClassname(
		pEntity, "trigger_teleport" ) ) !is null )
	{
		if( string( pEntity.pev.target ) == pClass.portal )
		{
			pClass.hPortal = EHandle( pEntity );
			return pEntity;
		}
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
		bool bOpen = g_Suspension.TierOpen( pTier.key );
		SuspensionRememberVoteButton( pButton, pTier );
		// Solid and visible either way. A button that vanishes refuses silently,
		// and a locked tier deserves the same sentence a locked weapon gets --
		// which needs something for the use trace to land on. Cutting the wire is
		// what makes the refusal safe: the press is answered, and nothing behind
		// it fires whether or not the press itself can be stopped.
		SuspensionSetVoteLive( pButton, pTier, bOpen );
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
		SuspensionSetPortalOpen( pClass, bOpen );
	}
}

/*
* Open or close a class booth.
*
* The portals are 64x64 slabs four units thick standing in the booth doorways,
* and walking into one is what teleports a player to the class pad behind it. A
* player is never *in* a booth, which is why switching the teleport off did not
* close one: it opened a room whose only way out was the teleport that had just
* been disabled, and players walked in and were stuck. Sending them somewhere
* else instead needed a destination, and the lobby's first spawn point turned
* out to be inside a wall.
*
* So the map's own portal is left exactly as the map built it -- live, solid,
* invisible -- and a wall of ours goes across the doorway in front of it, built
* from the portal's own brush so it is the same 64x64 slab. The engine builds it
* as a `func_wall`, which is a pusher and legally SOLID_BSP; setting that by
* hand on the trigger is what printed `SOLID_BSP WITHOUT MOVE_PUSH`.
*
* Removed, not disabled, when the item arrives: an entity that is not there
* cannot be left in a state that outlives the lock.
*/
void SuspensionSetPortalOpen( APClass@ pClass, bool bOpen )
{
	CBaseEntity@ pBlock = pClass.hBlock.GetEntity();

	if( bOpen )
	{
		if( pBlock !is null )
		{
			g_EntityFuncs.Remove( pBlock );
			pClass.hBlock = EHandle();
		}
		return;
	}

	if( pBlock !is null )
		return;  // already walled off

	CBaseEntity@ pPortal = SuspensionPortalOf( pClass );
	if( pPortal is null )
		return;

	// Brush models are named "*<index>". Anything else is not something a wall
	// can be built from, and an unearned class is better than a broken lobby.
	string szModel = string( pPortal.pev.model );
	if( szModel.Length() < 2 || szModel.SubString( 0, 1 ) != "*" )
	{
		APLog( "suspension: " + pClass.key + "'s portal has no brush to wall off; "
		     + "the class stays enterable" );
		return;
	}

	dictionary keys;
	keys[ "targetname" ] = "ap_sus_block_" + pClass.key;
	keys[ "model" ] = szModel;
	CBaseEntity@ pNew = g_EntityFuncs.CreateEntity( "func_wall", keys, true );

	if( pNew is null )
	{
		APLog( "suspension: could not wall off " + pClass.key
		     + "; the class stays enterable" );
		return;
	}

	// Invisible, because the brush is a trigger's and wears a trigger's texture.
	// What tells a player the booth is shut is the message, not a slab.
	pNew.pev.effects |= EF_NODRAW;
	pClass.hBlock = EHandle( pNew );
}

/*
* Say what is open, on arrival. The per-booth message below covers walking into
* one; this is what a player gets before they have walked anywhere.
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
// What the seal was last set to: -1 nothing yet, 0 open, 1 sealed. The locks are
// reasserted every second and this is not idempotent -- the reveal is a
// multi_manager fire, and firing it four times a minute made the placeholder
// flash on and off over the Juggernaut's icon for as long as anyone watched.
int g_iSusSealApplied = -1;

void SuspensionSealJuggernaut( bool bSealed )
{
	int iWanted = bSealed ? 1 : 0;
	if( g_iSusSealApplied == iWanted )
		return;
	g_iSusSealApplied = iWanted;

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

/*
* What this entity may legally be switched on as.
*
* SOLID_BSP is only ever legal on a pusher: the engine checks the pair every
* time it links an entity, and `SOLID_BSP without MOVETYPE_PUSH` is a fatal
* error rather than a warning. The Juggernaut's seal is two entities, a
* `func_wall_toggle` and a `trigger_hurt`, and giving both of them SOLID_BSP
* took the server down the next time the trigger was linked -- on a respawn in
* the lobby, long after the seal was set. Switching a trigger on means
* SOLID_TRIGGER; only the wall is a wall.
*/
int SuspensionSolidFor( CBaseEntity@ pEntity )
{
	if( pEntity !is null && pEntity.pev.movetype == MOVETYPE_PUSH )
		return SOLID_BSP;
	return SOLID_TRIGGER;
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
		pEntity.pev.solid = bSealed ? SuspensionSolidFor( pEntity ) : SOLID_NOT;
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

	// Spent, so the next round needs the map to signal a start of its own.
	SuspensionSetCounter( SUS_COUNTER_START, 0 );
	SuspensionSetCounter( SUS_COUNTER_END, 0 );
	SuspensionSetCounter( SUS_COUNTER_SECTION, 0 );

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

	// Both spent: the map's signals stand for the rest of the map, and reading
	// them again is what turned one clear into an endless run of them.
	SuspensionSetCounter( SUS_COUNTER_END, 0 );
	SuspensionSetCounter( SUS_COUNTER_START, 0 );

	// The last section has no signal of its own: reaching the end of the round
	// is what clears it.
	if( g_SusSections.length() > 0 )
		SuspensionCreditSection( g_SusSections[ g_SusSections.length() - 1 ].index );

	// Every medal the run earned, not only the best one. A seed whose ladder
	// stops at bronze contains no gold medal at all, so a five-death run -- a
	// gold -- used to send nothing whatever, because the one medal it was
	// scored as was not a check in this seed. An award is earned when the team
	// died no more often than it allows, and every easier one is earned with it.
	bool bAnyEarned = false;
	for( uint i = 0; i < g_SusAwards.length(); ++i )
	{
		APAward@ pAward = g_SusAwards[i];
		if( g_iSusDeaths > pAward.deaths )
			continue;
		bAnyEarned = true;
		if( g_Suspension.AwardWanted( pAward.key ) )
			SuspensionSendAward( pAward.key, g_szSusTier );
	}

	// Past the bottom of the ladder is still the bottom rung rather than
	// nothing: a won run always earns the worst medal, however it went.
	if( !bAnyEarned && g_SusAwards.length() > 0 )
	{
		APAward@ pWorst = g_SusAwards[ g_SusAwards.length() - 1 ];
		if( g_Suspension.AwardWanted( pWorst.key ) )
			SuspensionSendAward( pWorst.key, g_szSusTier );
	}

	// A run was finished at this tier, whoever played what.
	SuspensionSendClear( "", g_szSusTier );

	for( int i = 1; i <= g_Engine.maxClients; ++i )
	{
		CBasePlayer@ pPlayer = g_PlayerFuncs.FindPlayerByIndex( i );
		if( pPlayer is null || !pPlayer.IsConnected() )
			continue;

		string szClass = SuspensionMajorityClass( pPlayer );
		if( szClass.Length() == 0 )
			continue;

		SuspensionSendClear( szClass, g_szSusTier );
	}

	// No goal is reported from here. Winning the arcade is a set of clears --
	// one per class at the capped tier, and the medal too where the seed asks
	// for it -- which is a question about what has been checked rather than
	// about what just happened, and only the client can see that.

	g_PlayerFuncs.ClientPrintAll( HUD_PRINTTALK,
		"[AP] Suspension cleared on " + g_szSusTier + " with "
		+ g_iSusDeaths + " deaths.\n" );

	// The map ends itself once the bridge is taken, and the server then moves on
	// to whatever its map cycle says -- which stranded the lobby somewhere that
	// is not in the seed at all. Come back here instead.
	g_bSusRestartPending = true;
}

// Set when a round is scored, read on the far side of the map change the map
// makes for itself. Survives that change, like everything else the plugin has
// to carry across one.
bool g_bSusRestartPending = false;

/*
* We were playing the arcade, the map ended, and the server has loaded something
* else. Go back rather than leave the lobby stranded on a map from the cycle.
*
* Answered once: if Suspension is not in the seed any more -- a new slot, say --
* the hub is where everything else goes.
*/
bool SuspensionConsumeRestart()
{
	if( !g_bSusRestartPending )
		return false;

	g_bSusRestartPending = false;

	if( g_pArcade is null || !g_Suspension.enabled )
		return false;
	if( g_szCurrentMap == g_pArcade.map )
		return false;  // it restarted itself; nothing to do

	g_PlayerFuncs.ClientPrintAll( HUD_PRINTTALK,
		"[AP] Back to " + g_pArcade.name + "...\n" );
	ChangeLevel( g_pArcade.map );
	return true;
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

		// PlayerUse is a per-frame hook, not a per-press one: it runs on every
		// think for every player, so merely looking at the button from across the
		// lobby was a refusal several times a second. Answer a press.
		if( ( pPlayer.pev.button & IN_USE ) == 0 )
			return true;

		// And a press is held down across many frames, so say it occasionally
		// even then.
		string szKey = SuspensionPlayerKey( pPlayer ) + "|" + pTier.key;
		float flLast = 0.0f;
		if( !g_flSusVoteRefused.get( szKey, flLast )
		    || g_Engine.time - flLast >= SUS_REFUSAL_INTERVAL )
		{
			g_flSusVoteRefused[ szKey ] = g_Engine.time;
			g_PlayerFuncs.SayText( pPlayer,
				"[AP] " + pTier.name + " is locked. Find Progressive Suspension Difficulty.\n" );
		}

		return true;
	}
	return false;
}

void SuspensionCountDeath()
{
	if( SuspensionManaged() && g_bSusRoundActive )
		++g_iSusDeaths;
}

// When the locks are next reasserted. The map is free to spawn, respawn and
// reset its own entities -- `kill_vote_button` alone removes all four buttons by
// wildcard -- and a lock applied once at map start is only as good as whatever
// the map does next. Reasserting is idempotent and costs a handful of entity
// lookups, so it runs on its own slow beat rather than every think.
float g_flSusNextLockSync = 0.0f;
const float SUS_LOCK_SYNC_INTERVAL = 1.0f;

// Close enough to a booth's doorway to have meant to walk into it.
const float SUS_BOOTH_WARN_RANGE = 80.0f;

// How long before a player is told the same thing again, whichever lock told
// them. Both refusals are driven by something that repeats every tick -- the
// think loop for a booth, the use key for a button -- so without this they are
// not a message but a wall of text.
const float SUS_REFUSAL_INTERVAL = 4.0f;

dictionary g_flSusBoothWarned;
dictionary g_flSusVoteRefused;

/*
* Tell a player why the booth they are standing at will not let them in.
*
* A locked booth is a wall with nothing written on it, and a wall that refuses
* silently reads as a broken map. This is the same sentence a locked weapon
* gives, in the same place on the screen, for the same reason: the centre print
* is where this game says "you cannot have that yet".
*
* Proximity rather than a touch, because the wall is what they reach first and a
* wall has nothing to touch. Rate-limited per player and class, since standing
* in front of one is a normal thing to do for a few seconds.
*/
void SuspensionWarnLockedBooths()
{
	for( uint i = 0; i < g_SusClasses.length(); ++i )
	{
		APClass@ pClass = g_SusClasses[i];

		// Only ones we have actually walled off. A class the seed left open, or
		// one whose wall could not be built, has nothing to explain.
		if( pClass.hBlock.GetEntity() is null )
			continue;

		CBaseEntity@ pPortal = SuspensionPortalOf( pClass );
		if( pPortal is null )
			continue;

		Vector vecDoor = ( pPortal.pev.absmin + pPortal.pev.absmax ) * 0.5f;

		for( int iPlayer = 1; iPlayer <= g_Engine.maxClients; ++iPlayer )
		{
			CBasePlayer@ pPlayer = g_PlayerFuncs.FindPlayerByIndex( iPlayer );
			if( pPlayer is null || !pPlayer.IsConnected() || !pPlayer.IsAlive() )
				continue;

			if( ( pPlayer.pev.origin - vecDoor ).Length() > SUS_BOOTH_WARN_RANGE )
				continue;

			string szKey = SuspensionPlayerKey( pPlayer ) + "|" + pClass.key;
			float flLast = 0.0f;
			if( g_flSusBoothWarned.get( szKey, flLast )
			    && g_Engine.time - flLast < SUS_REFUSAL_INTERVAL )
				continue;

			g_flSusBoothWarned[ szKey ] = g_Engine.time;
			g_PlayerFuncs.ClientPrint( pPlayer, HUD_PRINTCENTER,
				"You have not found the " + pClass.name + " yet.\n" );
		}
	}
}

/*
* The think loop. Reads our own counters, which the map advanced for us.
*/
void SuspensionThink()
{
	if( !SuspensionManaged() )
		return;

	if( g_Engine.time >= g_flSusNextLockSync )
	{
		g_flSusNextLockSync = g_Engine.time + SUS_LOCK_SYNC_INTERVAL;
		SuspensionSyncLocks();
	}

	SuspensionWarnLockedBooths();

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
