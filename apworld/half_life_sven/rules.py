"""Access rules.

Two kinds of gate exist:

* **Mission unlocks** -- entering a mission needs its unlock item, except for the
  goal mission and any mission paired with it, which open once
  `missions_required` other missions are done.
* **Weapon gates** -- expressed as "any one of this group of weapons". They are
  attached to a mission entrance (everything in the mission inherits it), to the
  seam between two parts of a mission (everything from that part on inherits
  it), or to an individual location, which is how a check that sits past the
  point where a weapon becomes necessary carries that requirement.

A gate is either `strict`, which loose logic drops because it is about how hard
the fighting is, or `always`, which no difficulty drops because it is about
whether the map lets you past at all.

The groups themselves live in `tools/campaign_layout.py` and are baked into
`data/index.json`; this module only turns them into callables.
"""

from __future__ import annotations

from typing import TYPE_CHECKING, Callable

from BaseClasses import CollectionState

from .data import (
    GOAL_COMPANIONS,
    GOAL_PREREQUISITES,
    REQUIREMENT_GROUPS,
    chapter_cleared_event,
    mission_complete_event,
)
from .options import LogicDifficulty

if TYPE_CHECKING:
    from . import HalfLifeSvenWorld

# Gate keys used by `gates["always"]` that name a single optional item rather
# than a requirement group. Only a gate naming one of these is allowed to vanish
# when the item is not in the pool: the YAML decides whether the suit and the
# long jump module are shuffled at all, and equipment nobody will receive is not
# a gate. Any other `always` key is read as a requirement group.
EQUIPMENT_GATES = {"longjump": "Long Jump Module", "suit": "HEV Suit"}


def group_items(world: "HalfLifeSvenWorld", group: str) -> list[str]:
    """The items satisfying a requirement group that are actually in this pool."""
    return [name for name in REQUIREMENT_GROUPS[group] if name in world.available_item_names]


def any_of(world: "HalfLifeSvenWorld", groups: list[str]) -> Callable[[CollectionState], bool] | None:
    """Require at least one item from each named group."""
    requirements = [group_items(world, group) for group in groups]
    requirements = [names for names in requirements if names]
    if not requirements:
        return None
    player = world.player

    def rule(state: CollectionState) -> bool:
        return all(state.has_any(names, player) for names in requirements)

    return rule


def all_of(
    conditions: list[Callable[[CollectionState], bool]]
) -> Callable[[CollectionState], bool] | None:
    """Fold a list of rules into one, or None where there is nothing to ask."""
    if not conditions:
        return None
    if len(conditions) == 1:
        return conditions[0]

    def rule(state: CollectionState) -> bool:
        return all(condition(state) for condition in conditions)

    return rule


def gate_conditions(
    world: "HalfLifeSvenWorld", gates: dict
) -> list[Callable[[CollectionState], bool]]:
    """What a gate table asks for, as rules.

    Shared by mission doors and the seams between parts, which express the same
    two kinds of requirement and differ only in where they hang.
    """
    player = world.player
    conditions: list[Callable[[CollectionState], bool]] = []

    if world.options.logic_difficulty.value == LogicDifficulty.option_strict:
        strict = any_of(world, gates.get("strict", []))
        if strict is not None:
            conditions.append(strict)

    for key in gates.get("always", []):
        item_name = EQUIPMENT_GATES.get(key)
        if item_name is None:
            required = any_of(world, [key])
            if required is not None:
                conditions.append(required)
        elif item_name in world.available_item_names:
            conditions.append(lambda state, name=item_name: state.has(name, player))

    return conditions


def gates_are_shut(world: "HalfLifeSvenWorld", gates: dict) -> bool:
    """Does this gate table ask for anything the seed can actually provide?

    The startability question, and deliberately not `gate_conditions`: this runs
    before the pool exists, so it asks whether items would be named rather than
    building rules around them.
    """
    if world.options.logic_difficulty.value == LogicDifficulty.option_strict:
        if any(group_items(world, group) for group in gates.get("strict", [])):
            return True

    for key in gates.get("always", []):
        item_name = EQUIPMENT_GATES.get(key)
        if item_name is None:
            if group_items(world, key):
                return True
        elif item_name in world.available_item_names:
            return True

    return False


def chapter_is_startable(world: "HalfLifeSvenWorld", chapter: dict) -> bool:
    """Can this mission be entered with nothing but its own unlock item?

    The mission handed out at the start has to be one of these. Every location in
    the game sits behind a mission entrance, so if the one open mission also
    demands a real weapon or the long jump module, *nothing* is reachable in
    sphere one: fill has no legal spot for the item that would open sphere two,
    burns its swap budget, and dies with "no more spots to place N items.
    Remaining locations are invalid".

    Called before the pool is built, so it reads `available_item_names` — a gate
    naming equipment nobody will ever receive is not a gate.

    Only the mission door counts. A gate on a later part of the mission leaves
    part 1 walkable, which is all this question is about.
    """
    return not gates_are_shut(world, chapter["gates"])


