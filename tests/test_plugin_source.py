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
