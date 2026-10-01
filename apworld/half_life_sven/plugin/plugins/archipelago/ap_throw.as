/*
* Melee Throw.
*
* Once the item arrives, secondary fire throws the crowbar: which is also
* Opposing Force's combat knife and They Hunger's umbrella, since those are the
* crowbar wearing another model. It hits four times as hard as a swing, lands on
* the floor, and can be walked over to pick back up; otherwise it comes back by
* itself after ten seconds.
*
* Built out of the pieces Butterfingers already uses. The throw is a drop with a
* great deal of velocity behind it, the ten seconds is the same withholding that
* stops the loadout sweep handing the weapon straight back, and the copy in
* flight is a trap drop, so neither its landing nor walking over it sends the
* map's weapon check. What is new is the hit: a thrown weapon has no touch of its
* own that a plugin can reach, so its path is traced on the fast timer instead.
*/

const string MELEE_THROW_ITEM = "Melee Throw";
const string THROWN_CLASSNAME = "weapon_crowbar";

// How long before a thrown crowbar comes back on its own.
const float MELEE_THROW_RETURN = 10.0f;

// How hard it leaves the hand, and how much of that is lift. Faster than
// Half-Life: Anniversary's 1100: tuned up for Sven.
const float MELEE_THROW_SPEED = 1300.0f;
const float MELEE_THROW_LIFT = 100.0f;

// The share of world gravity it falls under while thrown: a longer, flatter arc
// than a dropped item's at the same speed.
const float MELEE_THROW_GRAVITY = 0.6f;

// Only while it is still flying fast enough to hurt. Below this it is sliding
// to a stop, and a crowbar at walking pace hits nobody.
const float MELEE_THROW_LETHAL_SPEED = 250.0f;

// 4x a swing's worth when the skill cvar cannot be read.
const float MELEE_THROW_DAMAGE = 60.0f;

class APThrown
{
	EHandle hWeapon;
	EHandle hThrower;
	Vector vecLast;
	float flThrownAt;
	bool bHit = false;
}

array<APThrown@> g_Thrown;

bool MeleeThrowOwned()
{
	return g_State.ItemUnlocked( MELEE_THROW_ITEM );
}

float MeleeThrowDamage()
{
	float flDamage = g_EngineFuncs.CVarGetFloat( "sk_plr_crowbar" ) * 4.0f;
	return flDamage > 0.0f ? flDamage : MELEE_THROW_DAMAGE;
}

/*
* Per frame, per player, from PlayerPreThink: throw on a fresh press of
* secondary fire with the crowbar out.
*
* A fresh press, not a held button, or every frame of holding it would try again.
* Nothing at all on the hub or the arcade map, which are outside the randomiser
* and keep their own rules for what secondary fire does.
*/
void MeleeThrowThink( CBasePlayer@ pPlayer )
{
	if( ( pPlayer.pev.button & IN_ATTACK2 ) == 0 || ( pPlayer.pev.oldbuttons & IN_ATTACK2 ) != 0 )
		return;

	if( g_CurrentChapter is null || SuspensionManaged() || !MeleeThrowOwned() )
		return;

	CBasePlayerItem@ pActive = cast<CBasePlayerItem@>( pPlayer.m_hActiveItem.GetEntity() );
	if( pActive is null || pActive.GetClassname() != THROWN_CLASSNAME )
		return;

	ThrowMelee( pPlayer );
}

