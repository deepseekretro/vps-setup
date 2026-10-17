#!/usr/bin/env python3
"""Multi-tab web terminal backend with persistent sessions.

Sessions outlive the WebSocket connection: a browser refresh (or a network
blip) detaches a client but keeps the shell (and its scrollback buffer) alive,
so reconnecting re-attaches to the *same* shell and replays missed output.

Protocol (JSON frames):
  Client -> Server:
    {"type": "attach", "sessions": [{"id", "cols", "rows"}, ...]}   attach/create + replay
    {"type": "create", "id": "...", "cols": 80, "rows": 24}         create one session
    {"type": "input",  "id": "...", "data": "..."}                  keystrokes
    {"type": "resize", "id": "...", "cols": 80, "rows": 24}
    {"type": "close",  "id": "..."}                                 kill a session
    {"type": "list"}                                                list live sessions
    {"type": "upload", "id": "...", "upid": "...", "name": "...", "mime": "image/png",
     "seq": 0, "data": "<base64 chunk>", "last": false}             image upload
    {"type": "ping"}
  Server -> Client:
    {"type": "reset",    "id": "..."}                 clear terminal before replay
    {"type": "output",   "id": "...", "data": "..."}
    {"type": "attached", "id": "..."}                 session is live and attached
    {"type": "exit",     "id": "...", "code": 0}
    {"type": "sessions", "ids": ["...", ...]}
    {"type": "upload_done",  "id", "upid", "path", "rel", "name", "bytes", "mime"}
    {"type": "upload_error", "id", "upid", "error"}
    {"type": "pong"}
"""

import asyncio
import base64
import fcntl
import json
import os
import pty
import re
import signal
import struct
import subprocess
import termios
import time

import websockets

LISTEN_PORT = int(os.environ.get("TERM_PORT", "9000"))
# Output delivery. By default the pump is event-driven: each PTY master fd has a
# loop reader, so a repaint frame is forwarded the instant the app writes it and
# an idle server wakes for nothing (a 30ms poll both downsampled opencode's
# ~60fps scroll animation and merged frames on the wire). Setting TERM_READ_INTERVAL
# explicitly forces the old fixed-interval polling path (used by the A/B test).
READ_INTERVAL_ENV = os.environ.get("TERM_READ_INTERVAL")
READ_INTERVAL = float(READ_INTERVAL_ENV) if READ_INTERVAL_ENV else 0.005
USE_READERS = READ_INTERVAL_ENV is None
WAKE = None                     # asyncio.Event, created in main()
MAX_BUF = 512 * 1024                       # per-session replay ring buffer
DETACHED_TTL = int(os.environ.get("TERM_TTL", "1800"))   # keep detached shells (s)
MAX_SESSIONS = 50

# --- terminal capability probes -------------------------------------------------
# TUI apps ask the terminal what it can do. opencode asks XTGETTCAP for "Ms"
# (= OSC 52 clipboard) and only enables its copy features if the answer is yes.
# xterm.js does not answer, so we answer on its behalf: the frontend really does
# implement OSC 52 (see handleOsc52 in app.js).
XTGETTCAP_RE = re.compile(rb"\x1bP\+q([0-9a-fA-F;]+)\x1b\\")
XTVERSION_RE = re.compile(rb"\x1b\[>0?q")
MS_NAME = b"4d73"                                   # hex("Ms")
MS_VALUE = b"\x1b]52;c;%p1%s\x07"                   # iTerm2-style template
MS_HEX = MS_VALUE.hex().encode()
TERM_NAME = b"WebTerm(1.0)"
PROBE_TAIL = 256
OSC52_SEEN_RE = re.compile(rb"\x1b\]52;")            # apps copying via OSC 52

SESSIONS = {}   # id -> {proc, master_fd, ws|None, buf, detached_at, last, readable}


def log(msg):
    print(msg, flush=True)


def _readable(sid):
    """Loop reader callback: this PTY has data (or hit EOF). Never reads here;
    it only flags the session and wakes the pump, which owns all I/O."""
    ses = SESSIONS.get(sid)
    if ses is None:
        return
    ses["readable"] = True
    if WAKE is not None:
        WAKE.set()


