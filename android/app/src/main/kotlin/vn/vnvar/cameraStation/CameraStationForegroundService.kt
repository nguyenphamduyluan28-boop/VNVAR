package vn.vnvar.cameraStation

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.content.pm.PackageManager
import android.Manifest
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.util.Log
import androidx.core.app.NotificationCompat
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.plugin.common.MethodChannel

class CameraStationForegroundService : Service() {
    private var currentCameraId = "Camera"
    private var currentCourtId = "Chưa chọn sân"
    private val mainHandler = Handler(Looper.getMainLooper())
    private var taskRemovalShutdownStarted = false
    private var taskRemovalShutdownFinished = false
    private val taskRemovalTimeout = Runnable {
        Log.w(TAG, "[SERVICE] Dart shutdown timed out after task removal")
        finishAfterTaskRemoval()
    }

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
        val isRefresh = intent?.action == ACTION_REFRESH_TYPES

        if (!startForegroundSafely(notification)) {
            if (!isRefresh) {
                // Không vào được foreground (Android 12+ chặn khởi động từ nền,
                // Android 14 thiếu điều kiện cho type camera/micro): dừng gọn
                // thay vì để exception làm sập cả tiến trình.
                Log.e(TAG, "[SERVICE] Unable to enter foreground; stopping service")
                // Dịch vụ được khởi động bằng startForegroundService: trên
                // Android 8–11, stopSelf() khi chưa từng startForeground vẫn
                // làm hệ thống ném "did not then call startForeground" và sập
                // tiến trình. Thử vào foreground tối thiểu rồi rời ngay.
                if (startForegroundMinimal()) {
                    Log.w(TAG, "[SERVICE] Entered minimal foreground only to stop cleanly")
                }
                appliedForegroundTypes = 0
                try {
                    stopForeground(STOP_FOREGROUND_REMOVE)
                } catch (error: Exception) {
                    Log.w(TAG, "[SERVICE] stopForeground failed", error)
                }
                stopSelf()
            }
            return START_NOT_STICKY
        }
        val action = if (isRefresh) "types refreshed" else "active"
        Log.i(TAG, "[SERVICE] Foreground $action: $currentCameraId / $currentCourtId")