void ThrowMelee( CBasePlayer@ pPlayer )
{
	// Booked first, for the same reason Butterfingers books first: the loadout
	// sweep would otherwise put it back in their hand within the second.
	WithholdWeapon( pPlayer, THROWN_CLASSNAME, MELEE_THROW_RETURN );

	CBaseEntity@ pThrown = ScriptDropItem( pPlayer, THROWN_CLASSNAME );
	if( pThrown is null )
	{
		ReleaseWeapon( pPlayer, THROWN_CLASSNAME );
		return;
	}

	Math.MakeVectors( pPlayer.pev.v_angle );
	Vector vecStart = pPlayer.GetGunPosition() + g_Engine.v_forward * 16.0f;

	g_EntityFuncs.SetOrigin( pThrown, vecStart );
	pThrown.pev.velocity = g_Engine.v_forward * MELEE_THROW_SPEED
		+ Vector( 0.0f, 0.0f, MELEE_THROW_LIFT );
	// MOVETYPE_TOSS reads it; ThrownThink puts it back once picked up.
	pThrown.pev.gravity = MELEE_THROW_GRAVITY;
	// Tumbling end over end, which is how everyone expects a thrown crowbar to
	// fly and what makes it read as a throw rather than a drop.
	pThrown.pev.avelocity = Vector( -720.0f, 0.0f, 0.0f );

	RegisterTrapDrop( pThrown );

	APThrown thrown;
	thrown.hWeapon = EHandle( pThrown );
	thrown.hThrower = EHandle( pPlayer );
	thrown.vecLast = vecStart;
	thrown.flThrownAt = g_Engine.time;
	g_Thrown.insertLast( @thrown );

	g_SoundSystem.EmitSoundDyn( pPlayer.edict(), CHAN_WEAPON, "weapons/cbar_miss1.wav",
		1.0f, ATTN_NORM, 0, 94 + Math.RandomLong( 0, 15 ) );
}

/*
* On the fast timer: move each thrown crowbar's hit test along its path, and
* bring back the ones nobody collected.
*/
void ThrownThink()
{
	for( uint i = g_Thrown.length(); i > 0; --i )
	{
		APThrown@ pThrown = g_Thrown[i - 1];
		CBaseEntity@ pWeapon = pThrown.hWeapon.GetEntity();
		CBasePlayer@ pThrower = cast<CBasePlayer@>( pThrown.hThrower.GetEntity() );

		// Picked back up, or gone with the map.
		if( pWeapon is null || WeaponIsHeld( pWeapon ) )
		{
			// Back to full gravity, so a later drop of the same crowbar falls
			// like any other weapon. 0 is the engine's "unset", which reads as 1.
			if( pWeapon !is null )
				pWeapon.pev.gravity = 0.0f;
			if( pThrower !is null )
				ReleaseWeapon( pThrower, THROWN_CLASSNAME );
			g_Thrown.removeAt( i - 1 );
			continue;
		}

		// Uncollected: take the floor copy away, and the withholding ends on the
		// same tick, so the sweep hands the thrower a fresh one.
		if( g_Engine.time - pThrown.flThrownAt >= MELEE_THROW_RETURN )
		{
			g_EntityFuncs.Remove( pWeapon );
			if( pThrower !is null )
			{
				ReleaseWeapon( pThrower, THROWN_CLASSNAME );
				g_PlayerFuncs.ClientPrint( pThrower, HUD_PRINTCENTER,
					"Your crowbar comes back to you." );
			}
			g_Thrown.removeAt( i - 1 );
			continue;
		}

		Vector vecNow = pWeapon.pev.origin;

		if( !pThrown.bHit && pThrower !is null
		    && pWeapon.pev.velocity.Length() >= MELEE_THROW_LETHAL_SPEED )
		{
			TraceResult tr;
			g_Utility.TraceLine( pThrown.vecLast, vecNow, dont_ignore_monsters,
			                     pThrower.edict(), tr );

			CBaseEntity@ pHit = tr.pHit !is null ? g_EntityFuncs.Instance( tr.pHit ) : null;
			if( pHit !is null && pHit !is pWeapon && pHit.pev.takedamage != DAMAGE_NO )
			{
				pThrown.bHit = true;
				// The thrower is the attacker, so the game's own friendly fire
				// rules decide whether a teammate can be hit by it.
				pHit.TakeDamage( pWeapon.pev, pThrower.pev, MeleeThrowDamage(), DMG_CLUB );
				g_SoundSystem.EmitSoundDyn( pWeapon.edict(), CHAN_WEAPON,
					"weapons/cbar_hitbod1.wav", 1.0f, ATTN_NORM, 0, PITCH_NORM );
				// Spent: it drops where it struck rather than carrying on through.
				pWeapon.pev.velocity = pWeapon.pev.velocity * 0.1f;
			}
		}

		pThrown.vecLast = vecNow;
	}
}

void ClearThrown()
{
	g_Thrown.resize( 0 );
}
