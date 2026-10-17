from __future__ import annotations

import os
import zipfile
from pathlib import Path

from gallery_sr.config import Config
from gallery_sr.install import install_tools
from gallery_sr.models import ENGINES


def test_releases_downloaded_elsewhere_unpack_where_the_service_runs_them(tmp_path: Path):
    downloaded = tmp_path / "downloaded"
    downloaded.mkdir()
    for engine in ENGINES:
        inside = f"{engine.subdir}/" if engine.subdir else ""
        with zipfile.ZipFile(downloaded / engine.url.rsplit("/", 1)[-1], "w") as release:
            release.writestr(f"{inside}{engine.executable}", "#!/bin/sh\n")
            release.writestr(f"{inside}models/model.param", "")
    config = Config(tools_root=tmp_path / "tools")

    install_tools(config, downloaded)

    for engine in ENGINES:
        assert engine.is_installed(config.tools_root), engine.name
        assert os.access(engine.executable_path(config.tools_root), os.X_OK), engine.name
        assert (engine.directory(config.tools_root) / "models" / "model.param").is_file()
