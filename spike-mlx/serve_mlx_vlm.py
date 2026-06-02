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


def main():
    wired, rest = _extract_wired_limit(sys.argv[1:])
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

    from mlx_vlm.server import main as server_main
    sys.argv = ["mlx_vlm.server"] + rest
    return server_main()


if __name__ == "__main__":
    sys.exit(main())
