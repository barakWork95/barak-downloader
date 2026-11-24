#!/usr/bin/env python3
"""מנוע ההורדות. משותף לסקריפט הטרמינל (ytdl.py) ולאפליקציה.

כמודול: fetch() -> describe() -> download()
כפקודה (בשביל האפליקציה, הפלט הוא JSON):
    engine.py info <קישור> [--cookies chrome]     -> אובייקט JSON אחד
    engine.py download <state.json> <מספר-בחירה> [אפשרויות-JSON]  -> שורת JSON לכל אירוע
        אפשרויות: out_dir, by_platform, name_style (title_quality|title|uploader_title),
                  trim [התחלה, סוף] בשניות, whatsapp, sponsorblock
    engine.py update                             -> brew upgrade yt-dlp
"""

from __future__ import annotations

import json
import os
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import time
from pathlib import Path

DOWNLOAD_DIR = Path(os.environ.get("YTDL_DIR", Path.home() / "Downloads"))
STATE_DIR = Path(tempfile.gettempdir()) / "ytdl-states"
MAX_ITEMS = 20  # פוסט עם כמה סרטונים (קרוסלה באינסטגרם, ציוץ עם כמה סרטונים)

# כשהאפליקציה נפתחת מ-Finder אין לה את הנתיבים של Homebrew
os.environ["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + os.environ.get("PATH", "/usr/bin:/bin")

PLATFORM_NAMES = {"youtube": "YouTube", "instagram": "Instagram", "tiktok": "TikTok",
                  "facebook": "Facebook", "twitter": "X", "vimeo": "Vimeo", "reddit": "Reddit"}


class EngineError(Exception):
    def __init__(self, kind: str, message: str, detail: str = ""):
        super().__init__(message)
        self.kind, self.message, self.detail = kind, message, detail

    def as_dict(self) -> dict:
        return {"kind": self.kind, "message": self.message, "detail": self.detail}


def missing_tools() -> list:
    return [t for t in ("yt-dlp", "ffmpeg") if not shutil.which(t)]


# ---------- שגיאות ----------

ERROR_RULES = [
    (r"Failed to resolve|nodename nor servname|Network is unreachable|timed out|Connection (refused|reset)",
     "network", "אין חיבור לאתר. בדוק את החיבור לאינטרנט ונסה שוב."),
    (r"Unsupported URL|is not a valid URL", "unsupported",
     "האתר הזה לא נתמך, או שהקישור לא מוביל לסרטון."),
    (r"IP address is blocked", "blocked",
     "האתר חוסם את ההורדה של הפוסט הזה מהרשת שלך."),
    (r"log ?in|sign in|cookies|private|confirm your age|age-restricted|rate.?limit|authenticat",
     "login", "הסרטון דורש התחברות: הוא פרטי, מוגבל גיל, או שהאתר לא מציג אותו בלי חשבון."),
    (r"No video formats|no video in this|There's no video|does not contain any video", "novideo",
     "לא מצאתי וידאו בקישור הזה. אולי זה פוסט של תמונה בלבד?"),
    (r"unavailable|not available|removed|deleted|HTTP Error 404|does not exist", "unavailable",
     "הסרטון לא זמין. ייתכן שהוא נמחק או הוסתר."),
]


def classify(stderr: str) -> EngineError:
    detail = "\n".join(l for l in stderr.splitlines() if l.startswith("ERROR")) or stderr.strip()[-600:]
    for pattern, kind, message in ERROR_RULES:
        if re.search(pattern, detail, re.I):
            return EngineError(kind, message, detail)
    return EngineError("generic", "משהו השתבש. אם זה קורה גם בסרטונים אחרים, עדכון yt-dlp בדרך כלל פותר את זה.", detail)


# ---------- קריאת הסרטון ----------

def fetch(url: str, cookies: str | None = None) -> dict:
    url = url.strip()
    if not re.match(r"^https?://", url):
        url = "https://" + url
    cmd = ["yt-dlp", "-J", "--no-playlist", "--no-warnings", "--playlist-items", f"1:{MAX_ITEMS + 1}", url]
    if cookies:
        cmd += ["--cookies-from-browser", cookies]
    try:
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=180)
    except subprocess.TimeoutExpired:
        raise EngineError("generic", "האתר לא ענה בזמן. נסה שוב בעוד רגע.")
    if result.returncode != 0:
        raise classify(result.stderr)
    info = json.loads(result.stdout)
    info["_cookies"] = cookies
    return info


