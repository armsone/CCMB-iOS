#!/usr/bin/env python3
"""CCMB Gemini online relay (single-shot; run every 60s by launchd).

Reads this Mac's own gemini.online.{fiveHour,weekly} reading from the
existing CCMB usage-v1.json, validates it against a small allowlisted
contract, and relays it onto the server's own private data folder
(DATA_DIR/ccmb-usage) over the already-configured SSH route.

Only `schemaVersion` and `gemini.online` of usage-v1.json are ever read;
account, cookies, tokens, paths, and any other service field are never read
or sent.

The "나의 AI 열정" consumption history is no longer relayed from the Mac: the
NAS now samples it on its own every 5 minutes (see scripts/nas-usage-history).
A CCMB-consumption-history-v1.json copy relayed by an earlier version of this
script is left on the NAS untouched and unused.

This script never touches the NAS quota API, never changes NAS auth/
permissions/trust, and never queries Gemini itself. On any missing/invalid
source, network failure, or remote rejection, it simply leaves the
previously relayed NAS file untouched and exits quietly (stderr logging
only).
"""

import base64
import json
import os
import shlex
import subprocess
import sys

SOURCE = os.path.expanduser("~/Library/Application Support/CCMB/usage-v1.json")
SSH_HOST = "hanstree-dev"
MAX_RESET_TEXT = 160
SSH_TIMEOUT_SECONDS = 30

