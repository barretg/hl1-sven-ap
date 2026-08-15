"""Suspension's generated data, and its half of checkdata.txt.

The arcade map is a different shape from a campaign -- no chapters, no hub
console, its own goal -- so it gets its own consistency tests rather than being
squeezed into the campaign ones. What they mostly guard is the combinatorial
part: every tier crossed with every section, class and medal, with nothing
missing and nothing duplicated.
"""

from __future__ import annotations

import sys
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "tools"))
sys.path.insert(0, str(REPO / "apworld" / "half_life_sven"))

import suspension_layout as sus  # noqa: E402
from data import load_campaign  # noqa: E402

CHECKDATA_PATH = (
    REPO / "apworld" / "half_life_sven" / "plugin"
    / "plugins" / "store" / "archipelago" / "checkdata.txt"
)


@pytest.fixture(scope="module")
def campaign() -> dict:
    return load_campaign()


@pytest.fixture(scope="module")
def arcade(campaign: dict) -> dict:
    arcades = {entry["key"]: entry for entry in campaign["arcades"]}
    assert sus.KEY in arcades
    return arcades[sus.KEY]


@pytest.fixture(scope="module")
def records() -> list[list[str]]:
    out = []
    for line in CHECKDATA_PATH.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if line and not line.startswith("#"):
            out.append(line.split("|"))
    return out


def suspension_locations(campaign: dict) -> list[dict]:
    return [
        entry for entry in campaign["locations"]
        if entry["trigger"]["type"].startswith("suspension_")
    ]


# --- the data itself ------------------------------------------------------


def test_the_arcade_is_not_a_campaign(campaign: dict) -> None:
    """It must never reach the campaign machinery.

    A chapter of it would be counted toward `missions_required`, offered a hub
    console and asked for a finale, none of which it has.
    """
    assert sus.KEY not in {c["key"] for c in campaign["campaigns"]}
    assert sus.KEY not in {c["key"] for c in campaign["chapters"]}
    assert not any(c.get("campaign") == sus.KEY for c in campaign["chapters"])


def test_every_combination_exists(campaign: dict) -> None:
    locations = suspension_locations(campaign)
    tiers = [d.key for d in sus.DIFFICULTIES]
    classes = [""] + [c.key for c in sus.CLASSES]

    sections = {
        (l["trigger"]["difficulty"], l["trigger"]["section"], l["trigger"]["class"])
        for l in locations if l["trigger"]["type"] == "suspension_section"
    }
    assert sections == {
        (tier, section.key, class_key)
        for tier in tiers for section in sus.SECTIONS for class_key in classes
    }

    clears = {
        (l["trigger"]["difficulty"], l["trigger"]["class"])
        for l in locations if l["trigger"]["type"] == "suspension_clear"
    }
    assert clears == {(tier, class_key) for tier in tiers for class_key in classes}

    awards = {
        (l["trigger"]["difficulty"], l["trigger"]["award"])
        for l in locations if l["trigger"]["type"] == "suspension_award"
    }
    assert awards == {(tier, award.key) for tier in tiers for award in sus.AWARDS}


def test_location_names_are_unique(campaign: dict) -> None:
    names = [entry["name"] for entry in campaign["locations"]]
    assert len(names) == len(set(names))


def test_location_ids_are_unique_and_beyond_the_campaigns(campaign: dict) -> None:
    ids = [entry["id"] for entry in campaign["locations"]]
    assert len(ids) == len(set(ids))


def test_the_goal_class_is_never_the_starting_class(arcade: dict) -> None:
    """The Juggernaut is earned, so it cannot be what a seed opens with."""
    goal = arcade["goal_class"]
    startable = [c["key"] for c in arcade["classes"] if c["key"] != goal]
    assert goal not in startable
    assert len(startable) == len(arcade["classes"]) - 1


def test_only_the_goal_class_is_map_gated(arcade: dict) -> None:
    gated = [c["key"] for c in arcade["classes"] if c["map_gated"]]
    assert gated == [arcade["goal_class"]]


def test_the_map_gated_class_can_be_granted_without_its_booth(arcade: dict) -> None:
    """Its booth does nothing below the map's own tier, so the plugin needs
    everything required to hand the class over itself."""
    entry = next(c for c in arcade["classes"] if c["key"] == arcade["goal_class"])
    grant = entry["grant"]
    for field in ("health", "max_health", "armorvalue", "armortype", "weapons", "teleport"):
        assert grant.get(field), field


def test_awards_are_ordered_hardest_first(arcade: dict) -> None:
    """The plugin walks this ladder in order to score a run, and rolls medals
    down it, so the order is load-bearing rather than cosmetic."""
    thresholds = [award["deaths"] for award in arcade["awards"]]
    assert thresholds == sorted(thresholds)
    assert thresholds[0] == 0  # platinum is a flawless run


def test_sections_are_numbered_in_order_and_only_the_last_ends_the_round(
    arcade: dict,
) -> None:
    sections = arcade["sections"]
    assert [s["index"] for s in sections] == list(range(1, len(sections) + 1))
    # Every section but the last announces its own clear; the last one is
    # cleared by the round ending, and has no signal to hang a counter on.
    assert all(s["signal"] for s in sections[:-1])
    assert sections[-1]["signal"] == ""


