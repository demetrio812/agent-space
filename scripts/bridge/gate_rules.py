"""Import the standalone gate's pure rules without running its CLI main."""
import importlib.util
from pathlib import Path

try:
    import catalog_gate as gate
except ImportError:
    spec = importlib.util.spec_from_file_location('catalog_gate', Path(__file__).parent.parent / 'catalog-gate.py')
    gate = importlib.util.module_from_spec(spec); spec.loader.exec_module(gate)

validate_input = gate.validate_input
validate_send = gate.validate_send
valid_viewport = gate.valid_viewport
