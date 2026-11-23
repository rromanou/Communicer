-- ============================================================================
-- Communicer! — Lot 22 (additif, relançable). À exécuter après patch_lot21.sql (voir database/exe.txt).
-- 1) VlafiBOT : main.cmm complet et vérifié (corrige « Ligne 232 : chaîne non fermée »)
-- 2) Libération d'espace : suppression de journaux autorisée par la purge (plus de fausse « ALERTE SÉCURITÉ »), espace réellement libéré, poids affiché à jour
-- 3) Comptes @system / @staff : code de 64 caractères (au-delà de 72, GoTrue répond 500) valable 5 minutes seulement
-- 4) Légalisation : le commandant publie de nouvelles conditions ; chaque compte les accepte ou les refuse à la connexion
-- 5) Conservation des données : durées par défaut + retention_run() planifiée (voir mentions.html)
-- ============================================================================

-- ---------- 1) VlafiBOT ----------
update public.bot_files f set content = $cm$# VlafiBOT — musique dans les appels (préfixe « vl/ »).
# Le son est calculé et décodé EN MÉMOIRE par le navigateur (Web Audio API) : aucun lecteur standard, aucun site externe.
# Chaque personne dans l'appel joue le morceau chez elle ; la file d'attente et les réglages sont partagés.
# Les réglages (vitesse, hauteur, volume, basses, 8D) durent le temps de la session puis reviennent aux valeurs par défaut.

constante DEFAUT = {speed: 1, pitch: 1, vol: 100, bass: faux, d8: faux}
soit connaissances = JSON.parse(attends api.fs.read("musique.json"))
soit etat = {file: [], courant: nul, ctrl: nul, reglages: Object.assign({}, DEFAUT), cache: {}}

# ---------- recherche : la musique la plus proche dans les connaissances ----------
fonction norm(s):
    retour String(s || "").toLowerCase().normalize("NFD").replace(/[̀-ͯ]/g, "").replace(/[^a-z0-9 ]/g, " ").replace(/\s+/g, " ").trim()

fonction distance(a, b):
    soit m = a.length
    soit n = b.length
    si m == 0:
        retour n
    si n == 0:
        retour m
    soit prev = []
    pour j de 0 a n:
        prev.push(j)
    pour i de 1 a m:
        soit cur = [i]
        pour j de 1 a n:
            soit cout = a[i - 1] == b[j - 1] ? 0 : 1
            cur.push(Math.min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cout))
        prev = cur
    retour prev[n]

fonction score(q, p):
    soit titre = norm(p.titre)
    soit texte = titre + " " + norm(p.artiste) + " " + p.tags.map(norm).join(" ")
    soit s = 0
    si titre == q:
        s += 100
    si titre.includes(q):
        s += 60
    si texte.includes(q):
        s += 30
    pour mot dans q.split(" "):
        si mot.length < 2:
            continuer
        si titre.includes(mot):
            s += 14
        sinon si texte.includes(mot):
            s += 8
    soit d = distance(q, titre.slice(0, Math.max(q.length, 3)))
    s += Math.max(0, 20 - d * 2)
    retour s

fonction chercher(requete, n):
    soit q = norm(requete)
    soit liste = connaissances.map(p => ({p: p, s: q ? score(q, p) : 0}))
    liste.sort((x, y) => y.s - x.s)
    retour liste.slice(0, n).map(x => x.p)

fonction trouver(id):
    retour connaissances.find(p => p.id == id)

fonction minutes(p):
    soit beats = 0
    pour v dans p.voices:
        soit t = 0
        pour tok dans v.notes.split(" "):
            soit d = +(tok.split(":")[1] || 1)
            t += d
        beats = Math.max(beats, t)
    soit s = Math.round(beats * 60 / p.bpm)
    retour Math.floor(s / 60) + ":" + String(s % 60).padStart(2, "0")

fonction etiquette(p):
    retour p.titre + " — " + p.artiste + " (" + minutes(p) + ")"

# ---------- vérifications ----------
fonction moi():
    retour api.conv.info().then(i => i.me)

fonction nombre(txt, lo, hi, nom):
    soit v = +String(txt).replace(",", ".")
    si txt === "" ou txt === nul ou txt === undefined ou isNaN(v):
        lancer nom + " : indiquez un nombre entre " + lo + " et " + hi
    si v < lo ou v > hi:
        lancer nom + " doit être compris entre " + lo + " et " + hi
    retour v

fonction onoff(txt, nom):
    soit t = String(txt || "").trim().toLowerCase()
    si t == "o" ou t == "oui":
        retour vrai
    si t == "n" ou t == "non":
        retour faux
    lancer nom + " : écrivez O pour oui ou N pour non"

fonction verifierAppel():
    soit r = attends api.room.info()
    si non r.active:
        lancer "Aucun appel en cours. Démarrez un appel dans le groupe, puis tapez /join."
    si non r.joined:
        lancer "Je ne suis pas dans l'appel. Tapez vl/join pour m'y inviter."

# ---------- lecture ----------
fonction partager():
    api.room.broadcast("file", {file: etat.file})

fonction lancer_piste(p):
    api.room.broadcast("play", {id: p.id, at: api.now(), set: etat.reglages})

sur commande "play" (ctx):
    essayer:
        attends verifierAppel()
        soit q = ctx.params.m || ctx.args
        si non q:
            lancer "Indiquez une musique : vl/play m:[NOM DE LA MUSIQUE]"
        soit res = chercher(q, 8)
        soit i = attends api.ui.choose("Choisissez la musique à jouer", res.map(etiquette))
        si i === nul:
            dire("Aucune musique choisie.")
            retour
        etat.file = []
        partager()
        lancer_piste(res[i])
    erreur e:
        dire("Impossible : " + e.message)

