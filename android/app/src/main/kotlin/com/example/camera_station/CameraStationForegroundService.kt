package com.example.camera_station

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.util.Log

class CameraStationForegroundService : Service() {
    override fun onCreate() {
        super.onCreate()
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

        val cameraId = intent?.getStringExtra(EXTRA_CAMERA_ID) ?: "Camera"
        val courtId = intent?.getStringExtra(EXTRA_COURT_ID) ?: "Chưa chọn sân"
        val notification = buildNotification(cameraId, courtId)

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_CAMERA,
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }

        Log.i(TAG, "[SERVICE] Foreground active: $cameraId / $courtId")

        // Camera services must be started while the Activity is visible. Do not
        // ask Android to recreate this service silently from the background.
        return START_NOT_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onTaskRemoved(rootIntent: Intent?) {
        Log.i(TAG, "[SERVICE] App removed from recent tasks; stopping foreground service")
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
        super.onTaskRemoved(rootIntent)
    }

    override fun onDestroy() {
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
        const val ACTION_START = "com.example.camera_station.action.START"
        const val ACTION_STOP = "com.example.camera_station.action.STOP"
        const val EXTRA_CAMERA_ID = "camera_id"
        const val EXTRA_COURT_ID = "court_id"

        private const val CHANNEL_ID = "vnvar_camera_station"
        private const val NOTIFICATION_ID = 1001
        private const val TAG = "VNVAR"
    }
}
