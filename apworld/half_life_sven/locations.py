from __future__ import annotations

from BaseClasses import Location

from .data import CHAPTERS, LOCATIONS, SUSPENSION_TRIGGERS

location_table: dict[str, dict] = {entry["name"]: entry for entry in LOCATIONS}
location_name_to_id: dict[str, int] = {entry["name"]: entry["id"] for entry in LOCATIONS}

def location_in_seed(entry: dict, excluded_chapters: set[str]) -> bool:
    """Whether a seed leaving these missions out still contains this check.

    A weapon check is there while any of its sources' missions is.
    """
    chapters = [s["chapter"] for s in entry.get("sources", ())] or [entry["chapter"]]
    return any(chapter not in excluded_chapters for chapter in chapters)


# Locations grouped by the map region they live in.
locations_by_map: dict[str, list[dict]] = {}
for _entry in LOCATIONS:
    locations_by_map.setdefault(_entry["map"], []).append(_entry)

location_name_groups: dict[str, set[str]] = {
    chapter["name"]: {e["name"] for e in LOCATIONS if e["chapter"] == chapter["key"]}
    for chapter in CHAPTERS
}
location_name_groups["Mission Completions"] = {
    e["name"] for e in LOCATIONS if e["trigger"]["type"] == "chapter_complete"
}
location_name_groups["Weapon Pickups"] = {
    e["name"] for e in LOCATIONS if e["trigger"]["type"] in ("pickup", "weapon_pickup")
}
location_name_groups["Chargers"] = {
    e["name"] for e in LOCATIONS if e["trigger"]["type"] == "charger"
}
location_name_groups["Kills"] = { # Unused for now
    e["name"] for e in LOCATIONS if e["trigger"]["type"] in ("kill", "kill_count")
}
location_name_groups["Suspension"] = {
    e["name"] for e in LOCATIONS if e["trigger"]["type"] in SUSPENSION_TRIGGERS
}


class HalfLifeSvenLocation(Location):
    game = "Half-Life (Sven Co-op)"
