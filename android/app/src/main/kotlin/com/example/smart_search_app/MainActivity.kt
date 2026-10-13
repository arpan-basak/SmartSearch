package com.example.smart_search_app

import android.Manifest
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.SearchManager
import android.os.BatteryManager
import android.os.PowerManager
import android.os.Build
import android.os.Bundle
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.provider.Settings
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.pdf.PdfRenderer
import android.graphics.drawable.BitmapDrawable
import android.graphics.drawable.Drawable
import android.net.Uri
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.provider.ContactsContract
import android.provider.CallLog
import android.provider.MediaStore
import android.speech.tts.TextToSpeech
import android.speech.tts.UtteranceProgressListener
import android.telephony.PhoneNumberUtils
import android.util.Base64
import android.util.Log
import android.util.Size
import android.webkit.MimeTypeMap
import android.view.WindowManager
import android.view.inputmethod.InputMethodManager
import androidx.core.app.NotificationCompat
import androidx.work.Constraints
import androidx.work.Data
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.ExistingWorkPolicy
import androidx.work.OneTimeWorkRequest
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.Worker
import androidx.work.WorkerParameters
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.InputStream
import java.security.MessageDigest
import java.util.Calendar
import java.util.Locale
import java.util.zip.ZipInputStream
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong
import com.tom_roush.pdfbox.android.PDFBoxResourceLoader
import com.tom_roush.pdfbox.pdmodel.PDDocument
import com.tom_roush.pdfbox.text.PDFTextStripper
import com.google.android.gms.tasks.Tasks
import com.google.mlkit.vision.common.InputImage
import com.google.mlkit.vision.text.TextRecognition
import com.google.mlkit.vision.text.latin.TextRecognizerOptions
import org.json.JSONArray
import org.json.JSONObject
import java.util.concurrent.TimeUnit

private val searchableExtensions = setOf(
    "pdf", "txt", "md", "csv", "json", "xml", "rtf",
    "docx", "xlsx", "pptx", "jpg", "jpeg", "png", "webp",
    "heic", "heif", "bmp"
)

internal fun resolvedMimeType(name: String, reportedType: String?): String {
    val extension = name.substringAfterLast('.', "").lowercase()
    val reported = reportedType.orEmpty().trim()
    if (reported.isNotEmpty() &&
        reported != "application/octet-stream" &&
        reported != "application/unknown") {
        return reported
    }
    return when (extension) {
        "pdf" -> "application/pdf"
        "txt", "md" -> "text/plain"
        "csv" -> "text/csv"
        "json" -> "application/json"
        "xml" -> "application/xml"
        "rtf" -> "application/rtf"
        "docx" -> "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
        "xlsx" -> "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
        "pptx" -> "application/vnd.openxmlformats-officedocument.presentationml.presentation"
        else -> MimeTypeMap.getSingleton().getMimeTypeFromExtension(extension)
            ?: reported.ifEmpty { "application/octet-stream" }
    }
}

internal fun isSearchableFile(name: String, mimeType: String): Boolean {
    val extension = name.substringAfterLast('.', "").lowercase()
    return extension in searchableExtensions ||
        mimeType == "application/pdf" ||
        mimeType.startsWith("text/") ||
        mimeType.startsWith("image/") ||
        mimeType.contains("openxmlformats") ||
        mimeType.contains("officedocument")
}

internal const val INDEX_MODE_ULTRA_FAST = "ultra_fast"
internal const val INDEX_MODE_FAST = "fast"
internal const val INDEX_MODE_BALANCED = "balanced"
internal const val INDEX_MODE_SLOW = "slow"
private const val LEGACY_INDEX_MODE_CHARGING_ONLY = "charging_only"
private const val LEGACY_INDEX_MODE_FASTER = "faster"
private const val DOCUMENT_INDEX_PREFERENCES = "smart_search_cache"
private const val DOCUMENT_INDEX_GENERATION_KEY = "document_index_generation"
private const val DOCUMENT_INDEX_WINDOW_START_KEY =
    "document_index_heavy_window_start_minute"
private const val DOCUMENT_INDEX_WINDOW_END_KEY =
    "document_index_heavy_window_end_minute"
private const val DEFAULT_DOCUMENT_INDEX_WINDOW_START_MINUTE = 0
private const val DEFAULT_DOCUMENT_INDEX_WINDOW_END_MINUTE = 7 * 60
private const val MINUTES_PER_DAY = 24 * 60

/**
 * Serializes the generation switch that starts a fresh scan with durable index
 * commits. A stopped worker can still be unwinding while WorkManager reports
 * cancellation, so it must not be able to write an older generation afterward.
 */
private val documentIndexCommitLock = Any()

private data class DocumentIndexSchedule(
    val startMinute: Int,
    val endMinute: Int,
)

/**
 * A concrete resource policy for one indexing batch. Keeping the policy pure
 * makes the four user-facing speeds both testable and observably different.
 */
internal data class DocumentIndexWorkPolicy(
    val mayRunNow: Boolean,
    val processesHeavyFiles: Boolean,
    val batchSize: Int,
    val maxBatchRuntimeMs: Long,
    val nextBatchDelayMs: Long,
    val requiresBatteryNotLow: Boolean,
    val requiresCharging: Boolean,
    val requiresDeviceIdle: Boolean,
)

internal fun normalizedDocumentIndexMode(mode: String?): String = when (mode) {
    INDEX_MODE_ULTRA_FAST -> INDEX_MODE_ULTRA_FAST
    INDEX_MODE_FAST, LEGACY_INDEX_MODE_FASTER -> INDEX_MODE_FAST
    INDEX_MODE_SLOW, LEGACY_INDEX_MODE_CHARGING_ONLY -> INDEX_MODE_SLOW
    else -> INDEX_MODE_BALANCED
}

internal fun documentIndexWorkPolicy(
    mode: String,
    inScheduledWindow: Boolean,
): DocumentIndexWorkPolicy = when (normalizedDocumentIndexMode(mode)) {
    INDEX_MODE_ULTRA_FAST -> DocumentIndexWorkPolicy(
        mayRunNow = true,
        processesHeavyFiles = true,
        batchSize = 24,
        maxBatchRuntimeMs = 12 * 60 * 1000L,
        nextBatchDelayMs = 0L,
        requiresBatteryNotLow = false,
        requiresCharging = false,
        requiresDeviceIdle = false,
    )
    INDEX_MODE_FAST -> DocumentIndexWorkPolicy(
        mayRunNow = true,
        processesHeavyFiles = true,
        batchSize = 12,
        maxBatchRuntimeMs = 6 * 60 * 1000L,
        nextBatchDelayMs = 5 * 1000L,
        requiresBatteryNotLow = true,
        requiresCharging = false,
        requiresDeviceIdle = false,
    )
    INDEX_MODE_SLOW -> DocumentIndexWorkPolicy(
        mayRunNow = inScheduledWindow,
        processesHeavyFiles = inScheduledWindow,
        batchSize = 1,
        maxBatchRuntimeMs = 60 * 1000L,
        nextBatchDelayMs = 2 * 60 * 1000L,
        requiresBatteryNotLow = true,
        requiresCharging = true,
        requiresDeviceIdle = true,
    )
    else -> if (inScheduledWindow) {
        DocumentIndexWorkPolicy(
            mayRunNow = true,
            processesHeavyFiles = true,
            batchSize = 6,
            maxBatchRuntimeMs = 4 * 60 * 1000L,
            nextBatchDelayMs = 15 * 1000L,
            requiresBatteryNotLow = true,
            requiresCharging = true,
            requiresDeviceIdle = true,
        )
    } else {
        DocumentIndexWorkPolicy(
            mayRunNow = true,
            processesHeavyFiles = false,
            batchSize = 1,
            maxBatchRuntimeMs = 90 * 1000L,
            nextBatchDelayMs = 45 * 1000L,
            requiresBatteryNotLow = true,
            requiresCharging = false,
            requiresDeviceIdle = false,
        )
    }
}

private class IndexingInterruptedException : RuntimeException()

private fun documentIndexPreferences(context: Context) = context.getSharedPreferences(
    DOCUMENT_INDEX_PREFERENCES,
    Context.MODE_PRIVATE,
)

private fun validScheduleMinute(value: Int) = value in 0 until MINUTES_PER_DAY

private fun isValidDocumentIndexSchedule(startMinute: Int, endMinute: Int): Boolean =
    validScheduleMinute(startMinute) &&
        validScheduleMinute(endMinute) &&
        startMinute != endMinute

private fun documentIndexSchedule(context: Context): DocumentIndexSchedule {
    val preferences = documentIndexPreferences(context)
    val startMinute = preferences.getInt(
        DOCUMENT_INDEX_WINDOW_START_KEY,
        DEFAULT_DOCUMENT_INDEX_WINDOW_START_MINUTE,
    )
    val endMinute = preferences.getInt(
        DOCUMENT_INDEX_WINDOW_END_KEY,
        DEFAULT_DOCUMENT_INDEX_WINDOW_END_MINUTE,
    )
    return if (isValidDocumentIndexSchedule(startMinute, endMinute)) {
        DocumentIndexSchedule(startMinute, endMinute)
    } else {
        DocumentIndexSchedule(
            DEFAULT_DOCUMENT_INDEX_WINDOW_START_MINUTE,
            DEFAULT_DOCUMENT_INDEX_WINDOW_END_MINUTE,
        )
    }
}

/** Supports normal and overnight windows. The end minute is exclusive. */
private fun isHeavyIndexWindow(
    context: Context,
    atMillis: Long = System.currentTimeMillis(),
): Boolean {
    val schedule = documentIndexSchedule(context)
    val calendar = Calendar.getInstance().apply { timeInMillis = atMillis }
    val minute = calendar.get(Calendar.HOUR_OF_DAY) * 60 + calendar.get(Calendar.MINUTE)
    return if (schedule.startMinute < schedule.endMinute) {
        minute >= schedule.startMinute && minute < schedule.endMinute
    } else {
        minute >= schedule.startMinute || minute < schedule.endMinute
    }
}

/**
 * WorkManager starts work inexactly. This yields the next eligible start; the
 * worker still checks [isHeavyIndexWindow] before it reads a heavy file.
 */
private fun nextHeavyIndexWindowStart(
    context: Context,
    now: Long = System.currentTimeMillis(),
): Long {
    if (isHeavyIndexWindow(context, now)) return now
    val schedule = documentIndexSchedule(context)
    val calendar = Calendar.getInstance().apply {
        timeInMillis = now
        set(Calendar.HOUR_OF_DAY, schedule.startMinute / 60)
        set(Calendar.MINUTE, schedule.startMinute % 60)
        set(Calendar.SECOND, 0)
        set(Calendar.MILLISECOND, 0)
    }
    if (calendar.timeInMillis <= now) calendar.add(Calendar.DAY_OF_YEAR, 1)
    return calendar.timeInMillis
}

private fun documentIndexGeneration(context: Context): Long =
    documentIndexPreferences(context).getLong(DOCUMENT_INDEX_GENERATION_KEY, 0L)

private fun isCurrentDocumentIndexGeneration(context: Context, expectedGeneration: Long): Boolean =
    documentIndexGeneration(context) == expectedGeneration

private fun advanceDocumentIndexGeneration(context: Context): Long =
    synchronized(documentIndexCommitLock) {
        val preferences = documentIndexPreferences(context)
        val current = preferences.getLong(DOCUMENT_INDEX_GENERATION_KEY, 0L)
        val next = if (current == Long.MAX_VALUE) 1L else current + 1L
        // A committed generation is the fence checked by a cancelled worker.
        preferences.edit().putLong(DOCUMENT_INDEX_GENERATION_KEY, next).commit()
        next
    }

internal fun documentIndexMode(context: Context): String = normalizedDocumentIndexMode(
    documentIndexPreferences(context).getString("document_index_mode", INDEX_MODE_BALANCED)
)

private fun newDocumentIndexRequest(
    context: Context,
    initialDelayMs: Long = 0L,
    scheduledRunAtMs: Long = System.currentTimeMillis() + initialDelayMs,
    generation: Long = documentIndexGeneration(context),
): OneTimeWorkRequest {
    val now = System.currentTimeMillis()
    val mode = documentIndexMode(context)
    val requestedRunAt = maxOf(scheduledRunAtMs, now + initialDelayMs.coerceAtLeast(0L))
    // Slow mode promises not to scan outside the user's window, so avoid even
    // waking its document worker until the next window begins.
    val effectiveRunAt = if (
        mode == INDEX_MODE_SLOW && !isHeavyIndexWindow(context, requestedRunAt)
    ) {
        nextHeavyIndexWindowStart(context, requestedRunAt)
    } else {
        requestedRunAt
    }
    val policy = documentIndexWorkPolicy(
        mode,
        isHeavyIndexWindow(context, effectiveRunAt),
    )
    return OneTimeWorkRequestBuilder<DocumentIndexWorker>()
        .setInputData(
            Data.Builder()
                .putLong(DocumentIndexWorker.INPUT_GENERATION, generation)
                .build()
        )
        .setConstraints(
            Constraints.Builder()
                .setRequiresStorageNotLow(true)
                .apply {
                    if (policy.requiresBatteryNotLow) setRequiresBatteryNotLow(true)
                    if (policy.requiresDeviceIdle) setRequiresDeviceIdle(true)
                    if (policy.requiresCharging) setRequiresCharging(true)
                }
                .build()
        )
        .setInitialDelay(
            (effectiveRunAt - now).coerceAtLeast(0L),
            TimeUnit.MILLISECONDS,
        )
        .addTag(DocumentIndexWorker.WORK_TAG)
        .build()
}

private fun ensureDocumentIndexRecovery(context: Context) {
    val watchdog = PeriodicWorkRequestBuilder<DocumentIndexWatchdogWorker>(
        2,
        TimeUnit.HOURS
    )
        .addTag(DocumentIndexWatchdogWorker.WORK_TAG)
        .build()
    WorkManager.getInstance(context.applicationContext).enqueueUniquePeriodicWork(
        DocumentIndexWatchdogWorker.UNIQUE_WORK_NAME,
        ExistingPeriodicWorkPolicy.UPDATE,
        watchdog
    )
}

class MainActivity: FlutterActivity() {

    private val CHANNEL = "smart_search/apps"
    private val CONTACTS_PERMISSION_REQUEST = 4801
    private val CALL_PHONE_PERMISSION_REQUEST = 4802
    private val NOTIFICATIONS_PERMISSION_REQUEST = 4803
    private val FILES_PERMISSION_REQUEST = 4804
    private val CALL_LOG_PERMISSION_REQUEST = 4805
    private val INDEX_NOTIFICATION_ID = 4810
    private val INDEX_CHANNEL_ID = "document_indexing"
    private val INDEX_BATCH_SIZE = 100
    private val INDEX_BATCH_DELAY_MS = 1200L
    private val IMPORT_PICKER_REQUEST = 4811
    private var appChannel: MethodChannel? = null
    private val pendingImportUris = mutableListOf<Uri>()
    private var pendingImportSubject = ""
    private var pendingPickerResult: MethodChannel.Result? = null
    private var pendingContactsPermissionResult: MethodChannel.Result? = null
    private var pendingCallPhone: String? = null
    private var pendingCallResult: MethodChannel.Result? = null
    private var pendingIndexResult: MethodChannel.Result? = null
    private var pendingIndexForceRecovery = false
    private var pendingIndexRestart = false
    private var pendingFilesIndexResult: MethodChannel.Result? = null
    private var pendingCallUsageResult: MethodChannel.Result? = null
    private var awaitingAllFilesAccess = false
    private var awaitingAllFilesForceRecovery = false
    private var awaitingAllFilesRestart = false
    @Volatile private var documentIndexing = false
    private var voiceTts: TextToSpeech? = null
    @Volatile private var voiceTtsReady = false
    private var pendingVoicePrompt: String? = null
    private var pendingVoicePromptId: String? = null
    private var pendingVoicePromptResult: MethodChannel.Result? = null

    // Interactive retrieval must never queue behind MediaStore enumeration,
    // previews, contacts, graph maintenance, or index recovery.
    private val searchExecutor = Executors.newFixedThreadPool(2)
    private val metadataExecutor = Executors.newFixedThreadPool(2)
    private val maintenanceExecutor = Executors.newSingleThreadExecutor()
    private val latestSearchRequestId = AtomicLong(0L)
    private val semanticStoragePreparationStarted = AtomicBoolean(false)
    private var startupMaintenanceScheduled = false

    private var cachedApps: List<Map<String, String>>? = null
    private var cachedContacts: List<Map<String, String>>? = null

    private fun activateSearchRequest(requestId: Long): Long {
        val active = latestSearchRequestId.updateAndGet { current ->
            maxOf(current, requestId)
        }
        LocalSemanticSearch.activateRequest(active)
        return active
    }

    private fun isAppInstalled(packageName: String): Boolean {
        return try {
            packageManager.getPackageInfo(packageName, 0)
            true
        } catch (e: Exception) {
            false
        }
    }

    private fun getAppsInternal(): List<Map<String, String>> {
        if (cachedApps != null) return cachedApps!!
        val persistent = loadFromCache("apps")
        if (persistent != null) {
            cachedApps = persistent
            return persistent
        }
        return emptyList()
    }

