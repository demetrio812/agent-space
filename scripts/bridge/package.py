"""Reproducible package bytes, shared by Flutter builds and tests."""
import io
from pathlib import Path
import zipfile

try:
    from .bootstrap import MODULES, validate_package
except ImportError:
    from bootstrap import MODULES, validate_package


def build_package(gate_path):
    root = Path(__file__).parent
    output = io.BytesIO()
    with zipfile.ZipFile(output, 'w', compression=zipfile.ZIP_STORED) as archive:
        for name in sorted(MODULES):
            path = Path(gate_path) if name == 'catalog_gate.py' else root / name
            if name == 'gateway.py' and not path.exists(): continue
            info = zipfile.ZipInfo(name, date_time=(2026, 1, 1, 0, 0, 0))
            info.external_attr = 0o100600 << 16
            info.compress_type = zipfile.ZIP_STORED
            archive.writestr(info, path.read_bytes())
    return output.getvalue()
