"""How the client decides a seed is won.

The client cannot be imported here: it pulls in `CommonClient` and the rest of
a real Archipelago install: so these read its source, in the same style as
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
    body = block[1][:600]

    assert re.search(r"for key in finales if key", body), (
        "empty chapter keys are believed again"
    )
    # Campaign -> finale now; a plain list in older seeds. The finales are the
    # values, never the campaign keys.
    assert "goals.values() if isinstance(goals, dict) else goals" in body
    # An empty list means an empty list. Only a seed that mentions neither key
    # falls back to the finales the data declares.
    assert "elif slot_data.get(" in body


def test_a_collected_finale_never_sends_the_goal() -> None:
    """The goal is for a run finished in play. A finale that arrives by collect
    or release still counts as done, for the seals and for `run_complete`, but
    the poll does not report the goal for it."""
    pump = CLIENT.split("async def pump", 1)[1]
    tail = pump.split("ctx.sync_completed_missions()", 1)
    assert len(tail) == 2, "the poll no longer syncs completed missions"
    after = tail[1][:400]
    assert "if ctx.suspension_enabled and ctx.suspension_played:" in after
    assert after.index("if ctx.suspension_enabled and ctx.suspension_played:") < after.index(
        "await report_goal(ctx)"
    ), "the poll reports the goal unconditionally again"


def test_a_goal_event_completing_the_run_sends_the_goal() -> None:
    pump = CLIENT.split("async def pump", 1)[1]
    goal = pump.split('elif event.kind == "GOAL":', 1)[1].split("elif event.kind", 1)[0]
    assert "await report_goal(ctx)" in goal


def test_a_suspension_clear_sent_this_session_sends_the_goal() -> None:
    """Suspension has no finale event: a clear sent from this client, for this
    slot, is what marks its goal as played."""
    pump = CLIENT.split("async def pump", 1)[1]
    sent = pump.split('"cmd": "LocationChecks"', 1)[1][:300]
    assert "is_suspension_location" in sent
    assert "ctx.suspension_played = True" in sent
    assert "def is_suspension_location" in CLIENT
    connected = CLIENT.split('if cmd == "Connected":', 1)[1][:400]
    assert "self.suspension_played = False" in connected


def test_a_different_slot_can_send_its_own_goal() -> None:
    """`goal_sent` is per slot: a second slot connected from the same client
    must not inherit the first one's sent goal."""
    connected = CLIENT.split('if cmd == "Connected":', 1)[1][:400]
    assert "self.goal_sent = False" in connected


def test_the_first_batch_after_connecting_delivers_no_filler_or_traps() -> None:
    """A freshly started client must not redeliver the slot's whole filler and
    trap history: the first batch after connecting is backlog. A later batch
    still delivers."""
    init = CLIENT.split("def __init__", 1)[1].split("\n    def ", 1)[0]
    assert "self.items_synced = False" in init
    connected = CLIENT.split('if cmd == "Connected":', 1)[1][:400]
    assert "self.items_synced = False" in connected
    receive = CLIENT.split("def receive_items", 1)[1].split("\n    def ", 1)[0]
    assert "backlog = not self.items_synced" in receive
    assert "is_new = not backlog and" in receive
    assert "self.items_synced = True" in receive
    assert receive.index("is_new = not backlog and") < receive.index(
        "self.items_synced = True"
    ), "the batch is marked synced before its items are judged"
