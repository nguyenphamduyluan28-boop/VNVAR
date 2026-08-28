package vn.vnvar.cameraStation

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.content.pm.PackageManager
import android.Manifest
import android.os.Build
import android.os.IBinder
import android.util.Log

class CameraStationForegroundService : Service() {
    private var currentCameraId = "Camera"
    private var currentCourtId = "Chưa chọn sân"

    override fun onCreate() {
        super.onCreate()
        isRunning = true
        createNotificationChannel()
        Log.i(TAG, "[SERVICE] Camera Station foreground service created")
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            Log.i(TAG, "[SERVICE] Stop requested")
            stopForeground(STOP_FOREGROUND_REMOVE)
            stopSelf()
            return START_NOT_STICKY
        }

        if (intent?.action != ACTION_REFRESH_TYPES) {
            currentCameraId = intent?.getStringExtra(EXTRA_CAMERA_ID) ?: currentCameraId
            currentCourtId = intent?.getStringExtra(EXTRA_COURT_ID) ?: currentCourtId
        }
        val notification = buildNotification(currentCameraId, currentCourtId)

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val foregroundTypes = if (
                checkSelfPermission(Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED
            ) {
                ServiceInfo.FOREGROUND_SERVICE_TYPE_CAMERA or
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE
            } else {
                ServiceInfo.FOREGROUND_SERVICE_TYPE_CAMERA
            }
            startForeground(
                NOTIFICATION_ID,
                notification,
                foregroundTypes,
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }

        val action = if (intent?.action == ACTION_REFRESH_TYPES) "types refreshed" else "active"
        Log.i(TAG, "[SERVICE] Foreground $action: $currentCameraId / $currentCourtId")

        // Camera services must be started while the Activity is visible. Do not
        // ask Android to recreate this service silently from the background.
        return START_NOT_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onTaskRemoved(rootIntent: Intent?) {
        // Keep the already-running camera/microphone foreground service alive.
        // The user can stop it explicitly from the app/API after Dart has
        // finalized MP4, WAV and TS segments.
        Log.i(TAG, "[SERVICE] App removed from recent tasks; keeping recording active")
        super.onTaskRemoved(rootIntent)
    }

    override fun onDestroy() {
        isRunning = false
        stopForeground(STOP_FOREGROUND_REMOVE)
        Log.i(TAG, "[SERVICE] Camera Station foreground service destroyed")
        super.onDestroy()
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return

        val channel = NotificationChannel(
            CHANNEL_ID,
            "VNVAR Camera Station",
            NotificationManager.IMPORTANCE_LOW,
        ).apply {
            description = "Trạng thái quay của Camera Station"
            setShowBadge(false)
        }

        getSystemService(NotificationManager::class.java)
            .createNotificationChannel(channel)
    }

    private fun buildNotification(cameraId: String, courtId: String): Notification {
        val openAppIntent = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        val openAppPendingIntent = PendingIntent.getActivity(
            this,
            0,
            openAppIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )

        return Notification.Builder(this, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.presence_video_online)
            .setContentTitle("VNVAR Camera Station")
            .setContentText("$cameraId đang hoạt động · $courtId")
            .setContentIntent(openAppPendingIntent)
            .setCategory(Notification.CATEGORY_SERVICE)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .build()
    }

    companion object {
        @Volatile
        var isRunning: Boolean = false
            private set

        const val ACTION_START = "vn.vnvar.cameraStation.action.START"
        const val ACTION_STOP = "vn.vnvar.cameraStation.action.STOP"
        const val ACTION_REFRESH_TYPES = "vn.vnvar.cameraStation.action.REFRESH_TYPES"
        const val EXTRA_CAMERA_ID = "camera_id"
        const val EXTRA_COURT_ID = "court_id"

        private const val CHANNEL_ID = "vnvar_camera_station"
        private const val NOTIFICATION_ID = 1001
        private const val TAG = "VNVAR"
    }
}
