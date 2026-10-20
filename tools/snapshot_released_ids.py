"""Record the datapackage of every released tag, for the back-compat tests.

A seed carries the ids of the release that generated it, and the current apworld
must still name every one of them: Universal Tracker refuses the whole
datapackage over a single id it does not know. Each tag is exported, its world
imported against an Archipelago checkout, and its `item_name_to_id` and
`location_name_to_id` written to `tests/fixtures/released_ids.json`.

Run after tagging a release:

    python tools/snapshot_released_ids.py --archipelago ~/Projects/MoreProjects/Archipelago-src
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
import tarfile
import tempfile
from io import BytesIO
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
OUT_PATH = REPO_ROOT / "tests" / "fixtures" / "released_ids.json"

# Runs in the Archipelago interpreter, with only the exported tag on its path.
DUMP = """
import importlib, json, os, sys, warnings
warnings.filterwarnings("ignore")
ap, root = sys.argv[1], sys.argv[2]
sys.path[:0] = [root, ap]
os.chdir(ap)
items = importlib.import_module("half_life_sven.items")
locations = importlib.import_module("half_life_sven.locations")
print(json.dumps({
    "items": {str(v): k for k, v in sorted(items.item_name_to_id.items(), key=lambda e: e[1])},
    "locations": {str(v): k for k, v in sorted(locations.location_name_to_id.items(), key=lambda e: e[1])},
}))
"""


def tags() -> list[str]:
    out = subprocess.run(
        ["git", "tag", "--list", "v*", "--sort=v:refname"],
        cwd=REPO_ROOT, check=True, capture_output=True, text=True,
    ).stdout
    return out.split()


def dump_tag(tag: str, archipelago: Path, python: Path) -> dict:
    archive = subprocess.run(
        ["git", "archive", tag, "apworld"], cwd=REPO_ROOT, check=True, capture_output=True,
    ).stdout
    with tempfile.TemporaryDirectory() as tmp:
        with tarfile.open(fileobj=BytesIO(archive)) as tar:
            tar.extractall(tmp, filter="data")
        out = subprocess.run(
            [str(python), "-c", DUMP, str(archipelago), str(Path(tmp) / "apworld")],
            check=True, capture_output=True, text=True,
        ).stdout
    return json.loads(out)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--archipelago", type=Path, required=True,
                        help="Archipelago source checkout")
    parser.add_argument("--python", type=Path,
                        help="its interpreter (default: <archipelago>/.venv/bin/python)")
    args = parser.parse_args()
    archipelago = args.archipelago.expanduser().resolve()
    python = args.python or archipelago / ".venv" / "bin" / "python"

    snapshot = {}
    for tag in tags():
        snapshot[tag] = dump_tag(tag, archipelago, python)
        print(f"{tag}: {len(snapshot[tag]['items'])} items, "
              f"{len(snapshot[tag]['locations'])} locations", file=sys.stderr)

    OUT_PATH.parent.mkdir(parents=True, exist_ok=True)
    OUT_PATH.write_text(json.dumps(snapshot, indent=1) + "\n", encoding="utf-8")
    print(f"wrote {OUT_PATH.relative_to(REPO_ROOT)}", file=sys.stderr)


if __name__ == "__main__":
    main()
