from __future__ import annotations

import asyncio
import io
import json
import zipfile
from pathlib import Path

from PIL import Image

from gallery_sr.app import create_app
from gallery_sr.config import Config
from gallery_sr.models import REALCUGAN, REALESRGAN


def encoded(image: Image.Image, fmt: str) -> bytes:
    out = io.BytesIO()
    image.save(out, fmt)
    return out.getvalue()


def batch(*pages: bytes) -> bytes:
    out = io.BytesIO()
    with zipfile.ZipFile(out, "w", zipfile.ZIP_STORED) as archive:
        for i, page in enumerate(pages):
            archive.writestr(str(i), page)
    return out.getvalue()


def answer(body: bytes) -> dict[str, Image.Image]:
    with zipfile.ZipFile(io.BytesIO(body)) as archive:
        return {name: Image.open(io.BytesIO(archive.read(name))) for name in archive.namelist()}


def calls(tools_root: Path, engine=REALESRGAN) -> list[dict]:
    log = engine.directory(tools_root) / "calls.jsonl"
    return [json.loads(line) for line in log.read_text().splitlines()] if log.exists() else []


async def client_for(aiohttp_client, config: Config):
    return await aiohttp_client(create_app(config))


async def test_models_lists_every_model_and_the_gpu(aiohttp_client, config):
    client = await client_for(aiohttp_client, config)
    info = await (await client.get("/v1/models")).json()
    assert info["gpus"] == ["0: Fake GPU 4080"]
    assert info["maxPages"] == 4
    assert [m["id"] for m in info["models"]] == [
        "realesr-animevideov3", "realesrgan-x4plus-anime", "realesrgan-x4plus",
        "realcugan-se", "realcugan-pro", "realcugan-nose",
    ]
    assert all(m["available"] for m in info["models"])
    assert {m["id"]: m["denoiseLevels"] for m in info["models"]}["realcugan-se"] == [-1, 0, 3]


async def test_a_batch_comes_back_upscaled_page_by_page(aiohttp_client, config, tools_root):
    client = await client_for(aiohttp_client, config)
    probe_runs = len(calls(tools_root))
    red = Image.new("RGB", (40, 30), (220, 20, 20))
    # Transparent on the left half: shown on white, as on the desktop.
    half = Image.new("RGBA", (20, 10), (0, 0, 255, 255))
    half.paste((0, 0, 0, 0), (0, 0, 10, 10))
    green = Image.new("RGB", (10, 50), (20, 200, 20))

    response = await client.post(
        "/v1/upscale?model=realesr-animevideov3&scale=2",
        data=batch(encoded(red, "JPEG"), encoded(half, "PNG"), encoded(green, "WEBP")),
    )
    assert response.status == 200, await response.text()
    pages = answer(await response.read())
    assert sorted(pages) == ["0", "1", "2"]
    assert pages["0"].size == (80, 60) and pages["0"].format == "JPEG"
    assert pages["1"].size == (40, 20)
    assert pages["1"].convert("RGB").getpixel((5, 10))[0] > 240  # white, not black
    assert pages["1"].convert("RGB").getpixel((35, 10))[2] > 200  # still blue
    assert pages["2"].size == (20, 100)

    # One run of the program for the batch, with the app's arguments.
    runs = calls(tools_root)[probe_runs:]
    assert len(runs) == 1
    opts = dict(zip(runs[0]["args"][::2], runs[0]["args"][1::2]))
    assert opts["-s"] == "2" and opts["-n"] == "realesr-animevideov3" and opts["-f"] == "jpg" and opts["-g"] == "0"
    assert opts["-m"] == str(REALESRGAN.directory(tools_root) / "models")
    assert runs[0]["cwd"] == str(REALESRGAN.directory(tools_root))
    # Nothing of the run is left.
    assert list(config.work_dir.iterdir()) == []


async def test_realcugan_takes_the_denoise_level(aiohttp_client, config, tools_root):
    client = await client_for(aiohttp_client, config)
    response = await client.post("/v1/upscale?model=realcugan-se&scale=3&denoise=-1",
                                 data=batch(encoded(Image.new("RGB", (8, 8)), "PNG")))
    assert response.status == 200
    assert answer(await response.read())["0"].size == (24, 24)
    opts = dict(zip(calls(tools_root, REALCUGAN)[-1]["args"][::2], calls(tools_root, REALCUGAN)[-1]["args"][1::2]))
    assert opts["-n"] == "-1" and opts["-s"] == "3"
    assert opts["-m"] == str(REALCUGAN.directory(tools_root) / "models-se")


