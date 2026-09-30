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

        // Try CAMCORDER first for wide dynamic range and natural acoustics without
        // aggressive speech gating/clipping, then fallback to MIC and DEFAULT.
        val audioSources = intArrayOf(
            MediaRecorder.AudioSource.CAMCORDER,
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
