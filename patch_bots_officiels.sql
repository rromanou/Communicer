-- Bots officiels : LibonBOT et VlafiBOT (propriétaire @rhum). Relançable : met à jour le code à chaque exécution.

insert into public.bots(name,username,prefix,description,owner_username,visibility,official,perms,commands,notes)
values ('Libon','libonbot','!',$cm$Le bot officiel de Communicer! : gestion du groupe, bannissements, pause des jeux. Toujours présent dans les groupes.$cm$,'rhum','public',true,array['msg.send','call.join','game.control','group.manage','msg.delete','ui.html','bypass','files.write']::text[],$cm$[{"cmd": "!help", "usage": "!help", "desc": "liste des commandes"}, {"cmd": "!add", "usage": "!add [UTILISATEUR]", "desc": "ajoute une personne (ami) ou un bot au groupe"}, {"cmd": "!del", "usage": "!del [UTILISATEUR]", "desc": "retire une personne du groupe"}, {"cmd": "!del msg:", "usage": "!del msg:[NUMÉRO]", "desc": "supprime un message du groupe"}, {"cmd": "!adm", "usage": "!adm [UTILISATEUR]", "desc": "donne ou retire le rôle d'administrateur"}, {"cmd": "!rename", "usage": "!rename [NOM]", "desc": "renomme le groupe"}, {"cmd": "!droit", "usage": "!droit [UTILISATEUR]", "desc": "donne ou retire le droit d'utiliser les commandes"}, {"cmd": "!print", "usage": "!print", "desc": "informations du serveur"}, {"cmd": "!ban", "usage": "!ban u:[UTILISATEUR] t:[SECONDES]", "desc": "bannit une personne (0 = sans limite)"}, {"cmd": "!deban", "usage": "!deban [UTILISATEUR]", "desc": "lève un bannissement"}, {"cmd": "!banlist", "usage": "!banlist", "desc": "liste des personnes bannies"}, {"cmd": "!cj", "usage": "!cj [UTILISATEUR]", "desc": "casier : bannissements, retraits, suppressions, droits"}, {"cmd": "!kick", "usage": "!kick [UTILISATEUR]", "desc": "exclut quelqu'un d'un appel ou d'un jeu"}, {"cmd": "!pause", "usage": "!pause [SECONDES]", "desc": "met le jeu en pause (60 s maximum)"}, {"cmd": "!fpause", "usage": "!fpause [o/n]", "desc": "bouton de pause pour tout le monde"}, {"cmd": "!bypass", "usage": "!bypass [o/n]", "desc": "débloque tous les jeux dans ce groupe"}, {"cmd": "!mp", "usage": "/mp u:[UTILISATEUR] m:[MESSAGE]", "desc": "message privé : seule cette personne le voit."}]$cm$::jsonb,$cm$Version initiale.$cm$)
on conflict (username) do update set description=excluded.description, perms=excluded.perms, commands=excluded.commands, notes=excluded.notes, official=true, status='active', updated_at=now();
update public.bots set owner_id=(select id from public.profiles where username='rhum') where username='libonbot' and owner_id is null;
delete from public.bot_files where bot_id=(select id from public.bots where username='libonbot') and not runtime;
insert into public.bot_files(bot_id,path,content,size) select id,'bot.json',$cm${"name":"Libon","entry":["main.cmm","pause.cmm","bypass.cmm"],"version":1}
$cm$,75 from public.bots where username='libonbot' on conflict (bot_id,path) do update set content=excluded.content,size=excluded.size,updated_at=now(),runtime=false;
insert into public.bot_files(bot_id,path,content,size) select id,'bypass.cmm',$cm$# /bypass — débloque tous les jeux du Bloc-note, des groupes et des conversations pour CE groupe.
# Sécurité en couches :
#   1. seul un administrateur du groupe peut l'activer (contrôle SERVEUR dans libon_do),
#   2. l'état est enregistré côté serveur (persistant, visible de tous les membres),
#   3. chaque activation est inscrite au casier (user.txt du serveur),
#   4. à l'ouverture de la conversation et à chaque appel, l'état est relu depuis le serveur :
#      un message falsifié ne peut pas débloquer plus que ce que le serveur a accordé.

soit etatBypass = faux

fonction lire(arg):
    soit a = (arg || "").trim().toLowerCase()
    si a == "n" ou a == "non" ou a == "0":
        retour faux
    retour vrai

