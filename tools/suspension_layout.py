"""Hand-authored facts about Suspension, the arcade map.

`suspension` ships with Sven Co-op -- it is an official Hezus release, not a
download -- and is nothing like a campaign. It is one map: a class-based, wave
based push along a suspension bridge, in eight sections, at a difficulty the
lobby votes for, ending in a medal scored on the team's total deaths.

Everything here was read out of `suspension.bsp` and
`scripts/maps/bridge/{bridge3,CustomHUD}.as` with `tools/bsp_entities.py`. It is
in this module rather than derived at build time because none of it is
*derivable*: which volume is a class booth and what the ticket counts mean are
facts about the map's design, not about its entity list.

Kept apart from `campaign_layout.py` on purpose. Nothing here is a chapter, has a
hub console, or belongs to a campaign, and the two would only tangle.
"""

from __future__ import annotations

from dataclasses import dataclass, field

KEY = "suspension"
NAME = "Suspension"
MAP = "suspension"

# YAML toggle that puts it in a seed.
OPTION = "suspension"


# --- Difficulty -----------------------------------------------------------
#
# Not a menu: the lobby votes on four buttons, and the winner sets the team's
# shared ticket pool (`ticket_counter`'s `frags`). Fewer tickets is harder, and
# the pool is the only difficulty knob the map has -- `suspension.cfg` pins
# `skill 3` regardless.
#
# `vote` is the button the plugin has to refuse while a tier is locked. The
# numbering runs backwards from the difficulty order, which is why this is a
# table and not arithmetic.


@dataclass(frozen=True)
class Difficulty:
    key: str
    name: str
    # Starting tickets, and so how the plugin recognises which tier was voted in.
    tickets: int
    # The map's own colour for this tier, which names its entities.
    colour: str
    # `func_button` the plugin blocks with a message while the tier is locked.
    vote_button: str
    # `trigger_changevalue` the winning vote fires. The plugin hangs its own
    # counter off the same name to learn the result without polling for it.
    ticket_signal: str


DIFFICULTIES: list[Difficulty] = [
    Difficulty("easy", "Easy", 50, "red", "vote_button4", "win_red_tickets"),
    Difficulty("medium", "Medium", 25, "blue", "vote_button3", "win_blue_tickets"),
    Difficulty("hard", "Hard", 10, "yellow", "vote_button2", "win_yellow_tickets"),
    Difficulty("insane", "Insane", 1, "white", "vote_button1", "win_white_tickets"),
]


# --- Sections -------------------------------------------------------------
#
# Eight, fought in order along the bridge. The map has no uniform "section N
# cleared" entity -- only s1 and s2 have a `sX_win` -- but every section past the
# first announces itself by firing `sN_events`, so clearing section N is the same
# event as section N+1 starting. The last section has no successor: it ends the
# round at `final_end`, a `game_end`.
#
# `signal` is a name the map already fires. The plugin creates its own
# `trigger_changevalue` under the same name, so the map's own multi_manager
# advances our counter for us. That is exact and needs no polling, which reading
# player positions would have.


@dataclass(frozen=True)
class Section:
    key: str
    index: int
    name: str
    # The entity name whose firing means this section has been cleared.
    # Empty on the last one, which is cleared by the round ending.
    signal: str


SECTIONS: list[Section] = [
    Section("s1", 1, "Section 1: The Approach", "s2_events"),
    Section("s2", 2, "Section 2: The APC", "s3_events"),
    Section("s3", 3, "Section 3: The Helipad", "s4_events"),
    Section("s4", 4, "Section 4: The Tank", "s5_events"),
    Section("s5", 5, "Section 5: The Apache", "s6_events"),
    # `s6_captured` fires this at once and `s7_apc_start` twenty seconds later.
    # The immediate one, so the check lands when the flag does.
    Section("s6", 6, "Section 6: The Flag", "s6_captured_text"),
    Section("s7", 7, "Section 7: The Counterattack", "s8_events"),
    Section("s8", 8, "Section 8: The Assassin", ""),
]

# Fired when the round actually starts, after the vote. Resets our per-round
# bookkeeping, which otherwise carries a lost run's state into the next one.
START_SIGNAL = "start_events"

# The map's own end-of-round script entity. The plugin hangs a counter off the
# same name, so it learns the run ended in the same instant the medal is shown.
END_SIGNAL = "end_script"


