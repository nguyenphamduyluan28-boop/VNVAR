package vn.vnvar.cameraStation

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import androidx.core.content.ContextCompat
import java.io.File
import java.io.RandomAccessFile
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong

/** Records microphone PCM independently from flutter_webrtc's video muxer. */
class NativeAudioSegmentRecorder(private val context: Context) {
    @Volatile var onPcm: ((ByteArray) -> Unit)? = null
    private val recordingFileActive = AtomicBoolean(false)
    private val streamingActive = AtomicBoolean(false)
    private val isAudioRecordRunning = AtomicBoolean(false)

    private var audioRecord: AudioRecord? = null
    private val windRainFilter = PcmWindRainFilter(48_000, 130f)

    private var worker: Thread? = null
    private val fileLock = Any()
    private var output: RandomAccessFile? = null
    private var outputFile: File? = null
    private val dataBytes = AtomicLong(0L)
    private val lastProgressElapsedMs = AtomicLong(0L)

    private fun ensureAudioRecordStartedLocked() {
        if (isAudioRecordRunning.get() && audioRecord != null && worker != null) {
            return
        }
        check(
            ContextCompat.checkSelfPermission(context, Manifest.permission.RECORD_AUDIO) ==
                PackageManager.PERMISSION_GRANTED,
        ) { "RECORD_AUDIO permission is not granted" }

        val sampleRate = 48_000
        val channelConfig = AudioFormat.CHANNEL_IN_MONO
        val encoding = AudioFormat.ENCODING_PCM_16BIT
        val minimum = AudioRecord.getMinBufferSize(sampleRate, channelConfig, encoding)
        check(minimum > 0) { "AudioRecord buffer is unavailable: $minimum" }
        val internalBufferSize = maxOf(minimum * 4, 16_384)

        // Try CAMCORDER first for wide dynamic range, then VOICE_RECOGNITION
        // (unprocessed on most devices), MIC and DEFAULT. Hardware NoiseSuppressor,
        // AcousticEchoCanceler and AutomaticGainControl are intentionally not
        // attached: they are tuned for calls and suppress the referee whistle and
        // crowd ambience or make the level pump. Only the gentle software
        // high-pass below removes wind rumble.
        val audioSources = intArrayOf(
            MediaRecorder.AudioSource.CAMCORDER,
            MediaRecorder.AudioSource.VOICE_RECOGNITION,
            MediaRecorder.AudioSource.MIC,
            MediaRecorder.AudioSource.DEFAULT,
        )
        var recorder: AudioRecord? = null
        for (source in audioSources) {
            try {
                val candidate = AudioRecord(
                    source,
                    sampleRate,
                    channelConfig,
                    encoding,
                    internalBufferSize,
                )
                if (candidate.state == AudioRecord.STATE_INITIALIZED) {
                    recorder = candidate
                    break
                } else {
                    candidate.release()
                }
            } catch (_: Exception) {}
        }
        val activeRecorder = recorder
            ?: throw IllegalStateException("AudioRecord failed to initialize on available audio sources")

        try {
            activeRecorder.startRecording()
            check(activeRecorder.recordingState == AudioRecord.RECORDSTATE_RECORDING) {
                "Microphone is already occupied or unavailable"
            }
        } catch (error: Exception) {
            try { activeRecorder.release() } catch (_: Exception) {}
            throw error
        }

        windRainFilter.reset()

        audioRecord = activeRecorder
        isAudioRecordRunning.set(true)

        // 960 bytes = 480 samples = 10ms of 16-bit mono 48kHz audio.
        // Reading in 10ms chunks ensures ultra-low latency, zero micro-bursts,
        // and fits cleanly within single RTP packets (<1000 bytes) without IP fragmentation.
        val chunkBytes = 960
        worker = Thread({
            val buffer = ByteArray(chunkBytes)
            while (isAudioRecordRunning.get()) {
                val count = activeRecorder.read(buffer, 0, buffer.size)
                when {
                    count > 0 -> {
                        // Apply zero-allocation high-pass filter to strip wind rumble
                        windRainFilter.processInPlace(buffer, count)
                        val pcmChunk = buffer.copyOf(count)
                        try {
                            synchronized(fileLock) {
                                if (recordingFileActive.get()) {
                                    output?.write(pcmChunk)
                                    dataBytes.addAndGet(count.toLong())
                                }
                            }
                            onPcm?.invoke(pcmChunk)
                            lastProgressElapsedMs.set(android.os.SystemClock.elapsedRealtime())
                        } catch (_: Exception) {}
                    }
                    count == AudioRecord.ERROR_INVALID_OPERATION ||
                        count == AudioRecord.ERROR_BAD_VALUE -> {
                        isAudioRecordRunning.set(false)
                    }
                }
            }
        }, "VNVAR-NativeAudio").also { it.start() }
    }

    private fun stopAudioRecordInternalLocked() {
        val recorder = audioRecord
        val thread = worker
        isAudioRecordRunning.set(false)
        try { recorder?.stop() } catch (_: Exception) {}
        if (thread != null && thread !== Thread.currentThread()) {
            try { thread.join(1_000) } catch (_: InterruptedException) {
                Thread.currentThread().interrupt()
            }
        }
        try { recorder?.release() } catch (_: Exception) {}
        audioRecord = null
        worker = null
    }

