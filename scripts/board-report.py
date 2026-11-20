#!/usr/bin/env python3
"""Turn a board-test.sh result folder into one self-contained index.html.

    scripts/board-report.py board-test-<host>-<time>/

Also checks the ToF frames (tof.jsonl) and adds motion.json / build.json.
Exits 1 if any test failed. Standard library only.
"""
import base64
import html
import json
import struct
import sys
import xml.etree.ElementTree as ET
import zlib
from pathlib import Path


def uyvy_to_rgb(data: bytes, width: int, height: int) -> bytes:
    """BT.601, limited range."""
    out = bytearray()
    for i in range(0, width * height * 2, 4):
        u, y0, v, y1 = data[i] - 128, data[i + 1], data[i + 2] - 128, data[i + 3]
        for y in (y0, y1):
            c = 298 * (y - 16) + 128
            for value in ((c + 409 * v) >> 8, (c - 100 * u - 208 * v) >> 8, (c + 516 * u) >> 8):
                out.append(min(255, max(0, value)))
    return bytes(out)


def png(rgb: bytes, width: int, height: int) -> bytes:
    def chunk(kind: bytes, body: bytes) -> bytes:
        return struct.pack(">I", len(body)) + kind + body + struct.pack(">I", zlib.crc32(kind + body))

    stride = width * 3
    rows = b"".join(b"\0" + rgb[r * stride:(r + 1) * stride] for r in range(height))
    return (b"\x89PNG\r\n\x1a\n"
            + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(rows, 6))
            + chunk(b"IEND", b""))


# Black, white, red: catches swapped U/V or byte order.
assert uyvy_to_rgb(bytes([128, 16, 128, 235]), 2, 1) == bytes([0, 0, 0, 255, 255, 255])
_r, _g, _b = uyvy_to_rgb(bytes([90, 82, 240, 82]), 2, 1)[:3]
assert _r > 250 and _g < 5 and _b < 5, (_r, _g, _b)

TOF_VALID = (5, 9)  # ST's valid target statuses
TOF_MIN_FRAMES = 3
TOF_MIN_VALID = 16  # of 64; ~55 measured looking at a floor
TOF_RANGE_MM = 2000  # fixed colour scale, so reports compare


def turbo(t: float) -> str:
    """Google's Turbo colormap (polynomial fit), t in 0..1."""
    t = min(max(t, 0.0), 1.0)
    channels = (
        (0.13572138, 4.61539260, -42.66032258, 132.13108234, -152.94239396, 59.28637943),
        (0.09140261, 2.19418839, 4.84296658, -14.18503333, 4.27729857, 2.82956604),
        (0.10667330, 12.64194608, -60.58204836, 110.36276771, -89.90310912, 27.34824973),
    )
    rgb = []
    for c in channels:
        v = 0.0
        for k in reversed(c):
            v = v * t + k
        rgb.append(round(255 * min(max(v, 0.0), 1.0)))
    return f"rgb({rgb[0]},{rgb[1]},{rgb[2]})"


assert turbo(0.0) == "rgb(35,23,27)" and turbo(1.0) == "rgb(144,13,0)", (turbo(0.0), turbo(1.0))


def depth_colour(mm: int) -> str:
    """Near red, far blue; Turbo's near-black ends are left out."""
    return turbo(0.1 + 0.85 * (1 - min(max(mm, 0), TOF_RANGE_MM) / TOF_RANGE_MM))


def tof(path: Path) -> tuple[str, str, str]:
    """The ToF check's status and output, and the last frame as a heatmap."""
    frames = []
    if path.exists():
        for line in path.read_text().splitlines():
            try:
                message = json.loads(line)
            except ValueError:
                continue
            if message.get("method") == "tof.frame":
                frames.append(message["params"])
    if not frames:
        return "FAIL", "no frame from tofd's stream", ""
    last = frames[-1]
    rows, cols = last["rows"], last["cols"]
    valid = sum(s in TOF_VALID for s in last["status"])
    status = "PASS" if len(frames) >= TOF_MIN_FRAMES and valid >= TOF_MIN_VALID else "FAIL"
    output = f"tof: {len(frames)} frames in ~4 s, last {rows}x{cols} with {valid} valid zones"

    cells = []  # solid blocks: invalid zones have no depth to interpolate
    for i, (mm, st) in enumerate(zip(last["distance_mm"], last["status"], strict=True)):
        tip = f"row {i // cols}, col {i % cols}: {mm} mm, status {st}"
        if st in TOF_VALID:
            cells.append(f'<div style="background:{depth_colour(mm)}" title="{tip}"></div>')
        else:
            cells.append(f'<div class="invalid" title="{tip} (not a valid target)"></div>')
    stops = ", ".join(depth_colour(TOF_RANGE_MM * k / 10) for k in range(11))
    grid = (f'<h2>Head ToF</h2><p class="sub">Depth map, last of {len(frames)} frames. Row 0 is the top, '
            f'column 0 the sensor\'s left. Hatched: not a valid target. Hover a zone for its distance.</p>'
            f'<div class="tof" style="grid-template-columns: repeat({cols}, 1fr)">{"".join(cells)}</div>'
            f'<div class="tofbar" style="background: linear-gradient(to right, {stops})"></div>'
            f'<div class="tofscale"><span>0 m</span><span>{TOF_RANGE_MM / 2000:g} m</span>'
            f'<span>{TOF_RANGE_MM / 1000:g} m and farther</span></div>')
    return status, output, grid