# --- Classes --------------------------------------------------------------
#
# Eight. A player walks a portal on the lobby's display wall, is teleported onto
# a pad, and the pad's `trigger_multiple` fires everything sharing the class
# name: the loadout, the stat changes, and a `trigger_changevalue` that sets the
# *player's own* `targetname` to `class_<key>`.
#
# That targetname is how the plugin knows who is playing what, and it is
# authoritative: single-valued, per player, and updated the moment they switch.
# The map's `class_counter_*` entities look like the same answer and are not --
# they only ever increment, so a player who walks through three booths counts
# three times, and there is no counter for the Juggernaut at all.
#
# The restock stations along the bridge filter on `target=class_<key>`, so a
# class the plugin grants itself restocks correctly as long as it sets the
# targetname the same way.


@dataclass(frozen=True)
class Class:
    key: str
    # What the lobby display calls it, which is *not* what its entities are
    # named: the booth that equips a shotgun is `shotty` and the sign above it
    # reads Pointman. These came from the game rather than from the BSP, and
    # guessing them from the entity names got every one of them wrong.
    name: str
    # What the map sets the player's targetname to. The plugin reads it rather
    # than tracking booth entries.
    targetname: str
    # The name the booth fires. The plugin grants a class itself by doing what
    # this name does.
    signal: str
    # The teleport destination its lobby portal sends a player to. The plugin
    # finds the portal by this and makes it non-solid to lock the class.
    portal: str
    # True where the map itself gates the class, rather than us. Only the
    # Juggernaut, which the map reveals on an Insane vote and seals behind the
    # first player to take it.
    map_gated: bool = False
    # Everything needed to grant the class without the booth firing, which is how
    # the Juggernaut is handed out on the tiers where its booth does nothing.
    # Empty where the booth is the only way in and always works.
    grant: dict = field(default_factory=dict)


CLASSES: list[Class] = [
    # Keys are the map's entity names and are permanent -- `data/ids.json` is
    # keyed by them, so renaming one renumbers a location. The display names
    # beside them are the lobby's and are free to change.
    Class("soldier", "Assault", "class_soldier", "soldier", "pick_soldier"),
    Class("gl_soldier", "Grenadier", "class_GL_soldier", "GL_soldier", "pick_GLsoldier"),
    Class("shotty", "Pointman", "class_shotty", "shotty", "pick_shotty"),
    Class("saw", "Support", "class_saw", "saw", "pick_saw"),
    Class("sniper", "Sniper", "class_sniper", "sniper", "pick_sniper"),
    Class("medic", "Medic", "class_medic", "medic", "pick_medic"),
    Class("engineer", "Engineer", "class_engineer", "engineer", "pick_engi"),
    Class(
        "jugger",
        "Juggernaut",
        "class_jugger",
        "jugger",
        "pick_jugger",
        map_gated=True,
        grant={
            "health": 200,
            "max_health": 200,
            "armorvalue": 200,
            "armortype": 200,
            "model": "models/player/OP4_Heavy/OP4_Heavy.mdl",
            "weapons": [
                "weapon_crowbar",
                "weapon_uziakimbo",
                "weapon_eagle",
            ],
            "ammo": {"ammo_556": 1, "ammo_9mmbox": 1, "ammo_357": 3},
            # Where the booth would have put them, for the tiers where walking
            # the portal does nothing.
            "teleport": [6256, -6880, 96],
        },
    ),
]

# The one class the *map* gates rather than the seed: it opens once a run has
# been cleared with each of the other seven, and it is not an item.
#
# Called the goal class once, which it no longer is and never quite was. The goal
# is a run cleared with each class in `suspension_goal_classes`, which is all
# eight by default -- this one among them, and last, because the map will not
# open it any sooner.
GATED_CLASS = "jugger"

# Volumes the plugin watches so it can grant the Juggernaut itself: the lobby
# portal, and the pad it teleports onto. Watched rather than hooked because a
# booth that does nothing fires nothing. Read from the BSP's model lump; the
# portal is a four-unit slab, so the plugin inflates it by a player half-width
# before testing.
JUGGER_VOLUMES = {
    "portal": {"mins": [6256, -6064, 144], "maxs": [6260, -6000, 208]},
    "pad": {"mins": [6224, -6912, 88], "maxs": [6288, -6848, 96]},
}

# The eight portals are the eight faces of an octagon standing in the middle of
# the lobby -- four axis-aligned slabs four units thick, four diagonal ones the
# compiler records as squares -- and the booths are what they enclose. That is
# why the plugin is given the ring as one volume rather than a box per doorway:
# reasoning outward from a single face points into the room, and the room is
# where everybody is standing. See `suspension_booth_volumes` in
# tools/build_campaign_data.py, which measures all of it from the BSP.

