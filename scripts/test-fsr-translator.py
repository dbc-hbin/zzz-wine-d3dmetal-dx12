#!/usr/bin/env python3
"""Build and run the real FSR API -> Wine Unix -> MetalFX DX12 smoke."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import time

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "d3dmetal-pso-cache" / "fsr-translator.d3d12.test.cpp"
DEFAULT_COMPILER = Path("/opt/llvm-mingw-20260616-ucrt-macos-universal/bin/x86_64-w64-mingw32-clang++")


def digest(path: Path) -> str:
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--runtime", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--compiler", type=Path, default=DEFAULT_COMPILER)
    parser.add_argument("--timeout", type=int, default=180)
    parser.add_argument("--frame-generation", action="store_true")
    parser.add_argument("--command-buffer", choices=("metal4", "legacy"),
                        default="metal4")
    args = parser.parse_args()
    source = (ROOT / "d3dmetal-pso-cache" / "fsr-framegeneration.d3d12.test.cpp"
              if args.frame_generation else SOURCE)
    marker = "FSR_FRAMEGENERATION_D3D12_PASS" if args.frame_generation else "FSR_TRANSLATOR_D3D12_PASS"

    runtime = args.runtime.resolve()
    wine = runtime / "bin" / "wine"
    if not wine.is_file():
        raise SystemExit(f"missing runtime launcher: {wine}")
    if not args.compiler.is_file():
        raise SystemExit(f"missing x86_64 compiler: {args.compiler}")
    output_root = args.out.resolve()
    output_root.mkdir(parents=True, exist_ok=True)
    run = output_root / f"run-{time.time_ns()}"
    run.mkdir()
    executable = run / "fsr-translator.exe"
    build_log = run / "build.log"
    command = [str(args.compiler), "-std=c++20", "-O2", "-static", "-Wall", "-Wextra", "-Werror", "-Wno-switch",
               "-I", str(ROOT / "d3dmetal-pso-cache"), str(source), "-ld3d12", "-ld3dcompiler",
               "-ldxgi", "-lole32", "-luser32", "-o", str(executable)]
    with build_log.open("w") as stream:
        build = subprocess.run(command, cwd=ROOT, stdout=stream, stderr=subprocess.STDOUT,
                               timeout=args.timeout, check=False)
    evidence: dict[str, object] = {
        "schema": 1,
        "source": str(source.relative_to(ROOT)),
        "source_sha256": digest(source),
        "compiler": str(args.compiler),
        "build_command": command,
        "build_exit": build.returncode,
        "build_log": str(build_log),
        "runtime": str(runtime),
        "requested_command_buffer": args.command_buffer,
    }
    if build.returncode:
        (run / "evidence.json").write_text(json.dumps(evidence, indent=2) + "\n")
        raise SystemExit(f"FSR smoke build failed: {build_log}")

    prefix = run / "prefix"
    prefix.mkdir()
    log = run / "fsr.jsonl"
    output = run / "run.log"
    environment = dict(os.environ)
    for key in list(environment):
        if key.startswith("YAAGL_") or key in {"WINEPREFIX", "WINEDLLOVERRIDES", "DYLD_INSERT_LIBRARIES"}:
            environment.pop(key, None)
    environment.update({
        "WINEPREFIX": str(prefix),
        "WINEDLLOVERRIDES": "amd_fidelityfx_upscaler_dx12,amd_fidelityfx_framegeneration_dx12=b",

        "YAAGL_FSR_LOG": str(log),
        "D3DM_MTL4": "1" if args.command_buffer == "metal4" else "0",
        "MTL_DEBUG_LAYER": "1",
    })
    if args.command_buffer == "legacy":
        real_wine = runtime / "bin" / "wine.real"
        if not real_wine.is_file():
            raise SystemExit("legacy mode requires bin/wine.real")
        environment.update({
            "WINE_ENABLE_TIMEOUT_FIX": "1",
            "CX_ACTIVE_GRAPHICS_BACKEND": "d3dmetal",
            "D3DM_ENABLE_METALFX": "1",
            "D3DM_SUPPORT_DXR": "1",
            "D3DM_VENDOR_ID": "0x1002",
            "D3DM_DEVICE_ID": "0x7550",
            "D3DM_DEVICE_DESCRIPTION": "AMD Radeon RX 9070",
            "WINEMSYNC": "1",
            "MTL_CAPTURE_ENABLED": "0",
            "YAAGL_FSR_FG_NATIVE_DLL": f"Z:{runtime}/lib/wine/x86_64-windows/amd_fidelityfx_framegeneration_dx12_native.dll",
        })
        run_command = [str(real_wine), str(executable)]
    else:
        run_command = [str(wine), str(executable)]
    started = time.monotonic()
    with output.open("w") as stream:
        try:
            process = subprocess.run(run_command, cwd=run, env=environment, stdout=stream,
                                     stderr=subprocess.STDOUT, timeout=args.timeout, check=False)
            exit_code: int | None = process.returncode
        except subprocess.TimeoutExpired:
            exit_code = None
    text = output.read_text(errors="replace")
    passed = exit_code == 0 and marker in text
    evidence.update({
        "executable_sha256": digest(executable),
        "run_command": run_command,
        "run_exit": exit_code,
        "duration_seconds": round(time.monotonic() - started, 3),
        "run_log": str(output),
        "translator_log": str(log),
        "passed": passed,
        "mode_behavior_passed": passed,
        "result_lines": [line for line in text.splitlines()
                         if "FSR_TRANSLATOR_" in line or "FSR_FRAMEGENERATION_" in line],
    })
    (run / "evidence.json").write_text(json.dumps(evidence, indent=2) + "\n")
    if not passed:
        raise SystemExit(f"FSR smoke failed: {output}")
    print(marker, flush=True)


if __name__ == "__main__":
    main()
