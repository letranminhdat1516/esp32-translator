package vn.cicca.livetranslator.engine

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager
import android.util.Log
import vn.cicca.livetranslator.R

/**
 * Keeps a conversation running with the screen off and in the background (P6): a foreground service of
 * type microphone with the notification "Đang dịch hội thoại", a partial wake lock, and a heartbeat log
 * line every 10 s (what the engine is doing: mic frames, gate, route).
 *
 * The engine itself lives in the process ([VoiceEnginePlugin]); this service only holds the process in the
 * foreground while `start()`…`stop()`.
 */
class VoiceService : Service() {
    private val main = Handler(Looper.getMainLooper())
    private var wakeLock: PowerManager.WakeLock? = null
    private var startedAt = 0L

    private val heartbeat = object : Runnable {
        override fun run() {
            val seconds = (android.os.SystemClock.elapsedRealtime() - startedAt) / 1000
            heartbeats++
            Log.i(TAG, "heartbeat ${seconds}s: ${status()}")
            main.postDelayed(this, HEARTBEAT_MS)
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        startedAt = android.os.SystemClock.elapsedRealtime()
        val notification = notification(this)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE)
        } else {
            // API 29 (the Note 9) has no microphone type: a plain foreground service keeps the mic
            startForeground(NOTIFICATION_ID, notification)
        }
        wakeLock = getSystemService(PowerManager::class.java)
            .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "livetranslator:conversation")
            .apply { acquire(WAKE_LOCK_MAX_MS) }
        running = true
        main.postDelayed(heartbeat, HEARTBEAT_MS)
        Log.i(TAG, "foreground service started")
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int = START_NOT_STICKY

    override fun onDestroy() {
        main.removeCallbacks(heartbeat)
        wakeLock?.let { if (it.isHeld) it.release() }
        wakeLock = null
        running = false
        Log.i(TAG, "foreground service stopped")
        super.onDestroy()
    }

    companion object {
        private const val TAG = "VoiceService"
        private const val CHANNEL = "conversation"
        private const val NOTIFICATION_ID = 1
        const val HEARTBEAT_MS = 10_000L
        /** Released by stop(); the cap only guards against a lost stop */
        private const val WAKE_LOCK_MAX_MS = 6 * 60 * 60 * 1000L

        /** What the heartbeat logs; set by the engine */
        @Volatile var status: () -> String = { "idle" }

        @Volatile var running = false
            private set

        /** Heartbeats logged since the process started (tests read it) */
        @Volatile var heartbeats = 0
            private set

        fun start(context: Context) {
            context.startForegroundService(Intent(context, VoiceService::class.java))
        }

        fun stop(context: Context) {
            context.stopService(Intent(context, VoiceService::class.java))
        }

        private fun notification(context: Context): Notification {
            val manager = context.getSystemService(NotificationManager::class.java)
            manager.createNotificationChannel(
                NotificationChannel(CHANNEL, "Hội thoại", NotificationManager.IMPORTANCE_LOW).apply {
                    description = "Hiện khi ứng dụng đang nghe và dịch"
                    setShowBadge(false)
                },
            )
            val launch = context.packageManager.getLaunchIntentForPackage(context.packageName)
            val content = launch?.let {
                PendingIntent.getActivity(context, 0, it, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
            }
            return Notification.Builder(context, CHANNEL)
                .setSmallIcon(R.drawable.ic_stat_conversation)
                .setContentTitle("Đang dịch hội thoại")
                .setOngoing(true)
                .setCategory(Notification.CATEGORY_SERVICE)
                .apply { content?.let { setContentIntent(it) } }
                .build()
        }
    }
}