fonction resume(jeux):
    soit n = jeux.length
    soit solo = jeux.filter(g => g.conv.length == 1 && g.conv[0] == "self").length
    retour n + " jeux disponibles dont " + solo + " jeux solo jouables ici."

sur commande "bypass" (ctx):
    essayer:
        soit voulu = lire(ctx.args)
        soit reel = attends api.group.bypass(voulu)
        etatBypass = reel
        attends api.conv.bypass(reel)
        si reel:
            soit jeux = attends api.game.list()
            attends api.group.note("bypass", ctx.user, "jeux débloqués")
            dire("Tous les jeux sont débloqués dans ce groupe. " + resume(jeux), {fx: {bypass: vrai}})
        sinon:
            dire("Les jeux sont de nouveau limités à leur configuration normale.", {fx: {bypass: faux}})
    erreur e:
        dire("Impossible : " + e.message)

sur evenement "demarrage" (e):
    soit s = attends api.store.get("bypass")
    etatBypass = s == vrai
    attends api.conv.bypass(etatBypass)
$cm$,1706 from public.bots where username='libonbot' on conflict (bot_id,path) do update set content=excluded.content,size=excluded.size,updated_at=now(),runtime=false;
insert into public.bot_files(bot_id,path,content,size) select id,'main.cmm',$cm$# LibonBOT — bot officiel de Communicer! (préfixe « ! »)
# Toutes les commandes s'exécutent avec les droits de la personne qui les écrit :
# le serveur vérifie qu'elle est administratrice ou qu'elle a reçu le droit (!droit).

fonction cible(ctx):
    si ctx.params.u:
        retour ctx.params.u
    retour ctx.args.split(" ")[0]

fonction quand(d):
    si non d:
        retour "—"
    retour nouveau Date(d).toLocaleString("fr-CA")

fonction temps(s):
    si +s == 0:
        retour "sans limite de temps"
    retour s + " s"

sur commande "help" (ctx):
    dire("!add [UTILISATEUR]  ajoute une personne (vous devez être ami(e) avec elle) ou un bot\n!del [UTILISATEUR]  retire une personne du groupe\n!del msg:[NUMÉRO]  supprime un message du groupe\n!adm [UTILISATEUR]  donne ou retire le rôle d'administrateur\n!rename [NOM]  renomme le groupe\n!droit [UTILISATEUR]  donne ou retire le droit d'utiliser les commandes\n!print  informations du serveur\n!ban u:[UTILISATEUR] t:[SECONDES]  bannit (0 = sans limite)\n!deban [UTILISATEUR]  lève un bannissement\n!banlist  liste des bannis\n!cj [UTILISATEUR]  casier : bannissements, retraits, suppressions, droits\n!kick [UTILISATEUR]  exclut d'un appel ou d'un jeu\n!pause [SECONDES]  met le jeu en pause (60 s maximum)\n!fpause [o/n]  ajoute un bouton de pause pour tout le monde\n!bypass [o/n]  débloque tous les jeux dans ce groupe", {title: "LibonBOT — commandes"})

sur commande "add" (ctx):
    essayer:
        soit r = attends api.group.add(cible(ctx))
        dire(r)
    erreur e:
        dire("Impossible : " + e.message)

sur commande "del" (ctx):
    essayer:
        si ctx.params.msg:
            dire(attends api.group.delmsg(ctx.params.msg))
        sinon:
            dire(attends api.group.del(cible(ctx)))
    erreur e:
        dire("Impossible : " + e.message)

sur commande "adm" (ctx):
    essayer:
        dire(attends api.group.adm(cible(ctx)))
    erreur e:
        dire("Impossible : " + e.message)

sur commande "rename" (ctx):
    essayer:
        dire(attends api.group.rename(ctx.args))
    erreur e:
        dire("Impossible : " + e.message)

sur commande "droit" (ctx):
    essayer:
        dire(attends api.group.droit(cible(ctx)))
    erreur e:
        dire("Impossible : " + e.message)

sur commande "ban" (ctx):
    essayer:
        soit u = cible(ctx)
        soit t = +(ctx.params.t || 0)
        si t < 0:
            lancer "La durée doit être positive"
        dire(attends api.group.ban(u, t))
    erreur e:
        dire("Impossible : " + e.message)

sur commande "deban" (ctx):
    essayer:
        dire(attends api.group.deban(cible(ctx)))
    erreur e:
        dire("Impossible : " + e.message)