    private fun appIconBase64(icon: Drawable): String {
        return try {
            val size = 96
            val bitmap = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888)
            val canvas = Canvas(bitmap)
            icon.setBounds(0, 0, size, size)
            icon.draw(canvas)
            val output = ByteArrayOutputStream()
            bitmap.compress(Bitmap.CompressFormat.PNG, 100, output)
            Base64.encodeToString(output.toByteArray(), Base64.NO_WRAP)
        } catch (_: Exception) {
            ""
        }
    }

    private fun documentPreviewBase64(path: String, reportedType: String, name: String): String {
        val uri = Uri.parse(path)
        if (uri.scheme != "content") return ""
        var bitmap: Bitmap? = null
        var temporaryPdf: File? = null
        return try {
            val mimeType = resolvedMimeType(name,
                reportedType.takeIf { it.contains('/') } ?: contentResolver.getType(uri))
            bitmap = when {
                mimeType.startsWith("image/", ignoreCase = true) -> {
                    val thumbnail = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                        try { contentResolver.loadThumbnail(uri, Size(176, 176), null) }
                        catch (_: Exception) { null }
                    } else null
                    if (thumbnail != null) {
                        thumbnail
                    } else {
                    val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
                    contentResolver.openInputStream(uri)?.use {
                        BitmapFactory.decodeStream(it, null, bounds)
                    }
                    var sample = 1
                    while (bounds.outWidth / sample > 352 || bounds.outHeight / sample > 352) {
                        sample *= 2
                    }
                    val options = BitmapFactory.Options().apply { inSampleSize = sample }
                    contentResolver.openInputStream(uri)?.use {
                        BitmapFactory.decodeStream(it, null, options)
                    }
                    }
                }
                mimeType.startsWith("text/") || name.substringAfterLast('.').lowercase() in
                    setOf("txt", "md", "csv", "json", "xml", "log") -> {
                    val text = contentResolver.openInputStream(uri)?.use { input ->
                        input.bufferedReader().use { reader ->
                            val chars = CharArray(1800)
                            val count = reader.read(chars)
                            if (count > 0) String(chars, 0, count) else ""
                        }
                    }.orEmpty()
                    if (text.isBlank()) null else Bitmap.createBitmap(176, 208, Bitmap.Config.ARGB_8888).also {
                        it.eraseColor(Color.WHITE)
                        val canvas = Canvas(it)
                        val paint = android.text.TextPaint(android.graphics.Paint.ANTI_ALIAS_FLAG).apply {
                            color = Color.DKGRAY
                            textSize = 12f
                        }
                        @Suppress("DEPRECATION")
                        val layout = android.text.StaticLayout(text, paint, 156,
                            android.text.Layout.Alignment.ALIGN_NORMAL, 1f, 2f, false)
                        canvas.translate(10f, 10f)
                        layout.draw(canvas)
                    }
                }
                mimeType.equals("application/pdf", ignoreCase = true) -> {
                    val descriptor = contentResolver.openFileDescriptor(uri, "r") ?: return ""
                    val pdf = try {
                        PdfRenderer(descriptor)
                    } catch (_: IllegalArgumentException) {
                        // Some document providers return pipes. PdfRenderer
                        // requires a seekable descriptor, so stage only this
                        // requested preview in private, temporary storage.
                        descriptor.close()
                        val staged = File.createTempFile("preview-", ".pdf", cacheDir)
                        temporaryPdf = staged
                        contentResolver.openInputStream(uri)?.use { input ->
                            staged.outputStream().use { output ->
                                val buffer = ByteArray(16384)
                                var total = 0L
                                while (true) {
                                    val count = input.read(buffer)
                                    if (count < 0) break
                                    total += count
                                    if (total > 64L * 1024 * 1024) return ""
                                    output.write(buffer, 0, count)
                                }
                            }
                        } ?: return ""
                        val local = android.os.ParcelFileDescriptor.open(staged,
                            android.os.ParcelFileDescriptor.MODE_READ_ONLY)
                        try { PdfRenderer(local) } catch (error: Exception) {
                            local.close()
                            throw error
                        }
                    } catch (error: Exception) {
                        descriptor.close()
                        throw error
                    }
                        pdf.use { renderer ->
                            if (renderer.pageCount == 0) return@use null
                            renderer.openPage(0).use { page ->
                                val scale = minOf(
                                    176f / page.width.coerceAtLeast(1),
                                    208f / page.height.coerceAtLeast(1),
                                )
                                val width = (page.width * scale).toInt().coerceAtLeast(1)
                                val height = (page.height * scale).toInt().coerceAtLeast(1)
                                Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888).also {
                                    it.eraseColor(Color.WHITE)
                                    page.render(it, null, null, PdfRenderer.Page.RENDER_MODE_FOR_DISPLAY)
                                }
                            }
                        }
                }
                else -> null
            }
            val preview = bitmap ?: return ""
            val output = ByteArrayOutputStream()
            preview.compress(Bitmap.CompressFormat.PNG, 90, output)
            Base64.encodeToString(output.toByteArray(), Base64.NO_WRAP)
        } catch (_: Exception) {
            ""
        } finally {
            bitmap?.recycle()
            temporaryPdf?.delete()
        }
    }

    private fun getContactsInternal(): List<Map<String, String>> {
        if (cachedContacts != null) return cachedContacts!!
        return emptyList()
    }

    private fun getPrefs() = documentIndexPreferences(applicationContext)

    private fun saveToCache(key: String, data: List<Map<String, String>>) {
        val array = JSONArray()
        for (map in data) {
            val obj = JSONObject()
            for ((k, v) in map) {
                obj.put(k, v)
            }
            array.put(obj)
        }
        getPrefs().edit().putString(key, array.toString()).apply()
    }

    private fun loadFromCache(key: String): List<Map<String, String>>? {
        val json = getPrefs().getString(key, null) ?: return null
        val list = mutableListOf<Map<String, String>>()
        try {
            val array = JSONArray(json)
            for (i in 0 until array.length()) {
                val obj = array.getJSONObject(i)
                val map = mutableMapOf<String, String>()
                val keys = obj.keys()
                while (keys.hasNext()) {
                    val k = keys.next()
                    map[k] = obj.getString(k)
                }
                list.add(map)
            }
            return list
        } catch (e: Exception) {
            return null
        }
    }

    private fun prewarmData() {
        metadataExecutor.execute {
            getAppsInternal()
            getContactsInternal()
        }
    }

    private fun loadDocumentIndex(): List<Map<String, String>> =
        DocumentIndexDatabase.representativeRows(applicationContext)

    private fun documentRows(includeExcluded: Boolean = false): List<Map<String, String>> {
        val docs = mutableListOf<Map<String, String>>()
        val excludedFolders = getPrefs().getStringSet("excluded_document_folders", emptySet())
            ?: emptySet()
        val uri = MediaStore.Files.getContentUri("external")
        val projection = mutableListOf(
            MediaStore.Files.FileColumns._ID,
            MediaStore.Files.FileColumns.DISPLAY_NAME,
            MediaStore.Files.FileColumns.MIME_TYPE,
            MediaStore.Files.FileColumns.DATE_MODIFIED,
            MediaStore.Files.FileColumns.SIZE
        ).apply {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                add(MediaStore.Files.FileColumns.RELATIVE_PATH)
            }
        }.toTypedArray()
        try {
            contentResolver.query(uri, projection, null, null,
                "${MediaStore.Files.FileColumns.DATE_MODIFIED} DESC")?.use { cursor ->
                val idColumn = cursor.getColumnIndexOrThrow(MediaStore.Files.FileColumns._ID)
                val nameColumn = cursor.getColumnIndexOrThrow(MediaStore.Files.FileColumns.DISPLAY_NAME)
                val mimeColumn = cursor.getColumnIndexOrThrow(MediaStore.Files.FileColumns.MIME_TYPE)
                val modifiedColumn = cursor.getColumnIndexOrThrow(MediaStore.Files.FileColumns.DATE_MODIFIED)
                val sizeColumn = cursor.getColumnIndexOrThrow(MediaStore.Files.FileColumns.SIZE)
                val folderColumn = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                    cursor.getColumnIndex(MediaStore.Files.FileColumns.RELATIVE_PATH)
                } else -1
                while (cursor.moveToNext()) {
                    val name = cursor.getString(nameColumn) ?: continue
                    val type = resolvedMimeType(name, cursor.getString(mimeColumn))
                    val size = cursor.getLong(sizeColumn)
                    val folder = if (folderColumn >= 0) cursor.getString(folderColumn).orEmpty() else ""
                    if (size <= 0 || !isSearchableFile(name, type)) continue
                    if (!includeExcluded &&
                        excludedFolders.any { folder.startsWith(it, ignoreCase = true) }
                    ) continue
                    docs.add(mapOf(
                        "name" to name,
                        "type" to type,
                        "path" to Uri.withAppendedPath(uri, cursor.getLong(idColumn).toString()).toString(),
                        "modified" to cursor.getLong(modifiedColumn).toString(),
                        "size" to size.toString(),
                        "folder" to folder
                    ))
                }
            }
        } catch (_: SecurityException) {
            // The normal document list stays empty until Android grants access.
        } catch (_: Exception) { }
        docs.addAll(ImportedDocumentStore.rows(applicationContext).filter { row ->
            includeExcluded || excludedFolders.none {
                row["folder"].orEmpty().startsWith(it, ignoreCase = true)
            }
        })
        return docs.sortedBy { it["type"].orEmpty().startsWith("image/") }
    }

    private fun extractText(uri: String, type: String): String {
        return try {
            val source = contentResolver.openInputStream(Uri.parse(uri)) ?: return ""
            source.use { input ->
                when {
                    type.contains("pdf", ignoreCase = true) -> {
                        PDDocument.load(input).use { document ->
                            PDFTextStripper().getText(document).take(12000)
                        }
                    }
                    type.startsWith("text/", ignoreCase = true) ->
                        input.bufferedReader().readText().take(12000)
                    type.contains("openxmlformats", ignoreCase = true) -> extractOfficeText(input)
                    else -> ""
                }
            }
        } catch (_: Exception) {
            ""
        }
    }

    private fun extractOfficeText(input: InputStream): String {
        val result = StringBuilder()
        ZipInputStream(input).use { zip ->
            var entry = zip.nextEntry
            while (entry != null && result.length < 12000) {
                val relevant = entry.name.startsWith("word/") ||
                    entry.name.startsWith("ppt/slides/") ||
                    entry.name.startsWith("xl/sharedStrings")
                if (relevant && entry.name.endsWith(".xml")) {
                    val xml = zip.bufferedReader().readText()
                    result.append(' ').append(xml.replace(Regex("<[^>]+>"), " "))
                }
                zip.closeEntry()
                entry = zip.nextEntry
            }
        }
        return result.toString().replace(Regex("\\s+"), " ").take(12000)
    }

    private fun createIndexChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                INDEX_CHANNEL_ID, "Document indexing", NotificationManager.IMPORTANCE_LOW
            ).apply { description = "Shows local file indexing progress" }
            getSystemService(NotificationManager::class.java).createNotificationChannel(channel)
        }
    }

    private fun formatBytes(bytes: Long): String = when {
        bytes >= 1024 * 1024 -> String.format("%.1f MB", bytes / (1024.0 * 1024.0))
        bytes >= 1024 -> String.format("%.0f KB", bytes / 1024.0)
        else -> "$bytes B"
    }

    private fun showIndexNotification(done: Int, total: Int, bytes: Long, finished: Boolean = false) {
        // API 33 is Android 13. Using the number keeps this compatible with
        // Android SDK installations that do not expose VERSION_CODES.T.
        if (Build.VERSION.SDK_INT >= 33 &&
            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) return
        createIndexChannel()
        val text = if (finished) "Indexed $done files • ${formatBytes(bytes)} extracted on this device"
            else "Indexed $done of $total files • ${formatBytes(bytes)} extracted"
        val notification = NotificationCompat.Builder(this, INDEX_CHANNEL_ID)
            .setSmallIcon(android.R.drawable.ic_menu_search)
            .setContentTitle(if (finished) "File index is ready" else "Indexing your files")
            .setContentText(text)
            .setOnlyAlertOnce(true)
            .setOngoing(!finished)
            .setProgress(if (finished) 0 else total.coerceAtLeast(1), if (finished) 0 else done, !finished && total == 0)
            .build()
        getSystemService(NotificationManager::class.java).notify(INDEX_NOTIFICATION_ID, notification)
    }

    private fun startDocumentIndexing(forceRecovery: Boolean = false) {
        // KEEP prevents every activity resume from cancelling a healthy batch.
        // A stale/incomplete index is explicitly replaced, and the independent
        // periodic watchdog provides the same recovery even if the app is not
        // opened again.
        ensureDocumentIndexRecovery(applicationContext)
        val preferences = getPrefs()
        if (preferences.getBoolean("document_index_paused_for_search", false)) {
            preferences.edit()
                .putString("document_index_state", "paused_for_search")
                .putString("document_index_current_file", "")
                .apply()
            return
        }
        val now = System.currentTimeMillis()
        val lastActivity = maxOf(
            preferences.getLong("document_index_last_progress_at", 0L),
            preferences.getLong("document_index_worker_started_at", 0L),
            preferences.getLong("document_index_requested_at", 0L)
        )
        val stale = !preferences.getBoolean("document_index_complete", false) &&
            now - lastActivity > DocumentIndexWatchdogWorker.STALE_AFTER_MS
        val policy = if (forceRecovery || stale) {
            ExistingWorkPolicy.REPLACE
        } else {
            ExistingWorkPolicy.KEEP
        }
        val existingState = preferences.getString("document_index_state", "idle")
        val mode = documentIndexMode(applicationContext)
        val workPolicy = documentIndexWorkPolicy(
            mode,
            isHeavyIndexWindow(applicationContext, now),
        )
        val constraintState = when {
            !workPolicy.mayRunNow -> "scheduled"
            workPolicy.requiresCharging && workPolicy.requiresDeviceIdle ->
                "waiting_for_idle_charging"
            workPolicy.requiresCharging -> "waiting_for_charging"
            workPolicy.requiresDeviceIdle -> "waiting_for_idle"
            else -> "queued"
        }
        val requestedState = if (
            policy == ExistingWorkPolicy.KEEP && existingState == "running"
        ) {
            "running"
        } else if (stale) {
            "recovering"
        } else {
            constraintState
        }
        preferences.edit()
            .putBoolean("document_index_complete", false)
            .putString("document_index_state", requestedState)
            .putLong("document_index_requested_at", now)
            .apply()
        Log.i(
            DocumentIndexWorker.LOG_TAG,
            "Index requested policy=$policy force=$forceRecovery stale=$stale"
        )
        WorkManager.getInstance(applicationContext).enqueueUniqueWork(
            DocumentIndexWorker.UNIQUE_WORK_NAME,
            policy,
            newDocumentIndexRequest(applicationContext)
        )
    }

    /**
     * Explicit user action: re-read every currently exposed file without
     * discarding their exclusions, power preference, or graph usage history.
     */
    private fun restartDocumentIndexing(result: MethodChannel.Result? = null) {
        val appContext = applicationContext
        maintenanceExecutor.execute {
            try {
                val workManager = WorkManager.getInstance(appContext)
                // Wait off the main thread for the previous unique chain to be
                // cancelled before switching its durable generation fence.
                workManager.cancelUniqueWork(DocumentIndexWorker.UNIQUE_WORK_NAME)
                    .result.get()
                val generation = DocumentIndexer.beginFreshIndexGeneration(appContext)
                ensureDocumentIndexRecovery(appContext)
                startDocumentIndexing(forceRecovery = true)
                Log.i(DocumentIndexWorker.LOG_TAG, "Fresh index requested generation=$generation")
                runOnUiThread { result?.success(true) }
            } catch (error: Exception) {
                Log.e(DocumentIndexWorker.LOG_TAG, "Could not restart document indexing", error)
                runOnUiThread {
                    result?.error("INDEX_RESTART_FAILED", "Could not restart file indexing.", null)
                }
            }
        }
    }

    private fun startIndexAfterNotificationPermission(
        forceRecovery: Boolean,
        result: MethodChannel.Result? = null,
    ) {
        if (Build.VERSION.SDK_INT >= 33 &&
            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) !=
            PackageManager.PERMISSION_GRANTED) {
            pendingIndexResult = result
            pendingIndexForceRecovery = forceRecovery
            requestPermissions(
                arrayOf(Manifest.permission.POST_NOTIFICATIONS),
                NOTIFICATIONS_PERMISSION_REQUEST
            )
            return
        }
        startDocumentIndexing(forceRecovery)
        result?.success(true)
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        captureSharedDocuments(intent)
        if (intent?.action in setOf(Intent.ACTION_SEND, Intent.ACTION_SEND_MULTIPLE)) {
            setIntent(Intent(Intent.ACTION_MAIN))
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            // Do not fade a dark splash over an already-rendered Flutter UI.
            // Android calls this only when the app content is ready to reveal.
            splashScreen.setOnExitAnimationListener { splashView ->
                splashView.remove()
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        captureSharedDocuments(intent)
        if (intent.action in setOf(Intent.ACTION_SEND, Intent.ACTION_SEND_MULTIPLE)) {
            setIntent(Intent(Intent.ACTION_MAIN))
        }
        appChannel?.invokeMethod("sharedDocumentsAvailable", null)
    }

    @Suppress("DEPRECATION")
    private fun captureSharedDocuments(sourceIntent: Intent?) {
        if (sourceIntent?.action !in setOf(Intent.ACTION_SEND, Intent.ACTION_SEND_MULTIPLE)) return
        val incoming = mutableListOf<Uri>()
        sourceIntent?.clipData?.let { clip ->
            for (index in 0 until clip.itemCount) clip.getItemAt(index).uri?.let(incoming::add)
        }
        if (sourceIntent?.action == Intent.ACTION_SEND_MULTIPLE) {
            sourceIntent.getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM)?.let(incoming::addAll)
        } else {
            sourceIntent?.getParcelableExtra<Uri>(Intent.EXTRA_STREAM)?.let(incoming::add)
        }
        synchronized(pendingImportUris) {
            pendingImportUris.addAll(incoming.filter { it.scheme == "content" }.distinct())
            pendingImportSubject = sourceIntent?.getStringExtra(Intent.EXTRA_SUBJECT).orEmpty()
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != IMPORT_PICKER_REQUEST) return
        if (resultCode == RESULT_OK) {
            val selected = mutableListOf<Uri>()
            data?.data?.let(selected::add)
            data?.clipData?.let { clip ->
                for (index in 0 until clip.itemCount) clip.getItemAt(index).uri?.let(selected::add)
            }
            synchronized(pendingImportUris) {
                pendingImportUris.addAll(selected.filter { it.scheme == "content" }.distinct())
            }
        }
        pendingPickerResult?.success(resultCode == RESULT_OK)
        pendingPickerResult = null
    }

    override fun onFlutterUiDisplayed() {
        super.onFlutterUiDisplayed()
        if (startupMaintenanceScheduled) return
        startupMaintenanceScheduled = true

        // A fixed delay from onCreate can still expire before a cold first
        // frame. Wait for Flutter to actually be visible, then do disk work
        // off the Android UI thread.
        maintenanceExecutor.execute {
            // Remove legacy sensitive caches without delaying window layout.
            getPrefs().edit()
                .remove("contacts")
                .remove("discovered_groups")
                .apply()
            ensureDocumentIndexRecovery(applicationContext)
        }
    }

    override fun onResume() {
        super.onResume()
        if (awaitingAllFilesAccess &&
            (Build.VERSION.SDK_INT < Build.VERSION_CODES.R ||
                Environment.isExternalStorageManager())) {
            val restart = awaitingAllFilesRestart
            val forceRecovery = awaitingAllFilesForceRecovery
            awaitingAllFilesAccess = false
            awaitingAllFilesForceRecovery = false
            awaitingAllFilesRestart = false
            if (restart) {
                restartDocumentIndexing()
            } else {
                startIndexAfterNotificationPermission(forceRecovery)
            }
        }
    }

    private fun startDirectCall(phone: String, result: MethodChannel.Result) {
        val normalizedPhone = phone.trim().replace(Regex("[\\s()-]"), "")
        // Do not allow USSD/service codes to be executed from natural language.
        if (!normalizedPhone.matches(Regex("^\\+?[0-9]{3,20}$"))) {
            result.error("INVALID", "Invalid phone number", null)
            return
        }
        try {
            startActivity(Intent(Intent.ACTION_CALL, Uri.parse("tel:$normalizedPhone")))
            result.success(true)
        } catch (e: Exception) {
            result.error("FAILED", "Could not start the phone call", null)
        }
    }

    private fun completeVoicePrompt(utteranceId: String, success: Boolean) {
        runOnUiThread {
            if (pendingVoicePromptId != utteranceId) return@runOnUiThread
            pendingVoicePromptId = null
            pendingVoicePrompt = null
            val result = pendingVoicePromptResult
            pendingVoicePromptResult = null
            result?.success(success)
        }
    }

    private fun startQueuedVoicePrompt() {
        val prompt = pendingVoicePrompt ?: return
        val utteranceId = pendingVoicePromptId ?: return
        val status = voiceTts?.speak(
            prompt,
            TextToSpeech.QUEUE_FLUSH,
            Bundle(),
            utteranceId
        ) ?: TextToSpeech.ERROR
        if (status == TextToSpeech.ERROR) {
            completeVoicePrompt(utteranceId, false)
        }
    }

    private fun speakVoicePrompt(text: String, result: MethodChannel.Result) {
        val prompt = text.trim().take(500)
        if (prompt.isEmpty()) {
            result.error("INVALID", "Missing voice prompt text", null)
            return
        }
        stopVoicePrompt()
        val utteranceId = "apex-voice-${SystemClock.elapsedRealtime()}"
        pendingVoicePrompt = prompt
        pendingVoicePromptId = utteranceId
        pendingVoicePromptResult = result
        val current = voiceTts
        if (current != null && voiceTtsReady) {
            startQueuedVoicePrompt()
            return
        }
        if (current != null) return
        voiceTts = TextToSpeech(applicationContext) { status ->
            voiceTtsReady = status == TextToSpeech.SUCCESS
            if (!voiceTtsReady) {
                pendingVoicePromptId?.let { completeVoicePrompt(it, false) }
                return@TextToSpeech
            }
            voiceTts?.apply {
                language = Locale.getDefault()
                setOnUtteranceProgressListener(object : UtteranceProgressListener() {
                    override fun onStart(utteranceId: String) = Unit

                    override fun onDone(utteranceId: String) {
                        completeVoicePrompt(utteranceId, true)
                    }

                    @Deprecated("Deprecated in Java")
                    override fun onError(utteranceId: String) {
                        completeVoicePrompt(utteranceId, false)
                    }

                    override fun onError(utteranceId: String, errorCode: Int) {
                        completeVoicePrompt(utteranceId, false)
                    }
                })
            }
            startQueuedVoicePrompt()
        }
    }

    private fun stopVoicePrompt() {
        val pendingResult = pendingVoicePromptResult
        pendingVoicePrompt = null
        pendingVoicePromptId = null
        pendingVoicePromptResult = null
        voiceTts?.stop()
        pendingResult?.success(false)
    }

    private fun getOutgoingCallUsage(): List<Map<String, String>> {
        if (checkSelfPermission(Manifest.permission.READ_CALL_LOG) !=
            PackageManager.PERMISSION_GRANTED) return emptyList()
        val usage = linkedMapOf<String, Pair<Int, Long>>()
        val projection = arrayOf(
            CallLog.Calls.NUMBER,
            CallLog.Calls.DATE
        )
        contentResolver.query(
            CallLog.Calls.CONTENT_URI,
            projection,
            "${CallLog.Calls.TYPE} = ?",
            arrayOf(CallLog.Calls.OUTGOING_TYPE.toString()),
            "${CallLog.Calls.DATE} DESC"
        )?.use { cursor ->
            val numberColumn = cursor.getColumnIndexOrThrow(CallLog.Calls.NUMBER)
            val dateColumn = cursor.getColumnIndexOrThrow(CallLog.Calls.DATE)
            while (cursor.moveToNext()) {
                val normalized = PhoneNumberUtils.normalizeNumber(
                    cursor.getString(numberColumn).orEmpty()
                ).filter { it.isDigit() }
                if (normalized.length < 3) continue
                val date = cursor.getLong(dateColumn)
                val previous = usage[normalized]
                usage[normalized] = Pair(
                    (previous?.first ?: 0) + 1,
                    maxOf(previous?.second ?: 0L, date)
                )
            }
        }
        return usage.map { (phone, value) ->
            mapOf(
                "phone" to phone,
                "count" to value.first.toString(),
                "lastCalled" to value.second.toString()
            )
        }
    }

    private fun returnCallUsage(result: MethodChannel.Result) {
        metadataExecutor.execute {
            val usage = try { getOutgoingCallUsage() } catch (_: Exception) { emptyList() }
            runOnUiThread { result.success(usage) }
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        appChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            CHANNEL
        )
        appChannel?.setMethodCallHandler { call, result ->

            when (call.method) {

                "pickNotesToImport" -> {
                    if (pendingPickerResult != null) {
                        result.error("PICKER_BUSY", "The file picker is already open.", null)
                    } else {
                        pendingPickerResult = result
                        val picker = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                            addCategory(Intent.CATEGORY_OPENABLE)
                            type = "*/*"
                            putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true)
                            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                        }
                        try {
                            startActivityForResult(picker, IMPORT_PICKER_REQUEST)
                        } catch (_: Exception) {
                            pendingPickerResult = null
                            result.error("PICKER_UNAVAILABLE", "Could not open the file picker.", null)
                        }
                    }
                }

                "getPendingSharedDocuments" -> {
                    val snapshot = synchronized(pendingImportUris) {
                        pendingImportUris.distinct() to pendingImportSubject
                    }
                    metadataExecutor.execute {
                        val names = snapshot.first.map { source ->
                            ImportedDocumentStore.describe(applicationContext, source)["name"].orEmpty()
                        }
                        runOnUiThread {
                            result.success(mapOf("names" to names, "subject" to snapshot.second))
                        }
                    }
                }

                "dismissPendingSharedDocuments" -> {
                    synchronized(pendingImportUris) {
                        pendingImportUris.clear()
                        pendingImportSubject = ""
                    }
                    result.success(true)
                }

                "importSharedDocuments" -> {
                    val subject = call.argument<String>("subject").orEmpty()
                    val snapshot = synchronized(pendingImportUris) { pendingImportUris.distinct() }
                    if (subject.isBlank() || snapshot.isEmpty()) {
                        result.error("INVALID_IMPORT", "Select notes and enter their subject.", null)
                    } else {
                        maintenanceExecutor.execute {
                            val imported = mutableListOf<Map<String, String>>()
                            val failures = mutableListOf<String>()
                            snapshot.forEach { source ->
                                try {
                                    imported += ImportedDocumentStore.import(
                                        applicationContext, source, subject,
                                    )
                                } catch (error: Exception) {
                                    failures += error.message ?: "Could not read an attachment."
                                }
                            }
                            synchronized(pendingImportUris) {
                                pendingImportUris.removeAll(snapshot.toSet())
                                pendingImportSubject = ""
                            }
                            if (imported.isNotEmpty() && (Build.VERSION.SDK_INT < 30 ||
                                    Environment.isExternalStorageManager())) {
                                startDocumentIndexing(forceRecovery = true)
                            }
                            runOnUiThread {
                                result.success(mapOf(
                                    "imported" to imported.size,
                                    "failed" to failures.size,
                                    "error" to failures.firstOrNull().orEmpty(),
                                ))
                            }
                        }
                    }
                }

                "removeImportedDocument" -> {
                    val path = call.argument<String>("path").orEmpty()
                    val importedUri = Uri.parse(path)
                    if (importedUri.scheme != "content" ||
                        importedUri.authority != "$packageName.imported_documents") {
                        result.error("INVALID", "Only imported copies can be removed.", null)
                    } else {
                        maintenanceExecutor.execute {
                            val removed = ImportedDocumentStore.delete(
                                applicationContext, importedUri,
                            )
                            if (removed) {
                                runCatching {
                                    DocumentIndexDatabase.removeGeneratedDataFor(
                                        applicationContext, setOf(path),
                                    )
                                    PersonalKnowledgeGraph.syncFromCurrentIndex(applicationContext)
                                }.onFailure { error ->
                                    Log.e(DocumentIndexWorker.LOG_TAG,
                                        "Could not immediately remove imported index data", error)
                                }
                                DocumentIndexer.clearCachesAfterImportChange()
                                getPrefs().edit()
                                    .putLong("document_index_revision", System.currentTimeMillis())
                                    .apply()
                                runCatching { startDocumentIndexing(forceRecovery = true) }
                            }
                            runOnUiThread { result.success(removed) }
                        }
                    }
                }

                "speakVoicePrompt" -> {
                    val text = call.argument<String>("text").orEmpty()
                    speakVoicePrompt(text, result)
                }

                "stopVoicePrompt" -> {
                    stopVoicePrompt()
                    result.success(true)
                }

                "requestContactsPermission" -> {
                    if (checkSelfPermission(Manifest.permission.READ_CONTACTS) ==
                        PackageManager.PERMISSION_GRANTED
                    ) {
                        result.success(true)
                    } else {
                        pendingContactsPermissionResult = result
                        requestPermissions(
                            arrayOf(Manifest.permission.READ_CONTACTS),
                            CONTACTS_PERMISSION_REQUEST
                        )
                    }
                }

                "getContacts" -> {
                    var returned = false
                    if (cachedContacts != null) {
                        result.success(cachedContacts)
                        returned = true
                    } else {
                        val persistent = loadFromCache("contacts")
                        if (persistent != null) {
                            cachedContacts = persistent
                            result.success(persistent)
                            returned = true
                        }
                    }

                    val resultWrapper = result // Capture for use in background
                    val finalReturned = returned

                    metadataExecutor.execute {
                        if (checkSelfPermission(Manifest.permission.READ_CONTACTS) !=
                            PackageManager.PERMISSION_GRANTED
                        ) {
                            if (!finalReturned) {
                                runOnUiThread { resultWrapper.success(emptyList<Map<String, String>>()) }
                            }
                            return@execute
                        }

                        val contacts = mutableListOf<Map<String, String>>()
                        val projection = arrayOf(
                            ContactsContract.CommonDataKinds.Phone.DISPLAY_NAME,
                            ContactsContract.CommonDataKinds.Phone.NUMBER,
                            ContactsContract.CommonDataKinds.Phone.NORMALIZED_NUMBER
                        )

                        try {
                            contentResolver.query(
                                ContactsContract.CommonDataKinds.Phone.CONTENT_URI,
                                projection,
                                null,
                                null,
                                "${ContactsContract.CommonDataKinds.Phone.DISPLAY_NAME} ASC"
                            )?.use { cursor ->
                                val nameColumn = cursor.getColumnIndexOrThrow(
                                    ContactsContract.CommonDataKinds.Phone.DISPLAY_NAME
                                )
                                val phoneColumn = cursor.getColumnIndexOrThrow(
                                    ContactsContract.CommonDataKinds.Phone.NUMBER
                                )
                                val normalizedPhoneColumn = cursor.getColumnIndex(
                                    ContactsContract.CommonDataKinds.Phone.NORMALIZED_NUMBER
                                )
                                val seen = mutableSetOf<String>()

                                while (cursor.moveToNext()) {
                                    val name = cursor.getString(nameColumn) ?: continue
                                    val rawPhone = cursor.getString(phoneColumn) ?: continue
                                    val normalizedPhone = if (normalizedPhoneColumn >= 0) {
                                        cursor.getString(normalizedPhoneColumn)
                                    } else {
                                        null
                                    }
                                    val phone = normalizedPhone ?: rawPhone
                                    val key = "$name|$phone"

                                    if (seen.add(key)) {
                                        contacts.add(
                                            mapOf(
                                                "name" to name,
                                                "phone" to phone
                                            )
                                        )
                                    }
                                }
                            }
                            runOnUiThread { 
                                cachedContacts = contacts
                                if (!finalReturned) {
                                    resultWrapper.success(contacts)
                                } else {
                                    // If data changed, we could signal Flutter here via another channel
                                    // For now, we just update the cache for next time
                                }
                            }
                        } catch (e: Exception) {
                            if (!finalReturned) {
                                runOnUiThread { resultWrapper.success(contacts) }
                            }
                        }
                    }
                }

                "getApps" -> {
                    val resultWrapper = result
                    val pm = packageManager

                    metadataExecutor.execute {
                        val apps = mutableListOf<Map<String, String>>()
                        val intent = Intent(Intent.ACTION_MAIN, null)
                        intent.addCategory(Intent.CATEGORY_LAUNCHER)

                        val resolvedApps = pm.queryIntentActivities(intent, 0)

                        for (app in resolvedApps) {
                            val appName = app.loadLabel(pm).toString()
                            val packageName = app.activityInfo.packageName
                            apps.add(
                                mapOf(
                                    "name" to appName,
                                    "package" to packageName,
                                    // Return searchable metadata immediately.
                                    // Flutter already has a fallback app icon.
                                    "icon" to ""
                                )
                            )
                        }
                        runOnUiThread { 
                            cachedApps = apps
                            // Keep the startup cache small. Icons are rebuilt in
                            // memory for the current device when apps are loaded.
                            saveToCache("apps", apps.map {
                                mapOf(
                                    "name" to (it["name"] ?: ""),
                                    "package" to (it["package"] ?: "")
                                )
                            })
                            resultWrapper.success(apps)
                        }
                    }
                }

                "getAppIcon" -> {
                    val packageName = call.argument<String>("package")?.trim().orEmpty()
                    if (packageName.isEmpty()) {
                        result.success("")
                    } else {
                        metadataExecutor.execute {
                            val icon = try {
                                appIconBase64(packageManager.getApplicationIcon(packageName))
                            } catch (_: Exception) {
                                ""
                            }
                            runOnUiThread { result.success(icon) }
                        }
                    }
                }

                "getDocumentPreview" -> {
                    val path = call.argument<String>("path")?.trim().orEmpty()
                    val mimeType = call.argument<String>("mimeType")?.trim().orEmpty()
                    if (path.isEmpty()) {
                        result.success("")
                    } else {
                        metadataExecutor.execute {
                            val preview = documentPreviewBase64(path, mimeType, call.argument<String>("name").orEmpty())
                            runOnUiThread { result.success(preview) }
                        }
                    }
                }

                "getInitialData" -> {
                    val data = mutableMapOf<String, Any>()
                    
                    // This method is called while the first Flutter screen is
                    // being built. Keep it strictly tiny: loading the cached
                    // app list can deserialize many base64 icons and used to
                    // block the Android UI thread on a cold start.
                    data["history"] = getPrefs().getString("search_history", "[]") ?: "[]"
                    data["apps"] = emptyList<Map<String, String>>()
                    data["contacts"] = emptyList<Map<String, String>>()
                    
                    result.success(data)
                }

                "openApp" -> {

                    val packageName =
                        call.argument<String>("package")

                    if (packageName != null) {

                        val intent =
                            packageManager
                                .getLaunchIntentForPackage(packageName)

                        if (intent != null) {

                            startActivity(intent)

                            result.success(true)

                        } else {

                            result.error(
                                "UNAVAILABLE",
                                "App not found",
                                null
                            )
                        }
                    }
                }

                "searchInApp" -> {
                    val packageName = call.argument<String>("package")
                    val query = call.argument<String>("query")?.trim().orEmpty()
                    if (packageName.isNullOrEmpty() || query.isEmpty()) {
                        result.error("INVALID_REQUEST", "An app and search query are required", null)
                    } else if (!AppSearchAccessibilityService.requestSearch(packageName, query)) {
                        result.error(
                            "ACCESSIBILITY_DISABLED",
                            "App automation is not enabled",
                            null,
                        )
                    } else {
                        val intent = packageManager.getLaunchIntentForPackage(packageName)
                        if (intent == null) {
                            result.error("UNAVAILABLE", "App not found", null)
                        } else {
                            startActivity(intent)
                            result.success(true)
                        }
                    }
                }

                "openAccessibilitySettings" -> {
                    try {
                        startActivity(Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS))
                        result.success(true)
                    } catch (_: Exception) {
                        result.error("UNAVAILABLE", "Could not open accessibility settings", null)
                    }
                }

                "getDocuments" -> {
                    metadataExecutor.execute {
                        val documents = documentRows()
                        runOnUiThread { result.success(documents) }
                    }
                }

                "getChatContext" -> {
                    val query = call.argument<String>("query")?.trim().orEmpty()
                    searchExecutor.execute {
                        try {
                            val sources = ChatContextSearch.search(applicationContext, query)
                            runOnUiThread { result.success(sources) }
                        } catch (_: Exception) {
                            runOnUiThread {
                                result.error("CHAT_CONTEXT_UNAVAILABLE", "Could not read indexed context", null)
                            }
                        }
                    }
                }

                "searchDocuments" -> {
                    val query = call.argument<String>("query")?.trim().orEmpty()
                    // The initial request uses the exact FTS/graph snapshot;
                    // semantic enrichment is requested separately after those
                    // usable results are already on screen.
                    val includeSemantic = call.argument<Boolean>("includeSemantic") ?: true
                    val requestId = call.argument<Number>("requestId")?.toLong()
                        ?: latestSearchRequestId.incrementAndGet()
                    activateSearchRequest(requestId)
                    if (query.isEmpty()) {
                        result.success(emptyList<Map<String, String>>())
                    } else {
                        val enqueuedAt = SystemClock.elapsedRealtime()
                        searchExecutor.execute {
                            try {
                                val queueMs = SystemClock.elapsedRealtime() - enqueuedAt
                                val shouldContinue = {
                                    latestSearchRequestId.get() == requestId &&
                                        !Thread.currentThread().isInterrupted
                                }
                                if (!shouldContinue()) {
                                    runOnUiThread { result.success(emptyList<Map<String, String>>()) }
                                    return@execute
                                }
                                val matches = DocumentIndexer.search(
                                    applicationContext,
                                    query,
                                    includeSemantic,
                                    requestId,
                                    shouldContinue,
                                )
                                Log.i(
                                    DocumentIndexWorker.LOG_TAG,
                                    "search request=$requestId semantic=$includeSemantic queueMs=$queueMs " +
                                        "cancelled=${!shouldContinue()} results=${matches.size}"
                                )
                                runOnUiThread {
                                    result.success(if (shouldContinue()) matches else emptyList())
                                }
                            } catch (error: Exception) {
                                Log.e(DocumentIndexWorker.LOG_TAG, "Search request $requestId failed", error)
                                runOnUiThread {
                                    result.error("SEARCH_UNAVAILABLE", "Could not search the local file index", null)
                                }
                            }
                        }
                    }
                }

                "cancelDocumentSearch" -> {
                    val requestId = call.argument<Number>("requestId")?.toLong()
                        ?: latestSearchRequestId.incrementAndGet()
                    activateSearchRequest(requestId)
                    result.success(true)
                }

                "getKnowledgeStatus" -> {
                    maintenanceExecutor.execute {
                        val status = try {
                            PersonalKnowledgeGraph.status(applicationContext)
                        } catch (_: Exception) {
                            emptyMap<String, Any>()
                        }
                        runOnUiThread { result.success(status) }
                    }
                }

                "getDocumentFolders" -> {
                    metadataExecutor.execute {
                        val folders = documentRows(includeExcluded = true)
                            .mapNotNull { it["folder"] }
                            .filter { it.isNotBlank() }.distinct().sorted()
                        runOnUiThread { result.success(folders) }
                    }
                }

                "getExcludedFolders" -> {
                    result.success(
                        getPrefs().getStringSet("excluded_document_folders", emptySet())
                            ?.sorted() ?: emptyList<String>()
                    )
                }

                "setFolderExcluded" -> {
                    val folder = call.argument<String>("folder")?.trim().orEmpty()
                    val excluded = call.argument<Boolean>("excluded") == true
                    if (folder.isEmpty()) {
                        result.error("INVALID", "A folder is required.", null)
                    } else {
                        val folders = getPrefs()
                            .getStringSet("excluded_document_folders", emptySet())
                            ?.toMutableSet() ?: mutableSetOf()
                        if (excluded) folders.add(folder) else folders.remove(folder)
                        getPrefs().edit()
                            .putStringSet("excluded_document_folders", folders)
                            .putBoolean("document_index_complete", false)
                            .putString("document_index_state", "queued")
                            .apply()
                        startDocumentIndexing(forceRecovery = true)
                        result.success(true)
                    }
                }

                "recordKnowledgeUsage" -> {
                    val kind = call.argument<String>("kind").orEmpty()
                    val target = call.argument<String>("target").orEmpty()
                    val title = call.argument<String>("title").orEmpty()
                    maintenanceExecutor.execute {
                        runCatching {
                            PersonalKnowledgeGraph.recordUsage(
                                applicationContext, kind, target, title
                            )
                        }
                    }
                    result.success(true)
                }

                "clearKnowledgeIndex" -> {
                    maintenanceExecutor.execute {
                        try {
                            // deleteDatabase returns false when an existing DB
                            // could not be deleted; an absent DB is already reset.
                            val databaseExisted = applicationContext
                                .getDatabasePath("personal_knowledge.db").exists()
                            val cleared = !databaseExisted ||
                                PersonalKnowledgeGraph.clear(applicationContext)
                            runOnUiThread { result.success(cleared) }
                        } catch (error: Exception) {
                            Log.e(DocumentIndexWorker.LOG_TAG, "Could not reset knowledge graph", error)
                            runOnUiThread { result.success(false) }
                        }
                    }
                }

                "getDocumentIndex" -> {
                    metadataExecutor.execute {
                        val index = loadDocumentIndex()
                        runOnUiThread { result.success(index) }
                    }
                }

                "getCloudSyncRows" -> {
                    val paths = call.argument<List<String>>("paths").orEmpty().toSet()
                    metadataExecutor.execute {
                        val rows = DocumentIndexDatabase.syncRows(applicationContext, paths)
                        runOnUiThread { result.success(rows) }
                    }
                }

                "getCloudGraphRows" -> {
                    val paths = call.argument<List<String>>("paths").orEmpty().toSet()
                    metadataExecutor.execute {
                        val rows = PersonalKnowledgeGraph.exportRelations(
                            applicationContext, paths
                        )
                        runOnUiThread { result.success(rows) }
                    }
                }

                "getCloudSyncConditions" -> {
                    val connectivity = getSystemService(ConnectivityManager::class.java)
                    val network = connectivity.activeNetwork
                    val capabilities = network?.let { connectivity.getNetworkCapabilities(it) }
                    val battery = getSystemService(BatteryManager::class.java)
                    val power = getSystemService(PowerManager::class.java)
                    val percent = battery.getIntProperty(BatteryManager.BATTERY_PROPERTY_CAPACITY)
                    val charging = battery.isCharging
                    result.success(mapOf(
                        "connected" to (capabilities?.hasCapability(
                            NetworkCapabilities.NET_CAPABILITY_INTERNET
                        ) == true),
                        "wifi" to (capabilities?.hasTransport(
                            NetworkCapabilities.TRANSPORT_WIFI
                        ) == true),
                        "charging" to charging,
                        "lowBattery" to (!charging && percent in 0..14),
                        "dataSaver" to (connectivity.restrictBackgroundStatus ==
                            ConnectivityManager.RESTRICT_BACKGROUND_STATUS_ENABLED),
                        "poorNetwork" to (capabilities?.hasCapability(
                            NetworkCapabilities.NET_CAPABILITY_NOT_CONGESTED
                        ) == false),
                        "powerSave" to power.isPowerSaveMode,
                    ))
                }

                "getDocumentStorageBreakdown" -> {
                    metadataExecutor.execute {
                        val values = DocumentIndexDatabase.storageBreakdown(applicationContext)
                            .toMutableMap()
                        values["knowledgeGraphBytes"] =
                            applicationContext.getDatabasePath("personal_knowledge.db").length()
                        values["previewCacheBytes"] = applicationContext.cacheDir
                            .walkTopDown().filter { it.isFile }.sumOf { it.length() }
                        runOnUiThread { result.success(values) }
                    }
                }

                "deleteLocalDocumentIndex" -> {
                    maintenanceExecutor.execute {
                        try {
                            WorkManager.getInstance(applicationContext)
                                .cancelUniqueWork(DocumentIndexWorker.UNIQUE_WORK_NAME)
                            DocumentIndexDatabase.clear(applicationContext)
                            PersonalKnowledgeGraph.clear(applicationContext)
                            getPrefs().edit()
                                .putInt("document_index_cursor", 0)
                                .putInt("document_index_total", 0)
                                .putBoolean("document_index_complete", false)
                                .putString("document_index_state", "idle")
                                .putString("document_index_current_file", "")
                                .putString("document_index_last_error", "")
                                .putLong("document_index_revision", System.currentTimeMillis())
                                .apply()
                            runOnUiThread { result.success(true) }
                        } catch (error: Exception) {
                            Log.e(DocumentIndexWorker.LOG_TAG, "Could not delete local index", error)
                            runOnUiThread { result.success(false) }
                        }
                    }
                }

                "removeVerifiedLocalCloudIndex" -> {
                    val paths = call.argument<List<String>>("paths").orEmpty().toSet()
                    maintenanceExecutor.execute {
                        try {
                            DocumentIndexDatabase.removeGeneratedDataFor(
                                applicationContext, paths
                            )
                            PersonalKnowledgeGraph.syncFromCurrentIndex(applicationContext)
                            getPrefs().edit()
                                .putLong("document_index_revision", System.currentTimeMillis())
                                .apply()
                            runOnUiThread { result.success(true) }
                        } catch (error: Exception) {
                            Log.e(DocumentIndexWorker.LOG_TAG,
                                "Could not release verified local cloud data", error)
                            runOnUiThread { result.success(false) }
                        }
                    }
                }

                "prepareSemanticSearchStorage" -> {
                    if (semanticStoragePreparationStarted.compareAndSet(false, true)) {
                        maintenanceExecutor.execute {
                            val startedAt = SystemClock.elapsedRealtime()
                            val preferences = getPrefs()
                            val updated = if (preferences.getBoolean(
                                    "semantic_blob_storage_ready_v1", false
                                )) {
                                0
                            } else {
                                DocumentIndexDatabase.backfillEmbeddingBlobs(
                                    applicationContext,
                                ) { !Thread.currentThread().isInterrupted }.also {
                                    if (!Thread.currentThread().isInterrupted) {
                                        preferences.edit().putBoolean(
                                            "semantic_blob_storage_ready_v1", true
                                        ).apply()
                                    }
                                }
                            }
                            val storageMs = SystemClock.elapsedRealtime() - startedAt
                            val corpusStartedAt = SystemClock.elapsedRealtime()
                            val prepared = LocalSemanticSearch.prepare(
                                applicationContext,
                            ) { !Thread.currentThread().isInterrupted }
                            Log.i(
                                DocumentIndexWorker.LOG_TAG,
                                "semantic-storage updated=$updated prepared=$prepared " +
                                    "storageMs=$storageMs corpusMs=" +
                                    "${SystemClock.elapsedRealtime() - corpusStartedAt}"
                            )
                        }
                    }
                    result.success(true)
                }

                "getDocumentIndexStatus" -> {
                    val preferences = getPrefs()
                    val schedule = documentIndexSchedule(applicationContext)
                    result.success(mapOf(
                        "indexed" to preferences.getInt("document_index_cursor", 0),
                        "total" to preferences.getInt("document_index_total", 0),
                        "complete" to preferences.getBoolean("document_index_complete", false),
                        "revision" to preferences.getLong("document_index_revision", 0L),
                        "lastScan" to preferences.getLong("document_index_last_scan", 0L),
                        "lastProgressAt" to preferences.getLong("document_index_last_progress_at", 0L),
                        "state" to preferences.getString("document_index_state", "idle"),
                        "currentFile" to preferences.getString("document_index_current_file", ""),
                        "lastError" to preferences.getString("document_index_last_error", ""),
                        "scheduleStartMinute" to schedule.startMinute,
                        "scheduleEndMinute" to schedule.endMinute,
                    ))
                }

                "getDocumentIndexSchedule" -> {
                    val schedule = documentIndexSchedule(applicationContext)
                    result.success(mapOf(
                        "startMinute" to schedule.startMinute,
                        "endMinute" to schedule.endMinute,
                    ))
                }

                "setDocumentIndexSchedule" -> {
                    val startMinute = call.argument<Int>("startMinute")
                    val endMinute = call.argument<Int>("endMinute")
                    if (startMinute == null || endMinute == null ||
                        !isValidDocumentIndexSchedule(startMinute, endMinute)) {
                        result.error(
                            "INVALID",
                            "Choose different start and end times within one day.",
                            null,
                        )
                        return@setMethodCallHandler
                    }
                    getPrefs().edit()
                        .putInt(DOCUMENT_INDEX_WINDOW_START_KEY, startMinute)
                        .putInt(DOCUMENT_INDEX_WINDOW_END_KEY, endMinute)
                        .putString("document_index_state", "queued")
                        .apply()
                    WorkManager.getInstance(applicationContext).cancelUniqueWork(
                        DocumentIndexWorker.UNIQUE_WORK_NAME
                    )
                    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R ||
                        Environment.isExternalStorageManager()) {
                        // The work delay is only a hint. The worker re-checks
                        // this persisted window before reading a heavy file.
                        startDocumentIndexing(forceRecovery = true)
                    }
                    result.success(true)
                }

                "getDocumentIndexMode" -> {
                    result.success(documentIndexMode(applicationContext))
                }

                "setDocumentIndexMode" -> {
                    val mode = call.argument<String>("mode")
                    if (mode !in setOf(
                            INDEX_MODE_ULTRA_FAST,
                            INDEX_MODE_FAST,
                            INDEX_MODE_BALANCED,
                            INDEX_MODE_SLOW,
                        )) {
                        result.error("INVALID", "Unknown indexing mode.", null)
                        return@setMethodCallHandler
                    }
                    getPrefs().edit()
                        .putString("document_index_mode", mode)
                        .putString("document_index_state", "queued")
                        .apply()
                    WorkManager.getInstance(applicationContext).cancelUniqueWork(
                        DocumentIndexWorker.UNIQUE_WORK_NAME
                    )
                    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R ||
                        Environment.isExternalStorageManager()) {
                        startDocumentIndexing(forceRecovery = true)
                    }
                    result.success(true)
                }

                "setDocumentIndexPaused" -> {
                    val paused = call.argument<Boolean>("paused") == true
                    val preferences = getPrefs()
                    preferences.edit()
                        .putBoolean("document_index_paused_for_search", paused)
                        .putString(
                            "document_index_state",
                            if (paused) "paused_for_search" else "queued"
                        )
                        .putString("document_index_current_file", "")
                        .apply()
                    if (paused) {
                        WorkManager.getInstance(applicationContext).cancelUniqueWork(
                            DocumentIndexWorker.UNIQUE_WORK_NAME
                        )
                    } else if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R ||
                        Environment.isExternalStorageManager()) {
                        // Resume only when the existing permission is present;
                        // typing in search must never trigger a permission prompt.
                        startDocumentIndexing()
                    }
                    result.success(true)
                }

                "getTextEmbedding" -> {
                    val text = call.argument<String>("text")?.trim().orEmpty()
                    if (text.isEmpty()) {
                        result.success("")
                    } else {
                        searchExecutor.execute {
                            val embedding = DocumentIndexer.embedText(applicationContext, text)
                            runOnUiThread { result.success(embedding) }
                        }
                    }
                }

                "startDocumentIndexing" -> {
                    val forceRecovery =
                        call.argument<Boolean>("forceRecovery") == true
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R &&
                        !Environment.isExternalStorageManager()) {
                        result.error(
                            "FILES_PERMISSION_REQUIRED",
                            "Enable All files access to index the whole phone.",
                            null
                        )
                        return@setMethodCallHandler
                    }
                    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R &&
                        checkSelfPermission(Manifest.permission.READ_EXTERNAL_STORAGE) !=
                        PackageManager.PERMISSION_GRANTED) {
                        pendingFilesIndexResult = result
                        pendingIndexForceRecovery = forceRecovery
                        pendingIndexRestart = false
                        requestPermissions(
                            arrayOf(Manifest.permission.READ_EXTERNAL_STORAGE),
                            FILES_PERMISSION_REQUEST
                        )
                        return@setMethodCallHandler
                    }
                    startIndexAfterNotificationPermission(forceRecovery, result)
                }

                "restartDocumentIndexing" -> {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R &&
                        !Environment.isExternalStorageManager()) {
                        result.error(
                            "FILES_PERMISSION_REQUIRED",
                            "Enable All files access to index the whole phone.",
                            null,
                        )
                        return@setMethodCallHandler
                    }
                    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R &&
                        checkSelfPermission(Manifest.permission.READ_EXTERNAL_STORAGE) !=
                        PackageManager.PERMISSION_GRANTED) {
                        pendingFilesIndexResult = result
                        pendingIndexRestart = true
                        requestPermissions(
                            arrayOf(Manifest.permission.READ_EXTERNAL_STORAGE),
                            FILES_PERMISSION_REQUEST,
                        )
                        return@setMethodCallHandler
                    }
                    restartDocumentIndexing(result)
                }

                "requestAllFilesAccess" -> {
                    val forceRecovery =
                        call.argument<Boolean>("forceRecovery") == true
                    val restart = call.argument<Boolean>("restart") == true
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R &&
                        !Environment.isExternalStorageManager()) {
                        try {
                            awaitingAllFilesAccess = true
                            awaitingAllFilesForceRecovery = forceRecovery
                            awaitingAllFilesRestart = restart
                            startActivity(Intent(
                                Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION,
                                Uri.parse("package:$packageName")
                            ))
                            result.success(true)
                        } catch (_: Exception) {
                            result.error("UNAVAILABLE", "Could not open file access settings", null)
                        }
                    } else if (restart) {
                        restartDocumentIndexing(result)
                    } else {
                        result.success(true)
                    }
                }

                "openDocument" -> {
                    val path = call.argument<String>("path")
                    val name = call.argument<String>("name").orEmpty()
                    val suppliedMimeType = call.argument<String>("mimeType").orEmpty()

                    if (path.isNullOrEmpty()) {
                        result.error("INVALID", "Missing document path", null)
                        return@setMethodCallHandler
                    }
                    if (Uri.parse(path).scheme != "content") {
                        result.error("INVALID", "Only content document URIs are allowed", null)
                        return@setMethodCallHandler
                    }

                    try {
                        val uri = Uri.parse(path)
                        val expectedSize = call.argument<Number>("expectedFileSize")?.toLong()
                        val expectedModified = call.argument<Number>("expectedModifiedSeconds")?.toLong()
                        val projection = arrayOf(
                            MediaStore.Files.FileColumns.SIZE,
                            MediaStore.Files.FileColumns.DATE_MODIFIED,
                        )
                        val imported = ImportedDocumentStore.metadataForUri(applicationContext, uri)
                        if (uri.authority == "$packageName.imported_documents" && imported == null) {
                            result.error("MISSING", "Imported file is unavailable", null)
                            return@setMethodCallHandler
                        }
                        if (imported != null) {
                            val actualSize = imported["size"]?.toLongOrNull() ?: 0L
                            val actualModified = imported["modified"]?.toLongOrNull() ?: 0L
                            if ((expectedSize != null && expectedSize > 0 && actualSize != expectedSize) ||
                                (expectedModified != null && expectedModified > 0 && actualModified != expectedModified)) {
                                result.error("STALE", "Original file changed after indexing", null)
                                return@setMethodCallHandler
                            }
                        } else {
                            contentResolver.query(uri, projection, null, null, null)?.use { cursor ->
                                if (!cursor.moveToFirst()) {
                                    result.error("MISSING", "Original file is unavailable", null)
                                    return@setMethodCallHandler
                                }
                                val actualSize = cursor.getLong(0)
                                val actualModified = cursor.getLong(1)
                                if ((expectedSize != null && expectedSize > 0 && actualSize != expectedSize) ||
                                    (expectedModified != null && expectedModified > 0 && actualModified != expectedModified)) {
                                    result.error("STALE", "Original file changed after indexing", null)
                                    return@setMethodCallHandler
                                }
                            }
                        }
                        val providerMimeType = contentResolver.getType(uri)
                        val mimeType = when {
                            suppliedMimeType.isNotBlank() &&
                                suppliedMimeType != "application/octet-stream" -> suppliedMimeType
                            !providerMimeType.isNullOrBlank() &&
                                providerMimeType != "*/*" &&
                                providerMimeType != "application/octet-stream" -> providerMimeType
                            else -> resolvedMimeType(name, suppliedMimeType)
                        }
                        val intent = Intent(Intent.ACTION_VIEW).apply {
                            setDataAndType(uri, mimeType)
                            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                        }
                        val handlers = packageManager.queryIntentActivities(
                            intent,
                            PackageManager.MATCH_DEFAULT_ONLY,
                        )
                        if (handlers.isEmpty()) {
                            result.error(
                                "NO_COMPATIBLE_APP",
                                "No installed app can open $mimeType",
                                mapOf("mimeType" to mimeType),
                            )
                            return@setMethodCallHandler
                        }
                        startActivity(Intent.createChooser(intent, "Open document"))
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("UNAVAILABLE", "No app can open this document", null)
                    }
                }

                "makeDirectCall" -> {
                    val phone = call.argument<String>("phone")
                    if (phone.isNullOrEmpty()) {
                        result.error("INVALID", "Missing phone number", null)
                        return@setMethodCallHandler
                    }

                    if (checkSelfPermission(Manifest.permission.CALL_PHONE) ==
                        PackageManager.PERMISSION_GRANTED
                    ) {
                        startDirectCall(phone, result)
                    } else {
                        pendingCallPhone = phone
                        pendingCallResult = result
                        requestPermissions(
                            arrayOf(Manifest.permission.CALL_PHONE),
                            CALL_PHONE_PERMISSION_REQUEST
                        )
                    }
                }

                "getCallUsage" -> {
                    val requestPermission =
                        call.argument<Boolean>("requestPermission") == true
                    if (checkSelfPermission(Manifest.permission.READ_CALL_LOG) ==
                        PackageManager.PERMISSION_GRANTED) {
                        returnCallUsage(result)
                    } else if (requestPermission) {
                        pendingCallUsageResult = result
                        requestPermissions(
                            arrayOf(Manifest.permission.READ_CALL_LOG),
                            CALL_LOG_PERMISSION_REQUEST
                        )
                    } else {
                        result.success(emptyList<Map<String, String>>())
                    }
                }

                "getHistory" -> {
                    val json = getPrefs().getString("search_history", "[]")
                    // If we find old string-based history, clear it to prevent crashes
                    if (json != "[]" && !json!!.contains("\"kind\":")) {
                        getPrefs().edit().putString("search_history", "[]").apply()
                        result.success("[]")
                    } else {
                        result.success(json)
                    }
                }

                "addToHistory" -> {
                    val query = call.argument<String>("query")
                    val kind = call.argument<String>("kind")
                    val title = call.argument<String>("title")
                    val subtitle = call.argument<String>("subtitle")
                    val extra = call.argument<String>("extra")
                    val icon = call.argument<String>("icon")
                    val timestamp = call.argument<String>("timestamp")

                    if (title.isNullOrEmpty()) {
                        result.success(false)
                        return@setMethodCallHandler
                    }

                    val json = getPrefs().getString("search_history", "[]")
                    try {
                        val oldArray = JSONArray(json)
                        val list = mutableListOf<JSONObject>()
                        
                        var updatedItem: JSONObject? = null
                        for (i in 0 until oldArray.length()) {
                            val item = oldArray.optJSONObject(i) ?: continue
                            if (item.optString("title") == title && item.optString("kind") == kind) {
                                val count = item.optInt("usageCount", 0) + 1
                                item.put("usageCount", count)
                                item.put("query", query ?: "")
                                item.put("subtitle", subtitle ?: "")
                                item.put("extra", extra ?: "")
                                if (!icon.isNullOrEmpty()) item.put("icon", icon)
                                item.put("timestamp", timestamp ?: "")
                                updatedItem = item
                            } else {
                                list.add(item)
                            }
                        }
                        
                        if (updatedItem != null) {
                            // A repeated action is the most recent history item.
                            list.add(0, updatedItem)
                        } else {
                            val newItem = JSONObject()
                            newItem.put("query", query ?: "")
                            newItem.put("kind", kind ?: "")
                            newItem.put("title", title ?: "")
                            newItem.put("subtitle", subtitle ?: "")
                            newItem.put("extra", extra ?: "")
                            newItem.put("icon", icon ?: "")
                            newItem.put("usageCount", 1)
                            newItem.put("timestamp", timestamp ?: "")
                            list.add(0, newItem)
                        }
                        
                        val newArray = JSONArray()
                        // Keep top 100 items for long history
                        for (i in 0 until list.take(100).size) {
                            newArray.put(list[i])
                        }
                        
                        getPrefs().edit().putString("search_history", newArray.toString()).apply()
                        result.success(true)
                    } catch (e: Exception) {
                        getPrefs().edit().putString("search_history", "[]").apply()
                        result.success(false)
                    }
                }

                "removeFromHistory" -> {
                    val title = call.argument<String>("title")
                    val kind = call.argument<String>("kind")
                    val json = getPrefs().getString("search_history", "[]")
                    try {
                        val oldArray = JSONArray(json)
                        val newArray = JSONArray()
                        for (i in 0 until oldArray.length()) {
                            val item = oldArray.optJSONObject(i) ?: continue
                            if (item.optString("title") != title || item.optString("kind") != kind) {
                                newArray.put(item)
                            }
                        }
                        getPrefs().edit().putString("search_history", newArray.toString()).apply()
                        result.success(true)
                    } catch (e: Exception) {
                        result.success(false)
                    }
                }


                "openWhatsApp" -> {
                    val phone = call.argument<String>("phone")
                    val message = call.argument<String>("message")?.take(2000).orEmpty()
                    if (phone.isNullOrEmpty()) {
                        result.error("INVALID", "Missing phone number", null)
                        return@setMethodCallHandler
                    }

                    // 1. Clean the number: Keep only digits
                    var cleanNumber = ""
                    for (char in phone) {
                        if (char in '0'..'9') cleanNumber += char
                    }
                    
                    // 2. Add India country code (91) if it's a 10-digit number
                    if (cleanNumber.length == 10) {
                        val firstChar = cleanNumber[0]
                        if (firstChar == '7' || firstChar == '8' || firstChar == '9' || firstChar == '6') {
                            cleanNumber = "91$cleanNumber"
                        }
                    }

                    val packages = arrayOf("com.whatsapp", "com.whatsapp.w4b")
                    var launched = false

                    for (pkg in packages) {
                        if (!isAppInstalled(pkg)) continue

                        try {
                            // Method 1: smsto: scheme (Very effective at bypassing search dialog)
                            val uri = Uri.parse("smsto:$cleanNumber")
                            val intent = Intent(Intent.ACTION_SENDTO, uri)
                            intent.setPackage(pkg)
                            intent.putExtra("chat", true)
                            if (message.isNotEmpty()) intent.putExtra(Intent.EXTRA_TEXT, message)
                            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            
                            startActivity(intent)
                            launched = true
                            break
                        } catch (e: Exception) {
                            // Method 2: JID Direct
                            try {
                                val jidIntent = Intent(Intent.ACTION_SEND)
                                jidIntent.setPackage(pkg)
                                jidIntent.type = "text/plain"
                                jidIntent.putExtra("jid", "$cleanNumber@s.whatsapp.net")
                                jidIntent.putExtra(Intent.EXTRA_TEXT, message)
                                jidIntent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                                startActivity(jidIntent)
                                launched = true
                                break
                            } catch (e2: Exception) {
                                // Method 3: API URI
                                try {
                                    val apiIntent = Intent(Intent.ACTION_VIEW)
                                    apiIntent.setPackage(pkg)
                                    apiIntent.data = Uri.parse(
                                        "https://api.whatsapp.com/send?phone=$cleanNumber" +
                                            if (message.isEmpty()) "" else "&text=${Uri.encode(message)}"
                                    )
                                    apiIntent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                                    startActivity(apiIntent)
                                    launched = true
                                    break
                                } catch (e3: Exception) {}
                            }
                        }
                    }

                    if (launched) {
                        result.success(true)
                    } else {
                        result.error("UNAVAILABLE", "WhatsApp is not installed", null)
                    }
                }

                "playMusic" -> {
                    val query = call.argument<String>("query")?.trim()
                    val provider = call.argument<String>("provider")
                    if (query.isNullOrEmpty() || provider.isNullOrEmpty()) {
                        result.error("INVALID", "Missing song or music provider", null)
                        return@setMethodCallHandler
                    }
                    val packageName = when (provider) {
                        "spotify" -> "com.spotify.music"
                        "apple_music" -> "com.apple.android.music"
                        else -> null
                    }
                    if (packageName == null || !isAppInstalled(packageName)) {
                        result.error("UNAVAILABLE", "The selected music app is not installed", null)
                        return@setMethodCallHandler
                    }
                    try {
                        val playIntent = Intent(MediaStore.INTENT_ACTION_MEDIA_PLAY_FROM_SEARCH).apply {
                            setPackage(packageName)
                            putExtra(SearchManager.QUERY, query)
                            putExtra(MediaStore.EXTRA_MEDIA_FOCUS, MediaStore.Audio.Media.ENTRY_CONTENT_TYPE)
                        }
                        startActivity(playIntent)
                        result.success(true)
                    } catch (e: Exception) {
                        try {
                            val uri = if (provider == "spotify") {
                                Uri.parse("spotify:search:${Uri.encode(query)}")
                            } else {
                                Uri.parse("https://music.apple.com/us/search?term=${Uri.encode(query)}")
                            }
                            startActivity(Intent(Intent.ACTION_VIEW, uri).setPackage(packageName))
                            result.success(true)
                        } catch (fallbackError: Exception) {
                            result.error("UNAVAILABLE", "Could not open the selected music app", null)
                        }
                    }
                }

                else -> result.notImplemented()
            }
        }
    }

    override fun onDestroy() {
        activateSearchRequest(latestSearchRequestId.incrementAndGet())
        searchExecutor.shutdownNow()
        metadataExecutor.shutdownNow()
        maintenanceExecutor.shutdownNow()
        stopVoicePrompt()
        voiceTts?.shutdown()
        voiceTts = null
        voiceTtsReady = false
        super.onDestroy()
    }

    private fun drawableToBase64(drawable: Drawable): String {
        val bitmap = if (drawable is BitmapDrawable) {
            drawable.bitmap
        } else {
            val bmp = Bitmap.createBitmap(
                drawable.intrinsicWidth.coerceAtLeast(1),
                drawable.intrinsicHeight.coerceAtLeast(1),
                Bitmap.Config.ARGB_8888
            )
            val canvas = Canvas(bmp)
            drawable.setBounds(0, 0, canvas.width, canvas.height)
            drawable.draw(canvas)
            bmp
        }

        val outputStream = ByteArrayOutputStream()
        bitmap.compress(Bitmap.CompressFormat.PNG, 100, outputStream)
        return Base64.encodeToString(outputStream.toByteArray(), Base64.NO_WRAP)
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)

        if (requestCode == CONTACTS_PERMISSION_REQUEST) {
            val allowed = grantResults.isNotEmpty() &&
                grantResults[0] == PackageManager.PERMISSION_GRANTED
            pendingContactsPermissionResult?.success(allowed)
            pendingContactsPermissionResult = null
        }
        if (requestCode == CALL_PHONE_PERMISSION_REQUEST) {
            val allowed = grantResults.isNotEmpty() &&
                grantResults[0] == PackageManager.PERMISSION_GRANTED
            val phone = pendingCallPhone
            val pendingResult = pendingCallResult
            pendingCallPhone = null
            pendingCallResult = null
            if (allowed && phone != null && pendingResult != null) {
                startDirectCall(phone, pendingResult)
            } else {
                pendingResult?.error(
                    "PERMISSION_DENIED",
                    "Phone permission is needed to place calls directly",
                    null
                )
            }
        }
        if (requestCode == NOTIFICATIONS_PERMISSION_REQUEST) {
            // Indexing remains local and works without notifications, but a granted
            // permission lets the user see the requested progress bar.
            startDocumentIndexing(pendingIndexForceRecovery)
            pendingIndexResult?.success(true)
            pendingIndexResult = null
            pendingIndexForceRecovery = false
        }
        if (requestCode == FILES_PERMISSION_REQUEST) {
            val allowed = grantResults.isNotEmpty() &&
                grantResults[0] == PackageManager.PERMISSION_GRANTED
            val pendingResult = pendingFilesIndexResult
            val restart = pendingIndexRestart
            val forceRecovery = pendingIndexForceRecovery
            pendingFilesIndexResult = null
            pendingIndexForceRecovery = false
            pendingIndexRestart = false
            if (allowed) {
                if (restart) {
                    restartDocumentIndexing(pendingResult)
                } else {
                    startDocumentIndexing(forceRecovery)
                    pendingResult?.success(true)
                }
            } else {
                pendingResult?.error(
                    "FILES_PERMISSION_REQUIRED",
                    "File access is needed to index documents on this device.",
                    null
                )
            }
        }
        if (requestCode == CALL_LOG_PERMISSION_REQUEST) {
            val allowed = grantResults.isNotEmpty() &&
                grantResults[0] == PackageManager.PERMISSION_GRANTED
            val pendingResult = pendingCallUsageResult
            pendingCallUsageResult = null
            if (pendingResult != null) {
                if (allowed) returnCallUsage(pendingResult)
                else pendingResult.success(emptyList<Map<String, String>>())
            }
        }
    }
}