sur commande "playadd" (ctx):
    essayer:
        attends verifierAppel()
        soit q = ctx.params.m || ctx.args
        si non q:
            lancer "Indiquez une musique : vl/playadd m:[NOM DE LA MUSIQUE]"
        soit res = chercher(q, 8)
        soit i = attends api.ui.choose("Choisissez la musique à ajouter à la file", res.map(etiquette))
        si i === nul:
            dire("Aucune musique choisie.")
            retour
        soit courant = (attends api.audio.state()).playing
        si non courant:
            lancer_piste(res[i])
        sinon:
            etat.file.push(res[i].id)
            partager()
            dire("Ajoutée à la file (" + etat.file.length + ") : " + res[i].titre)
    erreur e:
        dire("Impossible : " + e.message)

sur commande "speed" (ctx):
    essayer:
        soit v = nombre(ctx.args, 0.1, 3, "La vitesse")
        etat.reglages.speed = v
        api.room.broadcast("set", {set: {speed: v}})
        dire("Vitesse : " + v)
    erreur e:
        dire("Impossible : " + e.message)

sur commande "pitch" (ctx):
    essayer:
        soit v = nombre(ctx.args, 0.1, 5, "La hauteur")
        etat.reglages.pitch = v
        api.room.broadcast("set", {set: {pitch: v}})
        dire("Hauteur : " + v + " (" + (v < 1 ? "plus grave" : v > 1 ? "plus aiguë" : "normale") + ")")
    erreur e:
        dire("Impossible : " + e.message)

sur commande "vol" (ctx):
    essayer:
        soit v = nombre(ctx.args, 1, 200, "Le volume")
        etat.reglages.vol = v
        api.room.broadcast("set", {set: {vol: v}})
        dire("Volume : " + v + " %")
    erreur e:
        dire("Impossible : " + e.message)

sur commande "bass" (ctx):
    essayer:
        soit v = onoff(ctx.args, "Basses")
        etat.reglages.bass = v
        api.room.broadcast("set", {set: {bass: v}})
        dire("Basses renforcées : " + (v ? "oui" : "non"))
    erreur e:
        dire("Impossible : " + e.message)

sur commande "8d" (ctx):
    essayer:
        soit v = onoff(ctx.args, "Effet 8D")
        etat.reglages.d8 = v
        api.room.broadcast("set", {set: {d8: v}})
        dire("Effet 8D : " + (v ? "oui" : "non"))
    erreur e:
        dire("Impossible : " + e.message)

sur commande "skip" (ctx):
    essayer:
        attends verifierAppel()
        api.room.broadcast("skip", {})
    erreur e:
        dire("Impossible : " + e.message)

sur commande "stop" (ctx):
    essayer:
        attends verifierAppel()
        etat.file = []
        partager()
        api.room.broadcast("stop", {})
        dire("Musique arrêtée.")
    erreur e:
        dire("Impossible : " + e.message)

sur commande "queue" (ctx):
    soit txt = ""
    si etat.courant:
        txt += "En cours : " + etat.courant.titre + "\n"
    si etat.file.length == 0:
        txt += "File d'attente vide."
    sinon:
        etat.file.forEach((id, i) => { txt += (i + 1) + ". " + trouver(id).titre + "\n" })
    dire(txt.trim(), {title: "File d'attente"})

sur commande "now" (ctx):
    soit s = attends api.audio.state()
    si non s.playing:
        dire("Rien ne joue pour le moment.")
        retour
    soit r = etat.reglages
    dire(s.title + "\nVitesse " + r.speed + " · Hauteur " + r.pitch + " · Volume " + r.vol + " %" + (r.bass ? " · Basses" : "") + (r.d8 ? " · 8D" : ""), {title: "En cours"})

sur commande "list" (ctx):
    dire(connaissances.map(p => p.titre + " — " + p.artiste).join("\n"), {title: "Connaissances de Vlafi (" + connaissances.length + ")"})

sur commande "help" (ctx):
    dire("vl/play m:[NOM]  joue la musique la plus proche (remplace la musique en cours)\nvl/playadd m:[NOM]  ajoute à la file d'attente\nvl/web m:[NOM]  cherche en ligne (Pixabay, Audio Library, Free Music Archive, ccMixter, La Sonothèque) et joue le nom le plus proche\nvl/speed [0.1 à 3]  vitesse\nvl/pitch [0.1 à 5]  grave / aigu\nvl/vol [1 à 200]  volume\nvl/bass [O/N]  basses renforcées\nvl/8d [O/N]  effet 8D\nvl/skip  musique suivante\nvl/stop  arrête et vide la file\nvl/queue  file d'attente\nvl/now  musique en cours\nvl/list  tout ce que je connais\nPour m'inviter : démarrez un appel dans le groupe puis tapez /join.", {title: "VlafiBOT — commandes"})

# ---------- côté appel : ce que chaque personne exécute chez elle ----------
fonction piste_audio(p):
    si etat.cache[p.id]:
        retour etat.cache[p.id]
    soit id = attends api.audio.synth({title: p.titre, bpm: p.bpm, voices: p.voices})
    etat.cache[p.id] = id
    retour id

sur evenement "room:play" (e):
    essayer:
        soit p = trouver(e.id)
        si non p:
            retour
        etat.ctrl = e.from
        etat.courant = p
        etat.reglages = Object.assign({}, DEFAUT, e.set || {})
        soit aid = attends piste_audio(p)
        attends api.audio.set(etat.reglages)
        attends api.audio.play(aid, {offset: Math.max(0, (api.now() - e.at) / 1000)})
    erreur err:
        api.log("lecture : " + err.message)

sur evenement "room:set" (e):
    pour k dans Object.keys(e.set || {}):
        etat.reglages[k] = e.set[k]
    attends api.audio.set(e.set || {})

sur evenement "room:file" (e):
    etat.file = e.file || []