async def test_requests_the_models_cannot_take_are_refused(aiohttp_client, config):
    client = await client_for(aiohttp_client, config)
    page = encoded(Image.new("RGB", (8, 8)), "PNG")
    for query, body in [
        ("model=nope&scale=2", batch(page)),
        ("model=realesrgan-x4plus&scale=2", batch(page)),
        ("model=realesr-animevideov3&scale=2&denoise=3", batch(page)),
        ("model=realcugan-pro&scale=2&denoise=1", batch(page)),
        ("model=realesr-animevideov3&scale=x", batch(page)),
        ("model=realesr-animevideov3&scale=2", b"not a zip"),
        ("model=realesr-animevideov3&scale=2", batch(*[page] * 5)),
    ]:
        response = await client.post(f"/v1/upscale?{query}", data=body)
        assert response.status == 400, query
        assert "error" in await response.json()

    out = io.BytesIO()
    with zipfile.ZipFile(out, "w") as archive:
        archive.writestr("../0", page)
    assert (await client.post("/v1/upscale?model=realesr-animevideov3&scale=2", data=out.getvalue())).status == 400


async def test_pages_that_cannot_be_upscaled_are_left_out(aiohttp_client, config):
    client = await client_for(aiohttp_client, config)
    page = encoded(Image.new("RGB", (8, 8), (1, 2, 3)), "PNG")
    too_large = encoded(Image.new("RGB", (1001, 1000)), "PNG")
    animated = io.BytesIO()
    Image.new("RGB", (8, 8)).save(animated, "GIF", save_all=True,
                                  append_images=[Image.new("RGB", (8, 8), (255, 0, 0))])
    response = await client.post("/v1/upscale?model=realesr-animevideov3&scale=2",
                                 data=batch(page, b"broken", too_large, animated.getvalue()))
    assert response.status == 200
    assert sorted(answer(await response.read())) == ["0"]


async def test_a_page_the_program_writes_nothing_for_has_no_entry(aiohttp_client, config, tools_root):
    client = await client_for(aiohttp_client, config)
    (REALESRGAN.directory(tools_root) / "skip-0001").touch()
    page = encoded(Image.new("RGB", (8, 8)), "PNG")
    response = await client.post("/v1/upscale?model=realesr-animevideov3&scale=2", data=batch(page, page, page))
    assert sorted(answer(await response.read())) == ["0", "2"]


async def test_a_failing_program_answers_an_error(aiohttp_client, config, tools_root):
    client = await client_for(aiohttp_client, config)
    (REALESRGAN.directory(tools_root) / "fail").touch()
    response = await client.post("/v1/upscale?model=realesr-animevideov3&scale=2",
                                 data=batch(encoded(Image.new("RGB", (8, 8)), "PNG")))
    assert response.status == 500
    assert "vkCreateInstance failed" in (await response.json())["error"]
    assert list(config.work_dir.iterdir()) == []


async def test_a_program_that_does_not_run_at_start_is_unavailable(aiohttp_client, config, tools_root):
    (REALCUGAN.directory(tools_root) / "fail").touch()
    REALESRGAN.executable_path(tools_root).unlink()
    client = await client_for(aiohttp_client, config)
    info = await (await client.get("/v1/models")).json()
    assert info["engines"]["realesrgan"] == {"installed": False, "error": None}
    assert "vkCreateInstance failed" in info["engines"]["realcugan"]["error"]
    assert not any(m["available"] for m in info["models"])
    response = await client.post("/v1/upscale?model=realcugan-se&scale=2&denoise=0",
                                 data=batch(encoded(Image.new("RGB", (8, 8)), "PNG")))
    assert response.status == 503


async def test_the_gpu_runs_one_batch_at_a_time(aiohttp_client, config, tools_root):
    client = await client_for(aiohttp_client, config)
    probe_runs = len(calls(tools_root))
    (REALESRGAN.directory(tools_root) / "delay").write_text("0.4")
    page = encoded(Image.new("RGB", (8, 8)), "PNG")

    async def one() -> int:
        response = await client.post("/v1/upscale?model=realesr-animevideov3&scale=2", data=batch(page))
        return response.status

    assert await asyncio.gather(one(), one(), one()) == [200, 200, 200]
    runs = sorted(calls(tools_root)[probe_runs:], key=lambda run: run["start"])
    assert len(runs) == 3
    for earlier, later in zip(runs, runs[1:]):
        assert later["start"] >= earlier["end"]