# Fixed, trusted remote-side code. Deployed to the NAS only as a base64
# argv payload over an already-authorized SSH route (BatchMode, existing
# key); the JSON data itself always travels over stdin, never argv. The
# remote script enforces the exact same contract again (schema, numeric
# 0..100 percentages, timestamp sanity, 8KiB cap, control-character/length
# limits on reset captions) and refuses to touch anything outside the
# single known project file, including refusing a symlinked target and
# refusing to overwrite a remote reading that is already newer.
REMOTE_SCRIPT = r'''
import sys, os, json, time, datetime, fcntl, errno

MAX_BYTES = 8192
TARGET_DIR = "/home/developer/.local/share/hanstree-workroom/ccmb-usage"
TARGET = os.path.join(TARGET_DIR, "CCMB-gemini-online-v1.json")


def fail(msg):
    sys.stderr.write(msg + "\n")
    sys.exit(1)


def is_number(v):
    return isinstance(v, (int, float)) and not isinstance(v, bool)


def parse_iso(s):
    # Require an explicit timezone so the comparison against "now" below is
    # unambiguous; truncating to 19 chars (as a naive implementation would)
    # silently drops both the timezone and any fractional seconds.
    text = s.strip()
    if text.endswith("Z"):
        text = text[:-1] + "+00:00"
    dt = datetime.datetime.fromisoformat(text)
    if dt.tzinfo is None:
        raise ValueError("fetchedAt has no timezone")
    return dt.astimezone(datetime.timezone.utc).timestamp()


raw = sys.stdin.buffer.read(MAX_BYTES + 1)
if len(raw) > MAX_BYTES:
    fail("payload too large")
try:
    data = json.loads(raw.decode("utf-8"))
except Exception:
    fail("invalid json")

schema_version = data.get("schemaVersion") if isinstance(data, dict) else None
if not isinstance(data, dict) or isinstance(schema_version, bool) or schema_version != 1:
    fail("bad schema")
gemini = data.get("gemini")
online = gemini.get("online") if isinstance(gemini, dict) else None
if not isinstance(online, dict):
    fail("missing gemini.online")


def percent(key):
    v = online.get(key)
    if v is None:
        return None
    if not is_number(v):
        fail("bad percent " + key)
    if v != v or v in (float("inf"), float("-inf")) or not (0 <= v <= 100):
        fail("out of range " + key)
    return v


five = percent("fiveHourRemainingPercent")
weekly = percent("weeklyRemainingPercent")
if five is None and weekly is None:
    fail("no usable percentage")

fetched_at = online.get("fetchedAt")
if not isinstance(fetched_at, str) or not fetched_at:
    fail("missing fetchedAt")
try:
    epoch = parse_iso(fetched_at)
except Exception:
    fail("bad fetchedAt")
if epoch > time.time() + 5 * 60:
    fail("fetchedAt too far in the future")


def clean_text(v):
    if not isinstance(v, str):
        return None
    stripped = "".join(ch for ch in v if ch == " " or (ord(ch) >= 32 and ord(ch) != 127))
    stripped = stripped.strip()
    return stripped[:160] if stripped else None


out_online = {"fetchedAt": fetched_at}
if five is not None:
    out_online["fiveHourRemainingPercent"] = five
if weekly is not None:
    out_online["weeklyRemainingPercent"] = weekly
reset5 = clean_text(online.get("fiveHourResetText"))
resetw = clean_text(online.get("weeklyResetText"))
if reset5 is not None:
    out_online["fiveHourResetText"] = reset5
if resetw is not None:
    out_online["weeklyResetText"] = resetw
out = {"schemaVersion": 1, "gemini": {"online": out_online}}

if not os.path.isdir(TARGET_DIR):
    fail("project directory missing")

# TARGET_DIR itself (and every ancestor) must be the real, non-symlinked
# path, not just TARGET's own leaf component — otherwise a symlinked
# parent directory could redirect the write outside the project.
if os.path.realpath(TARGET_DIR) != TARGET_DIR:
    fail("refusing symlinked project directory")

if os.path.islink(TARGET):
    fail("refusing symlinked target")

ONLINE_ALLOWED_KEYS = {
    "fetchedAt",
    "fiveHourRemainingPercent",
    "weeklyRemainingPercent",
    "fiveHourResetText",
    "weeklyResetText",
}


def validate_existing_online(existing):
    """Re-validates a previously-written remote file against the exact same
    contract this script itself writes. Returns the existing online dict
    only when every field matches; raises ValueError otherwise so the
    caller refuses to overwrite anything that isn't unambiguously our own
    prior output (e.g. unrelated JSON that merely happens to contain a
    `gemini.online` key)."""
    if not isinstance(existing, dict) or set(existing.keys()) != {"schemaVersion", "gemini"}:
        raise ValueError("unexpected root shape")
    sv = existing.get("schemaVersion")
    if isinstance(sv, bool) or sv != 1:
        raise ValueError("unexpected schemaVersion")
    gemini = existing.get("gemini")
    if not isinstance(gemini, dict) or set(gemini.keys()) != {"online"}:
        raise ValueError("unexpected gemini shape")
    online = gemini.get("online")
    if not isinstance(online, dict) or not set(online.keys()) <= ONLINE_ALLOWED_KEYS:
        raise ValueError("unexpected online shape")

    def ex_percent(key):
        if key not in online:
            return None
        v = online[key]
        if not is_number(v) or v != v or v in (float("inf"), float("-inf")) or not (0 <= v <= 100):
            raise ValueError("bad existing percent " + key)
        return v

    ex_five = ex_percent("fiveHourRemainingPercent")
    ex_weekly = ex_percent("weeklyRemainingPercent")
    if ex_five is None and ex_weekly is None:
        raise ValueError("no usable existing percentage")

    ex_fetched = online.get("fetchedAt")
    if not isinstance(ex_fetched, str) or not ex_fetched:
        raise ValueError("missing existing fetchedAt")
    parse_iso(ex_fetched)  # raises on invalid/naive timestamp

    for key in ("fiveHourResetText", "weeklyResetText"):
        if key in online:
            v = online[key]
            if v is not None and not (isinstance(v, str) and len(v) <= 160):
                raise ValueError("bad existing " + key)

    return online


lock_path = TARGET + ".lock"
lock_fd = os.open(lock_path, os.O_WRONLY | os.O_CREAT | os.O_NOFOLLOW, 0o600)
lock_st = os.fstat(lock_fd)
if not __import__("stat").S_ISREG(lock_st.st_mode) or lock_st.st_nlink != 1:
    os.close(lock_fd)
    fail("lock file is not a plain, unlinked file")
fcntl.flock(lock_fd, fcntl.LOCK_EX)
try:
    if os.path.exists(TARGET):
        try:
            # O_NOFOLLOW so a target swapped for a symlink between the
            # islink() check above and here is refused rather than
            # followed; the stat check also rejects a hardlinked target
            # (nlink > 1 means some other path can still observe/mutate
            # what we think is our own exclusive file).
            existing_fd = os.open(TARGET, os.O_RDONLY | os.O_NOFOLLOW)
            try:
                st = os.fstat(existing_fd)
                if not __import__("stat").S_ISREG(st.st_mode) or st.st_nlink != 1:
                    fail("existing remote target is not a plain, unlinked file")
                existing_raw = os.read(existing_fd, MAX_BYTES + 1)
            finally:
                os.close(existing_fd)
            existing = json.loads(existing_raw.decode("utf-8"))
            existing_online = validate_existing_online(existing)
            existing_fetched = existing_online.get("fetchedAt")
            if isinstance(existing_fetched, str):
                if parse_iso(existing_fetched) > epoch:
                    sys.stdout.write("stale-skip\n")
                    sys.exit(0)
            if existing_online == out_online:
                sys.stdout.write("unchanged\n")
                sys.exit(0)
        except SystemExit:
            raise
        except Exception:
            fail("existing remote file is not the expected shape; refusing to overwrite")

    tmp = "%s.tmp.%d.%d" % (TARGET, os.getpid(), time.time_ns())
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    try:
        with os.fdopen(fd, "w") as f:
            json.dump(out, f)
        os.chmod(tmp, 0o600)
        os.replace(tmp, TARGET)
    except Exception:
        try:
            os.remove(tmp)
        except OSError:
            pass
        raise

    sys.stdout.write("written\n")
finally:
    fcntl.flock(lock_fd, fcntl.LOCK_UN)
    os.close(lock_fd)
'''