def platform_of(info: dict) -> str:
    key = (info.get("extractor_key") or info.get("extractor") or "").lower()
    for prefix, name in PLATFORM_NAMES.items():
        if key.startswith(prefix):
            return name
    return info.get("webpage_url_domain") or info.get("extractor_key") or ""


# ---------- בחירת איכויות ----------

def size_of(fmt) -> int:
    return (fmt or {}).get("filesize") or (fmt or {}).get("filesize_approx") or 0


def is_audio_only(f: dict) -> bool:
    return f.get("vcodec") == "none" and f.get("acodec") != "none"


def is_video(f: dict) -> bool:
    # vcodec חסר = לא ידוע (נפוץ ב-X ובפייסבוק), ולכן נחשב וידאו. רק "none" מפורש הוא לא-וידאו
    return f.get("vcodec") != "none" and f.get("ext") != "mhtml" and "storyboard" not in (f.get("format_note") or "")


def codec_rank(f: dict) -> int:
    """H.264 נפתח בכל מקום (QuickTime, וואטסאפ, עורכי וידאו), אחריו VP9, ורק אז AV1."""
    vcodec = (f.get("vcodec") or "").lower()
    if vcodec.startswith(("avc1", "h264")):
        return 3
    if vcodec.startswith(("vp9", "vp09")):
        return 2
    if vcodec.startswith("av01"):
        return 1
    return 0


def pick_video(formats: list) -> dict:
    # קבצים רגילים (https) קודם: גודל ידוע והורדה מהירה יותר מ-HLS
    return max(formats, key=lambda f: (f.get("protocol") == "https", codec_rank(f), f.get("fps") or 0,
                                       f.get("tbr") or 0, size_of(f)))


def pick_audio(formats: list):
    # AAC סטריאו רגיל, בלי גרסת "drc" (דחיסת עוצמה) ובלי 5.1
    return max(formats, key=lambda f: (
        (f.get("acodec") or "").startswith("mp4a"),
        "drc" not in (f.get("format_id") or ""),
        (f.get("audio_channels") or 2) <= 2,
        f.get("protocol") == "https",
        f.get("abr") or f.get("tbr") or 0,
    ), default=None)


def needs_player_note(f: dict) -> bool:
    return (f.get("vcodec") or "").lower().startswith(("vp9", "vp09", "av01"))


QT_NOTE = "לא נפתח ב-QuickTime, כן ב-VLC/IINA"


def entry_options(entry: dict) -> list:
    """האיכויות של סרטון בודד: [{label, rank, format, size, note, audio_only}]"""
    formats = entry.get("formats") or [entry]
    video = [f for f in formats if is_video(f)]
    audio = pick_audio([f for f in formats if is_audio_only(f)])
    with_height = [f for f in video if f.get("height")]
    options = []

    def spec_for(f):
        has_audio = f.get("acodec") != "none"
        return (f["format_id"], size_of(f)) if has_audio or not audio else \
            (f"{f['format_id']}+{audio['format_id']}", size_of(f) + size_of(audio))

    if with_height:
        for height in sorted({f["height"] for f in with_height}, reverse=True):
            best = pick_video([f for f in with_height if f["height"] == height])
            short_side = min(best.get("width") or height, height)  # סרטון אנכי: 1080x1920 הוא 1080p
            label = f"{short_side}p"
            if any(o["label"] == label for o in options):
                continue
            spec, size = spec_for(best)
            options.append({"label": label, "rank": short_side, "format": spec, "size": size,
                            "note": QT_NOTE if needs_player_note(best) else "", "audio_only": False})
    elif video:
        # בלי מידע על רזולוציה (למשל פייסבוק): HD/SD לפי השם, או "איכות מקורית"
        for i, f in enumerate(sorted(video, key=lambda f: (f.get("tbr") or 0, size_of(f)), reverse=True)[:3]):
            fid = (f.get("format_id") or "").lower()
            label = fid.upper() if fid in ("hd", "sd") else ("איכות מקורית" if i == 0 else f"חלופה {i}")
            spec, size = spec_for(f)
            options.append({"label": label, "rank": -i, "format": spec, "size": size,
                            "note": "", "audio_only": False})

    with_sound = [f for f in video if f.get("acodec") != "none"]  # יש סרטונים שקטים לגמרי
    source = audio or (pick_video(with_sound) if with_sound else None)
    if source:
        duration = entry.get("duration") or 0
        options.append({"label": "אודיו בלבד (MP3)", "rank": -100, "format": source["format_id"],
                        "size": int(duration * 245_000 / 8),  # MP3 באיכות הכי גבוהה: בערך 245kbps
                        "note": "", "audio_only": True})
    return options