    @Synchronized
    fun start(path: String): Map<String, Any> {
        val sampleRate = 48_000
        val file = File(path)
        file.parentFile?.mkdirs()
        val writer = RandomAccessFile(file, "rw")
        writer.setLength(0)
        writeWavHeader(writer, sampleRate, 1, 16, 0)

        synchronized(fileLock) {
            try { output?.close() } catch (_: Exception) {}
            dataBytes.set(0L)
            lastProgressElapsedMs.set(android.os.SystemClock.elapsedRealtime())
            outputFile = file
            output = writer
            recordingFileActive.set(true)
        }

        try {
            ensureAudioRecordStartedLocked()
        } catch (error: Exception) {
            synchronized(fileLock) {
                recordingFileActive.set(false)
                try { writer.close() } catch (_: Exception) {}
                output = null
                outputFile = null
            }
            throw error
        }

        return mapOf("path" to path, "sampleRate" to sampleRate, "channels" to 1)
    }

    @Synchronized
    fun startStreaming(): Boolean {
        streamingActive.set(true)
        return try {
            ensureAudioRecordStartedLocked()
            true
        } catch (_: Exception) {
            streamingActive.set(false)
            false
        }
    }

    @Synchronized
    fun stopStreaming() {
        streamingActive.set(false)
        if (!recordingFileActive.get()) {
            stopAudioRecordInternalLocked()
        }
    }

    fun status(): Map<String, Any?> = mapOf(
        "active" to (recordingFileActive.get() || isAudioRecordRunning.get()),
        "path" to outputFile?.absolutePath,
        "bytes" to dataBytes.get(),
        "lastProgressElapsedMs" to lastProgressElapsedMs.get(),
    )

    @Synchronized
    fun stop(): Map<String, Any?> {
        val bytes = dataBytes.get()
        val file = outputFile
        synchronized(fileLock) {
            recordingFileActive.set(false)
            try {
                output?.let {
                    writeWavHeader(it, 48_000, 1, 16, bytes)
                    it.fd.sync()
                    it.close()
                }
            } catch (_: Exception) {}
            output = null
            outputFile = null
            dataBytes.set(0L)
            lastProgressElapsedMs.set(0L)
        }

        if (!streamingActive.get()) {
            stopAudioRecordInternalLocked()
        }
        return mapOf("path" to file?.absolutePath, "bytes" to bytes)
    }

    private fun writeWavHeader(
        file: RandomAccessFile,
        sampleRate: Int,
        channels: Int,
        bitsPerSample: Int,
        pcmBytes: Long,
    ) {
        val byteRate = sampleRate * channels * bitsPerSample / 8
        val blockAlign = channels * bitsPerSample / 8
        file.seek(0)
        file.writeBytes("RIFF")
        writeLeInt(file, (36L + pcmBytes).coerceAtMost(0xffffffffL).toInt())
        file.writeBytes("WAVEfmt ")
        writeLeInt(file, 16)
        writeLeShort(file, 1)
        writeLeShort(file, channels)
        writeLeInt(file, sampleRate)
        writeLeInt(file, byteRate)
        writeLeShort(file, blockAlign)
        writeLeShort(file, bitsPerSample)
        file.writeBytes("data")
        writeLeInt(file, pcmBytes.coerceAtMost(0xffffffffL).toInt())
    }

    private fun writeLeInt(file: RandomAccessFile, value: Int) {
        file.write(value and 0xff)
        file.write(value ushr 8 and 0xff)
        file.write(value ushr 16 and 0xff)
        file.write(value ushr 24 and 0xff)
    }

    private fun writeLeShort(file: RandomAccessFile, value: Int) {
        file.write(value and 0xff)
        file.write(value ushr 8 and 0xff)
    }
}

/**
 * Zero-allocation in-place IIR High-Pass Filter for 16-bit Mono PCM.
 * Cutoff at 130Hz eliminates low-frequency wind turbulence and tripod vibration,
 * while preserving full speech and referee whistle harmonics (2.5kHz - 3.5kHz).
 */
private class PcmWindRainFilter(sampleRate: Int = 48_000, cutoffHz: Float = 130f) {
    private val alpha: Float
    private var prevX = 0f
    private var prevY = 0f

    init {
        val dt = 1f / sampleRate
        val rc = 1f / (2f * Math.PI.toFloat() * cutoffHz)
        alpha = rc / (rc + dt)
    }

    fun processInPlace(buffer: ByteArray, count: Int) {
        var i = 0
        while (i + 1 < count) {
            val low = buffer[i].toInt() and 0xFF
            val high = buffer[i + 1].toInt() and 0xFF
            val sample = ((high shl 8) or low).toShort().toFloat()

            val filtered = alpha * (prevY + sample - prevX)
            prevX = sample
            prevY = filtered

            val clamped = filtered.coerceIn(-32768f, 32767f).toInt().toShort()
            buffer[i] = (clamped.toInt() and 0xFF).toByte()
            buffer[i + 1] = ((clamped.toInt() shr 8) and 0xFF).toByte()
            i += 2
        }
    }

    fun reset() {
        prevX = 0f
        prevY = 0f
    }
}

