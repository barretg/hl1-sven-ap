/*
* Bot Swarm Trap: six crowbar bots, ported from hl1-anniversary-ap.
*
* The brain is anniversary's: walk a heading; duck if that is what opens the way;
* otherwise crouch-jump it, and turn away if the landing got nowhere. Anything
* alive within reach, a player included, is faced and hit with the crowbar for a
* bout of one to three swings, and then the bot turns tail and runs.
*
* The body is different, because a plugin cannot register an entity class of its
* own. A bot is a stock `monster_generic` wearing a player model, with its own
* AI kept asleep by pushing its think into the future every tick, and this file
* drives it from the plugin's fast timer instead. `g_PlayerFuncs.CreateBot` was
* the other way in, and the wrong one here: a fake client is a player, so it
* would take a slot, be handed a loadout, trip DeathLink when it died and be
* immune to friendly-fire-off crowbars.
*
* The hull is the player's, origin at the centre, because a player model is drawn
* around its origin: with a monster's feet origin every bot stood waist deep in
* the floor.
*/

const int BOT_SWARM_COUNT = 6;
const float BOT_HEALTH = 30.0f;
const float BOT_CROWBAR_DAMAGE = 5.0f;

// How far ahead the way is checked, how often progress is sampled, and how far
// the bot has to have gone in that time to count as moving.
const float BOT_LOOKAHEAD = 24.0f;
const float BOT_PROGRESS_INTERVAL = 0.3f;
const float BOT_PROGRESS_DISTANCE = 16.0f;

// The step the engine walks a monster up without being asked.
const float BOT_STEP_HEIGHT = 18.0f;

// A jump got somewhere if it ended this much higher or this much further along
// the heading. One that has not landed by the timeout was a fall.
const float BOT_JUMP_GAIN_Z = 8.0f;
const float BOT_JUMP_GAIN_FORWARD = 16.0f;
const float BOT_JUMP_TIMEOUT = 2.0f;

// The smallest turn taken when a heading is given up on.
const float BOT_TURN_MIN = 45.0f;

const float BOT_MELEE_RANGE = 48.0f;
const float BOT_MELEE_HEIGHT = 72.0f;

// One swing, the player model's crowbar swing: the hit lands partway through it,
// and there is a breath before the next.
const float BOT_SWING_HIT_AT = 0.2f;
const float BOT_SWING_TIME = 0.55f;
const float BOT_RECOVER_TIME = 0.2f;

const int BOT_BOUT_SWINGS_MIN = 1;
const int BOT_BOUT_SWINGS_MAX = 3;
const float BOT_FLEE_MIN = 1.0f;
const float BOT_FLEE_MAX = 2.0f;
const float BOT_FLEE_SPREAD = 45.0f;

// A player's run speed and jump.
const float BOT_RUN_SPEED = 240.0f;
const float BOT_JUMP_SPEED = 268.0f;

const float BOT_STAND_HALF = 36.0f;
const float BOT_DUCK_HALF = 18.0f;

const float BOT_CORPSE_SECONDS = 5.0f;

// How far into the future the monster's own AI is pushed on every tick. Longer
// than the fast timer's interval, so it never gets a turn while we are driving.
const float BOT_AI_SNOOZE = 1.0f;

// Player skins Sven Co-op ships, all on the player skeleton so the crowbar pose
// and the animation names below fit every one. Each is a precache slot on every
// map, so the list is short.
array<string> g_BotModels = {
	"models/player/barney/barney.mdl",
	"models/player/gordon/gordon.mdl",
	"models/player/helmet/helmet.mdl",
	"models/player/gina/gina.mdl",
	"models/player/scientist/scientist.mdl",
	"models/player/robo/robo.mdl"
};

const string BOT_CROWBAR_MODEL = "models/p_crowbar.mdl";

// Set in MapInit alongside the trap monsters, for the same reason: a precache
// anywhere else is a Host_Error.
bool g_bBotsPrecached = false;

