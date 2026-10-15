"""Shares Code tab sessions across accounts in the Claude desktop app.

The app files Code sessions per account and organization:
  claude-code-sessions/<accountUuid>/<orgUuid>/local_<id>.json      one per session
  claude-code-sessions/<accountUuid>/<orgUuid>/deleted_<id>         tombstone (deletion time in ms)
  claude-code-sessions/<accountUuid>/<orgUuid>/scheduled-tasks.json
Transcripts live in ~/.claude/projects and are shared already, so these files
are all that keeps one account from listing another account's sessions.

sync gives every org folder of the named accounts the same sessions:
  - the newest copy of each session wins, by file time;
  - a session deleted in one account leaves every account; removed copies go to the stash;
  - a session restored after its deletion (newer than its tombstone) comes back everywhere;
  - scheduled tasks merge by id against the snapshot of the last sync: the newest copy
    of a task wins, and a task removed in any folder since then stays removed. Each
    rewritten tasks file is copied to the stash first.
Some fields point at things only the source account can reach, such as Remote Control
and cloud sessions or saved environments. A copy drops the source's values and keeps
the ones the destination already had.

Run it only while the app is closed.

Usage:
  sessions.py sync <sessions-dir> <stash-dir> <snapshot.json> <accountUuid>...
"""
import argparse
import json
import os
import re
import shutil
import sys
import tempfile

UUID = r"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"
SESSION = re.compile(rf"^local_({UUID})\.json$")
TOMBSTONE = re.compile(rf"^deleted_({UUID})$")
FOLDER = re.compile(rf"^{UUID}$")
TASKS = "scheduled-tasks.json"
ACCOUNT_BOUND = (
    "bridgeSessionIds", "startedFromEnvironmentId", "cloudSessionId", "movedToCloud", "cloudSpawnedTasks",
    "remoteControlSpawn", "remoteControlUserEnabled", "remoteControlLiveAtUpdateQuit",
)


def read_json(path):
    try:
        with open(path, encoding="utf-8-sig") as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


def write_json(path, data, mtime_ns=None):
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), prefix=".sync-", suffix=".json")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(data, f, separators=(",", ":"))
            f.flush()
            os.fsync(f.fileno())
        if mtime_ns is not None:
            os.utime(tmp, ns=(mtime_ns, mtime_ns))
        os.replace(tmp, path)
    except BaseException:
        if os.path.exists(tmp):
            os.remove(tmp)
        raise


def stash_dir(stash, acc, org):
    dst = os.path.join(stash, f"{acc[:8]}-{org[:8]}")
    os.makedirs(dst, exist_ok=True)
    return dst


def deleted_at(path):
    # The app writes the deletion time in milliseconds; copies keep it.
    try:
        with open(path, encoding="utf-8-sig") as f:
            return int(f.read().strip()) * 1_000_000
    except (OSError, ValueError):
        return os.stat(path).st_mtime_ns


def org_folders(root, accounts):
    found = []
    for acc in accounts:
        base = os.path.join(root, acc)
        if not os.path.isdir(base):
            continue
        for org in sorted(os.listdir(base)):
            if FOLDER.match(org) and os.path.isdir(os.path.join(base, org)):
                found.append((acc, org, os.path.join(base, org)))
    return found


