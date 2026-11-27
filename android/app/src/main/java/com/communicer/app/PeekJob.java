package com.communicer.app;

import android.app.job.JobParameters;
import android.app.job.JobService;
import android.content.SharedPreferences;

import org.json.JSONObject;

import java.io.InputStream;
import java.io.OutputStream;
import java.net.HttpURLConnection;
import java.net.URL;

/** Tâche périodique (toutes les 15 minutes au mieux) : demande au serveur combien de nouveautés existent et affiche une notification si ce nombre a augmenté. */
public class PeekJob extends JobService {
    @Override public boolean onStartJob(final JobParameters p) {
        new Thread(() -> {
            try { run(); } catch (Throwable t) { /* réessai à la prochaine période */ }
            finally { jobFinished(p, false); }
        }).start();
        return true;
    }

    @Override public boolean onStopJob(JobParameters p) { return true; }

    private void run() throws Exception {
        if (MainActivity.visible) return;   // l'application est ouverte : elle notifie elle-même
        SharedPreferences sp = getSharedPreferences("cm_push", MODE_PRIVATE);
        String url = sp.getString("url", ""), key = sp.getString("key", ""), tok = sp.getString("tok", "");
        if (url.isEmpty() || key.isEmpty() || !tok.matches("^[0-9a-f]{64}$")) return;
        HttpURLConnection c = (HttpURLConnection) new URL(url + "/rest/v1/rpc/notif_peek").openConnection();
        c.setRequestMethod("POST");
        c.setConnectTimeout(10000);
        c.setReadTimeout(15000);
        c.setRequestProperty("apikey", key);
        c.setRequestProperty("Authorization", "Bearer " + key);
        c.setRequestProperty("Content-Type", "application/json");
        c.setDoOutput(true);
        try (OutputStream os = c.getOutputStream()) { os.write(("{\"p_token\":\"" + tok + "\"}").getBytes("UTF-8")); }
        if (c.getResponseCode() != 200) return;
        StringBuilder sb = new StringBuilder();
        try (InputStream is = c.getInputStream()) {
            byte[] buf = new byte[2048];
            int n;
            while ((n = is.read(buf)) > 0) sb.append(new String(buf, 0, n, "UTF-8"));
        }
        JSONObject o = new JSONObject(sb.toString());
        if (!o.optBoolean("ok", false)) { sp.edit().remove("tok").apply(); return; }   // jeton révoqué : on s'arrête
        int msgs = o.optInt("msgs"), fr = o.optInt("friends"), inv = o.optInt("invites"), tk = o.optInt("tokens");
        int pm = sp.getInt("msgs", 0), pf = sp.getInt("friends", 0), pi = sp.getInt("invites", 0);
        if (msgs > pm) Notifs.post(this, 1, "Nouveaux messages", msgs == 1 ? "Vous avez 1 message non lu." : "Vous avez " + msgs + " messages non lus.");
        if (fr > pf) Notifs.post(this, 2, "Demande d'ami", "Quelqu'un souhaite devenir votre ami.");
        if (inv > pi) Notifs.post(this, 3, "Invitation de groupe", "Vous avez une invitation de groupe.");
        if (tk > 0) Notifs.post(this, 4, "Jetons", "Vous avez reçu des jetons.");
        sp.edit().putInt("msgs", msgs).putInt("friends", fr).putInt("invites", inv).apply();
    }
}