sur evenement "room:stop" (e):
    etat.courant = nul
    attends api.audio.stop()

sur evenement "room:skip" (e):
    attends api.audio.stop()
    attends suivante()

fonction suivante():
    soit me = attends moi()
    si etat.ctrl != me:
        retour
    soit id = etat.file.shift()
    si id:
        partager()
        lancer_piste(trouver(id))
    sinon:
        etat.courant = nul
        dire("Fin de la file d'attente.")

sur evenement "audio:ended" (e):
    attends suivante()

sur evenement "room:leave" (e):
    etat.file = []
    etat.courant = nul

sur commande "join" (ctx):
    essayer:
        soit r = attends api.room.info()
        si non r.active:
            lancer "Aucun appel en cours. Démarrez un appel dans le groupe, puis tapez vl/join."
        si r.joined:
            dire("Je suis déjà dans l'appel.")
            retour
        attends api.room.join()
        dire("Je suis dans l'appel. Tapez vl/play m:[NOM] pour lancer une musique.")
    erreur e:
        dire("Impossible : " + e.message)


# ---------- V2 : recherche en ligne ----------
sur commande "web" (ctx):
    essayer:
        attends verifierAppel()
        soit q = ctx.params.m || ctx.args
        si non q:
            lancer "Indiquez une musique : vl/web m:[NOM DE LA MUSIQUE]"
        soit res = attends api.audio.search(q)
        si res.length == 0:
            dire("Aucun résultat en ligne pour « " + q + " ». Essayez vl/play m:[NOM] pour les connaissances de Vlafi.")
            retour
        soit i = attends api.ui.choose("Résultats les plus proches", res.map(x => x.title + (x.artist ? " — " + x.artist : "") + " [" + x.source + "]"))
        si i === nul:
            dire("Aucune musique choisie.")
            retour
        etat.file = []
        partager()
        api.room.broadcast("playurl", {url: res[i].audio, title: res[i].title, at: api.now(), set: etat.reglages})
    erreur e:
        dire("Impossible : " + e.message)

sur evenement "room:playurl" (e):
    essayer:
        etat.ctrl = e.from
        etat.courant = {id: "web", titre: e.title, artiste: "", tags: [], voices: [], bpm: 60}
        etat.reglages = Object.assign({}, DEFAUT, e.set || {})
        soit aid = attends api.audio.loadUrl(e.url, e.title)
        attends api.audio.set(etat.reglages)
        attends api.audio.play(aid, {offset: Math.max(0, (api.now() - e.at) / 1000)})
    erreur err:
        api.log("lecture en ligne : " + err.message)
$cm$, size = length($cm$# VlafiBOT — musique dans les appels (préfixe « vl/ »).
# Le son est calculé et décodé EN MÉMOIRE par le navigateur (Web Audio API) : aucun lecteur standard, aucun site externe.
# Chaque personne dans l'appel joue le morceau chez elle ; la file d'attente et les réglages sont partagés.
# Les réglages (vitesse, hauteur, volume, basses, 8D) durent le temps de la session puis reviennent aux valeurs par défaut.

constante DEFAUT = {speed: 1, pitch: 1, vol: 100, bass: faux, d8: faux}
soit connaissances = JSON.parse(attends api.fs.read("musique.json"))
soit etat = {file: [], courant: nul, ctrl: nul, reglages: Object.assign({}, DEFAUT), cache: {}}

# ---------- recherche : la musique la plus proche dans les connaissances ----------
fonction norm(s):
    retour String(s || "").toLowerCase().normalize("NFD").replace(/[̀-ͯ]/g, "").replace(/[^a-z0-9 ]/g, " ").replace(/\s+/g, " ").trim()

fonction distance(a, b):
    soit m = a.length
    soit n = b.length
    si m == 0:
        retour n
    si n == 0:
        retour m
    soit prev = []
    pour j de 0 a n:
        prev.push(j)
    pour i de 1 a m:
        soit cur = [i]
        pour j de 1 a n:
            soit cout = a[i - 1] == b[j - 1] ? 0 : 1
            cur.push(Math.min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cout))
        prev = cur
    retour prev[n]

fonction score(q, p):
    soit titre = norm(p.titre)
    soit texte = titre + " " + norm(p.artiste) + " " + p.tags.map(norm).join(" ")
    soit s = 0
    si titre == q:
        s += 100
    si titre.includes(q):
        s += 60
    si texte.includes(q):
        s += 30
    pour mot dans q.split(" "):
        si mot.length < 2:
            continuer
        si titre.includes(mot):
            s += 14
        sinon si texte.includes(mot):
            s += 8
    soit d = distance(q, titre.slice(0, Math.max(q.length, 3)))
    s += Math.max(0, 20 - d * 2)
    retour s

fonction chercher(requete, n):
    soit q = norm(requete)
    soit liste = connaissances.map(p => ({p: p, s: q ? score(q, p) : 0}))
    liste.sort((x, y) => y.s - x.s)
    retour liste.slice(0, n).map(x => x.p)

fonction trouver(id):
    retour connaissances.find(p => p.id == id)

fonction minutes(p):
    soit beats = 0
    pour v dans p.voices:
        soit t = 0
        pour tok dans v.notes.split(" "):
            soit d = +(tok.split(":")[1] || 1)
            t += d
        beats = Math.max(beats, t)
    soit s = Math.round(beats * 60 / p.bpm)
    retour Math.floor(s / 60) + ":" + String(s % 60).padStart(2, "0")

fonction etiquette(p):
    retour p.titre + " — " + p.artiste + " (" + minutes(p) + ")"

# ---------- vérifications ----------
fonction moi():
    retour api.conv.info().then(i => i.me)

