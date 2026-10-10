package vn.vnvar.cameraStation

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.util.Log
import java.io.InputStream
import java.io.OutputStream
import java.net.Inet4Address
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import java.util.Collections
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import javax.net.ssl.HttpsURLConnection
import javax.net.ssl.SSLSocket
import javax.net.ssl.SSLSocketFactory
import kotlin.concurrent.thread

/**
 * Đường 4G/5G dự phòng cho livestream khi mạng mặc định (thường là Wi-Fi
 * không có Internet) không đẩy được luồng.
 *
 * FFmpeg đẩy vào 127.0.0.1:<cổng>; mỗi kết nối được nối tiếp tới server phát
 * qua `Network.socketFactory` của mạng di động, nên Wi-Fi vẫn phục vụ Tablet.
 * Với RTMPS, TLS được mở ở đây tới đúng tên máy chủ (SNI + kiểm tra chứng chỉ).
 */
class CellularUplink(context: Context) {
    private val connectivity =
        context.getSystemService(ConnectivityManager::class.java)

    @Volatile private var network: Network? = null
    @Volatile private var availability: CountDownLatch? = null
    private var callback: ConnectivityManager.NetworkCallback? = null
    private var server: ServerSocket? = null
    private var target: Triple<String, Int, Boolean>? = null
    private val sockets = Collections.synchronizedSet(mutableSetOf<Socket>())

    /** Trả cổng cục bộ của bộ chuyển tiếp, hoặc null khi không có mạng di động. */
    @Synchronized
    fun open(host: String, port: Int, tls: Boolean): Int? {
        if (ensureCellularNetwork(NETWORK_WAIT_MS) == null) {
            Log.w(TAG, "Mobile data network is unavailable")
            return null
        }
        val desired = Triple(host, port, tls)
        val current = server
        if (current != null && !current.isClosed && target == desired) {
            // FFmpeg chỉ mở lại khi phiên trước đã hỏng: đóng các kết nối cũ
            // (có thể đang kẹt ghi vào socket 4G/5G đã chết) để giải phóng luồng.
            closeLinksLocked()
            return current.localPort
        }
        closeServerLocked()
        val listener = ServerSocket(0, 4, InetAddress.getByName("127.0.0.1"))
        server = listener
        target = desired
        thread(name = "VNVAR-Cellular-Accept", isDaemon = true) {
            while (!listener.isClosed) {
                val local = try {
                    listener.accept()
                } catch (_: Exception) {
                    break
                }
                thread(name = "VNVAR-Cellular-Link", isDaemon = true) {
                    bridge(local, host, port, tls)
                }
            }
        }
        Log.i(TAG, "Mobile data uplink ready: 127.0.0.1:${listener.localPort} -> $host:$port tls=$tls")
        return listener.localPort
    }

    @Synchronized
    fun close() {
        closeServerLocked()
        callback?.let {
            try {
                connectivity.unregisterNetworkCallback(it)
            } catch (_: Exception) {}
        }
        callback = null
        network = null
    }

    private fun closeServerLocked() {
        try { server?.close() } catch (_: Exception) {}
        server = null
        target = null
        closeLinksLocked()
    }

    private fun closeLinksLocked() {
        synchronized(sockets) {
            sockets.forEach { try { it.close() } catch (_: Exception) {} }
            sockets.clear()
        }
    }

    private fun ensureCellularNetwork(timeoutMs: Long): Network? {
        network?.let { return it }
        val latch = CountDownLatch(1)
        availability = latch
        if (callback == null) {
            val networkCallback = object : ConnectivityManager.NetworkCallback() {
                override fun onAvailable(available: Network) {
                    network = available
                    availability?.countDown()
                }

                override fun onLost(lost: Network) {
                    if (network == lost) network = null
                }
            }
            val request = NetworkRequest.Builder()
                .addTransportType(NetworkCapabilities.TRANSPORT_CELLULAR)
                .addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
                .build()
            // Giữ mạng di động hoạt động song song với Wi-Fi.
            connectivity.requestNetwork(request, networkCallback)
            callback = networkCallback
        }
        network?.let { return it }
        try {
            latch.await(timeoutMs, TimeUnit.MILLISECONDS)
        } catch (_: InterruptedException) {
            Thread.currentThread().interrupt()
        }
        return network
    }

    private fun bridge(local: Socket, host: String, port: Int, tls: Boolean) {
        var remote: Socket? = null
        try {
            val cellular = network ?: throw IllegalStateException("Mobile data network lost")
            val address = cellular.getAllByName(host)
                .sortedBy { if (it is Inet4Address) 0 else 1 }
                .first()
            val plain = cellular.socketFactory.createSocket()
            plain.connect(InetSocketAddress(address, port), CONNECT_TIMEOUT_MS)
            plain.tcpNoDelay = true
            remote = if (tls) {
                val secure = (SSLSocketFactory.getDefault() as SSLSocketFactory)
                    .createSocket(plain, host, port, true) as SSLSocket
                secure.startHandshake()
                if (!HttpsURLConnection.getDefaultHostnameVerifier().verify(host, secure.session)) {
                    throw IllegalStateException("TLS certificate does not match $host")
                }
                secure
            } else {
                plain
            }
            local.tcpNoDelay = true
            sockets += local
            sockets += remote
            val upstream = remote
            thread(name = "VNVAR-Cellular-Up", isDaemon = true) {
                pipe(local.getInputStream(), upstream.getOutputStream())
                closeQuietly(upstream)
                closeQuietly(local)
            }
            pipe(upstream.getInputStream(), local.getOutputStream())
        } catch (error: Exception) {
            Log.w(TAG, "Mobile data link to $host:$port failed: ${error.message}")
        } finally {
            closeQuietly(local)
            remote?.let { closeQuietly(it) }
            sockets -= local
            remote?.let { sockets -= it }
        }
    }

    private fun pipe(input: InputStream, output: OutputStream) {
        val buffer = ByteArray(64 * 1024)
        try {
            while (true) {
                val count = input.read(buffer)
                if (count < 0) break
                output.write(buffer, 0, count)
                output.flush()
            }
        } catch (_: Exception) {}
    }

    private fun closeQuietly(socket: Socket) {
        try { socket.close() } catch (_: Exception) {}
    }

    companion object {
        private const val TAG = "VNVAR-Cellular"
        private const val NETWORK_WAIT_MS = 5_000L
        private const val CONNECT_TIMEOUT_MS = 10_000
    }
}
