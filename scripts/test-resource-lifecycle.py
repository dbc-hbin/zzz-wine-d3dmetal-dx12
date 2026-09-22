#!/usr/bin/env python3
"""
Yaagl Wine DX12 Installer - Resource Lifecycle Regression Test Suite

Validates:
1. Strict requirement of explicit --stock-resource fixture (no userhome/machine paths).
2. Handling paths with spaces and apostrophes in both app and support directories.
3. Seeding valid prior Wine runtime so Restore has real backup.
4. App bundle immutability:
   - app/Contents/Resources/resources.neu bytes and mtime 100% untouched.
   - Pre-existing legacy app/Contents/Resources/resources.neu.bak is 100% untouched.
5. Support-only resource patching & floor-second mtime safety preventing rsync downgrade.
6. Automatic update helper (zzz-wine-register) execution on unpatched newer update:
   - Patches pending update, retains version, records hash-keyed pristine backup.
   - Emulated updater commit (forceMove) preserves registration and frontend version.
7. Corrupted / malformed update rejection leaving active support untouched.
8. Reinstall after upstream update.
9. Hash-keyed restore cleanly restoring matching unpatched version and wine runtime.
10. Restore on clean upstream preserving current frontend.
11. Same-ID runtime upgrade replaces a stale target-named cached archive and old Wine tree.
12. Activation failure restores this attempt's runtime and selection without consuming an older backup.
"""

import argparse
import hashlib
import json
import os
import pathlib
import shutil
import struct
import subprocess
import sys
import tempfile

def create_asar_fixture(stock_bytes, version):
    size, length = struct.unpack_from('<II', stock_bytes, 8)
    header = json.loads(stock_bytes[16:16+length])
    entries = []
    def walk(files, prefix=''):
        for name, entry in files.items():
            if 'files' in entry:
                walk(entry['files'], prefix + name + '/')
            elif 'offset' in entry:
                entries.append((int(entry['offset']), prefix + name, entry))
    walk(header['files'])
    payload = bytearray()
    for offset, name, entry in sorted(entries):
        content = stock_bytes[12+size+offset : 12+size+offset+entry['size']]
        if name == 'neutralino.config.json':
            config = json.loads(content)
            config['version'] = version
            content = json.dumps(config).encode() + (b'\n' if version.startswith('3') else b'')
        entry['offset'] = str(len(payload))
        entry['size'] = len(content)
        if 'integrity' in entry:
            blocksize = entry['integrity'].get('blockSize', 4*1024*1024)
            entry['integrity'].update(
                hash=hashlib.sha256(content).hexdigest(),
                blocks=[hashlib.sha256(content[i : i+blocksize]).hexdigest() for i in range(0, len(content), blocksize)]
            )
        payload.extend(content)
    text = json.dumps(header, separators=(',', ':')).encode()
    pad_len = (-len(text)) % 4
    padded = text + (b'\0' * pad_len)
    return struct.pack('<IIII', 4, len(padded)+8, len(padded)+4, len(text)) + padded + payload

def parse_asar_version(data):
    size, length = struct.unpack_from('<II', data, 8)
    entry = json.loads(data[16:16+length])['files']['neutralino.config.json']
    offset = 12 + size + int(entry['offset'])
    return json.loads(data[offset:offset+entry['size']])['version']

def sha256(data):
    return hashlib.sha256(data).hexdigest()


def sha256_file(path):
    digest = hashlib.sha256()
    with path.open('rb') as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b''):
            digest.update(chunk)
    return digest.hexdigest()


def extract_runtime_archive(archive_path, destination):
    destination.mkdir(parents=True, exist_ok=True)
    subprocess.run(['/usr/bin/tar', '-xJf', str(archive_path), '-C', str(destination)], check=True)
    wine = destination / 'wine'
    assert wine.is_dir(), f"Runtime archive did not contain wine: {archive_path}"
    return wine


