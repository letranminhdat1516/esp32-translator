#!/usr/bin/env python3
"""Edit Claude Code settings.json hooks and render the launchd plist for claude-board.

usage: claude_settings.py install   SETTINGS HOOK_PATH
       claude_settings.py uninstall SETTINGS
       claude_settings.py plist TEMPLATE OUT BIN HOME
"""
import json, os, plistlib, sys, tempfile, time


def is_ours(h):
    cmd = h.get("command", "") if isinstance(h, dict) else ""
    return cmd.strip().strip("\"'").strip().endswith("claude-board-hook")


def die(msg):
    print("error: " + msg, file=sys.stderr)
    sys.exit(1)


def load(path):
    if not os.path.exists(path):
        return {}
    try:
        with open(path) as f:
            s = json.load(f)
    except (ValueError, OSError) as e:
        die("%s is not valid JSON (%s); left untouched" % (path, e))
    if not isinstance(s, dict):
        die("%s is not a JSON object; left untouched" % path)
    return s


def strip_ours(entries):
    """Drop our hook objects; drop an entry only if we emptied it. Returns (list, changed)."""
    out, changed = [], False
    for e in entries:
        hs = e.get("hooks") if isinstance(e, dict) else None
        if not isinstance(hs, list) or not any(is_ours(h) for h in hs):
            out.append(e)
            continue
        changed = True
        rest = [h for h in hs if not is_ours(h)]
        if rest:
            out.append(dict(e, hooks=rest))
    return out, changed


def backup(path):
    if not os.path.exists(path):
        return
    base = "%s.bak.%s.%d" % (path, time.strftime("%Y%m%d%H%M%S"), os.getpid())
    dest, n = base, 0
    while os.path.exists(dest):
        n += 1
        dest = "%s.%d" % (base, n)
    with open(path, "rb") as src, open(dest, "xb") as dst:
        dst.write(src.read())


def atomic_write(path, text):
    d = os.path.dirname(path)
    fd, tmp = tempfile.mkstemp(dir=d, prefix=".settings.", suffix=".tmp")
    try:
        with os.fdopen(fd, "w") as f:
            f.write(text)
            f.flush()
            os.fsync(f.fileno())
        if os.path.exists(path):
            os.chmod(tmp, os.stat(path).st_mode & 0o7777)
        os.replace(tmp, path)
    except BaseException:
        if os.path.exists(tmp):
            os.unlink(tmp)
        raise


def main(argv):
    mode = argv[1]
    if mode == "plist":
        tmpl, out, binp, home = argv[2:6]
        with open(tmpl, "rb") as f:
            pl = plistlib.load(f)
        pl["ProgramArguments"] = [a.replace("__BIN__", binp) for a in pl["ProgramArguments"]]
        pl["StandardErrorPath"] = pl["StandardErrorPath"].replace("__HOME__", home)
        with open(out, "wb") as f:
            plistlib.dump(pl, f)
        return
    path = os.path.realpath(argv[2])
    s = load(path)
    hooks = s.get("hooks", {})
    if not isinstance(hooks, dict):
        die("'hooks' in %s is not an object; left untouched" % path)
    if mode == "install":
        cmd = '"%s"' % argv[3]
        s["hooks"] = hooks
        for event, extra in (("PermissionRequest", {"matcher": "*"}),
                             ("Stop", {}),
                             ("Notification", {"matcher": "idle_prompt"})):
            lst = hooks.get(event, [])
            if not isinstance(lst, list):
                die("hooks.%s is not an array; left untouched" % event)
            lst, _ = strip_ours(lst)
            hook = {"type": "command", "command": cmd}
            hook.update({"timeout": 100} if event == "PermissionRequest" else {"async": True})
            lst.append(dict(extra, hooks=[hook]))
            hooks[event] = lst
        done = "installed in"
    else:
        changed_any = False
        for event in list(hooks):
            if not isinstance(hooks[event], list):
                continue
            lst, changed = strip_ours(hooks[event])
            if changed:
                changed_any = True
                if lst:
                    hooks[event] = lst
                else:
                    del hooks[event]
        if not changed_any:
            print("no claude-board hooks found in", path)
            return
        if not hooks:
            del s["hooks"]
        done = "removed from"
    text = json.dumps(s, indent=2, ensure_ascii=False) + "\n"
    backup(path)
    atomic_write(path, text)
    print("hooks", done, path)


if __name__ == "__main__":
    main(sys.argv)