/** Persistent, OS-managed indexing with a durable cursor between bounded jobs. */
class DocumentIndexWorker(
    appContext: Context,
    workerParams: WorkerParameters
) : Worker(appContext, workerParams) {
    companion object {
        const val UNIQUE_WORK_NAME = "smart_search_document_index"
        const val WORK_TAG = "smart_search_document_index_batch"
        const val LOG_TAG = "SmartSearchIndex"
        const val INPUT_GENERATION = "document_index_generation"
    }

    override fun doWork(): Result {
        // Storage v2 intentionally discards the generated JSON index and begins
        // with related SQLite file/chunk tables. This worker runs off the UI
        // thread, preserving the app's UI-first startup contract.
        DocumentIndexDatabase.ensureFreshStorage(applicationContext)
        // Older persisted requests have no input value. Generation zero is also
        // the compatible default for their existing index rows.
        val expectedGeneration = inputData.getLong(INPUT_GENERATION, 0L)
        fun isCurrentRun() = isCurrentDocumentIndexGeneration(
            applicationContext,
            expectedGeneration,
        )
        if (!isCurrentRun()) {
            Log.i(LOG_TAG, "Ignoring superseded index work generation=$expectedGeneration")
            return Result.success()
        }
        val settings = documentIndexPreferences(applicationContext)
        if (settings.getBoolean("document_index_paused_for_search", false)) {
            settings.edit()
                .putString("document_index_state", "paused_for_search")
                .putString("document_index_current_file", "")
                .apply()
            return Result.success()
        }
        settings.edit()
            .putString("document_index_state", "running")
            .putLong("document_index_worker_started_at", System.currentTimeMillis())
            .putString("document_index_last_error", "")
            .apply()
        Log.i(LOG_TAG, "Batch started generation=$expectedGeneration attempt=$runAttemptCount")
        return try {
            when (DocumentIndexer.indexOneBatch(applicationContext, expectedGeneration) {
                !isStopped && isCurrentRun()
            }) {
                DocumentIndexer.BatchResult.CONTINUE -> {
                    if (!isCurrentRun()) return Result.success()
                    val nextRunAt = settings.getLong(
                        "document_index_next_run_at",
                        System.currentTimeMillis()
                    )
                    val delayMs = (nextRunAt - System.currentTimeMillis()).coerceAtLeast(0L)
                    val next = newDocumentIndexRequest(
                        applicationContext,
                        delayMs,
                        nextRunAt,
                        expectedGeneration,
                    )
                    if (!isCurrentRun()) return Result.success()
                    WorkManager.getInstance(applicationContext).enqueueUniqueWork(
                        DocumentIndexWorker.UNIQUE_WORK_NAME,
                        ExistingWorkPolicy.APPEND_OR_REPLACE,
                        next
                    )
                    settings.edit()
                        .putString(
                            "document_index_state",
                            if (delayMs > 5_000L) "scheduled" else "queued"
                        )
                        .apply()
                    Log.i(LOG_TAG, "Batch committed; successor queued in ${delayMs}ms")
                    Result.success()
                }
                DocumentIndexer.BatchResult.COMPLETE -> {
                    if (!isCurrentRun()) return Result.success()
                    settings.edit()
                        .putString("document_index_state", "complete")
                        .putString("document_index_current_file", "")
                        .apply()
                    Log.i(LOG_TAG, "Index complete")
                    Result.success()
                }
                DocumentIndexer.BatchResult.NO_ACCESS -> {
                    if (!isCurrentRun()) return Result.success()
                    settings.edit()
                        .putString("document_index_state", "waiting_permission")
                        .putString(
                            "document_index_last_error",
                            "All files access is required to continue indexing."
                        )
                        .apply()
                    Log.w(LOG_TAG, "Index paused: storage access unavailable")
                    Result.failure()
                }
            }
        } catch (error: SecurityException) {
            if (!isCurrentRun()) return Result.success()
            settings.edit()
                .putString("document_index_state", "waiting_permission")
                .putString("document_index_last_error", error.toString())
                .apply()
            Log.e(LOG_TAG, "Index permission failure", error)
            Result.failure()
        } catch (_: IndexingInterruptedException) {
            if (!isCurrentRun()) return Result.success()
            settings.edit()
                .putString("document_index_state", "interrupted")
                .putString("document_index_current_file", "")
                .putString(
                    "document_index_last_error",
                    "Indexing paused because the phone became active."
                )
                .apply()
            Result.retry()
        } catch (error: Exception) {
            if (!isCurrentRun()) return Result.success()
            // A transient provider or storage error should be resumed by
            // WorkManager instead of leaving the visible progress stuck.
            settings.edit()
                .putString("document_index_state", "retrying")
                .putString("document_index_last_error", error.toString())
                .apply()
            Log.e(LOG_TAG, "Index batch failed; WorkManager will retry", error)
            Result.retry()
        } catch (error: OutOfMemoryError) {
            if (!isCurrentRun()) return Result.success()
            System.gc()
            settings.edit()
                .putString("document_index_state", "paused_memory")
                .putString(
                    "document_index_last_error",
                    "A large file was paused to protect this phone's memory."
                )
                .apply()
            Log.e(LOG_TAG, "Index batch ran out of memory", error)
            Result.failure()
        }
    }

    override fun onStopped() {
        super.onStopped()
        val expectedGeneration = inputData.getLong(INPUT_GENERATION, 0L)
        if (!isCurrentDocumentIndexGeneration(applicationContext, expectedGeneration)) return
        val settings = documentIndexPreferences(applicationContext)
        if (settings.getBoolean("document_index_paused_for_search", false)) {
            settings.edit()
                .putString("document_index_state", "paused_for_search")
                .putString("document_index_current_file", "")
                .apply()
            return
        }
        settings.edit()
            .putString("document_index_state", "interrupted")
            .putString(
                "document_index_last_error",
                "Android interrupted indexing; automatic recovery is scheduled."
            )
            .apply()
        Log.w(LOG_TAG, "Batch stopped by Android; watchdog will recover it")
    }
}

