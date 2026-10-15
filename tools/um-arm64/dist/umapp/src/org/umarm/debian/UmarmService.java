package org.umarm.debian;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.app.Service;
import android.content.Context;
import android.content.Intent;
import android.os.IBinder;
import android.os.PowerManager;

/**
 * The guest, while the app is not in front.
 *
 * A Linux kernel the user started should not die because they looked at
 * something else, and Android only lets a process ask for that through a
 * foreground service. So the console gets the entry Termux users expect: one
 * ongoing notification, tapping it comes back to the terminal, and "Stop" ends
 * the guest.
 *
 * It deliberately does not own the terminal session -- that lives in the
 * Activity, next to the view that draws it -- and it does not need to. A
 * foreground service in the same process is what keeps the process, and with it
 * the guest child, from being reclaimed when the Activity is stopped.
 *
 * The wakelock is not the "keep the screen on" preference. That one holds the
 * display awake; this one keeps the CPU running with the screen off, which is
 * what a long build or a `docker pull` in the guest wants.
 */
public class UmarmService extends Service {

    public static final String CHANNEL = "guest";
    public static final int ID = 1;
    public static final String ACTION_START = "org.umarm.action.START";
    public static final String ACTION_STOP = "org.umarm.action.STOP";
    public static final String EXTRA_WAKELOCK = "wakelock";

    private PowerManager.WakeLock wakeLock;

    @Override public IBinder onBind(Intent intent) { return null; }

    @Override public int onStartCommand(Intent intent, int flags, int startId) {
        String action = intent == null ? null : intent.getAction();

        if (ACTION_STOP.equals(action)) {
            /*
             * The Activity owns the session, so stopping the guest means telling
             * it. If it is gone the guest is gone with it, and stopping the
             * service is the only thing left. Done before stopSelf so the
             * notification does not outlive the guest by a moment.
             */
            Intent open = new Intent(this, MainActivity.class);
            open.setAction(ACTION_STOP);
            open.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_SINGLE_TOP);
            startActivity(open);
            stopForeground(true);
            stopSelf();
            return START_NOT_STICKY;
        }

        startForeground(ID, buildNotification());
        applyWakeLock(intent != null && intent.getBooleanExtra(EXTRA_WAKELOCK, false));
        return START_NOT_STICKY;
    }

    @Override public void onDestroy() {
        releaseWakeLock();
        super.onDestroy();
    }

    private Notification buildNotification() {
        NotificationManager nm =
                (NotificationManager) getSystemService(Context.NOTIFICATION_SERVICE);
        NotificationChannel ch = new NotificationChannel(CHANNEL, "Guest",
                NotificationManager.IMPORTANCE_LOW);
        ch.setShowBadge(false);
        nm.createNotificationChannel(ch);

        Intent open = new Intent(this, MainActivity.class);
        open.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_SINGLE_TOP);
        PendingIntent openPi = PendingIntent.getActivity(this, 0, open,
                PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE);

        Intent stop = new Intent(this, UmarmService.class).setAction(ACTION_STOP);
        PendingIntent stopPi = PendingIntent.getService(this, 1, stop,
                PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE);

        return new Notification.Builder(this, CHANNEL)
                .setSmallIcon(R.drawable.ic_notification)
                .setContentTitle("umarm")
                .setContentText("guest running")
                .setOngoing(true)
                .setShowWhen(false)
                .setContentIntent(openPi)
                .addAction(0, "Stop", stopPi)
                .build();
    }

    private void applyWakeLock(boolean want) {
        if (want) {
            if (wakeLock == null) {
                PowerManager pm = (PowerManager) getSystemService(Context.POWER_SERVICE);
                wakeLock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "umarm:guest");
                wakeLock.setReferenceCounted(false);
            }
            if (!wakeLock.isHeld()) wakeLock.acquire();
        } else {
            releaseWakeLock();
        }
    }

    private void releaseWakeLock() {
        if (wakeLock != null) {
            if (wakeLock.isHeld()) wakeLock.release();
            wakeLock = null;
        }
    }
}