def arm_reader(ses, sid):
    """Watch a PTY master fd with the event loop instead of polling it."""
    global USE_READERS
    if not USE_READERS:
        return
    try:
        asyncio.get_running_loop().add_reader(ses["master_fd"], _readable, sid)
    except (NotImplementedError, RuntimeError, AttributeError, ValueError):
        USE_READERS = False
        log("[term] loop has no add_reader: falling back to polling")
        if WAKE is not None:
            WAKE.set()          # make the pump switch over right away


def disarm_reader(ses):
    """Must run before the fd is closed, or a recycled fd would keep a stale
    callback pointing at the wrong session."""
    try:
        asyncio.get_running_loop().remove_reader(ses["master_fd"])
    except (NotImplementedError, RuntimeError, ValueError, AttributeError):
        pass


def which(cmd):
    try:
        r = subprocess.run(["/usr/bin/which", cmd], capture_output=True, text=True)
        return r.stdout.strip()
    except OSError:
        return ""


DEFAULT_SHELL = which("bash") or "/bin/bash"
DEFAULT_CWD = os.path.expanduser("~") if os.path.isdir(os.path.expanduser("~")) else "/root"

# --- opencode session listing (left-hand navigation) ---------------------------
# Read-only: shells out to the official CLI rather than touching opencode.db, so
# it keeps working if the storage schema changes.
OC_BIN = os.environ.get("TERM_OPENCODE_BIN") or which("opencode") or "/root/.opencode/bin/opencode"
OC_CWD = os.environ.get("TERM_OPENCODE_CWD") or DEFAULT_CWD
OC_LIMIT = int(os.environ.get("TERM_OPENCODE_LIMIT", "50"))
OC_CACHE = float(os.environ.get("TERM_OPENCODE_CACHE", "4"))
_oc_cache = {"ts": 0.0, "items": None, "error": None}


async def opencode_sessions(force=False):
    """List opencode sessions, newest first. Returns (items, error)."""
    now = time.time()
    if (not force and _oc_cache["items"] is not None
            and now - _oc_cache["ts"] < OC_CACHE):
        return _oc_cache["items"], _oc_cache["error"]

    items, err = None, None
    try:
        proc = await asyncio.create_subprocess_exec(
            OC_BIN, "session", "list", "--format=json", "-n", str(OC_LIMIT),
            cwd=OC_CWD,
            stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE)
        out, errb = await asyncio.wait_for(proc.communicate(), timeout=15)
        if proc.returncode != 0:
            err = (errb.decode("utf-8", "replace").strip()[:200]
                   or f"opencode exited {proc.returncode}")
        else:
            raw = json.loads(out.decode("utf-8", "replace") or "[]")
            items = sorted(
                ({"id": str(s.get("id", "")),
                  "title": str(s.get("title") or "").strip() or "(无标题)",
                  "updated": int(s.get("updated") or 0),
                  "directory": str(s.get("directory") or "")}
                 for s in raw if s.get("id")),
                key=lambda s: s["updated"], reverse=True)
    except asyncio.TimeoutError:
        err = "opencode session list 超时"
    except FileNotFoundError:
        err = f"找不到 opencode 可执行文件: {OC_BIN}"
    except json.JSONDecodeError as exc:
        err = f"opencode 输出无法解析: {exc}"
    except Exception as exc:                      # never take the backend down
        err = f"{type(exc).__name__}: {exc}"

    if items is not None or force:
        _oc_cache.update(ts=now, items=items, error=err)
    return items, err


# Only ever pass ids that look exactly like what the CLI produces, so nothing
# coming from the browser can be interpreted as a flag or a path.
OC_SID_RE = re.compile(r"^ses_[A-Za-z0-9]{6,64}$")


async def opencode_session_delete(session_id):
    """Delete an opencode session (and its child sessions). Returns (ok, error)."""
    if not OC_SID_RE.match(session_id or ""):
        return False, "非法的会话 id"
    try:
        proc = await asyncio.create_subprocess_exec(
            OC_BIN, "session", "delete", session_id, cwd=OC_CWD,
            stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE)
        _, errb = await asyncio.wait_for(proc.communicate(), timeout=20)
        if proc.returncode != 0:
            return False, (errb.decode("utf-8", "replace").strip()[:300]
                           or f"opencode exited {proc.returncode}")
    except asyncio.TimeoutError:
        return False, "opencode session delete 超时"
    except FileNotFoundError:
        return False, f"找不到 opencode 可执行文件: {OC_BIN}"
    except Exception as exc:
        return False, f"{type(exc).__name__}: {exc}"

    _oc_cache.update(ts=0.0, items=None, error=None)   # next listing must be fresh
    return True, None


