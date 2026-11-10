#!/usr/bin/env python3
"""Move project folders and everything Claude Code ties to their path.

Claude Code files chats by working directory: ~/.claude/projects/<encoded path>/ holds the
transcripts and the project's auto memory, every transcript line records its "cwd", and
history.jsonl records the "project" of each prompt. Codex records "cwd" in its sessions. A folder
moved by hand loses all of that (/resume, memory, history); this moves them together.

Usage: move_project.py moves.json [--apply]
moves.json: [["/old/path", "/new/path"], ...]. Without --apply it only reports.
Refuses folders where a Claude session or another process is working. Keeps file dates.
"""
import json, os, re, subprocess, sys, glob

HOME = os.path.expanduser("~")
STORE = os.path.realpath(os.path.join(HOME, ".claude/projects"))
CONFIG_DIRS = [os.path.join(HOME, d) for d in (".claude", ".claude-fede", ".claude-gusto")]
OPENBOARD_CONFIG = os.path.join(HOME, "Library/Application Support/OpenBoard/config.json")


def enc(path):
    return re.sub(r"[^A-Za-z0-9]", "-", path)


def inside(path, root):
    return path == root or path.startswith(root + "/")


def busy(src):
    """Live Claude sessions and processes whose working directory is inside src."""
    found = []
    for d in CONFIG_DIRS:
        for f in glob.glob(os.path.join(d, "sessions", "*.json")):
            try:
                pid = int(os.path.basename(f)[:-5])
                os.kill(pid, 0)
                if inside(json.load(open(f)).get("cwd", ""), src):
                    found.append(f"claude {pid}")
            except Exception:
                pass
    out = subprocess.run(["lsof", "-a", "-d", "cwd", "-Fpn"], capture_output=True, text=True).stdout
    pid = None
    for line in out.splitlines():
        if line.startswith("p"):
            pid = line[1:]
        elif line.startswith("n") and inside(line[1:], src):
            found.append(f"process {pid}")
    return found


def dir_cwd(path):
    """The working directory a transcript folder belongs to, from its transcripts."""
    for f in sorted(glob.glob(os.path.join(path, "*.jsonl"))):
        with open(f, "rb") as h:
            for i, line in enumerate(h):
                if i > 200:
                    break
                m = re.search(rb'"cwd":"((?:[^"\\]|\\.)*)"', line)
                if m:
                    return json.loads(b'"' + m.group(1) + b'"')
    return None


def rewrite(path, pairs, key):
    """Replaces "key":"<src>…" with "key":"<dst>…" in a JSON-lines file, keeping its dates."""
    stat = os.stat(path)
    changed = False
    tmp = path + ".moving"
    with open(path, "rb") as src_file, open(tmp, "wb") as out:
        for line in src_file:
            if f'"{key}":"'.encode() in line:
                for old, new in pairs:
                    for tail in (b'"', b"/"):
                        a = f'"{key}":"{old}'.encode() + tail
                        if a in line:
                            line = line.replace(a, f'"{key}":"{new}'.encode() + tail)
                            changed = True
            out.write(line)
    if changed:
        os.replace(tmp, path)
        os.utime(path, (stat.st_atime, stat.st_mtime))
    else:
        os.remove(tmp)
    return changed


def plan(moves):
    problems, store_moves = [], []
    for src, dst in moves:
        if not os.path.exists(src):
            problems.append(f"{src}: non esiste")
        elif os.path.exists(dst):
            problems.append(f"{dst}: esiste già")
        elif os.path.isdir(src) and (who := busy(src)):
            problems.append(f"{src}: in uso ({', '.join(who)})")
    for name in sorted(os.listdir(STORE)):
        path = os.path.join(STORE, name)
        if not os.path.isdir(path):
            continue
        cwd = dir_cwd(path)
        for src, dst in moves:
            if (cwd and inside(cwd, src)) or (cwd is None and name == enc(src)):
                new_cwd = dst + (cwd[len(src):] if cwd else "")
                store_moves.append((path, os.path.join(STORE, enc(new_cwd))))
                break
    return problems, store_moves


def apply(moves, store_moves):
    for src, dst in moves:
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        os.rename(src, dst)
        print(f"cartella  {src} -> {dst}")
    for old, new in store_moves:
        if os.path.exists(new):
            for entry in os.listdir(old):
                target = os.path.join(new, entry)
                if os.path.exists(target):
                    raise SystemExit(f"conflitto: {target}")
                os.rename(os.path.join(old, entry), target)
            os.rmdir(old)
        else:
            os.rename(old, new)
        n = sum(rewrite(f, moves, "cwd") for f in glob.glob(os.path.join(new, "**", "*.jsonl"), recursive=True))
        print(f"chat      {os.path.basename(old)} -> {os.path.basename(new)} ({n} file aggiornati)")
    n = 0
    for f in glob.glob(os.path.join(HOME, ".codex/sessions/**/*.jsonl"), recursive=True):
        n += rewrite(f, moves, "cwd")
    print(f"codex     {n} sessioni aggiornate")
    for d in CONFIG_DIRS:
        h = os.path.join(d, "history.jsonl")
        if os.path.exists(h) and rewrite(h, moves, "project"):
            print(f"history   {h}")
    if os.path.exists(OPENBOARD_CONFIG):
        config = json.load(open(OPENBOARD_CONFIG))

        def moved(path):
            for src, dst in moves:
                if inside(path, src):
                    return dst + path[len(src):]
            return path

        for key in ("folderContexts", "milestones"):
            if isinstance(config.get(key), dict):
                config[key] = {moved(k): v for k, v in config[key].items()}
        for team in (config.get("teams") or {}).values():
            team["directory"] = moved(team.get("directory", ""))
        json.dump(config, open(OPENBOARD_CONFIG, "w"), indent=2, sort_keys=True, ensure_ascii=False)
        print("openboard config aggiornata")


if __name__ == "__main__":
    moves = [(os.path.abspath(os.path.expanduser(a)), os.path.abspath(os.path.expanduser(b)))
             for a, b in json.load(open(sys.argv[1]))]
    problems, store_moves = plan(moves)
    for p in problems:
        print("PROBLEMA", p)
    print(f"{len(moves)} cartelle, {len(store_moves)} cartelle di chat")
    if "--apply" in sys.argv:
        if problems:
            raise SystemExit("Niente fatto: risolvi i problemi sopra.")
        apply(moves, store_moves)
    else:
        for old, new in store_moves:
            print(f"  {os.path.basename(old)} -> {os.path.basename(new)}")