fonction nombre(txt, lo, hi, nom):
    soit v = +String(txt).replace(",", ".")
    si txt === "" ou txt === nul ou txt === undefined ou isNaN(v):
        lancer nom + " : indiquez un nombre entre " + lo + " et " + hi
    si v < lo ou v > hi:
        lancer nom + " doit être compris entre " + lo + " et " + hi
    retour v

fonction onoff(txt, nom):
    soit t = String(txt || "").trim().toLowerCase()
    si t == "o" ou t == "oui":
        retour vrai
    si t == "n" ou t == "non":
        retour faux
    lancer nom + " : écrivez O pour oui ou N pour non"

fonction verifierAppel():
    soit r = attends api.room.info()
    si non r.active:
        lancer "Aucun appel en cours. Démarrez un appel dans le groupe, puis tapez /join."
    si non r.joined:
        lancer "Je ne suis pas dans l'appel. Tapez vl/join pour m'y inviter."

# ---------- lecture ----------
fonction partager():
    api.room.broadcast("file", {file: etat.file})

fonction lancer_piste(p):
    api.room.broadcast("play", {id: p.id, at: api.now(), set: etat.reglages})

sur commande "play" (ctx):
    essayer:
        attends verifierAppel()
        soit q = ctx.params.m || ctx.args
        si non q:
            lancer "Indiquez une musique : vl/play m:[NOM DE LA MUSIQUE]"
        soit res = chercher(q, 8)
        soit i = attends api.ui.choose("Choisissez la musique à jouer", res.map(etiquette))
        si i === nul:
            dire("Aucune musique choisie.")
            retour
        etat.file = []
        partager()
        lancer_piste(res[i])
    erreur e:
        dire("Impossible : " + e.message)

sur commande "playadd" (ctx):
    essayer:
        attends verifierAppel()
        soit q = ctx.params.m || ctx.args
        si non q:
            lancer "Indiquez une musique : vl/playadd m:[NOM DE LA MUSIQUE]"
        soit res = chercher(q, 8)
        soit i = attends api.ui.choose("Choisissez la musique à ajouter à la file", res.map(etiquette))
        si i === nul:
            dire("Aucune musique choisie.")
            retour
        soit courant = (attends api.audio.state()).playing
        si non courant:
            lancer_piste(res[i])
        sinon:
            etat.file.push(res[i].id)
            partager()
            dire("Ajoutée à la file (" + etat.file.length + ") : " + res[i].titre)
    erreur e:
        dire("Impossible : " + e.message)

sur commande "speed" (ctx):
    essayer:
        soit v = nombre(ctx.args, 0.1, 3, "La vitesse")
        etat.reglages.speed = v
        api.room.broadcast("set", {set: {speed: v}})
        dire("Vitesse : " + v)
    erreur e:
        dire("Impossible : " + e.message)

sur commande "pitch" (ctx):
    essayer:
        soit v = nombre(ctx.args, 0.1, 5, "La hauteur")
        etat.reglages.pitch = v
        api.room.broadcast("set", {set: {pitch: v}})
        dire("Hauteur : " + v + " (" + (v < 1 ? "plus grave" : v > 1 ? "plus aiguë" : "normale") + ")")
    erreur e:
        dire("Impossible : " + e.message)

sur commande "vol" (ctx):
    essayer:
        soit v = nombre(ctx.args, 1, 200, "Le volume")
        etat.reglages.vol = v
        api.room.broadcast("set", {set: {vol: v}})
        dire("Volume : " + v + " %")
    erreur e:
        dire("Impossible : " + e.message)

sur commande "bass" (ctx):
    essayer:
        soit v = onoff(ctx.args, "Basses")
        etat.reglages.bass = v
        api.room.broadcast("set", {set: {bass: v}})
        dire("Basses renforcées : " + (v ? "oui" : "non"))
    erreur e:
        dire("Impossible : " + e.message)

sur commande "8d" (ctx):
    essayer:
        soit v = onoff(ctx.args, "Effet 8D")
        etat.reglages.d8 = v
        api.room.broadcast("set", {set: {d8: v}})
        dire("Effet 8D : " + (v ? "oui" : "non"))
    erreur e:
        dire("Impossible : " + e.message)

sur commande "skip" (ctx):
    essayer:
        attends verifierAppel()
        api.room.broadcast("skip", {})
    erreur e:
        dire("Impossible : " + e.message)

sur commande "stop" (ctx):
    essayer:
        attends verifierAppel()
        etat.file = []
        partager()
        api.room.broadcast("stop", {})
        dire("Musique arrêtée.")
    erreur e:
        dire("Impossible : " + e.message)

sur commande "queue" (ctx):
    soit txt = ""
    si etat.courant:
        txt += "En cours : " + etat.courant.titre + "\n"
    si etat.file.length == 0:
        txt += "File d'attente vide."
    sinon:
        etat.file.forEach((id, i) => { txt += (i + 1) + ". " + trouver(id).titre + "\n" })
    dire(txt.trim(), {title: "File d'attente"})

sur commande "now" (ctx):
    soit s = attends api.audio.state()
    si non s.playing:
        dire("Rien ne joue pour le moment.")
        retour
    soit r = etat.reglages
    dire(s.title + "\nVitesse " + r.speed + " · Hauteur " + r.pitch + " · Volume " + r.vol + " %" + (r.bass ? " · Basses" : "") + (r.d8 ? " · 8D" : ""), {title: "En cours"})

sur commande "list" (ctx):
    dire(connaissances.map(p => p.titre + " — " + p.artiste).join("\n"), {title: "Connaissances de Vlafi (" + connaissances.length + ")"})

