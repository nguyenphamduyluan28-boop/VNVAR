package vn.vnvar.cameraStation

import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaCodecList
import android.media.MediaFormat
import android.os.Build
import android.util.Base64
import android.util.Log
import org.webrtc.VideoFrame
import org.webrtc.VideoSink
import org.webrtc.VideoTrack
import java.io.BufferedReader
import java.io.BufferedWriter
import java.io.InputStreamReader
import java.io.OutputStream
import java.io.OutputStreamWriter
import java.net.ServerSocket
import java.net.Socket
import java.nio.ByteBuffer
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.concurrent.thread

/** Publishes the existing WebRTC VideoTrack as H.264 over RTSP without opening another camera. */
class VnvarRtspPublisher(
    private val track: VideoTrack,
    private val port: Int = 8554,
) : VideoSink {
    private val running = AtomicBoolean(false)
    private val sessions = ConcurrentHashMap<String, Session>()
    private var serverSocket: ServerSocket? = null
    private var codec: MediaCodec? = null
    private var width = 0
    private var height = 0
    private var encoderColorFormat = MediaCodecInfo.CodecCapabilities.COLOR_FormatYUV420Planar
    private var sps: ByteArray? = null
    private var pps: ByteArray? = null
    private val codecLock = Any()
    private val encoderExecutor = Executors.newSingleThreadExecutor { task ->
        Thread(task, "VNVAR-RTSP-Encoder").apply { isDaemon = true }
    }
    private val framePending = AtomicBoolean(false)

    fun start() {
        if (!running.compareAndSet(false, true)) return
        track.addSink(this)
        serverSocket = ServerSocket(port).apply { reuseAddress = true }
        thread(name = "VNVAR-RTSP-Accept", isDaemon = true) {
            while (running.get()) {
                try {
                    val socket = serverSocket?.accept() ?: break
                    socket.tcpNoDelay = true
                    thread(name = "VNVAR-RTSP-Client", isDaemon = true) { handleClient(socket) }
                } catch (error: Exception) {
                    if (running.get()) Log.e(TAG, "RTSP accept failed", error)
                }
            }
        }
        Log.i(TAG, "RTSP started on 0.0.0.0:$port/camera")
    }

    override fun onFrame(frame: VideoFrame) {
        if (!running.get()) return
        // WebRTC owns the capture thread. Never run H.264 conversion/encoding on
        // that thread, otherwise the Tablet stream loses reference frames and
        // shows green macroblocks. Once SPS/PPS are ready, sleep while nobody is
        // watching RTSP so WebRTC and recording keep the device encoder budget.
        if (sps != null && pps != null && sessions.values.none { it.playing }) return
        if (!framePending.compareAndSet(false, true)) return
        frame.retain()
        try {
            encoderExecutor.execute {
                try {
                    encodeFrame(frame)
                } finally {
                    frame.release()
                    framePending.set(false)
                }
            }
        } catch (_: Exception) {
            frame.release()
            framePending.set(false)
        }
    }

    private fun encodeFrame(frame: VideoFrame) {
        if (!running.get()) return
        synchronized(codecLock) {
            try {
                val i420 = frame.buffer.toI420() ?: return
                try {
                    if (codec == null || width != i420.width || height != i420.height) {
                        configureEncoder(i420.width, i420.height)
                    }
                    drainEncoder()
                    val encoder = codec ?: return
                    val index = encoder.dequeueInputBuffer(0)
                    if (index >= 0) {
                        val input = encoder.getInputBuffer(index) ?: return
                        input.clear()
                        copyPlane(i420.dataY, i420.strideY, i420.width, i420.height, input)
                        if (encoderColorFormat == MediaCodecInfo.CodecCapabilities.COLOR_FormatYUV420SemiPlanar) {
                            copyNv12Chroma(i420, input)
                        } else {
                            copyPlane(i420.dataU, i420.strideU, (i420.width + 1) / 2, (i420.height + 1) / 2, input)
                            copyPlane(i420.dataV, i420.strideV, (i420.width + 1) / 2, (i420.height + 1) / 2, input)
                        }
                        encoder.queueInputBuffer(index, 0, input.position(), frame.timestampNs / 1000, 0)
                        drainEncoder()
                    }
                } finally {
                    i420.release()
                }
            } catch (error: Exception) {
                Log.e(TAG, "H264 frame encode failed", error)
            }
        }
    }

    private fun copyPlane(source: ByteBuffer, stride: Int, rowWidth: Int, rows: Int, target: ByteBuffer) {
        val duplicate = source.duplicate()
        for (row in 0 until rows) {
            duplicate.position(row * stride)
            duplicate.limit(row * stride + rowWidth)
            target.put(duplicate)
            duplicate.limit(source.capacity())
        }
    }

    private fun copyNv12Chroma(i420: VideoFrame.I420Buffer, target: ByteBuffer) {
        val chromaWidth = (i420.width + 1) / 2
        val chromaHeight = (i420.height + 1) / 2
        val u = i420.dataU.duplicate()
        val v = i420.dataV.duplicate()
        for (row in 0 until chromaHeight) {
            val uOffset = row * i420.strideU
            val vOffset = row * i420.strideV
            for (column in 0 until chromaWidth) {
                // COLOR_FormatYUV420SemiPlanar on Android AVC encoders is NV12: UVUV.
                target.put(u.get(uOffset + column))
                target.put(v.get(vOffset + column))
            }
        }
    }

    private fun configureEncoder(newWidth: Int, newHeight: Int) {
        codec?.stop()
        codec?.release()
        width = newWidth and 1.inv()
        height = newHeight and 1.inv()
        sps = null
        pps = null
        val codecInfo = MediaCodecList(MediaCodecList.REGULAR_CODECS).codecInfos.firstOrNull {
            it.isEncoder && it.supportedTypes.any { type ->
                type.equals(MediaFormat.MIMETYPE_VIDEO_AVC, ignoreCase = true)
            }
        } ?: throw IllegalStateException("Thiết bị không có H.264 encoder")
        val capabilities = codecInfo.getCapabilitiesForType(MediaFormat.MIMETYPE_VIDEO_AVC)
        encoderColorFormat = when {
            capabilities.colorFormats.contains(MediaCodecInfo.CodecCapabilities.COLOR_FormatYUV420SemiPlanar) ->
                MediaCodecInfo.CodecCapabilities.COLOR_FormatYUV420SemiPlanar
            capabilities.colorFormats.contains(MediaCodecInfo.CodecCapabilities.COLOR_FormatYUV420Planar) ->
                MediaCodecInfo.CodecCapabilities.COLOR_FormatYUV420Planar
            else -> MediaCodecInfo.CodecCapabilities.COLOR_FormatYUV420Flexible
        }
        Log.i(TAG, "H264 encoder=${codecInfo.name}, colorFormat=0x${encoderColorFormat.toString(16)}")
        codec = MediaCodec.createByCodecName(codecInfo.name).apply {
            val format = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_AVC, width, height)
            format.setInteger(MediaFormat.KEY_COLOR_FORMAT, encoderColorFormat)
            format.setInteger(MediaFormat.KEY_BIT_RATE, 2_000_000)
            format.setInteger(MediaFormat.KEY_FRAME_RATE, 60)
            format.setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 1)
            format.setInteger(MediaFormat.KEY_PROFILE, MediaCodecInfo.CodecProfileLevel.AVCProfileBaseline)
            format.setInteger(MediaFormat.KEY_PRIORITY, 0)
            format.setInteger(
                MediaFormat.KEY_BITRATE_MODE,
                MediaCodecInfo.EncoderCapabilities.BITRATE_MODE_CBR,
            )
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                format.setInteger(MediaFormat.KEY_LOW_LATENCY, 1)
            }
            configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
            start()
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
                for (nal in splitNals(bytes)) {
                    when (nal.firstOrNull()?.toInt()?.and(0x1f)) {
                        7 -> sps = nal
                        8 -> pps = nal
                        else -> sendNal(nal, info.presentationTimeUs)
                    }
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

    private fun sendNal(nal: ByteArray, presentationTimeUs: Long) {
        if (nal.isEmpty()) return
        val timestamp = presentationTimeUs * 90 / 1000
        sessions.values.filter { it.playing }.forEach { it.sendNal(nal, timestamp) }
    }

    private fun handleClient(socket: Socket) {
        val session = Session(socket)
        sessions[session.id] = session
        try {
            val reader = BufferedReader(InputStreamReader(socket.getInputStream()))
            val writer = BufferedWriter(OutputStreamWriter(socket.getOutputStream()))
            while (running.get() && !socket.isClosed) {
                val requestLine = reader.readLine() ?: break
                if (requestLine.isBlank()) continue
                val method = requestLine.substringBefore(' ')
                val headers = mutableMapOf<String, String>()
                while (true) {
                    val line = reader.readLine() ?: break
                    if (line.isEmpty()) break
                    val split = line.indexOf(':')
                    if (split > 0) headers[line.substring(0, split).trim().lowercase()] = line.substring(split + 1).trim()
                }
                val cseq = headers["cseq"] ?: "0"
                when (method) {
                    "OPTIONS" -> respond(writer, cseq, "Public: OPTIONS, DESCRIBE, SETUP, PLAY, PAUSE, TEARDOWN\r\n")
                    "DESCRIBE" -> describe(writer, cseq)
                    "SETUP" -> session.setup(writer, cseq, headers["transport"] ?: "")
                    "PLAY" -> { session.playing = true; respond(writer, cseq, "Session: ${session.id}\r\nRTP-Info: url=track0\r\n") }
                    "PAUSE" -> { session.playing = false; respond(writer, cseq, "Session: ${session.id}\r\n") }
                    "TEARDOWN" -> { respond(writer, cseq, "Session: ${session.id}\r\n"); break }
                    else -> writer.apply { write("RTSP/1.0 405 Method Not Allowed\r\nCSeq: $cseq\r\n\r\n"); flush() }
                }
            }
        } catch (error: Exception) {
            Log.d(TAG, "RTSP client closed: ${error.message}")
        } finally {
            sessions.remove(session.id)
            session.close()
        }
    }

    private fun describe(writer: BufferedWriter, cseq: String) {
        val localSps = sps
        val localPps = pps
        if (localSps == null || localPps == null) {
            writer.write("RTSP/1.0 503 Service Unavailable\r\nCSeq: $cseq\r\nRetry-After: 1\r\n\r\n")
            writer.flush()
            return
        }
        val sdp = "v=0\r\no=- 0 0 IN IP4 0.0.0.0\r\ns=VNVAR Camera\r\nt=0 0\r\na=control:*\r\nm=video 0 RTP/AVP 96\r\na=rtpmap:96 H264/90000\r\na=fmtp:96 packetization-mode=1;profile-level-id=42C01F;sprop-parameter-sets=${Base64.encodeToString(localSps, Base64.NO_WRAP)},${Base64.encodeToString(localPps, Base64.NO_WRAP)}\r\na=control:track0\r\n"
        writer.write("RTSP/1.0 200 OK\r\nCSeq: $cseq\r\nContent-Type: application/sdp\r\nContent-Length: ${sdp.toByteArray().size}\r\n\r\n$sdp")
        writer.flush()
    }

    private fun respond(writer: BufferedWriter, cseq: String, extra: String) {
        writer.write("RTSP/1.0 200 OK\r\nCSeq: $cseq\r\n$extra\r\n")
        writer.flush()
    }

    fun stop() {
        if (!running.compareAndSet(true, false)) return
        track.removeSink(this)
        serverSocket?.close()
        sessions.values.forEach { it.close() }
        sessions.clear()
        encoderExecutor.shutdownNow()
        synchronized(codecLock) {
            try { codec?.stop() } catch (_: Exception) {}
            codec?.release()
            codec = null
        }
    }

    private inner class Session(val socket: Socket) {
        val id = UUID.randomUUID().toString().replace("-", "").take(12)
        @Volatile var playing = false
        private var rtpChannel = 0
        private var sequence = 0
        private val output: OutputStream = socket.getOutputStream()

        fun setup(writer: BufferedWriter, cseq: String, transport: String) {
            if (transport.contains("TCP", true) || transport.contains("interleaved", true)) {
                rtpChannel = Regex("interleaved=(\\d+)").find(transport)?.groupValues?.get(1)?.toIntOrNull() ?: 0
                respond(writer, cseq, "Session: $id\r\nTransport: RTP/AVP/TCP;unicast;interleaved=$rtpChannel-${rtpChannel + 1}\r\n")
            } else {
                writer.write("RTSP/1.0 461 Unsupported Transport\r\nCSeq: $cseq\r\n\r\n")
                writer.flush()
            }
        }

        fun sendNal(nal: ByteArray, timestamp: Long) {
            if (nal.size <= 1200) sendPacket(nal, timestamp, true)
            else {
                val header = nal[0].toInt() and 255
                val fuIndicator = (header and 0xe0) or 28
                val nalType = header and 0x1f
                var offset = 1
                var first = true
                while (offset < nal.size) {
                    val size = minOf(1198, nal.size - offset)
                    val last = offset + size >= nal.size
                    val payload = ByteArray(size + 2)
                    payload[0] = fuIndicator.toByte()
                    payload[1] = (nalType or (if (first) 0x80 else 0) or (if (last) 0x40 else 0)).toByte()
                    System.arraycopy(nal, offset, payload, 2, size)
                    sendPacket(payload, timestamp, last)
                    first = false
                    offset += size
                }
            }
        }

        @Synchronized private fun sendPacket(payload: ByteArray, timestamp: Long, marker: Boolean) {
            val packet = ByteArray(12 + payload.size)
            packet[0] = 0x80.toByte(); packet[1] = ((if (marker) 0x80 else 0) or 96).toByte()
            packet[2] = (sequence shr 8).toByte(); packet[3] = sequence.toByte(); sequence = (sequence + 1) and 0xffff
            val ts = timestamp.toInt(); packet[4] = (ts shr 24).toByte(); packet[5] = (ts shr 16).toByte(); packet[6] = (ts shr 8).toByte(); packet[7] = ts.toByte()
            packet[8] = 0x56; packet[9] = 0x4e; packet[10] = 0x56; packet[11] = 0x52
            System.arraycopy(payload, 0, packet, 12, payload.size)
            try {
                output.write(byteArrayOf('$'.code.toByte(), rtpChannel.toByte(), (packet.size shr 8).toByte(), packet.size.toByte()))
                output.write(packet); output.flush()
            } catch (_: Exception) { close() }
        }

        fun close() { playing = false; try { socket.close() } catch (_: Exception) {} }
    }

    companion object { private const val TAG = "VNVAR-RTSP" }
}
