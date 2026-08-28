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
    private val running = AtomicBoolean(false)
    private var audioRecord: AudioRecord? = null
    private var worker: Thread? = null
    private var output: RandomAccessFile? = null
    private var outputFile: File? = null
    private val dataBytes = AtomicLong(0L)
    private val lastProgressElapsedMs = AtomicLong(0L)

    @Synchronized
    fun start(path: String): Map<String, Any> {
        stop()
        check(
            ContextCompat.checkSelfPermission(context, Manifest.permission.RECORD_AUDIO) ==
                PackageManager.PERMISSION_GRANTED,
        ) { "RECORD_AUDIO permission is not granted" }

        val sampleRate = 48_000
        val channelConfig = AudioFormat.CHANNEL_IN_MONO
        val encoding = AudioFormat.ENCODING_PCM_16BIT
        val minimum = AudioRecord.getMinBufferSize(sampleRate, channelConfig, encoding)
        check(minimum > 0) { "AudioRecord buffer is unavailable: $minimum" }
        val bufferSize = maxOf(minimum * 2, 16_384)
        val recorder = AudioRecord(
            MediaRecorder.AudioSource.VOICE_RECOGNITION,
            sampleRate,
            channelConfig,
            encoding,
            bufferSize,
        )
        check(recorder.state == AudioRecord.STATE_INITIALIZED) {
            recorder.release()
            "AudioRecord failed to initialize"
        }

        val file = File(path)
        file.parentFile?.mkdirs()
        val writer = RandomAccessFile(file, "rw")
        writer.setLength(0)
        writeWavHeader(writer, sampleRate, 1, 16, 0)

        dataBytes.set(0L)
        lastProgressElapsedMs.set(android.os.SystemClock.elapsedRealtime())
        outputFile = file
        output = writer
        audioRecord = recorder
        try {
            recorder.startRecording()
            check(recorder.recordingState == AudioRecord.RECORDSTATE_RECORDING) {
                "Microphone is already occupied or unavailable"
            }
        } catch (error: Exception) {
            running.set(false)
            try { recorder.release() } catch (_: Exception) {}
            try { writer.close() } catch (_: Exception) {}
            audioRecord = null
            output = null
            outputFile = null
            dataBytes.set(0L)
            throw error
        }
        running.set(true)

        worker = Thread({
            val buffer = ByteArray(bufferSize)
            while (running.get()) {
                val count = recorder.read(buffer, 0, buffer.size)
                when {
                    count > 0 -> try {
                        output?.write(buffer, 0, count)
                        dataBytes.addAndGet(count.toLong())
                        lastProgressElapsedMs.set(android.os.SystemClock.elapsedRealtime())
                    } catch (_: Exception) {
                        running.set(false)
                    }
                    count == AudioRecord.ERROR_INVALID_OPERATION ||
                        count == AudioRecord.ERROR_BAD_VALUE -> running.set(false)
                }
            }
        }, "VNVAR-NativeAudio").also { it.start() }

        return mapOf("path" to path, "sampleRate" to sampleRate, "channels" to 1)
    }

    fun status(): Map<String, Any?> = mapOf(
        "active" to running.get(),
        "path" to outputFile?.absolutePath,
        "bytes" to dataBytes.get(),
        "lastProgressElapsedMs" to lastProgressElapsedMs.get(),
    )

    @Synchronized
    fun stop(): Map<String, Any?> {
        val recorder = audioRecord
        val thread = worker
        running.set(false)
        try { recorder?.stop() } catch (_: Exception) {}
        if (thread != null && thread !== Thread.currentThread()) {
            try { thread.join(2_000) } catch (_: InterruptedException) {
                Thread.currentThread().interrupt()
            }
        }
        val bytes = dataBytes.get()
        val file = outputFile
        try {
            output?.let {
                writeWavHeader(it, 48_000, 1, 16, bytes)
                it.fd.sync()
                it.close()
            }
        } finally {
            try { recorder?.release() } catch (_: Exception) {}
            audioRecord = null
            worker = null
            output = null
            outputFile = null
            dataBytes.set(0L)
            lastProgressElapsedMs.set(0L)
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
