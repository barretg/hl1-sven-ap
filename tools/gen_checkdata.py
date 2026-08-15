"""Emit the AngelScript plugin's data file from the generated campaign data.

AngelScript has no JSON parser, so the plugin reads a line-oriented, pipe
delimited format that `string.Split("|")` handles in one call. Regenerating this
from the same data the apworld reads is what keeps location ids from drifting
between the two halves of the project. It goes through the world's own loader
rather than opening files itself, so the two can never disagree about how the
per-campaign files merge.

Usage:
    python tools/gen_checkdata.py
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

from campaign_layout import CLASSNAME_TO_ITEM, STARTING_WEAPONS

REPO_ROOT = Path(__file__).resolve().parent.parent
WORLD_DIR = REPO_ROOT / "apworld" / "half_life_sven"
sys.path.insert(0, str(WORLD_DIR))

from data import load_campaign  # noqa: E402
# The plugin tree is bundled inside the world package so a zipped .apworld can
# install itself. Plugins may only read and write under scripts/plugins/store/,
# so the data file sits there rather than next to the .as sources.
OUT_PATH = (
    REPO_ROOT / "apworld" / "half_life_sven" / "plugin"
    / "plugins" / "store" / "archipelago" / "checkdata.txt"
)

# 2 added the campaign records, the console table, and a seventh field on `C`.
# 3 added the eighth and ninth: the mission a finale is paired with, and whether
# finishing waits for the map to end.
# 4 added the arcade map records -- X, Y, Z, W, A, J, G, E -- and a new spelling
# of the `arg` field on `L` for its three trigger types. All of it is additive: a
# plugin reading the older format ignores what it does not recognise and behaves
# exactly as it did.
FORMAT_VERSION = 4


def arcade_records(arcades) -> list[str]:
    """The standalone maps: their tiers, sections, classes and medals.

    The plugin cannot derive any of this. It has to know which button belongs to
    which tier to refuse a locked one, which entity name means a section fell,
    and what a class does to a player -- the last because a booth that does
    nothing on the tier being played leaves the plugin to grant it.
    """
    lines: list[str] = []
    for arcade in arcades:
        key = arcade["key"]
        lines.append(
            "X|{key}|{name}|{map}|{goal}|{start}|{end}".format(
                key=key,
                name=arcade["name"],
                map=arcade["map"],
                goal=arcade["gated_class"],
                start=arcade["start_signal"],
                end=arcade["end_signal"],
            )
        )
        for entry in arcade["difficulties"]:
            lines.append(
                "Y|{arcade}|{key}|{name}|{tickets}|{button}|{signal}".format(
                    arcade=key,
                    key=entry["key"],
                    name=entry["name"],
                    tickets=entry["tickets"],
                    button=entry["vote_button"],
                    signal=entry["ticket_signal"],
                )
            )
        for entry in arcade["sections"]:
            lines.append(
                "Z|{arcade}|{key}|{index}|{name}|{signal}".format(
                    arcade=key,
                    key=entry["key"],
                    index=entry["index"],
                    name=entry["name"],
                    signal=entry["signal"],
                )
            )
        for entry in arcade["classes"]:
            lines.append(
                "W|{arcade}|{key}|{name}|{targetname}|{signal}|{gated}|{portal}".format(
                    arcade=key,
                    key=entry["key"],
                    name=entry["name"],
                    targetname=entry["targetname"],
                    signal=entry["signal"],
                    gated=1 if entry["map_gated"] else 0,
                    portal=entry.get("portal", ""),
                )
            )
        for entry in arcade["awards"]:
            lines.append(
                f"A|{key}|{entry['key']}|{entry['name']}|{entry['deaths']}"
            )
        # Every named box the plugin watches: the Juggernaut's portal and pad,
        # and the space behind each class booth's doorway.
        boxes = dict(arcade.get("jugger_volumes", {}))
        boxes.update(arcade.get("booth_volumes", {}))
        for name, box in sorted(boxes.items()):
            mins = " ".join(str(v) for v in box["mins"])
            maxs = " ".join(str(v) for v in box["maxs"])
            lines.append(f"J|{key}|{name}|{mins}|{maxs}")
        for part, value in sorted(arcade.get("jugger_seal", {}).items()):
            if isinstance(value, dict):
                lines.append(
                    f"G|{key}|{part}|{value['targetname']}|{value['classname']}"
                )
            else:
                lines.append(f"G|{key}|{part}|{value}|")
        for entry in arcade["classes"]:
            lines.extend(grant_records(key, entry))
    return lines


def grant_records(arcade_key: str, entry: dict) -> list[str]:
    """`E` records: everything a class does to the player who takes it."""
    grant = entry.get("grant") or {}
    lines: list[str] = []
    for field in ("health", "max_health", "armorvalue", "armortype", "model"):
        if field in grant:
            lines.append(f"E|{arcade_key}|{entry['key']}|{field}|{grant[field]}")
    if grant.get("weapons"):
        lines.append(
            f"E|{arcade_key}|{entry['key']}|weapons|{','.join(grant['weapons'])}"
        )
    if grant.get("ammo"):
        pairs = ",".join(f"{name}:{count}" for name, count in sorted(grant["ammo"].items()))
        lines.append(f"E|{arcade_key}|{entry['key']}|ammo|{pairs}")
    if grant.get("teleport"):
        where = " ".join(str(v) for v in grant["teleport"])
        lines.append(f"E|{arcade_key}|{entry['key']}|teleport|{where}")
    return lines


def render(campaign: dict) -> str:
    lines: list[str] = [
        "# Generated by tools/gen_checkdata.py -- do not edit by hand.",
        "# Record types:",
        "#   V|<format version>",
        "#   M|<key>|<name>|<goal chapter>  a campaign",
        "#   C|<index>|<key>|<name>|<map,map,...>|<is_goal>|<campaign key>"
        "|<requires chapter>|<complete on endgame>",
        "#   P|<console>|<chapter key>      hub console button -> the mission it enters",
        "#   L|<id>|<map>|<type>|<arg>|<name>[|<x y z>]",
        "#   K|<classname>|<item name>      weapon pickup that must be unlocked",
        "#   S|<classname>                  always granted, never randomised",
        "#   R|<classname>|<campaign,...>   grantable only on those campaigns' maps",
        "#   D|<data version>               must match the client's, or ids differ",
        "# Arcade maps (Suspension), all scoped by the arcade key:",
        "#   X|<key>|<name>|<map>|<goal class>|<start signal>|<end signal>",
        "#   Y|<arcade>|<key>|<name>|<tickets>|<vote button>|<ticket signal>",
        "#   Z|<arcade>|<key>|<index>|<name>|<clear signal>",
        "#   W|<arcade>|<key>|<name>|<player targetname>|<booth signal>|<map gated>|<portal>",
        "#   A|<arcade>|<key>|<name>|<max deaths>",
        "#   J|<arcade>|<volume>|<mins>|<maxs>   a box the plugin watches",
        "#   G|<arcade>|<part>|<targetname>|<classname>   the Juggernaut seal",
        "#   E|<arcade>|<class>|<field>|<value>  how to grant a class without its booth",
        f"V|{FORMAT_VERSION}",
        f"D|{campaign['data_version']}",
    ]

    for entry in campaign.get("campaigns", ()):
        lines.append(
            "M|{key}|{name}|{goal}".format(
                key=entry["key"], name=entry["name"], goal=entry["goal_chapter"],
            )
        )

    for chapter in campaign["chapters"]:
        lines.append(
            "C|{index}|{key}|{name}|{maps}|{goal}|{campaign}|{requires}|{endgame}".format(
                index=chapter["index"],
                key=chapter["key"],
                name=chapter["name"],
                maps=",".join(chapter["maps"]),
                goal=1 if chapter["is_goal"] else 0,
                campaign=chapter.get("campaign", ""),
                requires=chapter.get("requires_chapter", ""),
                endgame=1 if chapter.get("complete_on_endgame") else 0,
            )
        )

    # The hub numbers its consoles differently in every campaign -- Half-Life's
    # are unpadded and start at 1, Opposing Force's are padded and skip 06 -- so
    # the plugin is handed the mapping rather than deriving it from a targetname.
    for entry in campaign.get("campaigns", ()):
        for console, chapter_key in sorted(entry.get("consoles", {}).items()):
            lines.append(f"P|{console}|{chapter_key}")

    # By id, not in list order. The plugin keys these by id and never cares, but
    # emitting them in whatever order the data files happen to merge in means any
    # future change to the data layout rewrites half this file for no reason.
    for location in sorted(campaign["locations"], key=lambda l: l["id"]):
        trigger = location["trigger"]
        kind = trigger["type"]
        if kind in ("pickup", "weapon_pickup"):
            arg = ",".join(trigger["classnames"])
        elif kind == "kill":
            arg = trigger["classname"]
        elif kind == "kill_count":
            arg = str(trigger["count"])
        elif kind == "chapter_complete":
            arg = trigger["chapter"]
        elif kind == "suspension_section":
            arg = f"{trigger['section']}:{trigger['class']}:{trigger['difficulty']}"
        elif kind == "suspension_clear":
            arg = f"{trigger['class']}:{trigger['difficulty']}"
        elif kind == "suspension_award":
            arg = f"{trigger['award']}:{trigger['difficulty']}"
        elif kind == "charger":
            # `<classname>:<brush model>`, which is what the plugin matches the
            # entity a player pressed +use on against. Gains `@<origin>` only
            # where one brush is shared by two chargers, which is the sole case
            # where the model alone cannot tell them apart.
            arg = f"{trigger['classname']}:{trigger['model']}"
            if trigger.get("origin"):
                arg += f"@{trigger['origin']}"
        else:  # map_reached
            arg = ""
        # A seventh field where we know where the thing is, which is what `!find`
        # points at. Appended rather than inserted, so a plugin reading the older
        # six-field form is unaffected.
        position = location.get("position")
        record = "L|{id}|{map}|{kind}|{arg}|{name}".format(
            id=location["id"],
            map=location["map"],
            kind=kind,
            arg=arg,
            name=location["name"],
        )
        if position:
            record += "|" + " ".join(str(value) for value in position)
        lines.append(record)

    lines.extend(arcade_records(campaign.get("arcades", ())))

    # Every classname the plugin must refuse until the matching item arrives.
    for classname, item in sorted(CLASSNAME_TO_ITEM.items()):
        lines.append(f"K|{classname}|{item}")

    for classname in STARTING_WEAPONS:
        lines.append(f"S|{classname}")

    # Weapons a campaign's own map script defines rather than the game. Handing
    # one over anywhere else asks the engine to build an entity it has never
    # heard of, so the plugin holds it back until the player is somewhere it
    # exists -- the loadout is reapplied on every spawn, so it lands by itself.
    for classname, campaign_keys in sorted(
        campaign.get("restricted_classnames", {}).items()
    ):
        lines.append(f"R|{classname}|{','.join(campaign_keys)}")

    return "\n".join(lines) + "\n"


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", type=Path, default=OUT_PATH)
    args = parser.parse_args(argv)

    campaign = load_campaign()
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(render(campaign), encoding="utf-8")

    lockable = len(CLASSNAME_TO_ITEM)
    print(f"wrote {args.out}")
    print(f"  chapters {len(campaign['chapters'])}, locations {len(campaign['locations'])},"
          f" lockable classnames {lockable}")
    unused = set(CLASSNAME_TO_ITEM) - {
        c for l in campaign["locations"]
        if l["trigger"]["type"] in ("pickup", "weapon_pickup")
        for c in l["trigger"]["classnames"]
    }
    if unused:
        print(f"  note: no pickup location exists for {sorted(unused)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