def log(message):
    sys.stderr.write(f"[ccmb-gemini-relay] {message}\n")


def is_number(value):
    return isinstance(value, (int, float)) and not isinstance(value, bool)


def clean_text(value):
    if not isinstance(value, str):
        return None
    stripped = "".join(ch for ch in value if ch == " " or (ord(ch) >= 32 and ord(ch) != 127))
    stripped = stripped.strip()
    return stripped[:MAX_RESET_TEXT] if stripped else None


def load_source():
    """Returns the parsed Mac source dict (schemaVersion 1 only), or None if
    it is missing, unreadable, or not that schema."""
    try:
        with open(SOURCE, "rb") as f:
            raw = f.read()
    except OSError:
        return None
    try:
        data = json.loads(raw)
    except Exception:
        return None
    schema_version = data.get("schemaVersion") if isinstance(data, dict) else None
    if not isinstance(data, dict) or isinstance(schema_version, bool) or schema_version != 1:
        return None
    return data


def read_source(data):
    """Returns the bounded relay payload, or None if the Mac source carries
    no usable gemini.online reading at all.
    """
    gemini = data.get("gemini")
    online = gemini.get("online") if isinstance(gemini, dict) else None
    if not isinstance(online, dict):
        return None

    def percent(key):
        value = online.get(key)
        if value is None or not is_number(value):
            return None
        return value if 0 <= value <= 100 else None

    five = percent("fiveHourRemainingPercent")
    weekly = percent("weeklyRemainingPercent")
    if five is None and weekly is None:
        return None

    fetched_at = online.get("fetchedAt")
    if not isinstance(fetched_at, str) or not fetched_at:
        return None

    payload = {"fetchedAt": fetched_at}
    if five is not None:
        payload["fiveHourRemainingPercent"] = five
    if weekly is not None:
        payload["weeklyRemainingPercent"] = weekly
    reset5 = clean_text(online.get("fiveHourResetText"))
    resetw = clean_text(online.get("weeklyResetText"))
    if reset5 is not None:
        payload["fiveHourResetText"] = reset5
    if resetw is not None:
        payload["weeklyResetText"] = resetw
    return {"schemaVersion": 1, "gemini": {"online": payload}}


def send(payload, remote_script=REMOTE_SCRIPT, label="gemini-online"):
    body = json.dumps(payload).encode("utf-8")
    encoded = base64.b64encode(remote_script.encode("utf-8")).decode("ascii")
    # ssh itself space-joins all trailing argv into a single string handed
    # to the remote shell, so each piece must be shell-quoted ourselves;
    # passing them as separate subprocess argv elements does not protect
    # the spaces/semicolons/parentheses inside the wrapper one-liner.
    remote_command = shlex.join([
        "python3", "-c",
        "import sys,base64;exec(base64.b64decode(sys.argv[1]))",
        encoded,
    ])
    argv = [
        "/usr/bin/ssh",
        "-o", "BatchMode=yes",
        "-o", "ConnectTimeout=10",
        SSH_HOST,
        remote_command,
    ]
    try:
        result = subprocess.run(argv, input=body, capture_output=True, timeout=SSH_TIMEOUT_SECONDS)
    except Exception as exc:
        log(f"{label}: transfer failed: {exc}")
        return False
    if result.returncode != 0:
        log(f"{label}: remote rejected payload: {result.stderr.decode('utf-8', 'replace').strip()}")
        return False
    log(f"{label}: " + (result.stdout.decode("utf-8", "replace").strip() or "ok"))
    return True


def main():
    data = load_source()
    if data is None:
        log("no usable source file; nothing to relay")
        return 0
    # The remote side already refuses to overwrite an unchanged or newer
    # copy of its own, so there is no need for local last-sent state;
    # keeping one would mean a deleted/corrupted remote file could never
    # be recovered while the local source stays the same.
    online_payload = read_source(data)
    if online_payload is None:
        log("gemini-online: no usable source reading; nothing to relay")
        return 0
    return 0 if send(online_payload) else 1


if __name__ == "__main__":
    sys.exit(main())