# --- image uploads (attached to opencode prompts from the browser) -------------
# The browser streams an image in base64 chunks; we drop it into
# <OC_CWD>/webterm-uploads/ and answer with the path. The frontend then types
# "@<relative path>" into the PTY, which is how opencode's TUI attaches a file.
# Storing it *inside the project directory* matters: opencode's "@" search only
# looks at the session's own directory (absolute paths and ".." find nothing).
UPLOAD_DIR = os.environ.get("TERM_UPLOAD_DIR") or os.path.join(OC_CWD, "webterm-uploads")
UPLOAD_MAX = int(os.environ.get("TERM_UPLOAD_MAX", str(20 * 1024 * 1024)))  # bytes/file
UPLOAD_KEEP = int(os.environ.get("TERM_UPLOAD_KEEP", "80"))                 # newest kept
UPLOAD_TTL = 180                                   # drop unfinished uploads after this
UPLOAD_TYPES = {                                   # mime -> extension (whitelist)
    "image/png": ".png", "image/jpeg": ".jpg", "image/jpg": ".jpg",
    "image/gif": ".gif", "image/webp": ".webp", "image/bmp": ".bmp",
}
UPLOADS = {}                                       # upid -> {id, mime, name, data, ts}


def looks_like_image(data, mime):
    """Snapshot check of the magic bytes: we only ever store real images."""
    if mime == "image/png":
        return data.startswith(b"\x89PNG\r\n\x1a\n")
    if mime in ("image/jpeg", "image/jpg"):
        return data.startswith(b"\xff\xd8\xff")
    if mime == "image/gif":
        return data.startswith(b"GIF8")
    if mime == "image/webp":
        return data.startswith(b"RIFF") and data[8:12] == b"WEBP"
    if mime == "image/bmp":
        return data.startswith(b"BM")
    return False


def prune_uploads():
    """Forget stalled uploads and keep only the newest files on disk."""
    now = time.time()
    for upid in [k for k, v in UPLOADS.items() if now - v["ts"] > UPLOAD_TTL]:
        UPLOADS.pop(upid, None)
    try:
        names = sorted(
            (n for n in os.listdir(UPLOAD_DIR)
             if os.path.splitext(n)[1].lower() in UPLOAD_TYPES.values()),
            key=lambda n: os.path.getmtime(os.path.join(UPLOAD_DIR, n)))
    except OSError:
        return
    if UPLOAD_KEEP > 0:
        for name in names[:-UPLOAD_KEEP]:
            try:
                os.unlink(os.path.join(UPLOAD_DIR, name))
            except OSError:
                pass


def upload_chunk(msg):
    """Add one base64 chunk to an upload; returns a reply on the last chunk."""
    upid = str(msg.get("upid") or "")
    tab_id = str(msg.get("id") or "")
    if not upid:
        return {"type": "upload_error", "id": tab_id, "upid": upid, "error": "缺少上传 id"}

    up = UPLOADS.get(upid)
    if up is None:
        mime = str(msg.get("mime") or "").split(";")[0].strip().lower()
        if mime not in UPLOAD_TYPES:
            return {"type": "upload_error", "id": tab_id, "upid": upid,
                    "error": "只支持 png / jpg / gif / webp / bmp 图片"}
        up = {"id": tab_id, "mime": mime, "name": str(msg.get("name") or "image"),
              "data": bytearray(), "ts": time.time()}
        UPLOADS[upid] = up

    try:
        chunk = base64.b64decode(str(msg.get("data") or ""), validate=True)
    except Exception:
        UPLOADS.pop(upid, None)
        return {"type": "upload_error", "id": up["id"], "upid": upid, "error": "上传数据损坏"}

    if len(up["data"]) + len(chunk) > UPLOAD_MAX:
        UPLOADS.pop(upid, None)
        return {"type": "upload_error", "id": up["id"], "upid": upid,
                "error": f"图片太大（上限 {UPLOAD_MAX // (1024 * 1024)}MB）"}

    up["data"] += chunk
    up["ts"] = time.time()
    if not msg.get("last"):
        return None
    UPLOADS.pop(upid, None)
    return save_upload(upid, up)