sur commande "banlist" (ctx):
    essayer:
        soit rows = attends api.group.banlist()
        si rows.length == 0:
            dire("Personne n'est banni.")
            retour
        soit txt = ""
        pour r dans rows:
            txt += "@" + r.user + " — " + temps(r.seconds) + " (depuis le " + quand(r.at) + ")\n"
        dire(txt.trim(), {title: "Bannis (" + rows.length + ")"})
    erreur e:
        dire("Impossible : " + e.message)

sur commande "cj" (ctx):
    essayer:
        soit u = cible(ctx)
        soit rows = attends api.group.cj(u)
        si rows.length == 0:
            dire("Casier vide pour @" + u + ".")
            retour
        soit txt = ""
        pour r dans rows:
            txt += quand(r.at) + " — " + r.action + (r.detail ? " (" + r.detail + ")" : "") + " par @" + r.by + "\n"
        dire(txt.trim(), {title: "Casier de @" + u})
    erreur e:
        dire("Impossible : " + e.message)

sur commande "print" (ctx):
    essayer:
        soit i = attends api.group.print()
        soit txt = "Serveur " + i.server + "\nNom : " + (i.name || "groupe") + "\nBots : " + i.bots.join(", ") + "\nMembres :\n"
        pour m dans i.members:
            txt += "  @" + m.user + (m.role == "admin" ? " (admin)" : "") + (m.right ? " (droit)" : "") + "\n"
        dire(txt.trim(), {title: "Informations"})
    erreur e:
        dire("Impossible : " + e.message)

sur commande "kick" (ctx):
    essayer:
        soit u = cible(ctx)
        attends api.game.kick(u)
        attends api.group.note("kick", u, "exclu de l'appel ou du jeu")
        dire("@" + u + " a été exclu de l'activité en cours.")
    erreur e:
        dire("Impossible : " + e.message)

# Message privé : /mp u:[UTILISATEUR] m:[MESSAGE]
# Le serveur envoie le message à cette seule personne (et à vous) puis supprime tout de suite votre commande du groupe.
# Aucune réponse publique n'est écrite : personne d'autre ne sait qui écrit à qui.
sur commande "mp" (ctx):
    essayer:
        soit u = ctx.params.u
        soit m = ctx.params.m
        si non u ou non m:
            lancer "Utilisation : /mp u:[UTILISATEUR] m:[MESSAGE]"
        attends api.group.mp(u, m, ctx.msgid)
        api.ui.toast("Message privé envoyé à @" + u.replace("@", ""))
    erreur e:
        api.ui.toast("Impossible : " + e.message)
$cm$,5040 from public.bots where username='libonbot' on conflict (bot_id,path) do update set content=excluded.content,size=excluded.size,updated_at=now(),runtime=false;
insert into public.bot_files(bot_id,path,content,size) select id,'pause.cmm',$cm$# Pause des jeux et des appels — toute la logique est ici, en CMM.
# L'interface (bouton en haut à droite) est dans pause.html.
# Pendant la pause : plus personne ne touche au jeu, les minuteries, le jeu et les bots s'arrêtent ;
# on peut seulement parler et utiliser sa caméra. Durée maximale : 60 secondes.

constante MAX_PAUSE = 60
soit etat = {pause: faux, par: nul}

fonction duree(n):
    n = +n
    si non (n > 0):
        retour 30
    retour Math.min(n, MAX_PAUSE)

sur commande "pause" (ctx):
    essayer:
        soit ok = attends api.room.can(ctx.user)
        si non ok:
            dire("Vous n'avez pas le droit d'utiliser cette commande.")
            retour
        soit n = duree(ctx.args)
        api.room.broadcast("pause", {by: ctx.user, secs: n})
        attends api.group.note("pause", ctx.user, n + " s")
        dire("@" + ctx.user + " a mis le jeu en pause (" + n + " s maximum).")
    erreur e:
        dire("Impossible : " + e.message)

sur commande "fpause" (ctx):
    essayer:
        soit on = (ctx.args || "").trim().toLowerCase() == "o"
        soit r = attends api.group.fpause(on)
        essayer:
            api.room.broadcast("fpause", {on: r})
        erreur e2:
            api.log("pas d'appel en cours")
        dire(r ? "Le bouton de pause est maintenant disponible pour tout le monde." : "Le bouton de pause est désactivé.")
    erreur e:
        dire("Impossible : " + e.message)

sur evenement "room:open" (e):
    soit on = attends api.store.get("fpause")
    api.ui.show("pause-btn", on == vrai)

sur evenement "room:fpause" (e):
    api.ui.show("pause-btn", e.on == vrai)