        // Camera services must be started while the Activity is visible. Do not
        // ask Android to recreate this service silently from the background.
        return START_NOT_STICKY
    }

    /**
     * Gọi startForeground với type camera (+ micro khi đã có quyền). Lỗi từ hệ
     * thống (ForegroundServiceStartNotAllowedException, SecurityException...)
     * chỉ được ghi log; nếu type micro bị từ chối thì thử lại chỉ với camera.
     */
    private fun startForegroundSafely(notification: Notification): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            return try {
                startForeground(NOTIFICATION_ID, notification)
                appliedForegroundTypes = 0
                true
            } catch (error: Exception) {
                Log.e(TAG, "[SERVICE] startForeground failed", error)
                false
            }
        }
        val required = requiredForegroundTypes(this)
        val attempts = if (required != ServiceInfo.FOREGROUND_SERVICE_TYPE_CAMERA) {
            listOf(required, ServiceInfo.FOREGROUND_SERVICE_TYPE_CAMERA)
        } else {
            listOf(required)
        }
        for (types in attempts) {
            try {
                startForeground(NOTIFICATION_ID, notification, types)
                appliedForegroundTypes = types
                return true
            } catch (error: Exception) {
                Log.e(TAG, "[SERVICE] startForeground(types=$types) failed", error)
            }
        }
        return false
    }

    /**
     * Lần thử cuối trước khi dừng: notification tối thiểu, không kèm type
     * camera/micro. Android < 10: startForeground(id, notification). Android
     * 10–13: type 0 (NONE, luôn là tập con của manifest), rồi dạng 2 tham số
     * (= FOREGROUND_SERVICE_TYPE_MANIFEST). Android 14+ bắt buộc type hợp lệ và
     * đã thử camera ở trên, nên giữ nguyên hành vi (không thử thêm).
     */
    private fun startForegroundMinimal(): Boolean {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) return false
        val notification = try {
            // NotificationCompat: Notification.Builder(ctx, channelId) cần API 26
            // (Android 7.x sập với NoSuchMethodError).
            NotificationCompat.Builder(this, CHANNEL_ID)
                .setSmallIcon(android.R.drawable.presence_video_online)
                .setContentTitle("SportO Cam")
                .setCategory(NotificationCompat.CATEGORY_SERVICE)
                .build()
        } catch (error: Exception) {
            Log.e(TAG, "[SERVICE] Unable to build minimal notification", error)
            return false
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            try {
                startForeground(NOTIFICATION_ID, notification, 0)
                return true
            } catch (error: Exception) {
                Log.e(TAG, "[SERVICE] Minimal startForeground(type=0) failed", error)
            }
        }
        return try {
            startForeground(NOTIFICATION_ID, notification)
            true
        } catch (error: Exception) {
            Log.e(TAG, "[SERVICE] Minimal startForeground failed", error)
            false
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onTaskRemoved(rootIntent: Intent?) {
        if (taskRemovalShutdownStarted) {
            super.onTaskRemoved(rootIntent)
            return
        }
        taskRemovalShutdownStarted = true
        Log.i(TAG, "[SERVICE] App removed from recent tasks; finalizing recording")
        mainHandler.postDelayed(taskRemovalTimeout, TASK_REMOVAL_TIMEOUT_MS)

        val engine = FlutterEngineCache.getInstance().get(ENGINE_CACHE_KEY)
        if (engine == null) {
            Log.w(TAG, "[SERVICE] Flutter engine unavailable during task removal")
            finishAfterTaskRemoval()
        } else {
            MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL_NAME).invokeMethod(
                METHOD_ANDROID_TASK_REMOVED,
                null,
                object : MethodChannel.Result {
                    override fun success(result: Any?) = finishAfterTaskRemoval()

                    override fun error(code: String, message: String?, details: Any?) {
                        Log.e(TAG, "[SERVICE] Dart shutdown failed: $code $message")
                        finishAfterTaskRemoval()
                    }

                    override fun notImplemented() {
                        Log.w(TAG, "[SERVICE] Dart task-removal callback is not registered")
                        finishAfterTaskRemoval()
                    }
                },
            )
        }
        super.onTaskRemoved(rootIntent)
    }

    private fun finishAfterTaskRemoval() {
        if (taskRemovalShutdownFinished) return
        taskRemovalShutdownFinished = true
        mainHandler.removeCallbacks(taskRemovalTimeout)
        // The app deliberately caches its FlutterEngine for Activity
        // recreation. Once the task is explicitly removed, keeping that
        // engine alive would leave Dart timers/process state resident even
        // after camera and recording have stopped.
        val engineCache = FlutterEngineCache.getInstance()
        val cachedEngine = engineCache.get(ENGINE_CACHE_KEY)
        engineCache.remove(ENGINE_CACHE_KEY)
        cachedEngine?.destroy()
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    override fun onDestroy() {
        mainHandler.removeCallbacks(taskRemovalTimeout)
        isRunning = false
        appliedForegroundTypes = 0
        stopForeground(STOP_FOREGROUND_REMOVE)
        Log.i(TAG, "[SERVICE] Camera Station foreground service destroyed")
        super.onDestroy()
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return

        val channel = NotificationChannel(
            CHANNEL_ID,
            "SportO Cam",
            NotificationManager.IMPORTANCE_LOW,
        ).apply {
            description = "Trạng thái quay của SportO Cam"
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

        // NotificationCompat thay Notification.Builder(ctx, channelId) (API 26+).
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.presence_video_online)
            .setContentTitle("SportO Cam")
            .setContentText("$cameraId đang hoạt động · $courtId")
            .setContentIntent(openAppPendingIntent)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .build()
    }

    companion object {
        @Volatile
        var isRunning: Boolean = false
            private set

        /** Tập foreground type đã áp dụng thành công gần nhất (0 khi chưa/không dùng). */
        @Volatile
        var appliedForegroundTypes: Int = 0
            private set

        /** Tập foreground type dịch vụ cần với quyền hiện tại (0 trước Android 10). */
        fun requiredForegroundTypes(context: Context): Int {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return 0
            return if (
                context.checkSelfPermission(Manifest.permission.RECORD_AUDIO) ==
                PackageManager.PERMISSION_GRANTED
            ) {
                ServiceInfo.FOREGROUND_SERVICE_TYPE_CAMERA or
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE
            } else {
                ServiceInfo.FOREGROUND_SERVICE_TYPE_CAMERA
            }
        }

        const val ACTION_START = "vn.vnvar.cameraStation.action.START"
        const val ACTION_STOP = "vn.vnvar.cameraStation.action.STOP"
        const val ACTION_REFRESH_TYPES = "vn.vnvar.cameraStation.action.REFRESH_TYPES"
        const val EXTRA_CAMERA_ID = "camera_id"
        const val EXTRA_COURT_ID = "court_id"

        private const val ENGINE_CACHE_KEY = "vnvar_camera_station_engine"
        private const val CHANNEL_NAME = "vnvar/camera_station_service"
        private const val METHOD_ANDROID_TASK_REMOVED = "onAndroidTaskRemoved"
        // Final TS remux can take tens of seconds on slower storage. Camera is
        // released as soon as MediaRecorder stops; this timeout only guards
        // the remaining file finalization and engine shutdown.
        private const val TASK_REMOVAL_TIMEOUT_MS = 60_000L

        private const val CHANNEL_ID = "vnvar_camera_station"
        private const val NOTIFICATION_ID = 1001
        private const val TAG = "VNVAR"
    }
}
