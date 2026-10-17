"""Downloads and unpacks the Linux releases of the upscaler programs."""

from __future__ import annotations

import logging
import shutil
import tempfile
import urllib.request
import zipfile
from pathlib import Path

from .config import Config
from .models import ENGINES

log = logging.getLogger(__name__)


def install_tools(config: Config, downloaded: Path | None = None) -> None:
    """[downloaded]: a folder holding the release zips under their names on
    GitHub, downloaded elsewhere; else they are downloaded here."""
    # Only the proxy in the config file: none is taken from elsewhere.
    proxies = {"http": config.install_proxy, "https": config.install_proxy} if config.install_proxy else {}
    opener = urllib.request.build_opener(urllib.request.ProxyHandler(proxies))
    config.tools_root.mkdir(parents=True, exist_ok=True)
    for engine in ENGINES:
        target = config.tools_root / engine.name
        with tempfile.TemporaryDirectory() as scratch:
            if downloaded is not None:
                archive = downloaded / engine.url.rsplit("/", 1)[-1]
            else:
                archive = Path(scratch) / "release.zip"
                log.info("downloading %s", engine.url)
                with opener.open(engine.url, timeout=60) as response, archive.open("wb") as file:
                    shutil.copyfileobj(response, file)
            if target.exists():
                shutil.rmtree(target)
            with zipfile.ZipFile(archive) as release:
                release.extractall(target)
        # ZIP keeps no file modes.
        executable = engine.executable_path(config.tools_root)
        executable.chmod(0o755)
        log.info("installed %s", executable)