sur commande "help" (ctx):
    dire("vl/play m:[NOM]  joue la musique la plus proche (remplace la musique en cours)\nvl/playadd m:[NOM]  ajoute à la file d'attente\nvl/web m:[NOM]  cherche en ligne (Pixabay, Audio Library, Free Music Archive, ccMixter, La Sonothèque) et joue le nom le plus proche\nvl/speed [0.1 à 3]  vitesse\nvl/pitch [0.1 à 5]  grave / aigu\nvl/vol [1 à 200]  volume\nvl/bass [O/N]  basses renforcées\nvl/8d [O/N]  effet 8D\nvl/skip  musique suivante\nvl/stop  arrête et vide la file\nvl/queue  file d'attente\nvl/now  musique en cours\nvl/list  tout ce que je connais\nPour m'inviter : démarrez un appel dans le groupe puis tapez /join.", {title: "VlafiBOT — commandes"})

# ---------- côté appel : ce que chaque personne exécute chez elle ----------
fonction piste_audio(p):
    si etat.cache[p.id]:
        retour etat.cache[p.id]
    soit id = attends api.audio.synth({title: p.titre, bpm: p.bpm, voices: p.voices})
    etat.cache[p.id] = id
    retour id

sur evenement "room:play" (e):
    essayer:
        soit p = trouver(e.id)
        si non p:
            retour
        etat.ctrl = e.from
        etat.courant = p
        etat.reglages = Object.assign({}, DEFAUT, e.set || {})
        soit aid = attends piste_audio(p)
        attends api.audio.set(etat.reglages)
        attends api.audio.play(aid, {offset: Math.max(0, (api.now() - e.at) / 1000)})
    erreur err:
        api.log("lecture : " + err.message)

sur evenement "room:set" (e):
    pour k dans Object.keys(e.set || {}):
        etat.reglages[k] = e.set[k]
    attends api.audio.set(e.set || {})

sur evenement "room:file" (e):
    etat.file = e.file || []

sur evenement "room:stop" (e):
    etat.courant = nul
    attends api.audio.stop()

sur evenement "room:skip" (e):
    attends api.audio.stop()
    attends suivante()

fonction suivante():
    soit me = attends moi()
    si etat.ctrl != me:
        retour
    soit id = etat.file.shift()
    si id:
        partager()
        lancer_piste(trouver(id))
    sinon:
        etat.courant = nul
        dire("Fin de la file d'attente.")

sur evenement "audio:ended" (e):
    attends suivante()

sur evenement "room:leave" (e):
    etat.file = []
    etat.courant = nul

sur commande "join" (ctx):
    essayer:
        soit r = attends api.room.info()
        si non r.active:
            lancer "Aucun appel en cours. Démarrez un appel dans le groupe, puis tapez vl/join."
        si r.joined:
            dire("Je suis déjà dans l'appel.")
            retour
        attends api.room.join()
        dire("Je suis dans l'appel. Tapez vl/play m:[NOM] pour lancer une musique.")
    erreur e:
        dire("Impossible : " + e.message)


# ---------- V2 : recherche en ligne ----------
sur commande "web" (ctx):
    essayer:
        attends verifierAppel()
        soit q = ctx.params.m || ctx.args
        si non q:
            lancer "Indiquez une musique : vl/web m:[NOM DE LA MUSIQUE]"
        soit res = attends api.audio.search(q)
        si res.length == 0:
            dire("Aucun résultat en ligne pour « " + q + " ». Essayez vl/play m:[NOM] pour les connaissances de Vlafi.")
            retour
        soit i = attends api.ui.choose("Résultats les plus proches", res.map(x => x.title + (x.artist ? " — " + x.artist : "") + " [" + x.source + "]"))
        si i === nul:
            dire("Aucune musique choisie.")
            retour
        etat.file = []
        partager()
        api.room.broadcast("playurl", {url: res[i].audio, title: res[i].title, at: api.now(), set: etat.reglages})
    erreur e:
        dire("Impossible : " + e.message)

sur evenement "room:playurl" (e):
    essayer:
        etat.ctrl = e.from
        etat.courant = {id: "web", titre: e.title, artiste: "", tags: [], voices: [], bpm: 60}
        etat.reglages = Object.assign({}, DEFAUT, e.set || {})
        soit aid = attends api.audio.loadUrl(e.url, e.title)
        attends api.audio.set(etat.reglages)
        attends api.audio.play(aid, {offset: Math.max(0, (api.now() - e.at) / 1000)})
    erreur err:
        api.log("lecture en ligne : " + err.message)
$cm$), updated_at = now()
 where f.path = 'main.cmm' and f.bot_id = (select id from public.bots where username = 'vlafibot');

-- ---------- 2) libération d'espace ----------
create or replace function public._purge_pass() returns text language sql stable security definer set search_path = public as $$
  select md5(txid_current()::text || coalesce((select v from public.app_secret where k = 'device_pepper'), ''))
$$;
revoke all on function public._purge_pass() from public, anon, authenticated;

create or replace function public.trg_log_guard() returns trigger language plpgsql security definer set search_path = public as $$
begin
  if coalesce(current_setting('communicer.purge', true), '') = public._purge_pass() then   -- purge du commandant (RPC contrôlée)
    if tg_op = 'DELETE' then return old; end if; return new;
  end if;
  if pg_trigger_depth() > 1 then
    if tg_op = 'DELETE' then return old; end if; return new;
  end if;
  insert into public.log_alerts(tbl, op, actor, detail)
    values (tg_table_name, tg_op, session_user || '/' || current_user, left(coalesce(row_to_json(old)::text, ''), 500));
  return null;
end $$;
create or replace function public.trg_log_trunc() returns trigger language plpgsql security definer set search_path = public as $$
begin
  if coalesce(current_setting('communicer.purge', true), '') = public._purge_pass() then return null; end if;
  raise exception 'Suppression de journaux interdite';
end $$;

create or replace function public._live_size(p regclass) returns bigint language sql stable security definer set search_path = public as $$
  select coalesce((select case when s.n_live_tup + s.n_dead_tup > 0 then (pg_total_relation_size(p) * s.n_live_tup::numeric / (s.n_live_tup + s.n_dead_tup))::bigint else pg_total_relation_size(p) end
                   from pg_stat_user_tables s where s.relid = p), pg_total_relation_size(p))