void PrecacheBots()
{
	for( uint i = 0; i < g_BotModels.length(); ++i )
		g_Game.PrecacheModel( g_BotModels[i] );
	g_Game.PrecacheModel( BOT_CROWBAR_MODEL );

	g_SoundSystem.PrecacheSound( "weapons/cbar_hit1.wav" );
	g_SoundSystem.PrecacheSound( "weapons/cbar_hit2.wav" );
	g_SoundSystem.PrecacheSound( "weapons/cbar_hitbod1.wav" );
	g_SoundSystem.PrecacheSound( "weapons/cbar_hitbod2.wav" );
	g_SoundSystem.PrecacheSound( "weapons/cbar_hitbod3.wav" );
	g_SoundSystem.PrecacheSound( "weapons/cbar_miss1.wav" );

	g_bBotsPrecached = true;
}

const int BOT_MOVE_WANDER = 0;
const int BOT_MOVE_JUMP = 1;

const int BOT_MELEE_IDLE = 0;
const int BOT_MELEE_SWING = 1;
const int BOT_MELEE_RECOVER = 2;

class APBot
{
	EHandle hBody;
	EHandle hCrowbar;

	float flYaw = 0.0f;
	float flLastThink = 0.0f;
	int iMove = BOT_MOVE_WANDER;
	Vector vecLastOrigin;
	float flNextProgress = 0.0f;
	Vector vecJumpStart;
	bool bAirborne = false;
	float flJumpExpire = 0.0f;
	int iMelee = BOT_MELEE_IDLE;
	float flMeleeNext = 0.0f;
	bool bHitPending = false;
	int iSwingsLeft = 0;
	float flDiedAt = 0.0f;
	string szSequence;
}

array<APBot@> g_Bots;

void ClearBots()
{
	g_Bots.resize( 0 );
	g_bBotsPrecached = false;
}

/*
* Spring the trap: six bots, spread round-robin across the living players, so a
* full lobby gets the same six a lone player would rather than six each.
*/
void BotSwarm()
{
	if( !g_bBotsPrecached )
		return;

	array<CBasePlayer@> players;
	for( int i = 1; i <= g_Engine.maxClients; ++i )
	{
		CBasePlayer@ pPlayer = g_PlayerFuncs.FindPlayerByIndex( i );
		if( pPlayer is null || !pPlayer.IsConnected() || !pPlayer.IsAlive() )
			continue;
		if( pPlayer.GetObserver().IsObserver() )
			continue;
		players.insertLast( pPlayer );
	}

	if( players.length() == 0 )
		return;

	int iSpawned = 0;
	array<array<Vector>> placed( players.length() );

	for( int n = 0; n < BOT_SWARM_COUNT; ++n )
	{
		uint uiWho = uint( n ) % players.length();
		CBasePlayer@ pPlayer = players[uiWho];

		for( int attempt = 0; attempt < TRAP_PLACE_ATTEMPTS; ++attempt )
		{
			float flBearing = Math.RandomFloat( 0.0f, 360.0f );
			float flRange = Math.RandomFloat( TRAP_SPAWN_MIN_RADIUS, TRAP_SPAWN_MAX_RADIUS );

			Vector vecFeet;
			if( !FindTrapSpot( pPlayer, human_hull, HUMAN_HULL_HALF, flBearing, flRange, vecFeet ) )
				continue;
			if( TooCloseToPlaced( vecFeet, placed[uiWho] ) )
				continue;

			if( SpawnBot( vecFeet, flBearing + 180.0f ) )
			{
				placed[uiWho].insertLast( vecFeet );
				++iSpawned;
			}
			break;
		}
	}

	if( iSpawned > 0 )
		g_PlayerFuncs.ClientPrintAll( HUD_PRINTTALK, "[AP] Bot swarm!\n" );
	else
		APLog( "bot swarm found nowhere to stand" );
}

