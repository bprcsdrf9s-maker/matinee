"""Draws the Apple TV app icon (two layers, for the tilt effect) and Top Shelf images."""
import sys, os, math, json
from PIL import Image, ImageDraw, ImageFont

OUT = sys.argv[1]
BG = (44, 16, 13)
RINGS = [(52, 19, 15), (60, 22, 17), (68, 24, 18)]
GOLD = (245, 184, 66)
INFO = {"author": "xcode", "version": 1}

def back(w, h):
    img = Image.new("RGB", (w, h), BG)
    d = ImageDraw.Draw(img)
    u = h / 240.0
    for i, c in enumerate(RINGS):
        r = (190 - i * 38) * u
        cx, cy = w / 2, h * 0.46
        d.ellipse([cx - r * 1.35, cy - r, cx + r * 1.35, cy + r], fill=c)
    return img.quantize(colors=8)

def mark(d, cx, cy, u, dots=24):
    ring = 78 * u
    dot = 4.6 * u
    for i in range(dots):
        a = 2 * math.pi * i / dots
        x, y = cx + ring * math.cos(a), cy + ring * math.sin(a)
        d.ellipse([x - dot, y - dot, x + dot, y + dot], fill=GOLD + (255,))
    h = 78 * u; w = h * math.sqrt(3) / 2; px = cx + w * 0.12
    d.polygon([(px - w / 2, cy - h / 2), (px - w / 2, cy + h / 2), (px + w / 2, cy)], fill=GOLD + (255,))

def front(w, h):
    img = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    mark(d, w / 2, h / 2, h / 240.0)
    return img

def top_shelf(w, h):
    img = Image.new("RGB", (w, h), BG)
    d = ImageDraw.Draw(img)
    u = h / 720.0
    for i, c in enumerate(RINGS):
        r = (560 - i * 120) * u
        d.ellipse([w * 0.5 - r * 2.2, h * 0.5 - r, w * 0.5 + r * 2.2, h * 0.5 + r], fill=c)
    font = None
    for path in ("/System/Library/Fonts/Supplemental/Arial Bold.ttf", "/System/Library/Fonts/Supplemental/Arial Rounded Bold.ttf",
                 "/Library/Fonts/Arial Bold.ttf", "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf"):
        if os.path.exists(path):
            font = ImageFont.truetype(path, int(150 * u))
            break
    if font is None:
        font = ImageFont.load_default(size=int(150 * u))
    text = "Matinee"
    tw = d.textlength(text, font=font)
    gap = 70 * u
    mark_w = 300 * u
    total = mark_w + gap + tw
    x0 = (w - total) / 2
    rgba = img.convert("RGBA")
    dd = ImageDraw.Draw(rgba)
    mark(dd, x0 + mark_w / 2, h / 2, (mark_w / 2) / 82.6)
    dd.text((x0 + mark_w + gap, h / 2), text, font=font, fill=GOLD + (255,), anchor="lm")
    return rgba.convert("RGB").quantize(colors=16)

def save(img, path):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    img.save(path, optimize=True)

def jw(path, obj):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        json.dump(obj, f, indent=2)

root = os.path.join(OUT, "App Icon & Top Shelf Image.brandassets")
jw(os.path.join(root, "Contents.json"), {"assets": [
    {"filename": "App Icon - App Store.imagestack", "idiom": "tv", "role": "primary-app-icon", "size": "1280x768"},
    {"filename": "App Icon.imagestack", "idiom": "tv", "role": "primary-app-icon", "size": "400x240"},
    {"filename": "Top Shelf Image Wide.imageset", "idiom": "tv", "role": "top-shelf-image-wide", "size": "2320x720"},
    {"filename": "Top Shelf Image.imageset", "idiom": "tv", "role": "top-shelf-image", "size": "1920x720"},
], "info": INFO})

def stack(name, sizes):
    sroot = os.path.join(root, name)
    jw(os.path.join(sroot, "Contents.json"), {"info": INFO, "layers": [
        {"filename": "Front.imagestacklayer"}, {"filename": "Back.imagestacklayer"}]})
    for layer, fn in (("Front", front), ("Back", back)):
        lroot = os.path.join(sroot, layer + ".imagestacklayer")
        jw(os.path.join(lroot, "Contents.json"), {"info": INFO})
        images = []
        for scale, (w, h) in sizes:
            f = f"{layer.lower()}-{w}x{h}.png"
            save(fn(w, h), os.path.join(lroot, "Content.imageset", f))
            images.append({"idiom": "tv", "scale": scale, "filename": f})
        jw(os.path.join(lroot, "Content.imageset", "Contents.json"), {"images": images, "info": INFO})

stack("App Icon.imagestack", [("1x", (400, 240)), ("2x", (800, 480))])
stack("App Icon - App Store.imagestack", [("1x", (1280, 768))])

for name, sizes in (("Top Shelf Image.imageset", [("1x", (1920, 720)), ("2x", (3840, 1440))]),
                    ("Top Shelf Image Wide.imageset", [("1x", (2320, 720)), ("2x", (4640, 1440))])):
    iroot = os.path.join(root, name)
    images = []
    for scale, (w, h) in sizes:
        f = f"shelf-{w}x{h}.png"
        save(top_shelf(w, h), os.path.join(iroot, f))
        images.append({"idiom": "tv", "scale": scale, "filename": f})
    jw(os.path.join(iroot, "Contents.json"), {"images": images, "info": INFO})

jw(os.path.join(OUT, "Contents.json"), {"info": INFO})
jw(os.path.join(OUT, "AccentColor.colorset", "Contents.json"), {"colors": [{"idiom": "universal", "color": {
    "color-space": "srgb", "components": {"red": "0.490", "green": "0.400", "blue": "1.000", "alpha": "1.000"}}}], "info": INFO})
