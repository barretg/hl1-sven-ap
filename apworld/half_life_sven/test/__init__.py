"""World tests.

These run under an Archipelago source checkout (`pytest test/general` picks the
world up automatically, and these add world-specific cases on top). They are
excluded from the packaged .apworld by tools/build_apworld.py.
"""

from BaseClasses import CollectionState
from test.bases import WorldTestBase

from .. import GAME_NAME


class HalfLifeSvenTestBase(WorldTestBase):
    game = GAME_NAME
    player: int = 1

    def can_reach_entrance(self, entrance: str, state: CollectionState | None = None) -> bool:
        """`WorldTestBase`'s check, against `state` when given rather than the
        multiworld's own."""
        state = state if state is not None else self.multiworld.state
        return state.can_reach(entrance, "Entrance", self.player)
