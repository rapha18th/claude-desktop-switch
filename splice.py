"""Account-key splice for the Claude desktop app's config.json.

Mirrors claude-swap's oauthAccount splice: only the account-specific keys move
between accounts; every other setting in config.json stays live and shared.

Usage:
  splice.py uuid     <config.json>
  splice.py export   <config.json> <fragment.json>
  splice.py import   <config.json> <fragment.json>
  splice.py strip    <config.json>
  splice.py loginok  <config.json> <Cookies db>
  splice.py journal  <config.json> <stash dir>

loginok prints "ok" or the reason a login looks signed out. It reads key names
and counts cookie rows, and leaves every token and cookie value unread.

journal settles a leftover config.json.journal. The app writes the journal
before each config commit and replays it at start only while config.json is
unchanged. A switch changes config.json, so a valid journal is replayed here
first and the journal file moves to the stash.
"""
import hashlib
import json
import os
import pathlib
import shutil
import sqlite3
import sys
import tempfile

ACCOUNT_KEYS = {"lastKnownAccountUuid"}
ACCOUNT_PREFIXES = ("oauth:",)
USAGE = __doc__.split("Usage:")[1].split("\n\n")[0]


def is_account_key(key):
    return key in ACCOUNT_KEYS or key.startswith(ACCOUNT_PREFIXES)


def load(path):
    if not os.path.exists(path):
        return {}
    with open(path, encoding="utf-8-sig") as f:
        return json.load(f)


def write_atomic(path, payload):
    folder = os.path.dirname(os.path.abspath(path))
    fd, tmp = tempfile.mkstemp(dir=folder, prefix=".splice-", suffix=".json")
    try:
        with os.fdopen(fd, "wb") as f:
            f.write(payload)
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, path)
    except BaseException:
        if os.path.exists(tmp):
            os.remove(tmp)
        raise


def save_atomic(path, data):
    write_atomic(path, json.dumps(data, indent=2).encode("utf-8"))


def login_problem(config, cookies):
    data = load(config)
    if not data.get("lastKnownAccountUuid"):
        return "account id missing"
    if not any(k.startswith(ACCOUNT_PREFIXES) for k in data):
        return "login keys missing"
    if data.get("windowSizeWasSignedIn") is False:
        return "the app last showed the signed-out screen"
    if not os.path.exists(cookies):
        return "cookie database missing"
    try:
        uri = pathlib.Path(cookies).resolve().as_uri() + "?mode=ro&immutable=1"
        con = sqlite3.connect(uri, uri=True)
        try:
            rows = con.execute(
                "select count(*) from cookies where host_key like '%claude.ai' and name = 'sessionKey'"
            ).fetchone()[0]
        finally:
            con.close()
        if rows == 0:
            return "claude.ai session cookie missing"
    except sqlite3.Error:
        pass  # an unreadable database leaves the call to the checks above
    return ""


def settle_journal(config, stash):
    journal = config + ".journal"
    if not os.path.exists(journal):
        return "clean"
    with open(journal, "rb") as f:
        raw = f.read()
    valid = False
    try:
        nl = raw.index(b"\n")
        fields = raw[:nl].decode("latin-1").split(" ")
        payload = raw[nl + 1:]
        if os.path.exists(config):
            with open(config, "rb") as f:
                current = hashlib.sha256(f.read()).hexdigest()
        else:
            current = "-"
        json.loads(payload.decode("utf-8"))
        valid = fields[0] == hashlib.sha256(payload).hexdigest() and current in fields[1:]
    except (ValueError, UnicodeDecodeError):
        valid = False
    if valid:
        write_atomic(config, payload)
    os.makedirs(stash, exist_ok=True)
    shutil.move(journal, os.path.join(stash, "config.json.journal"))
    return "replayed" if valid else "dropped"


def main():
    args = sys.argv[1:]
    need = {"uuid": 2, "export": 3, "import": 3, "strip": 2, "loginok": 3, "journal": 3}
    if not args or args[0] not in need or len(args) != need[args[0]]:
        raise SystemExit("usage:" + USAGE)
    mode, config = args[0], args[1]
    if mode == "uuid":
        print(load(config).get("lastKnownAccountUuid") or "")
    elif mode == "export":
        save_atomic(args[2], {k: v for k, v in load(config).items() if is_account_key(k)})
    elif mode == "import":
        fragment = load(args[2])
        kept = {k: v for k, v in load(config).items() if not is_account_key(k)}
        kept.update(fragment)
        save_atomic(config, kept)
    elif mode == "strip":
        save_atomic(config, {k: v for k, v in load(config).items() if not is_account_key(k)})
    elif mode == "loginok":
        print(login_problem(config, args[2]) or "ok")
    elif mode == "journal":
        print(settle_journal(config, args[2]))


if __name__ == "__main__":
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    try:
        main()
    except (OSError, ValueError) as e:
        print(f"{type(e).__name__}: {e}")
        sys.exit(1)