def describe(info: dict) -> dict:
    """סיכום לתצוגה + האיכויות. בפוסט עם כמה סרטונים, כל בחירה חלה על כולם."""
    if info.get("is_live"):
        raise EngineError("live", "זה שידור חי. אפשר להוריד אותו רק אחרי שהשידור מסתיים.")
    entries = [e for e in (info.get("entries") or []) if e] if info.get("_type") == "playlist" else [info]
    if len(entries) > MAX_ITEMS:
        raise EngineError("playlist", "זו רשימה של הרבה סרטונים. הדבק קישור לסרטון בודד.")
    per_entry = [entry_options(e) for e in entries]
    entries = [e for e, opts in zip(entries, per_entry) if opts]
    per_entry = [opts for opts in per_entry if opts]
    if not entries:
        raise EngineError("novideo", "לא מצאתי וידאו בקישור הזה. אולי זה פוסט של תמונה בלבד?")

    # רשימת האיכויות: כל מה שקיים לפחות באחד הסרטונים
    labels = []
    for opts in per_entry:
        for o in opts:
            if o["label"] not in [l["label"] for l in labels]:
                labels.append(o)
    labels.sort(key=lambda o: o["rank"], reverse=True)

    choices = []
    for wanted in labels:
        picks = []
        for opts in per_entry:
            same_kind = [o for o in opts if o["audio_only"] == wanted["audio_only"]] or opts
            exact = [o for o in same_kind if o["label"] == wanted["label"]]
            lower = [o for o in same_kind if o["rank"] <= wanted["rank"]]
            picks.append((exact or lower or [min(same_kind, key=lambda o: o["rank"])])[0])
        choices.append({
            "label": wanted["label"],
            "size": sum(p["size"] for p in picks),
            "note": QT_NOTE if any(p["note"] for p in picks) else "",
            "audio_only": wanted["audio_only"],
            "rank": wanted["rank"],
            "picks": [{"format": p["format"], "size": p["size"]} for p in picks],
        })

    # ברירת מחדל: האיכות הכי גבוהה שנפתחת בכל נגן (בדרך כלל 1080p)
    default = next((i for i, c in enumerate(choices) if not c["note"] and not c["audio_only"]), 0)
    # המקור לגרסת וואטסאפ: הכי טוב עד 720p (אין טעם להוריד 4K כדי לכווץ אותו)
    videos = [i for i, c in enumerate(choices) if not c["audio_only"]]
    compact = next((i for i in videos if 0 < choices[i]["rank"] <= 720 and not choices[i]["note"]),
                   videos[-1] if videos else default)
    thumb = info.get("thumbnail") or next((e.get("thumbnail") for e in entries if e.get("thumbnail")), None)
    return {
        "title": info.get("title") or entries[0].get("title") or "",
        "uploader": info.get("uploader") or info.get("channel") or entries[0].get("uploader") or "",
        "platform": platform_of(info),
        "thumbnail": thumb,
        "duration": sum(e.get("duration") or 0 for e in entries) or None,
        "items": len(entries),
        "choices": choices,
        "default": default,
        "compact": compact,
        "_entries": entries,
        "_cookies": info.get("_cookies"),
    }


