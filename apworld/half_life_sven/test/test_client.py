"""Client state tests: slot switches, local and remote completions, air
acceleration and the machine preferences. Run from an Archipelago checkout."""

import tempfile
import unittest
from pathlib import Path
from unittest import mock

from ..client import bridge as bridge_module
from ..client.bridge import Bridge
from ..data import air_accelerate_steps


def make_context(store: Path):
    from ..client.launcher import HalfLifeSvenContext

    with mock.patch.object(HalfLifeSvenContext, "resolve_game_dir", lambda self: None):
        ctx = HalfLifeSvenContext(None, None)
    ctx.bridge = Bridge(store)
    return ctx


def connect(ctx, seed: str, slot: int, checked=(), slot_data=None) -> None:
    ctx.seed_name = seed
    ctx.slot = slot
    ctx.checked_locations = set(checked)
    ctx.on_package("Connected", {"slot_data": slot_data or {}, "slot": slot, "players": [],
                                 "checked_locations": list(checked),
                                 "missing_locations": [], "slot_info": {},
                                 "hint_points": 0})


def complete_id(ctx, chapter_key: str) -> int:
    return next(
        entry["id"] for entry in ctx.campaign["locations"]
        if entry["trigger"]["type"] == "chapter_complete"
        and entry["trigger"]["chapter"] == chapter_key
    )


class TestSlotsAndCompletions(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self) -> None:
        self.dir = tempfile.TemporaryDirectory()
        self.ctx = make_context(Path(self.dir.name))

    async def asyncTearDown(self) -> None:
        self.dir.cleanup()

    async def test_a_different_slot_forgets_the_last_ones_missions(self) -> None:
        connect(self.ctx, "seed", 1)
        self.ctx.finished_here("office_complex")
        self.assertIn("office_complex", self.ctx.completed_missions)
        connect(self.ctx, "seed", 2)
        self.assertNotIn("office_complex", self.ctx.completed_missions)

    async def test_the_same_slot_keeps_them(self) -> None:
        connect(self.ctx, "seed", 1)
        self.ctx.finished_here("office_complex")
        connect(self.ctx, "seed", 1)
        self.assertIn("office_complex", self.ctx.completed_missions)

    async def test_server_completions_never_played_here_are_remote(self) -> None:
        connect(self.ctx, "seed", 1)
        self.ctx.finished_here("blast_pit")
        self.ctx.checked_locations = {complete_id(self.ctx, "office_complex")}
        self.ctx.sync_completed_missions()
        self.assertEqual(self.ctx.remote_completed, {"office_complex"})

    async def test_local_completions_survive_a_client_restart(self) -> None:
        connect(self.ctx, "seed", 1)
        self.ctx.finished_here("blast_pit")
        again = make_context(Path(self.dir.name))
        connect(again, "seed", 1, checked=[complete_id(again, "blast_pit")])
        self.assertNotIn("blast_pit", again.remote_completed)

    async def test_an_old_run_with_no_record_counts_as_played_here(self) -> None:
        connect(self.ctx, "seed", 1, checked=[complete_id(self.ctx, "blast_pit")])
        self.assertEqual(self.ctx.remote_completed, set())

    async def test_newrun_makes_them_remote(self) -> None:
        connect(self.ctx, "seed", 1, checked=[complete_id(self.ctx, "blast_pit")])
        self.ctx.command_processor(self.ctx)("/newrun")
        self.assertEqual(self.ctx.remote_completed, {"blast_pit"})

    async def test_the_snapshot_carries_the_new_keys(self) -> None:
        connect(self.ctx, "seed", 1, slot_data={
            "air_acceleration": [10, 100], "butterfingers_reissue": False,
            "melee_throw": True,
        })
        self.ctx.publish_snapshot(force=True)
        text = (Path(self.dir.name) / "ap_in.txt").read_text(encoding="utf-8")
        self.assertIn("butterfingers_reissue=0", text)
        self.assertIn("air_accelerate=10", text)
        self.assertIn("melee_throw=1", text)
        self.assertIn("remote=", text)


class TestAirAcceleration(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self) -> None:
        self.dir = tempfile.TemporaryDirectory()
        self.ctx = make_context(Path(self.dir.name))

    async def asyncTearDown(self) -> None:
        self.dir.cleanup()

    async def test_each_item_is_a_step(self) -> None:
        connect(self.ctx, "seed", 1, slot_data={"air_acceleration": [10, 100]})
        item_id = next(
            entry["id"] for entry in self.ctx.campaign["items"]
            if entry["name"] == "Progressive Air Acceleration"
        )
        self.assertEqual(self.ctx.air_accelerate, 10)
        self.ctx.apply_item(item_id)
        self.assertEqual(self.ctx.air_accelerate, air_accelerate_steps(10, 100)[0])
        for _ in range(40):
            self.ctx.apply_item(item_id)
        self.assertEqual(self.ctx.air_accelerate, 100)

    async def test_a_seed_without_it_leaves_the_server_alone(self) -> None:
        connect(self.ctx, "seed", 1)
        self.assertEqual(self.ctx.air_accelerate, -1)


class TestForceMeleeThrow(unittest.IsolatedAsyncioTestCase):
    async def test_it_adds_the_item_only_when_the_seed_has_none(self) -> None:
        with tempfile.TemporaryDirectory() as path:
            ctx = make_context(Path(path))
            connect(ctx, "seed", 1)
            ctx.command_processor(ctx)("/force_melee_throw")
            self.assertIn("Melee Throw", ctx.held_item_names)
            connect(ctx, "seed", 2, slot_data={"melee_throw": True})
            self.assertNotIn("Melee Throw", ctx.held_item_names)


class TestPrefs(unittest.IsolatedAsyncioTestCase):
    async def test_custom_bots_default_on_and_round_trip(self) -> None:
        with tempfile.TemporaryDirectory() as path:
            store = Path(path)
            self.assertTrue(bridge_module.custom_bots_enabled(store))
            (store / bridge_module.PREFS_NAME).write_text("other=7\n", encoding="utf-8")
            bridge_module.write_pref(store, "custom_bots", "0")
            self.assertFalse(bridge_module.custom_bots_enabled(store))
            self.assertEqual(bridge_module.read_prefs(store)["other"], "7")