def save_upload(upid, up):
    data = bytes(up["data"])
    if not looks_like_image(data, up["mime"]):
        return {"type": "upload_error", "id": up["id"], "upid": upid,
                "error": "文件内容不是有效的图片"}

    try:
        os.makedirs(UPLOAD_DIR, exist_ok=True)
    except OSError as exc:
        return {"type": "upload_error", "id": up["id"], "upid": upid,
                "error": f"无法创建目录：{exc}"}

    # Never trust the client's filename: generate one, keep it unique so the "@"
    # search has exactly one match.
    fname = "img-{}-{}{}".format(time.strftime("%Y%m%d-%H%M%S"), os.urandom(3).hex(),
                                 UPLOAD_TYPES[up["mime"]])
    path = os.path.join(UPLOAD_DIR, fname)
    tmp = path + ".part"
    try:
        with open(tmp, "wb") as fh:
            fh.write(data)
        os.chmod(tmp, 0o644)
        os.replace(tmp, path)
    except OSError as exc:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        return {"type": "upload_error", "id": up["id"], "upid": upid,
                "error": f"写入失败：{exc}"}

    prune_uploads()
    rel = os.path.relpath(path, OC_CWD)
    log(f"[up] saved {path} ({len(data)}B, {up['mime']}, rel={rel})")
    return {"type": "upload_done", "id": up["id"], "upid": upid, "path": path,
            "rel": rel, "name": os.path.basename(str(up["name"])) or fname,
            "bytes": len(data), "mime": up["mime"]}


def set_winsize(fd, cols, rows):
    try:
        cols, rows = max(int(cols), 2), max(int(rows), 2)
    except (TypeError, ValueError):
        return
    try:
        fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))
    except OSError:
        pass


def buffer_out(ses, data):
    """Ring buffer of recent output, used to replay history on re-attach."""
    buf = ses["buf"]
    buf.extend(data)
    over = len(buf) - MAX_BUF
    if over > 0:
        cut = over
        nl = buf.find(b"\n", cut)      # resync to a line boundary when trimming
        if 0 <= nl < cut + 8192:
            cut = nl + 1
        del buf[:cut]


def create_session(sid, cols=80, rows=24):
    """Spawn a shell in a fresh PTY. Returns True on success."""
    if sid in SESSIONS:
        return True
    if len(SESSIONS) >= MAX_SESSIONS:
        log(f"[term] refused {sid}: session limit {MAX_SESSIONS}")
        return False

    master_fd, slave_fd = pty.openpty()
    env = os.environ.copy()
    env["TERM"] = "xterm-256color"
    try:
        proc = subprocess.Popen(
            [DEFAULT_SHELL],
            stdin=slave_fd, stdout=slave_fd, stderr=slave_fd,
            start_new_session=True,     # own session/pgid for clean signal handling
            env=env, cwd=DEFAULT_CWD,
        )
    except OSError as e:
        os.close(master_fd)
        os.close(slave_fd)
        log(f"[term] spawn failed for {sid}: {e}")
        return False
    os.close(slave_fd)
    fcntl.fcntl(master_fd, fcntl.F_SETFL,
                fcntl.fcntl(master_fd, fcntl.F_GETFL) | os.O_NONBLOCK)
    set_winsize(master_fd, cols, rows)
    SESSIONS[sid] = {
        "proc": proc, "master_fd": master_fd, "ws": None,
        "buf": bytearray(), "detached_at": time.time(), "last": time.time(),
        "readable": False,
    }
    arm_reader(SESSIONS[sid], sid)
    log(f"[term] created {sid} pid={proc.pid}")
    return True


def remove_session(sid):
    """Drop a session and terminate its process tree. Returns the record."""
    ses = SESSIONS.pop(sid, None)
    if not ses:
        return None
    disarm_reader(ses)
    try:
        os.close(ses["master_fd"])
    except OSError:
        pass
    proc = ses["proc"]
    if proc.poll() is None:
        try:
            os.killpg(os.getpgid(proc.pid), signal.SIGHUP)
        except (ProcessLookupError, PermissionError):
            pass
        try:
            proc.wait(timeout=3)
        except subprocess.TimeoutExpired:
            try:
                os.killpg(os.getpgid(proc.pid), signal.SIGKILL)
            except (ProcessLookupError, PermissionError):
                pass
    log(f"[term] removed {sid}")
    return ses


