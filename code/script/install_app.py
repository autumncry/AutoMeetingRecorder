#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Install verified AMR; preserve rollback copies, libraries, settings and keychain."""
from pathlib import Path
import datetime, hashlib, json, os, plistlib, shutil, subprocess, uuid

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "Builds/AutoMeetingRecorder.app"
DESTINATION = Path("/Applications/AutoMeetingRecorder.app")
LEGACY = Path("/Applications/MeetingScribe.app")
LSREGISTER = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

def run(*args):
    subprocess.run(list(map(str, args)), check=True)

def verify(app):
    with (app / "Contents/Info.plist").open("rb") as f:
        info = plistlib.load(f)
    assert info["CFBundleName"] == "AutoMeetingRecorder"
    assert info["CFBundleExecutable"] == "AutoMeetingRecorder"
    assert info["CFBundleIdentifier"] == "local.MeetingScribe"
    assert info["CFBundleIconFile"] == "AppIcon.icns"
    assert (app / "Contents/Resources/AppIcon.icns").stat().st_size > 1000
    run("/usr/bin/codesign", "--verify", "--deep", "--strict", app)
    return info

def main():
    check = subprocess.run(["/usr/bin/pgrep", "-f", r"/(MeetingScribe|AutoMeetingRecorder)\.app/Contents/MacOS/(MeetingScribe|AutoMeetingRecorder)([[:space:]]|$)"], capture_output=True)
    if check.returncode == 0:
        raise SystemExit("旧版或新版仍在运行。请先保存录音并退出，然后重试安装。")
    if check.returncode != 1:
        raise SystemExit("无法确认应用运行状态，未替换任何应用。")
    info = verify(SOURCE)
    stamp = datetime.datetime.now(datetime.timezone(datetime.timedelta(hours=8))).strftime("%Y%m%d-%H%M%S")
    backup = ROOT / "Backups" / ("installation-" + stamp + "-" + uuid.uuid4().hex[:8])
    backup.mkdir(parents=True)
    stage = Path("/Applications/.AMR-install-" + uuid.uuid4().hex + ".app")
    moved = []
    installed = False
    try:
        run("/usr/bin/ditto", SOURCE, stage)
        verify(stage)
        for old in [LEGACY, DESTINATION]:
            if not old.exists():
                continue
            archive = backup / (old.stem + ".zip")
            run("/usr/bin/ditto", "-c", "-k", "--keepParent", old, archive)
            run("/usr/bin/unzip", "-tqq", archive)
            subprocess.run([LSREGISTER, "-u", str(old)], check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            parked = backup / old.name
            shutil.move(str(old), str(parked))
            moved.append((old, parked, archive))
        shutil.move(str(stage), str(DESTINATION))
        installed = True
        verify(DESTINATION)
        os.utime(DESTINATION, None)
        run(LSREGISTER, "-f", DESTINATION)
        development_legacy = ROOT.parent / "MeetingScribe/Builds/MeetingScribe.app"
        if development_legacy.exists():
            subprocess.run([LSREGISTER, "-u", str(development_legacy)], check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        for _, parked, _ in moved:
            shutil.rmtree(parked)
        manifest = {"installed": str(DESTINATION), "version": info["CFBundleShortVersionString"], "backup": str(backup),
                    "icon_sha256": hashlib.sha256((DESTINATION / "Contents/Resources/AppIcon.icns").read_bytes()).hexdigest(),
                    "preserved": ["recording libraries", "settings", "keychain", "bundle identifier"]}
        (backup / "installation.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2), encoding="utf-8")
        print(json.dumps(manifest, ensure_ascii=False, indent=2))
    except BaseException:
        if installed and DESTINATION.exists():
            shutil.rmtree(DESTINATION)
        for old, parked, archive in reversed(moved):
            if parked.exists():
                shutil.move(str(parked), str(old))
            elif archive.exists():
                run("/usr/bin/ditto", "-x", "-k", archive, old.parent)
        raise
    finally:
        if stage.exists():
            shutil.rmtree(stage)

if __name__ == "__main__":
    main()
