#!/usr/bin/env python3
"""Writes docs/brand/brand-manual.html plus the SVG assets and brand-tokens.css.
Geometry mirrors Sources/Whopper/Shell/Brand.swift (LogoMark) and MenuBarIcon.swift. Run from anywhere."""
import pathlib, textwrap

ROOT = pathlib.Path(__file__).resolve().parents[2]
OUT = ROOT / "docs" / "brand"
(OUT / "assets").mkdir(parents=True, exist_ok=True)

C = dict(violet="#5B2BD8", bright="#7C4DFF", deep="#221060", bun="#FFC857", seed="#FFF0B8", patty="#FF4F81",
         red="#FF3B4A", green="#2EE66B", blue="#4DA3FF", ink="#1D1B19", paper="#F4F2EE",
         good="#1FB955", warn="#E08A00", accent_dark="#A98BFF", good_text="#0F7D37")
RGB = [C["red"], C["green"], C["blue"]]

def lum(h):
    r, g, b = [int(h[i:i+2], 16) / 255 for i in (1, 3, 5)]
    f = lambda c: c / 12.92 if c <= .03928 else ((c + .055) / 1.055) ** 2.4
    return .2126 * f(r) + .7152 * f(g) + .0722 * f(b)
def contrast(a, b):
    la, lb = sorted([lum(a), lum(b)], reverse=True)
    return (la + .05) / (lb + .05)

# ---------------- artwork ----------------
SEEDS = [(28, 33, -25), (39, 26.5, -12), (50, 24, 0), (61, 26.5, 12), (72, 33, 25), (33, 38.5, -8), (44, 35, -4), (56, 35, 4), (67, 38.5, 8)]
BARS = [4, 7, 10, 7, 12, 8, 11, 13, 11, 8, 12, 7, 10, 7, 4]
_n = [0]

def burger(scale, small=False):
    seeds = "" if small else "".join(f'<ellipse cx="{x}" cy="{y}" rx="3.2" ry="1.7" transform="rotate({r} {x} {y})" fill="{C["seed"]}"/>' for x, y, r in SEEDS)
    w = 4.8; pitch = (76 - w) / 11
    cols = "".join(f'<rect x="{12 + i*pitch:.2f}" y="46" width="{w}" height="9" rx="1.6" fill="{RGB[i%3]}"/>' for i in range(12))
    bars = "".join(f'<rect x="{13.2 + i*5:.2f}" y="{64 - h/2:.2f}" width="3.6" height="{h}" rx="1.8" fill="{C["patty"]}"/>' for i, h in enumerate(BARS))
    return (f'<g transform="translate(50 50) scale({scale}) translate(-50 -50)">'
            f'<path d="M12 43C12 27 28 17 50 17s38 10 38 26z" fill="{C["bun"]}"/>{seeds}{cols}{bars}'
            f'<path d="M14 74h72v2c0 5-4 7-9 7H23c-5 0-9-2-9-7z" fill="{C["bun"]}"/></g>')

def icon(size, plate=True, scale=1.105):
    _n[0] += 1; i = _n[0]
    bg = (f'<defs><linearGradient id="ig{i}" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="{C["violet"]}"/>'
          f'<stop offset="1" stop-color="{C["deep"]}"/></linearGradient></defs><rect width="100" height="100" rx="22.5" fill="url(#ig{i})"/>') if plate else ""
    return f'<svg width="{size}" height="{size}" viewBox="0 0 100 100" role="img" aria-label="Whoprrr">{bg}{burger(scale if plate else 1.31, small=size<40)}</svg>'

def glyph_paths(color="currentColor"):
    bars = [2, 3.5, 5, 3.2, 5.6, 3.2, 5, 3.5, 2]
    x0 = (24 - (8 * 2.2 + 1.6)) / 2
    dashes = "".join(f'<rect x="{2.6 + i*3.24:.2f}" y="10.15" width="2.6" height="1.5" rx=".5"/>' for i in range(6))
    b = "".join(f'<rect x="{x0 + i*2.2:.2f}" y="{15.4 - h/2:.2f}" width="1.6" height="{h}" rx=".8"/>' for i, h in enumerate(bars))
    return (f'<path d="M1.8 9.2C1.8 5 6 2.8 12 2.8s10.2 2.2 10.2 6.4z"/>{dashes}{b}'
            f'<rect x="2.6" y="19.5" width="18.8" height="2.3" rx="1.15"/>')

def glyph(size, cls="g"):
    return f'<svg class="{cls}" width="{size}" height="{size}" viewBox="0 0 24 24" fill="currentColor" role="img" aria-label="Whoprrr menu-bar glyph">{glyph_paths()}</svg>'