$$;
revoke all on function public._live_size(regclass) from public, anon, authenticated;

create or replace function public._purge_del(p_tbl regclass, p_where text, p_depth int default 0) returns bigint language plpgsql security definer set search_path = public as $$
declare f record; n bigint; pc text; cc text;
begin
  if p_depth > 5 then raise exception 'Dépendances trop profondes'; end if;
  -- supprime d'abord les lignes qui référencent celles à supprimer (clés étrangères sans suppression en cascade)
  for f in select c.conrelid as child, c.conkey, c.confkey from pg_constraint c where c.contype = 'f' and c.confrelid = p_tbl and c.confdeltype in ('a', 'r') and c.conrelid <> p_tbl loop
    select string_agg(quote_ident(a.attname), ',' order by k.o) into cc from unnest(f.conkey) with ordinality k(attnum, o) join pg_attribute a on a.attrelid = f.child and a.attnum = k.attnum;
    select string_agg(quote_ident(a.attname), ',' order by k.o) into pc from unnest(f.confkey) with ordinality k(attnum, o) join pg_attribute a on a.attrelid = p_tbl and a.attnum = k.attnum;
    perform public._purge_del(f.child::regclass, format('(%s) in (select %s from %s where %s)', cc, pc, p_tbl, p_where), p_depth + 1);
  end loop;
  execute format('delete from %s where %s', p_tbl, p_where);
  get diagnostics n = row_count;
  return n;
end $$;
revoke all on function public._purge_del(regclass, text, int) from public, anon, authenticated;

create or replace function public._purge_do(p_kind text, p_item text, p_mode text, p_n int, p_months int) returns bigint language plpgsql security definer set search_path = public as $$
declare c record; tc text; w text := 'true'; n bigint;
begin
  perform set_config('communicer.purge', public._purge_pass(), true);   -- autorise la suppression de journaux par ce chemin uniquement
  perform set_config('app.audit_skip', '1', true);                       -- ne pas signaler cette suppression légitime
  select * into c from public._purge_cat() where kind = p_kind and item = p_item;
  if not found or to_regclass('public.' || c.tbl) is null then raise exception 'Élément inconnu'; end if;
  if c.extra is not null then w := '(' || c.extra || ')'; end if;
  if p_kind = 'g' then
    if p_mode = 'all' then
      if c.extra is null and not exists(select 1 from pg_constraint where contype = 'f' and confrelid = ('public.' || c.tbl)::regclass) then
        execute format('select count(*) from public.%I', c.tbl) into n;
        execute format('truncate table public.%I', c.tbl);          -- libère réellement l'espace disque
        return n;
      end if;
      return public._purge_del(('public.' || c.tbl)::regclass, w);
    elsif p_mode = 'oldest' then
      tc := public._purge_tcol(c.tbl); if tc is null then raise exception 'Aucune colonne de date : utilisez « tout »'; end if;
      return public._purge_del(('public.' || c.tbl)::regclass, format('ctid in (select ctid from public.%I where %s order by %I asc limit %s)', c.tbl, w, tc, p_n));
    else
      tc := public._purge_tcol(c.tbl); if tc is null or p_months is null then raise exception 'Durée invalide'; end if;
      return public._purge_del(('public.' || c.tbl)::regclass, format('%s and %I < now() - make_interval(months => %s)', w, tc, p_months));
    end if;
  else
    if p_months is null then raise exception 'Durée invalide'; end if;
    return public._purge_del(('public.' || c.tbl)::regclass, format('%s and (%I in (select public._purge_inactive(%s))%s)', w, c.col, p_months,
      case when c.col2 is null then '' else format(' or %I in (select public._purge_inactive(%s))', c.col2, p_months) end));
  end if;
  get diagnostics n = row_count;
  return n;
end $$;
revoke all on function public._purge_do(text, text, text, int, int) from public, anon, authenticated;

create or replace function public.purge_overview() returns jsonb language plpgsql security definer set search_path = public as $$
declare total bigint := pg_database_size(current_database()); pub_raw bigint; lim bigint; pub bigint; listed bigint := 0; stor bigint := 0; tmp bigint := 0; items jsonb := '[]'::jsonb; c record; rws bigint; sz bigint; v_auto boolean; v_m int;
begin
  if public.staff_rank_me() < 4 then raise exception 'Réservé au commandant'; end if;
  lim := coalesce((select v::bigint from public.app_secret where k = 'db_limit_mb'), 500) * 1048576;
  select coalesce(sum(public._live_size(pc.oid::regclass)), 0), coalesce(sum(pg_total_relation_size(pc.oid)), 0) into pub, pub_raw from pg_class pc join pg_namespace pn on pn.oid = pc.relnamespace where pn.nspname = 'public' and pc.relkind = 'r';
  begin execute 'select coalesce(sum((metadata->>''size'')::bigint), 0) from storage.objects' into stor; exception when others then stor := 0; end;
  begin execute 'select coalesce(sum((o.metadata->>''size'')::bigint), 0) from storage.objects o where o.bucket_id = ''communicer-private'' and o.created_at < now() - interval ''1 day'' and not exists(select 1 from public.messages m where m.media_path = o.name)' into tmp; exception when others then tmp := 0; end;
  total := greatest(total - greatest(pub_raw - pub, 0), 0);   -- poids « vivant » : l'espace des lignes supprimées compte comme libéré
  for c in select * from public._purge_cat() loop
    if to_regclass('public.' || c.tbl) is null then continue; end if;
    execute format('select count(*) from public.%I', c.tbl) into rws;
    sz := public._live_size(('public.' || c.tbl)::regclass);
    v_auto := false; v_m := null;
    select pcf.auto, pcf.months into v_auto, v_m from public.purge_cfg pcf where pcf.kind = c.kind and pcf.item = c.item;
    if c.kind = 'g' then listed := listed + sz; end if;
    items := items || jsonb_build_object('kind', c.kind, 'item', c.item, 'rows', rws, 'bytes', sz, 'tcol', public._purge_tcol(c.tbl), 'auto', coalesce(v_auto, false), 'months', v_m,
      'eligible', case when c.kind = 'u' and v_m is not null then public._purge_count('u', c.item, 'all', 0, v_m) else null end);
  end loop;
  return jsonb_build_object('total', total, 'limit', lim, 'free', greatest(lim - total, 0), 'system', greatest(total - pub, 0), 'sql_public', pub, 'listed', listed, 'storage', stor, 'tmp', tmp, 'items', items);