bool SpawnBot( const Vector& in vecFeet, float flYaw )
{
	dictionary keys;
	// Handed the feet, like any spawn spot; the origin is the hull's centre.
	Vector vecOrigin = vecFeet + Vector( 0.0f, 0.0f, BOT_STAND_HALF );
	keys[ "origin" ] = "" + vecOrigin.x + " " + vecOrigin.y + " " + vecOrigin.z;
	keys[ "angles" ] = "0 " + flYaw + " 0";
	keys[ "model" ] = g_BotModels[ Math.RandomLong( 0, g_BotModels.length() - 1 ) ];
	keys[ "health" ] = "" + int( BOT_HEALTH );
	// Hostile to everyone, players included, which is the whole joke. The
	// game's own monsters return the favour.
	keys[ "classify" ] = "" + int( CLASS_ALIEN_MONSTER );
	keys[ "displayname" ] = "Bot";

	CBaseEntity@ pBody = g_EntityFuncs.CreateEntity( "monster_generic", keys, true );
	if( pBody is null )
		return false;

	g_EntityFuncs.SetSize( pBody.pev, Vector( -16, -16, -BOT_STAND_HALF ),
	                       Vector( 16, 16, BOT_STAND_HALF ) );
	g_EntityFuncs.SetOrigin( pBody, vecOrigin );
	pBody.pev.movetype = MOVETYPE_STEP;
	pBody.pev.solid = SOLID_SLIDEBOX;
	pBody.pev.takedamage = DAMAGE_AIM;
	pBody.pev.health = BOT_HEALTH;
	pBody.pev.max_health = BOT_HEALTH;
	pBody.pev.view_ofs = Vector( 0, 0, 28 );
	// Shirt and trousers, as a player's topcolor and bottomcolor.
	pBody.pev.colormap = Math.RandomLong( 0, 255 ) | ( Math.RandomLong( 0, 255 ) << 8 );
	pBody.pev.nextthink = g_Engine.time + BOT_AI_SNOOZE;

	APBot bot;
	bot.hBody = EHandle( pBody );
	bot.flYaw = flYaw;
	bot.flLastThink = g_Engine.time;
	BotSampleProgress( bot, pBody );

	// A non-player is drawn without its weapon model, so the crowbar is its own
	// entity following the bot. MOVETYPE_FOLLOW copies the bones of whatever it
	// follows, which is what a p_ model is built for.
	CBaseEntity@ pCrowbar = g_EntityFuncs.Create( "info_target", vecOrigin, g_vecZero, false );
	if( pCrowbar !is null )
	{
		g_EntityFuncs.SetModel( pCrowbar, BOT_CROWBAR_MODEL );
		pCrowbar.pev.movetype = MOVETYPE_FOLLOW;
		@pCrowbar.pev.aiment = pBody.edict();
		pCrowbar.pev.solid = SOLID_NOT;
		bot.hCrowbar = EHandle( pCrowbar );
	}

	BotSequence( bot, pBody, "ref_aim_crowbar", true );
	g_Bots.insertLast( @bot );
	return true;
}

void BotRemove( APBot@ bot )
{
	CBaseEntity@ pCrowbar = bot.hCrowbar.GetEntity();
	if( pCrowbar !is null )
		g_EntityFuncs.Remove( pCrowbar );
	CBaseEntity@ pBody = bot.hBody.GetEntity();
	if( pBody !is null )
		g_EntityFuncs.Remove( pBody );
}

