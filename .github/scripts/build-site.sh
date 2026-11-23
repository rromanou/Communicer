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
# anti-cache : chaque publication change l'adresse des scripts et styles (le navigateur recharge la nouvelle version)
STAMP="${GITHUB_SHA:-$(date +%s)}"; STAMP="${STAMP:0:10}"
for f in "$OUT"/*.html "$OUT"/phone/*.html; do
  [ -f "$f" ] && sed -i -E "s#((scripts|style)/[A-Za-z0-9_.-]+\.(js|css))(\"|')#\1?v=$STAMP\4#g" "$f"
done
touch "$OUT/.nojekyll"
echo "Site assemblé dans $OUT ($(find "$OUT" -type f | wc -l) fichiers)"
