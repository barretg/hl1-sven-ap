"""Location and item ids must never come to mean something else.

Ids used to be positional, so toggling which location types are generated
reassigned all of them. An existing seed then resolved a check to whatever
location had moved into that slot, which looks exactly like the plugin sending
random checks on level change.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "tools"))

from build_campaign_data import IdRegistry, location_key  # noqa: E402

sys.path.insert(0, str(REPO / "apworld" / "half_life_sven"))

from data import load_campaign  # noqa: E402

IDS_PATH = REPO / "apworld" / "half_life_sven" / "data" / "ids.json"
CHECKDATA_PATH = (
    REPO / "apworld" / "half_life_sven" / "plugin"
    / "plugins" / "store" / "archipelago" / "checkdata.txt"
)


@pytest.fixture(scope="module")
def campaign() -> dict:
    return load_campaign()


@pytest.fixture(scope="module")
def registry_data() -> dict:
    return json.loads(IDS_PATH.read_text(encoding="utf-8"))


def test_registry_is_committed() -> None:
    """Without this file checked in, a rebuild would renumber everything."""
    assert IDS_PATH.is_file()


def test_every_location_id_comes_from_the_registry(campaign: dict, registry_data: dict) -> None:
    table = registry_data["locations"]
    for entry in campaign["locations"]:
        key = location_key(entry["chapter"], entry["map"], entry["trigger"])
        assert key in table, key
        assert table[key] == entry["id"], key


def test_every_item_id_comes_from_the_registry(campaign: dict, registry_data: dict) -> None:
    table = registry_data["items"]
    for entry in campaign["items"]:
        assert table.get(entry["name"]) == entry["id"], entry["name"]


def test_registry_ids_are_unique(registry_data: dict) -> None:
    for kind in ("locations", "items"):
        ids = list(registry_data[kind].values())
        assert len(ids) == len(set(ids)), kind


def test_ids_are_stable_across_a_location_set_change(tmp_path: Path) -> None:
    """The exact regression: enabling a location type must not renumber the rest."""
    path = tmp_path / "ids.json"
    registry = IdRegistry(path)

    reached = location_key("office_complex", "hl_c03", {"type": "map_reached"})
    complete = location_key(
        "office_complex", "hl_c03", {"type": "chapter_complete", "chapter": "office_complex"}
    )
    before = (registry.get("locations", reached, 1000), registry.get("locations", complete, 1000))
    registry.save()

    # A later build turns pickups back on, generating them *before* the others.
    reloaded = IdRegistry(path)
    pickup = location_key(
        "office_complex", "hl_c03", {"type": "pickup", "classnames": ["weapon_shotgun"]}
    )
    reloaded.get("locations", pickup, 1000)
    after = (
        reloaded.get("locations", reached, 1000),
        reloaded.get("locations", complete, 1000),
    )

    assert after == before


def test_new_keys_get_fresh_ids(tmp_path: Path) -> None:
    registry = IdRegistry(tmp_path / "ids.json")
    first = registry.get("locations", "a", 1000)
    second = registry.get("locations", "b", 1000)
    assert first != second


def test_fingerprint_changes_when_ids_change(tmp_path: Path) -> None:
    registry = IdRegistry(tmp_path / "ids.json")
    registry.get("locations", "a", 1000)
    before = registry.fingerprint()

    registry.get("locations", "b", 1000)
    assert registry.fingerprint() != before


def test_fingerprint_is_stable_for_the_same_ids(tmp_path: Path) -> None:
    path = tmp_path / "ids.json"
    registry = IdRegistry(path)
    registry.get("locations", "a", 1000)
    registry.save()

    assert IdRegistry(path).fingerprint() == registry.fingerprint()


def test_data_version_is_published_to_both_sides(campaign: dict) -> None:
    """The plugin pauses checks unless these agree."""
    version = campaign["data_version"]
    assert version

    records = [
        line.split("|") for line in CHECKDATA_PATH.read_text(encoding="utf-8").splitlines()
        if line.startswith("D|")
    ]
    assert records == [["D", version]], "run: python tools/gen_checkdata.py"


# --- Back compatibility with released seeds ---------------------------------
#
# `fixtures/released_ids.json` is every tagged release's datapackage, written by
# `tools/snapshot_released_ids.py`. A seed from any of them must still resolve
# every id it carries: Universal Tracker rejects the whole datapackage over one
# it cannot name, and a check nothing sends any more can strand progression.

RELEASED_PATH = REPO / "tests" / "fixtures" / "released_ids.json"


@pytest.fixture(scope="module")
def released() -> dict:
    return json.loads(RELEASED_PATH.read_text(encoding="utf-8"))


def test_every_release_tag_has_a_snapshot(released: dict) -> None:
    import subprocess

    try:
        out = subprocess.run(
            ["git", "tag", "--list", "v*"], cwd=REPO, check=True, capture_output=True, text=True,
        ).stdout
    except (OSError, subprocess.CalledProcessError):
        pytest.skip("no git checkout")
    missing = set(out.split()) - set(released)
    assert not missing, f"run tools/snapshot_released_ids.py for {sorted(missing)}"


def test_every_released_item_id_still_resolves(campaign: dict, released: dict) -> None:
    from data.legacy import LEGACY_WEAPONS

    known = {entry["id"] for entry in campaign["items"]}
    known |= {item_id for item_id, _ in LEGACY_WEAPONS.values()}
    for tag, data in released.items():
        lost = {name for item_id, name in data["items"].items() if int(item_id) not in known}
        assert not lost, f"{tag} items no longer in the datapackage: {sorted(lost)}"


def test_every_released_location_id_still_resolves(campaign: dict, released: dict) -> None:
    from data.legacy import LEGACY_LOCATIONS

    known = {entry["id"] for entry in campaign["locations"]} | set(LEGACY_LOCATIONS)
    for tag, data in released.items():
        lost = {
            name for location_id, name in data["locations"].items()
            if int(location_id) not in known
        }
        assert not lost, (
            f"{tag} locations no longer in the datapackage: {sorted(lost)}; "
            "add them to LEGACY_LOCATIONS"
        )


def test_released_item_ids_keep_their_meaning(campaign: dict, released: dict) -> None:
    """An item id received in an old seed names what it did then. The client
    grants by name, so a renamed id would grant nothing or the wrong thing."""
    from data.legacy import LEGACY_WEAPONS

    name_by_id = {entry["id"]: entry["name"] for entry in campaign["items"]}
    name_by_id |= {item_id: name for name, (item_id, _) in LEGACY_WEAPONS.items()}
    for tag, data in released.items():
        for item_id, old in data["items"].items():
            assert name_by_id[int(item_id)] == old, f"{tag} item {item_id} was {old!r}"


def test_legacy_successors_are_live_checks(campaign: dict) -> None:
    from data.legacy import LEGACY_LOCATION_SUCCESSORS, LEGACY_LOCATIONS

    live = {entry["id"] for entry in campaign["locations"]}
    for legacy_id, successor in LEGACY_LOCATION_SUCCESSORS.items():
        assert legacy_id in LEGACY_LOCATIONS, legacy_id
        assert successor in live, successor