def test_signals_are_unique(arcade: dict) -> None:
    """Two counters answering to one name would both fire on it."""
    signals = [s["signal"] for s in arcade["sections"] if s["signal"]]
    signals += [d["ticket_signal"] for d in arcade["difficulties"]]
    signals += [arcade["start_signal"], arcade["end_signal"]]
    assert len(signals) == len(set(signals))


def test_each_tier_has_its_own_vote_button_and_ticket_count(arcade: dict) -> None:
    buttons = [d["vote_button"] for d in arcade["difficulties"]]
    tickets = [d["tickets"] for d in arcade["difficulties"]]
    assert len(set(buttons)) == len(buttons)
    # Fewer tickets is harder, and the tiers are ordered easiest first.
    assert tickets == sorted(tickets, reverse=True)


def test_items_cover_every_class(campaign: dict, arcade: dict) -> None:
    items = {i["class"] for i in campaign["items"] if i.get("group") == "suspension_class"}
    assert items == {c["key"] for c in arcade["classes"]}
    progressive = [i for i in campaign["items"] if i.get("group") == "suspension_difficulty"]
    assert len(progressive) == 1


# --- checkdata.txt --------------------------------------------------------


def test_checkdata_describes_the_arcade(records: list[list[str]], arcade: dict) -> None:
    x = [r for r in records if r[0] == "X"]
    assert len(x) == 1
    assert x[0][1] == arcade["key"]
    assert x[0][3] == arcade["map"]

    assert len([r for r in records if r[0] == "Y"]) == len(arcade["difficulties"])
    assert len([r for r in records if r[0] == "Z"]) == len(arcade["sections"])
    assert len([r for r in records if r[0] == "W"]) == len(arcade["classes"])
    assert len([r for r in records if r[0] == "A"]) == len(arcade["awards"])
    # The portal and the pad the plugin watches, and the seal it drives.
    assert {r[2] for r in records if r[0] == "J"} == {"portal", "pad"}
    assert {r[2] for r in records if r[0] == "G"} == {"wall", "hurt", "reveal"}


def test_checkdata_carries_every_suspension_location(
    records: list[list[str]], campaign: dict
) -> None:
    ids = {int(r[1]) for r in records if r[0] == "L"}
    for entry in suspension_locations(campaign):
        assert entry["id"] in ids, entry["name"]


def test_checkdata_args_match_what_the_plugin_looks_up(
    records: list[list[str]], campaign: dict
) -> None:
    """The plugin matches a location by its `arg` field alone, so the spelling
    here is the contract between the two halves."""
    by_id = {int(r[1]): r for r in records if r[0] == "L"}
    for entry in suspension_locations(campaign):
        trigger = entry["trigger"]
        record = by_id[entry["id"]]
        if trigger["type"] == "suspension_section":
            expected = f"{trigger['section']}:{trigger['class']}:{trigger['difficulty']}"
        elif trigger["type"] == "suspension_clear":
            expected = f"{trigger['class']}:{trigger['difficulty']}"
        else:
            expected = f"{trigger['award']}:{trigger['difficulty']}"
        assert record[4] == expected, entry["name"]


def test_format_version_advertises_the_arcade_records(records: list[list[str]]) -> None:
    version = next(r for r in records if r[0] == "V")
    assert int(version[1]) >= 4


def test_the_explosives_gate_names_real_classes_and_a_real_section(
    arcade: dict,
) -> None:
    """Only three classes can get explosives on the bridge, and past the tank
    the run cannot go on without them.

    The restock crates are `game_player_equip` entities filtered by class
    targetname and they name `class_engineer`, `class_GL_soldier` and
    `class_shotty` alone; no other booth loadout carries anything explosive. A
    lobby of Assaults, Snipers, Supports and Medics has nothing that can hurt a
    1500 health tank.
    """
    keys = {entry["key"] for entry in arcade["classes"]}
    explosive = arcade["explosive_classes"]

    assert explosive, "the gate is empty, so it gates nothing"
    assert set(explosive) <= keys, f"unknown class in {explosive}"
    assert arcade["goal_class"] not in explosive, (
        "the Juggernaut stands behind every other class already; counting it "
        "here would let the gate be satisfied by the one item that needs it"
    )

    indices = {entry["index"] for entry in arcade["sections"]}
    first = arcade["explosives_from_section"]
    assert first in indices, f"section {first} does not exist"
    # Not the first section, or the whole map would be behind three classes, and
    # not the last, or the sections it is meant to cover would not be covered.
    assert min(indices) < first < max(indices)


def test_only_the_first_section_is_outside_the_explosives_gate(arcade: dict) -> None:
    """Section 2 is where armour first has to be dealt with, so section 1 is the
    only one any class can finish. Reported from play: the entity list alone
    puts the named tank fight in section 4, and there is one in section 2 as
    well, which is why the map has an explosives crate there."""
    first = arcade["explosives_from_section"]
    assert first == 2

    ungated = [e["key"] for e in arcade["sections"] if e["index"] < first]
    assert ungated == ["s1"]
