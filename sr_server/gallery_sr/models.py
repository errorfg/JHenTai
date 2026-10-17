"""The upscaler programs and the models they run.

The same table as `lib/src/service/sr/sr_tools.dart` in the app: a model id,
scale and denoise level chosen in the app's settings mean the same here.
"""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path


@dataclass(frozen=True)
class Engine:
    """An ncnn + Vulkan command line upscaler, as its Linux release unpacks."""

    name: str
    url: str
    # Folder inside the release zip that holds the program and its models.
    subdir: str
    executable: str

    def directory(self, tools_root: Path) -> Path:
        return tools_root / self.name / self.subdir

    def executable_path(self, tools_root: Path) -> Path:
        return self.directory(tools_root) / self.executable

    def is_installed(self, tools_root: Path) -> bool:
        return self.executable_path(tools_root).is_file()


REALESRGAN = Engine(
    name="realesrgan",
    url="https://github.com/xinntao/Real-ESRGAN/releases/download/v0.2.5.0/realesrgan-ncnn-vulkan-20220424-ubuntu.zip",
    subdir="",
    executable="realesrgan-ncnn-vulkan",
)
REALCUGAN = Engine(
    name="realcugan",
    url="https://github.com/nihui/realcugan-ncnn-vulkan/releases/download/20220728/realcugan-ncnn-vulkan-20220728-ubuntu.zip",
    subdir="realcugan-ncnn-vulkan-20220728-ubuntu",
    executable="realcugan-ncnn-vulkan",
)
ENGINES = (REALESRGAN, REALCUGAN)


@dataclass(frozen=True)
class Model:
    id: str
    engine: Engine
    # Model folder inside the program's folder.
    model_dir: str
    # `-n` of realesrgan; realcugan picks its file from scale and denoise.
    model_name: str | None
    scales: tuple[int, ...]
    # `-n` of realcugan: -1 conservative, 0 no denoise, 1-3 denoise.
    denoise_levels: tuple[int, ...] = ()

    def label(self, scale: int, denoise: int) -> str:
        if self.engine is REALCUGAN:
            return f"{self.id}-x{scale}-n{denoise}"
        return f"{self.id}-x{scale}"

    def arguments(self, tools_root: Path, scale: int, denoise: int, gpu_id: int, source: Path, target: Path) -> list[str]:
        """Arguments of one run on the folder [source], results into [target]."""
        name = str(denoise) if self.engine is REALCUGAN else (self.model_name or self.id)
        return [
            "-i", str(source),
            "-o", str(target),
            "-s", str(scale),
            "-n", name,
            "-f", "jpg",
            "-g", str(gpu_id),
            "-m", str(self.engine.directory(tools_root) / self.model_dir),
        ]


MODELS = (
    Model("realesr-animevideov3", REALESRGAN, "models", "realesr-animevideov3", (2, 3, 4)),
    Model("realesrgan-x4plus-anime", REALESRGAN, "models", "realesrgan-x4plus-anime", (4,)),
    Model("realesrgan-x4plus", REALESRGAN, "models", "realesrgan-x4plus", (4,)),
    Model("realcugan-se", REALCUGAN, "models-se", None, (2, 3, 4), (-1, 0, 3)),
    Model("realcugan-pro", REALCUGAN, "models-pro", None, (2, 3), (-1, 0, 3)),
    Model("realcugan-nose", REALCUGAN, "models-nose", None, (2,), (0,)),
)


def model_by_id(model_id: str) -> Model | None:
    return next((m for m in MODELS if m.id == model_id), None)