STYLE = """
body { font: 15px/1.45 system-ui, sans-serif; margin: 2rem auto; max-width: 1100px; padding: 0 1rem; color: #1d1d1f; }
h1 { margin-bottom: .2rem; } .sub { color: #666; margin-top: 0; }
.summary span { display: inline-block; padding: .3rem .8rem; border-radius: 6px; margin-right: .5rem; font-weight: 600; }
.PASS { background: #e3f5e8; color: #17692f; } .FAIL { background: #fde7e7; color: #a11a1a; } .SKIP { background: #fff4d6; color: #7a5a00; }
table { border-collapse: collapse; width: 100%; margin: 1rem 0 2rem; }
th, td { text-align: left; padding: .45rem .6rem; border-bottom: 1px solid #e5e5e5; vertical-align: top; }
th { background: #f6f6f6; font-weight: 600; }
td.status span { padding: .1rem .5rem; border-radius: 4px; font-weight: 600; font-size: .85em; }
code, pre { font: 13px ui-monospace, monospace; } pre { background: #f6f6f6; padding: .8rem; overflow-x: auto; }
img { max-width: 100%; border: 1px solid #ddd; } audio { width: 100%; }
.tof { display: grid; width: 384px; aspect-ratio: 1; border: 1px solid #ddd; }
.tof .invalid { background: repeating-linear-gradient(45deg, #ccc 0 4px, #eee 4px 8px); }
.tofbar { width: 384px; height: 14px; margin-top: .6rem; border: 1px solid #ddd; }
.tofscale { width: 384px; display: flex; justify-content: space-between; font-size: .85em; color: #666; }
"""


def main() -> int:
    folder = Path(sys.argv[1])
    if not (folder / "report.xml").exists():
        print(f"cukinia wrote no report in {folder}: see the run's output above")
        return 1
    root = ET.parse(folder / "report.xml").getroot()

    rows, counts = [], {"PASS": 0, "FAIL": 0, "SKIP": 0}

    def add(suite: str, name: str, status: str, output: str) -> None:
        counts[status] += 1
        print(f"[{status}] {name}")
        rows.append(f'<tr><td>{html.escape(suite)}</td><td>{html.escape(name)}</td>'
                    f'<td class="status"><span class="{status}">{status}</span></td>'
                    f'<td><code>{html.escape(output.strip())}</code></td></tr>')

    for suite in root.iter("testsuite"):
        for case in suite.iter("testcase"):
            status = "FAIL" if case.find("failure") is not None else \
                "SKIP" if case.find("skipped") is not None else "PASS"
            output = " ".join(e.text or "" for e in (case.find("system-out"), case.find("system-err")) if e is not None)
            add(suite.get("name", ""), case.get("name", ""), status, output)

    tof_grid = ""  # only a board runs the hardware suite
    if any(s.get("name") == "hardware" for s in root.iter("testsuite")):
        status, output, tof_grid = tof(folder / "tof.jsonl")
        add("hardware", "Head ToF gives live frames now", status, output)

    for name, suite in (("motion.json", "motion"), ("build.json", "build")):
        if (folder / name).exists():
            for step in json.loads((folder / name).read_text()):
                add(suite, step["name"], step["status"], step["output"])

    def text(name: str) -> str:
        path = folder / name
        return path.read_text(errors="replace") if path.exists() else "(not collected)"

    board = text("board.txt")
    media = []
    if (folder / "frame.uyvy").exists():
        meta = json.loads((folder / "frame.json").read_text())
        w, h = meta["width"], meta["height"]
        # shortcut: a rotated frame is shown unrotated; rotate here if mediad ever reports one.
        image = png(uyvy_to_rgb((folder / "frame.uyvy").read_bytes(), w, h), w, h)
        (folder / "frame.png").write_bytes(image)
        media.append(f'<h2>Camera frame</h2><p class="sub">{w}x{h} {html.escape(meta.get("format", ""))}, '
                     f'as mediad delivered it.</p>'
                     f'<img alt="camera frame" src="data:image/png;base64,{base64.b64encode(image).decode()}">')
    if (folder / "mic.wav").exists():
        wav = base64.b64encode((folder / "mic.wav").read_bytes()).decode()
        media.append('<h2>Mic recording</h2><p class="sub">The face mic during the speaker test: '
                     'silence, then about 2 s of a 500 Hz tone, then silence. Stereo, 16 kHz.</p>'
                     f'<audio controls src="data:audio/wav;base64,{wav}"></audio>')
    media.append(tof_grid)

    failed_units = text("failed-units.txt").strip() if (folder / "failed-units.txt").exists() else ""
    failed = (f'<h2>Failed units</h2><p class="sub">The last journal lines of each.</p>'
              f'<pre>{html.escape(failed_units)}</pre>') if failed_units else ""

    page = f"""<!doctype html>
<html lang="en"><head><meta charset="utf-8"><title>microduck board test: {html.escape(folder.name)}</title>
<style>{STYLE}</style></head><body>
<h1>microduck board test</h1>
<p class="sub">{html.escape(folder.name)}</p>
<pre>{html.escape(board.strip())}</pre>
<p class="summary"><span class="PASS">{counts["PASS"]} passed</span><span class="FAIL">{counts["FAIL"]} failed</span><span class="SKIP">{counts["SKIP"]} skipped</span></p>
<table><tr><th>Suite</th><th>Test</th><th>Result</th><th>Output</th></tr>
{"".join(rows)}
</table>
{"".join(media)}
{failed}
<h2>robotctl health</h2>
<pre>{html.escape(text("health.txt").strip())}</pre>
</body></html>
"""
    (folder / "index.html").write_text(page)
    print(f"{counts['PASS']} passed, {counts['FAIL']} failed, {counts['SKIP']} skipped")
    print(f"report: {(folder / 'index.html').resolve()}")
    return 1 if counts["FAIL"] else 0


if __name__ == "__main__":
    sys.exit(main())