# Un client reçoit « pause » : il vérifie auprès du serveur que l'auteur y avait droit.
sur evenement "room:pause" (e):
    soit ok = attends api.room.can(e.from, "pause")
    si non ok:
        api.log("pause refusée pour " + e.from)
        retour
    etat.pause = vrai
    etat.par = e.by
    api.game.freeze(duree(e.secs), e.by)
    api.ui.set("pause-lbl", "Reprendre")

sur evenement "room:unpause" (e):
    soit ok = attends api.room.can(e.from, "pause")
    si non ok:
        retour
    api.game.unfreeze()

sur evenement "room:unfrozen" (e):
    etat.pause = faux
    api.ui.set("pause-lbl", "Pause")

# Bouton « Pause » (tout le monde, si !fpause o) : met en pause ou reprend.
sur clic "pause-btn" (e):
    essayer:
        si etat.pause:
            api.room.broadcast("unpause", {by: e.user})
            attends api.group.note("fin de pause", e.user, "reprise manuelle")
        sinon:
            api.room.broadcast("pause", {by: e.user, secs: MAX_PAUSE})
            attends api.group.note("pause", e.user, MAX_PAUSE + " s maximum")
    erreur err:
        api.ui.toast(err.message)
$cm$,2736 from public.bots where username='libonbot' on conflict (bot_id,path) do update set content=excluded.content,size=excluded.size,updated_at=now(),runtime=false;
insert into public.bot_files(bot_id,path,content,size) select id,'pause.css',$cm$.pausebtn{display:inline-flex;align-items:center;gap:6px;background:#ffb703;color:#2b1d00;border-radius:10px;padding:6px 12px;font-weight:700}
$cm$,143 from public.bots where username='libonbot' on conflict (bot_id,path) do update set content=excluded.content,size=excluded.size,updated_at=now(),runtime=false;
insert into public.bot_files(bot_id,path,content,size) select id,'pause.html',$cm$<!-- Interface ajoutée à l'appel : bouton de pause en haut à droite (caché tant que !fpause n'est pas activé) -->
<template data-slot="call-top">
  <button class="rbtn pausebtn" id="pause-btn" data-bot-click="pause-btn" style="display:none" title="Mettre le jeu en pause ou le reprendre">
    <svg viewBox="0 0 24 24" width="18" height="18" fill="currentColor"><rect x="6" y="5" width="4" height="14" rx="1"/><rect x="14" y="5" width="4" height="14" rx="1"/></svg>
    <span id="pause-lbl">Pause</span>
  </button>
</template>
$cm$,532 from public.bots where username='libonbot' on conflict (bot_id,path) do update set content=excluded.content,size=excluded.size,updated_at=now(),runtime=false;