def drain(ses):
    """Read all pending PTY output. Returns (data, closed)."""
    fd = ses["master_fd"]
    data = b""
    while True:
        try:
            chunk = os.read(fd, 65536)
        except BlockingIOError:
            return data, False
        except OSError:          # PTY closed -> child exited
            return data, True
        if not chunk:
            return data, False
        data += chunk


async def finish_session(sid):
    """Session's shell exited: notify the attached client, then drop it."""
    ses = remove_session(sid)
    if not ses:
        return
    ws = ses["ws"]
    if ws is not None:
        code = ses["proc"].poll()
        try:
            await ws.send(json.dumps({"type": "exit", "id": sid,
                                      "code": code if code is not None else -1}))
        except Exception:
            pass


def expire_detached():
    """Reap shells nobody has re-attached to within DETACHED_TTL."""
    now = time.time()
    for sid, ses in list(SESSIONS.items()):
        if ses["ws"] is None and now - ses["detached_at"] > DETACHED_TTL:
            log(f"[term] expiring detached session {sid} "
                f"(>{DETACHED_TTL}s, buf={len(ses['buf'])}B)")
            remove_session(sid)


def answer_probes(ses, data):
    """Reply to terminal capability probes found in the app's output.

    Handles queries that may be split across reads by keeping a small tail.
    Returns bytes to write back into the PTY (terminal -> app direction).
    """
    buf = (ses.get("probe_buf") or b"") + data
    last = 0
    replies = []

    for m in XTGETTCAP_RE.finditer(buf):
        last = max(last, m.end())
        wanted = [n for n in m.group(1).split(b";") if n]
        found = []
        for name in wanted:
            if name.lower() == MS_NAME:
                found.append(MS_NAME + b"=" + MS_HEX)
        if found:
            replies.append(b"\x1bP1+r" + b";".join(found) + b"\x1b\\")
        elif wanted:
            log(f"[term] capability probe for {wanted!r}: not supported")

    for m in XTVERSION_RE.finditer(buf):
        last = max(last, m.end())
        replies.append(b"\x1bP>|" + TERM_NAME + b"\x1b\\")

    ses["probe_buf"] = buf[last:][-PROBE_TAIL:]
    return b"".join(replies)


async def pump_forever():
    """Single global loop: keep per-session scrollback, forward to the attached client.

    Event-driven: waits on a loop reader per PTY (no polling), so a frame written
    by the app is forwarded immediately. A 1s timeout doubles as the TTL reaper
    tick and as a safety sweep in case a readable notification is ever missed.
    """
    while True:
        sweep_all = True
        if USE_READERS and WAKE is not None:
            try:
                await asyncio.wait_for(WAKE.wait(), timeout=1.0)
                sweep_all = False
            except asyncio.TimeoutError:
                pass
            WAKE.clear()
        else:
            await asyncio.sleep(READ_INTERVAL)

        expire_detached()
        for sid, ses in list(SESSIONS.items()):
            if USE_READERS and not sweep_all and not ses.get("readable"):
                continue
            ses["readable"] = False
            data, closed = drain(ses)
            if data:
                ses["last"] = time.time()
                reply = answer_probes(ses, data)      # terminal capability replies
                if reply:
                    try:
                        os.write(ses["master_fd"], reply)
                    except OSError:
                        pass                          # tiny replies; EAGAIN is fine
                if OSC52_SEEN_RE.search(data):
                    log(f"[term] {sid}: OSC 52 clipboard write from app")
                buffer_out(ses, data)          # always keep history for re-attach replay
                ws = ses["ws"]
                if ws is not None:
                    try:
                        await ws.send(json.dumps({"type": "output", "id": sid,
                                                  "data": data.decode("utf-8", "replace")}))
                    except Exception:
                        # client vanished: just detach, the output stays buffered
                        ses["ws"] = None
                        ses["detached_at"] = time.time()
            if closed:
                await finish_session(sid)


