"""Region graph.

    Menu -> Hub -> (first map of each mission) -> ... -> (last map of that mission)

Each Sven Co-op map is its own region so that a check in part 4 of Surface
Tension is correctly gated behind reaching parts 1-3. Missions are entered only
from the Hub, which mirrors how the game actually works: you leave the campaign
portal into a mission and come back to it when the mission ends.

That per-map split is also what lets a requirement begin partway through a
mission -- see `map_entry_rule`.
"""

from __future__ import annotations

from typing import TYPE_CHECKING

from BaseClasses import LocationProgressType, Region

from .data import (
    GOAL_PREREQUISITES,
    SUSPENSION_AWARD,
    chapter_cleared_event,
    mission_complete_event,
    suspension_victory_event,
    victory_event,
)
from .locations import HalfLifeSvenLocation, locations_by_map
from .rules import chapter_entry_rule, location_rule, map_entry_rule, suspension_rule

if TYPE_CHECKING:
    from . import HalfLifeSvenWorld

MENU = "Menu"
HUB = "Hub"
SUSPENSION = "Suspension"


def create_regions(world: "HalfLifeSvenWorld") -> None:
    multiworld = world.multiworld
    player = world.player

    menu = Region(MENU, player, multiworld)
    hub = Region(HUB, player, multiworld)
    multiworld.regions += [menu, hub]
    menu.connect(hub)

    # An excluded mission gets no regions at all, so its checks never enter the
    # datapackage-backed location pool for this slot. Leaving them in place with
    # no way to unlock the mission would make them permanently unreachable, which
    # `accessibility: full` correctly refuses to generate.
    for chapter in world.included_chapters:
        previous: Region | None = None
        for map_name in chapter["maps"]:
            region = Region(map_name, player, multiworld)
            multiworld.regions.append(region)

            for entry in locations_by_map.get(map_name, []):
                # A check category the YAML turned off is left out of the seed
                # rather than placed and made unreachable.
                if entry["trigger"]["type"] in world.excluded_triggers:
                    continue

                location = HalfLifeSvenLocation(
                    player, entry["name"], entry["id"], region
                )
                rule = location_rule(world, entry)
                if rule is not None:
                    location.access_rule = rule
                region.locations.append(location)

            if previous is None:
                hub.connect(
                    region,
                    f"Enter {chapter['name']}",
                    chapter_entry_rule(world, chapter),
                )
            else:
                # Usually unconditional -- walking from part 3 into part 4 is
                # the game's business, not ours. A handful of seams carry a
                # requirement that starts there rather than at the mission door.
                previous.connect(
                    region,
                    f"{chapter['name']}: {map_name}",
                    map_entry_rule(world, chapter, map_name),
                )
            previous = region

        assert previous is not None
        add_event(world, previous, chapter)

    if world.suspension_enabled:
        add_suspension(world, hub)


def add_suspension(world: "HalfLifeSvenWorld", hub: Region) -> None:
    """One region for the whole arcade map.

    Suspension is a single map with no sub-levels, so there is nothing to chain:
    every check on it is reachable the moment you can warp there, and what gates
    them is the tier and the class rather than where you are standing. It hangs
    off the Hub for the same reason a mission does -- you leave the portal for it
    and come back -- even though it has no console of its own.
    """
    region = Region(SUSPENSION, world.player, world.multiworld)
    world.multiworld.regions.append(region)
    hub.connect(region, f"Enter {SUSPENSION}")

    arcade = world.suspension
    assert arcade is not None

    for entry in locations_by_map.get(arcade["map"], []):
        if not world.suspension_includes(entry):
            continue

        location = HalfLifeSvenLocation(world.player, entry["name"], entry["id"], region)
        rule = suspension_rule(world, entry)
        if rule is not None:
            location.access_rule = rule
        if (
            entry["trigger"]["type"] == SUSPENSION_AWARD
            and world.suspension_priority_awards
            and entry["name"] in world.suspension_priority_awards
        ):
            location.progress_type = LocationProgressType.PRIORITY
        region.locations.append(location)

    # The goal. A separate event rather than the Juggernaut clear location
    # itself, so that the check can hold an ordinary item like any other while
    # the win condition still has one name to ask for.
    victory = HalfLifeSvenLocation(
        world.player, f"{SUSPENSION} - Cleared As Juggernaut", None, region
    )
    victory.access_rule = world.suspension_goal_rule()
    victory.place_locked_item(world.create_item(suspension_victory_event()))
    region.locations.append(victory)


def add_event(world: "HalfLifeSvenWorld", region: Region, chapter: dict) -> None:
    """Finishing a mission grants an event item.

    Both are named for the campaign the mission belongs to. `missions_required`
    is a separate setting per campaign, so its counter has to be separate too:
    one shared `Mission Complete` would let a run of Opposing Force unseal
    Nihilanth. The same goes for the finales, which are counted by name so that
    clearing one campaign is not mistaken for clearing them all.
    """
    campaign = chapter["campaign"]
    name = victory_event(campaign) if chapter["is_goal"] else mission_complete_event(campaign)
    location = HalfLifeSvenLocation(
        world.player, f"{chapter['name']} - Mission Cleared", None, region
    )
    location.place_locked_item(world.create_item(name))
    region.locations.append(location)

    # A mission a finale is paired with grants a second event naming it, because
    # the counter above cannot say *which* missions were finished. Only Blue
    # Shift's Power Struggle has one today.
    if chapter["key"] in GOAL_PREREQUISITES.values():
        named = HalfLifeSvenLocation(
            world.player, f"{chapter['name']} - Cleared", None, region
        )
        named.place_locked_item(world.create_item(chapter_cleared_event(chapter["key"])))
        region.locations.append(named)
