"""Static checks on the AngelScript sources.

Nothing here compiles anything -- the compiler is the game server, and the only
feedback it gives is a line number in the server console after a reload. These
are the cheap checks that would have caught real breakage before it got that
far, and every one of them is a bug that actually shipped.

They are deliberately blunt. A rule that reads the source as text and is
occasionally wrong is worth having when the alternative is a round trip through
a listen server.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parent.parent
PLUGIN_DIR = (
    REPO / "apworld" / "half_life_sven" / "plugin" / "plugins" / "archipelago"
)
CHECKDATA_PATH = (
    REPO / "apworld" / "half_life_sven" / "plugin"
    / "plugins" / "store" / "archipelago" / "checkdata.txt"
)
sys.path.insert(0, str(REPO / "apworld" / "half_life_sven"))

import plugin  # noqa: E402

ENTRY_POINT = "ap_main.as"


@pytest.fixture(scope="module")
def sources() -> dict[str, str]:
    return {
        path.name: path.read_text(encoding="utf-8")
        for path in sorted(PLUGIN_DIR.glob("*.as"))
    }


def function_body(text: str, name: str) -> str:
    """The body of one function, by brace matching from its opening line."""
    match = re.search(rf"^\w[\w:<>@&\s]*\b{name}\s*\([^)]*\)\s*$", text, re.M)
    assert match, f"{name} not found"
    start = text.index("{", match.end())
    depth = 0
    for index in range(start, len(text)):
        if text[index] == "{":
            depth += 1
        elif text[index] == "}":
            depth -= 1
            if depth == 0:
                return text[start:index]
    raise AssertionError(f"unbalanced braces in {name}")


# --- API calls that do not exist ------------------------------------------
#
# Each of these compiled fine in somebody's head and failed on the server. The
# API reference is https://sven-coop.github.io/, one path segment per class.

BANNED_CALLS = {
    # Ammo is read by index -- m_rgAmmo(i) or AmmoInventory(i) -- and the index
    # comes from the weapon's m_iPrimaryAmmoType. Only GiveAmmo takes a name.
    "GetAmmoIndex": "no such method; use pWeapon.m_iPrimaryAmmoType as the index",
    "ClearPendingHubReturn": "not a function; call SetPendingHubReturn( false )",
    "APLowercase": "no such helper; copy the string and call ToLowercase()",
}


def test_no_calls_to_functions_that_do_not_exist(sources: dict[str, str]) -> None:
    for name, text in sources.items():
        for banned, why in BANNED_CALLS.items():
            assert f"{banned}(" not in text, f"{name}: {banned} -- {why}"


def test_arrays_are_returned_by_value(sources: dict[str, str]) -> None:
    """`array<T>@ F()` returns a handle to a local, and a by-value result cannot
    be assigned to a local handle. The plugin returns arrays by value."""
    for name, text in sources.items():
        offenders = re.findall(r"^array<[^>]+>@\s+(\w+)\s*\(", text, re.M)
        assert not offenders, f"{name}: {offenders} should return by value"


def test_dictionaries_are_read_with_get(sources: dict[str, str]) -> None:
    """Indexing a dictionary yields a dictionaryValue, which a handle cast
    cannot take. `dict.get( key, @handle )` is the way in."""
    for name, text in sources.items():
        offenders = re.findall(r"cast<[^>]+>\(\s*\w+\[", text)
        assert not offenders, f"{name}: cast of a dictionary index -- use get()"


# --- The two halves have to agree -----------------------------------------


def test_every_script_is_included_by_the_entry_point(sources: dict[str, str]) -> None:
    """A file nobody includes is a file the server never compiles, and its
    absence shows up as a missing function rather than as a missing file."""
    included = set(re.findall(r'#include\s+"([^"]+)"', sources[ENTRY_POINT]))
    for name in sources:
        if name == ENTRY_POINT:
            continue
        assert name[:-3] in included, f"{name} is not #included by {ENTRY_POINT}"


def test_every_script_is_in_the_install_manifest(sources: dict[str, str]) -> None:
    """Otherwise /install copies a plugin that cannot compile."""
    manifest = {Path(entry).name for entry in plugin.PLUGIN_FILES}
    for name in sources:
        assert name in manifest, f"{name} is missing from plugin.PLUGIN_FILES"


def test_record_guards_match_what_the_generator_emits() -> None:
    """Every checkdata record must carry at least the fields the parser demands.

    The parser guards each record type with `parts.length() >= N`, and a record
    emitted with fewer fields than that is silently skipped -- no error, no log
    line, just a table that is quietly empty. Adding a field to the generator
    without widening the guard fails the other way round, which is harmless but
    means the new field is being ignored.
    """
    parser = (PLUGIN_DIR / "ap_state.as").read_text(encoding="utf-8")
    guards = {
        letter: int(count)
        for letter, count in re.findall(
            r'parts\[0\] == "([A-Z])" && parts\.length\(\) >= (\d+)', parser
        )
    }
    assert guards, "no record guards found; has the parser been rewritten?"

    widths: dict[str, int] = {}
    for line in CHECKDATA_PATH.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        fields = line.split("|")
        widths[fields[0]] = min(widths.get(fields[0], 99), len(fields))

    for letter, needed in guards.items():
        if letter not in widths:
            continue  # a record type this build happens not to emit
        assert widths[letter] >= needed, (
            f"`{letter}` records carry {widths[letter]} fields, "
            f"but the parser skips anything under {needed}"
        )


# --- Behaviour that regressed once ----------------------------------------


def test_a_death_only_wipes_the_lobby_when_deathlink_is_on(
    sources: dict[str, str],
) -> None:
    """The wipe *is* the DeathLink. Only the report to the client is meant to be
    unconditional, and for a while the wipe was too -- so every death gibbed the
    lobby in seeds that had the option switched off."""
    body = function_body(sources["ap_deathlink.as"], "PlayerKilled")
    gate = body.find("g_State.deathLink")
    wipe = body.find("WipeLobby(")
    assert gate >= 0, "PlayerKilled no longer checks whether DeathLink is on"
    assert wipe >= 0, "PlayerKilled no longer wipes the lobby at all"
    assert gate < wipe, "the DeathLink check must come before the wipe"


def test_the_arcade_map_is_exempt_from_the_weapon_gating(
    sources: dict[str, str],
) -> None:
    """Suspension hands out its own class loadouts and its checks are sections
    and medals. Gating weapons there left a Sniper with no rifle, and the weapon
    checks are campaign-wide, so a class loadout could send a campaign check."""
    for name, function in (
        ("ap_items.as", "ApplyLoadout"),
        ("ap_items.as", "PickupCanCollect"),
        ("ap_locations.as", "SweepWeaponPickups"),
    ):
        body = function_body(sources[name], function)
        assert "SuspensionManaged()" in body, (
            f"{name}: {function} no longer stands down on the arcade map"
        )


def test_loadout_ammo_is_only_set_for_weapons_just_granted(
    sources: dict[str, str],
) -> None:
    """ApplyLoadout runs from the one-second sweep as well as from a spawn.

    Topping up every weapon held, rather than only the ones this call handed
    over, refills whatever the player has been firing once a second for as long
    as they stand there -- infinite ammo, with a pickup sound each time.
    """
    text = sources["ap_items.as"]
    body = function_body(text, "ApplyLoadout")

    calls = re.findall(r"SetLoadoutAmmo\(([^)]*)\)", body)
    assert calls, "ApplyLoadout no longer sets the loadout's ammo"
    for arguments in calls:
        assert "," in arguments, (
            "SetLoadoutAmmo must be passed the list of weapons this call "
            f"granted, not just the player: got ({arguments.strip()})"
        )


def test_the_loadout_checks_every_name_a_weapon_has(sources: dict[str, str]) -> None:
    """Three items are one gun under two classnames.

    Glock is `weapon_9mmhandgun` and `weapon_glock`, MP5 is `weapon_9mmAR` and
    `weapon_m16`, SAW is `weapon_m249` and `weapon_saw`. Asking `HasItem` about
    one name while the player carries the other answers no, so the loadout hands
    the gun over again every sweep -- and every grant brings a clip of ammo.
    """
    body = function_body(sources["ap_items.as"], "ApplyLoadout")
    assert "HasWeaponUnderAnyName(" in body, (
        "the grant loop is back to asking about one classname at a time"
    )


def test_aliased_weapons_are_still_aliased(sources: dict[str, str]) -> None:
    """If the data ever stops pairing them, the guard above has nothing to do
    and the test that guards it would pass while meaning nothing."""
    pairs: dict[str, list[str]] = {}
    for line in CHECKDATA_PATH.read_text(encoding="utf-8").splitlines():
        if line.startswith("K|"):
            _, classname, item = line.split("|")[:3]
            pairs.setdefault(item, []).append(classname)

    aliased = {item: names for item, names in pairs.items() if len(names) > 1}
    assert aliased, "no weapon has two classnames any more; is the guard still needed?"


def test_the_weapon_sweep_ignores_weapons_being_carried(
    sources: dict[str, str],
) -> None:
    """A carried weapon is still an entity of its classname and its origin is
    the player's, so the sweep sent a check for holding one anywhere in the map
    it was anchored to."""
    body = function_body(sources["ap_locations.as"], "AnyPlayerNear")
    assert "WeaponIsHeld(" in body, "the sweep counts weapons in players' hands"


def test_a_granted_weapon_does_not_send_its_pickup_check(
    sources: dict[str, str],
) -> None:
    """`GiveNamedItem` builds the weapon and touches the player with it before it
    returns, so the loadout's own grant arrives at the pickup hook looking like a
    weapon found on the floor. Being handed the Shotgun on arrival in Office
    Complex sent First Shotgun without the player going near the map's copy.

    Two guards, because there are two ways in: our own grants raise a flag, and
    anything else built at the player's own origin (a map .cfg loadout,
    game_player_equip) is spotted by where it is.
    """
    text = sources["ap_items.as"]

    grant = function_body(text, "ApplyLoadout")
    assert re.search(
        r"g_bHandingOver\s*=\s*true;\s*[^;]*GiveNamedItem[^;]*;\s*"
        r"g_bHandingOver\s*=\s*false;",
        grant,
    ), "ApplyLoadout no longer flags its own grants as hand-overs"

    hook = function_body(text, "PickupCanCollect")
    match = re.search(r"RegisterPickupCheck\(", hook)
    assert match, "the pickup hook no longer sends checks at all"
    assert "PickupWasHandedOver(" in hook[: match.start()], (
        "the pickup hook sends a check for a weapon it was handed"
    )

    handover = function_body(text, "PickupWasHandedOver")
    assert "g_bHandingOver" in handover, "the hand-over flag is not read"
    assert "pev.origin" in handover, (
        "grants from outside the plugin are no longer caught by their origin"
    )


def test_a_released_completion_marks_the_mission_complete(
    sources: dict[str, str],
) -> None:
    """A mission's completion is a location, so it can arrive from the server
    with the mission never played -- released, collected, or sent by hand.

    `!ap` worked its status out from whether every location in the mission had
    been found, which a released completion does not make true, so the mission
    went on reading "unlocked" while the seal it feeds had already counted it.
    """
    text = sources["ap_hub.as"]

    status = function_body(text, "ShowStatus")
    assert "ChapterFinished(" in status, (
        "the mission list is back to judging completion by all-found alone"
    )

    finished = function_body(text, "ChapterFinished")
    assert "ChapterCompletionFound(" in finished, (
        "ChapterFinished no longer looks at the mission's own completion check"
    )
    assert "ChapterAllFound(" in finished, (
        "ChapterFinished no longer covers a mission emptied without a completion"
    )

    completion = function_body(text, "ChapterCompletionFound")
    assert "TRIGGER_CHAPTER_COMPLETE" in completion
    assert "LocationFound(" in completion, (
        "ChapterCompletionFound does not ask whether the check was sent"
    )


def test_a_warp_out_of_a_mission_does_not_queue_a_hub_return(
    sources: dict[str, str],
) -> None:
    """The bounce belongs to the campaign running one mission into the next.

    It was armed for every transition that left a mission for a map outside it,
    ours included, so `!warp` from inside one mission to another arrived and was
    sent straight back to the hub. A transition we issued is a decision, which
    is the same thing `g_bSelfChange` already says about the completion above
    it, and MapStart lets a map we asked for outrank a pending return.
    """
    change = function_body(sources["ap_hub.as"], "MapChange")
    arm = re.search(r"if\s*\(([^)]*)\)\s*\n\s*SetPendingHubReturn\(\s*true\s*\)", change)
    assert arm, "MapChange no longer arms the hub return in a readable shape"
    assert "g_bSelfChange" in arm.group(1), (
        "the hub return is armed for transitions we issued ourselves, so a warp "
        "into another mission bounces straight back"
    )

    start = function_body(sources["ap_main.as"], "MapStart")
    consume = re.search(
        r"bool bDeliberate[^\n]*\n(?:.|\n)*?ConsumePendingHubReturn\(\)", start
    )
    assert consume, "MapStart no longer decides deliberateness before the bounce"
    assert re.search(
        r"ConsumePendingHubReturn\(\)\s*&&\s*!bDeliberate", start
    ), "a pending hub return still outranks the map the player asked for"


def test_the_run_resets_on_the_slot_rather_than_the_session(
    sources: dict[str, str],
) -> None:
    """Reconnecting has to be safe in both directions.

    The session id is minted per client launch, so it fired when the same slot
    reconnected from a restarted client -- a blip that should move nobody -- and
    stayed put when a different slot was connected from the client already
    running, which is the case that makes every remembered check wrong.
    """
    body = function_body(sources["ap_bridge.as"], "BridgePoll")
    reset = body.find("ResetRunState()")
    assert reset >= 0, "the snapshot no longer resets the run state at all"
    assert "g_szSlot" in body, "the snapshot does not track which slot is connected"

    # An empty slot is a disconnected client, and must not read as a new run.
    assert re.search(r"szSlot\.Length\(\)\s*>\s*0\s*&&\s*szSlot\s*!=\s*g_szSlot", body), (
        "a disconnected client's empty slot can reset the run"
    )


def test_a_locked_vote_button_is_disarmed_rather_than_removed(
    sources: dict[str, str],
) -> None:
    """Going non-solid was not enough in game: the vote still went through. It
    also refused silently, because a button that is not there cannot be pressed
    and so cannot be answered.

    The button is now left exactly as the map built it, solid and drawn, so the
    use trace lands on it and PlayerUse can say why -- and its `target` is taken
    away, which is what leaves the press harmless. The whole set of locks is
    reasserted on a timer because the map kills and resets its own entities.
    """
    text = sources["ap_suspension.as"]

    sync = function_body(text, "SuspensionSyncLocks")
    assert "SuspensionSetVoteLive(" in sync, (
        "the vote lock is back to solidity alone"
    )
    assert "SuspensionSetSolid(" not in sync, (
        "a hidden button refuses silently; leave the map's own solidity alone"
    )

    refusal = function_body(text, "SuspensionBlockUse")
    assert "is locked" in refusal, "the press is no longer answered"

    live = function_body(text, "SuspensionSetVoteLive")
    assert "pev.target" in live, "the button's wiring is not what is being cut"
    assert "voteTargetKnown" in live, (
        "unlocking cannot restore a target it never remembered"
    )

    think = function_body(text, "SuspensionThink")
    assert "SuspensionSyncLocks()" in think, (
        "the locks are applied once and left at the map's mercy"
    )


def test_the_vote_wiring_is_only_forgotten_on_a_map_load(
    sources: dict[str, str],
) -> None:
    """A locked button has already had its target blanked, so forgetting what it
    was at any moment other than a fresh map load loses the only record of what
    to put back when the item arrives."""
    text = sources["ap_suspension.as"]
    assert "voteTargetKnown = false" not in function_body(text, "SuspensionResetRound")
    assert "voteTargetKnown = false" in function_body(text, "SuspensionMapStart")


def test_the_map_entities_are_never_relinked(sources: dict[str, str]) -> None:
    """`SetOrigin` on a map entity asks the engine to link it again, and linking
    revalidates it: an entity that is SOLID_BSP without MOVETYPE_PUSH is fatal
    there, not cosmetic. Relinking the vote buttons to make a solidity change
    take printed `SOLID_BSP WITHOUT MOVE_PUSH` and killed the server on a
    respawn. Players are fine to move; the map's own entities are not."""
    text = sources["ap_suspension.as"]
    for name in ("SuspensionSyncLocks", "SuspensionSetPortalOpen", "SuspensionSetSealPart"):
        assert "SetOrigin(" not in function_body(text, name), (
            f"{name} relinks a map entity"
        )