/** Independent recovery path for a batch that Android timed out or killed. */
class DocumentIndexWatchdogWorker(
    appContext: Context,
    workerParams: WorkerParameters
) : Worker(appContext, workerParams) {
    companion object {
        const val UNIQUE_WORK_NAME = "smart_search_document_index_watchdog"
        const val WORK_TAG = "smart_search_document_index_watchdog"
        const val STALE_AFTER_MS = 8 * 60 * 1000L
    }

    override fun doWork(): Result {
        DocumentIndexDatabase.ensureFreshStorage(applicationContext)
        val settings = applicationContext.getSharedPreferences(
            "smart_search_cache",
            Context.MODE_PRIVATE
        )
        if (settings.getBoolean("document_index_paused_for_search", false)) {
            return Result.success()
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R &&
            !Environment.isExternalStorageManager()) {
            settings.edit()
                .putString("document_index_state", "waiting_permission")
                .putString(
                    "document_index_last_error",
                    "All files access is required to continue indexing."
                )
                .apply()
            return Result.success()
        }
        val now = System.currentTimeMillis()
        val lastActivity = maxOf(
            settings.getLong("document_index_last_progress_at", 0L),
            settings.getLong("document_index_worker_started_at", 0L),
            settings.getLong("document_index_requested_at", 0L)
        )
        val complete = settings.getBoolean("document_index_complete", false)
        if (!complete && now - lastActivity < STALE_AFTER_MS) return Result.success()

        settings.edit()
            .putString("document_index_state", "recovering")
            .putLong("document_index_requested_at", now)
            .apply()
        Log.w(
            DocumentIndexWorker.LOG_TAG,
            if (complete) "Checking for new or changed files"
            else if (settings.getString("document_index_state", "") == "scheduled") {
                "Checking the daytime queue for new or changed small files"
            }
            else "Watchdog found stale index; replacing the stranded batch"
        )
        WorkManager.getInstance(applicationContext).enqueueUniqueWork(
            DocumentIndexWorker.UNIQUE_WORK_NAME,
            ExistingWorkPolicy.REPLACE,
            newDocumentIndexRequest(applicationContext)
        )
        return Result.success()
    }
}

