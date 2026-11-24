# Third-party software

Barak ⚡ Downloader does not ship these tools inside the app. On first launch it downloads them, verifies their SHA-256 checksums, and stores them in `~/Library/Application Support/Barak Downloader/tools/`.

| Tool | Used for | License | Source |
|---|---|---|---|
| [yt-dlp](https://github.com/yt-dlp/yt-dlp) | Reading video pages and downloading | The Unlicense (public domain); the macOS build bundles Python and other components under their own licenses | Official GitHub releases (`yt-dlp_macos.zip`), checked against `SHA2-256SUMS` |
| [Deno](https://github.com/denoland/deno) | JavaScript runtime that yt-dlp needs for YouTube | MIT | Official GitHub releases, checked against the published `.sha256sum` |
| [FFmpeg](https://ffmpeg.org) | Merging video and audio, trimming, compressing, MP3 | LGPL-2.1-or-later (built without GPL components) | Built from the official source by [`scripts/build-ffmpeg.sh`](scripts/build-ffmpeg.sh) and published in this repo's `tools-ffmpeg-*` releases, together with the license and the exact build configuration |
| [LAME](https://lame.sourceforge.io) | MP3 encoding (linked into FFmpeg) | LGPL | Built from the official source by the same script |

The app's own code is under the MIT license (see [LICENSE](LICENSE)).