/* On the fast timer. */
void BotsThink()
{
	for( uint i = g_Bots.length(); i > 0; --i )
	{
		APBot@ bot = g_Bots[i - 1];
		CBaseEntity@ pBody = bot.hBody.GetEntity();

		if( pBody is null )
		{
			BotRemove( bot );
			g_Bots.removeAt( i - 1 );
			continue;
		}

		// Its own AI never gets a turn, alive or dead: its death schedule would
		// look for activities a player model does not have.
		pBody.pev.nextthink = g_Engine.time + BOT_AI_SNOOZE;

		if( pBody.pev.deadflag != DEAD_NO || pBody.pev.health <= 0 )
		{
			if( BotDeadThink( bot, pBody ) )
			{
				BotRemove( bot );
				g_Bots.removeAt( i - 1 );
			}
			continue;
		}

		float flDt = g_Engine.time - bot.flLastThink;
		if( flDt <= 0.0f || flDt > 0.2f )
			flDt = FAST_INTERVAL;
		bot.flLastThink = g_Engine.time;

		float flYaw = bot.flYaw;
		bool bFighting = BotMeleeThink( bot, pBody, flYaw );
		if( bFighting && bot.iMove == BOT_MOVE_JUMP && ( pBody.pev.flags & FL_ONGROUND ) != 0 )
		{
			bot.iMove = BOT_MOVE_WANDER;
			bot.bAirborne = false;
		}

		BotMoveThink( bot, pBody, flDt, flYaw, bFighting );

		pBody.pev.angles.y = bFighting ? flYaw : bot.flYaw;
		pBody.pev.ideal_yaw = pBody.pev.angles.y;
		BotAnimate( bot, pBody, !bFighting );
	}
}

/* True once the body is done with and can go. */
bool BotDeadThink( APBot@ bot, CBaseEntity@ pBody )
{
	if( bot.flDiedAt <= 0.0f )
	{
		bot.flDiedAt = g_Engine.time;
		pBody.pev.deadflag = DEAD_DEAD;
		pBody.pev.takedamage = DAMAGE_NO;
		pBody.pev.solid = SOLID_NOT;
		pBody.pev.velocity.x = 0.0f;
		pBody.pev.velocity.y = 0.0f;

		CBaseEntity@ pCrowbar = bot.hCrowbar.GetEntity();
		if( pCrowbar !is null )
			g_EntityFuncs.Remove( pCrowbar );

		array<string> deaths = { "die_simple", "die_backwards", "die_forwards", "die_spin", "gutshot" };
		BotSequence( bot, pBody, deaths[ Math.RandomLong( 0, deaths.length() - 1 ) ], true );
		bot.iMelee = BOT_MELEE_IDLE;
	}

	// Gibbed: nothing left to lie there.
	if( ( pBody.pev.effects & EF_NODRAW ) != 0 )
		return true;

	return g_Engine.time - bot.flDiedAt >= BOT_CORPSE_SECONDS;
}

bool BotDucked( CBaseEntity@ pBody )
{
	return pBody.pev.maxs.z < BOT_STAND_HALF - 1.0f;
}

Vector BotFeet( CBaseEntity@ pBody )
{
	return pBody.pev.origin + Vector( 0.0f, 0.0f, pBody.pev.mins.z );
}

void BotSetDucked( CBaseEntity@ pBody, bool bDucked )
{
	if( bDucked == BotDucked( pBody ) )
		return;

	bool bOnGround = ( pBody.pev.flags & FL_ONGROUND ) != 0;
	Vector vecFeet = BotFeet( pBody );
	float flHalf = bDucked ? BOT_DUCK_HALF : BOT_STAND_HALF;
	g_EntityFuncs.SetSize( pBody.pev, Vector( -16, -16, -flHalf ), Vector( 16, 16, flHalf ) );

	// On the ground the feet stay on the floor; in the air the centre stays put
	// and the legs tuck up, which is what makes a crouch jump clear more.
	if( bOnGround )
		g_EntityFuncs.SetOrigin( pBody, vecFeet + Vector( 0.0f, 0.0f, flHalf ) );
	pBody.pev.view_ofs = Vector( 0, 0, bDucked ? 12 : 28 );
}

