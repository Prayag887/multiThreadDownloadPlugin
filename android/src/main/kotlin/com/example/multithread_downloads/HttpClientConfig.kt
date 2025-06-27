package com.example.multithread_downloads


import okhttp3.*
import java.util.concurrent.TimeUnit

object HttpClientConfig {

    // Ultra-optimized HTTP client for maximum throughput
    val client = OkHttpClient.Builder()
        .connectionPool(ConnectionPool(300, 10, TimeUnit.MINUTES))
        .dispatcher(Dispatcher().apply {
            maxRequests = 500
            maxRequestsPerHost = 200
        })
        .protocols(listOf(Protocol.HTTP_2, Protocol.HTTP_1_1))
        .connectTimeout(5, TimeUnit.SECONDS)
        .readTimeout(15, TimeUnit.SECONDS)
        .writeTimeout(15, TimeUnit.SECONDS)
        .retryOnConnectionFailure(true)
        .followRedirects(true)
        .followSslRedirects(true)
        .addInterceptor { chain ->
            val request = chain.request().newBuilder()
                .addHeader("Accept-Encoding", "gzip")
                .addHeader("Connection", "keep-alive")
                .build()
            chain.proceed(request)
        }
        .build()

    fun buildRequest(
        url: String,
        headers: Map<String, String>,
        startByte: Long = 0
    ): Request {
        return Request.Builder()
            .url(url)
            .addHeader("User-Agent", "Mozilla/5.0 (Android) AppleWebKit/537.36")
            .addHeader("Accept", "*/*")
            .addHeader("Accept-Encoding", "gzip, deflate")
            .addHeader("Connection", "keep-alive")
            .apply {
                if (startByte > 0) {
                    addHeader("Range", "bytes=$startByte-")
                }
                headers.forEach { (key, value) -> addHeader(key, value) }
            }
            .build()
    }
}