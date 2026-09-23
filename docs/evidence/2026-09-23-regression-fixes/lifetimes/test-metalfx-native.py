#!/usr/bin/env python3
"""Build and run the shared MetalFX backend, transport, and quality suites."""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import subprocess
import time

ROOT = Path(__file__).resolve().parents[1]
SRC = ROOT / "d3dmetal-pso-cache"
SOURCES = {
    "backend": ["metalfx-backend.mm", "metalfx-backend.native.test.mm"],
    "transport": ["metalfx-backend.mm", "d3dmetal-transport.mm",
                  "d3dmetal-transport-legacy.mm", "fsr-framegeneration.mm",
                  "d3dmetal-transport.native.test.mm"],
    "legacy-transport": ["metalfx-backend.mm", "d3dmetal-transport-legacy.mm",
                         "d3dmetal-transport.mm", "fsr-framegeneration.mm",
                         "d3dmetal-transport-legacy.native.test.mm"],
    "lifetime": ["metalfx-backend.mm", "d3dmetal-transport-legacy.mm",
                 "fsr-framegeneration.mm", "d3dmetal-transport-lifetime.test.mm"],
    "quality": ["metalfx-backend.mm", "metalfx-quality.native.test.mm"],
}
MARKERS = {
    "backend": "METALFX_BACKEND_NATIVE_PASS",
    "transport": "PASS transport pins=1",
    "legacy-transport": "PASS legacy pins=1",
    "lifetime": "TRANSPORT_LIFETIME_PASS",
    "quality": "METALFX_QUALITY_NATIVE_PASS",
}
# The lifetime fixture includes transport.mm directly to access its private
# execution-slot registry; hash that included translation unit as build input.
INCLUDED_SOURCES = {"lifetime": ["d3dmetal-transport.mm"]}
TRACKED_HEADERS = [
    "metalfx-contract.hpp",
    "metalfx-backend.hpp",
    "d3dmetal-transport.hpp",
    "d3dmetal-transport-legacy.hpp",
    "fsr-framegeneration.hpp",
]


def digest(path: Path) -> str:
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def run_suite(suite: str, out: Path, d3dmetal: Path) -> dict[str, object]:
    executable = out / suite
    compile_log = out / f"{suite}-build.log"
    run_log = out / f"{suite}.log"
    sources = [SRC / name for name in SOURCES[suite]]
    kernel = (SRC / "fsr-kernels.metal").read_text()
    if ')YAAGL_METAL"' in kernel:
        raise RuntimeError("FSR Metal source collides with its generated raw-string delimiter")
    generated_kernel = out / "fsr-kernels.inc"
    generated_kernel.write_text(
        'static const char kFsrKernelsSource[] = R"YAAGL_METAL(' + kernel + ')YAAGL_METAL";\n')
    tracked = set(sources)
    tracked.update(SRC / name for name in INCLUDED_SOURCES.get(suite, []))
    tracked.update(SRC / name for name in TRACKED_HEADERS)
    tracked.add(SRC / "fsr-kernels.metal")
    before = {str(path.relative_to(ROOT)): digest(path) for path in sorted(tracked)}
    command = ["xcrun", "clang++", "-arch", "x86_64", "-std=c++20", "-O2",
               "-mmacosx-version-min=14.0", "-Wall", "-Wextra", "-Werror", "-pthread",
               "-fno-objc-arc", "-fobjc-exceptions", "-fblocks", "-I", str(out)]
    command.extend(str(path) for path in sources)
    command.extend(["-framework", "Foundation", "-framework", "Metal", "-framework", "MetalFX",
                    "-o", str(executable)])
    with compile_log.open("w") as stream:
        build = subprocess.run(command, cwd=ROOT, stdout=stream, stderr=subprocess.STDOUT,
                               timeout=180, check=False)
    unchanged = before == {str(path.relative_to(ROOT)): digest(path) for path in sorted(tracked)}
    result: dict[str, object] = {
        "suite": suite,
        "build_exit": build.returncode,
        "sources": before,
        "sources_unchanged_during_build": unchanged,
        "build_log": str(compile_log),
        "build_command": command,
        "passed": False,
    }
    if build.returncode or not unchanged:
        print(f"{suite}: BUILD FAIL ({compile_log})", flush=True)
        return result
    command = ["/usr/bin/arch", "-x86_64", str(executable)]
    if suite.endswith("transport"):
        command.append(str(d3dmetal))
        result["d3dmetal_sha256"] = digest(d3dmetal)
    elif suite == "quality":
        command.append(str(out / "quality-artifacts"))
    environment = dict(os.environ)
    for name in list(environment):
        if name.startswith("YAAGL_") or name in ("DYLD_INSERT_LIBRARIES", "MTL_SHADER_VALIDATION"):
            environment.pop(name, None)
    environment["MTL_DEBUG_LAYER"] = "1"
    start = time.monotonic()
    with run_log.open("w") as stream:
        try:
            run = subprocess.run(command, cwd=ROOT, env=environment, stdout=stream,
                                 stderr=subprocess.STDOUT, timeout=180, check=False)
            status = run.returncode
        except subprocess.TimeoutExpired:
            status = None
    text = run_log.read_text(errors="replace")
    result.update({
        "run_command": command,
        "run_exit": status,
        "run_log": str(run_log),
        "duration_seconds": round(time.monotonic() - start, 3),
        "executable_sha256": digest(executable),
        "passed": status == 0 and MARKERS[suite] in text,
        "result_lines": [line for line in text.splitlines() if "PASS" in line or "FAIL" in line],
    })
    print(f"{suite}: {'PASS' if result['passed'] else 'FAIL'} ({run_log})", flush=True)
    return result


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--suite", action="append", choices=tuple(SOURCES))
    parser.add_argument("--out", type=Path, default=ROOT / "build/fsr4-metalfx/native-tests")
    parser.add_argument(
        "--d3dmetal",
        type=Path,
        default=ROOT / "build/metalfx-output-contract-20260918/wine-pre-pso/lib/external/D3DMetal.framework/Versions/A/D3DMetal",
    )
    args = parser.parse_args()
    suites = args.suite or list(SOURCES)
    if any(suite.endswith("transport") for suite in suites) and not args.d3dmetal.is_file():
        parser.error("--d3dmetal must identify the verified native D3DMetal binary")
    out = args.out.resolve() / datetime.now(timezone.utc).strftime("run-%Y%m%dT%H%M%S%fZ")
    out.mkdir(parents=True)
    results = []
    for suite in suites:
        results.append(run_suite(suite, out, args.d3dmetal.resolve()))
        (out / "results.json").write_text(json.dumps(results, indent=2) + "\n")
    print(out / "results.json", flush=True)
    if not all(row["passed"] for row in results):
        raise SystemExit(1)
    print("METALFX_NATIVE_MATRIX_PASS", flush=True)


if __name__ == "__main__":
    main()