bool BotCanStand( CBaseEntity@ pBody )
{
	Vector vecCentre = ( pBody.pev.flags & FL_ONGROUND ) != 0
		? BotFeet( pBody ) + Vector( 0.0f, 0.0f, BOT_STAND_HALF )
		: pBody.pev.origin;

	TraceResult tr;
	g_Utility.TraceHull( vecCentre, vecCentre, dont_ignore_monsters, human_hull,
	                     pBody.edict(), tr );
	return tr.fStartSolid == 0 && tr.fAllSolid == 0;
}

/*
* Is there room to go BOT_LOOKAHEAD units along `vecForward`, standing or ducked?
* Flat first, then from the top of a step, which the engine walks a monster up
* anyway.
*/
bool BotPathClear( CBaseEntity@ pBody, const Vector& in vecForward, bool bDuck )
{
	HULL_NUMBER hull = bDuck ? head_hull : human_hull;
	float flCentre = bDuck ? BOT_DUCK_HALF : BOT_STAND_HALF;

	for( int pass = 0; pass < 2; ++pass )
	{
		Vector vecStart = BotFeet( pBody )
			+ Vector( 0.0f, 0.0f, flCentre + ( pass == 1 ? BOT_STEP_HEIGHT : 0.0f ) );
		TraceResult tr;
		g_Utility.TraceHull( vecStart, vecStart + vecForward * BOT_LOOKAHEAD,
		                     dont_ignore_monsters, hull, pBody.edict(), tr );
		if( tr.fAllSolid == 0 && tr.fStartSolid == 0 && tr.flFraction >= 1.0f )
			return true;
	}

	return false;
}

void BotSampleProgress( APBot@ bot, CBaseEntity@ pBody )
{
	bot.vecLastOrigin = pBody.pev.origin;
	bot.flNextProgress = g_Engine.time + BOT_PROGRESS_INTERVAL;
}

void BotTurnAway( APBot@ bot, CBaseEntity@ pBody )
{
	float flTurn = Math.RandomFloat( BOT_TURN_MIN, 180.0f );
	bot.flYaw = Math.AngleMod( bot.flYaw + ( Math.RandomLong( 0, 1 ) == 1 ? flTurn : -flTurn ) );
	BotSampleProgress( bot, pBody );
}

float BotYawTo( const Vector& in vecDelta )
{
	return Math.VecToYaw( vecDelta );
}

Vector BotForward( float flYaw )
{
	Math.MakeVectors( Vector( 0.0f, flYaw, 0.0f ) );
	return g_Engine.v_forward;
}

/*
* Whatever this bot has run into: anything alive in reach, a player, a monster,
* another bot, and failing that whatever breakable thing is straight ahead.
*/
CBaseEntity@ BotFindVictim( APBot@ bot, CBaseEntity@ pBody )
{
	Vector vecEyes = pBody.pev.origin + pBody.pev.view_ofs;
	CBaseEntity@ pNearest = null;
	float flNearest = BOT_MELEE_RANGE;

	CBaseEntity@ pOther = null;
	while( ( @pOther = g_EntityFuncs.FindEntityInSphere( pOther, pBody.pev.origin,
	         BOT_MELEE_RANGE + BOT_MELEE_HEIGHT, "*", "classname" ) ) !is null )
	{
		if( pOther is pBody || pOther.pev.takedamage == DAMAGE_NO || !pOther.IsAlive()
		    || pOther.IsBSPModel() )
			continue;
		if( ( pOther.pev.flags & ( FL_CLIENT | FL_MONSTER ) ) == 0
		    || ( pOther.pev.flags & FL_NOTARGET ) != 0 )
			continue;

		Vector vecDelta = pOther.pev.origin - pBody.pev.origin;
		if( vecDelta.z > BOT_MELEE_HEIGHT || vecDelta.z < -BOT_MELEE_HEIGHT )
			continue;
		float flDistance = Vector( vecDelta.x, vecDelta.y, 0.0f ).Length();
		if( flDistance > flNearest )
			continue;

		TraceResult tr;
		g_Utility.TraceLine( vecEyes, pOther.Center(), ignore_monsters, pBody.edict(), tr );
		if( tr.flFraction < 1.0f )
			continue;

		flNearest = flDistance;
		@pNearest = pOther;
	}

	if( pNearest !is null )
		return pNearest;

	TraceResult tr;
	g_Utility.TraceLine( vecEyes, vecEyes + BotForward( bot.flYaw ) * BOT_MELEE_RANGE,
	                     dont_ignore_monsters, pBody.edict(), tr );
	if( tr.flFraction < 1.0f && tr.pHit !is null )
	{
		CBaseEntity@ pHit = g_EntityFuncs.Instance( tr.pHit );
		if( pHit !is null && pHit !is pBody && pHit.pev.takedamage != DAMAGE_NO )
			return pHit;
	}

	return null;
}

