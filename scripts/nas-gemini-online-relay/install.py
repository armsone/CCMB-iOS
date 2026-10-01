#!/usr/bin/env python3
"""Installer for the CCMB Gemini online NAS relay (macOS, standard library
only). Prepares a task-specific LaunchAgent that runs relay.py once every
60 seconds, independent of CCMB.app itself and of any shell/cwd. Does
nothing destructive to any other LaunchAgent and never touches the NAS
quota UI, NAS auth, or any existing CCMB collector.

Usage:
    python3 install.py            # dry run: prints what would happen
    python3 install.py --install  # installs + loads only this agent
    python3 install.py --uninstall

Safety:
  - Refuses to overwrite the plist if a file already exists at the target
    path with a different Label or Program, rather than assuming it is
    safe to replace.
  - Only ever loads/kickstarts its own label
    (com.armsone.ccmb.gemini-nas-relay); never touches any other agent.
  - Performs no NAS-side writes itself; the NAS side is written only by
    relay.py's own bounded SSH transfer once actually running.
"""

import argparse
import os
import plistlib
import shlex
import shutil
import subprocess
import sys

LABEL = "com.armsone.ccmb.gemini-nas-relay"
APP_SUPPORT_DIR = os.path.expanduser("~/Library/Application Support/CCMB/NASRelay")
INSTALLED_SCRIPT = os.path.join(APP_SUPPORT_DIR, "relay.py")
LOG_DIR = os.path.join(APP_SUPPORT_DIR, "logs")
LAUNCH_AGENTS_DIR = os.path.expanduser("~/Library/LaunchAgents")
PLIST_PATH = os.path.join(LAUNCH_AGENTS_DIR, f"{LABEL}.plist")

SOURCE_SCRIPT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "relay.py")


def reject_symlinked_destination(path):
    """Refuses a destination (file or directory, existing or dangling) that
    is itself a symlink, or whose parent directories up to and including
    APP_SUPPORT_DIR/LAUNCH_AGENTS_DIR are, since any of those could
    redirect our own read/write elsewhere."""
    node = os.path.abspath(path)
    while True:
        if os.path.islink(node):
            raise RuntimeError(f"refusing symlinked path: {node}")
        parent = os.path.dirname(node)
        if parent == node:
            break
        node = parent
        if node in (os.path.expanduser("~"), "/", ""):
            break


def build_plist():
    return {
        "Label": LABEL,
        "ProgramArguments": [sys.executable, INSTALLED_SCRIPT],
        "RunAtLoad": True,
        "StartInterval": 60,
        "StandardOutPath": os.path.join(LOG_DIR, "relay.out.log"),
        "StandardErrorPath": os.path.join(LOG_DIR, "relay.err.log"),
    }


def existing_plist_is_foreign():
    """True only when a plist already sits at PLIST_PATH and does not look
    like a previous install of this same task (different Label or
    Program) — in which case installation must stop rather than overwrite
    unrelated state."""
    if not os.path.lexists(PLIST_PATH):
        return False
    if os.path.islink(PLIST_PATH):
        return True
    try:
        with open(PLIST_PATH, "rb") as f:
            current = plistlib.load(f)
    except Exception:
        return True
    expected_program = [sys.executable, INSTALLED_SCRIPT]
    return current.get("Label") != LABEL or current.get("ProgramArguments") != expected_program


# Appears verbatim in this task's own relay.py docstring; an installed
# script lacking it is either a stray unrelated file or belongs to a
# different task, even when (unlike the plist case) there is no missing
# plist to signal that on its own.
OWN_SCRIPT_MARKER = "CCMB Gemini online relay"


def installed_script_is_foreign():
    if not os.path.lexists(INSTALLED_SCRIPT):
        return False
    if os.path.islink(INSTALLED_SCRIPT):
        return True
    try:
        fd = os.open(INSTALLED_SCRIPT, os.O_RDONLY | os.O_NOFOLLOW)
        try:
            st = os.fstat(fd)
            import stat as stat_mod
            if not stat_mod.S_ISREG(st.st_mode) or st.st_nlink != 1:
                return True
            head = os.read(fd, 4096).decode("utf-8", "replace")
        finally:
            os.close(fd)
    except OSError:
        return True
    return OWN_SCRIPT_MARKER not in head