# ---------------- standalone assets ----------------
def standalone_icon():
    return icon(1024).replace('<svg ', '<svg xmlns="http://www.w3.org/2000/svg" ', 1)
(OUT / "assets" / "whoprrr-icon.svg").write_text(standalone_icon())
(OUT / "assets" / "whoprrr-logo.svg").write_text(icon(512, plate=False).replace('<svg ', '<svg xmlns="http://www.w3.org/2000/svg" ', 1))
(OUT / "assets" / "whoprrr-glyph.svg").write_text(
    f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="#000">{glyph_paths()}</svg>')
(OUT / "brand-tokens.css").write_text(textwrap.dedent(f"""\
    /* Whoprrr brand tokens. Mirrors Sources/Whopper/Shell/Brand.swift. */
    :root {{
      --whoprrr-violet: {C['violet']};
      --whoprrr-violet-bright: {C['bright']};
      --whoprrr-violet-deep: {C['deep']};
      --whoprrr-bun: {C['bun']};
      --whoprrr-seed: {C['seed']};
      --whoprrr-patty: {C['patty']};
      --whoprrr-signal-red: {C['red']};
      --whoprrr-signal-green: {C['green']};
      --whoprrr-signal-blue: {C['blue']};
      --whoprrr-good: {C['good']};
      --whoprrr-accent-on-dark: {C['accent_dark']};
      --whoprrr-warn: {C['warn']};
      --whoprrr-ink: {C['ink']};
      --whoprrr-paper: {C['paper']};
      --whoprrr-font-display: ui-rounded, "SF Pro Rounded", system-ui, sans-serif;
      --whoprrr-font-text: -apple-system, "SF Pro Text", system-ui, sans-serif;
      --whoprrr-font-mono: ui-monospace, "SF Mono", Menlo, monospace;
    }}
    """))

# ---------------- manual ----------------
def swatch(name, hexv, role, text="#fff"):
    return (f'<div class="sw"><div class="chip" style="background:{hexv};color:{text}"><b>{name}</b></div>'
            f'<div class="meta"><code>{hexv}</code><span>{role}</span></div></div>')

def con_row(fg, bg, label):
    r = contrast(fg, bg)
    grade = "AAA" if r >= 7 else "AA" if r >= 4.5 else "AA large" if r >= 3 else "fails"
    return (f'<tr><td><span class="pair" style="background:{bg};color:{fg}">Aa</span></td><td>{label}</td>'
            f'<td><code>{fg} on {bg}</code></td><td>{r:.1f}:1</td><td><span class="grade {"ok" if r>=4.5 else "mid" if r>=3 else "bad"}">{grade}</span></td></tr>')

dont_cases = [
    ("Stretched", f'<div style="transform:scaleX(1.35)">{icon(84)}</div>'),
    ("Recoloured RGB", icon(84).replace(C["red"], "#999").replace(C["green"], "#888").replace(C["blue"], "#777")),
    ("Outlined", f'<div style="outline:3px solid #000;border-radius:20px">{icon(84)}</div>'),
    ("Rotated", f'<div style="transform:rotate(-14deg)">{icon(84)}</div>'),
]

HTML = f'''<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>Whoprrr brand manual</title>
<style>
:root{{--bg:{C["paper"]};--card:#fff;--ink:{C["ink"]};--mute:#6c675f;--line:#e4dfd6;--violet:{C["violet"]};--bright:{C["bright"]};--deep:{C["deep"]};--accent:{C["violet"]};--good-t:#0f7d37;--bad-t:#d0222f;--warn-t:#9a5b00}}
@media (prefers-color-scheme: dark){{:root{{--bg:#141311;--card:#1d1b19;--ink:#f3efe8;--mute:#a39d92;--line:#2d2a26;--accent:#a98bff;--good-t:#4ade80;--bad-t:#ff7a84;--warn-t:#f2b450}}}}
*{{box-sizing:border-box}}
html{{scroll-behavior:smooth}}
body{{margin:0;background:var(--bg);color:var(--ink);font:16px/1.6 -apple-system,"SF Pro Text",system-ui,sans-serif}}
.wrap{{max-width:1040px;margin:0 auto;padding:0 20px 80px}}
header.cover{{background:linear-gradient(135deg,{C["violet"]},{C["deep"]});color:#fff;padding:56px 20px 64px}}
header.cover .in{{max-width:1040px;margin:0 auto;display:flex;gap:40px;align-items:center;flex-wrap:wrap}}
header.cover svg{{filter:drop-shadow(0 18px 30px rgba(0,0,0,.4))}}
.cover h1{{font:800 64px/1 ui-rounded,"SF Pro Rounded",system-ui,sans-serif;letter-spacing:-.04em;margin:0 0 10px}}
.cover h1 i{{font-style:normal;color:#B9A2FF;text-shadow:4px 0 0 rgba(255,59,74,.55),-4px 0 0 rgba(77,163,255,.6)}}
.cover p{{margin:0;font-size:20px;opacity:.9;max-width:34ch}}
.cover small{{display:block;margin-top:16px;opacity:.88;font:500 12px ui-monospace,Menlo,monospace;letter-spacing:.06em;text-transform:uppercase}}
nav{{position:sticky;top:0;z-index:5;background:color-mix(in srgb,var(--bg) 88%,transparent);backdrop-filter:blur(10px);border-bottom:1px solid var(--line)}}
nav .in{{max-width:1040px;margin:0 auto;padding:10px 20px;display:flex;gap:6px;overflow-x:auto}}
nav a{{white-space:nowrap;text-decoration:none;color:var(--mute);font:600 13px ui-rounded,system-ui;padding:5px 11px;border-radius:99px}}
nav a:hover{{background:color-mix(in srgb,var(--violet) 14%,transparent);color:var(--accent)}}
section{{padding-top:56px}}
.k{{font:600 12px ui-monospace,Menlo,monospace;letter-spacing:.1em;text-transform:uppercase;color:var(--accent)}}
h2{{font:800 34px/1.1 ui-rounded,"SF Pro Rounded",system-ui,sans-serif;letter-spacing:-.025em;margin:6px 0 14px}}
h3{{font:700 18px/1.3 ui-rounded,system-ui,sans-serif;margin:26px 0 8px}}
p{{margin:0 0 12px;max-width:68ch}}
.mute{{color:var(--mute)}}
.grid{{display:grid;gap:14px}}
.g2{{grid-template-columns:repeat(auto-fit,minmax(300px,1fr))}}
.g3{{grid-template-columns:repeat(auto-fit,minmax(210px,1fr))}}
.g4{{grid-template-columns:repeat(auto-fit,minmax(160px,1fr))}}
.card{{background:var(--card);border:1px solid var(--line);border-radius:18px;padding:20px}}
.card h3{{margin:0 0 6px;font:700 15px ui-rounded,system-ui}}
.stage{{display:flex;align-items:center;justify-content:center;gap:18px;flex-wrap:wrap;padding:26px;border-radius:14px;background:color-mix(in srgb,var(--ink) 5%,transparent)}}
.stage.dark{{background:#141311;color:#fff}}
.bar{{display:inline-flex;align-items:center;gap:14px;padding:8px 14px;border-radius:9px}}
.bar.l{{background:#e9e9ed;color:#1d1d1f}}.bar.d{{background:#2b2b30;color:#fff}}
.sw{{background:var(--card);border:1px solid var(--line);border-radius:14px;overflow:hidden}}
.sw .chip{{height:84px;padding:12px;display:flex;align-items:flex-end;font:600 14px ui-rounded,system-ui}}
.sw .meta{{padding:10px 12px;display:flex;flex-direction:column;gap:2px;font-size:13px;color:var(--mute)}}
code{{font:12.5px ui-monospace,"SF Mono",Menlo,monospace;background:color-mix(in srgb,var(--ink) 7%,transparent);padding:1px 6px;border-radius:5px}}
table{{width:100%;border-collapse:collapse;font-size:14px}}
td,th{{text-align:left;padding:9px 10px;border-bottom:1px solid var(--line);vertical-align:middle}}
th{{font:600 11px ui-monospace,Menlo,monospace;text-transform:uppercase;letter-spacing:.08em;color:var(--mute)}}
.pair{{display:inline-block;width:42px;text-align:center;border-radius:8px;padding:3px 0;font:700 15px ui-rounded}}
.grade{{font:600 11px ui-monospace,Menlo,monospace;padding:2px 7px;border-radius:99px}}
.grade.ok{{background:#1fb95526;color:var(--good-t)}}.grade.mid{{background:#e08a0026;color:var(--warn-t)}}.grade.bad{{background:#ff3b4a26;color:var(--bad-t)}}
.bandrow{{display:flex;height:22px;border-radius:99px;overflow:hidden;margin:10px 0 4px}}
.anat{{display:grid;grid-template-columns:minmax(220px,300px) 1fr;gap:28px;align-items:center}}
@media(max-width:640px){{.anat{{grid-template-columns:1fr}}}}
.anat ol{{margin:0;padding-left:20px}}.anat li{{margin:8px 0}}
.mock{{width:100%;max-width:400px;margin:0 auto;border-radius:16px;background:var(--card);border:1px solid var(--line);box-shadow:0 16px 40px rgba(0,0,0,.15);overflow:hidden;font-size:13px}}
.m-head{{display:flex;gap:10px;align-items:center;padding:12px 14px 8px}}
.m-head .w{{font:800 19px ui-rounded,system-ui;letter-spacing:-.03em}}.m-head .w i{{font-style:normal;color:var(--accent);text-shadow:1.4px 0 0 rgba(255,59,74,.55),-1.4px 0 0 rgba(77,163,255,.6)}}
.m-head small{{display:block;color:var(--mute);font:500 10.5px ui-rounded,system-ui;margin-top:-2px}}
.chipx{{margin-left:auto;display:inline-flex;gap:5px;align-items:center;padding:3px 8px;border-radius:99px;background:#1fb95520;color:var(--good-t);font:500 11px ui-rounded}}
.chipx:before{{content:"";width:6px;height:6px;border-radius:50%;background:{C["good"]}}}
.m-nav{{display:flex;gap:4px;padding:0 10px 8px;align-items:center}}
.m-nav span{{height:28px;min-width:28px;border-radius:99px;display:inline-flex;align-items:center;justify-content:center;color:var(--mute);font-size:13px;padding:0 8px}}
.m-nav span.on{{background:{C["violet"]};color:#fff;font:600 11.5px ui-rounded;gap:5px;padding:0 11px}}
.m-body{{padding:12px 14px 14px;border-top:1px solid var(--line);display:flex;flex-direction:column;gap:9px}}
.m-ph{{display:flex;gap:10px;align-items:center}}.m-ph .t{{width:28px;height:28px;border-radius:8px;background:linear-gradient(135deg,{C["violet"]},{C["deep"]});color:#fff;display:flex;align-items:center;justify-content:center;font-size:13px}}
.m-ph b{{font:600 15px ui-rounded}}
.m-card{{padding:10px;border-radius:10px;background:color-mix(in srgb,var(--ink) 4.5%,transparent);border:1px solid color-mix(in srgb,var(--ink) 7%,transparent)}}
.m-card.row{{display:flex;gap:12px;align-items:center}}.m-card.row b{{display:block;font:600 15px ui-rounded,system-ui}}.m-card.row small{{display:block;color:var(--mute);font-size:13px}}.tile{{width:36px;height:36px;border-radius:10px;background:color-mix(in srgb,{C["violet"]} 14%,transparent);color:var(--accent);display:flex;align-items:center;justify-content:center}}.tiles{{display:flex;gap:6px;margin-top:8px}}.tiles span{{flex:1;height:34px;border-radius:8px;background:color-mix(in srgb,{C["violet"]} 14%,transparent);color:var(--accent);display:flex;align-items:center;justify-content:center;font-size:14px}}.tg{{margin-left:auto;width:40px;height:24px;border-radius:99px;background:{C["bright"]};position:relative}}.tg:after{{content:"";position:absolute;right:3px;top:3px;width:18px;height:18px;border-radius:50%;background:#fff}}.m-card .l{{font:600 11px ui-rounded;letter-spacing:.09em;text-transform:uppercase;color:var(--mute)}}
.btn{{display:inline-block;font:600 14px ui-rounded;padding:6px 13px;border-radius:99px}}
.btn.p{{background:{C["violet"]};color:#fff}}.btn.q{{background:color-mix(in srgb,{C["violet"]} 14%,transparent);color:var(--accent)}}
.tag{{display:inline-block;font:500 11px ui-rounded;padding:1.5px 6px;border-radius:99px;background:color-mix(in srgb,{C["violet"]} 14%,transparent);color:var(--accent)}}
.say{{display:grid;grid-template-columns:1fr 1fr;gap:14px}}@media(max-width:640px){{.say{{grid-template-columns:1fr}}}}
.yes,.no{{border-radius:14px;padding:14px 16px;border:1px solid var(--line);background:var(--card)}}
.yes b{{color:var(--good-t)}}.no b{{color:var(--bad-t)}}
.yes ul,.no ul{{margin:6px 0 0;padding-left:18px}}.yes li,.no li{{margin:5px 0}}
.dont{{text-align:center;font-size:13px;color:var(--mute)}}.dont .stage{{height:132px;padding:10px;overflow:hidden}}
.scale div{{display:flex;align-items:baseline;gap:16px;padding:8px 0;border-bottom:1px solid var(--line)}}.scale span{{flex:none;width:130px;font:12px ui-monospace,Menlo,monospace;color:var(--mute)}}
footer{{margin-top:64px;padding-top:20px;border-top:1px solid var(--line);color:var(--mute);font-size:14px}}
</style></head><body>

<header class="cover"><div class="in">
  {icon(190)}
  <div><h1>Whop<i>rrr</i></h1><p>Your Mac, stacked your way.</p><small>Brand manual · v1 · 2026-11-24</small></div>
</div></header>
<nav><div class="in">
  <a href="#essence">Essence</a><a href="#logo">Logo</a><a href="#glyph">Menu-bar glyph</a><a href="#color">Colour</a><a href="#type">Type</a><a href="#ui">Interface</a><a href="#voice">Voice</a><a href="#assets">Assets</a>
</div></nav>

<div class="wrap">

<section id="essence">
  <div class="k">01 · Essence</div><h2>A burger that is also the menu</h2>
  <p>The hamburger menu is three lines that hide a pile of options. Whoprrr is a pile of Mac utilities that stays out of sight until needed, so the mark is a burger: it is the menu button, and it is the app.</p>
  <div class="grid g3">
    <div class="card"><h3>The name</h3><p class="mute">Say “whop-rrr”. The <b>rrr</b> is the sound of a machine doing something for you: a purr, a rev. Write it <b>Whoprrr</b>: capital W, the rest lowercase, one word.</p></div>
    <div class="card"><h3>The idea</h3><p class="mute">Layers you can stack, drop or swap. One bun is the chrome, the middle is signal: display signal above, audio waveform below. It looks like what the app does.</p></div>
    <div class="card"><h3>The personality</h3><p class="mute"><b>Playful on the outside, exact inside.</b> The logo can be silly; the behaviour is not. When it works it is quiet. When it fails it says so plainly.</p></div>
  </div>
  <h3>Tagline</h3>
  <p><b>Your Mac, stacked your way.</b> <span class="mute">Short forms: “Stack it your way.” · “One menu bar. Everything else, off.”</span></p>
</section>

<section id="logo">
  <div class="k">02 · Logo</div><h2>The burger</h2>
  <div class="card anat">
    <div class="stage" style="padding:18px">{icon(260)}</div>
    <ol>
      <li><b>Top bun.</b> The menu. Always bun yellow with sesame.</li>
      <li><b>Subpixel row.</b> Twelve chunky columns, red, green, blue, repeating: the display and video side (Samsung control, window layout).</li>
      <li><b>Waveform patty.</b> Fifteen mirrored bars in pink, loudest in the middle: the audio side. It is a patty, so it stays low and wide.</li>
      <li><b>Bottom bun.</b> A flat base with rounded heels.</li>
      <li><b>Plate.</b> Violet gradient, 22.5% corner radius. The burger fills 84% of its width.</li>
    </ol>
  </div>
  <h3>Forms</h3>
  <div class="grid g3">
    <div class="card"><h3>App icon</h3><div class="stage">{icon(112)}{icon(56)}{icon(32)}{icon(16)}</div><p class="mute" style="margin-top:10px">Sesame drops out below 40 px. Never smaller than 16 px.</p></div>
    <div class="card"><h3>Mark only</h3><div class="stage dark">{icon(112, plate=False)}</div><p class="mute" style="margin-top:10px">For dark or violet grounds when the plate would double up. Keep clear space of one column width on all sides.</p></div>
    <div class="card"><h3>Wordmark</h3><div class="stage"><div class="w" style="font:800 44px ui-rounded,system-ui;letter-spacing:-.04em">Whop<i style="font-style:normal;color:{C["bright"]};text-shadow:3px 0 0 rgba(255,59,74,.55),-3px 0 0 rgba(77,163,255,.6)">rrr</i></div></div><p class="mute" style="margin-top:10px">SF Pro Rounded Heavy, tracking −3%. The <b>rrr</b> is bright violet with a red and blue split shadow (0.07 em). Use the split on large sizes only; flat violet under 20 pt.</p></div>
  </div>
  <h3>Don’t</h3>
  <div class="grid g4">{"".join(f'<div class="dont"><div class="stage">{h}</div>{n}</div>' for n, h in dont_cases)}</div>
  <p class="mute" style="margin-top:12px">Also: no other bun colour, no extra layers (cheese, lettuce, bacon) in the official mark, no drop shadow baked into the artwork, and never use the name or mark next to anyone else’s burger trademark.</p>
</section>

<section id="glyph">
  <div class="k">03 · Menu-bar glyph</div><h2>One colour, 18 points</h2>
  <p>The menu bar only accepts a template image, so the glyph is a single colour and macOS tints it for light and dark. It keeps the three signals of the full mark: dome bun, <b>six dashes</b> for the subpixel row, <b>nine mirrored bars</b> for the waveform, flat base.</p>
  <div class="card"><div class="grid g2">
    <div class="stage" style="gap:30px"><span class="bar l">{glyph(18)} <span style="font:500 11px ui-monospace,Menlo">18 pt</span></span><span class="bar d">{glyph(18)} <span style="font:500 11px ui-monospace,Menlo">dark</span></span></div>
    <div class="stage" style="gap:30px"><span style="color:{C["ink"]}">{glyph(96)}</span><span style="color:{C["ink"]}">{glyph(48)}</span><span style="color:{C["ink"]}">{glyph(24)}</span></div>
  </div>
  <p class="mute" style="margin:12px 0 0">Source: <code>MenuBarIcon.swift</code> (24-unit grid drawn at 0.75). Don’t colour it, don’t add a badge dot (use the panel’s status chip), keep the height at 18 pt.</p></div>
</section>

<section id="color">
  <div class="k">04 · Colour</div><h2>One violet, three signals</h2>
  <p>Violet is the whole interface. Red, green and blue are the display signal; they only appear in the logo row and as meaning (error, good). Bun and patty belong to the logo and illustrations, never to controls.</p>
  <h3>Brand</h3>
  <div class="grid g4">
    {swatch("Violet", C["violet"], "Primary. Plate, filled buttons, selected nav")}
    {swatch("Violet bright", C["bright"], "Accent text, links, tints, the “rrr”")}
    {swatch("Violet deep", C["deep"], "Plate gradient end, dark grounds")}
    {swatch("Accent on dark", C["accent_dark"], "Accent text and icons in dark mode", "#1d1b19")}
  </div>
  <h3>Logo only</h3>
  <div class="grid g4">
    {swatch("Bun", C["bun"], "Buns", "#3a2a00")}
    {swatch("Seed", C["seed"], "Sesame", "#3a2a00")}
    {swatch("Patty", C["patty"], "Waveform", "#1d1b19")}
    {swatch("Paper", C["paper"], "Light ground", "#3a3630")}
  </div>
  <h3>Signal and status</h3>
  <div class="grid g4">
    {swatch("Signal red", C["red"], "Errors, destructive", "#1d1b19")}
    {swatch("Signal green", C["green"], "Logo row", "#0a2c16")}
    {swatch("Signal blue", C["blue"], "Logo row", "#06233f")}
    {swatch("Good", C["good"], "Running / OK chip dot and fill", "#06280f")}
  </div>
  <h3>Proportion (interface)</h3>
  <div class="bandrow"><div style="flex:78;background:var(--line)"></div><div style="flex:14;background:{C["violet"]}"></div><div style="flex:5;background:{C["bright"]}"></div><div style="flex:3;background:linear-gradient(90deg,{C["red"]} 33%,{C["green"]} 33% 66%,{C["blue"]} 66%)"></div></div>
  <p class="mute">System neutrals 78% · violet 14% · bright violet 5% · signal colours 3%.</p>
  <h3>Contrast</h3>
  <div class="card" style="padding:6px 14px"><table>
    <tr><th></th><th>Use</th><th>Pair</th><th>Ratio</th><th>Grade</th></tr>
    {con_row("#FFFFFF", C["violet"], "Filled button label")}
    {con_row(C["violet"], "#FFFFFF", "Accent text on light (Brand.accentText)")}
    {con_row(C["accent_dark"], "#1D1B19", "Accent text on dark (Brand.accentText)")}
    {con_row(C["good_text"], "#FFFFFF", "Good chip text on light")}
    {con_row(C["ink"], C["paper"], "Body on paper")}
    {con_row(C["bun"], C["deep"], "Bun on plate")}
  </table></div>
  <p class="mute" style="margin-top:8px">Small accent text uses <b>Brand.accentText</b>: violet in light mode, a lighter violet in dark mode, so it keeps 4.5:1 on either. Bright violet (#7C4DFF) is for fills, tints, toggles and the large “rrr” only.</p>
</section>

<section id="type">
  <div class="k">05 · Type</div><h2>Rounded for character, system for work</h2>
  <p>Whoprrr uses Apple’s own faces so it feels native and costs nothing to ship: <b>SF Pro Rounded</b> for the wordmark, panel titles and small caps labels; <b>SF Pro</b> for everything you read; <b>SF Mono</b> for shortcuts and codes.</p>
  <div class="card scale">
    <div><span>Wordmark · 24–64 / Heavy</span><b style="font:800 30px ui-rounded,system-ui;letter-spacing:-.03em">Whoprrr</b></div>
    <div><span>Page title · 19 / Semibold rounded</span><b style="font:600 19px ui-rounded,system-ui">Keys and mouse</b></div>
    <div><span>Card title · 15 / Semibold rounded</span><b style="font:600 15px ui-rounded,system-ui">Caps Lock: Esc on tap, Control on hold</b></div>
    <div><span>Body · 15 / Regular SF Pro</span><span style="width:auto;color:var(--ink);font:15px -apple-system,system-ui">Hold Caps Lock and use H J K L as arrows anywhere.</span></div>
    <div><span>Caption · 13 / Regular</span><span style="width:auto;font:13px -apple-system,system-ui">Applied by macOS itself. Removed when Whoprrr quits.</span></div>
    <div><span>Label · 12 / Semibold rounded, +9%</span><b style="font:600 12px ui-rounded,system-ui;letter-spacing:.09em;color:var(--mute)">RULES</b></div>
    <div><span>Code · 13 / SF Mono</span><code>⌃⌥⇧⌘⎋</code></div>
  </div>
  <p class="mute" style="margin-top:10px">Nothing in the interface is smaller than 12 pt. Controls use the regular macOS size, not small or mini.</p>
</section>

<section id="ui">
  <div class="k">06 · Interface</div><h2>Two surfaces, two jobs</h2>
  <p>The <b>menu-bar panel</b> is for glancing and doing things right now: status and the few toggles you reach for during the day. The <b>main window</b> is the app: a sidebar of features and a roomy page for each, where everything is set up. The panel has a Settings button (⌘,) and nothing else that needs configuring.</p>
  <div class="grid g2" style="align-items:start">
    <div class="mock">
      <div class="m-head">{icon(38)}<div><div class="w">Whop<i>rrr</i></div></div><span style="margin-left:auto;color:var(--mute);font-size:16px">⚙</span></div>
      <div class="m-body">
        <div class="m-card row"><span class="tile">⌨</span><div><b>Keys and mouse</b><small>2 rules active</small></div><span class="btn q">Pause</span></div>
        <div class="m-card row"><span class="tile">⎘</span><div><b>Clipboard</b><small>6 saved · ⌃⌘V</small></div><span class="btn q">Open</span></div>
        <div class="m-card"><b style="font:600 15px ui-rounded,system-ui">Window</b><div class="tiles"><span>◧</span><span>◨</span><span>⬒</span><span>⬓</span><span>⤢</span><span>▣</span><span>▭▭</span><span>↩</span></div></div>
        <div class="m-card row"><span class="tile">♪</span><div><b>MacBook Air Speakers</b><small>Equalizer on</small></div><span class="tg"></span></div>
        <div class="m-card row"><span class="tile">🎙</span><div><b>RØDE PodMic USB</b><small>Pinned as your input</small></div><span class="tg"></span></div>
        <div style="display:flex;align-items:center"><span class="btn p">Settings…</span><span style="margin-left:auto;color:var(--mute);font-size:14px">Quit</span></div>
      </div>
    </div>
    <div>
      <div class="card"><h3>Menu-bar panel</h3><p class="mute" style="margin:0">400 pt wide. Header (logo, wordmark, settings gear), a permission banner only when something needs fixing, one card per installed feature with its status and one control, then Settings… and Quit. Window buttons act on the app you were in, not on Whoprrr.</p></div>
      <div class="card" style="margin-top:12px"><h3>Main window</h3><p class="mute" style="margin:0">Sidebar 232 pt (logo, features, Features, Permissions, status chip) and a page up to 680 pt wide, minimum window 860 × 620. Opens on Permissions the first time. While it is open Whoprrr also shows in the Dock; closing it returns to menu-bar only.</p></div>
      <div class="card" style="margin-top:12px"><h3>Components</h3>
        <table style="font-size:14px"><tr><th>Piece</th><th>Spec</th></tr>
        <tr><td>Page header</td><td>34 pt violet-gradient tile, radius 10; title 19 rounded semibold</td></tr>
        <tr><td>Card</td><td>Radius 10, 4.5% ink fill, 7% ink stroke, 12 pt padding</td></tr>
        <tr><td>Row tile</td><td>36 pt, radius 10, 14% violet fill, accent icon</td></tr>
        <tr><td>Primary button</td><td>Capsule, violet fill, white 14 pt rounded semibold</td></tr>
        <tr><td>Quiet button</td><td>Capsule, 14% violet fill, accent label</td></tr>
        <tr><td>Status chip</td><td>Capsule, tone dot + 12% tone fill, 13 pt</td></tr>
        <tr><td>Sidebar item</td><td>Radius 9; selected = 16% violet fill, accent label, semibold</td></tr>
        <tr><td>Toggle</td><td>Native switch, tinted bright violet</td></tr></table></div>
      <div class="card" style="margin-top:12px"><h3>Spacing, radius, motion</h3><p class="mute" style="margin:0">Spacing steps 4 · 8 · 10 · 12 · 16 · 28. Radii 8 · 9 · 10 · capsule. Motion is 150 ms ease-out, no bounce, none under Reduce Motion. Light and dark follow the system; the plate and the logo never change.</p></div>
    </div>
  </div>
</section>

<section id="voice">
  <div class="k">07 · Voice</div><h2>Warm, short, honest</h2>
  <p>Talk like a helpful friend who knows the Mac: plain words, one idea per sentence, no exclamation marks, no puns in places where something is wrong. The jokes live in the logo and the name; the copy gets on with it.</p>
  <div class="say">
    <div class="yes"><b>Say</b><ul><li>“Needs Input Monitoring to see keys.” <span class="mute">(what, then the fix)</span></li><li>“Imported 6 rules; 1 skipped.”</li><li>“Quit Karabiner-Elements so the same rule does not run twice.”</li><li>“Paused. Press ⌃⌥⇧⌘⎋ to resume.”</li></ul></div>
    <div class="no"><b>Don’t say</b><ul><li>“Oops! Something went wrong 🍔”</li><li>“Whoprrr couldn’t be bothered.”</li><li>“Error 1190: invalid state.”</li><li>“Please grant the necessary permissions to continue.”</li></ul></div>
  </div>
  <h3>Words we use</h3>
  <p class="mute"><b>Rule</b> (not mapping), <b>Keys and mouse</b>, <b>Mic</b> (the processed one is <b>Whoprrr Mic</b>), <b>Features</b> (installed or not), <b>Permissions</b>. Say “press” for keys, “click” for buttons, “hold” for dual-role keys. Name shortcuts with symbols (⌃⌥⇧⌘) and name keys as they are printed.</p>
</section>

<section id="assets">
  <div class="k">08 · Assets</div><h2>Files and how to rebuild them</h2>
  <div class="card" style="padding:6px 14px"><table>
    <tr><th>File</th><th>What</th></tr>
    <tr><td><code>assets/AppIcon.icns</code></td><td>The app icon (full set 16–1024). Embedded by <code>scripts/build-app.sh</code></td></tr>
    <tr><td><code>assets/whoprrr-icon-1024.png</code> · <code>whoprrr-icon.svg</code></td><td>Icon with plate, flat. For decks, READMEs, social</td></tr>
    <tr><td><code>assets/whoprrr-logo-512.png</code> · <code>whoprrr-logo.svg</code></td><td>Mark without the plate</td></tr>
    <tr><td><code>assets/whoprrr-glyph.svg</code> · <code>whoprrr-glyph@4x.png</code></td><td>Menu-bar glyph, black on clear</td></tr>
    <tr><td><code>brand-tokens.css</code></td><td>Colour and type tokens for anything on the web</td></tr>
    <tr><td><code>Sources/Whopper/Shell/Brand.swift</code></td><td>Tokens, <code>LogoMark</code>, <code>Wordmark</code>, card/chip/button styles</td></tr>
    <tr><td><code>Sources/Whopper/Shell/MenuBarIcon.swift</code></td><td>The glyph, drawn in code</td></tr></table></div>
  <h3>Regenerate</h3>
  <p><code>swift build -c release &amp;&amp; WHOPPER_RENDER_ICON=docs/brand/assets .build/release/Whopper</code> writes the iconset, <code>AppIcon.icns</code> and the PNGs from the SwiftUI artwork, so the shipped icon and the in-app logo are the same drawing. <code>python3 scripts/brand/gen_manual.py</code> rewrites this manual, the SVGs and the tokens.</p>
</section>

<footer>Whoprrr is an independent project and is not affiliated with any other company or product. The bundle id <code>gg.tico.whopper</code> and the module names keep the original working name so renaming the product never costs users their permission grants or data.</footer>
</div>
</body></html>'''

(OUT / "brand-manual.html").write_text(HTML)
print("wrote", OUT / "brand-manual.html", len(HTML))
