"""The HTTP interface.

GET  /v1/models   the models with their scales and denoise levels, whether
                  each can run here, and the GPUs the programs see.
POST /v1/upscale?model=<id>&scale=<n>&denoise=<n>
                  Body: a ZIP of the pages of a batch, each entry named by
                  its number in the batch ("0", "1", ...), as the page's
                  file (JPEG, PNG or WebP). Answer: a ZIP with an entry of
                  the same name for every page upscaled, as JPEG; a page
                  left out (unreadable, animated, too large) has none.
"""

from __future__ import annotations

import io
import logging
import re
import zipfile

from aiohttp import web

from .config import Config
from .models import MODELS, model_by_id
from .upscaler import Upscaler

log = logging.getLogger(__name__)

_ENTRY_NAME = re.compile(r"^\d{1,4}$")


def _error(status: int, message: str) -> web.Response:
    return web.json_response({"error": message}, status=status)


def create_app(config: Config, upscaler: Upscaler | None = None) -> web.Application:
    upscaler = upscaler or Upscaler(config)
    app = web.Application(client_max_size=config.max_request_bytes)

    async def probe(_: web.Application) -> None:
        await upscaler.probe()

    app.on_startup.append(probe)

    async def models(_: web.Request) -> web.Response:
        return web.json_response({
            "gpus": upscaler.gpus,
            "maxPages": config.max_pages,
            "engines": {name: {"installed": s.installed, "error": s.error} for name, s in upscaler.engines.items()},
            "models": [
                {
                    "id": m.id,
                    "engine": m.engine.name,
                    "scales": list(m.scales),
                    "denoiseLevels": list(m.denoise_levels),
                    "available": upscaler.usable(m.engine),
                }
                for m in MODELS
            ],
        })

    async def upscale(request: web.Request) -> web.Response:
        model = model_by_id(request.query.get("model", ""))
        if model is None:
            return _error(400, f"unknown model {request.query.get('model')!r}")
        try:
            scale = int(request.query.get("scale", ""))
            denoise = int(request.query.get("denoise", "0"))
        except ValueError:
            return _error(400, "scale and denoise must be integers")
        if scale not in model.scales:
            return _error(400, f"{model.id} has no scale {scale}")
        if (denoise not in model.denoise_levels) if model.denoise_levels else denoise != 0:
            return _error(400, f"{model.id} has no denoise level {denoise}")
        if not upscaler.usable(model.engine):
            state = upscaler.engines[model.engine.name]
            return _error(503, f"{model.engine.name} is not installed" if not state.installed else
                          f"{model.engine.name} does not run: {state.error}")

        body = await request.read()
        try:
            archive = zipfile.ZipFile(io.BytesIO(body))
        except zipfile.BadZipFile:
            return _error(400, "the body is not a ZIP")
        with archive:
            entries = [info for info in archive.infolist() if not info.is_dir()]
            if not entries:
                return _error(400, "no pages")
            if len(entries) > config.max_pages:
                return _error(400, f"{len(entries)} pages, at most {config.max_pages} in a batch")
            names = [info.filename for info in entries]
            if any(not _ENTRY_NAME.match(n) for n in names) or len(set(names)) != len(names):
                return _error(400, "pages are named by their number in the batch, each once")
            pages: list[bytes] = []
            for info in entries:
                with archive.open(info) as file:
                    data = file.read(config.max_page_bytes + 1)
                if len(data) > config.max_page_bytes:
                    return _error(400, f"page {info.filename} is over {config.max_page_bytes} bytes")
                pages.append(data)

        result = await upscaler.run(model, scale, denoise, pages)
        label = model.label(scale, denoise)
        if result.error is not None:
            log.error("%s on %d page(s) failed: %s", label, len(pages), result.error)
            return _error(500, result.error)

        answer = io.BytesIO()
        with zipfile.ZipFile(answer, "w", zipfile.ZIP_STORED) as out:
            for page_name, data in zip(names, result.pages):
                if data is not None:
                    out.writestr(page_name, data)
        done = sum(data is not None for data in result.pages)
        log.info("%s: %d/%d page(s) in %d ms", label, done, len(pages), result.elapsed_ms)
        return web.Response(
            body=answer.getvalue(),
            content_type="application/zip",
            headers={"X-Sr-Elapsed-Ms": str(result.elapsed_ms)},
        )

    app.router.add_get("/v1/models", models)
    app.router.add_post("/v1/upscale", upscale)
    return app