async def attach_all(ws, items):
    """Attach to existing sessions (replaying their buffer) or create new ones."""
    for it in items:
        sid = str(it.get("id", "") or "")
        if not sid:
            continue
        cols = it.get("cols", 80)
        rows = it.get("rows", 24)
        ses = SESSIONS.get(sid)
        if ses is None:
            if not create_session(sid, cols, rows):
                continue
            ses = SESSIONS[sid]
            # fresh session: nothing to replay, just tell the client it is live
            ses["ws"] = ws
            try:
                await ws.send(json.dumps({"type": "reset", "id": sid}))
                await ws.send(json.dumps({"type": "output", "id": sid,
                                          "data": "\x1b[38;5;244m[原会话已结束，已开启新会话]\x1b[0m\r\n"}))
                await ws.send(json.dumps({"type": "attached", "id": sid}))
            except Exception:
                ses["ws"] = None
                ses["detached_at"] = time.time()
            continue

        ses["ws"] = ws
        set_winsize(ses["master_fd"], cols, rows)
        buf = bytes(ses["buf"])
        try:
            await ws.send(json.dumps({"type": "reset", "id": sid}))
            if buf:
                await ws.send(json.dumps({"type": "output", "id": sid,
                                          "data": buf.decode("utf-8", "replace")}))
            await ws.send(json.dumps({"type": "attached", "id": sid}))
            log(f"[term] re-attached {sid} (replayed {len(buf)}B)")
        except Exception:
            ses["ws"] = None
            ses["detached_at"] = time.time()


async def handler(ws):
    peer = ws.remote_address
    log(f"[ws] connected {peer}")
    try:
        async for raw in ws:
            try:
                msg = json.loads(raw)
            except (json.JSONDecodeError, TypeError):
                continue
            mtype = msg.get("type", "")
            sid = str(msg.get("id", "") or "")
            ses = SESSIONS.get(sid)

            if mtype == "attach":
                await attach_all(ws, msg.get("sessions") or [])
            elif mtype == "create":
                if create_session(sid, msg.get("cols", 80), msg.get("rows", 24)):
                    SESSIONS[sid]["ws"] = ws
            elif mtype == "input":
                if ses:
                    try:
                        os.write(ses["master_fd"], str(msg.get("data", "")).encode())
                        ses["last"] = time.time()
                    except OSError:
                        pass
            elif mtype == "resize":
                if ses:
                    set_winsize(ses["master_fd"], msg.get("cols", 80), msg.get("rows", 24))
            elif mtype == "close":
                ses = SESSIONS.get(sid)
                if ses:
                    ses["ws"] = None        # client-initiated: no exit event needed
                remove_session(sid)
            elif mtype == "list":
                await ws.send(json.dumps({"type": "sessions", "ids": list(SESSIONS)}))
            elif mtype == "opencode_sessions":
                items, err = await opencode_sessions(bool(msg.get("force")))
                await ws.send(json.dumps({"type": "opencode_sessions",
                                          "items": items or [], "error": err,
                                          "bin": OC_BIN, "fetched": time.time()}))
            elif mtype == "opencode_session_delete":
                target = str(msg.get("session") or "")
                ok, derr = await opencode_session_delete(target)
                if ok:
                    log(f"[oc] deleted session {target}")
                else:
                    log(f"[oc] delete {target} failed: {derr}")
                await ws.send(json.dumps({"type": "opencode_session_deleted",
                                          "session": target, "ok": ok, "error": derr}))
            elif mtype == "upload":
                reply = upload_chunk(msg)
                if reply is not None:
                    await ws.send(json.dumps(reply))
            elif mtype == "ping":
                await ws.send(json.dumps({"type": "pong"}))
    except websockets.exceptions.ConnectionClosed:
        pass
    finally:
        # Detach only: shells keep running (and buffering) for DETACHED_TTL.
        for sid, ses in list(SESSIONS.items()):
            if ses["ws"] is ws:
                ses["ws"] = None
                ses["detached_at"] = time.time()
        log(f"[ws] disconnected {peer} (sessions kept: {len(SESSIONS)})")


async def main():
    global WAKE
    WAKE = asyncio.Event()
    asyncio.ensure_future(pump_forever())
    server = await websockets.serve(handler, "127.0.0.1", LISTEN_PORT,
                                    origins=None, ping_interval=20, max_size=8 * 1024 * 1024)
    log(f"[srv] web-terminal backend on 127.0.0.1:{LISTEN_PORT} "
        f"(shell={DEFAULT_SHELL}, detached TTL={DETACHED_TTL}s, "
        f"output={'event-driven' if USE_READERS else format(READ_INTERVAL, '.3f') + 's poll'})")
    await server.wait_closed()


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        for sid in list(SESSIONS):
            remove_session(sid)
