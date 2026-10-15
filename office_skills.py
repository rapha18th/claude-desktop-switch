"""Makes the Office skills' LibreOffice helper run on Windows.

The docx, pptx and xlsx skills ship scripts/office/soffice.py, written for Linux
sandboxes. It probes socket.AF_UNIX, which Windows Python lacks, and the probe
raises AttributeError before LibreOffice starts. This patch returns early on
Windows, where LibreOffice talks over named pipes and needs no socket shim.

The app re-downloads skills per account and on updates, so the switcher runs
this after every switch. The patch is idempotent.

Usage:
  office_skills.py patch [<root> ...]
  office_skills.py check [<root> ...]
"""
import os
import sys

MARKER = "# windows-pipes: patched by ClaudeAccountSwitch"
OLD = "def _needs_shim() -> bool:\n    try:"
NEW = (
    "def _needs_shim() -> bool:\n"
    "    if not hasattr(socket, \"AF_UNIX\"):  " + MARKER + "\n"
    "        return False  # Windows: LibreOffice uses named pipes, so no shim\n"
    "    try:"
)


def default_roots():
    roots = []
    local = os.environ.get("LOCALAPPDATA", "")
    packages = os.path.join(local, "Packages")
    if os.path.isdir(packages):
        for name in os.listdir(packages):
            if name.startswith("Claude_"):
                roots.append(os.path.join(packages, name, "LocalCache", "Roaming", "Claude", "local-agent-mode-sessions"))
    roots.append(os.path.join(os.environ.get("APPDATA", ""), "Claude", "local-agent-mode-sessions"))
    return [r for r in roots if os.path.isdir(r)]


def helpers(roots):
    for root in roots:
        for dirpath, _dirs, files in os.walk(root):
            if "soffice.py" in files and dirpath.replace("\\", "/").endswith("scripts/office"):
                yield os.path.join(dirpath, "soffice.py")


def main():
    mode = sys.argv[1] if len(sys.argv) > 1 else "check"
    roots = sys.argv[2:] or default_roots()
    patched = ready = unknown = 0
    for path in helpers(roots):
        with open(path, encoding="utf-8") as f:
            text = f.read()
        if MARKER in text:
            ready += 1
        elif OLD in text.replace("\r\n", "\n"):
            if mode == "patch":
                crlf = "\r\n" in text
                body = text.replace("\r\n", "\n").replace(OLD, NEW, 1)
                with open(path, "w", encoding="utf-8", newline="") as f:
                    f.write(body.replace("\n", "\r\n") if crlf else body)
                patched += 1
            else:
                unknown += 1
                print(f"needs patch: {path}")
        else:
            unknown += 1
            print(f"unrecognised helper, left as is: {path}")
    print(f"Office skills: {patched} patched, {ready} already patched, {unknown} other.")


if __name__ == "__main__":
    main()
