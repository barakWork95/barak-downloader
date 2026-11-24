#!/usr/bin/env python3
"""הורדת סרטון (יוטיוב, אינסטגרם, טיקטוק, פייסבוק, X ועוד) לתיקיית ההורדות, עם בחירת איכות.

שימוש:
    ytdl                 # מבקש קישור
    ytdl <קישור>         # מדלג על השאלה הראשונה

דורש: yt-dlp ו-ffmpeg (brew install yt-dlp ffmpeg)
"""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))  # עובד גם דרך הקיצור ~/.local/bin/ytdl
import engine  # noqa: E402


def fail(msg: str) -> None:
    print(f"\n✖ {msg}")
    sys.exit(1)


def mb(size) -> str:
    return f"~{size / 1_000_000:,.0f} MB" if size else ""


def ask_yes(question: str) -> bool:
    return input(f"{question} (כ/ל): ").strip().lower() in ("כ", "כן", "y", "yes")


def fetch_summary(url: str) -> dict:
    print("בודק את הקישור...")
    try:
        return engine.describe(engine.fetch(url))
    except engine.EngineError as e:
        if e.kind != "login":
            print(e.detail) if e.detail else None
            fail(e.message)
        print(f"\n{e.message}")
        if not ask_yes("לנסות עם ההתחברות שלך בכרום? (מק יבקש אישור גישה ל-Keychain)"):
            sys.exit(1)
        try:
            return engine.describe(engine.fetch(url, cookies="chrome"))
        except engine.EngineError as e2:
            fail(e2.message)


def ask_quality(summary: dict) -> int:
    choices, default = summary["choices"], summary["default"] + 1
    print("\nבאיזו איכות להוריד?")
    for i, c in enumerate(choices, 1):
        mark = "  ← ברירת מחדל" if i == default else ""
        print(f"  {i}) {c['label']:<8} {mb(c['size']):<11} {c['note']}{mark}")
    while True:
        answer = input(f"מספר (1-{len(choices)}, Enter = {default}): ").strip() or str(default)
        if answer.isdigit() and 1 <= int(answer) <= len(choices):
            return int(answer) - 1
        print("מספר לא תקין, נסה שוב.")


def bar(fraction: float, width: int = 30) -> str:
    filled = int(fraction * width)
    return "█" * filled + "░" * (width - filled)


def main() -> None:
    missing = engine.missing_tools()
    if missing:
        fail(f"חסר {', '.join(missing)}. התקנה: brew install {' '.join(missing)}")
    url = sys.argv[1] if len(sys.argv) > 1 else input("הדבק קישור לסרטון: ")
    if not url.strip():
        fail("לא הודבק קישור.")
    summary = fetch_summary(url)

    print(f"\n🎬 {summary['title']}")
    details = [summary["platform"], summary["uploader"]]
    if summary["items"] > 1:
        details.append(f"{summary['items']} סרטונים בפוסט, כולם יורדו")
    print("   " + " · ".join(d for d in details if d))
    index = ask_quality(summary)

    print(f"\nמוריד {summary['choices'][index]['label']}...")
    try:
        for event in engine.download(summary, index):
            if event["type"] == "progress":
                speed = f"{event['speed'] / 1_000_000:.1f} MB/s" if event["speed"] else ""
                item = f"  ({event['item']}/{event['items']})" if event["items"] > 1 else ""
                print(f"\r  {bar(event['fraction'])} {event['fraction'] * 100:3.0f}%  {speed:<10}{item}",
                      end="", flush=True)
            elif event["type"] == "stage":
                label = ("ממיר ל-MP3..." if event["audio_only"] else
                         "מחבר וידאו ואודיו..." if event["merge"] else "מסיים...")
                print(f"\r  {bar(1)} 100%  {label:<20}", end="", flush=True)
            elif event["type"] == "done":
                print()
                for path in event["paths"]:
                    print(f"\n✔ נשמר: {path}")
    except engine.EngineError as e:
        print()
        fail(e.message)


if __name__ == "__main__":
    try:
        main()
    except (KeyboardInterrupt, EOFError):
        print("\nבוטל.")
        sys.exit(130)
