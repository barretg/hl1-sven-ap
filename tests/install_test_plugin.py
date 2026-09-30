"""Install the current plugin and the APTest harness into Sven Co-op.

Copies the Archipelago plugin straight from this checkout (the same files
`/install` copies from a packaged apworld), then copies `tests/aptest/aptest.as`
and registers both in default_plugins.txt. See `tests/aptest/aptest.as` for the
in-game commands.

Usage:
    python tests/install_test_plugin.py
    python tests/install_test_plugin.py --game "F:/SteamLibrary/steamapps/common/Sven Co-op"
    python tests/install_test_plugin.py --remove-test    # drop only the harness
"""

from __future__ import annotations

import argparse
import shutil
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO_ROOT / "apworld" / "half_life_sven"))

import plugin  # noqa: E402

LINUX_DEFAULT_GAME = Path("/mnt/win/f/SteamLibrary/steamapps/common/Sven Co-op")

TEST_SOURCE = REPO_ROOT / "tests" / "aptest" / "aptest.as"
TEST_SUBDIR = "plugins/aptest"
TEST_SCRIPT_KEY = '"aptest/aptest"'
TEST_ENTRY = """	"plugin"
	{
		"name" "APTest"
		"script" "aptest/aptest"
	}
"""


def register_test(svencoop: Path) -> bool:
    """Add the harness after the main plugin's block. True if it changed."""
    config = svencoop / plugin.CONFIG_NAME
    text = config.read_text(encoding="utf-8")
    if TEST_SCRIPT_KEY in text:
        return False

    index = text.rstrip().rfind("}")
    if index < 0:
        raise ValueError(f"unexpected format in {config}")

    config.write_text(text[:index] + TEST_ENTRY + text[index:], encoding="utf-8")
    return True


def remove_test(svencoop: Path) -> bool:
    """Deregister the harness and delete its script. True if the config changed."""
    shutil.rmtree(svencoop / "scripts" / TEST_SUBDIR, ignore_errors=True)
    state = svencoop / "scripts" / plugin.STORE_SUBDIR / "aptest_state.txt"
    state.unlink(missing_ok=True)

    config = svencoop / plugin.CONFIG_NAME
    text = config.read_text(encoding="utf-8")
    # The main plugin's block remover, pointed at the harness's key instead.
    original_key = plugin.PLUGIN_SCRIPT_KEY
    plugin.PLUGIN_SCRIPT_KEY = TEST_SCRIPT_KEY
    try:
        stripped = plugin.remove_plugin_block(text)
    finally:
        plugin.PLUGIN_SCRIPT_KEY = original_key
    if stripped == text:
        return False
    config.write_text(stripped, encoding="utf-8")
    return True


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--game",
        type=Path,
        default=LINUX_DEFAULT_GAME if sys.platform.startswith("linux") else None,
        help=f"Sven Co-op install path (default on Linux: {LINUX_DEFAULT_GAME})",
    )
    parser.add_argument(
        "--remove-test", action="store_true", help="remove only the APTest harness"
    )
    args = parser.parse_args(argv)

    if args.game is None:
        parser.error("--game is required on this platform")

    try:
        svencoop = plugin.resolve_svencoop(args.game)

        if args.remove_test:
            changed = remove_test(svencoop)
            print("removed APTest" + (" and deregistered it" if changed else ""))
            return 0

        written, changed = plugin.install(args.game)
        print(f"copied {written} plugin files into {svencoop / 'scripts'}")
        if changed:
            print("registered Archipelago in default_plugins.txt (backup written alongside it)")

        target = svencoop / "scripts" / TEST_SUBDIR / TEST_SOURCE.name
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(TEST_SOURCE, target)
        print(f"copied {TEST_SOURCE.name} into {target.parent}")
        if register_test(svencoop):
            print("registered APTest in default_plugins.txt")
    except (OSError, ValueError) as exc:
        raise SystemExit(str(exc))

    print("\nClose the Archipelago client, then in Sven: map -sp_campaign_portal")
    print("(or as_reloadplugins if already running), and type !apt in chat.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