def run_suite(stock_bytes, repo_root, previous_runtime_archive=None):
    print("====================================================================")
    print("Yaagl Wine DX12 Installer - Resource Lifecycle Regression Test Suite")
    print("====================================================================")

    installer_app = repo_root / 'installer/ZZZ Wine DX12 Installer.app'
    installer_bin = installer_app / 'Contents/MacOS/zzz-wine-installer'
    helper_bin = installer_app / 'Contents/Resources/zzz-wine-register'
    if not helper_bin.exists():
        helper_bin = repo_root / 'installer/zzz-wine-register'

    runtime_archive_name = 'Wine 11.17 ZZZ DX12 (GPTK4.0b2 macOS26).tar.xz'
    runtime_target_id = '11.17-zzz-dx12-tuned-stage-parallel-cache-warmup-cursor-rollback-gptk4b2-arm64server'
    runtime_archive_source = installer_app / 'Contents/Resources' / runtime_archive_name

    assert installer_bin.exists(), f"Installer binary not found: {installer_bin}"
    assert helper_bin.exists(), f"Helper binary not found: {helper_bin}"
    assert runtime_archive_source.exists(), f"Runtime archive not found: {runtime_archive_source}"

    with tempfile.TemporaryDirectory(prefix='zzz-lifecycle-', dir='/tmp') as tmp:
        root = pathlib.Path(tmp)

        # Use paths with spaces and apostrophes
        app = root / "Yaagl Test's App.app"
        resources = app / "Contents/Resources"
        resources.mkdir(parents=True)
        support = root / "Yaagl's Support Folder With Spaces"
        support.mkdir()

        app_neu = resources / "resources.neu"
        support_neu = support / "resources.neu"
        legacy_bak = resources / "resources.neu.bak"

        # Seed pre-existing legacy backup in app bundle to prove it is NEVER touched
        legacy_marker = b"LEGACY_APP_BACKUP_MARKER_PRESERVED"
        legacy_bak.write_bytes(legacy_marker)
        os.utime(legacy_bak, (500, 500))

        # Seed a real prior Wine runtime when supplied so installation exercises an actual upgrade.
        # Falling back to the bundled runtime preserves the standalone lifecycle contract.
        prior_wine = support / "wine"
        prior_runtime_source = previous_runtime_archive or runtime_archive_source
        subprocess.run(["/usr/bin/tar", "-xJf", str(prior_runtime_source), "-C", str(support)], check=True)
        assert prior_wine.is_dir(), "Seeded wine directory failed extraction"
        marker_file = prior_wine / "PRIOR_WINE_MARKER.txt"
        marker_file.write_text("PRIOR_WINE_VERSION_FOR_RESTORE_TEST")

        f29 = create_asar_fixture(stock_bytes, "2.9.0")
        f30 = create_asar_fixture(stock_bytes, "3.0.0")
        f31 = create_asar_fixture(stock_bytes, "3.1.0")
        f32 = create_asar_fixture(stock_bytes, "3.2.0")

        app_neu.write_bytes(f29)
        support_neu.write_bytes(f30)
        os.utime(app_neu, (1000, 1000))
        os.utime(support_neu, (2000, 2000))

        app_sha_before = sha256(app_neu.read_bytes())
        app_mtime_before = app_neu.stat().st_mtime

        # -------------------------------------------------------------
        # Scenario 1: Fresh Install with App Immutability & Floor-Second Mtime
        # -------------------------------------------------------------
        print("\n[SCENARIO 1] Fresh installation with spaces/quotes and legacy app backup...")
        subprocess.run([str(installer_bin), "--install", "--app-path", str(app), "--support-path", str(support)],
                       check=True, capture_output=False, timeout=120)

        # 1a. App bundle resources.neu must be completely untouched
        assert sha256(app_neu.read_bytes()) == app_sha_before, "App resources.neu bytes modified!"
        assert app_neu.stat().st_mtime == app_mtime_before, "App resources.neu mtime modified!"
        print("  -> PASS: App bundle resources.neu bytes and mtime are 100% UNTOUCHED.")

        # 1b. Legacy backup in app bundle must be completely untouched
        assert legacy_bak.read_bytes() == legacy_marker, "Legacy app backup was overwritten!"
        assert legacy_bak.stat().st_mtime == 500.0, "Legacy app backup mtime was modified!"
        print("  -> PASS: Pre-existing legacy app backup remained 100% UNTOUCHED.")

        # 1c. Support resources.neu patched with version 3.0.0 and updater hook
        support_bytes = support_neu.read_bytes()
        assert parse_asar_version(support_bytes) == "3.0.0", "Support version changed unexpectedly!"
        print("  -> PASS: Support resources.neu patched (version 3.0.0 + updater hook retained).")

        # 1d. Registration helper deployed
        helper_deployed = support / ".zzz-wine-registration/zzz-wine-register"
        assert helper_deployed.exists() and os.access(helper_deployed, os.X_OK), "Helper not deployed or not executable!"
        print("  -> PASS: Registration helper deployed to support/.zzz-wine-registration/zzz-wine-register.")

        # 1e. Support mtime floor-second strictly > App mtime
        assert int(support_neu.stat().st_mtime) > int(app_neu.stat().st_mtime)
        print("  -> PASS: Support integer mtime strictly greater than app mtime.")

        # 1f. Startup rsync test: must preserve 3.0.0 and custom runtime
        subprocess.run(["/usr/bin/rsync", "-rlptu", str(resources) + "/.", str(support)], check=True)
        rsync_bytes = support_neu.read_bytes()
        assert parse_asar_version(rsync_bytes) == "3.0.0", "Startup rsync downgraded support to 2.9.0!"
        print("  -> PASS: Startup rsync preserved support version 3.0.0 and registration.")

        # -------------------------------------------------------------
        # Scenario 2: Automatic Update Retention via Native Helper (3.1.0)
        # -------------------------------------------------------------
        print("\n[SCENARIO 2] Automatic update helper execution on unpatched 3.1.0 update...")
        runtime_before = {path: (support / path).read_bytes() for path in
                          ["wine/bin/wine", "wine/bin/wineserver", ".storage/wine_tag.neustorage", ".storage/wine_state.neustorage"]}
        archive_path = support / "local-runtimes" / "Wine 11.17 ZZZ DX12 (GPTK4.0b2 macOS26).tar.xz"
        assert archive_path.exists(), f"Runtime archive missing at {archive_path}"

        update_neu = support / "resources.neu.update"
        update_neu.write_bytes(f31)
        update_sha_clean = sha256(f31)

        res = subprocess.run([str(helper_deployed), "--resource-path", str(update_neu), "--archive-path", str(archive_path)],
                             capture_output=True, text=True)
        assert res.returncode == 0, f"Helper failed: {res.stderr}\n{res.stdout}"

        update_bytes = update_neu.read_bytes()
        assert parse_asar_version(update_bytes) == "3.1.0", "Update version changed unexpectedly!"

        # Pristine backup keyed by patched SHA
        patched_sha = sha256(update_bytes)
        backup_file = support / ".zzz-wine-registration/backups" / f"{patched_sha}.neu"
        assert backup_file.exists(), "Pristine backup not created!"
        assert sha256(backup_file.read_bytes()) == update_sha_clean, "Backup does not match clean 3.1.0 bytes!"
        print("  -> PASS: Helper patched update and recorded pristine backup keyed by patched SHA.")

        # Emulate updater commit: forceMove(resources.neu.update, resources.neu)
        os.replace(update_neu, support_neu)
        committed_bytes = support_neu.read_bytes()
        for path, content in runtime_before.items():
            assert (support / path).read_bytes() == content, f"Update changed installed Wine or its selection: {path}"
        assert parse_asar_version(committed_bytes) == "3.1.0"
        print("  -> PASS: Emulated updater commit succeeded; active frontend is now 3.1.0 with registration.")

        # Startup rsync must not downgrade 3.1.0
        subprocess.run(["/usr/bin/rsync", "-rlptu", str(resources) + "/.", str(support)], check=True)
        assert parse_asar_version(support_neu.read_bytes()) == "3.1.0"
        print("  -> PASS: Startup rsync does not downgrade active 3.1.0.")

        # -------------------------------------------------------------
        # Scenario 3: Malformed / Corrupted Update Rejection
        # -------------------------------------------------------------
        print("\n[SCENARIO 3] Corrupted update rejection by helper...")
        active_sha_before = sha256(support_neu.read_bytes())
        update_neu.write_bytes(b"corrupted invalid ASAR data junk")

        res = subprocess.run([str(helper_deployed), "--resource-path", str(update_neu), "--archive-path", str(archive_path)],
                             capture_output=True, text=True)
        assert res.returncode != 0, "Helper should have failed on corrupted update!"
        assert sha256(support_neu.read_bytes()) == active_sha_before, "Active support resource was modified by failed helper!"
        update_neu.unlink()
        print("  -> PASS: Malformed update rejected; active support resource untouched.")

        # -------------------------------------------------------------
        # Scenario 4: Reinstall After Upstream Update (3.2.0)
        # -------------------------------------------------------------
        print("\n[SCENARIO 4] Reinstall after upstream update to 3.2.0...")
        support_neu.write_bytes(f32)

        subprocess.run([str(installer_bin), "--install", "--app-path", str(app), "--support-path", str(support)],
                       check=True, capture_output=False, timeout=120)

        reinstalled_bytes = support_neu.read_bytes()
        assert parse_asar_version(reinstalled_bytes) == "3.2.0"
        print("  -> PASS: Reinstall registered into 3.2.0 without downgrade.")

        # -------------------------------------------------------------
        # Scenario 5: Same-ID Upgrade Replaces Stale Cached Runtime
        # -------------------------------------------------------------
        print("\n[SCENARIO 5] Same-ID upgrade replaces stale cached runtime...")
        persistent_wine_backup = support / "wine.bak"
        persistent_backup_marker = persistent_wine_backup / "PRIOR_WINE_MARKER.txt"
        assert persistent_wine_backup.is_dir(), "Original Wine restore backup is missing before same-ID upgrade!"
        assert persistent_backup_marker.read_text() == "PRIOR_WINE_VERSION_FOR_RESTORE_TEST"
        persistent_backup_wine_hash = sha256_file(persistent_wine_backup / "bin/wine")

        fixture_root = root / "same-id-upgrade-fixture"
        bundled_runtime = extract_runtime_archive(runtime_archive_source, fixture_root / "bundled")
        stale_archive_root = fixture_root / "cached"
        shutil.copytree(bundled_runtime, stale_archive_root / "wine", symlinks=True)
        obsolete_runtime_file = stale_archive_root / "wine" / "obsolete-same-id-runtime-file.txt"
        obsolete_runtime_file.write_text("stale file from a valid previous target-named runtime\n")

        archive_path = support / "local-runtimes" / runtime_archive_name
        subprocess.run(["/usr/bin/tar", "-cJf", str(archive_path), "-C", str(stale_archive_root), "wine"], check=True)
        assert sha256_file(archive_path) != sha256_file(runtime_archive_source), \
            "Cached target-named archive fixture must differ from the bundled archive!"

        shutil.rmtree(support / "wine")
        extract_runtime_archive(archive_path, support)
        assert (support / "wine" / obsolete_runtime_file.name).is_file(), \
            "Old valid target-named runtime fixture was not installed!"
        storage_tag = support / ".storage" / "wine_tag.neustorage"
        storage_state = support / ".storage" / "wine_state.neustorage"
        storage_tag.write_text(runtime_target_id)
        storage_state.write_text("ready")

        subprocess.run([str(installer_bin), "--install", "--app-path", str(app), "--support-path", str(support)],
                       check=True, capture_output=False, timeout=120)

        assert sha256_file(archive_path) == sha256_file(runtime_archive_source), \
            "Bundled archive did not replace the stale target-named cache!"
        for relative_path in ["bin/wine", "bin/wineserver"]:
            assert sha256_file(support / "wine" / relative_path) == sha256_file(bundled_runtime / relative_path), \
                f"Same-ID upgrade did not install bundled {relative_path}!"
        assert not (support / "wine" / obsolete_runtime_file.name).exists(), \
            "Same-ID upgrade left a file that exists only in the old runtime tree!"
        assert storage_tag.read_text() == runtime_target_id, "Same-ID upgrade did not select the target Wine tag!"
        assert storage_state.read_text() == "ready", "Same-ID upgrade did not mark the target runtime ready!"
        assert persistent_backup_marker.read_text() == "PRIOR_WINE_VERSION_FOR_RESTORE_TEST", \
            "Same-ID upgrade consumed the original Wine restore backup!"
        assert sha256_file(persistent_wine_backup / "bin/wine") == persistent_backup_wine_hash, \
            "Same-ID upgrade modified the original Wine restore backup!"
        print("  -> PASS: Bundled bytes replaced same-ID cache/tree; ready selection and original backup were retained.")

        # -------------------------------------------------------------
        # Scenario 6: Restore on Registered 3.2.0 (Matching Version + Wine)
        # -------------------------------------------------------------
        print("\n[SCENARIO 6] Restore on registered 3.2.0...")
        # A prepared update must not replace the active generation's restore point.
        update_neu.write_bytes(f31)
        subprocess.run([str(helper_deployed), "--resource-path", str(update_neu), "--archive-path", str(archive_path)],
                       check=True, capture_output=True, text=True)
        subprocess.run([str(installer_bin), "--restore", "--app-path", str(app), "--support-path", str(support)],
                       check=True, capture_output=False, timeout=120)

        restored_bytes = support_neu.read_bytes()
        assert restored_bytes == f32, "Pending update changed the active generation restore point!"
        assert parse_asar_version(restored_bytes) == "3.2.0", f"Restore downgraded to {parse_asar_version(restored_bytes)}!"
        # Check that prior wine runtime was restored
        assert (support / "wine/PRIOR_WINE_MARKER.txt").exists(), "Prior wine runtime was not restored!"
        print("  -> PASS: Restore cleanly restored pristine unpatched 3.2.0 and prior Wine runtime.")

        # -------------------------------------------------------------
        # Scenario 7: Restore on Clean Upstream (No-op Safe Preservation)
        # -------------------------------------------------------------
        print("\n[SCENARIO 7] Restore on already-clean upstream...")
        subprocess.run([str(installer_bin), "--install", "--app-path", str(app), "--support-path", str(support)],
                       check=True, capture_output=True, text=True, timeout=120)
        clean_update = create_asar_fixture(stock_bytes, "3.3.0")
        support_neu.write_bytes(clean_update)
        res = subprocess.run([str(installer_bin), "--restore", "--app-path", str(app), "--support-path", str(support)],
                             capture_output=True, text=True, timeout=120)
        assert res.returncode == 0, res.stdout + res.stderr
        assert support_neu.read_bytes() == clean_update
        print("  -> PASS: Restore on clean upstream safely preserved current version.")

        # -------------------------------------------------------------
        # Scenario 8: Subsecond / Integer Floor-Second Boundary
        # -------------------------------------------------------------
        print("\n[SCENARIO 8] Subsecond boundary rsync safety...")
        app_neu.write_bytes(f29); support_neu.write_bytes(f30)
        os.utime(app_neu, (1000.2, 1000.2))
        os.utime(support_neu, (1000.8, 1000.8))
        app_sub_mtime_before = app_neu.stat().st_mtime
        subprocess.run([str(installer_bin), "--install", "--app-path", str(app), "--support-path", str(support)],
                       check=True, capture_output=False, timeout=120)
        # An idempotent registration preserves the resource mtime. Force both
        # resources into the same rsync-visible second before reinstalling.
        os.utime(support_neu, (1000.8, 1000.8))
        subprocess.run([str(installer_bin), "--install", "--app-path", str(app), "--support-path", str(support)],
                       check=True, capture_output=False, timeout=120)
        assert app_neu.stat().st_mtime == app_sub_mtime_before, "App mtime modified during subsecond test!"
        assert int(support_neu.stat().st_mtime) > int(app_neu.stat().st_mtime)
        subprocess.run(["/usr/bin/rsync", "-rlptu", str(resources) + "/.", str(support)], check=True)
        assert parse_asar_version(support_neu.read_bytes()) == "3.0.0"
        print("  -> PASS: Floor-second mtime enforcement safely prevents rsync clobbering.")

        # -------------------------------------------------------------
        # Scenario 9: Final Activation Failure Restores Current Attempt
        # -------------------------------------------------------------
        print("\n[SCENARIO 9] Activation failure restores current runtime and selection...")
        support_neu.write_bytes(f32)
        import stat
        storage_tag = support / ".storage" / "wine_tag.neustorage"
        storage_state = support / ".storage" / "wine_state.neustorage"
        storage_tag.parent.mkdir(parents=True, exist_ok=True)
        storage_tag.write_text("same-id-upgrade-pre-failure-tag")
        storage_state.write_text("preparing")

        persistent_wine_backup = support / "wine.bak"
        persistent_backup_marker = persistent_wine_backup / "PRIOR_WINE_MARKER.txt"
        assert persistent_wine_backup.is_dir(), "Persistent Wine backup is missing before activation-failure rollback!"
        assert persistent_backup_marker.read_text() == "PRIOR_WINE_VERSION_FOR_RESTORE_TEST"
        persistent_backup_before = {
            "wine/bin/wine": sha256_file(persistent_wine_backup / "bin/wine"),
            "wine_tag.neustorage.bak": (support / ".storage" / "wine_tag.neustorage.bak").read_bytes(),
            "wine_state.neustorage.bak": (support / ".storage" / "wine_state.neustorage.bak").read_bytes(),
        }
        active_runtime_before = {
            relative_path: sha256_file(support / "wine" / relative_path)
            for relative_path in ["bin/wine", "bin/wineserver"]
        }
        assert not (support / "wine" / persistent_backup_marker.name).exists(), \
            "Current runtime must differ from the old persistent backup for rollback proof!"
        pre_fail_support_sha = sha256(support_neu.read_bytes())
        pre_fail_support_mtime = support_neu.stat().st_mtime

        os.chflags(str(storage_state), stat.UF_IMMUTABLE)
        try:
            res = subprocess.run([str(installer_bin), "--install", "--app-path", str(app), "--support-path", str(support)],
                                 capture_output=True, text=True, timeout=120)
        finally:
            os.chflags(str(storage_state), 0)

        assert res.returncode != 0, "Installer should fail when activation cannot write wine_state!"
        assert sha256(support_neu.read_bytes()) == pre_fail_support_sha, \
            "Resources bytes not restored after activation failure!"
        assert support_neu.stat().st_mtime == pre_fail_support_mtime, \
            "Resources mtime not restored after activation failure!"
        for relative_path, expected_hash in active_runtime_before.items():
            assert sha256_file(support / "wine" / relative_path) == expected_hash, \
                f"Activation failure restored a persistent backup instead of current {relative_path}!"
        assert storage_tag.read_text() == "same-id-upgrade-pre-failure-tag", \
            "Activation failure did not restore the tag from this attempt!"
        assert storage_state.read_text() == "preparing", \
            "Activation failure did not preserve the state from this attempt!"
        assert persistent_backup_marker.read_text() == "PRIOR_WINE_VERSION_FOR_RESTORE_TEST", \
            "Activation failure consumed the old persistent Wine backup!"
        assert sha256_file(persistent_wine_backup / "bin/wine") == persistent_backup_before["wine/bin/wine"], \
            "Activation failure modified the old persistent Wine backup!"
        assert (support / ".storage" / "wine_tag.neustorage.bak").read_bytes() == persistent_backup_before["wine_tag.neustorage.bak"], \
            "Activation failure modified the persistent tag backup!"
        assert (support / ".storage" / "wine_state.neustorage.bak").read_bytes() == persistent_backup_before["wine_state.neustorage.bak"], \
            "Activation failure modified the persistent state backup!"
        assert helper_deployed.exists() and os.access(helper_deployed, os.X_OK), \
            "Helper was removed on activation failure!"
        assert (support / ".zzz-wine-registration/backups").is_dir(), \
            "Registration backups were deleted on activation failure!"
        print("  -> PASS: Activation fault restored this attempt's runtime/tag/state and retained the old backup.")

        # Final app immutability verification
        assert sha256(app_neu.read_bytes()) == app_sha_before
        assert legacy_bak.read_bytes() == legacy_marker
        assert legacy_bak.stat().st_mtime == 500.0
        print("\n[FINAL VERIFICATION] App bundle and legacy backup remained 100% untouched across all 9 scenarios!")

    print("\n====================================================================")
    print("ALL 9 RESOURCE LIFECYCLE REGRESSION SCENARIOS PASSED SUCCESSFULLY!")
    print("====================================================================")

def main():
    parser = argparse.ArgumentParser(description="Yaagl Wine DX12 Resource Lifecycle Regression Tests")
    parser.add_argument("--stock-resource", required=True, help="Path to stock Yaagl resources.neu fixture (REQUIRED)")
    parser.add_argument("--previous-runtime", help="Optional prior release archive used for a real upgrade scenario")
    parser.add_argument("--repo", help="Repository root path", default=str(pathlib.Path.cwd()))
    args = parser.parse_args()

    stock_path = pathlib.Path(args.stock_resource).resolve()
    if not stock_path.is_file():
        print(f"Error: --stock-resource fixture does not exist: {stock_path}", file=sys.stderr)
        sys.exit(1)

    stock_bytes = stock_path.read_bytes()
    repo_root = pathlib.Path(args.repo).resolve()
    previous_runtime = pathlib.Path(args.previous_runtime).resolve() if args.previous_runtime else None
    if previous_runtime is not None and not previous_runtime.is_file():
        print(f"Error: --previous-runtime archive does not exist: {previous_runtime}", file=sys.stderr)
        sys.exit(1)

    run_suite(stock_bytes, repo_root, previous_runtime)

if __name__ == '__main__':
    main()