internal object DocumentIndexer {
    private const val INDEX_NOTIFICATION_ID = 4810
    private const val INDEX_CHANNEL_ID = "document_indexing"
    // Keep every regular WorkManager execution well below Android's background
    // job time limit, even when a batch contains scanned PDFs requiring OCR.
    // One document at a time is deliberate. PDFBox and OCR allocate large
    // native buffers, and parallel extraction was the main risk of Android
    // killing the process on a demo phone.
    private const val VERY_SMALL_FILE_BYTES = 500L * 1024L
    // Keep the full text of books and long reports in the private index. The
    // index is built in resumable background batches, so this does not block
    // the search screen while a large file is being read.
    // A document is stored as independently searchable chunks. This keeps a
    // long book useful after its first pages are read instead of keeping the
    // result hidden behind one very large in-memory extraction.
    private const val MAX_TEXT_CHARS = 160_000
    private const val PDF_PAGES_PER_EXTRACTION_BATCH = 5
    private const val MAX_DART_CONTEXT_CHARS = 2400
    private const val MIN_USEFUL_TEXT_CHARS = 300
    private const val MAX_OCR_PDF_PAGES = 1_000
    private const val OCR_PAGE_WIDTH = 1080
    private const val PROFILE_VERSION = "6"
    // Bump this whenever extraction changes so previously empty image/scanned-PDF
    // entries are actually OCRed instead of being reused solely by timestamp.
    private const val EXTRACTION_VERSION = "7"
    private const val SEARCH_CACHE_SIZE = 48
    private val retrievalExecutor = Executors.newFixedThreadPool(2)
    private val searchCacheLock = Any()