insert into public.bots(name,username,prefix,description,owner_username,visibility,official,perms,commands,notes)
values ('Vlafi','vlafibot','vl/',$cm$Fait jouer de la musique dans les appels du groupe : recherche, file d'attente, vitesse, hauteur, volume, basses et 8D.$cm$,'rhum','public',true,array['msg.send','call.join','audio.play']::text[],$cm$[{"cmd": "vl/play", "usage": "vl/play m:[VOTRE MUSIQUE]", "desc": "fais jouer la musique."}, {"cmd": "vl/playadd", "usage": "vl/playadd m:[VOTRE MUSIQUE]", "desc": "ajoute la musique à la file d'attente."}, {"cmd": "vl/help", "usage": "vl/help", "desc": "liste des commandes."}, {"cmd": "vl/speed", "usage": "vl/speed [0.1 à 3]", "desc": "change la vitesse de la musique."}, {"cmd": "vl/pitch", "usage": "vl/pitch [0.1 à 5]", "desc": "rend la musique plus grave ou plus aiguë."}, {"cmd": "vl/vol", "usage": "vl/vol [1 à 200]", "desc": "change le volume."}, {"cmd": "vl/bass", "usage": "vl/bass [O/N]", "desc": "renforce les basses."}, {"cmd": "vl/8d", "usage": "vl/8d [O/N]", "desc": "active l'effet 8D."}, {"cmd": "vl/skip", "usage": "vl/skip", "desc": "passe à la musique suivante."}, {"cmd": "vl/stop", "usage": "vl/stop", "desc": "arrête la musique et vide la file."}, {"cmd": "vl/queue", "usage": "vl/queue", "desc": "affiche la file d'attente."}, {"cmd": "vl/now", "usage": "vl/now", "desc": "affiche la musique en cours."}, {"cmd": "vl/list", "usage": "vl/list", "desc": "liste tout ce que Vlafi connaît."}]$cm$::jsonb,$cm$Version initiale.$cm$)
on conflict (username) do update set description=excluded.description, perms=excluded.perms, commands=excluded.commands, notes=excluded.notes, official=true, status='active', updated_at=now();
update public.bots set owner_id=(select id from public.profiles where username='rhum') where username='vlafibot' and owner_id is null;
delete from public.bot_files where bot_id=(select id from public.bots where username='vlafibot') and not runtime;
insert into public.bot_files(bot_id,path,content,size) select id,'bot.json',$cm${"name":"Vlafi","entry":["main.cmm"],"version":1}
$cm$,50 from public.bots where username='vlafibot' on conflict (bot_id,path) do update set content=excluded.content,size=excluded.size,updated_at=now(),runtime=false;
insert into public.bot_files(bot_id,path,content,size) select id,'main.cmm',$cm$# VlafiBOT — musique dans les appels (préfixe « vl/ »).
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
        lancer "Je ne suis pas dans l'appel. Tapez /join pour m'y inviter."

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
    dire("vl/play m:[NOM]  joue la musique la plus proche (remplace la musique en cours)\nvl/playadd m:[NOM]  ajoute à la file d'attente\nvl/speed [0.1 à 3]  vitesse\nvl/pitch [0.1 à 5]  grave / aigu\nvl/vol [1 à 200]  volume\nvl/bass [O/N]  basses renforcées\nvl/8d [O/N]  effet 8D\nvl/skip  musique suivante\nvl/stop  arrête et vide la file\nvl/queue  file d'attente\nvl/now  musique en cours\nvl/list  tout ce que je connais\nPour m'inviter : démarrez un appel dans le groupe puis tapez /join.", {title: "VlafiBOT — commandes"})

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
$cm$,9893 from public.bots where username='vlafibot' on conflict (bot_id,path) do update set content=excluded.content,size=excluded.size,updated_at=now(),runtime=false;
insert into public.bot_files(bot_id,path,content,size) select id,'musique.json',$cm$[
{
"id": "ode",
"titre": "Ode à la joie",
"artiste": "Beethoven",
"tags": [
"beethoven",
"classique",
"joie",
"symphonie 9",
"hymne"
],
"bpm": 108,
"voices": [
{
"wave": "triangle",
"vol": 0.34,
"notes": "E4:1 E4:1 F4:1 G4:1 G4:1 F4:1 E4:1 D4:1 C4:1 C4:1 D4:1 E4:1 E4:1.5 D4:.5 D4:2 E4:1 E4:1 F4:1 G4:1 G4:1 F4:1 E4:1 D4:1 C4:1 C4:1 D4:1 E4:1 D4:1.5 C4:.5 C4:2 D4:1 D4:1 E4:1 C4:1 D4:1 E4:.5 F4:.5 E4:1 C4:1 D4:1 E4:.5 F4:.5 E4:1 D4:1 C4:1 D4:1 G3:2 E4:1 E4:1 F4:1 G4:1 G4:1 F4:1 E4:1 D4:1 C4:1 C4:1 D4:1 E4:1 D4:1.5 C4:.5 C4:2 "
},
{
"wave": "sine",
"vol": 0.3,
"notes": "C3:4 G3:4 C3:4 G3:4 C3:4 G3:4 C3:4 G3:4 C3:4 G3:4 C3:4 G3:4 C3:4 G3:4 C3:4 G3:4"
}
]
},
{
"id": "elise",
"titre": "Lettre à Élise",
"artiste": "Beethoven",
"tags": [
"beethoven",
"classique",
"piano",
"elise",
"fur elise"
],
"bpm": 132,
"voices": [
{
"wave": "triangle",
"vol": 0.34,
"notes": "E5:.5 D#5:.5 E5:.5 D#5:.5 E5:.5 B4:.5 D5:.5 C5:.5 A4:1.5 R:.5 C4:.5 E4:.5 A4:.5 B4:1.5 R:.5 E4:.5 G#4:.5 B4:.5 C5:1.5 R:.5 E4:.5 E5:.5 D#5:.5 E5:.5 D#5:.5 E5:.5 B4:.5 D5:.5 C5:.5 A4:1.5 R:.5 C4:.5 E4:.5 A4:.5 B4:1.5 R:.5 E4:.5 C5:.5 B4:.5 A4:2"
},
{
"wave": "sine",
"vol": 0.3,
"notes": "R:6 A2:.5 E3:.5 A3:.5 R:1.5 E2:.5 E3:.5 G#3:.5 R:1.5 A2:.5 E3:.5 A3:.5 R:2.5 A2:.5 E3:.5 A3:.5 R:1.5 E2:.5 E3:.5 G#3:.5 R:1.5 A2:.5 E3:.5 A3:.5 R:2"
}
]
},
{
"id": "jacques",
"titre": "Frère Jacques",
"artiste": "Comptine",
"tags": [
"comptine",
"enfant",
"traditionnel",
"jacques",
"canon"
],
"bpm": 112,
"voices": [
{
"wave": "triangle",
"vol": 0.34,
"notes": "C4:1 D4:1 E4:1 C4:1 C4:1 D4:1 E4:1 C4:1 E4:1 F4:1 G4:2 E4:1 F4:1 G4:2 G4:.5 A4:.5 G4:.5 F4:.5 E4:1 C4:1 G4:.5 A4:.5 G4:.5 F4:.5 E4:1 C4:1 C4:1 G3:1 C4:2 C4:1 G3:1 C4:2"
},
{
"wave": "sine",
"vol": 0.3,
"notes": "C3:4 C3:4 C3:4 C3:4 C3:4 G3:4 C3:4 G3:4"
}
]
},
{
"id": "lune",
"titre": "Au clair de la lune",
"artiste": "Comptine",
"tags": [
"comptine",
"enfant",
"traditionnel",
"lune",
"clair"
],
"bpm": 96,
"voices": [
{
"wave": "triangle",
"vol": 0.34,
"notes": "C4:1 C4:1 C4:1 D4:1 E4:2 D4:2 C4:1 E4:1 D4:1 D4:1 C4:4 C4:1 C4:1 C4:1 D4:1 E4:2 D4:2 C4:1 E4:1 D4:1 D4:1 C4:4 D4:1 D4:1 D4:1 D4:1 A3:2 A3:2 D4:1 C4:1 B3:1 A3:1 G3:4 C4:1 C4:1 C4:1 D4:1 E4:2 D4:2 C4:1 E4:1 D4:1 D4:1 C4:4"
},
{
"wave": "sine",
"vol": 0.3,
"notes": "C3:4 C3:4 C3:4 G3:4 C3:4 C3:4 C3:4 G3:4 C3:4 C3:4"
}
]
},
{
"id": "greensleeves",
"titre": "Greensleeves",
"artiste": "Traditionnel anglais",
"tags": [
"traditionnel",
"anglais",
"ballade",
"medieval",
"greensleeves"
],
"bpm": 116,
"voices": [
{
"wave": "sine",
"vol": 0.34,
"notes": "A4:1 C5:2 D5:1 E5:1.5 F5:.5 E5:1 D5:2 B4:1 G4:1.5 A4:.5 B4:1 C5:2 A4:1 A4:1.5 G#4:.5 A4:1 B4:2 G#4:1 E4:2 A4:1 C5:2 D5:1 E5:1.5 F5:.5 E5:1 D5:2 B4:1 G4:1.5 A4:.5 B4:1 C5:1.5 B4:.5 A4:1 G#4:1.5 F#4:.5 G#4:1 A4:3"
},
{
"wave": "sine",
"vol": 0.3,
"notes": "A2:3 A2:3 C3:3 G2:3 A2:3 E2:3 A2:3 E2:3 A2:3 A2:3 C3:3 G2:3 A2:3 E3:3 A2:3"
}
]
},
{
"id": "canon",
"titre": "Canon en ré",
"artiste": "Pachelbel",
"tags": [
"pachelbel",
"classique",
"canon",
"mariage",
"baroque"
],
"bpm": 72,
"voices": [
{
"wave": "triangle",
"vol": 0.34,
"notes": "F#5:2 E5:2 D5:2 C#5:2 B4:2 A4:2 B4:2 C#5:2 F#5:2 E5:2 D5:2 C#5:2 B4:2 A4:2 B4:2 C#5:2 D5:1 F#5:1 A5:1 G5:1 F#5:1 D5:1 F#5:1 E5:1 D5:1 B4:1 D5:1 A5:1 G5:1 B5:1 A5:1 G5:1"
},
{
"wave": "sine",
"vol": 0.3,
"notes": "D3:2 A2:2 B2:2 F#2:2 G2:2 D2:2 G2:2 A2:2 D3:2 A2:2 B2:2 F#2:2 G2:2 D2:2 G2:2 A2:2 D3:2 A2:2 B2:2 F#2:2 G2:2 D2:2 G2:2 A2:2"
}
]
},
{
"id": "twinkle",
"titre": "Ah ! vous dirai-je, maman",
"artiste": "Mozart (variations)",
"tags": [
"mozart",
"comptine",
"twinkle",
"etoile",
"classique",
"enfant"
],
"bpm": 108,
"voices": [
{
"wave": "triangle",
"vol": 0.34,
"notes": "C4:1 C4:1 G4:1 G4:1 A4:1 A4:1 G4:2 F4:1 F4:1 E4:1 E4:1 D4:1 D4:1 C4:2 G4:1 G4:1 F4:1 F4:1 E4:1 E4:1 D4:2 G4:1 G4:1 F4:1 F4:1 E4:1 E4:1 D4:2 C4:1 C4:1 G4:1 G4:1 A4:1 A4:1 G4:2 F4:1 F4:1 E4:1 E4:1 D4:1 D4:1 C4:2"
},
{
"wave": "sine",
"vol": 0.3,
"notes": "C3:4 C3:4 F3:4 C3:4 C3:4 G3:4 C3:4 G3:4 C3:4 C3:4 F3:4 C3:4"
}
]
},
{
"id": "anniv",
"titre": "Joyeux anniversaire",
"artiste": "Traditionnel",
"tags": [
"anniversaire",
"fete",
"joyeux",
"happy birthday",
"traditionnel"
],
"bpm": 110,
"voices": [
{
"wave": "triangle",
"vol": 0.34,
"notes": "G4:.75 G4:.25 A4:1 G4:1 C5:1 B4:2 G4:.75 G4:.25 A4:1 G4:1 D5:1 C5:2 G4:.75 G4:.25 G5:1 E5:1 C5:1 B4:1 A4:1 F5:.75 F5:.25 E5:1 C5:1 D5:1 C5:3"
},
{
"wave": "sine",
"vol": 0.3,
"notes": "C3:3 C3:3 G2:3 G2:3 C3:3 C3:3 C3:3 F3:3 C3:3 G2:3 C3:3"
}
]
},
{
"id": "jingle",
"titre": "Vive le vent (Jingle Bells)",
"artiste": "Traditionnel",
"tags": [
"noel",
"hiver",
"fete",
"jingle bells",
"vive le vent",
"traditionnel"
],
"bpm": 140,
"voices": [
{
"wave": "triangle",
"vol": 0.34,
"notes": "E4:1 E4:1 E4:2 E4:1 E4:1 E4:2 E4:1 G4:1 C4:1.5 D4:.5 E4:4 F4:1 F4:1 F4:1.5 F4:.5 F4:1 E4:1 E4:1 E4:.5 E4:.5 E4:1 D4:1 D4:1 E4:1 D4:2 G4:2 E4:1 E4:1 E4:2 E4:1 E4:1 E4:2 E4:1 G4:1 C4:1.5 D4:.5 E4:4 F4:1 F4:1 F4:1.5 F4:.5 F4:1 E4:1 E4:1 E4:.5 E4:.5 G4:1 G4:1 F4:1 D4:1 C4:4"
},
{
"wave": "sine",
"vol": 0.3,
"notes": "C3:4 C3:4 C3:4 C3:4 F3:4 C3:4 G3:4 C3:4 C3:4 C3:4 C3:4 C3:4 F3:4 C3:4 G3:4 C3:4"
}
]
},
{
"id": "grace",
"titre": "Amazing Grace",
"artiste": "Traditionnel",
"tags": [
"gospel",
"traditionnel",
"grace",
"ballade",
"spirituel"
],
"bpm": 88,
"voices": [
{
"wave": "sine",
"vol": 0.34,
"notes": "D4:1 G4:2 B4:.5 G4:.5 B4:2 A4:1 G4:2 E4:1 D4:2 D4:1 G4:2 B4:.5 G4:.5 B4:2 A4:1 D5:3 B4:2 D5:.5 B4:.5 D5:1.5 B4:.5 G4:2 E4:1 D4:2 D4:1 G4:2 B4:.5 G4:.5 B4:2 A4:1 G4:3"
},
{
"wave": "sine",
"vol": 0.3,
"notes": "G2:3 G2:3 C3:3 G2:3 G2:3 E3:3 D3:3 G2:3 G2:3 C3:3 G2:3 G2:3 D3:3 G2:3"
}
]
},
{
"id": "sym5",
"titre": "Symphonie n°5 (motif)",
"artiste": "Beethoven",
"tags": [
"beethoven",
"classique",
"symphonie",
"destin",
"sol"
],
"bpm": 104,
"voices": [
{
"wave": "sawtooth",
"vol": 0.34,
"notes": "G4:.5 G4:.5 G4:.5 D#4:3 R:1 F4:.5 F4:.5 F4:.5 D4:3 R:1 G4:.5 G4:.5 G4:.5 D#4:2 G4:.5 G4:.5 G4:.5 D#4:2"
},
{
"wave": "sine",
"vol": 0.3,
"notes": "G2:.5 G2:.5 G2:.5 D#2:3 R:1 F2:.5 F2:.5 F2:.5 D2:3 R:1 G2:.5 G2:.5 G2:.5 D#2:4"
}
]
},
{
"id": "turque",
"titre": "Marche turque",
"artiste": "Mozart",
"tags": [
"mozart",
"classique",
"turque",
"piano",
"sonate 11"
],
"bpm": 138,
"voices": [
{
"wave": "triangle",
"vol": 0.34,
"notes": "B4:.25 A4:.25 G#4:.25 A4:.25 C5:1 D5:.25 C5:.25 B4:.25 C5:.25 E5:1 F5:.25 E5:.25 D#5:.25 E5:.25 B5:.25 A5:.25 G#5:.25 A5:.25 B5:.25 A5:.25 G#5:.25 A5:.25 C6:1 A5:.5 C6:.5 B5:.5 A5:.5 G5:.5 F#5:.5 G5:.5 B5:.5 B5:.25 A5:.25 G#5:.25 A5:.25 C6:1"
},
{
"wave": "sine",
"vol": 0.3,
"notes": "A2:.5 E3:.5 A3:.5 E3:.5 A2:.5 E3:.5 A3:.5 E3:.5 A2:.5 E3:.5 A3:.5 E3:.5 A2:.5 E3:.5 A3:.5 E3:.5 A2:.5 E3:.5 A3:.5 E3:.5 A2:.5 E3:.5 A3:.5 E3:.5 A2:.5 E3:.5 A3:.5 E3:.5 A2:.5 E3:.5 A3:.5 E3:.5"
}
]
},
{
"id": "nachtmusik",
"titre": "Une petite musique de nuit",
"artiste": "Mozart",
"tags": [
"mozart",
"classique",
"serenade",
"nuit",
"eine kleine"
],
"bpm": 126,
"voices": [
{
"wave": "triangle",
"vol": 0.34,
"notes": "G4:1 R:.5 D4:.5 G4:1 R:.5 D4:.5 G4:.5 D4:.5 G4:.5 B4:.5 D5:2 C5:1 R:.5 A4:.5 C5:1 R:.5 A4:.5 C5:.5 A4:.5 F#4:.5 A4:.5 D4:2 G4:1 R:.5 D4:.5 G4:1 R:.5 D4:.5 G4:.5 D4:.5 G4:.5 B4:.5 D5:2"
},
{
"wave": "sine",
"vol": 0.3,
"notes": "G2:2 G2:2 G2:2 G2:2 D3:2 D3:2 D3:2 D3:2 G2:2 G2:2 G2:2 G2:2"
}
]
},
{
"id": "menuet",
"titre": "Menuet en sol",
"artiste": "Petzold (attr. Bach)",
"tags": [
"bach",
"classique",
"menuet",
"baroque",
"petzold"
],
"bpm": 120,
"voices": [
{
"wave": "triangle",
"vol": 0.34,
"notes": "D5:1 G4:.5 A4:.5 B4:.5 C5:.5 D5:1 G4:1 G4:1 E5:1 C5:.5 D5:.5 E5:.5 F#5:.5 G5:1 G4:1 G4:1 C5:1 D5:.5 C5:.5 B4:.5 A4:.5 B4:1 C5:.5 B4:.5 A4:.5 G4:.5 F#4:1 G4:.5 A4:.5 B4:.5 G4:.5 B4:3"
},
{
"wave": "sine",
"vol": 0.3,
"notes": "G2:3 G2:3 C3:3 G2:3 A2:3 G2:3 G2:3 D3:3 G2:3 G2:3"
}
]
}
]$cm$,7738 from public.bots where username='vlafibot' on conflict (bot_id,path) do update set content=excluded.content,size=excluded.size,updated_at=now(),runtime=false;
