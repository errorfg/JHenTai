"""Stand-ins for the two upscaler programs: same command line, a plain
resize instead of a model. Each run is appended to calls.jsonl next to
them: its arguments and when it started and ended."""

from __future__ import annotations

import sys
from pathlib import Path

import pytest

from gallery_sr.config import Config
from gallery_sr.models import ENGINES

FAKE_PROGRAM = '''#!{python}
import json, sys, time
from pathlib import Path
from PIL import Image

args = sys.argv[1:]
opts = dict(zip(args[::2], args[1::2]))
here = Path(__file__).resolve().parent
started = time.time()
print("[0 Fake GPU 4080]  queueC=2[8]  queueG=0[16]", file=sys.stderr)
if (here / "fail").exists():
    print("vkCreateInstance failed", file=sys.stderr)
    sys.exit(255)
time.sleep(float((here / "delay").read_text()) if (here / "delay").exists() else 0)
scale = int(opts["-s"])
for page in sorted(Path(opts["-i"]).iterdir()):
    if (here / ("skip-" + page.stem)).exists():
        continue
    with Image.open(page) as image:
        assert image.mode == "RGB", image.mode
        image.resize((image.width * scale, image.height * scale)).save(
            Path(opts["-o"]) / (page.stem + "." + opts["-f"]), "JPEG", quality=95)
with (here / "calls.jsonl").open("a") as log:
    log.write(json.dumps({{"args": args, "cwd": str(Path.cwd()), "start": started, "end": time.time()}}) + "\\n")
'''


@pytest.fixture
def tools_root(tmp_path: Path) -> Path:
    root = tmp_path / "tools"
    for engine in ENGINES:
        program = engine.executable_path(root)
        program.parent.mkdir(parents=True, exist_ok=True)
        program.write_text(FAKE_PROGRAM.format(python=sys.executable))
        program.chmod(0o755)
    return root


@pytest.fixture
def config(tmp_path: Path, tools_root: Path) -> Config:
    return Config(tools_root=tools_root, work_dir=tmp_path / "work", max_pages=4, max_page_bytes=2_000_000,
                  max_pixels=1_000_000, timeout_seconds=20)