def do_install():
    if existing_plist_is_foreign():
        print(f"REFUSING: {PLIST_PATH} already exists and is not this task's own plist.")
        print("Remove or rename it yourself first if you intend to replace it.")
        return 1
    if installed_script_is_foreign():
        print(f"REFUSING: {INSTALLED_SCRIPT} already exists and is not this task's own script.")
        print("Remove or rename it yourself first if you intend to replace it.")
        return 1

    for destination in (APP_SUPPORT_DIR, LOG_DIR, INSTALLED_SCRIPT, PLIST_PATH):
        try:
            reject_symlinked_destination(destination)
        except RuntimeError as exc:
            print(f"REFUSING: {exc}")
            return 1

    os.makedirs(APP_SUPPORT_DIR, exist_ok=True)
    os.makedirs(LOG_DIR, exist_ok=True)
    shutil.copyfile(SOURCE_SCRIPT, INSTALLED_SCRIPT)
    os.chmod(INSTALLED_SCRIPT, 0o700)

    os.makedirs(LAUNCH_AGENTS_DIR, exist_ok=True)
    with open(PLIST_PATH, "wb") as f:
        plistlib.dump(build_plist(), f)
    os.chmod(PLIST_PATH, 0o644)

    print(f"Installed script: {INSTALLED_SCRIPT}")
    print(f"Installed agent:  {PLIST_PATH}")
    print()

    uid_gui = f"gui/{os.getuid()}"
    # bootout first in case a previous run of this same task's agent is
    # already loaded; its failure (nothing was loaded) is expected and
    # ignored, matching what the printed-command version did with `2>/dev/null`.
    subprocess.run(
        ["launchctl", "bootout", uid_gui, PLIST_PATH],
        capture_output=True,
    )
    bootstrap = subprocess.run(
        ["launchctl", "bootstrap", uid_gui, PLIST_PATH],
        capture_output=True,
        text=True,
    )
    if bootstrap.returncode != 0:
        print(f"FAILED to bootstrap {LABEL}: {bootstrap.stderr.strip()}")
        return 1
    kickstart = subprocess.run(
        ["launchctl", "kickstart", f"{uid_gui}/{LABEL}"],
        capture_output=True,
        text=True,
    )
    if kickstart.returncode != 0:
        print(f"FAILED to kickstart {LABEL}: {kickstart.stderr.strip()}")
        return 1

    print(f"Loaded and kickstarted: {LABEL}")
    print()
    print("To check logs:")
    print(f"  tail -f {shlex.quote(os.path.join(LOG_DIR, 'relay.err.log'))}")
    return 0


def do_uninstall():
    print("To uninstall, run:")
    print(f"  launchctl bootout gui/$(id -u) {shlex.quote(PLIST_PATH)} 2>/dev/null")
    print(f"  rm -f {shlex.quote(PLIST_PATH)}")
    print(f"  rm -rf {shlex.quote(APP_SUPPORT_DIR)}")
    print()
    print("(This installer does not delete anything itself; copy/paste the above after review.)")
    return 0


def do_dry_run():
    print("Dry run — nothing has been changed. This would:")
    print(f"  copy {shlex.quote(SOURCE_SCRIPT)}")
    print(f"    -> {shlex.quote(INSTALLED_SCRIPT)}")
    print(f"  write LaunchAgent -> {shlex.quote(PLIST_PATH)}")
    print(f"    Label:    {LABEL}")
    print(f"    Program:  {shlex.join([sys.executable, INSTALLED_SCRIPT])}")
    print("    RunAtLoad: true, StartInterval: 60s")
    print(f"  log files under {shlex.quote(LOG_DIR)}")
    print()
    if existing_plist_is_foreign():
        print(f"NOTE: {PLIST_PATH} already exists and belongs to something else;")
        print("      --install would refuse to touch it.")
    if installed_script_is_foreign():
        print(f"NOTE: {INSTALLED_SCRIPT} already exists and is not this task's own script;")
        print("      --install would refuse to touch it.")
    print("Run with --install to actually install, or --uninstall for removal instructions.")
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    group = parser.add_mutually_exclusive_group()
    group.add_argument("--install", action="store_true", help="install and print load commands")
    group.add_argument("--uninstall", action="store_true", help="print uninstall commands")
    args = parser.parse_args()

    if args.install:
        return do_install()
    if args.uninstall:
        return do_uninstall()
    return do_dry_run()


if __name__ == "__main__":
    sys.exit(main())