/* The crowbar's own swing, from a bot: a short line, and a hull if it slipped past. */
void BotSwing( APBot@ bot, CBaseEntity@ pBody, CBaseEntity@ pVictim )
{
	Vector vecEyes = pBody.pev.origin + pBody.pev.view_ofs;
	Vector vecDir = pVictim !is null
		? ( pVictim.Center() - vecEyes ).Normalize()
		: BotForward( bot.flYaw );
	Vector vecEnd = vecEyes + vecDir * ( BOT_MELEE_RANGE + 16.0f );

	TraceResult tr;
	g_Utility.TraceLine( vecEyes, vecEnd, dont_ignore_monsters, pBody.edict(), tr );
	if( tr.flFraction >= 1.0f )
		g_Utility.TraceHull( vecEyes, vecEnd, dont_ignore_monsters, head_hull, pBody.edict(), tr );

	CBaseEntity@ pHit = ( tr.flFraction < 1.0f && tr.pHit !is null )
		? g_EntityFuncs.Instance( tr.pHit ) : null;

	if( pHit is null || pHit.pev.takedamage == DAMAGE_NO )
	{
		g_SoundSystem.EmitSoundDyn( pBody.edict(), CHAN_WEAPON, "weapons/cbar_miss1.wav",
			1.0f, ATTN_NORM, 0, 94 + Math.RandomLong( 0, 15 ) );
		return;
	}

	pHit.TakeDamage( pBody.pev, pBody.pev, BOT_CROWBAR_DAMAGE, DMG_CLUB );

	if( ( pHit.pev.flags & ( FL_CLIENT | FL_MONSTER ) ) != 0 )
	{
		array<string> body = { "weapons/cbar_hitbod1.wav", "weapons/cbar_hitbod2.wav",
		                       "weapons/cbar_hitbod3.wav" };
		g_SoundSystem.EmitSound( pBody.edict(), CHAN_WEAPON,
			body[ Math.RandomLong( 0, 2 ) ], 1.0f, ATTN_NORM );
	}
	else
	{
		g_SoundSystem.EmitSoundDyn( pBody.edict(), CHAN_WEAPON,
			Math.RandomLong( 0, 1 ) == 1 ? "weapons/cbar_hit1.wav" : "weapons/cbar_hit2.wav",
			1.0f, ATTN_NORM, 0, 98 + Math.RandomLong( 0, 3 ) );
	}
}

