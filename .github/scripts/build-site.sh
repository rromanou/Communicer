#!/usr/bin/env bash
# Assemble le site statique (GitHub Pages) dans _site/ : app/* à la racine + scripts/ style/ assets/.
set -euo pipefail
cd "$(dirname "$0")/../.."
OUT="${1:-_site}"
rm -rf "$OUT"; mkdir -p "$OUT/scripts" "$OUT/style" "$OUT/assets"
python3 .github/scripts/gen_lite.py
python3 .github/scripts/gen_phone.py
cp app/*.html app/sw.js "$OUT/"
mkdir -p "$OUT/phone"; cp phone/index.html phone/phone.js phone/phone-ui.js phone/phone.css "$OUT/phone/"
cp scripts/*.js scripts/ciffron.enc "$OUT/scripts/"
rm -f "$OUT/scripts/ciffron.js"                 # source en clair : jamais publiée
cp database/functions/bots-offline.js "$OUT/scripts/bots-offline.js"
cp style/*.css "$OUT/style/"
cp -r assets/. "$OUT/assets/"
touch "$OUT/.nojekyll"
echo "Site assemblé dans $OUT ($(find "$OUT" -type f | wc -l) fichiers)"
