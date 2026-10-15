#!/usr/bin/env python3
"""
Télécharge les textures et le ciel HDRI (licence CC0, Poly Haven) utilisés par la simulation.

    python tools/download_assets.py

Les fichiers sont placés dans assets/ (voir assets/CREDITS.md). Déjà présents = ignorés.
CC0 : utilisation libre, y compris commerciale, sans attribution obligatoire.
"""
import json
import os
import urllib.request

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
API = "https://api.polyhaven.com/files/"

# nom local -> (id Poly Haven, résolution)
TEXTURES = {
    "meadow": ("forrest_ground_01", "2k"),
    "forest_floor": ("mud_forest", "2k"),
    "rock": ("aerial_rocks_02", "1k"),
    "sand": ("coast_sand_01", "1k"),
    "burnt": ("burned_ground_01", "1k"),
    "park_grass": ("leafy_grass", "1k"),
    "asphalt": ("asphalt_02", "1k"),
    "sidewalk": ("concrete_pavement_02", "1k"),
    "concrete": ("brushed_concrete", "1k"),
    "facade_a": ("painted_plaster_wall", "1k"),
    "facade_b": ("beige_wall_001", "1k"),
    "facade_c": ("concrete_wall_008", "1k"),
    "facade_d": ("brick_4", "1k"),
    "roof": ("gravel_concrete", "1k"),
    "bark": ("knotted_pine_bark", "1k"),
}
MAPS = {"Diffuse": "diff", "nor_gl": "nor", "arm": "arm"}
HDRI = ("kloofendal_48d_partly_cloudy_puresky", "2k")
HEADERS = {"User-Agent": "orchestrateur-drones-eigsi/1.0 (asset downloader)"}


def fetch_json(url):
    with urllib.request.urlopen(urllib.request.Request(url, headers=HEADERS), timeout=30) as r:
        return json.loads(r.read().decode("utf-8"))


def download(url, dest):
    if os.path.exists(dest) and os.path.getsize(dest) > 0:
        return False
    os.makedirs(os.path.dirname(dest), exist_ok=True)
    tmp = dest + ".part"
    with urllib.request.urlopen(urllib.request.Request(url, headers=HEADERS), timeout=120) as r, open(tmp, "wb") as f:
        f.write(r.read())
    os.replace(tmp, dest)
    return True


def _compose_arm(files, res, dest):
    """Carte ARM absente : on l'assemble (R = occlusion, G = rugosité, B = métal à 0)."""
    if os.path.exists(dest):
        return
    from PIL import Image  # pip install pillow
    tmp_dir = os.path.dirname(dest)
    rough_p = os.path.join(tmp_dir, "_rough.jpg")
    download(files["Rough"][res]["jpg"]["url"], rough_p)
    rough = Image.open(rough_p).convert("L")
    if "AO" in files:
        ao_p = os.path.join(tmp_dir, "_ao.jpg")
        download(files["AO"][res]["jpg"]["url"], ao_p)
        ao = Image.open(ao_p).convert("L").resize(rough.size)
        os.remove(ao_p)
    else:
        ao = Image.new("L", rough.size, 255)
    Image.merge("RGB", (ao, rough, Image.new("L", rough.size, 0))).save(dest, quality=92)
    os.remove(rough_p)
    print("assemblé   " + os.path.relpath(dest, ROOT))


def main():
    credits = ["# Crédits des assets", "",
               "Toutes les ressources ci-dessous viennent de **Poly Haven** (https://polyhaven.com),",
               "sous licence **CC0** (domaine public). Téléchargées par `tools/download_assets.py`.", ""]
    for local, (pid, res) in TEXTURES.items():
        files = fetch_json(API + pid)
        for key, short in MAPS.items():
            dest = os.path.join(ROOT, "assets", "textures", local, f"{short}.jpg")
            if key == "arm" and "arm" not in files:
                _compose_arm(files, res, dest)
                continue
            url = files[key][res]["jpg"]["url"]
            got = download(url, dest)
            print(("téléchargé " if got else "présent    ") + os.path.relpath(dest, ROOT))
        credits.append(f"- `assets/textures/{local}/` : *{pid}* ({res}) — https://polyhaven.com/a/{pid}")
    pid, res = HDRI
    files = fetch_json(API + pid)
    url = files["hdri"][res]["hdr"]["url"]
    dest = os.path.join(ROOT, "assets", "sky", "sky.hdr")
    got = download(url, dest)
    print(("téléchargé " if got else "présent    ") + os.path.relpath(dest, ROOT))
    credits.append(f"- `assets/sky/sky.hdr` : ciel HDRI *{pid}* ({res}) — https://polyhaven.com/a/{pid}")
    with open(os.path.join(ROOT, "assets", "CREDITS.md"), "w", encoding="utf-8") as f:
        f.write("\n".join(credits) + "\n")


if __name__ == "__main__":
    main()
