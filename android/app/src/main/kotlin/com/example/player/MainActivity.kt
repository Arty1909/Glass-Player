package com.example.player

import android.Manifest
import android.content.ContentUris
import android.content.pm.PackageManager
import android.database.Cursor
import android.media.MediaMetadataRetriever
import android.net.Uri
import android.os.Build
import android.provider.MediaStore
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.IOException
import java.security.MessageDigest

class MainActivity : AudioServiceActivity() {
    private val channelName = "glass.player/device_media"
    private val audioPermissionRequest = 7301
    private val notificationPermissionRequest = 7302
    private var pendingScanResult: MethodChannel.Result? = null
    private var pendingScanExtensions: List<String> = emptyList()
    private var pendingNotificationResult: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            channelName,
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "scanAudio" -> {
                    val extensions =
                        call.argument<List<String>>("extensions") ?: emptyList()
                    requestPermissionAndScan(result, extensions)
                }
                "loadArtwork" -> {
                    val url = call.argument<String>("url") ?: ""
                    val albumId = call.argument<Number>("albumId")?.toLong() ?: 0L
                    loadArtwork(url, albumId, result)
                }
                "prepareAudioSource" -> {
                    val url = call.argument<String>("url") ?: ""
                    val name = call.argument<String>("name") ?: ""
                    val size = call.argument<Number>("size")?.toLong() ?: 0L
                    val modifiedAt =
                        call.argument<Number>("modifiedAt")?.toLong() ?: 0L
                    prepareAudioSource(url, name, size, modifiedAt, result)
                }
                "requestNotificationPermission" -> {
                    requestNotificationPermission(result)
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun requiredAudioPermission(): String {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            Manifest.permission.READ_MEDIA_AUDIO
        } else {
            Manifest.permission.READ_EXTERNAL_STORAGE
        }
    }

    private fun requestPermissionAndScan(
        result: MethodChannel.Result,
        extensions: List<String>,
    ) {
        val permission = requiredAudioPermission()
        if (ContextCompat.checkSelfPermission(this, permission) ==
            PackageManager.PERMISSION_GRANTED
        ) {
            scanAudio(result, extensions)
            return
        }

        pendingScanResult?.error(
            "MEDIA_SCAN_REPLACED",
            "A newer media scan request replaced the previous request.",
            null,
        )
        pendingScanResult = result
        pendingScanExtensions = extensions
        ActivityCompat.requestPermissions(
            this,
            arrayOf(permission),
            audioPermissionRequest,
        )
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == notificationPermissionRequest) {
            val result = pendingNotificationResult ?: return
            pendingNotificationResult = null
            result.success(
                grantResults.isNotEmpty() &&
                    grantResults[0] == PackageManager.PERMISSION_GRANTED,
            )
            return
        }
        if (requestCode != audioPermissionRequest) return