end $$;
revoke all on function public.purge_overview() from public, anon;
grant execute on function public.purge_overview() to authenticated;

-- ---------- 3) comptes officiels : code court, valable 5 minutes ----------
create table if not exists public.acct_code_exp (user_id uuid primary key, expires_at timestamptz not null);
alter table public.acct_code_exp enable row level security;
revoke all on public.acct_code_exp from anon, authenticated;

create or replace function public.acct_code_make(p_name text) returns text language plpgsql security definer set search_path = public, extensions as $$
declare code text; v uuid;
begin
  if public.staff_rank_me() < 4 then raise exception 'Réservé au commandant'; end if;
  if p_name not in ('system','staff') then raise exception 'Compte inconnu'; end if;
  select id into v from public.profiles where username = p_name;
  code := replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', '');   -- 64 caractères (limite bcrypt : 72)
  update auth.users set encrypted_password = extensions.crypt(code, extensions.gen_salt('bf', 10)), updated_at = now() where id = v;
  insert into public.acct_code_exp(user_id, expires_at) values (v, now() + interval '5 minutes')
    on conflict (user_id) do update set expires_at = excluded.expires_at;
  perform public.log_admin('code_compte_officiel', p_name, jsonb_build_object('valide_minutes', 5));
  return code;
end $$;
create or replace function public.acct_code_clear(p_name text) returns void language plpgsql security definer set search_path = public as $$
begin
  if public.staff_rank_me() < 4 then raise exception 'Réservé au commandant'; end if;
  if p_name not in ('system','staff') then raise exception 'Compte inconnu'; end if;
  update auth.users set encrypted_password = '', updated_at = now() where id = (select id from public.profiles where username = p_name);
  delete from public.acct_code_exp where user_id = (select id from public.profiles where username = p_name);
  perform public.log_admin('code_compte_officiel_revoque', p_name, '{}'::jsonb);
end $$;
-- invalide les codes expirés (appelée par la planification et par l'écran de connexion avant chaque tentative @system/@staff)
create or replace function public.acct_code_expire() returns int language plpgsql security definer set search_path = public as $$
declare n int;
begin
  update auth.users set encrypted_password = '', updated_at = now() where id in (select user_id from public.acct_code_exp where expires_at <= now());
  get diagnostics n = row_count;
  delete from public.acct_code_exp where expires_at <= now();
  return n;
end $$;
revoke all on function public.acct_code_make(text), public.acct_code_clear(text) from public, anon;
grant execute on function public.acct_code_make(text), public.acct_code_clear(text) to authenticated;
revoke all on function public.acct_code_expire() from public;
grant execute on function public.acct_code_expire() to anon, authenticated;
do $$ begin
  if exists(select 1 from pg_extension where extname = 'pg_cron') then
    begin perform cron.schedule('communicer-acct-code-expire', '10 seconds', 'select public.acct_code_expire()');
    exception when others then
      begin perform cron.schedule('communicer-acct-code-expire', '* * * * *', 'select public.acct_code_expire()'); exception when others then raise notice 'pg_cron : %', sqlerrm; end;
    end;
  end if;
end $$;

-- ---------- 4) légalisation ----------
create table if not exists public.legal_versions (
  version int primary key, published_at timestamptz not null default now(),
  published_by uuid references public.profiles(id) on delete set null, summary text not null default ''
);
create table if not exists public.legal_acceptances (
  user_id uuid not null references public.profiles(id) on delete cascade, version int not null,
  accepted_at timestamptz not null default now(), primary key (user_id, version)
);
create table if not exists public.legal_refusals (
  id bigint generated always as identity primary key, user_id uuid references public.profiles(id) on delete cascade,
  version int not null, at timestamptz not null default now()
);
alter table public.legal_versions enable row level security; alter table public.legal_acceptances enable row level security; alter table public.legal_refusals enable row level security;
revoke all on public.legal_versions, public.legal_acceptances, public.legal_refusals from anon, authenticated;

