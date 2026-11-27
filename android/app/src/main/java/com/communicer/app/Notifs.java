package com.communicer.app;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.content.Context;
import android.content.Intent;
import android.os.Build;

/** Notifications de la barre Android (messages, demandes d'ami, invitations, jetons). Aucun contenu de message : seulement des nombres. */
final class Notifs {
    static final String CHANNEL = "communicer_main";

    private Notifs() { }

    static void ensureChannel(Context ctx) {
        if (Build.VERSION.SDK_INT < 26) return;
        NotificationManager nm = (NotificationManager) ctx.getSystemService(Context.NOTIFICATION_SERVICE);
        if (nm == null || nm.getNotificationChannel(CHANNEL) != null) return;
        NotificationChannel ch = new NotificationChannel(CHANNEL, "Communicer!", NotificationManager.IMPORTANCE_HIGH);
        ch.setDescription("Messages, demandes d'ami, invitations et jetons");
        nm.createNotificationChannel(ch);
    }

    static void post(Context ctx, int id, String title, String text) {
        try {
            ensureChannel(ctx);
            NotificationManager nm = (NotificationManager) ctx.getSystemService(Context.NOTIFICATION_SERVICE);
            if (nm == null) return;
            Intent it = new Intent(ctx, MainActivity.class);
            it.setFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_SINGLE_TOP);
            int fl = PendingIntent.FLAG_UPDATE_CURRENT | (Build.VERSION.SDK_INT >= 23 ? PendingIntent.FLAG_IMMUTABLE : 0);
            PendingIntent pi = PendingIntent.getActivity(ctx, id, it, fl);
            Notification.Builder b = Build.VERSION.SDK_INT >= 26 ? new Notification.Builder(ctx, CHANNEL) : new Notification.Builder(ctx);
            b.setSmallIcon(ctx.getApplicationInfo().icon).setContentTitle(title).setContentText(text).setAutoCancel(true).setContentIntent(pi);
            if (Build.VERSION.SDK_INT < 26) b.setPriority(Notification.PRIORITY_HIGH);
            nm.notify(id, b.build());
        } catch (Throwable t) { /* l'absence de permission ne doit jamais faire planter l'application */ }
    }
}