def test_solid_bsp_is_only_ever_given_to_a_pusher(sources: dict[str, str]) -> None:
    """The engine checks `solid` against `movetype` every time it links an
    entity, and SOLID_BSP on anything but a MOVETYPE_PUSH entity is a fatal
    error, not a warning. The Juggernaut's seal is a `func_wall_toggle` *and* a
    `trigger_hurt`, and sealing gave both of them SOLID_BSP -- which killed the
    server on a respawn in the lobby, long after the seal was set."""
    text = sources["ap_suspension.as"]

    for name, body in (
        (name, function_body(text, name))
        for name in ("SuspensionSetSealPart", "SuspensionSetPortalOpen", "SuspensionSyncLocks")
    ):
        assert "SOLID_BSP" not in body, (
            f"{name} hands out SOLID_BSP directly; go through SuspensionSolidFor"
        )

    guard = function_body(text, "SuspensionSolidFor")
    assert "MOVETYPE_PUSH" in guard, "the pusher test is gone"
    assert "SOLID_TRIGGER" in guard, "a non-pusher has nothing safe to be switched on as"


def test_a_locked_class_booth_is_walled_off_rather_than_disabled(
    sources: dict[str, str],
) -> None:
    """Three things have failed here. Switching the teleport off opened a room
    whose only way out was the teleport, and players stuck; sending them to a
    spawn point instead put them inside a wall; making the trigger itself solid
    is the crash above. A wall of our own, built by the engine from the portal's
    brush, is none of those."""
    body = function_body(sources["ap_suspension.as"], "SuspensionSetPortalOpen")

    assert '"func_wall"' in body, "the block is no longer an entity the engine builds"
    assert "pev.model" in body, "the wall is not built from the portal's own brush"
    assert "g_EntityFuncs.Remove(" in body, "unlocking leaves the wall standing"