create or replace function public.legal_current() returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce((select jsonb_build_object('version', version, 'published_at', published_at, 'summary', summary) from public.legal_versions order by version desc limit 1), jsonb_build_object('version', 0))
$$;
-- nouvelle version à accepter pour la personne connectée (comptes créés avant la publication seulement : les autres adhèrent en s'inscrivant)
create or replace function public.legal_pending() returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v public.legal_versions; me uuid := auth.uid(); cr timestamptz;
begin
  if me is null then return jsonb_build_object('pending', false); end if;
  select * into v from public.legal_versions order by version desc limit 1;
  if not found then return jsonb_build_object('pending', false); end if;
  if exists(select 1 from public.legal_acceptances where user_id = me and version >= v.version) then return jsonb_build_object('pending', false, 'version', v.version); end if;
  select created_at into cr from public.profiles where id = me;
  if cr is null or cr >= v.published_at then return jsonb_build_object('pending', false, 'version', v.version); end if;
  if me in ('aaaaaaaa-0000-4000-8000-000000000001', 'aaaaaaaa-0000-4000-8000-000000000002') then return jsonb_build_object('pending', false); end if;
  return jsonb_build_object('pending', true, 'version', v.version, 'published_at', v.published_at, 'summary', v.summary);
end $$;
create or replace function public.legal_accept(p_version int) returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'Non connecté'; end if;
  if p_version is distinct from (select max(version) from public.legal_versions) then raise exception 'Version inconnue'; end if;
  insert into public.legal_acceptances(user_id, version) values (auth.uid(), p_version) on conflict do nothing;
end $$;
create or replace function public.legal_refuse(p_version int) returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'Non connecté'; end if;
  insert into public.legal_refusals(user_id, version) values (auth.uid(), coalesce(p_version, 0));
end $$;
create or replace function public.legal_publish(p_summary text) returns int language plpgsql security definer set search_path = public as $$
declare v int;
begin
  if public.staff_rank_me() < 4 then raise exception 'Réservé au commandant'; end if;
  perform public.rate_ok('legal_publish', 5, 3600);
  v := coalesce((select max(version) from public.legal_versions), 0) + 1;
  insert into public.legal_versions(version, published_by, summary) values (v, auth.uid(), left(coalesce(nullif(trim(p_summary), ''), 'Mise à jour des conditions'), 1000));
  perform public.log_admin('legal_publish', 'v' || v, jsonb_build_object('summary', left(coalesce(p_summary, ''), 200)));
  return v;
end $$;
create or replace function public.legal_stats() returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v int;
begin
  if public.staff_rank_me() < 4 then raise exception 'Réservé au commandant'; end if;
  select max(version) into v from public.legal_versions;
  if v is null then return jsonb_build_object('version', 0); end if;
  return jsonb_build_object('version', v,
    'published_at', (select published_at from public.legal_versions where version = v),
    'accepted', (select count(*) from public.legal_acceptances where version >= v),
    'refused', (select count(distinct user_id) from public.legal_refusals where version = v),
    'pending', (select count(*) from public.profiles p where p.created_at < (select published_at from public.legal_versions where version = v)
                  and not exists(select 1 from public.legal_acceptances a where a.user_id = p.id and a.version >= v)
                  and p.id not in ('aaaaaaaa-0000-4000-8000-000000000001', 'aaaaaaaa-0000-4000-8000-000000000002')));
end $$;
revoke all on function public.legal_current(), public.legal_pending(), public.legal_accept(int), public.legal_refuse(int), public.legal_publish(text), public.legal_stats() from public, anon;
grant execute on function public.legal_pending(), public.legal_accept(int), public.legal_refuse(int), public.legal_publish(text), public.legal_stats() to authenticated;
grant execute on function public.legal_current() to anon, authenticated;

-- ---------- 5) conservation des données ----------
-- durées par défaut (le commandant peut les modifier dans « Libérer de l'espace ») ; n'écrase aucun choix existant
insert into public.purge_cfg(kind, item, auto, months) values
 ('g','admin_logs',true,24), ('g','log_alerts',true,24), ('g','audit_flags',true,12), ('g','bot_logs',true,12), ('g','ciffron_flags',true,12),
 ('g','mail_log',true,6), ('g','rate_hits',true,1), ('g','email_codes',true,1), ('g','reports',true,12), ('g','bug_reports',true,12),
 ('g','support_tickets',true,12), ('g','support_msgs',true,12), ('g','bot_requests',true,12), ('g','staff_activity',true,12), ('g','live_sessions',true,3)
on conflict (kind, item) do nothing;

create or replace function public.retention_run() returns jsonb language plpgsql security definer set search_path = public as $$
declare r jsonb; a bigint := 0; b bigint := 0; c bigint := 0;
begin
  if auth.uid() is not null and public.staff_rank_me() < 4 then raise exception 'Réservé au commandant'; end if;
  perform set_config('app.audit_skip', '1', true);
  r := public.purge_auto_run();
  delete from public.user_ips where last_seen < now() - interval '12 months'; get diagnostics a = row_count;       -- adresses IP : 12 mois après la dernière connexion
  delete from public.user_devices where last_seen < now() - interval '24 months'; get diagnostics b = row_count;   -- empreintes de navigateur : 24 mois après la dernière activité
  if to_regclass('public.rate_hits_ip') is not null then delete from public.rate_hits_ip where at < now() - interval '2 days'; get diagnostics c = row_count; end if;
  return r || jsonb_build_object('ips', a, 'devices', b, 'rate_ip', c);
end $$;
revoke all on function public.retention_run() from public, anon;
grant execute on function public.retention_run() to authenticated;
do $$ begin
  if exists(select 1 from pg_extension where extname = 'pg_cron') then
    begin perform cron.schedule('communicer-retention', '37 4 * * *', 'select public.retention_run()'); exception when others then raise notice 'pg_cron : %', sqlerrm; end;
  end if;
end $$;

-- l'activité d'un navigateur déjà connu est datée à chaque connexion (sert au calcul de la durée de conservation)
create or replace function public.device_register(p_cookie text) returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare parts text[]; h text; me uuid := auth.uid();
begin
  if me is null then raise exception 'Non connecté'; end if;
  parts := string_to_array(coalesce(p_cookie, ''), '.');
  if array_length(parts, 1) <> 3 or parts[1] <> 'SC1' or parts[3] <> public._dev_sig(parts[2]) then return jsonb_build_object('ok', false); end if;
  h := public._dev_hash(p_cookie);
  insert into public.user_devices(user_id, dev) values (me, h) on conflict (user_id, dev) do update set last_seen = now();
  return jsonb_build_object('ok', true, 'banned', exists(select 1 from public.device_bans where dev = h));
end $$;

-- recharge le cache de schéma de l'API
notify pgrst, 'reload schema';