        val result = pendingScanResult ?: return
        val extensions = pendingScanExtensions
        pendingScanResult = null
        pendingScanExtensions = emptyList()
        if (grantResults.isNotEmpty() &&
            grantResults[0] == PackageManager.PERMISSION_GRANTED
        ) {
            scanAudio(result, extensions)
        } else {
            result.error(
                "MEDIA_PERMISSION_DENIED",
                "Music and audio permission was denied.",
                null,
            )
        }
    }

    private fun requestNotificationPermission(result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
            result.success(true)
            return
        }
        if (ContextCompat.checkSelfPermission(
                this,
                Manifest.permission.POST_NOTIFICATIONS,
            ) == PackageManager.PERMISSION_GRANTED
        ) {
            result.success(true)
            return
        }
        pendingNotificationResult?.success(false)
        pendingNotificationResult = result
        ActivityCompat.requestPermissions(
            this,
            arrayOf(Manifest.permission.POST_NOTIFICATIONS),
            notificationPermissionRequest,
        )
    }

    private fun scanAudio(
        result: MethodChannel.Result,
        extensions: List<String>,
    ) {
        Thread {
            try {
                val tracks = mutableListOf<Map<String, Any?>>()
                val projection = arrayOf(
                    MediaStore.Audio.Media._ID,
                    MediaStore.Audio.Media.DATA,
                    MediaStore.Audio.Media.DISPLAY_NAME,
                    MediaStore.Audio.Media.SIZE,
                    MediaStore.Audio.Media.TITLE,
                    MediaStore.Audio.Media.ARTIST,
                    MediaStore.Audio.Media.ALBUM,
                    MediaStore.Audio.Media.ALBUM_ID,
                    MediaStore.Audio.Media.DURATION,
                    MediaStore.Audio.Media.DATE_ADDED,
                    MediaStore.Audio.Media.DATE_MODIFIED,
                )
                val normalizedExtensions = extensions
                    .map { it.trim().lowercase() }
                    .filter { it.isNotEmpty() }
                    .distinct()
                val selection: String
                val selectionArgs: Array<String>?
                if (normalizedExtensions.isEmpty()) {
                    selection =
                        "${MediaStore.Audio.Media.SIZE} > 0 AND " +
                            "${MediaStore.Audio.Media.MIME_TYPE} LIKE 'audio/%'"
                    selectionArgs = null
                } else {
                    val extensionClauses = normalizedExtensions.joinToString(" OR ") {
                        "LOWER(${MediaStore.Audio.Media.DISPLAY_NAME}) LIKE ?"
                    }
                    selection =
                        "${MediaStore.Audio.Media.SIZE} > 0 AND ($extensionClauses)"
                    selectionArgs = normalizedExtensions
                        .map { "%.${it}" }
                        .toTypedArray()
                }
                val sortOrder = "${MediaStore.Audio.Media.DATE_ADDED} DESC"

                val cursor = contentResolver.query(
                    MediaStore.Audio.Media.EXTERNAL_CONTENT_URI,
                    projection,
                    selection,
                    selectionArgs,
                    sortOrder,
                ) ?: throw IllegalStateException("MediaStore audio is unavailable")
                cursor.use { mediaCursor ->
                    while (mediaCursor.moveToNext()) {
                        tracks.add(cursorToTrack(mediaCursor))
                    }
                }

                runOnUiThread { result.success(tracks) }
            } catch (error: Exception) {
                runOnUiThread {
                    result.error(
                        "MEDIA_SCAN_FAILED",
                        error.message ?: "Unable to scan device audio",
                        null,
                    )
                }
            }
        }.start()
    }

    private fun loadArtwork(
        url: String,
        albumId: Long,
        result: MethodChannel.Result,
    ) {
        if (url.isBlank()) {
            result.success(null)
            return
        }
        Thread {
            val artwork = try {
                readArtwork(Uri.parse(url), albumId)
            } catch (_: Exception) {
                null
            }
            runOnUiThread { result.success(artwork) }
        }.start()
    }

    private fun prepareAudioSource(
        url: String,
        name: String,
        size: Long,
        modifiedAt: Long,
        result: MethodChannel.Result,
    ) {
        if (!url.startsWith("content://")) {
            result.error("INVALID_AUDIO_URI", "Expected a content URI.", null)
            return
        }

        Thread {
            try {
                val directory = File(cacheDir, "audio_sources")
                if (!directory.exists() && !directory.mkdirs()) {
                    throw IOException("Unable to create the audio cache directory.")
                }

                val extension = name.substringAfterLast('.', "")
                    .lowercase()
                    .takeIf { it.matches(Regex("[a-z0-9]{1,8}")) }
                    ?.let { ".$it" }
                    ?: ""
                val cacheKey = "$url|$size|$modifiedAt"
                val digest = MessageDigest.getInstance("SHA-256")
                    .digest(cacheKey.toByteArray())
                    .joinToString("") { "%02x".format(it) }
                val cachedFile = File(directory, "$digest$extension")

                if (!cachedFile.exists() || cachedFile.length() <= 0L) {
                    val temporaryFile = File(directory, "$digest.tmp")
                    contentResolver.openInputStream(Uri.parse(url))?.use { input ->
                        temporaryFile.outputStream().buffered().use { output ->
                            input.copyTo(output)
                        }
                    } ?: throw IOException("Unable to open the selected audio file.")

                    if (temporaryFile.length() <= 0L) {
                        temporaryFile.delete()
                        throw IOException("The selected audio file is empty.")
                    }
                    if (cachedFile.exists()) cachedFile.delete()
                    if (!temporaryFile.renameTo(cachedFile)) {
                        temporaryFile.copyTo(cachedFile, overwrite = true)
                        temporaryFile.delete()
                    }
                }

                cachedFile.setLastModified(System.currentTimeMillis())
                directory.listFiles()
                    ?.filter { it.isFile && it != cachedFile }
                    ?.sortedByDescending { it.lastModified() }
                    ?.drop(3)
                    ?.forEach { it.delete() }

                runOnUiThread { result.success(cachedFile.absolutePath) }
            } catch (error: Exception) {
                runOnUiThread {
                    result.error(
                        "AUDIO_SOURCE_FAILED",
                        error.message ?: "Unable to prepare the selected audio file.",
                        null,
                    )
                }
            }
        }.start()
    }

    private fun readArtwork(trackUri: Uri, albumId: Long): ByteArray? {
        if (albumId > 0) {
            try {
                val albumArtUri = ContentUris.withAppendedId(
                    Uri.parse("content://media/external/audio/albumart"),
                    albumId,
                )
                contentResolver.openInputStream(albumArtUri)?.use { stream ->
                    val bytes = stream.readBytes()
                    if (bytes.isNotEmpty()) return bytes
                }
            } catch (_: Exception) {
                // Some Android vendors don't expose the albumart provider.
            }
        }

        val retriever = MediaMetadataRetriever()
        return try {
            retriever.setDataSource(this, trackUri)
            retriever.embeddedPicture
        } catch (_: Exception) {
            null
        } finally {
            try {
                retriever.release()
            } catch (_: Exception) {
                // Already released by the platform.
            }
        }
    }

    private fun cursorToTrack(cursor: Cursor): Map<String, Any?> {
        fun string(column: String): String {
            val index = cursor.getColumnIndex(column)
            return if (index >= 0 && !cursor.isNull(index)) {
                cursor.getString(index) ?: ""
            } else {
                ""
            }
        }

        fun number(column: String): Long {
            val index = cursor.getColumnIndex(column)
            return if (index >= 0 && !cursor.isNull(index)) {
                cursor.getLong(index)
            } else {
                0L
            }
        }

        val id = number(MediaStore.Audio.Media._ID)
        val albumId = number(MediaStore.Audio.Media.ALBUM_ID)
        val contentUri = ContentUris.withAppendedId(
            MediaStore.Audio.Media.EXTERNAL_CONTENT_URI,
            id,
        )

        val artist = string(MediaStore.Audio.Media.ARTIST).let {
            if (it == MediaStore.UNKNOWN_STRING) "" else it
        }

        return mapOf(
            "path" to string(MediaStore.Audio.Media.DATA),
            "url" to contentUri.toString(),
            "name" to string(MediaStore.Audio.Media.DISPLAY_NAME),
            "size" to number(MediaStore.Audio.Media.SIZE),
            "title" to string(MediaStore.Audio.Media.TITLE),
            "artist" to artist,
            "album" to string(MediaStore.Audio.Media.ALBUM),
            "albumId" to albumId,
            "duration" to number(MediaStore.Audio.Media.DURATION),
            "addedAt" to number(MediaStore.Audio.Media.DATE_ADDED) * 1000L,
            "modifiedAt" to number(MediaStore.Audio.Media.DATE_MODIFIED) * 1000L,
        )
    }
}