def test_a_locked_booth_says_why(sources: dict[str, str]) -> None:
    """A wall that refuses silently reads as a broken map. The message is the
    same sentence and the same centre print a locked weapon gets."""
    body = function_body(sources["ap_suspension.as"], "SuspensionWarnLockedBooths")
    assert "HUD_PRINTCENTER" in body, "the booth refusal is not where the weapon one is"
    assert "have not found the" in body, "the wording drifted from the weapon refusal"
    assert "SUS_REFUSAL_INTERVAL" in body, "the message repeats every think"


def test_the_arcade_answers_to_part_of_its_name(sources: dict[str, str]) -> None:
    """`!warp` matches missions on any part of their name, but the arcade map was
    only ever compared for equality, so it alone had to be spelled out in full.
    It is not a chapter, so it is never in `matches` and needs its own test
    alongside them -- including in the "be more specific" list, or a query that
    matched both would silently pick one."""
    body = function_body(sources["ap_hub.as"], "WarpToQuery")
    assert "ArcadeMatchesQuery(" in body, (
        "the arcade is back to exact spelling only"
    )
    assert re.search(r"matches\.length\(\) == 1 && !bArcade", body), (
        "a single mission match wins outright even when the arcade matched too"
    )

    match = function_body(sources["ap_hub.as"], "ArcadeMatchesQuery")
    assert "Find(" in match, "the arcade is still matched by equality"
    assert "g_Suspension.enabled" in match, (
        "a seed without the arcade offers it anyway"
    )