def sync_sessions(folders, stash):
    newest = {}  # session id -> (mtime_ns, data)
    marks = {}   # session id -> tombstone paths
    for _, _, folder in folders:
        for name in os.listdir(folder):
            path = os.path.join(folder, name)
            m = SESSION.match(name)
            if m:
                t = os.stat(path).st_mtime_ns
                if m[1] in newest and t <= newest[m[1]][0]:
                    continue
                data = read_json(path)
                if isinstance(data, dict):  # skip damaged or half-written files
                    newest[m[1]] = (t, data)
                continue
            m = TOMBSTONE.match(name)
            if m:
                marks.setdefault(m[1], []).append(path)

    tombstones = {}
    revived = 0
    for sid, paths in marks.items():
        if sid in newest and newest[sid][0] > max(deleted_at(p) for p in paths):
            for p in paths:  # restored after its deletion, as the app does on import
                os.remove(p)
            revived += 1
        else:
            tombstones[sid] = paths[0]

    copied = removed = 0
    for acc, org, folder in folders:
        for sid, mark_src in tombstones.items():
            live = os.path.join(folder, f"local_{sid}.json")
            if os.path.exists(live):
                shutil.move(live, os.path.join(stash_dir(stash, acc, org), os.path.basename(live)))
                removed += 1
            mark = os.path.join(folder, f"deleted_{sid}")
            if not os.path.exists(mark):
                shutil.copy2(mark_src, mark)
        for sid, (t, data) in newest.items():
            if sid in tombstones:
                continue
            dst = os.path.join(folder, f"local_{sid}.json")
            own = None
            if os.path.exists(dst):
                if os.stat(dst).st_mtime_ns >= t:
                    continue
                own = read_json(dst)
            copy = dict(data)
            for key in ACCOUNT_BOUND:
                if copy.get(key) is not None:
                    del copy[key]
                if isinstance(own, dict) and own.get(key) is not None:
                    copy[key] = own[key]
            write_json(dst, copy, t)
            copied += 1
    return len(newest) - len(set(newest) & set(tombstones)), copied, removed, revived


def sync_tasks(folders, snapshot_path, stash):
    snapshot = read_json(snapshot_path) or {}
    known_ids = set(snapshot.get("ids", []))
    known_folders = set(snapshot.get("folders", []))

    files = []  # (mtime_ns, took_part_in_last_sync, acc, org, path, data)
    for acc, org, folder in folders:
        path = os.path.join(folder, TASKS)
        data = read_json(path)
        if isinstance(data, dict) and isinstance(data.get("scheduledTasks"), list):
            files.append((os.stat(path).st_mtime_ns, f"{acc}/{org}" in known_folders, acc, org, path, data))
    files.sort(key=lambda f: -f[0])  # newest first: the first version of a task wins

    # Every folder that took part in the last sync held the same tasks, so a known task
    # missing from one of them was removed there since. A folder new to the group, or
    # one whose file was unreadable last time, has had no chance to remove anything.
    removed = set()
    for _, took_part, _, _, _, data in files:
        if took_part:
            removed |= known_ids - {t.get("id") for t in data["scheduledTasks"]}

    merged = {}
    for _, _, _, _, _, data in files:
        for task in data["scheduledTasks"]:
            tid = task.get("id")
            if tid and tid not in merged and tid not in removed:
                merged[tid] = task

    tasks = list(merged.values())
    written = 0
    for _, _, acc, org, path, data in files:
        if data["scheduledTasks"] != tasks:
            shutil.copy2(path, os.path.join(stash_dir(stash, acc, org), TASKS))
            data["scheduledTasks"] = tasks
            write_json(path, data)
            written += 1
    write_json(snapshot_path, {"ids": sorted(merged), "folders": sorted(f"{f[2]}/{f[3]}" for f in files)})
    return len(tasks), written


def main():
    p = argparse.ArgumentParser()
    p.add_argument("mode", choices=["sync"])
    p.add_argument("sessions")
    p.add_argument("stash")
    p.add_argument("snapshot")
    p.add_argument("accounts", nargs="+")
    a = p.parse_args()

    folders = org_folders(a.sessions, list(dict.fromkeys(a.accounts)))
    if len(folders) < 2:
        print("Sessions: one account folder so far.")
        return
    total, copied, removed, revived = sync_sessions(folders, a.stash)
    tasks, written = sync_tasks(folders, a.snapshot, a.stash)
    print(f"Sessions: {total} shared across {len(folders)} account folders; "
          f"{copied} copies updated, {removed} deleted copies moved to the stash, {revived} restored; "
          f"{tasks} scheduled task(s), {written} file(s) updated.")


if __name__ == "__main__":
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    try:
        main()
    except Exception as e:  # reported on stdout so the switcher can log it
        print(f"{type(e).__name__}: {e}")
        sys.exit(1)