    private data class RetrievalCacheKey(
        val indexRevision: Long,
        val graphRevision: Long,
        val excludedFolders: String,
        val query: String,
    )

    private data class RetrievalStages(
        val keyword: List<Map<String, String>>,
        val graph: List<Map<String, String>>,
    )

    private data class FinalCacheKey(
        val retrieval: RetrievalCacheKey,
        val semantic: Boolean,
    )

    private val retrievalCache = object : LinkedHashMap<RetrievalCacheKey, RetrievalStages>(
        SEARCH_CACHE_SIZE, 0.75f, true,
    ) {
        override fun removeEldestEntry(
            eldest: MutableMap.MutableEntry<RetrievalCacheKey, RetrievalStages>?,
        ): Boolean = size > SEARCH_CACHE_SIZE
    }
    private val finalSearchCache = object : LinkedHashMap<FinalCacheKey, List<Map<String, String>>>(
        SEARCH_CACHE_SIZE, 0.75f, true,
    ) {
        override fun removeEldestEntry(
            eldest: MutableMap.MutableEntry<FinalCacheKey, List<Map<String, String>>>?,
        ): Boolean = size > SEARCH_CACHE_SIZE
    }

    enum class BatchResult { CONTINUE, COMPLETE, NO_ACCESS }

    /**
     * Mark all existing chunks stale without deleting them. The next generation
     * has to extract every file again, while the existing graph rows retain the
     * user's usage history until their refreshed file is committed.
     */
    fun beginFreshIndexGeneration(context: Context): Long =
        synchronized(documentIndexCommitLock) {
            val generation = advanceDocumentIndexGeneration(context)
            DocumentIndexDatabase.clear(context)
            clearSearchCaches()
            val now = System.currentTimeMillis()
            prefs(context).edit()
                // An explicit Settings action wins over the temporary typing
                // pause, otherwise a restart appears to do nothing.
                .putBoolean("document_index_paused_for_search", false)
                .putInt("document_index_cursor", 0)
                .putInt("document_index_total", 0)
                .putBoolean("document_index_complete", false)
                .putString("document_index_state", "queued")
                .putLong("document_index_revision", now)
                .putLong("document_index_requested_at", now)
                .putLong("document_index_last_progress_at", now)
                .putLong("document_index_last_scan", 0L)
                .putLong("document_index_next_run_at", 0L)
                .putString("document_index_current_file", "")
                .putString("document_index_last_error", "")
                .commit()
            generation
        }

    /**
     * Fast retrieval is exact FTS plus the already-prepared graph snapshot.
     * The caller may then request the same exact semantic pass progressively,
     * rather than holding the first result list behind a full vector scan.
     */
    fun search(
        context: Context,
        query: String,
        includeSemantic: Boolean = true,
        requestId: Long = 0L,
        shouldContinue: () -> Boolean = { true },
    ): List<Map<String, String>> {
        val startedAt = SystemClock.elapsedRealtime()
        if (!shouldContinue()) return emptyList()
        val excludedFolders = prefs(context)
            .getStringSet("excluded_document_folders", emptySet()) ?: emptySet()
        val normalizedQuery = query.lowercase().replace(Regex("\\s+"), " ").trim()
        val retrievalKey = RetrievalCacheKey(
            indexRevision = prefs(context).getLong("document_index_revision", 0L),
            graphRevision = PersonalKnowledgeGraph.cacheRevision(),
            excludedFolders = excludedFolders.sorted().joinToString("|"),
            query = normalizedQuery,
        )
        val finalKey = FinalCacheKey(retrievalKey, includeSemantic)
        synchronized(searchCacheLock) { finalSearchCache[finalKey] }?.let { cached ->
            Log.i(
                DocumentIndexWorker.LOG_TAG,
                "search-stage request=$requestId cache=final semantic=$includeSemantic " +
                    "totalMs=${SystemClock.elapsedRealtime() - startedAt} results=${cached.size}"
            )
            return cached
        }

        var keywordMs = 0L
        var graphMs = 0L
        val stages = synchronized(searchCacheLock) { retrievalCache[retrievalKey] } ?: run {
            val keywordFuture = retrievalExecutor.submit<Pair<List<Map<String, String>>, Long>> {
                val stageStarted = SystemClock.elapsedRealtime()
                val rows = if (shouldContinue()) LocalDocumentSearch.search(context, query) else emptyList()
                Pair(rows, SystemClock.elapsedRealtime() - stageStarted)
            }
            val graphFuture = retrievalExecutor.submit<Pair<List<Map<String, String>>, Long>> {
                val stageStarted = SystemClock.elapsedRealtime()
                val rows = if (shouldContinue()) PersonalKnowledgeGraph.search(context, query) else emptyList()
                Pair(rows, SystemClock.elapsedRealtime() - stageStarted)
            }
            val keyword = keywordFuture.get().also { keywordMs = it.second }.first
            val graph = graphFuture.get().also { graphMs = it.second }.first
            if (!shouldContinue()) return emptyList()
            RetrievalStages(keyword, graph).also { loaded ->
                synchronized(searchCacheLock) { retrievalCache[retrievalKey] = loaded }
            }
        }

        var embeddingMs = 0L
        var semanticMs = 0L
        val semanticMatches = if (includeSemantic) {
            val embeddingStarted = SystemClock.elapsedRealtime()
            val embedding = embedText(context, query)
            embeddingMs = SystemClock.elapsedRealtime() - embeddingStarted
            if (!shouldContinue()) return emptyList()
            val semanticStarted = SystemClock.elapsedRealtime()
            LocalSemanticSearch.search(
                context,
                embedding,
                requestId = requestId,
                shouldContinue = shouldContinue,
            ).also {
                semanticMs = SystemClock.elapsedRealtime() - semanticStarted
            }
        } else {
            emptyList()
        }
        if (!shouldContinue()) return emptyList()

        val mergeStarted = SystemClock.elapsedRealtime()
        val merged = PersonalKnowledgeGraph.mergeSearchResults(
            context = context,
            query = query,
            keywordMatches = stages.keyword,
            semanticMatches = semanticMatches,
            graphMatches = stages.graph,
        ).filterNot { row ->
            val folder = row["folder"].orEmpty()
            excludedFolders.any { folder.startsWith(it, ignoreCase = true) }
        }
        val mergeMs = SystemClock.elapsedRealtime() - mergeStarted
        if (shouldContinue()) {
            synchronized(searchCacheLock) { finalSearchCache[finalKey] = merged }
        }
        Log.i(
            DocumentIndexWorker.LOG_TAG,
            "search-stage request=$requestId cache=${if (keywordMs == 0L && graphMs == 0L) "retrieval" else "miss"} " +
                "semantic=$includeSemantic keywordMs=$keywordMs graphMs=$graphMs " +
                "embeddingMs=$embeddingMs semanticMs=$semanticMs mergeMs=$mergeMs " +
                "totalMs=${SystemClock.elapsedRealtime() - startedAt} results=${merged.size}"
        )
        return merged
    }

    private fun clearSearchCaches() {
        synchronized(searchCacheLock) {
            retrievalCache.clear()
            finalSearchCache.clear()
        }
        LocalSemanticSearch.clearCache()
    }

    fun clearCachesAfterImportChange() = clearSearchCaches()

    private fun matchingSnippet(content: String, normalizedQuery: String): String {
        if (content.isBlank()) return ""
        val normalizedContent = normalizeProfileText(content)
        val matchIndex = normalizedContent.indexOf(normalizedQuery)
        if (matchIndex < 0) return content.take(MAX_DART_CONTEXT_CHARS)
        val start = (matchIndex - MAX_DART_CONTEXT_CHARS / 4).coerceAtLeast(0)
        val end = (start + MAX_DART_CONTEXT_CHARS).coerceAtMost(normalizedContent.length)
        return normalizedContent.substring(start, end)
    }

    private fun prefs(context: Context) = documentIndexPreferences(context)

    /** Commit only when this worker still owns the current reset generation. */
    private fun commitFile(
        context: Context,
        source: Map<String, String>,
        chunks: List<Map<String, String>>,
        fileEmbedding: String,
        hash: String,
        expectedGeneration: Long,
        replaceExisting: Boolean,
        complete: Boolean,
    ): Boolean = synchronized(documentIndexCommitLock) {
        if (!isCurrentDocumentIndexGeneration(context, expectedGeneration)) {
            return@synchronized false
        }
        DocumentIndexDatabase.commitFile(
            context, source, chunks, fileEmbedding, hash,
            expectedGeneration, replaceExisting, complete,
        )
        true
    }