# ---------- הורדה ----------

def save_state(summary: dict) -> str:
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    for old in STATE_DIR.glob("*.json"):  # ניקוי של מצבים ישנים
        if time.time() - old.stat().st_mtime > 7 * 86_400:
            old.unlink(missing_ok=True)
    fd, path = tempfile.mkstemp(suffix=".json", dir=STATE_DIR)
    with os.fdopen(fd, "w") as f:
        json.dump(summary, f)
    return path


def public(summary: dict) -> dict:
    """בלי השדות הפנימיים: מה שהאפליקציה צריכה לתצוגה."""
    out = {k: v for k, v in summary.items() if not k.startswith("_")}
    out["choices"] = [{k: v for k, v in c.items() if k != "picks"} for c in summary["choices"]]
    return out


def _num(value):
    try:
        return float(value)
    except (TypeError, ValueError):
        return None




WHATSAPP_TARGET = 15_500_000  # בייטים: נשלח מהר ונראה טוב בטלפון
WHATSAPP_AUDIO = 96_000


def whatsapp_plan(duration) -> tuple:
    """(קצב וידאו בביט לשנייה, הצלע הקצרה המקסימלית) כך שהקובץ ייצא בערך 15MB."""
    duration = max(duration or 0, 1)
    video = WHATSAPP_TARGET * 8 / duration - WHATSAPP_AUDIO
    video = int(min(max(video, 350_000), 2_000_000))
    return video, (720 if video >= 700_000 else 480)


def whatsapp_size(duration) -> int:
    video, _ = whatsapp_plan(duration)
    return int((video + WHATSAPP_AUDIO) * max(duration or 0, 1) / 8)


def clock(seconds) -> str:
    """לשם הקובץ: 1m05s (בלי נקודתיים, ש-Finder מציג כלוכסן)."""
    total = int(round(seconds))
    h, m, s = total // 3600, total % 3600 // 60, total % 60
    return f"{h}h{m:02d}m{s:02d}s" if h else f"{m}m{s:02d}s"


def output_name(summary: dict, choice: dict, index: int, opts: dict) -> str:
    style = opts.get("name_style") or "title_quality"
    name = "%(title).120B"
    if style == "uploader_title" and summary.get("uploader"):
        uploader = summary["uploader"].replace("%", "%%").replace("/", "-")[:60]
        name = f"{uploader} - %(title).100B"
    if len(summary["_entries"]) > 1:
        name += f" {index + 1}"
    tags = []
    if not choice["audio_only"]:
        if opts.get("whatsapp"):
            tags.append("WhatsApp")
        elif style != "title":
            tags.append(choice["label"])
    if opts.get("trim"):
        start, end = opts["trim"]
        tags.append(f"{clock(start)}-{clock(end)}")
    return name + (f" ({', '.join(tags)})" if tags else "") + ".%(ext)s"


def unique_path(path: Path) -> Path:
    n = 2
    candidate = path
    while candidate.exists():
        candidate = path.with_name(f"{path.stem} {n}{path.suffix}")
        n += 1
    return candidate


def probe_duration(path: Path) -> float:
    out = subprocess.run(["ffprobe", "-v", "error", "-show_entries", "format=duration",
                          "-of", "default=nw=1:nk=1", str(path)], capture_output=True, text=True).stdout
    return _num(out.strip()) or 0


