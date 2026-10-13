package com.example.smart_search_app

import android.content.Context
import android.net.Uri
import android.provider.OpenableColumns
import android.webkit.MimeTypeMap
import androidx.core.content.FileProvider
import java.io.File

/** Private, user-selected copies of attachments that other apps keep in their own storage. */
internal object ImportedDocumentStore {
    private const val FOLDER_NAME = "imported_notes"
    private const val DISPLAY_FOLDER = "Imported notes/"

    private fun folder(context: Context) = File(context.filesDir, FOLDER_NAME)

    private fun uri(context: Context, file: File): Uri = FileProvider.getUriForFile(
        context, "${context.packageName}.imported_documents", file,
    )

    private fun safeName(raw: String): String = raw
        .replace(Regex("[\\\\/:*?\"<>|\\p{Cntrl}]"), " ")
        .replace(Regex("\\s+"), " ")
        .trim(' ', '.')

    internal fun importedFileName(subject: String, originalName: String): String {
        val cleanSubject = safeName(subject).take(70)
        require(cleanSubject.isNotBlank()) { "Enter the subject for these notes." }
        val original = safeName(originalName)
        val extension = original.substringAfterLast('.', "").takeIf {
            it.isNotEmpty() && it.length <= 10
        }?.let { ".$it" }.orEmpty()
        val originalStem = if (extension.isEmpty()) original else original.dropLast(extension.length)
        val subjectLabel = if (Regex("\\bnotes?\\b", RegexOption.IGNORE_CASE)
                .containsMatchIn(cleanSubject)) cleanSubject else "$cleanSubject notes"
        return safeName("$subjectLabel - $originalStem")
            .take(160 - extension.length).trimEnd(' ', '.') + extension
    }

    fun describe(context: Context, source: Uri): Map<String, String> {
        var name = source.lastPathSegment.orEmpty()
            .replace('\\', '/').substringAfterLast('/')
        var size = 0L
        runCatching {
            context.contentResolver.query(
                source, arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE),
                null, null, null,
            )?.use { cursor ->
                if (cursor.moveToFirst()) {
                    val nameColumn = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                    val sizeColumn = cursor.getColumnIndex(OpenableColumns.SIZE)
                    if (nameColumn >= 0) name = cursor.getString(nameColumn) ?: name
                    if (sizeColumn >= 0 && !cursor.isNull(sizeColumn)) size = cursor.getLong(sizeColumn)
                }
            }
        }
        val reportedType = runCatching { context.contentResolver.getType(source) }.getOrNull()
        val safe = safeName(name).ifEmpty { "Attachment" }
        val type = resolvedMimeType(safe, reportedType)
        return mapOf("name" to safe, "type" to type, "size" to size.toString())
    }

    fun import(context: Context, source: Uri, subject: String): Map<String, String> {
        require(source.scheme == "content" || source.scheme == "file") {
            "The selected attachment is unavailable."
        }
        val description = describe(context, source)
        var original = description["name"].orEmpty()
        val type = description["type"].orEmpty()
        if (!original.contains('.')) {
            val extension = MimeTypeMap.getSingleton().getExtensionFromMimeType(type)
            if (!extension.isNullOrBlank()) original += ".$extension"
        }
        val baseName = importedFileName(subject, original)
        val directory = folder(context).apply { mkdirs() }
        val extension = baseName.substringAfterLast('.', "")
        val stem = if (extension.isNotEmpty()) baseName.dropLast(extension.length + 1) else baseName
        var destination = File(directory, baseName)
        var suffix = 2
        while (destination.exists()) {
            destination = File(directory, "$stem ($suffix)${if (extension.isEmpty()) "" else ".$extension"}")
            suffix++
        }
        val temporary = File.createTempFile("import-", ".part", directory)
        try {
            context.contentResolver.openInputStream(source)?.use { input ->
                temporary.outputStream().use { output -> input.copyTo(output, 64 * 1024) }
            } ?: throw IllegalArgumentException("The attachment could not be opened.")
            require(temporary.length() > 0L) { "The attachment is empty." }
            if (!temporary.renameTo(destination)) {
                throw IllegalStateException("The attachment could not be saved.")
            }
        } finally {
            temporary.delete()
        }
        return row(context, destination)
    }

    private fun row(context: Context, file: File): Map<String, String> = mapOf(
        "name" to file.name,
        "type" to resolvedMimeType(file.name, null),
        "path" to uri(context, file).toString(),
        "modified" to (file.lastModified() / 1000L).toString(),
        "size" to file.length().toString(),
        "folder" to DISPLAY_FOLDER,
    )

    fun rows(context: Context): List<Map<String, String>> = folder(context)
        .listFiles().orEmpty()
        .filter { it.isFile && it.length() > 0L && !it.name.endsWith(".part") }
        .map { row(context, it) }
        .sortedByDescending { it["modified"]?.toLongOrNull() ?: 0L }

    fun metadataForUri(context: Context, requestedUri: Uri): Map<String, String>? =
        rows(context).firstOrNull { it["path"] == requestedUri.toString() }

    fun delete(context: Context, requestedUri: Uri): Boolean {
        val file = folder(context).listFiles().orEmpty().firstOrNull { candidate ->
            candidate.isFile && uri(context, candidate) == requestedUri
        } ?: return false
        return file.delete()
    }
}