/*
* True while a swing is in progress, which tells the rest of the think that the
* view belongs to the fight. `flYaw` is turned to face the victim; the heading is
* left alone, so the bot carries on its way when the fight is over.
*/
bool BotMeleeThink( APBot@ bot, CBaseEntity@ pBody, float& inout flYaw )
{
	CBaseEntity@ pVictim = BotFindVictim( bot, pBody );

	if( bot.iMelee == BOT_MELEE_IDLE )
	{
		if( pVictim is null || g_Engine.time < bot.flMeleeNext )
			return false;
		if( bot.iSwingsLeft <= 0 )
			bot.iSwingsLeft = Math.RandomLong( BOT_BOUT_SWINGS_MIN, BOT_BOUT_SWINGS_MAX );
		bot.iMelee = BOT_MELEE_SWING;
		bot.flMeleeNext = g_Engine.time + BOT_SWING_TIME;
		bot.bHitPending = true;
		BotSequence( bot, pBody, BotDucked( pBody ) ? "crouch_shoot_crowbar" : "ref_shoot_crowbar", true );
	}

	if( pVictim !is null )
		flYaw = BotYawTo( pVictim.pev.origin - pBody.pev.origin );

	if( bot.iMelee == BOT_MELEE_SWING )
	{
		if( bot.bHitPending && g_Engine.time >= bot.flMeleeNext - BOT_SWING_TIME + BOT_SWING_HIT_AT )
		{
			bot.bHitPending = false;
			pBody.pev.angles.y = flYaw;
			BotSwing( bot, pBody, pVictim );
			--bot.iSwingsLeft;
		}
		if( g_Engine.time >= bot.flMeleeNext )
		{
			bot.iMelee = BOT_MELEE_RECOVER;
			bot.flMeleeNext = g_Engine.time + BOT_RECOVER_TIME;
		}
	}
	else if( bot.iMelee == BOT_MELEE_RECOVER && g_Engine.time >= bot.flMeleeNext )
	{
		bot.iMelee = BOT_MELEE_IDLE;
		bot.flMeleeNext = g_Engine.time;

		if( pVictim is null )
		{
			// It left first. The next bump is a new bout.
			bot.iSwingsLeft = 0;
			return false;
		}
		if( bot.iSwingsLeft > 0 )
			return true;  // straight into the next swing

		// Bout over: turn tail and run, and leave everything alone until clear.
		bot.iSwingsLeft = 0;
		bot.flYaw = Math.AngleMod( BotYawTo( pBody.pev.origin - pVictim.pev.origin )
			+ Math.RandomFloat( -BOT_FLEE_SPREAD, BOT_FLEE_SPREAD ) );
		bot.flMeleeNext = g_Engine.time + Math.RandomFloat( BOT_FLEE_MIN, BOT_FLEE_MAX );
		BotSampleProgress( bot, pBody );
		return false;
	}

	return bot.iMelee != BOT_MELEE_IDLE;
}

void BotJumpThink( APBot@ bot, CBaseEntity@ pBody, const Vector& in vecForward )
{
	bool bOnGround = ( pBody.pev.flags & FL_ONGROUND ) != 0;

	// A jump that never left the ground is somewhere a jump does not work.
	if( g_Engine.time >= bot.flJumpExpire )
	{
		bot.iMove = BOT_MOVE_WANDER;
		bot.bAirborne = false;
		if( BotCanStand( pBody ) )
			BotSetDucked( pBody, false );
		BotTurnAway( bot, pBody );
		return;
	}

	if( !bot.bAirborne )
	{
		if( !bOnGround )
		{
			// Off the floor: now tuck the legs up. Jump first and duck second,
			// never both at once.
			bot.bAirborne = true;
			BotSetDucked( pBody, true );
		}
		return;
	}

	if( bOnGround )
	{
		Vector vecTravel = BotFeet( pBody ) - bot.vecJumpStart;
		bool bGained = vecTravel.z > BOT_JUMP_GAIN_Z
			|| DotProduct( vecTravel, vecForward ) > BOT_JUMP_GAIN_FORWARD;
		bot.iMove = BOT_MOVE_WANDER;
		bot.bAirborne = false;
		if( BotCanStand( pBody ) )
			BotSetDucked( pBody, false );
		BotSampleProgress( bot, pBody );
		if( !bGained )
			BotTurnAway( bot, pBody );
	}
}

