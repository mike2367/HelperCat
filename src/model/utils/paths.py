import os
from pathlib import Path


PROJECT_ROOT = Path(__file__).resolve().parents[3]
DATA_DIR = PROJECT_ROOT / "data"
OUTPUT_DIR = PROJECT_ROOT / "output"


def _default_helpercat_data_dir():
    if os.environ.get("HELPERCAT_DATA_DIR"):
        return os.environ["HELPERCAT_DATA_DIR"]
    if os.name == "nt":
        local_app_data = os.environ.get("LOCALAPPDATA") or str(Path.home() / "AppData" / "Local")
        return str(Path(local_app_data) / "HelperCat")
    return str(Path.home() / ".local" / "share" / "HelperCat")

def resolve_local_path(path, project_root=None):
    if "${HELPERCAT_DATA_DIR}" in str(path):
        os.environ.setdefault("HELPERCAT_DATA_DIR", _default_helpercat_data_dir())
    text = os.path.expandvars(str(path))
    normalized = text.replace("\\", "/")
    if len(normalized) >= 3 and normalized[1:3] == ":/":
        drive_root = Path("/mnt") / normalized[0].lower()
        mounted_path = drive_root / normalized[3:]
        if os.name != "nt" and drive_root.exists():
            return mounted_path
        local_path = Path(normalized)
        if local_path.exists():
            return local_path
        return local_path

    local_path = Path(normalized)
    if local_path.is_absolute() or project_root is None:
        return local_path
    return Path(project_root) / local_path
