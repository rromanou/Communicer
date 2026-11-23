-- VlafiBOT V2 : recherche de musique en ligne (commande vl/web). Additif, relançable.
-- Nécessite la fonction edge « music-search » (voir music-search.ts) et le nouveau index.html (api.audio.search / loadUrl).
update public.bot_files f set content = replace(f.content, $a$vl/speed [0.1 à 3]  vitesse$a$, $b$vl/web m:[NOM]  cherche en ligne (Pixabay, Audio Library, Free Music Archive, ccMixter, La Sonothèque) et joue le nom le plus proche\nvl/speed [0.1 à 3]  vitesse$b$)
 where f.path = 'main.cmm' and f.bot_id = (select id from public.bots where username = 'vlafibot') and f.content not like '%vl/web m:%';

update public.bot_files f set content = f.content || $cm$

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
$cm$, size = length(f.content) + 1700, updated_at = now()
 where f.path = 'main.cmm' and f.bot_id = (select id from public.bots where username = 'vlafibot') and f.content not like '%sur commande "web"%';
