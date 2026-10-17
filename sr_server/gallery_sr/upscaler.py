"""Runs the upscaler programs on the pages of a request."""

from __future__ import annotations

import asyncio
import io
import logging
import re
import shutil
import tempfile
import time
from dataclasses import dataclass
from pathlib import Path

from PIL import Image, ImageOps

from .config import Config
from .models import ENGINES, MODELS, Engine, Model

log = logging.getLogger(__name__)

_GPU_LINE = re.compile(r"^\[(\d+) ([^\]]+)\]", re.MULTILINE)


class PageError(Exception):
    """A page that is not upscaled: unreadable, animated or too large."""


@dataclass
class RunResult:
    """Upscaled pages (JPEG) in the order given, None where a page was left
    out; [error] when the program failed."""

    pages: list[bytes | None]
    elapsed_ms: int = 0
    error: str | None = None


@dataclass
class EngineState:
    installed: bool = False
    # Why the program could not run a page when tried at start.
    error: str | None = None


def flatten(image: Image.Image) -> Image.Image:
    """RGB, transparent parts on white, as the app gives pages to the
    programs on the desktop: given an alpha channel, they upscale it too
    and write PNG whatever was asked for."""
    image = ImageOps.exif_transpose(image)
    if image.mode in ("RGBA", "LA", "PA") or (image.mode == "P" and "transparency" in image.info):
        rgba = image.convert("RGBA")
        white = Image.new("RGBA", rgba.size, (255, 255, 255, 255))
        return Image.alpha_composite(white, rgba).convert("RGB")
    return image.convert("RGB")


def prepare_page(data: bytes, target: Path, max_pixels: int) -> None:
    """Writes the page [data] (JPEG, PNG or WebP) as an RGB PNG to [target]."""
    try:
        with Image.open(io.BytesIO(data)) as image:
            if image.width * image.height > max_pixels:
                raise PageError(f"{image.width}x{image.height} is over {max_pixels} pixels")
            if getattr(image, "n_frames", 1) > 1:
                raise PageError("animated")
            image.load()
            flatten(image).save(target, "PNG", compress_level=1)
    except PageError:
        raise
    except Exception as e:  # Pillow raises many kinds for a broken file.
        raise PageError(f"unreadable: {e}") from e


class Upscaler:
    """One run of a program at a time: the GPU is shared by every request."""

    def __init__(self, config: Config):
        self.config = config
        self._lock = asyncio.Lock()
        self.gpus: list[str] = []
        self.engines: dict[str, EngineState] = {e.name: EngineState() for e in ENGINES}

    def usable(self, engine: Engine) -> bool:
        state = self.engines[engine.name]
        return state.installed and state.error is None

    async def probe(self) -> None:
        """Runs each installed program once on a small page: whether it
        works with this GPU and driver, and which GPUs it sees."""
        probe_page = io.BytesIO()
        Image.new("RGB", (16, 16), (200, 120, 40)).save(probe_page, "PNG")
        for engine in ENGINES:
            state = self.engines[engine.name]
            state.installed = engine.is_installed(self.config.tools_root)
            state.error = None
            if not state.installed:
                log.warning("%s is not installed under %s", engine.name, self.config.tools_root)
                continue
            model = next(m for m in MODELS if m.engine is engine)
            result = await self.run(model, model.scales[0], model.denoise_levels[0] if model.denoise_levels else 0,
                                    [probe_page.getvalue()], probing=True)
            if result.error is not None or result.pages[0] is None:
                state.error = result.error or "no result"
                log.error("%s does not run: %s", engine.name, state.error)
            else:
                log.info("%s runs (%d ms)", engine.name, result.elapsed_ms)

    async def run(self, model: Model, scale: int, denoise: int, pages: list[bytes], probing: bool = False) -> RunResult:
        config = self.config
        config.work_dir.mkdir(parents=True, exist_ok=True)
        run_dir = Path(tempfile.mkdtemp(prefix="run-", dir=config.work_dir))
        try:
            source = run_dir / "in"
            target = run_dir / "out"
            source.mkdir()
            target.mkdir()

            def name(i: int) -> str:
                return f"{i:04d}"

            def write_pages() -> list[bool]:
                written = []
                for i, data in enumerate(pages):
                    try:
                        prepare_page(data, source / f"{name(i)}.png", config.max_pixels)
                        written.append(True)
                    except PageError as e:
                        log.warning("page %d left out: %s", i, e)
                        written.append(False)
                return written

            written = await asyncio.to_thread(write_pages)
            if not any(written):
                return RunResult(pages=[None] * len(pages))

            engine = model.engine
            if not probing and not self.usable(engine):
                return RunResult(pages=[None] * len(pages), error=f"{engine.name} is not usable")
            arguments = model.arguments(config.tools_root, scale, denoise, config.gpu_id, source, target)
            async with self._lock:
                started = time.monotonic()
                process = await asyncio.create_subprocess_exec(
                    str(engine.executable_path(config.tools_root)),
                    *arguments,
                    # The program's folder holds the libraries it loads.
                    cwd=str(engine.directory(config.tools_root)),
                    stdin=asyncio.subprocess.DEVNULL,
                    stdout=asyncio.subprocess.DEVNULL,
                    stderr=asyncio.subprocess.PIPE,
                )
                try:
                    _, stderr_bytes = await asyncio.wait_for(process.communicate(), config.timeout_seconds)
                except TimeoutError:
                    process.kill()
                    await process.wait()
                    return RunResult(pages=[None] * len(pages), error=f"timed out after {config.timeout_seconds:g} s")
                elapsed_ms = round((time.monotonic() - started) * 1000)

            stderr = stderr_bytes.decode("utf-8", "replace")
            gpus = [f"{m.group(1)}: {m.group(2)}" for m in _GPU_LINE.finditer(stderr)]
            if gpus:
                self.gpus = list(dict.fromkeys(gpus))
            if process.returncode != 0:
                tail = stderr.strip().splitlines()[-5:]
                return RunResult(pages=[None] * len(pages), elapsed_ms=elapsed_ms,
                                 error=f"exited with {process.returncode}: {' | '.join(tail)}")

            results: list[bytes | None] = []
            for i, ok in enumerate(written):
                output = target / f"{name(i)}.jpg"
                if ok and output.is_file():
                    results.append(output.read_bytes())
                else:
                    if ok:
                        log.error("no result for page %d: %s", i, stderr.strip().splitlines()[-1:] or "")
                    results.append(None)
            return RunResult(pages=results, elapsed_ms=elapsed_ms)
        finally:
            shutil.rmtree(run_dir, ignore_errors=True)