def chapter_entry_rule(
    world: "HalfLifeSvenWorld", chapter: dict
) -> Callable[[CollectionState], bool] | None:
    """Rule for the Hub -> first map of a mission entrance."""
    player = world.player
    conditions = gate_conditions(world, chapter["gates"])

    # The seal: this campaign's own count, from this campaign's own setting.
    # Missions finished elsewhere in the seed do nothing for it. Both the finale
    # and the mission paired with it sit behind the same one, because the pair is
    # a single ending and an item that opened half of it early made a nonsense of
    # the other half.
    if chapter["is_goal"] or chapter["key"] in GOAL_COMPANIONS:
        campaign = chapter["campaign"]
        required = world.missions_required_for[campaign]
        event = mission_complete_event(campaign)
        conditions.append(
            lambda state, name=event, count=required: state.has(name, player, count)
        )

    if chapter["is_goal"]:
        # Some finales are the tail of one particular mission rather than a
        # mission in their own right, and open only once that one is cleared --
        # Blue Shift's outro after Power Struggle. Skipped if the seed left the
        # paired mission out, which would otherwise seal the campaign forever.
        prerequisite = GOAL_PREREQUISITES.get(chapter["key"], "")
        if prerequisite and prerequisite not in world.excluded_chapters:
            cleared = chapter_cleared_event(prerequisite)
            conditions.append(lambda state, name=cleared: state.has(name, player))
    elif chapter["key"] not in GOAL_COMPANIONS:
        unlock = world.unlock_item_for_chapter[chapter["key"]]
        conditions.append(lambda state, name=unlock: state.has(name, player))

    return all_of(conditions)


def map_entry_rule(
    world: "HalfLifeSvenWorld", chapter: dict, map_name: str
) -> Callable[[CollectionState], bool] | None:
    """Rule for the seam between two parts of one mission.

    Almost always None. It exists for the mission that hands you the thing it
    then requires: Opposing Force leaves the barnacle grapple in Pit Worm's Nest
    part 3 and is built around it from part 4 on, so gating the mission would put
    the grapple's own pickup behind the grapple.

    Missing entirely from data built before `map_gates` existed, which reads as
    no gate.
    """
    gates = chapter.get("map_gates", {}).get(map_name)
    if not gates:
        return None
    return all_of(gate_conditions(world, gates))


def location_rule(
    world: "HalfLifeSvenWorld", entry: dict
) -> Callable[[CollectionState], bool] | None:
    """Extra requirement on a single location, e.g. a boss that needs real damage."""
    requirement = entry.get("requires")
    if not requirement:
        return None
    if world.options.logic_difficulty.value != LogicDifficulty.option_strict:
        return None  # loose logic drops soft weapon gates
    return any_of(world, [requirement])


def suspension_rule(
    world: "HalfLifeSvenWorld", entry: dict
) -> Callable[[CollectionState], bool] | None:
    """What a Suspension check needs: the tier, and the class it names.

    Two requirements, both item counts:

    - the difficulty, as that many Progressive Suspension Difficulty items. Easy
      is the tier everyone starts on and needs none.
    - the class, where the check names one. The Juggernaut needs every other
      class as well, because it opens only once a run has been cleared with each
      of them -- the plugin enforces the clears, and logic enforces the items,
      which is what stops the generator expecting a Juggernaut run from a player
      who cannot field the seven runs that unlock it.
    """
    player = world.player
    trigger = entry["trigger"]
    conditions: list[Callable[[CollectionState], bool]] = []

    tier = world.suspension_tier_index.get(trigger["difficulty"])
    if tier is None:
        return None
    if tier > 0 and world.suspension_difficulty_item:
        conditions.append(
            lambda state, name=world.suspension_difficulty_item, count=tier:
            state.has(name, player, count)
        )

    required_classes = world.suspension_classes_required(trigger.get("class", ""))
    if required_classes:
        conditions.append(
            lambda state, names=required_classes: state.has_all(names, player)
        )

    # Past the tank, somebody in the lobby has to be able to hurt it, and only
    # three of the eight classes can. Held rather than played: the class a check
    # names is the one you were on when it landed, and switching between
    # sections is normal -- so blow the tank up as the Engineer and finish the
    # run as the Sniper if the Sniper is whose section this is.
    if world.suspension_needs_explosives(trigger):
        explosives = world.suspension_explosive_class_items()
        if explosives:
            conditions.append(
                lambda state, names=explosives: state.has_any(names, player)
            )

    if not conditions:
        return None
    if len(conditions) == 1:
        return conditions[0]

    def rule(state: CollectionState) -> bool:
        return all(condition(state) for condition in conditions)

    return rule
