"""Settings of the service, read from a TOML file (see config.example.toml)."""

from __future__ import annotations

import tomllib
from dataclasses import dataclass
from pathlib import Path


@dataclass(frozen=True)
class Config:
    host: str = "127.0.0.1"
    port: int = 8790
    # Holds one folder per program, as `install-tools` unpacks them.
    tools_root: Path = Path("tools")
    # Pages of a request are written here for the program and removed once
    # it is done; on Linux /dev/shm keeps them in memory.
    work_dir: Path = Path("/dev/shm/gallery-sr")
    gpu_id: int = 0
    timeout_seconds: float = 120
    max_pages: int = 16
    max_page_bytes: int = 20_000_000
    max_pixels: int = 40_000_000
    # Proxy for downloading the programs, e.g. "http://127.0.0.1:7890".
    install_proxy: str = ""

    @property
    def max_request_bytes(self) -> int:
        return self.max_pages * self.max_page_bytes + 1_000_000


def load_config(path: Path) -> Config:
    """Relative paths in the file are taken from the file's folder."""
    with path.open("rb") as file:
        data = tomllib.load(file)
    base = path.resolve().parent
    server = data.get("server", {})
    upscaler = data.get("upscaler", {})
    limits = data.get("limits", {})
    install = data.get("install", {})
    defaults = Config()

    def resolve(value: str | None, default: Path) -> Path:
        chosen = Path(value) if value else default
        return chosen if chosen.is_absolute() else base / chosen

    return Config(
        host=server.get("host", defaults.host),
        port=int(server.get("port", defaults.port)),
        tools_root=resolve(upscaler.get("tools_root"), defaults.tools_root),
        work_dir=resolve(upscaler.get("work_dir"), defaults.work_dir),
        gpu_id=int(upscaler.get("gpu_id", defaults.gpu_id)),
        timeout_seconds=float(upscaler.get("timeout_seconds", defaults.timeout_seconds)),
        max_pages=int(limits.get("max_pages", defaults.max_pages)),
        max_page_bytes=int(limits.get("max_page_bytes", defaults.max_page_bytes)),
        max_pixels=int(limits.get("max_pixels", defaults.max_pixels)),
        install_proxy=str(install.get("proxy", defaults.install_proxy)),
    )
