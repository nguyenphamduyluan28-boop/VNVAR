package vn.vnvar.cameraStation

import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaCodecList
import android.media.MediaFormat
import android.os.Build
import android.os.Bundle
import android.util.Base64
import android.util.Log
import org.webrtc.VideoFrame
import org.webrtc.VideoSink
import org.webrtc.VideoTrack
import org.webrtc.YuvHelper
import java.io.InputStream
import java.io.OutputStream
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import java.net.SocketTimeoutException
import java.nio.ByteBuffer
import java.util.ArrayDeque
import java.util.UUID
import java.util.Locale
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong
import java.util.concurrent.atomic.AtomicReference
import kotlin.concurrent.thread

/** Publishes the existing WebRTC VideoTrack as H.264 over RTSP without opening another camera. */
class VnvarRtspPublisher(
    private val track: VideoTrack,
    private val audioAvailable: Boolean = false,
    private val port: Int = 8554,
    private val bitrate: Int = 2_000_000,
    private val fps: Int = 30,
    remoteAudioEnabled: Boolean = false,
    /** Nhận [publisherId] để bên gọi bỏ qua callback trễ của phiên đã dừng. */
    private val onEncoderConfigured: (Long) -> Unit = {},
    private val onEncoderError: (Long, String) -> Unit = { _, _ -> },
) : VideoSink {
    /** Id duy nhất của phiên publisher này (đi kèm mọi callback). */
    val publisherId: Long = nextPublisherId.incrementAndGet()

    fun sendAudioPcm(pcm: ByteArray) {
        if (!running.get() || !audioAvailable || pcm.isEmpty()) return
        // Mỗi client gửi âm thanh trên luồng gửi riêng của nó. Trước đây mọi
        // client dùng chung một luồng ghi chặn vào socket, nên một Tablet có
        // Wi-Fi yếu làm ngắt tiếng của tất cả client (kể cả relay livestream).
        for (session in sessions.values) {
            if (session.playing && session.audioConfigured) session.enqueueAudio(pcm)
        }
    }
    /**
     * Tablet (client RTSP qua mạng) có nhận tiếng không. Relay livestream cục
     * bộ (loopback) luôn nhận tiếng. Áp dụng cho DESCRIBE/SETUP mới.
     */
    @Volatile var remoteAudioEnabled: Boolean = remoteAudioEnabled

    /**
     * Bitrate mục tiêu do bộ thích ứng livestream đặt. Báo cáo RTCP từ Tablet
     * chỉ được hạ thấp hơn mức này, không được nâng vượt lên.
     */
    fun setTargetBitrate(target: Int) {
        val clamped = synchronized(feedbackLock) {
            val value = target.coerceIn(MIN_RTSP_BITRATE, bitrate.coerceAtLeast(MIN_RTSP_BITRATE))
            maximumAdaptiveBitrate = value
            currentBitrate = value
            healthyReceiverReports = 0
            value
        }
        synchronized(codecLock) {
            try {
                codec?.setParameters(Bundle().apply {
                    putInt(MediaCodec.PARAMETER_KEY_VIDEO_BITRATE, clamped)
                })
                Log.i(TAG, "Live bitrate target applied: $clamped")
            } catch (error: Exception) {
                Log.w(TAG, "Unable to apply live bitrate $clamped", error)
            }
        }
    }

    private val running = AtomicBoolean(false)
    private val sessions = ConcurrentHashMap<String, Session>()
    private var serverSocket: ServerSocket? = null
    private var codec: MediaCodec? = null
    /** Kích thước canvas encoder (chẵn), cố định suốt đời encoder. */
    private var width = 0
    private var height = 0
    /** Kích thước nguồn (chưa xoay, chẵn) lúc dựng encoder; chỉ dùng dưới codecLock. */
    private var encoderSourceWidth = 0
    private var encoderSourceHeight = 0
    private var encoderColorFormat = MediaCodecInfo.CodecCapabilities.COLOR_FormatYUV420Planar
    /**
     * Cache encoder H.264 đã chọn theo kích thước (khoá = w shl 32 | h; giá trị
     * null = không encoder nào hỗ trợ). Danh sách codec không đổi suốt đời
     * tiến trình nên cache an toàn; chỉ dùng dưới codecLock.
     */
    private val avcEncoderBySize = HashMap<Long, MediaCodecInfo?>()
    // Đọc từ luồng client (DESCRIBE) và luồng gửi: volatile.
    @Volatile private var sps: ByteArray? = null
    @Volatile private var pps: ByteArray? = null
    private val codecLock = Any()
    private val feedbackLock = Any()
    // Ghi dưới feedbackLock; đọc không khoá (ước lượng hàng chờ) nên volatile.
    @Volatile private var currentBitrate = bitrate.coerceAtLeast(MIN_RTSP_BITRATE)
    private var maximumAdaptiveBitrate = currentBitrate
    private var healthyReceiverReports = 0
    private val encoderExecutor = Executors.newSingleThreadExecutor { task ->
        Thread(task, "VNVAR-RTSP-Encoder").apply { isDaemon = true }
    }
    /** Đóng các phiên không tới được PLAY trong [HANDSHAKE_DEADLINE_MS]. */
    private val handshakeWatchdog = Executors.newSingleThreadScheduledExecutor { task ->
        Thread(task, "VNVAR-RTSP-Watchdog").apply { isDaemon = true }
    }
    private val framePending = AtomicBoolean(false)
    /**
     * Khung đã retain() đang chờ luồng encoder. stop() (hoặc task bị bỏ khi
     * executor tắt) lấy ra và release() để không rò VideoFrame của camera.
     */
    private val pendingFrame = AtomicReference<VideoFrame?>(null)
    private val encoderReady = AtomicBoolean(false)
    private val encoderErrorReported = AtomicBoolean(false)
    /**
     * Sau khi đã báo lỗi encoder cho Dart thì ngừng encode (không tạo lại codec
     * và không log stack trace mỗi khung) cho tới khi Dart start phiên mới.
     */
    @Volatile private var encoderFailed = false
    private val lastSyncFrameRequestNanos = AtomicLong(0L)
    @Volatile private var streamStartNanos = -1L
    private var lastInputPtsUs = -1L
    private var lastOutputRtpTimestamp = -1L

    fun start() {
        if (!running.compareAndSet(false, true)) return
        // Publisher khác (vd của Activity cũ chưa bị huỷ / bị rò) còn giữ cổng:
        // dừng nó trước khi bind, nếu không startRtsp sẽ BindException mãi.
        val previous = activePublishersByPort.put(port, this)
        if (previous != null && previous !== this) {
            Log.w(TAG, "Stopping previous RTSP publisher ${previous.publisherId} still bound to :$port")
            try { previous.stop() } catch (error: Exception) {
                Log.w(TAG, "Unable to stop previous RTSP publisher", error)
            }
        }
        try {
            // reuseAddress phải đặt TRƯỚC bind mới có tác dụng (cổng còn TIME_WAIT
            // sau khi phiên cũ vừa đóng).
            serverSocket = ServerSocket().apply {
                reuseAddress = true
                bind(InetSocketAddress(port))
            }
            track.addSink(this)
        } catch (error: Exception) {
            running.set(false)
            activePublishersByPort.remove(port, this)
            try { serverSocket?.close() } catch (_: Exception) {}
            serverSocket = null
            throw error
        }
        thread(name = "VNVAR-RTSP-Accept", isDaemon = true) {
            while (running.get()) {
                try {
                    val socket = serverSocket?.accept() ?: break
                    acceptClient(socket)
                } catch (error: Throwable) {
                    if (running.get()) Log.e(TAG, "RTSP accept failed", error)
                }
            }
        }
        Log.i(TAG, "RTSP started on 0.0.0.0:$port/camera")
    }

    private fun acceptClient(socket: Socket) {
        var session: Session? = null
        try {
            val loopback = isLoopbackRemote(socket.inetAddress)
            // Giữ sẵn slot cho relay FFmpeg loopback: Tablet/LAN đầy không được
            // chặn livestream. (Không thêm xác thực — ràng buộc của dự án.)
            val totalClients = sessions.size
            val networkClients = if (loopback) 0 else sessions.values.count { !it.isLoopbackClient }
            val networkLimit = MAX_RTSP_CLIENTS - RESERVED_LOOPBACK_SLOTS
            if (totalClients >= MAX_RTSP_CLIENTS || (!loopback && networkClients >= networkLimit)) {
                Log.w(
                    TAG,
                    "Rejecting RTSP client (loopback=$loopback): total=$totalClients/$MAX_RTSP_CLIENTS, " +
                        "network=$networkClients/$networkLimit",
                )
                try { socket.close() } catch (_: Exception) {}
                return
            }
            socket.tcpNoDelay = true
            // Client mạng: bộ đệm nhỏ để nghẽn lộ ra ở hàng chờ (bị cắt theo
            // thời gian) thay vì nằm im vài giây trong kernel. Relay FFmpeg
            // loopback giữ bộ đệm lớn.
            socket.sendBufferSize = if (loopback) {
                LOOPBACK_SEND_BUFFER_BYTES
            } else {
                CLIENT_SEND_BUFFER_BYTES
            }
            socket.soTimeout = HANDSHAKE_READ_TIMEOUT_MS
            val created = Session(socket)
            session = created
            sessions[created.id] = created
            try {
                handshakeWatchdog.schedule(Runnable {
                    try {
                        if (!created.hasPlayed) {
                            Log.w(TAG, "Closing RTSP client ${created.id}: no PLAY within ${HANDSHAKE_DEADLINE_MS} ms")
                            sessions.remove(created.id)
                            created.close()
                        }
                    } catch (error: Throwable) {
                        Log.w(TAG, "RTSP handshake watchdog failed", error)
                    }
                }, HANDSHAKE_DEADLINE_MS, TimeUnit.MILLISECONDS)
            } catch (_: Exception) {
                // Watchdog đã tắt (publisher đang dừng): soTimeout vẫn bảo vệ.
            }
            thread(name = "VNVAR-RTSP-Client", isDaemon = true) {
                handleClient(created)
            }
        } catch (error: Throwable) {
            val created = session
            if (created != null) {
                sessions.remove(created.id)
                created.close()
            } else {
                try { socket.close() } catch (_: Exception) {}
            }
            throw error
        }
    }

    override fun onFrame(frame: VideoFrame) {
        if (!running.get() || encoderFailed) return
        // WebRTC owns the capture thread. Never run H.264 conversion/encoding on
        // that thread, otherwise the Tablet stream loses reference frames and
        // shows green macroblocks. Once SPS/PPS are ready, sleep while nobody is
        // watching RTSP so WebRTC and recording keep the device encoder budget.
        if (sps != null && pps != null && sessions.values.none { it.playing }) return
        if (!framePending.compareAndSet(false, true)) return
        frame.retain()
        pendingFrame.getAndSet(frame)?.release()
        if (!running.get()) {
            // stop() chạy xen giữa: tự dọn khung vừa giữ.
            pendingFrame.getAndSet(null)?.release()
            framePending.set(false)
            return
        }
        try {
            encoderExecutor.execute {
                val queued = pendingFrame.getAndSet(null)
                try {
                    if (queued != null) encodeFrame(queued)
                } catch (error: Throwable) {
                    // Không để Error (OOM...) lọt khỏi luồng executor và giết process.
                    Log.e(TAG, "H264 encoder task failed", error)
                    reportEncoderError(error)
                } finally {
                    queued?.release()
                    framePending.set(false)
                }
            }
        } catch (error: Exception) {
            // Executor đã tắt (stop) hoặc từ chối: task sẽ không chạy.
            pendingFrame.getAndSet(null)?.release()
            framePending.set(false)
            if (running.get()) reportEncoderError(error)
        }
    }

    private fun encodeFrame(frame: VideoFrame) {
        synchronized(codecLock) {
            // Kiểm tra lại dưới khoá: stop() có thể vừa giải phóng codec; không
            // được tạo encoder mới (rò MediaCodec) hay báo "configured" sau stop.
            if (!running.get() || encoderFailed) return
            try {
                val i420 = frame.buffer.toI420() ?: return
                try {
                    val rotation = normalizeRotation(frame.rotation)
                    val swapsAxes = rotation == 90 || rotation == 270
                    val outWidth = if (swapsAxes) i420.height else i420.width
                    val outHeight = if (swapsAxes) i420.width else i420.height
                    // Client RTSP (Tablet) không thể đổi kích thước video giữa
                    // phiên H.264: SPS đổi kích thước làm decoder đứng hình tới
                    // khi máy quay về góc ban đầu. Giống iOS
                    // (VnvarWebRtcTrackBridge.m): canvas encoder chốt theo kích
                    // thước SAU KHI XOAY của khung đầu tiên (camera Android gần
                    // như luôn cho buffer ngang + rotation 90/270, nên máy đặt
                    // dọc từ đầu phải ra canvas dọc, ảnh đầy khung). Xoay máy
                    // giữa phiên KHÔNG dựng lại encoder: khung lệch hướng được
                    // đặt vào canvas cũ (letterbox/pillarbox, writeFittedFrame).
                    // Chỉ dựng lại encoder khi độ phân giải nguồn (chưa xoay)
                    // thật sự đổi; nguồn chỉ hoán đổi rộng/cao vẫn coi là cùng nguồn.
                    val sourceW = i420.width and 1.inv()
                    val sourceH = i420.height and 1.inv()
                    val sameSource = (sourceW == encoderSourceWidth && sourceH == encoderSourceHeight) ||
                        (sourceW == encoderSourceHeight && sourceH == encoderSourceWidth)
                    if (codec == null || !sameSource) {
                        // Một số encoder phần cứng giới hạn chiều cao (vd. ≤1088)
                        // nên không nhận canvas dọc (vd. 1080x1920). Chỉ dùng
                        // canvas dọc khi encoder được chọn cho nó là phần cứng;
                        // nếu chỉ encoder phần mềm nhận canvas dọc mà phần cứng
                        // nhận canvas nguồn (chưa xoay) thì lùi về canvas nguồn
                        // (letterbox) để tránh nóng máy/rớt khung. Không có phần
                        // cứng cho cả hai: giữ hành vi cũ (dọc nếu có encoder nào nhận).
                        val rotatedCanvasSupported = if (!swapsAxes) {
                            true
                        } else {
                            val rotatedEncoder = selectAvcEncoder(outWidth and 1.inv(), outHeight and 1.inv())
                            if (rotatedEncoder != null && !isSoftwareEncoder(rotatedEncoder)) {
                                true
                            } else {
                                val sourceEncoder = selectAvcEncoder(sourceW, sourceH)
                                val sourceHardware = sourceEncoder != null && !isSoftwareEncoder(sourceEncoder)
                                !sourceHardware && rotatedEncoder != null
                            }
                        }
                        if (rotatedCanvasSupported) {
                            configureEncoder(outWidth, outHeight)
                        } else {
                            Log.w(TAG, "H264 encoder không hỗ trợ canvas ${outWidth}x$outHeight; dùng canvas nguồn")
                            configureEncoder(i420.width, i420.height)
                        }
                        encoderSourceWidth = sourceW
                        encoderSourceHeight = sourceH
                    }
                    drainEncoder()
                    val encoder = codec ?: return
                    val index = encoder.dequeueInputBuffer(0)
                    if (index >= 0) {
                        // COLOR_FormatYUV420Flexible (nv12 = false): khung I420
                        // liền khít rồi chép sang Image theo stride của encoder.
                        val nv12 = encoderColorFormat ==
                            MediaCodecInfo.CodecCapabilities.COLOR_FormatYUV420SemiPlanar
                        val queuedSize: Int
                        if (encoderPackedLayout) {
                            // Encoder báo đúng stride == rộng, slice-height == cao:
                            // ghi thẳng vào input buffer (không chép thêm).
                            val input = encoder.getInputBuffer(index) ?: return
                            input.clear()
                            writePackedFrame(i420, rotation, outWidth, outHeight, nv12, input)
                            queuedSize = input.position()
                        } else {
                            // Bố cục có đệm (stride/slice-height) hoặc chưa rõ: ghi
                            // khung liền khít vào bộ đệm dùng lại, rồi chép theo
                            // rowStride/pixelStride của Image (hoặc KEY_STRIDE).
                            val packed = packedFrameBuffer()
                            writePackedFrame(i420, rotation, outWidth, outHeight, nv12, packed)
                            queuedSize = writeStridedInput(encoder, index, packed, nv12)
                        }
                        val nowNanos = android.os.SystemClock.elapsedRealtimeNanos()
                        if (streamStartNanos < 0L) {
                            streamStartNanos = nowNanos
                        }
                        val elapsedUs = (nowNanos - streamStartNanos) / 1000L
                        val inputPtsUs = if (lastInputPtsUs != -1L && elapsedUs <= lastInputPtsUs) {
                            lastInputPtsUs + (1_000_000L / fps)
                        } else {
                            elapsedUs
                        }
                        lastInputPtsUs = inputPtsUs
                        encoder.queueInputBuffer(index, 0, queuedSize, inputPtsUs, 0)
                        drainEncoder()
                    }
                } finally {
                    i420.release()
                }
            } catch (error: Exception) {
                Log.e(TAG, "H264 frame encode failed", error)
                reportEncoderError(error)
            }
        }
    }

    private fun normalizeRotation(rotation: Int): Int = when (((rotation % 360) + 360) % 360) {
        90 -> 90
        180 -> 180
        270 -> 270
        else -> 0
    }

    private fun reportEncoderError(error: Throwable) {
        encoderReady.set(false)
        // Ngừng encode tới khi Dart khởi động phiên mới (Dart tự thử lại).
        encoderFailed = true
        if (!running.get()) return
        if (!encoderErrorReported.compareAndSet(false, true)) return
        val message = error.message?.takeIf { it.isNotBlank() }
            ?: error.javaClass.simpleName
        onEncoderError(publisherId, message)
    }

    /** false sau lần đầu libyuv lỗi trên máy này: dùng đường Kotlin dự phòng. */
    @Volatile
    private var nativeYuvAvailable = true
    private var rotateScratch: ByteBuffer? = null

    /**
     * Ghi khung I420 vào input buffer của encoder bằng libyuv (YuvHelper, có
     * SIMD/NEON), thay cho vòng lặp Kotlin từng byte vốn tốn CPU và làm nóng
     * máy khi livestream. Bố cục đầu ra giữ đúng như đường Kotlin: plane Y liền
     * khít, sau đó UV xen kẽ (NV12) hoặc U rồi V (I420). Trả về false để dùng
     * đường dự phòng.
     */
    private fun writeFrameNative(
        i420: VideoFrame.I420Buffer,
        rotation: Int,
        nv12: Boolean,
        input: ByteBuffer,
    ): Boolean {
        if (!nativeYuvAvailable) return false
        val swapsAxes = rotation == 90 || rotation == 270
        // Kích thước khung SAU khi xoay (90/270 hoán đổi rộng/cao).
        val frameWidth = if (swapsAxes) i420.height else i420.width
        val frameHeight = if (swapsAxes) i420.width else i420.height
        val chromaWidth = (frameWidth + 1) / 2
        val chromaHeight = (frameHeight + 1) / 2
        val lumaSize = frameWidth * frameHeight
        val chromaSize = chromaWidth * chromaHeight
        val outputSize = lumaSize + 2 * chromaSize
        if (input.capacity() < outputSize) return false
        return try {
            var srcY = i420.dataY
            var srcStrideY = i420.strideY
            var srcU = i420.dataU
            var srcStrideU = i420.strideU
            var srcV = i420.dataV
            var srcStrideV = i420.strideV
            if (rotation != 0) {
                val scratch = rotateScratch?.takeIf { it.capacity() >= outputSize }
                    ?: ByteBuffer.allocateDirect(outputSize).also { rotateScratch = it }
                val dstY = planeSlice(scratch, 0, lumaSize)
                val dstU = planeSlice(scratch, lumaSize, chromaSize)
                val dstV = planeSlice(scratch, lumaSize + chromaSize, chromaSize)
                // libyuv: srcWidth/srcHeight là kích thước nguồn (trước xoay);
                // stride đích theo chiều rộng sau xoay.
                YuvHelper.I420Rotate(
                    srcY, srcStrideY, srcU, srcStrideU, srcV, srcStrideV,
                    dstY, frameWidth, dstU, chromaWidth, dstV, chromaWidth,
                    i420.width, i420.height, rotation,
                )
                srcY = dstY
                srcStrideY = frameWidth
                srcU = dstU
                srcStrideU = chromaWidth
                srcV = dstV
                srcStrideV = chromaWidth
            }
            if (nv12) {
                YuvHelper.I420ToNV12(
                    srcY, srcStrideY, srcU, srcStrideU, srcV, srcStrideV,
                    planeSlice(input, 0, lumaSize), frameWidth,
                    planeSlice(input, lumaSize, 2 * chromaSize), 2 * chromaWidth,
                    frameWidth, frameHeight,
                )
            } else {
                YuvHelper.I420Copy(
                    srcY, srcStrideY, srcU, srcStrideU, srcV, srcStrideV,
                    planeSlice(input, 0, lumaSize), frameWidth,
                    planeSlice(input, lumaSize, chromaSize), chromaWidth,
                    planeSlice(input, lumaSize + chromaSize, chromaSize), chromaWidth,
                    frameWidth, frameHeight,
                )
            }
            input.position(outputSize)
            true
        } catch (error: Throwable) {
            // UnsatisfiedLinkError / IllegalArgumentException trên một số bản build.
            nativeYuvAvailable = false
            Log.w(TAG, "libyuv conversion unavailable; using Kotlin fallback", error)
            false
        }
    }

    /**
     * true khi inputFormat của encoder báo rõ stride == rộng và slice-height ==
     * cao: khung liền khít ghi thẳng vào input buffer. Ngược lại (có đệm căn
     * hàng, hoặc encoder không báo) phải chép theo bố cục thật. Dưới codecLock.
     */
    private var encoderPackedLayout = true
    /** KEY_STRIDE / KEY_SLICE_HEIGHT của input (đã chặn dưới bởi rộng/cao). */
    private var encoderStride = 0
    private var encoderSliceHeight = 0
    /** Khung liền khít trước khi chép sang bố cục có đệm; dùng lại giữa các khung. */
    private var packedFrame: ByteBuffer? = null
    private var imageRowBuffer = ByteArray(0)
    private var inputImageErrorLogged = false

    /** Ghi khung (đã xoay/đặt vào canvas) dạng liền khít I420/NV12 vào [target]. */
    private fun writePackedFrame(
        i420: VideoFrame.I420Buffer,
        rotation: Int,
        outWidth: Int,
        outHeight: Int,
        nv12: Boolean,
        target: ByteBuffer,
    ) {
        if (outWidth == width && outHeight == height) {
            // Khung sau xoay khớp đúng canvas: đường cũ.
            if (!writeFrameNative(i420, rotation, nv12, target)) {
                target.clear()
                writeFrameKotlin(i420, rotation, nv12, target)
            }
        } else {
            writeFittedFrame(i420, rotation, nv12, target)
        }
    }

    private fun packedFrameBuffer(): ByteBuffer {
        val size = width * height + 2 * (width / 2) * (height / 2)
        val buffer = packedFrame?.takeIf { it.capacity() >= size }
            ?: ByteBuffer.allocateDirect(size).also { packedFrame = it }
        buffer.clear()
        return buffer
    }

    /** Đọc stride/slice-height mà encoder yêu cầu cho input (gọi sau configure/start). */
    private fun readEncoderInputLayout(encoder: MediaCodec) {
        val format = try { encoder.inputFormat } catch (_: Exception) { null }
        fun intOrZero(key: String): Int = try {
            if (format != null && format.containsKey(key)) format.getInteger(key) else 0
        } catch (_: Exception) {
            0
        }
        // Dùng chuỗi khoá ("stride", "slice-height") thay hằng KEY_* (API 23).
        val stride = intOrZero("stride")
        val sliceHeight = intOrZero("slice-height")
        encoderStride = if (stride >= width) stride else width
        encoderSliceHeight = if (sliceHeight >= height) sliceHeight else height
        encoderPackedLayout = encoderColorFormat != MediaCodecInfo.CodecCapabilities.COLOR_FormatYUV420Flexible &&
            stride == width && sliceHeight == height
        Log.i(
            TAG,
            "H264 input layout: stride=$stride, sliceHeight=$sliceHeight, " +
                "packed=$encoderPackedLayout (${width}x$height)",
        )
    }

    /**
     * Chép khung liền khít [packed] vào input [index] theo bố cục thật của
     * encoder: ưu tiên getInputImage (rowStride/pixelStride của từng plane);
     * nếu null thì theo KEY_STRIDE/KEY_SLICE_HEIGHT. Trả số byte để queue.
     */
    private fun writeStridedInput(
        encoder: MediaCodec,
        index: Int,
        packed: ByteBuffer,
        nv12: Boolean,
    ): Int {
        // Lấy dung lượng TRƯỚC getInputImage: gọi getInputBuffer sau đó sẽ vô
        // hiệu hoá Image vừa nhận.
        val capacity = encoder.getInputBuffer(index)?.capacity()
            ?: throw IllegalStateException("Encoder không trả input buffer $index")
        val image = try {
            encoder.getInputImage(index)
        } catch (error: Exception) {
            if (!inputImageErrorLogged) {
                inputImageErrorLogged = true
                Log.w(TAG, "getInputImage failed; using KEY_STRIDE layout", error)
            }
            null
        }
        if (image != null) {
            // Không close(): MediaCodec tự vô hiệu Image khi queueInputBuffer.
            copyPackedToImage(packed, image, nv12)
            return capacity
        }
        if (encoderColorFormat == MediaCodecInfo.CodecCapabilities.COLOR_FormatYUV420Flexible) {
            throw IllegalStateException("Encoder YUV420Flexible không cấp Image cho input")
        }
        val input = encoder.getInputBuffer(index)
            ?: throw IllegalStateException("Encoder không trả input buffer $index")
        return copyPackedToStrided(packed, input, nv12)
    }

    private fun copyPackedToImage(packed: ByteBuffer, image: android.media.Image, nv12: Boolean) {
        val planes = image.planes
        if (planes.size < 3) {
            throw IllegalStateException("Image input của encoder chỉ có ${planes.size} plane")
        }
        val cols = minOf(width, image.width) and 1.inv()
        val rows = minOf(height, image.height) and 1.inv()
        val chromaCols = cols / 2
        val chromaRows = rows / 2
        val lumaSize = width * height
        val chromaSize = (width / 2) * (height / 2)
        copyPlaneToImage(packed, 0, width, 1, cols, rows, planes[0])
        if (nv12) {
            val u = planes[1]
            val v = planes[2]
            if (encoderColorFormat == MediaCodecInfo.CodecCapabilities.COLOR_FormatYUV420SemiPlanar &&
                u.pixelStride == 2 && v.pixelStride == 2 && u.rowStride == v.rowStride
            ) {
                copyNv12ToImage(packed, lumaSize, width, chromaCols, chromaRows, u, v)
            } else {
                copyPlaneToImage(packed, lumaSize, width, 2, chromaCols, chromaRows, u)
                copyPlaneToImage(packed, lumaSize + 1, width, 2, chromaCols, chromaRows, v)
            }
        } else {
            copyPlaneToImage(packed, lumaSize, width / 2, 1, chromaCols, chromaRows, planes[1])
            copyPlaneToImage(packed, lumaSize + chromaSize, width / 2, 1, chromaCols, chromaRows, planes[2])
        }
    }

    /** Chép một plane (nguồn liền khít, bước [srcPixelStride]) vào plane của Image. */
    private fun copyPlaneToImage(
        packed: ByteBuffer,
        srcOffset: Int,
        srcRowStride: Int,
        srcPixelStride: Int,
        cols: Int,
        rows: Int,
        plane: android.media.Image.Plane,
    ) {
        if (cols <= 0 || rows <= 0) return
        val dst = plane.buffer.duplicate()
        val dstRowStride = plane.rowStride
        val dstPixelStride = plane.pixelStride
        val source = packed.duplicate()
        if (srcPixelStride == 1 && dstPixelStride == 1) {
            for (row in 0 until rows) {
                val start = srcOffset + row * srcRowStride
                source.clear()
                source.position(start)
                source.limit(start + cols)
                dst.position(row * dstRowStride)
                dst.put(source)
            }
            return
        }
        val rowBytes = (cols - 1) * srcPixelStride + 1
        if (imageRowBuffer.size < rowBytes) imageRowBuffer = ByteArray(rowBytes)
        val rowData = imageRowBuffer
        for (row in 0 until rows) {
            source.clear()
            source.position(srcOffset + row * srcRowStride)
            source.get(rowData, 0, rowBytes)
            var srcIndex = 0
            var dstIndex = row * dstRowStride
            for (column in 0 until cols) {
                dst.put(dstIndex, rowData[srcIndex])
                srcIndex += srcPixelStride
                dstIndex += dstPixelStride
            }
        }
    }

    /**
     * NV12 → Image NV12 (pixelStride 2, V = U + 1): chép cả hàng UV một lần qua
     * plane U; byte V cuối hàng nằm ngoài giới hạn plane U nên ghi qua plane V.
     */
    private fun copyNv12ToImage(
        packed: ByteBuffer,
        uvOffset: Int,
        srcRowStride: Int,
        chromaCols: Int,
        chromaRows: Int,
        u: android.media.Image.Plane,
        v: android.media.Image.Plane,
    ) {
        if (chromaCols <= 0 || chromaRows <= 0) return
        val rowBytes = chromaCols * 2
        val span = rowBytes - 1
        if (imageRowBuffer.size < rowBytes) imageRowBuffer = ByteArray(rowBytes)
        val rowData = imageRowBuffer
        val dstU = u.buffer.duplicate()
        val dstV = v.buffer.duplicate()
        val source = packed.duplicate()
        for (row in 0 until chromaRows) {
            source.clear()
            source.position(uvOffset + row * srcRowStride)
            source.get(rowData, 0, rowBytes)
            dstU.position(row * u.rowStride)
            dstU.put(rowData, 0, span)
            dstV.put(row * v.rowStride + (chromaCols - 1) * 2, rowData[span])
        }
    }

    /** Dự phòng khi không có Image: bố cục theo KEY_STRIDE/KEY_SLICE_HEIGHT. */
    private fun copyPackedToStrided(packed: ByteBuffer, input: ByteBuffer, nv12: Boolean): Int {
        val stride = encoderStride.coerceAtLeast(width)
        val sliceHeight = encoderSliceHeight.coerceAtLeast(height)
        val chromaW = width / 2
        val chromaH = height / 2
        val lumaSize = width * height
        val chromaSize = chromaW * chromaH
        val chromaBase = stride * sliceHeight
        val chromaStride = stride / 2
        val vBase = chromaBase + chromaStride * (sliceHeight / 2)
        val required: Int
        val queued: Int
        if (nv12) {
            required = chromaBase + stride * (chromaH - 1) + width
            queued = chromaBase + stride * chromaH
        } else {
            required = vBase + chromaStride * (chromaH - 1) + chromaW
            queued = vBase + chromaStride * chromaH
        }
        if (input.capacity() < required) {
            throw IllegalStateException(
                "Input buffer encoder ${input.capacity()} < $required (stride=$stride, slice=$sliceHeight)",
            )
        }
        input.clear()
        val source = packed.duplicate()
        copyRows(source, 0, width, input, 0, stride, width, height)
        if (nv12) {
            copyRows(source, lumaSize, width, input, chromaBase, stride, width, chromaH)
        } else {
            copyRows(source, lumaSize, chromaW, input, chromaBase, chromaStride, chromaW, chromaH)
            copyRows(source, lumaSize + chromaSize, chromaW, input, vBase, chromaStride, chromaW, chromaH)
        }
        return minOf(queued, input.capacity())
    }

    private fun copyRows(
        source: ByteBuffer,
        srcOffset: Int,
        srcStride: Int,
        target: ByteBuffer,
        dstOffset: Int,
        dstStride: Int,
        rowBytes: Int,
        rows: Int,
    ) {
        for (row in 0 until rows) {
            val start = srcOffset + row * srcStride
            source.clear()
            source.position(start)
            source.limit(start + rowBytes)
            target.position(dstOffset + row * dstStride)
            target.put(source)
        }
    }

    /** Vùng [offset, offset + length) của [buffer] làm buffer riêng (địa chỉ gốc mới cho JNI). */
    private fun planeSlice(buffer: ByteBuffer, offset: Int, length: Int): ByteBuffer {
        val view = buffer.duplicate()
        view.clear()
        view.position(offset)
        view.limit(offset + length)
        return view.slice()
    }

    /** Khung I420 liền khít của ảnh đã thu nhỏ + xoay, trước khi đặt vào canvas. */
    private var fitScratch: ByteBuffer? = null
    /** Khung đen (Y=16, U=V=128) đúng kích thước canvas; I420 và NV12 có cùng byte. */
    private var blackCanvas: ByteBuffer? = null

    /**
     * Khung sau xoay khác hướng/kích thước canvas (ví dụ xoay máy giữa phiên;
     * canvas chốt theo hướng sau xoay của khung đầu tiên):
     * thu nhỏ giữ tỉ lệ, xoay, đặt giữa canvas [width]×[height] với viền đen —
     * như VnvarRenderFitted của iOS — để SPS không bao giờ đổi kích thước.
     */
    private fun writeFittedFrame(
        i420: VideoFrame.I420Buffer,
        rotation: Int,
        nv12: Boolean,
        input: ByteBuffer,
    ) {
        val canvasW = width
        val canvasH = height
        val chromaW = canvasW / 2
        val chromaH = canvasH / 2
        val lumaSize = canvasW * canvasH
        val outputSize = lumaSize + 2 * chromaW * chromaH
        if (input.capacity() < outputSize) {
            throw IllegalStateException("Input buffer encoder nhỏ hơn khung ${canvasW}x$canvasH")
        }
        val swapsAxes = rotation == 90 || rotation == 270
        val rotatedW = if (swapsAxes) i420.height else i420.width
        val rotatedH = if (swapsAxes) i420.width else i420.height
        val scale = minOf(
            canvasW.toDouble() / maxOf(1, rotatedW),
            canvasH.toDouble() / maxOf(1, rotatedH),
        )
        // Kích thước/offset chẵn để plane chroma (1/2) thẳng hàng.
        val fitW = ((rotatedW * scale).toInt() and 1.inv()).coerceIn(2, canvasW)
        val fitH = ((rotatedH * scale).toInt() and 1.inv()).coerceIn(2, canvasH)
        val offsetX = ((canvasW - fitW) / 2) and 1.inv()
        val offsetY = ((canvasH - fitH) / 2) and 1.inv()
        // Thu nhỏ TRƯỚC khi xoay (ít điểm ảnh hơn): kích thước trước xoay.
        val scaledW = if (swapsAxes) fitH else fitW
        val scaledH = if (swapsAxes) fitW else fitH
        val scaledBuffer: VideoFrame.Buffer? =
            if (scaledW == i420.width && scaledH == i420.height) {
                null
            } else {
                i420.cropAndScale(0, 0, i420.width, i420.height, scaledW, scaledH)
            }
        var scaledI420: VideoFrame.I420Buffer? = null
        try {
            val source: VideoFrame.I420Buffer = if (scaledBuffer == null) {
                i420
            } else {
                (scaledBuffer.toI420() ?: throw IllegalStateException("cropAndScale toI420() trả null"))
                    .also { scaledI420 = it }
            }
            val fitChromaW = fitW / 2
            val fitChromaH = fitH / 2
            var srcY = source.dataY
            var srcStrideY = source.strideY
            var srcU = source.dataU
            var srcStrideU = source.strideU
            var srcV = source.dataV
            var srcStrideV = source.strideV
            if (rotation != 0) {
                val fitLuma = fitW * fitH
                val fitChroma = fitChromaW * fitChromaH
                val fitSize = fitLuma + 2 * fitChroma
                val fitted = fitScratch?.takeIf { it.capacity() >= fitSize }
                    ?: ByteBuffer.allocateDirect(fitSize).also { fitScratch = it }
                fitted.clear()
                // Ghi I420 liền khít (nv12 = false) của ảnh đã xoay fitW×fitH.
                if (!writeFrameNative(source, rotation, false, fitted)) {
                    fitted.clear()
                    writeFrameKotlin(source, rotation, false, fitted)
                }
                srcY = planeSlice(fitted, 0, fitLuma)
                srcStrideY = fitW
                srcU = planeSlice(fitted, fitLuma, fitChroma)
                srcStrideU = fitChromaW
                srcV = planeSlice(fitted, fitLuma + fitChroma, fitChroma)
                srcStrideV = fitChromaW
            }
            // Nền đen cả canvas (memcpy), rồi chép ảnh vào giữa.
            val black = blackCanvas?.takeIf { it.capacity() == outputSize }
                ?: ByteBuffer.allocateDirect(outputSize).also { buffer ->
                    for (index in 0 until lumaSize) buffer.put(index, 16.toByte())
                    for (index in lumaSize until outputSize) buffer.put(index, 128.toByte())
                    blackCanvas = buffer
                }
            input.clear()
            input.put(black.duplicate().apply { clear() })
            val lumaOffset = offsetY * canvasW + offsetX
            val chromaOffset = (offsetY / 2) * chromaW + offsetX / 2
            if (!composeNative(
                    srcY, srcStrideY, srcU, srcStrideU, srcV, srcStrideV,
                    fitW, fitH, lumaOffset, chromaOffset, canvasW, lumaSize, outputSize,
                    nv12, input,
                )
            ) {
                composeKotlin(
                    srcY, srcStrideY, srcU, srcStrideU, srcV, srcStrideV,
                    fitW, fitH, offsetX, offsetY, canvasW, canvasH, nv12, input,
                )
            }
            input.position(outputSize)
        } finally {
            // toI420() của JavaI420Buffer retain() rồi trả chính nó: nhả cả hai.
            scaledI420?.release()
            scaledBuffer?.release()
        }
    }

    /** Chép vùng ảnh fitW×fitH vào canvas trong [input] bằng libyuv. */
    private fun composeNative(
        srcY: ByteBuffer, srcStrideY: Int,
        srcU: ByteBuffer, srcStrideU: Int,
        srcV: ByteBuffer, srcStrideV: Int,
        fitW: Int, fitH: Int,
        lumaOffset: Int, chromaOffset: Int,
        canvasW: Int, lumaSize: Int, outputSize: Int,
        nv12: Boolean, input: ByteBuffer,
    ): Boolean {
        if (!nativeYuvAvailable) return false
        val chromaW = canvasW / 2
        val chromaSize = (outputSize - lumaSize) / 2
        return try {
            // Mỗi lát bắt đầu tại góc trên-trái của vùng ảnh, kéo tới hết khung:
            // libyuv chỉ ghi fit* byte mỗi hàng nên không chạm viền.
            val dstY = planeSlice(input, lumaOffset, outputSize - lumaOffset)
            if (nv12) {
                val uvOffset = lumaSize + chromaOffset * 2
                YuvHelper.I420ToNV12(
                    srcY, srcStrideY, srcU, srcStrideU, srcV, srcStrideV,
                    dstY, canvasW,
                    planeSlice(input, uvOffset, outputSize - uvOffset), canvasW,
                    fitW, fitH,
                )
            } else {
                val uOffset = lumaSize + chromaOffset
                val vOffset = lumaSize + chromaSize + chromaOffset
                YuvHelper.I420Copy(
                    srcY, srcStrideY, srcU, srcStrideU, srcV, srcStrideV,
                    dstY, canvasW,
                    planeSlice(input, uOffset, outputSize - uOffset), chromaW,
                    planeSlice(input, vOffset, outputSize - vOffset), chromaW,
                    fitW, fitH,
                )
            }
            true
        } catch (error: Throwable) {
            nativeYuvAvailable = false
            Log.w(TAG, "libyuv compose unavailable; using Kotlin fallback", error)
            false
        }
    }

    /** Dự phòng: chép vùng ảnh vào canvas (đã tô đen) bằng Kotlin, theo hàng. */
    private fun composeKotlin(
        srcY: ByteBuffer, srcStrideY: Int,
        srcU: ByteBuffer, srcStrideU: Int,
        srcV: ByteBuffer, srcStrideV: Int,
        fitW: Int, fitH: Int,
        offsetX: Int, offsetY: Int,
        canvasW: Int, canvasH: Int,
        nv12: Boolean, input: ByteBuffer,
    ) {
        val lumaSize = canvasW * canvasH
        val chromaW = canvasW / 2
        val chromaSize = chromaW * (canvasH / 2)
        val fitChromaW = fitW / 2
        val fitChromaH = fitH / 2
        val target = input.duplicate()
        target.clear()
        if (rowTransferBuffer.size < fitW) rowTransferBuffer = ByteArray(fitW)
        val y = srcY.duplicate()
        for (row in 0 until fitH) {
            y.position(row * srcStrideY)
            y.get(rowTransferBuffer, 0, fitW)
            target.position((offsetY + row) * canvasW + offsetX)
            target.put(rowTransferBuffer, 0, fitW)
        }
        if (uRowBuffer.size < fitChromaW) {
            uRowBuffer = ByteArray(fitChromaW)
            vRowBuffer = ByteArray(fitChromaW)
            nv12RowBuffer = ByteArray(fitChromaW * 2)
        }
        val u = srcU.duplicate()
        val v = srcV.duplicate()
        val chromaOffsetY = offsetY / 2
        val chromaOffsetX = offsetX / 2
        for (row in 0 until fitChromaH) {
            u.position(row * srcStrideU)
            u.get(uRowBuffer, 0, fitChromaW)
            v.position(row * srcStrideV)
            v.get(vRowBuffer, 0, fitChromaW)
            val canvasRow = chromaOffsetY + row
            if (nv12) {
                var outIdx = 0
                for (column in 0 until fitChromaW) {
                    nv12RowBuffer[outIdx++] = uRowBuffer[column]
                    nv12RowBuffer[outIdx++] = vRowBuffer[column]
                }
                target.position(lumaSize + canvasRow * canvasW + chromaOffsetX * 2)
                target.put(nv12RowBuffer, 0, outIdx)
            } else {
                target.position(lumaSize + canvasRow * chromaW + chromaOffsetX)
                target.put(uRowBuffer, 0, fitChromaW)
                target.position(lumaSize + chromaSize + canvasRow * chromaW + chromaOffsetX)
                target.put(vRowBuffer, 0, fitChromaW)
            }
        }
    }

    /** Đường dự phòng (cũ): copy từng hàng/byte bằng Kotlin. */
    private fun writeFrameKotlin(
        i420: VideoFrame.I420Buffer,
        rotation: Int,
        nv12: Boolean,
        input: ByteBuffer,
    ) {
        val chromaWidth = (i420.width + 1) / 2
        val chromaHeight = (i420.height + 1) / 2
        if (rotation == 90 || rotation == 270) {
            val y = rotatePlaneQuarter(i420.dataY, i420.strideY, i420.width, i420.height, rotation)
            input.put(y)
            val u = rotatePlaneQuarter(i420.dataU, i420.strideU, chromaWidth, chromaHeight, rotation)
            val v = rotatePlaneQuarter(i420.dataV, i420.strideV, chromaWidth, chromaHeight, rotation)
            if (nv12) {
                val interleaved = ByteArray(u.size * 2)
                var outIdx = 0
                for (index in u.indices) {
                    interleaved[outIdx++] = u[index]
                    interleaved[outIdx++] = v[index]
                }
                input.put(interleaved)
            } else {
                input.put(u)
                input.put(v)
            }
            return
        }
        if (rotation == 180) {
            copyPlaneRotated180(i420.dataY, i420.strideY, i420.width, i420.height, input)
            if (nv12) {
                copyNv12ChromaRotated180(i420, input)
            } else {
                copyPlaneRotated180(i420.dataU, i420.strideU, chromaWidth, chromaHeight, input)
                copyPlaneRotated180(i420.dataV, i420.strideV, chromaWidth, chromaHeight, input)
            }
        } else {
            copyPlane(i420.dataY, i420.strideY, i420.width, i420.height, input)
            if (nv12) {
                copyNv12Chroma(i420, input)
            } else {
                copyPlane(i420.dataU, i420.strideU, chromaWidth, chromaHeight, input)
                copyPlane(i420.dataV, i420.strideV, chromaWidth, chromaHeight, input)
            }
        }
    }

    /**
     * Đường dự phòng: xoay một plane 90° (theo chiều kim đồng hồ, như libyuv
     * kRotate90) hoặc 270°. Kết quả liền khít, rộng [rows] × cao [rowWidth].
     */
    private fun rotatePlaneQuarter(
        source: ByteBuffer,
        stride: Int,
        rowWidth: Int,
        rows: Int,
        rotation: Int,
    ): ByteArray {
        val packed = ByteArray(rowWidth * rows)
        val duplicate = source.duplicate()
        for (row in 0 until rows) {
            duplicate.position(row * stride)
            duplicate.get(packed, row * rowWidth, rowWidth)
        }
        val rotated = ByteArray(packed.size)
        // Ảnh đích: rộng = rows, cao = rowWidth.
        var outIdx = 0
        for (dstRow in 0 until rowWidth) {
            for (dstCol in 0 until rows) {
                val srcRow: Int
                val srcCol: Int
                if (rotation == 90) {
                    srcRow = rows - 1 - dstCol
                    srcCol = dstRow
                } else {
                    srcRow = dstCol
                    srcCol = rowWidth - 1 - dstRow
                }
                rotated[outIdx++] = packed[srcRow * rowWidth + srcCol]
            }
        }
        return rotated
    }

    private var uRowBuffer = ByteArray(0)
    private var vRowBuffer = ByteArray(0)
    private var nv12RowBuffer = ByteArray(0)
    private var rowTransferBuffer = ByteArray(0)

    private fun copyPlane(source: ByteBuffer, stride: Int, rowWidth: Int, rows: Int, target: ByteBuffer) {
        val duplicate = source.duplicate()
        if (stride == rowWidth) {
            duplicate.position(0)
            duplicate.limit(rowWidth * rows)
            target.put(duplicate)
        } else {
            if (rowTransferBuffer.size < rowWidth) {
                rowTransferBuffer = ByteArray(rowWidth)
            }
            for (row in 0 until rows) {
                duplicate.position(row * stride)
                duplicate.get(rowTransferBuffer, 0, rowWidth)
                target.put(rowTransferBuffer, 0, rowWidth)
            }
        }
    }

    private fun copyNv12Chroma(i420: VideoFrame.I420Buffer, target: ByteBuffer) {
        val chromaWidth = (i420.width + 1) / 2
        val chromaHeight = (i420.height + 1) / 2
        if (uRowBuffer.size < chromaWidth) {
            uRowBuffer = ByteArray(chromaWidth)
            vRowBuffer = ByteArray(chromaWidth)
            nv12RowBuffer = ByteArray(chromaWidth * 2)
        }
        val u = i420.dataU.duplicate()
        val v = i420.dataV.duplicate()
        for (row in 0 until chromaHeight) {
            u.position(row * i420.strideU)
            u.get(uRowBuffer, 0, chromaWidth)
            v.position(row * i420.strideV)
            v.get(vRowBuffer, 0, chromaWidth)
            var outIdx = 0
            for (column in 0 until chromaWidth) {
                nv12RowBuffer[outIdx++] = uRowBuffer[column]
                nv12RowBuffer[outIdx++] = vRowBuffer[column]
            }
            target.put(nv12RowBuffer, 0, outIdx)
        }
    }

    private fun copyPlaneRotated180(source: ByteBuffer, stride: Int, rowWidth: Int, rows: Int, target: ByteBuffer) {
        val duplicate = source.duplicate()
        if (rowTransferBuffer.size < rowWidth) {
            rowTransferBuffer = ByteArray(rowWidth)
        }
        for (row in rows - 1 downTo 0) {
            duplicate.position(row * stride)
            duplicate.get(rowTransferBuffer, 0, rowWidth)
            for (col in rowWidth - 1 downTo 0) {
                target.put(rowTransferBuffer[col])
            }
        }
    }

    private fun copyNv12ChromaRotated180(i420: VideoFrame.I420Buffer, target: ByteBuffer) {
        val chromaWidth = (i420.width + 1) / 2
        val chromaHeight = (i420.height + 1) / 2
        if (uRowBuffer.size < chromaWidth) {
            uRowBuffer = ByteArray(chromaWidth)
            vRowBuffer = ByteArray(chromaWidth)
            nv12RowBuffer = ByteArray(chromaWidth * 2)
        }
        val u = i420.dataU.duplicate()
        val v = i420.dataV.duplicate()
        for (row in chromaHeight - 1 downTo 0) {
            u.position(row * i420.strideU)
            u.get(uRowBuffer, 0, chromaWidth)
            v.position(row * i420.strideV)
            v.get(vRowBuffer, 0, chromaWidth)
            var outIdx = 0
            for (column in chromaWidth - 1 downTo 0) {
                nv12RowBuffer[outIdx++] = uRowBuffer[column]
                nv12RowBuffer[outIdx++] = vRowBuffer[column]
            }
            target.put(nv12RowBuffer, 0, outIdx)
        }
    }

    /** Encoder phần mềm (chạy CPU): xếp sau encoder phần cứng. */
    private fun isSoftwareEncoder(info: MediaCodecInfo): Boolean {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            if (!info.isHardwareAccelerated || info.isSoftwareOnly) return true
        }
        val name = info.name.lowercase(Locale.ROOT)
        return name.startsWith("omx.google.") || name.startsWith("c2.android.") ||
            name.contains(".sw.") || name.contains("google")
    }

    /**
     * Encoder H.264 sẽ dùng cho kích thước [w]×[h] (chẵn): phần cứng trước, phần
     * mềm sau; null nếu không encoder nào hỗ trợ. Dùng chung cho chọn canvas và
     * configureEncoder; kết quả được cache theo kích thước. Gọi dưới codecLock.
     */
    private fun selectAvcEncoder(w: Int, h: Int): MediaCodecInfo? {
        val key = (w.toLong() shl 32) or (h.toLong() and 0xffffffffL)
        if (avcEncoderBySize.containsKey(key)) return avcEncoderBySize[key]
        val selected = MediaCodecList(MediaCodecList.REGULAR_CODECS).codecInfos
            .filter { codec ->
                codec.isEncoder && codec.supportedTypes.any { type ->
                    type.equals(MediaFormat.MIMETYPE_VIDEO_AVC, ignoreCase = true)
                }
            }
            .sortedBy { codec -> if (isSoftwareEncoder(codec)) 1 else 0 }
            .firstOrNull { codec ->
                try {
                    codec.getCapabilitiesForType(MediaFormat.MIMETYPE_VIDEO_AVC)
                        .videoCapabilities.isSizeSupported(w, h)
                } catch (_: Exception) {
                    false
                }
            }
        avcEncoderBySize[key] = selected
        return selected
    }

    private fun configureEncoder(newWidth: Int, newHeight: Int) {
        // Gán null NGAY: nếu cấu hình mới lỗi, không còn tham chiếu tới codec
        // đã release (dùng lại sẽ ném IllegalStateException).
        val previous = codec
        codec = null
        if (previous != null) {
            try { previous.stop() } catch (_: Exception) {}
            try { previous.release() } catch (_: Exception) {}
        }
        width = newWidth and 1.inv()
        height = newHeight and 1.inv()
        sps = null
        pps = null
        streamStartNanos = -1L
        lastInputPtsUs = -1L
        lastOutputRtpTimestamp = -1L
        val codecInfo = selectAvcEncoder(width, height) ?: throw IllegalStateException(
            "Thiết bị không có H.264 encoder hỗ trợ ${width}x$height",
        )
        val capabilities = codecInfo.getCapabilitiesForType(MediaFormat.MIMETYPE_VIDEO_AVC)
        encoderColorFormat = when {
            capabilities.colorFormats.contains(MediaCodecInfo.CodecCapabilities.COLOR_FormatYUV420SemiPlanar) ->
                MediaCodecInfo.CodecCapabilities.COLOR_FormatYUV420SemiPlanar
            capabilities.colorFormats.contains(MediaCodecInfo.CodecCapabilities.COLOR_FormatYUV420Planar) ->
                MediaCodecInfo.CodecCapabilities.COLOR_FormatYUV420Planar
            // Chỉ nhận định dạng linh hoạt: ghi qua getInputImage (stride/plane thật).
            capabilities.colorFormats.contains(MediaCodecInfo.CodecCapabilities.COLOR_FormatYUV420Flexible) ->
                MediaCodecInfo.CodecCapabilities.COLOR_FormatYUV420Flexible
            else -> throw IllegalStateException(
                "H.264 encoder ${codecInfo.name} không nhận I420/NV12 ByteBuffer",
            )
        }
        val videoCapabilities = capabilities.videoCapabilities
        val supportedFps = try {
            val range = videoCapabilities.getSupportedFrameRatesFor(width, height)
            fps.coerceIn(maxOf(1, range.lower.toInt()), maxOf(1, range.upper.toInt()))
        } catch (_: Exception) {
            fps
        }
        val supportedBitrate = bitrate.coerceIn(
            videoCapabilities.bitrateRange.lower,
            videoCapabilities.bitrateRange.upper,
        )
        val startBitrate = synchronized(feedbackLock) {
            // Encoder dựng lại (đổi kích thước khung) giữ mức đã thích ứng.
            val keep = maximumAdaptiveBitrate.coerceIn(
                videoCapabilities.bitrateRange.lower,
                supportedBitrate,
            )
            currentBitrate = keep
            maximumAdaptiveBitrate = keep
            healthyReceiverReports = 0
            keep
        }
        val bitrateMode = if (
            capabilities.encoderCapabilities.isBitrateModeSupported(
                MediaCodecInfo.EncoderCapabilities.BITRATE_MODE_CBR,
            )
        ) MediaCodecInfo.EncoderCapabilities.BITRATE_MODE_CBR
        else MediaCodecInfo.EncoderCapabilities.BITRATE_MODE_VBR
        Log.i(
            TAG,
            "H264 encoder=${codecInfo.name}, ${width}x$height@${supportedFps}, " +
                "bitrate=$supportedBitrate, colorFormat=0x${encoderColorFormat.toString(16)}",
        )
        val created = MediaCodec.createByCodecName(codecInfo.name)
        try {
            val format = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_AVC, width, height)
            format.setInteger(MediaFormat.KEY_COLOR_FORMAT, encoderColorFormat)
            format.setInteger(MediaFormat.KEY_BIT_RATE, startBitrate)
            format.setInteger(MediaFormat.KEY_FRAME_RATE, supportedFps)
            format.setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 1)
            format.setInteger(MediaFormat.KEY_PRIORITY, 0)
            format.setInteger(
                MediaFormat.KEY_BITRATE_MODE,
                bitrateMode,
            )
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                format.setInteger(MediaFormat.KEY_LOW_LATENCY, 1)
            }
            created.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
            created.start()
            readEncoderInputLayout(created)
        } catch (error: Exception) {
            // Codec vừa tạo chưa được gán vào `codec`: phải tự giải phóng.
            try { created.release() } catch (_: Exception) {}
            throw error
        }
        codec = created
        encoderErrorReported.set(false)
        if (encoderReady.compareAndSet(false, true) && running.get()) {
            onEncoderConfigured(publisherId)
        }
    }

    private fun drainEncoder() {
        val encoder = codec ?: return
        val info = MediaCodec.BufferInfo()
        while (true) {
            val index = encoder.dequeueOutputBuffer(info, 0)
            if (index == MediaCodec.INFO_TRY_AGAIN_LATER) return
            if (index == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                sps = stripStartCode(readBuffer(encoder.outputFormat.getByteBuffer("csd-0")))
                pps = stripStartCode(readBuffer(encoder.outputFormat.getByteBuffer("csd-1")))
                continue
            }
            if (index < 0) continue
            val output = encoder.getOutputBuffer(index)
            if (output != null && info.size > 0) {
                output.position(info.offset)
                output.limit(info.offset + info.size)
                val bytes = ByteArray(info.size)
                output.get(bytes)
                val frameNals = mutableListOf<ByteArray>()
                for (nal in splitNals(bytes)) {
                    when (nal.firstOrNull()?.toInt()?.and(0x1f)) {
                        7 -> {
                            sps = nal
                            frameNals += nal
                        }
                        8 -> {
                            pps = nal
                            frameNals += nal
                        }
                        else -> frameNals += nal
                    }
                }
                if (frameNals.isNotEmpty()) {
                    val isKeyFrame =
                        info.flags and MediaCodec.BUFFER_FLAG_KEY_FRAME != 0 ||
                            frameNals.any { nal ->
                                nal.firstOrNull()?.toInt()?.and(0x1f) == 5
                            }
                    if (isKeyFrame) {
                        val hasSps = frameNals.any { it.firstOrNull()?.toInt()?.and(0x1f) == 7 }
                        val hasPps = frameNals.any { it.firstOrNull()?.toInt()?.and(0x1f) == 8 }
                        if (!hasSps && sps != null) {
                            frameNals.add(0, sps!!)
                        }
                        if (!hasPps && pps != null) {
                            val insertIdx = if (frameNals.isNotEmpty() && frameNals[0].firstOrNull()?.toInt()?.and(0x1f) == 7) 1 else 0
                            frameNals.add(insertIdx, pps!!)
                        }
                    }
                    sendAccessUnit(
                        frameNals,
                        info.presentationTimeUs,
                        isKeyFrame,
                    )
                }
            }
            encoder.releaseOutputBuffer(index, false)
        }
    }

    private fun readBuffer(buffer: ByteBuffer?): ByteArray? {
        if (buffer == null) return null
        val copy = buffer.duplicate()
        val data = ByteArray(copy.remaining())
        copy.get(data)
        return data
    }

    private fun stripStartCode(data: ByteArray?): ByteArray? {
        if (data == null) return null
        val offset = if (data.size >= 4 && data[0] == 0.toByte() && data[1] == 0.toByte() && data[2] == 0.toByte() && data[3] == 1.toByte()) 4
        else if (data.size >= 3 && data[0] == 0.toByte() && data[1] == 0.toByte() && data[2] == 1.toByte()) 3 else 0
        return data.copyOfRange(offset, data.size)
    }

    private fun splitNals(data: ByteArray): List<ByteArray> {
        val result = mutableListOf<ByteArray>()
        var start = findStartCode(data, 0)
        if (start < 0) {
            // MediaCodec can return AVCC length-prefixed NAL units.
            var offset = 0
            while (offset + 4 <= data.size) {
                val size = ((data[offset].toInt() and 255) shl 24) or ((data[offset + 1].toInt() and 255) shl 16) or
                    ((data[offset + 2].toInt() and 255) shl 8) or (data[offset + 3].toInt() and 255)
                offset += 4
                if (size <= 0 || offset + size > data.size) break
                result += data.copyOfRange(offset, offset + size)
                offset += size
            }
            if (result.isEmpty() && data.isNotEmpty()) result += data
            return result
        }
        while (start >= 0) {
            val prefix = if (start + 3 < data.size && data[start + 2] == 1.toByte()) 3 else 4
            val nalStart = start + prefix
            val next = findStartCode(data, nalStart)
            result += data.copyOfRange(nalStart, if (next < 0) data.size else next)
            start = next
        }
        return result.filter { it.isNotEmpty() }
    }

    private fun findStartCode(data: ByteArray, from: Int): Int {
        for (i in from until data.size - 2) {
            if (data[i] == 0.toByte() && data[i + 1] == 0.toByte() &&
                (data[i + 2] == 1.toByte() || (i + 3 < data.size && data[i + 2] == 0.toByte() && data[i + 3] == 1.toByte()))) return i
        }
        return -1
    }

    private fun sendAccessUnit(
        nals: List<ByteArray>,
        presentationTimeUs: Long,
        isKeyFrame: Boolean,
    ) {
        var timestamp = presentationTimeUs * 90 / 1000
        if (lastOutputRtpTimestamp != -1L && timestamp <= lastOutputRtpTimestamp) {
            timestamp = lastOutputRtpTimestamp + (90000L / fps).coerceAtLeast(1L)
        }
        lastOutputRtpTimestamp = timestamp
        var shouldRequestKeyFrame = false
        sessions.values.filter { it.playing }.forEach {
            if (it.enqueueAccessUnit(nals, timestamp, isKeyFrame)) {
                shouldRequestKeyFrame = true
            }
        }
        if (shouldRequestKeyFrame) requestSyncFrame()
    }

    private fun handleClient(session: Session) {
        val socket = session.socket
        try {
            val reader = RtspRequestReader(socket.getInputStream(), session)
            while (running.get() && !socket.isClosed) {
                val request = try {
                    reader.next()
                } catch (timeout: SocketTimeoutException) {
                    // Sau PLAY, client hợp lệ có thể im lặng (không gửi RTCP /
                    // keepalive): chỉ là "không có dữ liệu". Client chết được
                    // phát hiện ở phía ghi (CLIENT_WRITE_STALL_NANOS). Reader
                    // giữ trạng thái gói đang dở nên đọc tiếp không mất đồng bộ.
                    if (session.playing) continue
                    throw timeout
                } ?: break
                val cseq = request.headers["cseq"] ?: "0"
                when (request.method) {
                    "OPTIONS" -> session.respond(
                        cseq,
                        "Public: OPTIONS, DESCRIBE, SETUP, PLAY, PAUSE, TEARDOWN\r\n",
                    )
                    "DESCRIBE" -> session.describe(cseq)
                    "SETUP" -> session.setup(cseq, request.uri, request.headers["transport"] ?: "")
                    "PLAY" -> {
                        // The RTSP response must be fully written before RTP is
                        // allowed onto the same interleaved TCP connection.
                        session.respond(
                            cseq,
                            "Session: ${session.id}\r\nRTP-Info: url=track0${if (audioAvailable && session.audioConfigured) ",url=track1" else ""}\r\n",
                        )
                        session.beginPlaying()
                        // Đang phát: luồng đọc chỉ nhận RTCP/keepalive thưa.
                        socket.soTimeout = PLAYING_READ_TIMEOUT_MS
                        requestSyncFrame(force = true)
                    }
                    "PAUSE" -> {
                        session.pause()
                        session.respond(cseq, "Session: ${session.id}\r\n")
                    }
                    "TEARDOWN" -> {
                        session.pause()
                        session.respond(cseq, "Session: ${session.id}\r\n")
                        break
                    }
                    else -> session.writeRtsp(
                        "RTSP/1.0 405 Method Not Allowed\r\nCSeq: $cseq\r\n\r\n",
                    )
                }
            }
        } catch (error: Exception) {
            Log.d(TAG, "RTSP client closed: ${error.message}")
        } catch (error: Throwable) {
            // Error (StackOverflowError, OOM...) không được lọt khỏi luồng client:
            // trên Android nó giết cả tiến trình.
            Log.w(TAG, "RTSP client ${session.id} failed", error)
        } finally {
            sessions.remove(session.id)
            try { session.close() } catch (_: Throwable) {}
        }
    }

    private data class RtspRequest(
        val method: String,
        val uri: String,
        val headers: Map<String, String>,
    )

    /**
     * Reads RTSP text while consuming interleaved RTP/RTCP binary frames.
     * Vòng lặp (không đệ quy): dòng trống giữa các request được bỏ qua tới một
     * giới hạn, quá giới hạn thì coi client hỏng và ném lỗi để đóng kết nối.
     *
     * Trạng thái phân tích (request đang dở, gói `$` đang dở) nằm trong đối
     * tượng, không nằm trên stack: khi đang PLAY, SocketTimeoutException chỉ
     * nghĩa là "chưa có dữ liệu" và lần gọi [next] sau đọc tiếp đúng phần còn
     * thiếu thay vì bắt đầu lại giữa một gói (mất đồng bộ luồng TCP). Socket
     * read() của Java hoặc trả byte, hoặc ném timeout mà không tiêu byte nào.
     */
    private inner class RtspRequestReader(
        private val input: InputStream,
        private val session: Session,
    ) {
        private val request = ArrayList<Byte>(1024)
        private var matchedHeaderEnd = 0
        private var emptyBlocks = 0
        private var emptyLines = 0
        /** 0: không ở trong gói `$`; 1..3: số byte header đã đọc sau `$`; 4: đang đọc payload. */
        private var interleavedStage = 0
        private var interleavedChannel = 0
        private var interleavedLengthHigh = 0
        private var interleavedPayload = EMPTY_PAYLOAD
        private var interleavedOffset = 0

        fun next(): RtspRequest? {
            while (running.get()) {
                if (interleavedStage > 0) {
                    if (!readInterleaved()) return null
                    continue
                }
                val first = input.read()
                if (first < 0) return null
                if (first == '$'.code && request.isEmpty()) {
                    interleavedStage = 1
                    continue
                }
                if (request.isEmpty() && (first == '\r'.code || first == '\n'.code)) {
                    // CRLF thừa trước request (keepalive kiểu cũ): bỏ qua.
                    if (first == '\n'.code) {
                        emptyLines++
                        if (emptyLines > MAX_EMPTY_RTSP_BLOCKS * 2) {
                            throw IllegalArgumentException("RTSP client gửi quá nhiều dòng trống")
                        }
                    }
                    continue
                }

                request += first.toByte()
                matchedHeaderEnd = when {
                    matchedHeaderEnd == 0 && first == '\r'.code -> 1
                    matchedHeaderEnd == 1 && first == '\n'.code -> 2
                    matchedHeaderEnd == 2 && first == '\r'.code -> 3
                    matchedHeaderEnd == 3 && first == '\n'.code -> 4
                    first == '\r'.code -> 1
                    else -> 0
                }
                if (matchedHeaderEnd != 4) {
                    if (request.size > MAX_RTSP_HEADER_BYTES) {
                        throw IllegalArgumentException("RTSP header quá lớn")
                    }
                    continue
                }

                val text = request.toByteArray().toString(Charsets.ISO_8859_1)
                request.clear()
                matchedHeaderEnd = 0
                val lines = text.split("\r\n")
                val requestLine = lines.firstOrNull()?.trim().orEmpty()
                if (requestLine.isEmpty()) {
                    emptyBlocks++
                    if (emptyBlocks > MAX_EMPTY_RTSP_BLOCKS) {
                        throw IllegalArgumentException("RTSP client gửi quá nhiều khối rỗng")
                    }
                    continue
                }
                emptyBlocks = 0
                emptyLines = 0
                val headers = mutableMapOf<String, String>()
                for (line in lines.drop(1)) {
                    val separator = line.indexOf(':')
                    if (separator > 0) {
                        headers[line.substring(0, separator).trim().lowercase()] =
                            line.substring(separator + 1).trim()
                    }
                }
                return RtspRequest(
                    requestLine.substringBefore(' ').uppercase(),
                    requestLine.split(' ').getOrElse(1) { "" },
                    headers,
                )
            }
            return null
        }

        /** Đọc tiếp gói interleaved đang dở. false: hết luồng (EOF). */
        private fun readInterleaved(): Boolean {
            while (interleavedStage in 1..3) {
                val value = input.read()
                if (value < 0) return false
                when (interleavedStage) {
                    1 -> interleavedChannel = value
                    2 -> interleavedLengthHigh = value
                    else -> {
                        val length = (interleavedLengthHigh shl 8) or value
                        interleavedPayload = if (length == 0) EMPTY_PAYLOAD else ByteArray(length)
                        interleavedOffset = 0
                    }
                }
                interleavedStage++
            }
            val payload = interleavedPayload
            while (interleavedOffset < payload.size) {
                val count = input.read(payload, interleavedOffset, payload.size - interleavedOffset)
                if (count < 0) return false
                interleavedOffset += count
            }
            // Về ranh giới gói TRƯỚC khi xử lý: lỗi trong handler không để lại
            // trạng thái dở.
            interleavedStage = 0
            interleavedPayload = EMPTY_PAYLOAD
            interleavedOffset = 0
            session.handleInterleaved(interleavedChannel, payload)
            return true
        }
    }

    /**
     * Yêu cầu IDR, tối đa một lần mỗi [SYNC_FRAME_MIN_INTERVAL_NANOS] cho toàn
     * encoder (tránh bão IDR khi nhiều client nghẽn/PLI liên tục). [force]: client
     * mới PLAY cần IDR ngay.
     */
    private fun requestSyncFrame(force: Boolean = false) {
        val now = System.nanoTime()
        while (true) {
            val last = lastSyncFrameRequestNanos.get()
            if (!force && last != 0L && now - last < SYNC_FRAME_MIN_INTERVAL_NANOS) return
            if (lastSyncFrameRequestNanos.compareAndSet(last, now)) break
        }
        synchronized(codecLock) {
            try {
                codec?.setParameters(Bundle().apply {
                    putInt(MediaCodec.PARAMETER_KEY_REQUEST_SYNC_FRAME, 0)
                })
            } catch (error: Exception) {
                Log.w(TAG, "Unable to request H264 sync frame", error)
            }
        }
    }

    private fun handleReceiverReport(fractionLost: Int) {
        val target = synchronized(feedbackLock) {
            val loss = fractionLost.coerceIn(0, 255) / 256.0
            val maximum = maximumAdaptiveBitrate
            // Mức sàn không bao giờ vượt mức trần do bộ thích ứng livestream đặt.
            val minimum = minOf(maximum, maxOf(MIN_RTSP_BITRATE, bitrate / 4))
            val proposed = when {
                loss >= 0.10 -> {
                    healthyReceiverReports = 0
                    (currentBitrate * 0.75).toInt()
                }
                loss <= 0.02 -> {
                    healthyReceiverReports++
                    if (healthyReceiverReports < 3) currentBitrate
                    else {
                        healthyReceiverReports = 0
                        (currentBitrate * 1.10).toInt()
                    }
                }
                else -> {
                    healthyReceiverReports = 0
                    currentBitrate
                }
            }
            minOf(maximum, maxOf(minimum, proposed)).also { currentBitrate = it }
        }
        synchronized(codecLock) {
            try {
                codec?.setParameters(Bundle().apply {
                    putInt(MediaCodec.PARAMETER_KEY_VIDEO_BITRATE, target)
                })
            } catch (error: Exception) {
                Log.w(TAG, "Unable to apply RTCP bitrate $target", error)
            }
        }
    }

    fun stop() {
        if (!running.compareAndSet(true, false)) return
        activePublishersByPort.remove(port, this)
        try { track.removeSink(this) } catch (_: Exception) {}
        try { serverSocket?.close() } catch (_: Exception) {}
        sessions.values.forEach { session ->
            try { session.close() } catch (_: Exception) {}
        }
        sessions.clear()
        handshakeWatchdog.shutdownNow()
        // shutdownNow() bỏ task chưa chạy mà không release khung: tự dọn.
        encoderExecutor.shutdownNow()
        pendingFrame.getAndSet(null)?.release()
        synchronized(codecLock) {
            val previous = codec
            codec = null
            encoderReady.set(false)
            if (previous != null) {
                try { previous.stop() } catch (_: Exception) {}
                try { previous.release() } catch (_: Exception) {}
            }
            // Nhả các buffer trung gian (direct ByteBuffer) của phiên.
            rotateScratch = null
            fitScratch = null
            blackCanvas = null
            packedFrame = null
        }
    }

    private inner class Session(val socket: Socket) {
        val id = UUID.randomUUID().toString().replace("-", "").take(12)
        @Volatile var playing = false
        /** Đã từng PLAY (watchdog bắt tay chỉ đóng phiên chưa bao giờ PLAY). */
        @Volatile var hasPlayed = false
        @Volatile var audioConfigured = false
        private var rtpChannel = 0
        private var audioRtpChannel = 2
        private var sequence = 0
        private var audioSequence = 0
        private var audioRtpTimestamp: Long = -1L
        private val output: OutputStream = socket.getOutputStream()
        private val outputLock = Any()
        private val sendStateLock = Any()
        private val senderExecutor = Executors.newSingleThreadExecutor { task ->
            Thread(task, "VNVAR-RTSP-Send-$id").apply { isDaemon = true }
        }
        private var sendGeneration = 0L
        private var pendingRtpPackets = 0
        /** Tổng byte NAL đang chờ gửi (thế hệ hiện tại). */
        private var pendingVideoBytes = 0L
        /** Thời điểm (nanoTime) xếp hàng của từng access unit chờ gửi, cũ nhất trước. */
        private val pendingUnitEnqueuedNanos = ArrayDeque<Long>()
        private var pendingAudioChunks = 0
        // Relay FFmpeg (livestream RTMP/RTSP) đọc qua loopback: khi đường upload
        // nghẽn chốc lát nó ngừng đọc, nên cần hàng chờ dài như video thay vì bỏ
        // tiếng sau 0,5 giây như client Wi-Fi.
        val isLoopbackClient = isLoopbackRemote(socket.inetAddress)
        private val offersAudio: Boolean
            get() = audioAvailable && (isLoopbackClient || remoteAudioEnabled)
        private var videoPacketCount = 0L
        private var videoOctetCount = 0L
        private var audioPacketCount = 0L
        private var audioOctetCount = 0L
        private var lastSenderReportNanos = 0L
        private var awaitingKeyFrame = true
        private var keyFrameQueued = false
        private var closed = false
        @Volatile private var writeStartedNanos = 0L

        fun setup(cseq: String, uri: String, transport: String) {
            if (transport.contains("TCP", true) || transport.contains("interleaved", true)) {
                val requested = Regex("interleaved=(\\d+)").find(transport)?.groupValues?.get(1)?.toIntOrNull()
                val isAudio = uri.contains("track1", true)
                if (isAudio && !offersAudio) {
                    writeRtsp("RTSP/1.0 404 Not Found\r\nCSeq: $cseq\r\n\r\n")
                    return
                }
                val channel = requested ?: if (isAudio) 2 else 0
                if (isAudio) { audioRtpChannel = channel; audioConfigured = true } else rtpChannel = channel
                respond(cseq, "Session: $id\r\nTransport: RTP/AVP/TCP;unicast;interleaved=$channel-${channel + 1}\r\n")
            } else {
                writeRtsp("RTSP/1.0 461 Unsupported Transport\r\nCSeq: $cseq\r\n\r\n")
            }
        }

        fun handleInterleaved(channel: Int, payload: ByteArray) {
            if (channel != rtpChannel + 1 || payload.size < 4) return
            var offset = 0
            var worstFractionLost: Int? = null
            var pictureLoss = false
            while (offset + 4 <= payload.size) {
                val first = payload[offset].toInt() and 0xff
                if (first ushr 6 != 2) return
                val countOrFormat = first and 0x1f
                val packetType = payload[offset + 1].toInt() and 0xff
                val words = ((payload[offset + 2].toInt() and 0xff) shl 8) or
                    (payload[offset + 3].toInt() and 0xff)
                val packetLength = (words + 1) * 4
                if (packetLength < 4 || offset + packetLength > payload.size) return
                if (packetType == 201 && countOrFormat > 0 && packetLength >= 32) {
                    for (index in 0 until countOrFormat) {
                        val block = offset + 8 + index * 24
                        if (block + 24 > offset + packetLength) break
                        val lost = payload[block + 4].toInt() and 0xff
                        worstFractionLost = maxOf(worstFractionLost ?: 0, lost)
                    }
                } else if (packetType == 206 && countOrFormat == 1 && packetLength >= 12) {
                    pictureLoss = true
                }
                offset += packetLength
            }
            if (offset != payload.size) return
            if (pictureLoss) requestSyncFrame()
            worstFractionLost?.let(::handleReceiverReport)
        }

        fun describe(cseq: String) {
            val deadline = System.currentTimeMillis() + 2500L
            while ((sps == null || pps == null) && System.currentTimeMillis() < deadline && running.get()) {
                try {
                    Thread.sleep(50)
                } catch (_: InterruptedException) {
                    break
                }
            }
            val localSps = sps
            val localPps = pps
            if (localSps == null || localPps == null) {
                writeRtsp(
                    "RTSP/1.0 503 Service Unavailable\r\n" +
                        "CSeq: $cseq\r\nRetry-After: 1\r\n\r\n",
                )
                return
            }
            val profileLevelId = if (localSps.size >= 4) {
                String.format(
                    Locale.US,
                    "%02X%02X%02X",
                    localSps[1].toInt() and 0xff,
                    localSps[2].toInt() and 0xff,
                    localSps[3].toInt() and 0xff,
                )
            } else {
                "42E01F"
            }
            val sdp = "v=0\r\n" +
                "o=- 0 0 IN IP4 0.0.0.0\r\n" +
                "s=VNVAR Camera\r\n" +
                "t=0 0\r\n" +
                "a=control:*\r\n" +
                "m=video 0 RTP/AVP 96\r\n" +
                "a=rtpmap:96 H264/90000\r\n" +
                "a=fmtp:96 packetization-mode=1;profile-level-id=$profileLevelId;" +
                "sprop-parameter-sets=${Base64.encodeToString(localSps, Base64.NO_WRAP)}," +
                "${Base64.encodeToString(localPps, Base64.NO_WRAP)}\r\n" +
                "a=control:track0\r\n" +
                if (offersAudio) "m=audio 0 RTP/AVP 97\r\na=rtpmap:97 L16/48000/1\r\na=control:track1\r\n" else ""
            val response = "RTSP/1.0 200 OK\r\n" +
                "CSeq: $cseq\r\n" +
                "Content-Type: application/sdp\r\n" +
                "Content-Length: ${sdp.toByteArray(Charsets.UTF_8).size}\r\n\r\n" +
                sdp
            writeRtsp(response)
        }

        fun respond(cseq: String, extra: String) {
            writeRtsp("RTSP/1.0 200 OK\r\nCSeq: $cseq\r\n$extra\r\n")
        }

        fun writeRtsp(value: String) {
            synchronized(outputLock) {
                output.write(value.toByteArray(Charsets.ISO_8859_1))
                output.flush()
            }
        }

        fun beginPlaying() {
            // MediaCodec may still have P-frames queued when PLAY arrives. Do
            // not send them to a decoder that has no reference picture yet.
            synchronized(sendStateLock) {
                sendGeneration++
                awaitingKeyFrame = true
                keyFrameQueued = false
                pendingRtpPackets = 0
                pendingVideoBytes = 0L
                pendingUnitEnqueuedNanos.clear()
                playing = true
                hasPlayed = true
                audioRtpTimestamp = -1L
                audioSequence = 0
            }
        }

        fun pause() {
            synchronized(sendStateLock) {
                playing = false
                sendGeneration++
                pendingRtpPackets = 0
                pendingVideoBytes = 0L
                pendingUnitEnqueuedNanos.clear()
                awaitingKeyFrame = true
                keyFrameQueued = false
                audioRtpTimestamp = -1L
            }
        }

        /** Bỏ toàn bộ video đang chờ (gói của thế hệ cũ bị luồng gửi bỏ qua). */
        private fun dropPendingVideoLocked() {
            sendGeneration++
            pendingRtpPackets = 0
            pendingVideoBytes = 0L
            pendingUnitEnqueuedNanos.clear()
            keyFrameQueued = false
        }

        /**
         * Hàng chờ đã quá dài chưa: giới hạn theo THỜI GIAN (gói cũ nhất chờ quá
         * hạn) và theo byte để độ trễ không tích luỹ, cộng trần an toàn theo số gói.
         * - Client mạng (Tablet): 0,5 giây, byte theo bitrate hiện tại — giữ độ
         *   trễ thấp.
         * - Relay FFmpeg loopback: 2 giây, byte theo bitrate TỐI ĐA cấu hình —
         *   FFmpeg khựng thoáng qua (upload RTMP) không làm mất hình livestream.
         */
        private fun queueWouldOverflowLocked(packetCount: Int, bytes: Long, now: Long): Boolean {
            if (pendingRtpPackets <= 0) return false
            val packetLimit = if (isLoopbackClient) {
                MAX_PENDING_RTP_PACKETS_LOOPBACK
            } else {
                MAX_PENDING_RTP_PACKETS
            }
            if (pendingRtpPackets + packetCount > packetLimit) return true
            val ageLimit = if (isLoopbackClient) {
                MAX_LOOPBACK_QUEUE_AGE_NANOS
            } else {
                MAX_CLIENT_QUEUE_AGE_NANOS
            }
            val oldest = pendingUnitEnqueuedNanos.peekFirst()
            if (oldest != null && now - oldest > ageLimit) return true
            val byteBudget = if (isLoopbackClient) {
                // Dùng bitrate tối đa (không phải bitrate thích ứng hiện tại) để
                // đủ chỗ cho ~2 giây kể cả khi bộ thích ứng vừa nâng bitrate.
                maxOf(
                    MIN_LOOPBACK_QUEUE_BYTES,
                    bitrate.coerceAtLeast(MIN_RTSP_BITRATE).toLong() * ageLimit / 8L / 1_000_000_000L,
                )
            } else {
                maxOf(
                    MIN_CLIENT_QUEUE_BYTES,
                    currentBitrate.toLong() * ageLimit / 8L / 1_000_000_000L,
                )
            }
            return pendingVideoBytes + bytes > byteBudget
        }

        /**
         * Queues one complete H.264 access unit without ever blocking the
         * encoder. Returns true when congestion broke the reference chain and
         * MediaCodec should produce a fresh IDR frame.
         */
        fun enqueueAccessUnit(
            nals: List<ByteArray>,
            timestamp: Long,
            isKeyFrame: Boolean,
        ): Boolean {
            val packetCount = nals.sumOf(::rtpPacketCount)
            if (packetCount == 0) return false
            val writeStarted = writeStartedNanos
            // Relay livestream cục bộ chỉ ngừng đọc khi upload RTMP khựng; đóng
            // nó sau 2 giây sẽ buộc livestream khởi động lại.
            val stallLimit = if (isLoopbackClient) {
                LOOPBACK_WRITE_STALL_NANOS
            } else {
                CLIENT_WRITE_STALL_NANOS
            }
            if (writeStarted != 0L &&
                System.nanoTime() - writeStarted > stallLimit
            ) {
                Log.w(TAG, "Closing stalled RTSP client $id")
                close()
                return false
            }

            val generation: Long
            val bytes = nals.sumOf { it.size.toLong() }
            synchronized(sendStateLock) {
                if (closed || !playing) return false
                if (awaitingKeyFrame && !isKeyFrame) return false

                val now = System.nanoTime()
                // Keyframe mới tới khi keyframe trước còn chờ: hàng chờ đã chậm
                // hơn một GOP, nhảy thẳng tới keyframe mới nhất. Chỉ áp dụng cho
                // client mạng: GOP = 1 giây nên với relay loopback luật này sẽ cắt
                // ở ~1 giây, vô hiệu hoá hạn 2 giây ở queueWouldOverflowLocked.
                val overflow = (isKeyFrame && keyFrameQueued && !isLoopbackClient) ||
                    queueWouldOverflowLocked(packetCount, bytes, now)
                if (overflow) {
                    dropPendingVideoLocked()
                    if (!isKeyFrame) {
                        // Bỏ P-frame làm đứt chuỗi tham chiếu: bỏ luôn mọi
                        // P-frame sau đó cho tới keyframe kế tiếp (tránh vỡ hình)
                        // và xin IDR (bị giới hạn 1 lần/giây toàn encoder).
                        awaitingKeyFrame = true
                        Log.w(
                            TAG,
                            "RTSP client $id congested (loopback=$isLoopbackClient); " +
                                "dropping to next keyframe",
                        )
                        return true
                    }
                    Log.w(
                        TAG,
                        "RTSP client $id congested (loopback=$isLoopbackClient); " +
                            "fast-forwarding to keyframe",
                    )
                }

                generation = sendGeneration
                pendingRtpPackets += packetCount
                pendingVideoBytes += bytes
                pendingUnitEnqueuedNanos.addLast(now)
                if (isKeyFrame) {
                    // Từ keyframe này trở đi chuỗi tham chiếu liền mạch: nhận
                    // P-frame ngay (không đợi keyframe gửi xong mới nhận).
                    keyFrameQueued = true
                    awaitingKeyFrame = false
                }
            }

            try {
                senderExecutor.execute {
                    try {
                        val valid = synchronized(sendStateLock) {
                            !closed && playing && generation == sendGeneration
                        }
                        if (valid) {
                            writeStartedNanos = System.nanoTime()
                            nals.forEachIndexed { index, nal ->
                                sendNal(nal, timestamp, index == nals.lastIndex)
                            }
                            sendSenderReportsIfDue()
                        }
                    } catch (error: Throwable) {
                        Log.w(TAG, "RTSP video sender failed for client $id", error)
                        close()
                    } finally {
                        writeStartedNanos = 0L
                        synchronized(sendStateLock) {
                            if (generation == sendGeneration) {
                                pendingRtpPackets =
                                    (pendingRtpPackets - packetCount).coerceAtLeast(0)
                                pendingVideoBytes =
                                    (pendingVideoBytes - bytes).coerceAtLeast(0L)
                                pendingUnitEnqueuedNanos.pollFirst()
                                if (isKeyFrame) keyFrameQueued = false
                            }
                        }
                    }
                }
            } catch (_: Exception) {
                synchronized(sendStateLock) {
                    if (generation == sendGeneration) {
                        pendingRtpPackets =
                            (pendingRtpPackets - packetCount).coerceAtLeast(0)
                        pendingVideoBytes = (pendingVideoBytes - bytes).coerceAtLeast(0L)
                        pendingUnitEnqueuedNanos.pollLast()
                        if (isKeyFrame) keyFrameQueued = false
                    }
                }
                close()
            }
            return false
        }

        private fun rtpPacketCount(nal: ByteArray): Int {
            if (nal.isEmpty()) return 0
            if (nal.size <= RTP_PAYLOAD_BYTES) return 1
            val bodySize = nal.size - 1
            val fragmentSize = RTP_PAYLOAD_BYTES - 2
            return (bodySize + fragmentSize - 1) / fragmentSize
        }

        private fun sendNal(nal: ByteArray, timestamp: Long, marker: Boolean) {
            if (nal.size <= RTP_PAYLOAD_BYTES) sendPacket(nal, timestamp, marker)
            else {
                val header = nal[0].toInt() and 255
                val fuIndicator = (header and 0xe0) or 28
                val nalType = header and 0x1f
                var offset = 1
                var first = true
                while (offset < nal.size) {
                    val size = minOf(RTP_PAYLOAD_BYTES - 2, nal.size - offset)
                    val last = offset + size >= nal.size
                    val payload = ByteArray(size + 2)
                    payload[0] = fuIndicator.toByte()
                    payload[1] = (nalType or (if (first) 0x80 else 0) or (if (last) 0x40 else 0)).toByte()
                    System.arraycopy(nal, offset, payload, 2, size)
                    sendPacket(payload, timestamp, marker && last)
                    first = false
                    offset += size
                }
            }
        }

        private fun sendPacket(payload: ByteArray, timestamp: Long, marker: Boolean) {
            val packet = ByteArray(12 + payload.size)
            packet[0] = 0x80.toByte(); packet[1] = ((if (marker) 0x80 else 0) or 96).toByte()
            packet[2] = (sequence shr 8).toByte(); packet[3] = sequence.toByte(); sequence = (sequence + 1) and 0xffff
            val ts = timestamp.toInt(); packet[4] = (ts shr 24).toByte(); packet[5] = (ts shr 16).toByte(); packet[6] = (ts shr 8).toByte(); packet[7] = ts.toByte()
            packet[8] = 0x56; packet[9] = 0x4e; packet[10] = 0x56; packet[11] = 0x52
            System.arraycopy(payload, 0, packet, 12, payload.size)
            val interleaved = ByteArray(packet.size + 4)
            interleaved[0] = '$'.code.toByte()
            interleaved[1] = rtpChannel.toByte()
            interleaved[2] = (packet.size shr 8).toByte()
            interleaved[3] = packet.size.toByte()
            System.arraycopy(packet, 0, interleaved, 4, packet.size)
            try {
                synchronized(outputLock) {
                    output.write(interleaved)
                }
                videoPacketCount++
                videoOctetCount += payload.size
            } catch (_: Exception) { close() }
        }

        /**
         * RTCP Sender Report cho video và audio, cùng một đồng hồ NTP. Nhờ đó
         * FFmpeg (relay livestream) và trình phát Tablet ghép hình–tiếng đúng
         * thời điểm thay vì coi gói đầu tiên của mỗi luồng là mốc 0.
         */
        private fun sendSenderReportsIfDue() {
            val nowNanos = android.os.SystemClock.elapsedRealtimeNanos()
            if (lastSenderReportNanos != 0L &&
                nowNanos - lastSenderReportNanos < SENDER_REPORT_INTERVAL_NANOS
            ) return
            val start = streamStartNanos
            if (start < 0L) return
            lastSenderReportNanos = nowNanos
            val wallMs = System.currentTimeMillis()
            val elapsedUs = (nowNanos - start) / 1000L
            val videoRtp = (elapsedUs * 90 / 1000) and 0xffffffffL
            writeSenderReport(rtpChannel + 1, VIDEO_SSRC, wallMs, videoRtp, videoPacketCount, videoOctetCount)
            val audioRtp = synchronized(sendStateLock) {
                if (audioConfigured) audioRtpTimestamp else -1L
            }
            if (audioRtp >= 0L) {
                writeSenderReport(audioRtpChannel + 1, AUDIO_SSRC, wallMs, audioRtp, audioPacketCount, audioOctetCount)
            }
        }

        private fun writeSenderReport(
            channel: Int,
            ssrc: Int,
            wallMs: Long,
            rtpTimestamp: Long,
            packets: Long,
            octets: Long,
        ) {
            val ntpSeconds = wallMs / 1000L + NTP_UNIX_OFFSET_SECONDS
            val ntpFraction = ((wallMs % 1000L) shl 32) / 1000L
            val report = java.nio.ByteBuffer.allocate(4 + 28)
            report.put('$'.code.toByte())
            report.put(channel.toByte())
            report.putShort(28)
            report.put(0x80.toByte())
            report.put(200.toByte())
            report.putShort(6)
            report.putInt(ssrc)
            report.putInt(ntpSeconds.toInt())
            report.putInt(ntpFraction.toInt())
            report.putInt(rtpTimestamp.toInt())
            report.putInt(packets.toInt())
            report.putInt(octets.toInt())
            try {
                synchronized(outputLock) { output.write(report.array()) }
            } catch (_: Exception) { close() }
        }

        /**
         * Xếp một gói PCM vào luồng gửi của client này. Timestamp RTP được cấp
         * ngay tại đây và luôn tăng theo số mẫu, kể cả khi gói bị bỏ do nghẽn,
         * để âm thanh không lệch khỏi hình sau khi mạng hồi phục.
         */
        fun enqueueAudio(pcm: ByteArray) {
            val generation: Long
            val timestamp: Long
            synchronized(sendStateLock) {
                if (closed || !playing || !audioConfigured) return
                if (audioRtpTimestamp < 0L) {
                    val nowNanos = android.os.SystemClock.elapsedRealtimeNanos()
                    val baseNanos = if (streamStartNanos > 0L) streamStartNanos else nowNanos
                    val elapsedNanos = (nowNanos - baseNanos).coerceAtLeast(0L)
                    audioRtpTimestamp = (elapsedNanos * 48_000L / 1_000_000_000L) and 0xffffffffL
                }
                timestamp = audioRtpTimestamp
                audioRtpTimestamp = (audioRtpTimestamp + pcm.size / 2) and 0xffffffffL
                // Tối đa ~0,5 giây âm thanh chờ gửi; nghẽn lâu hơn thì bỏ gói
                // mới thay vì tích độ trễ hoặc chặn các client khác.
                val audioLimit = if (isLoopbackClient) {
                    MAX_PENDING_AUDIO_CHUNKS_LOOPBACK
                } else {
                    MAX_PENDING_AUDIO_CHUNKS
                }
                if (pendingAudioChunks >= audioLimit) return
                pendingAudioChunks++
                generation = sendGeneration
            }
            try {
                senderExecutor.execute {
                    try {
                        val valid = synchronized(sendStateLock) {
                            !closed && playing && generation == sendGeneration
                        }
                        if (valid) sendAudio(pcm, timestamp)
                    } catch (error: Throwable) {
                        Log.w(TAG, "RTSP audio sender failed for client $id", error)
                        close()
                    } finally {
                        synchronized(sendStateLock) {
                            pendingAudioChunks = (pendingAudioChunks - 1).coerceAtLeast(0)
                        }
                    }
                }
            } catch (_: Exception) {
                synchronized(sendStateLock) {
                    pendingAudioChunks = (pendingAudioChunks - 1).coerceAtLeast(0)
                }
            }
        }

        private fun sendAudio(pcm: ByteArray, startTimestamp: Long) {
            var packetTimestamp = startTimestamp
            val networkPcm = ByteArray(pcm.size)
            var index = 0
            while (index + 1 < pcm.size) {
                networkPcm[index] = pcm[index + 1]
                networkPcm[index + 1] = pcm[index]
                index += 2
            }
            var offset = 0
            while (offset < networkPcm.size) {
                val size = minOf(1_200, networkPcm.size - offset) and -2
                if (size <= 0) break
                val packet = ByteArray(12 + size)
                packet[0] = 0x80.toByte(); packet[1] = 97
                packet[2] = (audioSequence shr 8).toByte(); packet[3] = audioSequence.toByte(); audioSequence = (audioSequence + 1) and 0xffff
                val ts = packetTimestamp.toInt()
                packet[4] = (ts shr 24).toByte(); packet[5] = (ts shr 16).toByte(); packet[6] = (ts shr 8).toByte(); packet[7] = ts.toByte()
                packet[8] = 0x56; packet[9] = 0x4e; packet[10] = 0x41; packet[11] = 0x55
                System.arraycopy(networkPcm, offset, packet, 12, size)
                val framed = ByteArray(packet.size + 4)
                framed[0] = '$'.code.toByte(); framed[1] = audioRtpChannel.toByte(); framed[2] = (packet.size shr 8).toByte(); framed[3] = packet.size.toByte()
                System.arraycopy(packet, 0, framed, 4, packet.size)
                try { synchronized(outputLock) { output.write(framed) } } catch (_: Exception) { close(); return }
                audioPacketCount++
                audioOctetCount += size
                val samples = size / 2
                packetTimestamp = (packetTimestamp + samples) and 0xffffffffL
                offset += size
            }
        }

        fun close() {
            synchronized(sendStateLock) {
                if (closed) return
                closed = true
                playing = false
                sendGeneration++
                pendingRtpPackets = 0
                pendingVideoBytes = 0L
                pendingUnitEnqueuedNanos.clear()
                pendingAudioChunks = 0
            }
            senderExecutor.shutdownNow()
            try { socket.close() } catch (_: Exception) {}
        }
    }

    companion object {
        private const val TAG = "VNVAR-RTSP"
        /** Payload rỗng dùng chung (chỉ đọc) cho gói interleaved dài 0. */
        private val EMPTY_PAYLOAD = ByteArray(0)
        private const val RTP_PAYLOAD_BYTES = 1200
        // Trần an toàn theo số gói cho client mạng (giới hạn chính là thời gian/byte).
        private const val MAX_PENDING_RTP_PACKETS = 2048
        private const val MAX_PENDING_RTP_PACKETS_LOOPBACK = 4096
        // Gói cũ nhất chờ quá 0,5 giây thì bỏ tới keyframe kế tiếp (Tablet: trễ thấp).
        private const val MAX_CLIENT_QUEUE_AGE_NANOS = 500_000_000L
        // Relay FFmpeg loopback: chịu được 2 giây khựng (upload livestream) trước
        // khi bỏ tới keyframe, tránh mất 1–3,5 giây hình trên livestream.
        private const val MAX_LOOPBACK_QUEUE_AGE_NANOS = 2_000_000_000L
        // Sàn đủ cho một IDR + vài P-frame ở bitrate thấp (không tự cắt IDR đang gửi).
        private const val MIN_CLIENT_QUEUE_BYTES = 256L * 1024L
        // Sàn byte cho relay loopback (~2 giây ở 2 Mbps mặc định + dư cho IDR).
        private const val MIN_LOOPBACK_QUEUE_BYTES = 1024L * 1024L
        // 50 gói × 10 ms = 0,5 giây âm thanh chờ gửi cho mỗi client.
        private const val MAX_PENDING_AUDIO_CHUNKS = 50
        // 800 gói × 10 ms = 8 giây cho relay livestream cục bộ.
        private const val MAX_PENDING_AUDIO_CHUNKS_LOOPBACK = 800
        private const val LOOPBACK_SEND_BUFFER_BYTES = 2 * 1024 * 1024
        private const val CLIENT_SEND_BUFFER_BYTES = 256 * 1024
        private const val HANDSHAKE_READ_TIMEOUT_MS = 10_000
        private const val PLAYING_READ_TIMEOUT_MS = 60_000
        private const val HANDSHAKE_DEADLINE_MS = 15_000L
        private const val MAX_EMPTY_RTSP_BLOCKS = 8
        private const val SYNC_FRAME_MIN_INTERVAL_NANOS = 1_000_000_000L
        private const val CLIENT_WRITE_STALL_NANOS = 2_000_000_000L
        private const val LOOPBACK_WRITE_STALL_NANOS = 10_000_000_000L
        private const val SENDER_REPORT_INTERVAL_NANOS = 2_000_000_000L
        private const val NTP_UNIX_OFFSET_SECONDS = 2_208_988_800L
        private const val VIDEO_SSRC = 0x564E5652
        private const val AUDIO_SSRC = 0x564E4155
        private const val MAX_RTSP_CLIENTS = 4
        /**
         * Số slot luôn để dành cho client loopback (relay FFmpeg livestream):
         * client mạng LAN chỉ chiếm tối đa MAX_RTSP_CLIENTS - slot này.
         */
        private const val RESERVED_LOOPBACK_SLOTS = 1
        private const val MAX_RTSP_HEADER_BYTES = 64 * 1024
        private const val MIN_RTSP_BITRATE = 500_000

        /**
         * Địa chỉ remote là loopback: 127.0.0.0/8, ::1, hoặc IPv4-mapped
         * ::ffff:127.x (phòng khi socket trả Inet6Address chưa quy đổi về IPv4).
         */
        private fun isLoopbackRemote(address: InetAddress?): Boolean {
            if (address == null) return false
            if (address.isLoopbackAddress) return true
            val raw = address.address ?: return false
            if (raw.size != 16) return false
            for (i in 0 until 10) {
                if (raw[i] != 0.toByte()) return false
            }
            return raw[10] == 0xFF.toByte() &&
                raw[11] == 0xFF.toByte() &&
                raw[12] == 127.toByte()
        }
        private val nextPublisherId = AtomicLong(0L)
        /** Publisher đang chạy theo cổng (cấp tiến trình) để không bao giờ có hai phiên giành một cổng. */
        private val activePublishersByPort = ConcurrentHashMap<Int, VnvarRtspPublisher>()
    }
}
