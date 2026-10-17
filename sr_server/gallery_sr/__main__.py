"""gallery-sr serve | install-tools [--from <folder>] [--config config.toml]"""

from __future__ import annotations

import argparse
import logging
from pathlib import Path

from aiohttp import web

from .app import create_app
from .config import load_config
from .install import install_tools


def main() -> None:
    parser = argparse.ArgumentParser(prog="gallery-sr")
    parser.add_argument("command", choices=("serve", "install-tools"))
    parser.add_argument("--config", type=Path, default=Path("config.toml"))
    parser.add_argument("--from", dest="downloaded", type=Path,
                        help="install-tools: a folder with the release zips, instead of downloading them")
    arguments = parser.parse_args()
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s: %(message)s")
    config = load_config(arguments.config)
    if arguments.command == "install-tools":
        install_tools(config, arguments.downloaded)
    else:
        web.run_app(create_app(config), host=config.host, port=config.port, access_log=None)


if __name__ == "__main__":
    main()