    private fun rows(context: Context): List<Map<String, String>> {
        val docs = mutableListOf<Map<String, String>>()
        val excludedFolders = prefs(context)
            .getStringSet("excluded_document_folders", emptySet()) ?: emptySet()
        val uri = MediaStore.Files.getContentUri("external")
        val projection = mutableListOf(
            MediaStore.Files.FileColumns._ID,
            MediaStore.Files.FileColumns.DISPLAY_NAME,
            MediaStore.Files.FileColumns.MIME_TYPE,
            MediaStore.Files.FileColumns.DATE_MODIFIED,
            MediaStore.Files.FileColumns.SIZE
        ).apply {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                add(MediaStore.Files.FileColumns.RELATIVE_PATH)
            }
        }.toTypedArray()
        context.contentResolver.query(
            uri,
            projection,
            null,
            null,
            "${MediaStore.Files.FileColumns.DATE_MODIFIED} DESC"
        )?.use { cursor ->
            val idColumn = cursor.getColumnIndexOrThrow(MediaStore.Files.FileColumns._ID)
            val nameColumn = cursor.getColumnIndexOrThrow(MediaStore.Files.FileColumns.DISPLAY_NAME)
            val mimeColumn = cursor.getColumnIndexOrThrow(MediaStore.Files.FileColumns.MIME_TYPE)
            val modifiedColumn = cursor.getColumnIndexOrThrow(MediaStore.Files.FileColumns.DATE_MODIFIED)
            val sizeColumn = cursor.getColumnIndexOrThrow(MediaStore.Files.FileColumns.SIZE)
            val folderColumn = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                cursor.getColumnIndex(MediaStore.Files.FileColumns.RELATIVE_PATH)
            } else -1
            while (cursor.moveToNext()) {
                val name = cursor.getString(nameColumn) ?: continue
                val type = resolvedMimeType(name, cursor.getString(mimeColumn))
                val size = cursor.getLong(sizeColumn)
                val folder = if (folderColumn >= 0) cursor.getString(folderColumn).orEmpty() else ""
                if (size <= 0 || !isSearchableFile(name, type)) continue
                if (excludedFolders.any { folder.startsWith(it, ignoreCase = true) }) continue
                docs.add(mapOf(
                    "name" to name,
                    "type" to type,
                    "path" to Uri.withAppendedPath(uri, cursor.getLong(idColumn).toString()).toString(),
                    "modified" to cursor.getLong(modifiedColumn).toString(),
                    "size" to size.toString(),
                    "folder" to folder
                ))
            }
        }
        // Index every supported file exposed by Android shared storage. The
        // newest files stay first so the search becomes useful immediately,
        // while older files continue sequentially without resetting progress.
        docs.addAll(ImportedDocumentStore.rows(context).filter { row ->
            excludedFolders.none { row["folder"].orEmpty().startsWith(it, ignoreCase = true) }
        })
        return docs.sortedByDescending {
            it["modified"]?.toLongOrNull() ?: 0L
        }
    }

    private fun documentKindPriority(type: String): Int = when {
        type.startsWith("text/", ignoreCase = true) ||
            type.contains("openxmlformats", ignoreCase = true) ||
            type.contains("officedocument", ignoreCase = true) ||
            type.contains("pdf", ignoreCase = true) -> 0
        type.startsWith("image/", ignoreCase = true) -> 1
        else -> 2
    }

    private fun sizeBucket(size: Long): Int = when {
        size <= 256 * 1024 -> 0
        size <= 2 * 1024 * 1024 -> 1
        size <= 10 * 1024 * 1024 -> 2
        size <= 50 * 1024 * 1024 -> 3
        else -> 4
    }

    private fun isHeavyIndexRow(row: Map<String, String>): Boolean {
        val type = row["type"].orEmpty()
        val size = row["size"]?.toLongOrNull() ?: Long.MAX_VALUE
        return size > VERY_SMALL_FILE_BYTES ||
            type.contains("pdf", ignoreCase = true) ||
            type.startsWith("image/", ignoreCase = true)
    }

    private fun contentHash(context: Context, uri: String): String {
        val digest = MessageDigest.getInstance("SHA-256")
        context.contentResolver.openInputStream(Uri.parse(uri))?.use { input ->
            val buffer = ByteArray(32 * 1024)
            var remaining = 512 * 1024
            while (remaining > 0) {
                val read = input.read(buffer, 0, minOf(buffer.size, remaining))
                if (read <= 0) break
                digest.update(buffer, 0, read)
                remaining -= read
            }
        } ?: return ""
        return digest.digest().joinToString("") { "%02x".format(it) }
    }

    private fun extractText(
        context: Context,
        uri: String,
        type: String,
        shouldContinue: () -> Boolean,
    ): String {
        if (!shouldContinue()) throw IndexingInterruptedException()
        return try {
            when {
                type.contains("pdf", ignoreCase = true) -> {
                    val embedded = try {
                        context.contentResolver.openInputStream(Uri.parse(uri))?.use { input ->
                            PDDocument.load(input).use { document ->
                                PDFTextStripper().getText(document).take(MAX_TEXT_CHARS)
                            }
                        } ?: ""
                    } catch (_: Exception) {
                        ""
                    }
                    // Image-only scans have no useful PDF text layer. Render a
                    // small number of pages and perform private, on-device OCR.
                    if (embedded.count { it.isLetterOrDigit() } >= MIN_USEFUL_TEXT_CHARS) embedded
                    else ocrPdf(
                        context,
                        Uri.parse(uri),
                        shouldContinue = shouldContinue
                    ).ifBlank { embedded }
                }
                type.startsWith("text/", ignoreCase = true) ||
                    type.contains("json", ignoreCase = true) ||
                    type.contains("xml", ignoreCase = true) ||
                    type.contains("rtf", ignoreCase = true) ->
                    context.contentResolver.openInputStream(Uri.parse(uri))?.use {
                        readLimitedText(it, MAX_TEXT_CHARS)
                    } ?: ""
                type.contains("openxmlformats", ignoreCase = true) ||
                    type.contains("officedocument", ignoreCase = true) ->
                    context.contentResolver.openInputStream(Uri.parse(uri))?.use { extractOfficeText(it) } ?: ""
                type.startsWith("image/", ignoreCase = true) ->
                    ocrImage(context, Uri.parse(uri), shouldContinue)
                else -> ""
            }
        } catch (error: IndexingInterruptedException) {
            throw error
        } catch (_: Exception) {
            ""
        }
    }

    private fun pdfPageCount(context: Context, uri: String): Int = try {
        context.contentResolver.openInputStream(Uri.parse(uri))?.use { input ->
            PDDocument.load(input).use { it.numberOfPages }
        } ?: 0
    } catch (_: Exception) {
        0
    }

    private fun extractPdfPages(
        context: Context,
        uri: String,
        firstPage: Int,
        lastPageExclusive: Int,
        shouldContinue: () -> Boolean,
    ): String {
        if (!shouldContinue()) throw IndexingInterruptedException()
        val embedded = try {
            context.contentResolver.openInputStream(Uri.parse(uri))?.use { input ->
                PDDocument.load(input).use { document ->
                    PDFTextStripper().apply {
                        startPage = firstPage + 1
                        endPage = lastPageExclusive.coerceAtMost(document.numberOfPages)
                    }.getText(document)
                }
            } ?: ""
        } catch (error: IndexingInterruptedException) {
            throw error
        } catch (_: Exception) {
            ""
        }
        if (!shouldContinue()) throw IndexingInterruptedException()
        return if (embedded.count { it.isLetterOrDigit() } >= MIN_USEFUL_TEXT_CHARS) {
            embedded
        } else {
            ocrPdf(
                context,
                Uri.parse(uri),
                firstPage,
                lastPageExclusive,
                shouldContinue
            ).ifBlank { embedded }
        }
    }

    private fun ocrImage(
        context: Context,
        uri: Uri,
        shouldContinue: () -> Boolean,
    ): String {
        if (!shouldContinue()) throw IndexingInterruptedException()
        val recognizer = TextRecognition.getClient(TextRecognizerOptions.DEFAULT_OPTIONS)
        return try {
            val image = InputImage.fromFilePath(context, uri)
            val text = Tasks.await(recognizer.process(image), 30, TimeUnit.SECONDS)
                .text.take(MAX_TEXT_CHARS)
            if (!shouldContinue()) throw IndexingInterruptedException()
            text
        } catch (error: IndexingInterruptedException) {
            throw error
        } catch (_: Exception) {
            ""
        } finally {
            recognizer.close()
        }
    }

    private fun ocrPdf(
        context: Context,
        uri: Uri,
        firstPage: Int = 0,
        lastPageExclusive: Int = MAX_OCR_PDF_PAGES,
        shouldContinue: () -> Boolean,
    ): String {
        val descriptor = context.contentResolver.openFileDescriptor(uri, "r") ?: return ""
        val recognizer = TextRecognition.getClient(TextRecognizerOptions.DEFAULT_OPTIONS)
        val result = StringBuilder()
        try {
            descriptor.use { fd ->
                PdfRenderer(fd).use { renderer ->
                    val pages = minOf(renderer.pageCount, lastPageExclusive, MAX_OCR_PDF_PAGES)
                    for (pageIndex in firstPage until pages) {
                        if (!shouldContinue()) throw IndexingInterruptedException()
                        if (result.length >= MAX_TEXT_CHARS) break
                        renderer.openPage(pageIndex).use { page ->
                            val scale = (OCR_PAGE_WIDTH.toFloat() / page.width.toFloat()).coerceAtMost(2.5f)
                            val width = (page.width * scale).toInt().coerceAtLeast(720)
                            val height = (page.height * scale).toInt().coerceAtLeast(960)
                            val bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
                            Canvas(bitmap).drawColor(Color.WHITE)
                            try {
                                page.render(bitmap, null, null, PdfRenderer.Page.RENDER_MODE_FOR_DISPLAY)
                                val text = Tasks.await(
                                    recognizer.process(InputImage.fromBitmap(bitmap, 0)),
                                    30,
                                    TimeUnit.SECONDS
                                ).text
                                if (!shouldContinue()) throw IndexingInterruptedException()
                                if (text.isNotBlank()) result.append('\n').append(text)
                            } finally {
                                bitmap.recycle()
                            }
                        }
                    }
                }
            }
        } catch (error: IndexingInterruptedException) {
            throw error
        } catch (_: Exception) {
            // Keep text from pages that were successfully recognized.
        } finally {
            recognizer.close()
        }
        return result.toString().take(MAX_TEXT_CHARS)
    }

    private fun extractOfficeText(input: InputStream): String {
        val result = StringBuilder()
        ZipInputStream(input).use { zip ->
            var entry = zip.nextEntry
            while (entry != null && result.length < MAX_TEXT_CHARS) {
                val relevant = entry.name.startsWith("word/") ||
                    entry.name.startsWith("ppt/slides/") ||
                    entry.name.startsWith("ppt/notesSlides/") ||
                    entry.name.startsWith("xl/sharedStrings") ||
                    entry.name.startsWith("xl/worksheets/") ||
                    entry.name == "docProps/core.xml"
                if (relevant && entry.name.endsWith(".xml")) {
                    val remaining = MAX_TEXT_CHARS - result.length
                    result.append(' ').append(
                        readLimitedText(zip, remaining)
                            .replace(Regex("<[^>]+>"), " ")
                    )
                }
                zip.closeEntry()
                entry = zip.nextEntry
            }
        }
        return result.toString()
            .replace("&amp;", "&")
            .replace("&lt;", "<")
            .replace("&gt;", ">")
            .replace("&quot;", "\"")
            .replace(Regex("\\s+"), " ")
            .take(MAX_TEXT_CHARS)
    }

    private fun readLimitedText(input: InputStream, maxChars: Int): String {
        if (maxChars <= 0) return ""
        val reader = input.reader(Charsets.UTF_8)
        val result = StringBuilder(minOf(maxChars, 4096))
        val buffer = CharArray(2048)
        while (result.length < maxChars) {
            val requested = minOf(buffer.size, maxChars - result.length)
            val read = reader.read(buffer, 0, requested)
            if (read <= 0) break
            result.append(buffer, 0, read)
        }
        return result.toString()
    }

    private fun documentProfile(name: String, mimeType: String, content: String): Map<String, String> {
        val text = normalizeProfileText("$name $content")
        val groups = linkedMapOf(
            "certificate" to linkedMapOf(
                "certificate of completion" to 15, "certificate of achievement" to 15,
                "certificate of participation" to 14, "this is to certify" to 15,
                "has successfully completed" to 12, "successfully completed" to 9,
                "is hereby awarded" to 11, "presented to" to 8, "awarded to" to 8,
                "completion certificate" to 14, "certificate" to 3,
                "workshop" to 2, "bootcamp" to 2, "training" to 2
            ),
            "travel_ticket" to linkedMapOf(
                "irctc" to 18, "pnr" to 14, "train number" to 10, "train no" to 10,
                "boarding" to 7, "reservation" to 7, "journey" to 6,
                "coach" to 5, "berth" to 5, "passenger" to 4, "fare" to 4,
                "e ticket" to 9, "flight ticket" to 12, "air ticket" to 12,
                "boarding pass" to 14
            ),
            "assignment" to linkedMapOf(
                "assignment" to 14, "digital assignment" to 16, "submitted by" to 7,
                "submitted to" to 7, "course code" to 6, "homework" to 11,
                "lab exercise" to 9
            ),
            "invoice" to linkedMapOf(
                "tax invoice" to 16, "invoice number" to 12, "invoice no" to 12,
                "bill to" to 8, "gstin" to 10, "subtotal" to 5, "amount due" to 7
            ),
            "receipt" to linkedMapOf(
                "payment receipt" to 15, "receipt number" to 10, "transaction id" to 7,
                "payment successful" to 8, "paid amount" to 7
            ),
            "resume" to linkedMapOf(
                "curriculum vitae" to 18, "work experience" to 10,
                "professional experience" to 10, "career objective" to 8, "resume" to 15
            ),
            "identity" to linkedMapOf(
                "aadhaar" to 18, "passport number" to 15, "identity card" to 13,
                "government of india" to 5, "driving licence" to 15, "driving license" to 15
            ),
            "bank_statement" to linkedMapOf(
                "account statement" to 15, "bank statement" to 18, "account number" to 7,
                "opening balance" to 8, "closing balance" to 8, "debit" to 4, "credit" to 4
            ),
            "study_material" to linkedMapOf(
                "lecture notes" to 12, "study material" to 14, "learning objectives" to 7,
                "chapter" to 3, "syllabus" to 12, "tutorial" to 5
            ),
            "education_record" to linkedMapOf(
                "statement of marks" to 18, "mark sheet" to 18, "marksheet" to 18,
                "academic record" to 15, "board examination" to 14,
                "board of secondary education" to 15, "higher secondary" to 12,
                "senior school certificate" to 12, "class xii" to 11,
                "12th" to 9, "subject code" to 7, "marks obtained" to 10,
                "maximum marks" to 8, "total marks" to 8, "result" to 3,
                "cbse" to 8, "cisce" to 8
            )
        )
        val scored = groups.mapValues { (_, signals) ->
            signals.entries.filter { text.contains(it.key) }.sumOf { it.value }
        }.toMutableMap()
        val travelMatches = groups["travel_ticket"]?.keys
            ?.filter { text.contains(it) }
            .orEmpty()
        val strongTravelSignals = setOf(
            "irctc", "pnr", "train number", "train no", "e ticket",
            "flight ticket", "air ticket", "boarding pass"
        )
        if (travelMatches.none { it in strongTravelSignals } && travelMatches.size < 2) {
            scored["travel_ticket"] = 0
        }
        val normalizedName = normalizeProfileText(name)
        if (normalizedName.contains("certificate")) scored["certificate"] = (scored["certificate"] ?: 0) + 5
        if (normalizedName.contains("ticket")) scored["travel_ticket"] = (scored["travel_ticket"] ?: 0) + 5
        if (normalizedName.contains("assignment")) scored["assignment"] = (scored["assignment"] ?: 0) + 6
        if (mimeType.contains("spreadsheet") || normalizedName.endsWith("xlsx")) scored["spreadsheet"] = 7
        if (mimeType.contains("presentation") || normalizedName.endsWith("pptx")) scored["presentation"] = 7

        val ordered = scored.entries.sortedByDescending { it.value }
        val best = ordered.firstOrNull()
        val category = if (best == null || best.value < 5) "document" else best.key
        val bestScore = if (category == "document") 0 else best?.value ?: 0
        val secondScore = ordered.drop(1).firstOrNull()?.value ?: 0
        val confidence = if (bestScore == 0) 0.25 else
            (0.55 + bestScore / 45.0 + (bestScore - secondScore) / 70.0).coerceIn(0.55, 0.99)
        val stopWords = setOf(
            "the", "and", "for", "this", "that", "with", "from", "have", "has", "was",
            "are", "your", "you", "document", "file", "page", "into", "their", "will"
        )
        val keywords = text.split(' ')
            .filter { it.length >= 3 && it !in stopWords }
            .groupingBy { it }.eachCount().entries
            .sortedWith(compareByDescending<Map.Entry<String, Int>> { it.value }.thenBy { it.key })
            .map { it.key }.take(16).toMutableList()
        if (category != "document" && category !in keywords) keywords.add(0, category)
        val matchingSignals = groups[category]?.keys?.filter { text.contains(it) }?.take(8) ?: emptyList()
        val label = categoryLabel(category)
        val topics = keywords.filter { it != category }.take(4).joinToString(", ")
        val summary = if (category == "document") name
            else if (topics.isBlank()) "$label: $name" else "$label about $topics"
        return mapOf(
            "category" to category,
            "categoryConfidence" to String.format(java.util.Locale.US, "%.2f", confidence),
            "summary" to summary.take(240),
            "keywords" to keywords.take(18).joinToString("|"),
            "signals" to matchingSignals.joinToString("|"),
            "metadata" to structuredMetadata(text, category),
            "profileVersion" to PROFILE_VERSION
        )
    }

    private fun structuredMetadata(text: String, category: String): String {
        val metadata = JSONObject()
        if (category == "travel_ticket") {
            when {
                Regex("\\b(flight|boarding pass|air\\s+ticket|airline|airport)\\b").containsMatchIn(text) ->
                    metadata.put("subtype", "flight")
                Regex("\\b(irctc|train|pnr|coach|berth)\\b").containsMatchIn(text) ->
                    metadata.put("subtype", "train")
            }
            Regex(
                "\\bfrom\\s+([a-z][a-z ]{1,28}?)\\s+to\\s+([a-z][a-z ]{1,28}?)(?=\\s+(?:on|date|departure|arrival|flight|train|journey)\\b|$)"
            ).find(text)?.let { route ->
                metadata.put("from", route.groupValues[1].trim())
                metadata.put("to", route.groupValues[2].trim())
            }
        }
        Regex(
            "\\b(?:\\d{4}\\s+\\d{1,2}\\s+\\d{1,2}|\\d{1,2}\\s+\\d{1,2}\\s+(?:\\d{2}|\\d{4})|\\d{1,2}\\s+(?:jan(?:uary)?|feb(?:ruary)?|mar(?:ch)?|apr(?:il)?|may|jun(?:e)?|jul(?:y)?|aug(?:ust)?|sep(?:tember)?|oct(?:ober)?|nov(?:ember)?|dec(?:ember)?)\\s+(?:\\d{2}|\\d{4}))\\b"
        ).find(text)?.value?.let { metadata.put("date", it) }
        return metadata.toString()
    }

    fun embedText(context: Context, value: String): String {
        return MiniLmTextEmbedder.embed(context, value)
    }

    private fun normalizeProfileText(value: String): String = value.lowercase()
        .replace(Regex("\\bpreambur\\b"), "perambur")
        .replace(Regex("\\b(one)\\b"), "1")
        .replace(Regex("\\b(two)\\b"), "2")
        .replace(Regex("\\b(three)\\b"), "3")
        .replace(Regex("front[ -]?end"), "frontend")
        .replace(Regex("[^a-z0-9]+"), " ")
        .replace(Regex("\\s+"), " ")
        .trim()

    private fun categoryLabel(category: String): String = when (category) {
        "certificate" -> "Certificate"
        "travel_ticket" -> "Travel ticket"
        "assignment" -> "Assignment"
        "invoice" -> "Invoice"
        "receipt" -> "Receipt"
        "resume" -> "Resume"
        "identity" -> "Identity document"
        "bank_statement" -> "Bank statement"
        "study_material" -> "Study material"
        "education_record" -> "Mark sheet / academic record"
        "spreadsheet" -> "Spreadsheet"
        "presentation" -> "Presentation"
        else -> "Document"
    }

    private fun createChannel(context: Context) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                INDEX_CHANNEL_ID,
                "Document indexing",
                NotificationManager.IMPORTANCE_LOW
            ).apply { description = "Shows local file indexing progress" }
            context.getSystemService(NotificationManager::class.java).createNotificationChannel(channel)
        }
    }

    private fun formatBytes(bytes: Long): String = when {
        bytes >= 1024 * 1024 -> String.format("%.1f MB", bytes / (1024.0 * 1024.0))
        bytes >= 1024 -> String.format("%.0f KB", bytes / 1024.0)
        else -> "$bytes B"
    }

    private fun notification(context: Context, done: Int, total: Int, bytes: Long, finished: Boolean): android.app.Notification {
        createChannel(context)
        val text = if (finished) {
            "Indexed $done files • ${formatBytes(bytes)} extracted on this device"
        } else {
            "Indexed $done of $total files • ${formatBytes(bytes)} extracted"
        }
        return NotificationCompat.Builder(context, INDEX_CHANNEL_ID)
            .setSmallIcon(android.R.drawable.ic_menu_search)
            .setContentTitle(if (finished) "File index is ready" else "Indexing your files")
            .setContentText(text)
            .setOnlyAlertOnce(true)
            .setOngoing(!finished)
            .setProgress(if (finished) 0 else total.coerceAtLeast(1), if (finished) 0 else done, !finished && total == 0)
            .build()
    }

    private fun updateNotification(context: Context, done: Int, total: Int, bytes: Long, finished: Boolean) {
        if (Build.VERSION.SDK_INT >= 33 &&
            context.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) return
        context.getSystemService(NotificationManager::class.java).notify(
            INDEX_NOTIFICATION_ID,
            notification(context, done, total, bytes, finished)
        )
    }

    fun indexOneBatch(
        context: Context,
        expectedGeneration: Long,
        shouldContinue: () -> Boolean,
    ): BatchResult {
        if (!isCurrentDocumentIndexGeneration(context, expectedGeneration)) {
            return BatchResult.CONTINUE
        }
        val settings = prefs(context)
        val now = System.currentTimeMillis()
        val batchStartedAt = SystemClock.elapsedRealtime()
        // This is a runtime check, not just a WorkRequest constraint: Android
        // may start an inexact request later than its selected window.
        val heavyWindow = isHeavyIndexWindow(context, now)
        val mode = documentIndexMode(context)
        val workPolicy = documentIndexWorkPolicy(
            mode,
            heavyWindow,
        )
        val allRows = try {
            rows(context)
        } catch (_: SecurityException) {
            return BatchResult.NO_ACCESS
        }
        val sourceFingerprint = allRows
            .sortedBy { it["path"].orEmpty() }
            .fold(1125899906842597L) { fingerprint, row ->
                31L * fingerprint + listOf(
                    row["path"].orEmpty(),
                    row["modified"].orEmpty(),
                    row["size"].orEmpty(),
                    row["type"].orEmpty(),
                    row["folder"].orEmpty()
                ).joinToString("|").hashCode().toLong()
            }
            .toString()
        PDFBoxResourceLoader.init(context.applicationContext)
        DocumentIndexDatabase.removeFilesNotIn(
            context,
            allRows.mapNotNull { it["path"] }.toSet(),
        )
        if (allRows.isEmpty()) {
            if (!shouldContinue()) return BatchResult.CONTINUE
            runCatching { LocalDocumentSearch.prepare(context) }
            runCatching { PersonalKnowledgeGraph.syncFromCurrentIndex(context) }
            if (!shouldContinue()) return BatchResult.CONTINUE
            settings.edit()
                .putBoolean("document_index_complete", true)
                .putLong("document_index_last_scan", now)
                .putLong("document_index_revision", now)
                .putString("document_profile_version", PROFILE_VERSION)
                .putString("document_extraction_version", EXTRACTION_VERSION)
                .putString("document_source_fingerprint", sourceFingerprint)
                .putLong("document_index_next_run_at", 0L)
                .apply()
            updateNotification(context, 0, 0, 0, true)
            return BatchResult.COMPLETE
        }

        // Load only small file-state columns. OCR text and embeddings stay on
        // disk until the one file currently being resumed needs them.
        val indexedStates = DocumentIndexDatabase.fileStates(context)
        fun isCurrent(row: Map<String, String>): Boolean {
            val path = row["path"] ?: return false
            val state = indexedStates[path] ?: return false
            return state.complete && state.modified == row["modified"] &&
                state.size == row["size"] &&
                state.extractionVersion == EXTRACTION_VERSION &&
                state.profileVersion == PROFILE_VERSION &&
                state.generation == expectedGeneration
        }

        val pendingRows = allRows.filter { !isCurrent(it) }
        if (pendingRows.isEmpty()) {
            runCatching { LocalDocumentSearch.prepare(context) }
            runCatching { PersonalKnowledgeGraph.syncFromCurrentIndex(context) }
            if (!shouldContinue()) return BatchResult.CONTINUE
            val totalBytes = DocumentIndexDatabase.totalExtractedBytes(
                context, expectedGeneration
            )
            settings.edit()
                .putInt("document_index_cursor", allRows.size)
                .putInt("document_index_total", allRows.size)
                .putBoolean("document_index_complete", true)
                .putLong("document_index_revision", System.currentTimeMillis())
                .putLong("document_index_last_progress_at", System.currentTimeMillis())
                .putLong("document_index_last_scan", System.currentTimeMillis())
                .putString("document_source_fingerprint", sourceFingerprint)
                .putString("document_index_current_file", "")
                .putString("document_index_last_error", "")
                .putLong("document_index_next_run_at", 0L)
                .apply()
            updateNotification(context, allRows.size, allRows.size, totalBytes, true)
            return BatchResult.COMPLETE
        }
        // The selected speed decides whether this batch may run and whether it
        // can include PDF/image/OCR work. Every tier keeps newest files first.
        val eligibleRows = when {
            !workPolicy.mayRunNow -> emptyList()
            workPolicy.processesHeavyFiles -> pendingRows
            else -> pendingRows.filter { !isHeavyIndexRow(it) }
        }
        if (eligibleRows.isEmpty()) {
            val nextRunAt = nextHeavyIndexWindowStart(context, now)
            if (!shouldContinue()) return BatchResult.CONTINUE
            settings.edit()
                .putBoolean("document_index_complete", false)
                .putInt("document_index_total", allRows.size)
                .putString("document_index_state", "scheduled")
                .putString("document_index_current_file", "")
                .putLong("document_index_next_run_at", nextRunAt)
                .putLong("document_index_last_progress_at", now)
                .apply()
            return BatchResult.CONTINUE
        }
        val batchRows = eligibleRows.take(workPolicy.batchSize)

        var processedRows = 0
        for (row in batchRows) {
            if (!shouldContinue() ||
                // The request may start near the window edge; never begin a
                // heavy extraction after the persisted window has closed.
                (isHeavyIndexRow(row) &&
                    !documentIndexWorkPolicy(
                        mode,
                        isHeavyIndexWindow(context),
                    ).processesHeavyFiles) ||
                (processedRows > 0 &&
                    SystemClock.elapsedRealtime() - batchStartedAt >=
                    workPolicy.maxBatchRuntimeMs)) {
                break
            }
            val path = row["path"] ?: continue
            settings.edit()
                .putString("document_index_current_file", row["name"].orEmpty())
                .apply()
            val oldChunks = DocumentIndexDatabase.chunksForFile(context, path)
            // Hash once when a file is first seen or changed. Reusing it for
            // the following page batches avoids rereading a 1,000-page book
            // before each 50-page chunk can be indexed.
            val savedHash = oldChunks.firstOrNull()?.get("hash").orEmpty()
            val sameRevision = oldChunks.isNotEmpty() && oldChunks.all {
                it["modified"] == row["modified"] &&
                    it["extractionVersion"] == EXTRACTION_VERSION &&
                    it["indexGeneration"]?.toLongOrNull() == expectedGeneration
            }
            val hash = if (sameRevision && savedHash.isNotEmpty()) savedHash
                else contentHash(context, path)
            val unchanged = oldChunks.isNotEmpty() &&
                oldChunks.all {
                        it["hash"] == hash &&
                        it["modified"] == row["modified"] &&
                        it["extractionVersion"] == EXTRACTION_VERSION &&
                        it["indexGeneration"]?.toLongOrNull() == expectedGeneration
                }
            val existingChunks = if (unchanged) oldChunks else emptyList()
            val chunkIndex = (existingChunks.maxOfOrNull {
                it["chunkIndex"]?.toIntOrNull() ?: -1
            } ?: -1) + 1
            val type = row["type"] ?: ""
            val isPdf = type.contains("pdf", ignoreCase = true)
            // Resume from the last committed page, not chunkIndex * chunkSize.
            // This keeps partially indexed PDFs correct when an app update
            // changes the safe page-batch size.
            val pageStart = if (isPdf) {
                existingChunks.maxOfOrNull {
                    it["pageEnd"]?.toIntOrNull() ?: 0
                } ?: 0
            } else {
                0
            }
            val pageTotal = if (isPdf) pdfPageCount(context, path) else 0
            if (isPdf) {
                settings.edit()
                    .putString(
                        "document_index_current_file",
                        "${row["name"].orEmpty()} (pages ${pageStart + 1}-${minOf(pageStart + PDF_PAGES_PER_EXTRACTION_BATCH, pageTotal)} of $pageTotal)"
                    )
                    .apply()
            }
            val content = when {
                isPdf && pageStart < pageTotal -> extractPdfPages(
                    context,
                    path,
                    pageStart,
                    pageStart + PDF_PAGES_PER_EXTRACTION_BATCH,
                    shouldContinue
                )
                isPdf -> ""
                else -> extractText(context, path, type, shouldContinue)
            }
            val completeForFile = !isPdf ||
                pageStart + PDF_PAGES_PER_EXTRACTION_BATCH >= pageTotal
            val extractedBytes = content.toByteArray(Charsets.UTF_8).size.toLong()
            val semanticChunks = SemanticTextChunker.chunk(content).ifEmpty {
                listOf(SemanticTextChunk("", emptyList()))
            }
            var nextChunkIndex = chunkIndex
            val newRows = semanticChunks.mapIndexed { semanticIndex, semanticChunk ->
                val profile = documentProfile(
                    row["name"] ?: "",
                    row["type"] ?: "",
                    semanticChunk.content
                )
                val headings = semanticChunk.headings.joinToString("|")
                val embeddingInput = listOf(
                    row["name"].orEmpty(),
                    headings,
                    semanticChunk.content,
                ).filter { it.isNotBlank() }.joinToString("\n")
                val embedding = embedText(context, embeddingInput)
                val currentIndex = nextChunkIndex++
                row + mapOf(
                    "sourcePath" to path,
                    "content" to semanticChunk.content,
                    // Count extraction bytes once; overlapping windows should
                    // not inflate the user's visible indexing progress.
                    "bytes" to if (semanticIndex == 0) extractedBytes.toString() else "0",
                    "embedding" to embedding,
                    "chunkEmbedding" to embedding,
                    "headings" to headings,
                    "extractionVersion" to EXTRACTION_VERSION,
                    "indexGeneration" to expectedGeneration.toString(),
                    "hash" to hash,
                    "chunkIndex" to currentIndex.toString(),
                    "pageStart" to if (isPdf) (pageStart + 1).toString() else "0",
                    "pageEnd" to if (isPdf) minOf(
                        pageStart + PDF_PAGES_PER_EXTRACTION_BATCH,
                        pageTotal
                    ).toString() else "0",
                    "complete" to (completeForFile &&
                        semanticIndex == semanticChunks.lastIndex).toString()
                ) + profile
            }
            val representationRows = existingChunks + newRows
            val fileRepresentation = buildString {
                append("File: ").append(row["name"].orEmpty())
                representationRows.mapNotNull { it["summary"] }
                    .filter { it.isNotBlank() }.distinct().take(8)
                    .forEach { append("\nSummary: ").append(it) }
                val topics = representationRows.flatMap {
                    it["keywords"].orEmpty().split('|')
                }.filter { it.isNotBlank() }.distinct().take(32)
                if (topics.isNotEmpty()) append("\nTopics: ").append(topics.joinToString(", "))
                val sections = representationRows.flatMap {
                    it["headings"].orEmpty().split('|')
                }.filter { it.isNotBlank() }.distinct().take(24)
                if (sections.isNotEmpty()) append("\nSections: ").append(sections.joinToString(", "))
            }
            val fileEmbedding = embedText(context, fileRepresentation)
            processedRows++
            // Commit after every completed file/page chunk. If Android stops
            // the worker when the user picks up the phone, all earlier work in
            // this batch remains durable and the next run starts after it.
            if (!shouldContinue() ||
                !commitFile(
                    context = context,
                    source = row,
                    chunks = newRows,
                    fileEmbedding = fileEmbedding,
                    hash = hash,
                    expectedGeneration = expectedGeneration,
                    replaceExisting = !unchanged,
                    complete = completeForFile,
                )) {
                return BatchResult.CONTINUE
            }
        }
        if (processedRows == 0) return BatchResult.CONTINUE
        // Prepare full-text lookup in this background indexing batch rather
        // than making the next keystroke rebuild the derived index.
        runCatching { LocalDocumentSearch.prepare(context) }
        runCatching { PersonalKnowledgeGraph.syncFromCurrentIndex(context) }
        if (!shouldContinue()) return BatchResult.CONTINUE

        val done = DocumentIndexDatabase.countIndexedFiles(context, expectedGeneration)
        val completeCount = DocumentIndexDatabase.countCompleteFiles(context, expectedGeneration)
        val complete = completeCount == allRows.size
        val totalBytes = DocumentIndexDatabase.totalExtractedBytes(context, expectedGeneration)
        settings.edit()
            .putString("document_profile_version", PROFILE_VERSION)
            .putString("document_extraction_version", EXTRACTION_VERSION)
            .putInt("document_index_cursor", done)
            .putInt("document_index_total", allRows.size)
            .putBoolean("document_index_complete", complete)
            .putLong("document_index_revision", System.currentTimeMillis())
            .putLong("document_index_last_progress_at", System.currentTimeMillis())
            .putString("document_index_current_file", "")
            .putString("document_index_last_error", "")
            .putLong(
                "document_index_next_run_at",
                System.currentTimeMillis() + workPolicy.nextBatchDelayMs
            )
            .apply()
        if (complete) {
            settings.edit()
                .putLong("document_index_last_scan", System.currentTimeMillis())
                .putString("document_profile_version", PROFILE_VERSION)
                .putString("document_extraction_version", EXTRACTION_VERSION)
                .putString("document_source_fingerprint", sourceFingerprint)
                .putLong("document_index_next_run_at", 0L)
                .apply()
            updateNotification(context, allRows.size, allRows.size, totalBytes, true)
            return BatchResult.COMPLETE
        }
        updateNotification(context, done, allRows.size, totalBytes, false)
        return BatchResult.CONTINUE
    }
}