void BotMoveThink( APBot@ bot, CBaseEntity@ pBody, float flDt, float flYaw, bool bFighting )
{
	Vector vecForward = BotForward( bot.flYaw );

	if( bot.iMove == BOT_MOVE_JUMP )
	{
		BotJumpThink( bot, pBody, vecForward );
		return;
	}

	if( ( pBody.pev.flags & FL_ONGROUND ) == 0 )
		return;  // falling; the engine has it

	if( bFighting )
	{
		// Walk into whoever is being hit, and read nothing into having stopped.
		g_EngineFuncs.WalkMove( pBody.edict(), flYaw, BOT_RUN_SPEED * flDt, WALKMOVE_NORMAL );
		BotSampleProgress( bot, pBody );
		return;
	}

	// The trace sees a wall before the bot is pressed against it; the progress
	// sample catches what the trace is too coarse for.
	bool bStuck = false;
	if( g_Engine.time >= bot.flNextProgress )
	{
		Vector vecMoved = pBody.pev.origin - bot.vecLastOrigin;
		bStuck = Vector( vecMoved.x, vecMoved.y, 0.0f ).Length() < BOT_PROGRESS_DISTANCE;
		BotSampleProgress( bot, pBody );
	}

	if( !bStuck && BotPathClear( pBody, vecForward, false ) )
	{
		if( BotDucked( pBody ) && BotCanStand( pBody ) )
			BotSetDucked( pBody, false );
	}
	else if( !bStuck && BotPathClear( pBody, vecForward, true ) )
	{
		BotSetDucked( pBody, true );
	}
	else
	{
		// Up from standing, for the full height of the jump.
		if( BotDucked( pBody ) && BotCanStand( pBody ) )
			BotSetDucked( pBody, false );
		bot.iMove = BOT_MOVE_JUMP;
		bot.vecJumpStart = BotFeet( pBody );
		bot.bAirborne = false;
		bot.flJumpExpire = g_Engine.time + BOT_JUMP_TIMEOUT;
		pBody.pev.velocity = vecForward * BOT_RUN_SPEED + Vector( 0.0f, 0.0f, BOT_JUMP_SPEED );
		pBody.pev.flags &= ~FL_ONGROUND;
		// Off the floor, or the engine puts it straight back on it.
		g_EntityFuncs.SetOrigin( pBody, pBody.pev.origin + Vector( 0.0f, 0.0f, 1.0f ) );
		return;
	}

	g_EngineFuncs.WalkMove( pBody.edict(), bot.flYaw, BOT_RUN_SPEED * flDt, WALKMOVE_NORMAL );
}

/*
* One sequence for the whole body. A non-player gets no gait layer, so the legs
* and arms come from the same animation.
*/
void BotAnimate( APBot@ bot, CBaseEntity@ pBody, bool bMoving )
{
	if( bot.iMelee != BOT_MELEE_IDLE )
		return;  // the swing owns the animation until it is done

	bool bOnGround = ( pBody.pev.flags & FL_ONGROUND ) != 0;
	string szName;
	if( !bOnGround || bot.iMove == BOT_MOVE_JUMP )
		szName = "jump";
	else if( BotDucked( pBody ) )
		szName = bMoving ? "crawl" : "crouch_aim_crowbar";
	else
		szName = bMoving ? "run2" : "ref_aim_crowbar";

	BotSequence( bot, pBody, szName, false );
}

void BotSequence( APBot@ bot, CBaseEntity@ pBody, const string& in szName, bool bRestart )
{
	if( !bRestart && bot.szSequence == szName )
		return;

	CBaseAnimating@ pAnimating = cast<CBaseAnimating@>( pBody );
	if( pAnimating is null )
		return;

	int iSequence = pAnimating.LookupSequence( szName );
	if( iSequence < 0 )
		return;

	bot.szSequence = szName;
	pBody.pev.sequence = iSequence;
	pBody.pev.frame = 0;
	pAnimating.ResetSequenceInfo();
}