def compress_for_whatsapp(src: Path, dst: Path):
    """מכווץ ל-H.264/AAC קטן. גנרטור של שברים 0..1. אם בוטל, לא נשאר קובץ חלקי ביעד."""
    duration = probe_duration(src)
    video, side = whatsapp_plan(duration)
    # לרוחב: גובה עד side; לאורך: רוחב עד side. תמיד מספר זוגי (ש-H.264 דורש)
    scale = (f"scale=w='if(gte(iw,ih),-2,trunc(min({side},iw)/2)*2)'"
             f":h='if(gte(iw,ih),trunc(min({side},ih)/2)*2,-2)'")
    partial = src.with_name("compressing.mp4")
    cmd = ["ffmpeg", "-hide_banner", "-nostdin", "-y", "-i", str(src), "-vf", scale, "-fpsmax", "30",
           "-c:v", "libx264", "-preset", "veryfast", "-pix_fmt", "yuv420p",
           "-b:v", str(video), "-maxrate", str(int(video * 1.4)), "-bufsize", str(video * 2),
           "-c:a", "aac", "-b:a", "96k", "-ac", "2", "-movflags", "+faststart",
           "-progress", "pipe:1", "-nostats", "-loglevel", "error", str(partial)]
    proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, bufsize=1)
    try:
        for line in proc.stdout:
            if line.startswith("out_time_us=") and duration:
                done = (_num(line.split("=", 1)[1]) or 0) / 1e6
                yield min(max(done / duration, 0), 0.99)
        proc.wait()
    finally:
        if proc.poll() is None:
            proc.terminate()
            proc.wait(timeout=10)
    if proc.returncode != 0:
        raise EngineError("generic", "הכיווץ לוואטסאפ נכשל.", proc.stderr.read()[-600:])
    shutil.move(str(partial), str(dst))


def download(summary: dict, choice_index: int, opts: dict | None = None):
    """גנרטור של אירועים: progress / stage / done. במקרה של כישלון זורק EngineError.

    opts: out_dir, by_platform, name_style, trim [start, end], whatsapp, sponsorblock
    """
    opts = opts or {}
    choice = summary["choices"][choice_index]
    entries = summary["_entries"]
    n = len(entries)
    whatsapp = bool(opts.get("whatsapp")) and not choice["audio_only"]
    trim = opts.get("trim") if n == 1 else None
    out_dir = Path(opts.get("out_dir") or DOWNLOAD_DIR).expanduser()
    if opts.get("by_platform"):
        out_dir /= (summary.get("platform") or "אחר").replace("/", "-")
    out_dir.mkdir(parents=True, exist_ok=True)
    tmp = Path(tempfile.mkdtemp(prefix="ytdl-"))
    # בוואטסאפ ההורדה היא רק חצי מהעבודה; החצי השני הוא הכיווץ
    span = 0.5 if whatsapp else 1.0
    saved = []
    try:
        for i, (entry, pick) in enumerate(zip(entries, choice["picks"])):
            entry_file = tmp / f"entry{i}.json"
            entry_file.write_text(json.dumps(entry))
            home = tmp / "ready" if whatsapp else out_dir
            cmd = [
                "yt-dlp", "--load-info-json", str(entry_file), "-f", pick["format"],
                "--no-warnings", "--no-mtime", "--newline", "--progress",  # --no-mtime: שיופיע כחדש בתיקייה
                "-P", str(home), "-P", f"temp:{tmp / 'parts'}", "-o", output_name(summary, choice, i, opts),
                "--progress-template", "download:@@P %(progress.downloaded_bytes)s %(progress.total_bytes)s "
                                       "%(progress.total_bytes_estimate)s %(progress.speed)s %(progress.eta)s "
                                       "%(info.format_id)s",
                "--print", "post_process:@@M", "--print", "after_move:@@F %(filepath)s",
                "--embed-metadata",
            ]
            if choice["audio_only"]:
                cmd += ["-x", "--audio-format", "mp3", "--audio-quality", "0", "--embed-thumbnail"]
            else:
                cmd += ["--merge-output-format", "mp4"]
            if trim:
                cmd += ["--download-sections", f"*{trim[0]}-{trim[1]}", "--force-keyframes-at-cuts"]
            elif opts.get("sponsorblock") and summary.get("platform") == "YouTube":
                cmd += ["--sponsorblock-remove", "sponsor,selfpromo,interaction"]
            if summary.get("_cookies"):
                cmd += ["--cookies-from-browser", summary["_cookies"]]

            if trim:  # הורדת קטע עוברת דרך ffmpeg ולא מדווחת התקדמות בדרך
                yield {"type": "stage", "stage": "trimming", "item": i + 1, "items": n}
            proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, bufsize=1)
            parts, log, files = {}, [], []
            try:
                for line in proc.stdout:
                    line = line.rstrip("\n")
                    if line.startswith("@@P ") and not trim:
                        done_b, total, estimate, speed, eta, fid = (line[4:].split(" ") + [""] * 6)[:6]
                        parts[fid] = (_num(done_b) or 0, _num(total) or _num(estimate) or 0)
                        totals = [t for _, t in parts.values()]
                        all_parts_known = len(parts) == pick["format"].count("+") + 1 and all(totals)
                        # הגודל שהאתר מדווח מראש לא תמיד נכון (ב-X הוא מנופח), אז ברגע שכל החלקים
                        # בהורדה, סומכים על הגודל האמיתי שלהם
                        expected = sum(totals) if all_parts_known else max(pick["size"], sum(totals))
                        got = sum(d for d, _ in parts.values())
                        fraction = min(got / expected, 0.99) if expected else 0
                        yield {"type": "progress", "item": i + 1, "items": n,
                               "fraction": (i + fraction * span) / n,
                               "speed": _num(speed), "eta": _num(eta)}
                    elif line == "@@M" and not trim:
                        yield {"type": "stage", "stage": "processing", "audio_only": choice["audio_only"],
                               "merge": "+" in pick["format"], "item": i + 1, "items": n}
                    elif line.startswith("@@F "):
                        files.append(line[4:])
                    else:
                        log.append(line)
                proc.wait()
            finally:
                if proc.poll() is None:
                    proc.terminate()
                    proc.wait(timeout=10)
            if proc.returncode != 0:
                raise classify("\n".join(log))

            if whatsapp:
                for f in files:
                    src = Path(f)
                    dst = unique_path(out_dir / src.name)
                    for fraction in compress_for_whatsapp(src, dst):
                        yield {"type": "progress", "stage": "compress", "item": i + 1, "items": n,
                               "fraction": (i + span + fraction * (1 - span)) / n, "speed": None, "eta": None}
                    saved.append(str(dst))
            else:
                saved.extend(files)
        yield {"type": "done", "paths": saved, "folder": str(out_dir)}
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def update_ytdlp() -> tuple:
    brew = shutil.which("brew")
    if not brew:
        return False, "Homebrew לא נמצא."
    result = subprocess.run([brew, "upgrade", "yt-dlp"], capture_output=True, text=True)
    version = subprocess.run(["yt-dlp", "--version"], capture_output=True, text=True).stdout.strip()
    return result.returncode == 0, version or result.stderr.strip()[-300:]


