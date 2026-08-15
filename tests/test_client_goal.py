"""How the client decides a seed is won.

The client cannot be imported here -- it pulls in `CommonClient` and the rest of
a real Archipelago install -- so these read its source, in the same style as
`test_tracker_support.py`. Blunt, and worth having: the fault they guard against
left a finished seed sitting one phantom goal short of won, with nothing in the
log to say so.
"""

from __future__ import annotations

import re
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
CLIENT = (
    REPO / "apworld" / "half_life_sven" / "client" / "launcher.py"
).read_text(encoding="utf-8")


def test_an_empty_goal_chapter_is_never_a_goal() -> None:
    """A seed of nothing but Suspension still carries the older single-goal
    field, as `""`. Believing it put a goal in the set that nothing could
    complete: the arcade was finished, the slot was not, for ever. Its tell was
    the connect line reading `?: 1 missions needed to open its final mission`.
    """
    block = CLIENT.split('if "goal_chapters" in slot_data:', 1)
    assert len(block) == 2, "the goal chapter set is no longer read from slot data"
    body = block[1][:400]

    assert re.search(r"for key in slot_data\[.goal_chapters.\] if key", body), (
        "empty chapter keys are believed again"
    )
    # An empty list means an empty list. Only a seed that mentions neither key
    # falls back to the finales the data declares.
    assert "elif slot_data.get(" in body


def test_the_goal_is_reported_from_the_poll_as_well_as_from_an_event() -> None:
    """Suspension's goal is a set of checks with no event behind it: the last
    clear simply lands. Waiting for a `GOAL` line from the game would wait for
    ever, because the plugin sends none for the arcade."""
    assert "async def report_goal" in CLIENT
    pump = CLIENT.split("async def pump", 1)[1]
    assert "await report_goal(ctx)" in pump
    assert "ctx.sync_completed_missions()" in pump