# The barrier that seals the Juggernaut portal, and the lethal volume behind it.
# Both share the class name, so the plugin finds them by name *and* classname.
JUGGER_SEAL = {
    "wall": {"targetname": "jugger", "classname": "func_wall_toggle"},
    "hurt": {"targetname": "jugger", "classname": "trigger_hurt"},
    # Swaps the display panel from the unknown placeholder to the Juggernaut
    # icon. The map fires this whole multi_manager rather than the env_render
    # alone, and firing only the render left both drawn on top of each other.
    "reveal": "display_change",
}


# --- Explosives -----------------------------------------------------------
#
# The bridge cannot be pushed past the tank without them, and only three classes
# can get any. The restock crates along the way (`restock_explo`) are three
# `game_player_equip` entities filtered by the player's class targetname:
# `class_engineer` gets a satchel and a tripmine, `class_GL_soldier` AR
# grenades, `class_shotty` hand grenades. Nothing equips `class_soldier`,
# `class_saw`, `class_sniper` or `class_medic`, and their booth loadouts carry
# no explosives either -- an Assault has a 9mmAR, a pistol, a Desert Eagle and a
# crowbar, and the tank is a 1500 health `func_breakable` shooting back with a
# 50 damage mortar.
#
# Section 3's detonation pack is *not* one of these: it is an `item_inventory`
# lying on the bridge that anybody may carry to the marked spot, so section 3
# gates on nothing.

EXPLOSIVE_CLASSES = ("gl_soldier", "shotty", "engineer")

# The first section that needs them, by index. Section 2 is where the armour
# first has to be dealt with -- the APC, and a tank behind it, which is why the
# map puts an explosives crate (`s2_restock_explo`) in that section. Reported
# from play; the entity list alone would have put this at section 4, where the
# named tank fight is. Everything after is behind it, so the requirement carries
# to the end of the run and to the clear and medal that depend on finishing it.
EXPLOSIVES_FROM_SECTION = 2


# --- Awards ---------------------------------------------------------------
#
# The medal shown at the end of a won round, scored on the team's *total* deaths.
# Thresholds are `CustomHUD.as`'s, and the plugin recomputes them rather than
# reading the map's HUD state: it already counts deaths for DeathLink.
#
# Ordered hardest first, which is the order they roll down in. Reaching one sends
# every easier one too, so nobody has to throw a run to collect the bad medals.


@dataclass(frozen=True)
class Award:
    key: str
    name: str
    # Most team deaths a run may have and still earn this.
    deaths: int


AWARDS: list[Award] = [
    Award("platinum", "Platinum", 0),
    Award("gold", "Gold", 5),
    Award("silver", "Silver", 10),
    Award("bronze", "Bronze", 20),
    Award("stone", "Stone", 30),
    Award("noob", "N00b", 40),
]


# --- Naming ---------------------------------------------------------------
#
# Location names are what a player reads in the client and in a spoiler log, and
# ids are keyed by identity rather than by name, so these are free to be reworded
# without renumbering anything.

DIFFICULTY_BY_KEY = {d.key: d for d in DIFFICULTIES}
CLASS_BY_KEY = {c.key: c for c in CLASSES}
SECTION_BY_KEY = {s.key: s for s in SECTIONS}
AWARD_BY_KEY = {a.key: a for a in AWARDS}


def section_location_name(section: Section, difficulty: Difficulty, class_key: str) -> str:
    if not class_key:
        return f"{NAME}: {difficulty.name} - {section.name}"
    return f"{NAME}: {difficulty.name} - {section.name} ({CLASS_BY_KEY[class_key].name})"


def clear_location_name(difficulty: Difficulty, class_key: str) -> str:
    if not class_key:
        return f"{NAME}: {difficulty.name} - Bridge Retaken"
    return f"{NAME}: {difficulty.name} - Bridge Retaken ({CLASS_BY_KEY[class_key].name})"


def award_location_name(difficulty: Difficulty, award: Award) -> str:
    return f"{NAME}: {difficulty.name} - {award.name} Award"


def class_item_name(entry: Class) -> str:
    return f"{NAME}: {entry.name}"


PROGRESSIVE_DIFFICULTY_ITEM = f"Progressive {NAME} Difficulty"