# ---------- ממשק שורת פקודה בשביל האפליקציה ----------

def _emit(obj: dict) -> None:
    print(json.dumps(obj, ensure_ascii=False), flush=True)


def _cli(argv: list) -> int:
    # כשהאפליקציה מבטלת הורדה היא שולחת SIGTERM: מנקים קבצים זמניים ויוצאים
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(143))
    missing = missing_tools()
    if missing:
        _emit({"ok": False, "type": "error", "kind": "tools",
               "message": "חסרים כלים: " + ", ".join(missing) + ". התקנה: brew install " + " ".join(missing)})
        return 1
    cmd = argv[0] if argv else ""
    try:
        if cmd == "info":
            cookies = argv[argv.index("--cookies") + 1] if "--cookies" in argv else None
            summary = describe(fetch(argv[1], cookies))
            _emit({"ok": True, "state": save_state(summary), **public(summary)})
        elif cmd == "download":
            summary = json.loads(Path(argv[1]).read_text())
            opts = json.loads(argv[3]) if len(argv) > 3 else {}
            for event in download(summary, int(argv[2]), opts):
                _emit(event)
        elif cmd == "update":
            ok, info = update_ytdlp()
            _emit({"ok": ok, "version": info})
        else:
            print(__doc__)
            return 2
    except EngineError as e:
        _emit({"ok": False, "type": "error", **e.as_dict()})
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(_cli(sys.argv[1:]))
