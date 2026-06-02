"""Tests for the serve_mlx_vlm.py launcher arg/env handling. Run with:
    spike-mlx/.venv-vlm/bin/python spike-mlx/test_serve_mlx_vlm.py
Self-contained (no pytest dependency)."""
import importlib.util, os, sys

_here = os.path.dirname(os.path.abspath(__file__))
_spec = importlib.util.spec_from_file_location(
    "serve_mlx_vlm", os.path.join(_here, "serve_mlx_vlm.py"))
mod = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(mod)


def test_extract_apc_disk_path_space_form():
    path, rest = mod._extract_apc_disk_path(
        ["--apc-disk-path", "/tmp/apc", "--model", "x"])
    assert path == "/tmp/apc", path
    assert rest == ["--model", "x"], rest


def test_extract_apc_disk_path_equals_form():
    path, rest = mod._extract_apc_disk_path(["--apc-disk-path=/tmp/a", "--port", "8080"])
    assert path == "/tmp/a", path
    assert rest == ["--port", "8080"], rest


def test_extract_apc_disk_path_absent():
    path, rest = mod._extract_apc_disk_path(["--model", "x", "--port", "8080"])
    assert path is None, path
    assert rest == ["--model", "x", "--port", "8080"], rest


def test_apply_apc_env_sets_vars(tmp_path="/tmp/gemma-apc-test"):
    for k in ("APC_ENABLED", "APC_HASH", "APC_DISK_PATH", "APC_DISK_MAX_GB", "APC_NUM_BLOCKS"):
        os.environ.pop(k, None)
    mod._apply_apc_env(tmp_path)
    assert os.environ["APC_ENABLED"] == "1"
    assert os.environ["APC_HASH"] == "sha256"
    assert os.environ["APC_DISK_PATH"] == tmp_path
    assert os.environ["APC_DISK_MAX_GB"] == "2"
    assert os.environ["APC_NUM_BLOCKS"] == "1024"
    assert os.path.isdir(tmp_path), "disk dir must be created"


if __name__ == "__main__":
    fails = 0
    for name, fn in sorted(globals().items()):
        if name.startswith("test_") and callable(fn):
            try:
                fn()
                print(f"PASS {name}")
            except Exception as e:
                fails += 1
                print(f"FAIL {name}: {e}")
    sys.exit(1 if fails else 0)
