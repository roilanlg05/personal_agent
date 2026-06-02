#!/usr/bin/env python3
"""Launcher for mlx_vlm.server with an optional MLX wired-memory limit.

Anti-cold-start: macOS pages out the file-backed model weights when the
server sits idle, so the first inference after idle re-pages ~15GB and is
slow. `mx.set_wired_limit(bytes)` wires the residency so macOS won't page
it out. mmap itself cannot be disabled in MLX's safetensors loader; wiring
is the real lever.

Usage:
  serve_mlx_vlm.py --wired-limit-bytes N [<all other mlx_vlm.server flags>]

If N <= 0 (or the flag is absent) wiring is skipped (pageable, current
behavior). All remaining args are passed through to mlx_vlm.server.main()
via sys.argv unchanged.
"""
import sys


def _extract_wired_limit(argv):
    """Pull --wired-limit-bytes N (or --wired-limit-bytes=N) out of argv.

    Returns (bytes_or_0, remaining_argv). Leaves every other flag intact so
    mlx_vlm.server's own parser sees exactly what it expects.
    """
    out = []
    wired = 0
    i = 0
    while i < len(argv):
        a = argv[i]
        if a == "--wired-limit-bytes":
            wired = int(argv[i + 1])
            i += 2
            continue
        if a.startswith("--wired-limit-bytes="):
            wired = int(a.split("=", 1)[1])
            i += 1
            continue
        out.append(a)
        i += 1
    return wired, out


def _extract_apc_disk_path(argv):
    """Pull --apc-disk-path PATH (or --apc-disk-path=PATH) out of argv.

    Returns (path_or_None, remaining_argv). Leaves every other flag intact so
    mlx_vlm.server's own parser sees exactly what it expects.
    """
    out = []
    path = None
    i = 0
    while i < len(argv):
        a = argv[i]
        if a == "--apc-disk-path":
            path = argv[i + 1]
            i += 2
            continue
        if a.startswith("--apc-disk-path="):
            path = a.split("=", 1)[1]
            i += 1
            continue
        out.append(a)
        i += 1
    return path, out


def _apply_apc_env(disk_path):
    """Turn on Automatic Prefix Caching for mlx_vlm.server (read by apc.from_env).

    sha256 hashing makes block hashes stable across processes so the SSD tier
    can be reused after a server restart (the default 'fast' hash is only
    deterministic within one process). APC_NUM_BLOCKS bounds the in-memory
    block pool (~16k tokens at the default 16-token block size).
    """
    import os
    from pathlib import Path
    Path(disk_path).expanduser().mkdir(parents=True, exist_ok=True)
    os.environ["APC_ENABLED"] = "1"
    os.environ["APC_HASH"] = "sha256"
    os.environ["APC_DISK_PATH"] = disk_path
    os.environ.setdefault("APC_DISK_MAX_GB", "2")
    os.environ.setdefault("APC_NUM_BLOCKS", "1024")


def main():
    wired, rest = _extract_wired_limit(sys.argv[1:])
    apc_path, rest = _extract_apc_disk_path(rest)
    if wired > 0:
        import mlx.core as mx
        prev = mx.set_wired_limit(wired)
        print(
            f"[serve_mlx_vlm] wired limit set to {wired} bytes "
            f"({wired / 1024**3:.2f} GiB), previous={prev}",
            flush=True,
        )
    else:
        print("[serve_mlx_vlm] no wiring (pageable)", flush=True)

    if apc_path:
        _apply_apc_env(apc_path)
        import os
        print(
            f"[serve_mlx_vlm] APC enabled (disk={apc_path}, hash=sha256, "
            f"num_blocks={os.environ['APC_NUM_BLOCKS']})",
            flush=True,
        )
    else:
        print("[serve_mlx_vlm] APC disabled", flush=True)

    from mlx_vlm.server import main as server_main
    sys.argv = ["mlx_vlm.server"] + rest
    return server_main()


if __name__ == "__main__":
    sys.exit(main())
