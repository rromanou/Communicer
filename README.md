# Communicer!

Messagerie (Supabase + GitHub Pages). Site : `https://rromanou.github.io/Communicer/` — version téléphone : `/phone/`.

## Organisation

| Dossier | Contenu |
|---|---|
| `app/` | Pages : `index.html`, `communicer-lite.html` (générée), `mentions.html` (conditions), `404.html`, `offline.html`, `sw.js` |
| `phone/` | Version téléphone : `index.html` (générée depuis `app/index.html`), `phone.js`, `phone-ui.js` (manette, textes tactiles), `phone.css` |
| `scripts/` | Code du site : `app.js`, `cmm.js`, `zcm.js`, `shell.js`, `ciffron-loader.js`, `ciffron.enc` (Ciffron chiffré), `theme.js` |
| `style/` | `style.css` |
| `database/` | `exe.txt` = **ordre d'exécution de tous les SQL** ; `sql/` ; `functions/` (fonctions edge + `bots-offline.js`) |
| `assets/` | `frames/` (cadres), `images/`, `media/`, `src/` (dialogues, ressources compressées) |
| `android/` | Projet Android (WebView) ; `src/data/data.json` (nom, version), `src/data/img.ico` (icône), `src/Communicer.apk` (produit par le workflow) |
| `docs/`, `tests/` | Documentation, test de fumée (`node tests/smoke.js _site`) |
| `.github/` | Workflows et scripts de contrôle |

## Règles de travail
- Chaque nouveau SQL va dans `database/sql/` **et** est ajouté à `database/exe.txt`.
- Le site publié est assemblé à plat par `.github/scripts/build-site.sh` (`app/*` à la racine + `scripts/ style/ assets/ phone/`).
- `app/communicer-lite.html` et `phone/index.html` sont générés (`gen_lite.py`, `gen_phone.py`) : ne pas les éditer à la main.
- Les images, GIF et vidéos sont compressés automatiquement avant l'envoi au serveur (aucun bouton).
- Aucune clé, keystore ni `ciffron` en clair ne doit être publié (voir `.gitignore`, `.gitleaks.toml`).

## Workflows
GitHub n'exécute que les fichiers directement dans `.github/workflows/` : le groupe est donc dans le nom (`deployment--`, `validation--`, `database--`, `security--`, `maintenance--`).
Pages : Settings > Pages > Source = **GitHub Actions**.

## Application Android
Secrets GitHub requis : `ANDROID_KEYSTORE_B64`, `ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_ALIAS`, `ANDROID_KEY_PASSWORD`. Le workflow `deployment--android-apk` compile, signe et dépose `android/src/Communicer.apk`.
