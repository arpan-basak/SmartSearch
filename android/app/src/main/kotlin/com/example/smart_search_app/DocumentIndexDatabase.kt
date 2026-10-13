package com.example.smart_search_app

import android.content.ContentValues
import android.content.Context
import android.database.sqlite.SQLiteDatabase
import android.database.sqlite.SQLiteOpenHelper
import android.util.Base64
import java.io.File

/**
 * Durable source of truth for the private document index.
 *
 * Files and their independently searchable sections are deliberately stored in
 * related tables. A completed file/page transaction changes only those rows;
 * indexing never materializes or rewrites the complete library in memory.
 */
internal object DocumentIndexDatabase {
    private const val DATABASE_NAME = "document_index_v2.db"
    private const val DATABASE_VERSION = 2
    private const val STORAGE_VERSION = 2
    private const val STORAGE_VERSION_KEY = "document_index_storage_version"
    private const val PREFERENCES_NAME = "smart_search_cache"
    private const val FTS_ENGINE_KEY = "fts_engine"
    private const val FTS5_TABLE = "document_chunks_fts5"
    private const val FTS4_TABLE = "document_chunks_fts4"
    private val initializationLock = Any()

    data class FileState(
        val modified: String,
        val size: String,
        val hash: String,
        val profileVersion: String,
        val extractionVersion: String,
        val generation: Long,
        val complete: Boolean,
    )

    data class SemanticRow(
        val path: String,
        val chunkIndex: Int,
        val chunkEmbedding: ByteArray?,
        val fileEmbedding: ByteArray?,
    )

    private class Helper(context: Context) :
        SQLiteOpenHelper(context, DATABASE_NAME, null, DATABASE_VERSION) {
        override fun onConfigure(db: SQLiteDatabase) {
            super.onConfigure(db)
            db.setForeignKeyConstraintsEnabled(true)
            db.enableWriteAheadLogging()
        }

        override fun onCreate(db: SQLiteDatabase) {
            db.execSQL(
                """CREATE TABLE metadata(
                    key TEXT PRIMARY KEY,
                    value TEXT NOT NULL
                )"""
            )
            db.execSQL(
                """CREATE TABLE files(
                    path TEXT PRIMARY KEY,
                    name TEXT NOT NULL,
                    mime_type TEXT NOT NULL,
                    modified INTEGER NOT NULL DEFAULT 0,
                    size INTEGER NOT NULL DEFAULT 0,
                    folder TEXT NOT NULL DEFAULT '',
                    content_hash TEXT NOT NULL DEFAULT '',
                    category TEXT NOT NULL DEFAULT 'document',
                    category_confidence TEXT NOT NULL DEFAULT '0.25',
                    summary TEXT NOT NULL DEFAULT '',
                    keywords TEXT NOT NULL DEFAULT '',
                    signals TEXT NOT NULL DEFAULT '',
                    profile_metadata TEXT NOT NULL DEFAULT '{}',
                    file_embedding TEXT NOT NULL DEFAULT '',
                    file_embedding_blob BLOB,
                    profile_version TEXT NOT NULL DEFAULT '0',
                    extraction_version TEXT NOT NULL DEFAULT '0',
                    index_generation INTEGER NOT NULL DEFAULT 0,
                    complete INTEGER NOT NULL DEFAULT 0,
                    updated_at INTEGER NOT NULL DEFAULT 0
                )"""
            )
            db.execSQL(
                """CREATE TABLE chunks(
                    file_path TEXT NOT NULL,
                    chunk_index INTEGER NOT NULL,
                    content TEXT NOT NULL DEFAULT '',
                    extracted_bytes INTEGER NOT NULL DEFAULT 0,
                    embedding TEXT NOT NULL DEFAULT '',
                    embedding_blob BLOB,
                    headings TEXT NOT NULL DEFAULT '',
                    page_start INTEGER NOT NULL DEFAULT 0,
                    page_end INTEGER NOT NULL DEFAULT 0,
                    PRIMARY KEY(file_path, chunk_index),
                    FOREIGN KEY(file_path) REFERENCES files(path) ON DELETE CASCADE
                )"""
            )
            db.execSQL("CREATE INDEX chunks_file_page ON chunks(file_path,page_start,page_end)")
            db.execSQL("CREATE INDEX files_generation_complete ON files(index_generation,complete)")
            val engine = try {
                db.execSQL(
                    """CREATE VIRTUAL TABLE $FTS5_TABLE USING
                        fts5(file_path UNINDEXED, chunk_index UNINDEXED, name,
                        summary, headings, content, tokenize='unicode61')"""
                )
                "fts5"
            } catch (_: Exception) {
                db.execSQL(
                    """CREATE VIRTUAL TABLE $FTS4_TABLE USING
                        fts4(file_path, chunk_index, name, summary, headings,
                        content, notindexed=file_path, notindexed=chunk_index,
                        tokenize=unicode61)"""
                )
                "fts4"
            }
            db.insert("metadata", null, ContentValues().apply {
                put("key", FTS_ENGINE_KEY)
                put("value", engine)
            })
        }

        override fun onUpgrade(db: SQLiteDatabase, oldVersion: Int, newVersion: Int) {
            if (oldVersion < 2) {
                db.execSQL("ALTER TABLE files ADD COLUMN file_embedding_blob BLOB")
                db.execSQL("ALTER TABLE chunks ADD COLUMN embedding_blob BLOB")
            }
        }
    }

    /**
     * The JSON index is generated data, so this storage change intentionally
     * starts a fresh scan instead of importing it. The marker prevents later
     * app launches from resetting the SQLite index again.
     */
    fun ensureFreshStorage(context: Context): Boolean = synchronized(initializationLock) {
        val appContext = context.applicationContext
        val preferences = appContext.getSharedPreferences(PREFERENCES_NAME, Context.MODE_PRIVATE)
        if (preferences.getInt(STORAGE_VERSION_KEY, 0) == STORAGE_VERSION) {
            return@synchronized false
        }

        appContext.deleteDatabase(DATABASE_NAME)
        appContext.deleteDatabase("document_search.db")
        File(appContext.filesDir, "document_index.json").delete()
        File(appContext.filesDir, "document_index.json.tmp").delete()
        // Do not persist the version marker until SQLite has successfully
        // created and opened every required table.
        val helper = Helper(appContext)
        helper.writableDatabase.close()
        helper.close()
        preferences.edit()
            .putInt(STORAGE_VERSION_KEY, STORAGE_VERSION)
            .putInt("document_index_cursor", 0)
            .putInt("document_index_total", 0)
            .putBoolean("document_index_complete", false)
            .putString("document_index_state", "queued")
            .putString("document_index_current_file", "")
            .putString("document_index_last_error", "")
            .putLong("document_index_last_scan", 0L)
            .putLong("document_index_next_run_at", 0L)
            .putLong("document_index_revision", System.currentTimeMillis())
            .putLong("document_index_last_progress_at", System.currentTimeMillis())
            .commit()
        true
    }

    fun clear(context: Context) {
        synchronized(initializationLock) {
            context.applicationContext.deleteDatabase(DATABASE_NAME)
        }
    }

    private inline fun <T> read(context: Context, block: (SQLiteDatabase) -> T): T {
        ensureFreshStorage(context)
        val helper = Helper(context.applicationContext)
        val db = helper.readableDatabase
        return try { block(db) } finally {
            db.close()
            helper.close()
        }
    }

    private inline fun <T> write(context: Context, block: (SQLiteDatabase) -> T): T {
        ensureFreshStorage(context)
        val helper = Helper(context.applicationContext)
        val db = helper.writableDatabase
        return try { block(db) } finally {
            db.close()
            helper.close()
        }
    }

    private fun ftsTable(db: SQLiteDatabase): Pair<String, Boolean> {
        val engine = db.rawQuery(
            "SELECT value FROM metadata WHERE key=?", arrayOf(FTS_ENGINE_KEY)
        ).use { if (it.moveToFirst()) it.getString(0) else "fts4" }
        return if (engine == "fts5") Pair(FTS5_TABLE, true) else Pair(FTS4_TABLE, false)
    }

    private fun decodeEmbedding(value: String): ByteArray? {
        if (value.isBlank()) return null
        return try {
            Base64.decode(value, Base64.NO_WRAP).takeIf { it.isNotEmpty() }
        } catch (_: IllegalArgumentException) {
            null
        }
    }

    fun fileStates(context: Context): Map<String, FileState> = read(context) { db ->
        buildMap {
            db.rawQuery(
                """SELECT path,modified,size,content_hash,profile_version,
                   extraction_version,index_generation,complete FROM files""", null
            ).use { cursor ->
                while (cursor.moveToNext()) {
                    put(cursor.getString(0), FileState(
                        modified = cursor.getLong(1).toString(),
                        size = cursor.getLong(2).toString(),
                        hash = cursor.getString(3),
                        profileVersion = cursor.getString(4),
                        extractionVersion = cursor.getString(5),
                        generation = cursor.getLong(6),
                        complete = cursor.getInt(7) != 0,
                    ))
                }
            }
        }
    }

    fun chunksForFile(context: Context, path: String): List<Map<String, String>> = read(context) { db ->
        queryRows(db, "WHERE f.path=? ORDER BY c.chunk_index", arrayOf(path))
    }

    fun representativeRows(context: Context): List<Map<String, String>> = read(context) { db ->
        queryRows(
            db,
            """WHERE c.chunk_index=(SELECT MIN(c2.chunk_index) FROM chunks c2
               WHERE c2.file_path=f.path) ORDER BY f.modified DESC""",
            emptyArray(),
        ).map { row -> row + ("content" to row["content"].orEmpty().take(2400)) }
    }

    fun syncRows(context: Context, paths: Set<String>): List<Map<String, String>> {
        if (paths.isEmpty()) return emptyList()
        return paths.flatMap { path -> chunksForFile(context, path) }
    }

    fun storageBreakdown(context: Context): Map<String, Long> = read(context) { db ->
        val values = db.rawQuery(
            """SELECT COUNT(DISTINCT f.path),
               COALESCE(SUM(LENGTH(c.content)),0),
               COALESCE(SUM(LENGTH(c.embedding_blob)),0) +
                 COALESCE(SUM(LENGTH(f.file_embedding_blob)),0)
               FROM files f LEFT JOIN chunks c ON c.file_path=f.path""",
            null,
        ).use { cursor ->
            if (cursor.moveToFirst()) Triple(
                cursor.getLong(0), cursor.getLong(1), cursor.getLong(2)
            ) else Triple(0L, 0L, 0L)
        }
        mapOf(
            "documentCount" to values.first,
            "ocrChunkBytes" to values.second,
            "embeddingBytes" to values.third,
            "documentIndexBytes" to context.getDatabasePath(DATABASE_NAME).length(),
        )
    }

    fun graphFiles(context: Context): List<Map<String, String>> = read(context) { db ->
        db.rawQuery(
            """SELECT path,name,mime_type,folder,modified,size,summary,category,
               keywords,content_hash,profile_version,extraction_version,
               (SELECT COUNT(*) FROM chunks c WHERE c.file_path=files.path)
               FROM files ORDER BY path""",
            null,
        ).use { cursor ->
            buildList {
                while (cursor.moveToNext()) {
                    add(mapOf(
                        "path" to cursor.getString(0),
                        "sourcePath" to cursor.getString(0),
                        "name" to cursor.getString(1),
                        "type" to cursor.getString(2),
                        "folder" to cursor.getString(3),
                        "modified" to cursor.getLong(4).toString(),
                        "size" to cursor.getLong(5).toString(),
                        "summary" to cursor.getString(6),
                        "category" to cursor.getString(7),
                        "keywords" to cursor.getString(8),
                        "hash" to cursor.getString(9),
                        "profileVersion" to cursor.getString(10),
                        "extractionVersion" to cursor.getString(11),
                        "chunkCount" to cursor.getInt(12).toString(),
                    ))
                }
            }
        }
    }

    fun revisionStamp(context: Context): String = read(context) { db ->
        db.rawQuery(
            """SELECT COUNT(*),COALESCE(MAX(updated_at),0),
               (SELECT COUNT(*) FROM chunks) FROM files""",
            null,
        ).use { cursor ->
            if (cursor.moveToFirst()) {
                "${cursor.getLong(0)}:${cursor.getLong(1)}:${cursor.getLong(2)}"
            } else "0:0:0"
        }
    }

    private fun queryRows(
        db: SQLiteDatabase,
        suffix: String,
        args: Array<String>,
    ): List<Map<String, String>> {
        val sql = """SELECT f.name,f.mime_type,f.path,f.modified,f.size,f.folder,
            f.category,f.category_confidence,f.summary,f.keywords,f.signals,
            f.profile_metadata,f.file_embedding,f.profile_version,
            f.extraction_version,f.content_hash,f.index_generation,f.complete,
            c.chunk_index,c.content,c.extracted_bytes,c.embedding,c.headings,
            c.page_start,c.page_end
            FROM files f JOIN chunks c ON c.file_path=f.path $suffix"""
        return db.rawQuery(sql, args).use { cursor ->
            buildList {
                while (cursor.moveToNext()) {
                    add(mapOf(
                        "name" to cursor.getString(0),
                        "type" to cursor.getString(1),
                        "path" to cursor.getString(2),
                        "sourcePath" to cursor.getString(2),
                        "modified" to cursor.getLong(3).toString(),
                        "size" to cursor.getLong(4).toString(),
                        "folder" to cursor.getString(5),
                        "category" to cursor.getString(6),
                        "categoryConfidence" to cursor.getString(7),
                        "summary" to cursor.getString(8),
                        "keywords" to cursor.getString(9),
                        "signals" to cursor.getString(10),
                        "metadata" to cursor.getString(11),
                        "fileEmbedding" to cursor.getString(12),
                        "profileVersion" to cursor.getString(13),
                        "extractionVersion" to cursor.getString(14),
                        "hash" to cursor.getString(15),
                        "indexGeneration" to cursor.getLong(16).toString(),
                        "complete" to (cursor.getInt(17) != 0).toString(),
                        "chunkIndex" to cursor.getInt(18).toString(),
                        "content" to cursor.getString(19),
                        "bytes" to cursor.getLong(20).toString(),
                        "embedding" to cursor.getString(21),
                        "chunkEmbedding" to cursor.getString(21),
                        "headings" to cursor.getString(22),
                        "pageStart" to cursor.getInt(23).toString(),
                        "pageEnd" to cursor.getInt(24).toString(),
                    ))
                }
            }
        }
    }

    /** Commit a file and all newly completed sections as one durable unit. */
    fun commitFile(
        context: Context,
        source: Map<String, String>,
        chunks: List<Map<String, String>>,
        fileEmbedding: String,
        hash: String,
        generation: Long,
        replaceExisting: Boolean,
        complete: Boolean,
    ) = write(context) { db ->
        db.beginTransaction()
        try {
            val path = source["path"].orEmpty()
            val (ftsTable, _) = ftsTable(db)
            if (replaceExisting) {
                db.delete(ftsTable, "file_path=?", arrayOf(path))
                db.delete("files", "path=?", arrayOf(path))
            }
            val first = chunks.firstOrNull().orEmpty()
            val existingProfile = if (first.isEmpty()) chunksForFileInDatabase(db, path).firstOrNull().orEmpty()
                else first
            val fileValues = ContentValues().apply {
                put("path", path)
                put("name", source["name"].orEmpty())
                put("mime_type", source["type"].orEmpty())
                put("modified", source["modified"]?.toLongOrNull() ?: 0L)
                put("size", source["size"]?.toLongOrNull() ?: 0L)
                put("folder", source["folder"].orEmpty())
                put("content_hash", hash)
                put("category", existingProfile["category"] ?: "document")
                put("category_confidence", existingProfile["categoryConfidence"] ?: "0.25")
                put("summary", existingProfile["summary"].orEmpty())
                put("keywords", existingProfile["keywords"].orEmpty())
                put("signals", existingProfile["signals"].orEmpty())
                put("profile_metadata", existingProfile["metadata"] ?: "{}")
                put("file_embedding", fileEmbedding)
                put("file_embedding_blob", decodeEmbedding(fileEmbedding))
                put("profile_version", existingProfile["profileVersion"] ?: "0")
                put("extraction_version", existingProfile["extractionVersion"] ?: "0")
                put("index_generation", generation)
                put("complete", if (complete) 1 else 0)
                put("updated_at", System.currentTimeMillis())
            }
            // UPDATE preserves previously committed page chunks. SQLite
            // REPLACE would delete the parent row and cascade-delete them.
            if (db.update("files", fileValues, "path=?", arrayOf(path)) == 0) {
                db.insertOrThrow("files", null, fileValues)
            }

            chunks.forEach { chunk ->
                val chunkIndex = chunk["chunkIndex"]?.toIntOrNull() ?: 0
                db.insertWithOnConflict("chunks", null, ContentValues().apply {
                    put("file_path", path)
                    put("chunk_index", chunkIndex)
                    put("content", chunk["content"].orEmpty())
                    put("extracted_bytes", chunk["bytes"]?.toLongOrNull() ?: 0L)
                    val embedding = chunk["chunkEmbedding"] ?: chunk["embedding"].orEmpty()
                    put("embedding", embedding)
                    put("embedding_blob", decodeEmbedding(embedding))
                    put("headings", chunk["headings"].orEmpty())
                    put("page_start", chunk["pageStart"]?.toIntOrNull() ?: 0)
                    put("page_end", chunk["pageEnd"]?.toIntOrNull() ?: 0)
                }, SQLiteDatabase.CONFLICT_REPLACE)
                db.delete(ftsTable, "file_path=? AND chunk_index=?", arrayOf(path, chunkIndex.toString()))
                db.insert(ftsTable, null, ContentValues().apply {
                    put("file_path", path)
                    put("chunk_index", chunkIndex)
                    put("name", source["name"].orEmpty())
                    put("summary", chunk["summary"].orEmpty())
                    put("headings", chunk["headings"].orEmpty())
                    put("content", chunk["content"].orEmpty())
                })
            }
            db.setTransactionSuccessful()
        } finally { db.endTransaction() }
    }

    private fun chunksForFileInDatabase(db: SQLiteDatabase, path: String): List<Map<String, String>> =
        queryRows(db, "WHERE f.path=? ORDER BY c.chunk_index", arrayOf(path))

    fun removeFilesNotIn(context: Context, paths: Set<String>) = write(context) { db ->
        val (ftsTable, _) = ftsTable(db)
        db.beginTransaction()
        try {
            val removed = mutableListOf<String>()
            db.rawQuery("SELECT path FROM files", null).use { cursor ->
                while (cursor.moveToNext()) {
                    val path = cursor.getString(0)
                    if (path !in paths) removed += path
                }
            }
            removed.forEach { path ->
                db.delete(ftsTable, "file_path=?", arrayOf(path))
                db.delete("files", "path=?", arrayOf(path))
            }
            db.setTransactionSuccessful()
        } finally { db.endTransaction() }
    }

    fun removeGeneratedDataFor(context: Context, paths: Set<String>) = write(context) { db ->
        if (paths.isEmpty()) return@write
        val (ftsTable, _) = ftsTable(db)
        db.beginTransaction()
        try {
            paths.forEach { path ->
                db.delete(ftsTable, "file_path=?", arrayOf(path))
                db.delete("files", "path=?", arrayOf(path))
            }
            db.setTransactionSuccessful()
        } finally { db.endTransaction() }
    }

    fun countIndexedFiles(context: Context, generation: Long): Int = read(context) { db ->
        db.rawQuery("SELECT COUNT(*) FROM files WHERE index_generation=?", arrayOf(generation.toString()))
            .use { if (it.moveToFirst()) it.getInt(0) else 0 }
    }

    fun countCompleteFiles(context: Context, generation: Long): Int = read(context) { db ->
        db.rawQuery(
            "SELECT COUNT(*) FROM files WHERE index_generation=? AND complete=1",
            arrayOf(generation.toString()),
        ).use { if (it.moveToFirst()) it.getInt(0) else 0 }
    }

    fun totalExtractedBytes(context: Context, generation: Long): Long = read(context) { db ->
        db.rawQuery(
            """SELECT COALESCE(SUM(c.extracted_bytes),0) FROM chunks c
               JOIN files f ON f.path=c.file_path WHERE f.index_generation=?""",
            arrayOf(generation.toString()),
        ).use { if (it.moveToFirst()) it.getLong(0) else 0L }
    }

    fun fullTextSearch(context: Context, query: String): List<Map<String, String>> = read(context) { db ->
        val terms = queryTerms(query)
        if (terms.isEmpty()) return@read emptyList()
        val (table, fts5) = ftsTable(db)
        fun retrieve(expression: String): List<Map<String, String>> {
            val snippet = if (fts5) "snippet($table,5,'','',' … ',48)" else
                "snippet($table,'','',' … ',5,48)"
            val relevance = if (fts5) "bm25($table,0.0,0.0,5.0,4.0,3.0,1.0)" else "0.0"
            val sql = """SELECT x.file_path,x.chunk_index,$snippet,$relevance,
                f.name,f.mime_type,f.modified,f.size,f.folder,f.category,
                f.category_confidence,f.summary,f.keywords,f.signals,
                f.profile_metadata,f.file_embedding,f.profile_version,
                f.extraction_version,f.content_hash,f.index_generation,f.complete,
                c.embedding,c.headings,c.page_start,c.page_end
                FROM $table x JOIN files f ON f.path=x.file_path
                JOIN chunks c ON c.file_path=x.file_path AND c.chunk_index=x.chunk_index
                WHERE $table MATCH ? ${if (fts5) "ORDER BY $relevance" else ""}"""
            return db.rawQuery(sql, arrayOf(expression)).use { cursor ->
                buildList {
                    var rank = 1
                    while (cursor.moveToNext()) {
                        add(mapOf(
                            "path" to cursor.getString(0), "sourcePath" to cursor.getString(0),
                            "chunkIndex" to cursor.getInt(1).toString(), "content" to cursor.getString(2).orEmpty(),
                            "ftsScore" to cursor.getDouble(3).toString(), "ftsRank" to (rank++).toString(),
                            "name" to cursor.getString(4), "type" to cursor.getString(5),
                            "modified" to cursor.getLong(6).toString(), "size" to cursor.getLong(7).toString(),
                            "folder" to cursor.getString(8), "category" to cursor.getString(9),
                            "categoryConfidence" to cursor.getString(10), "summary" to cursor.getString(11),
                            "keywords" to cursor.getString(12), "signals" to cursor.getString(13),
                            "metadata" to cursor.getString(14), "fileEmbedding" to cursor.getString(15),
                            "profileVersion" to cursor.getString(16), "extractionVersion" to cursor.getString(17),
                            "hash" to cursor.getString(18), "indexGeneration" to cursor.getLong(19).toString(),
                            "complete" to (cursor.getInt(20) != 0).toString(),
                            "embedding" to cursor.getString(21), "chunkEmbedding" to cursor.getString(21),
                            "headings" to cursor.getString(22), "pageStart" to cursor.getInt(23).toString(),
                            "pageEnd" to cursor.getInt(24).toString(), "retrievalReasons" to "Full-text match",
                        ))
                    }
                }
            }
        }
        val expression = if (fts5) terms.joinToString(" OR ") { "$it*" }
            else terms.joinToString(" OR ") { "\"$it*\"" }
        retrieve(expression).ifEmpty {
            val prefixes = terms.filter { it.length >= 5 }.map { it.dropLast(1) }
            if (prefixes.isEmpty()) emptyList() else retrieve(
                if (fts5) prefixes.joinToString(" OR ") { "$it*" }
                else prefixes.joinToString(" OR ") { "\"$it*\"" }
            )
        }
    }

    fun semanticRows(context: Context): List<SemanticRow> = read(context) { db ->
        db.rawQuery(
            """SELECT f.path,c.chunk_index,c.embedding_blob,f.file_embedding_blob,
               CASE WHEN c.embedding_blob IS NULL THEN c.embedding ELSE '' END,
               CASE WHEN f.file_embedding_blob IS NULL THEN f.file_embedding ELSE '' END
               FROM files f JOIN chunks c ON c.file_path=f.path
               ORDER BY f.path,c.chunk_index""",
            null,
        ).use { cursor ->
            buildList {
                while (cursor.moveToNext()) {
                    val chunkEncoded = cursor.getString(4).orEmpty()
                    val fileEncoded = cursor.getString(5).orEmpty()
                    add(SemanticRow(
                        path = cursor.getString(0),
                        chunkIndex = cursor.getInt(1),
                        chunkEmbedding = if (cursor.isNull(2)) {
                            decodeEmbedding(chunkEncoded)
                        } else {
                            cursor.getBlob(2)
                        },
                        fileEmbedding = if (cursor.isNull(3)) {
                            decodeEmbedding(fileEncoded)
                        } else {
                            cursor.getBlob(3)
                        },
                    ))
                }
            }
        }
    }

    fun visitSemanticRows(
        context: Context,
        visitor: (Map<String, String>) -> Unit,
    ) {
        semanticRows(context).forEach { row ->
            visitor(mapOf(
                "path" to row.path,
                "sourcePath" to row.path,
                "chunkIndex" to row.chunkIndex.toString(),
            ))
        }
    }

    fun semanticResultRows(
        context: Context,
        selections: List<Pair<String, Int>>,
    ): Map<Pair<String, Int>, Map<String, String>> = read(context) { db ->
        if (selections.isEmpty()) return@read emptyMap()
        val where = selections.joinToString(" OR ") { "(c.file_path=? AND c.chunk_index=?)" }
        val args = selections.flatMap { listOf(it.first, it.second.toString()) }.toTypedArray()
        queryRows(db, "WHERE $where", args).associateBy { row ->
            Pair(row["sourcePath"].orEmpty(), row["chunkIndex"]?.toIntOrNull() ?: 0)
        }
    }

    /** One-time migration for indexes created before binary vector storage.
     * Small transactions keep WAL readers responsive while the app is idle. */
    fun backfillEmbeddingBlobs(
        context: Context,
        shouldContinue: () -> Boolean = { true },
    ): Int {
        var updated = 0
        while (shouldContinue()) {
            val batch = write(context) { db ->
                val files = db.rawQuery(
                    """SELECT path,file_embedding FROM files
                       WHERE file_embedding_blob IS NULL AND file_embedding<>'' LIMIT 200""",
                    null,
                ).use { cursor ->
                    buildList {
                        while (cursor.moveToNext()) add(Pair(cursor.getString(0), cursor.getString(1)))
                    }
                }
                val chunks = db.rawQuery(
                    """SELECT file_path,chunk_index,embedding FROM chunks
                       WHERE embedding_blob IS NULL AND embedding<>'' LIMIT 400""",
                    null,
                ).use { cursor ->
                    buildList {
                        while (cursor.moveToNext()) add(Triple(
                            cursor.getString(0), cursor.getInt(1), cursor.getString(2),
                        ))
                    }
                }
                if (files.isEmpty() && chunks.isEmpty()) return@write 0
                var changed = 0
                db.beginTransaction()
                try {
                    files.forEach { (path, encoded) ->
                        val vector = decodeEmbedding(encoded) ?: return@forEach
                        changed += db.update("files", ContentValues().apply {
                            put("file_embedding_blob", vector)
                        }, "path=?", arrayOf(path))
                    }
                    chunks.forEach { (path, index, encoded) ->
                        val vector = decodeEmbedding(encoded) ?: return@forEach
                        changed += db.update("chunks", ContentValues().apply {
                            put("embedding_blob", vector)
                        }, "file_path=? AND chunk_index=?", arrayOf(path, index.toString()))
                    }
                    db.setTransactionSuccessful()
                } finally {
                    db.endTransaction()
                }
                changed
            }
            if (batch == 0) break
            updated += batch
            Thread.yield()
        }
        return updated
    }

    private fun queryTerms(query: String): Set<String> {
        val stop = setOf(
            "find", "my", "the", "document", "documents", "file", "files",
            "please", "show", "me", "about", "where", "did", "read"
        )
        val terms = Regex("[\\p{L}\\p{N}]+").findAll(query.lowercase())
            .map { it.value }.filter { it.length >= 2 && it !in stop }
            .take(12).toMutableSet()
        if ("syllabus" in terms) terms.addAll(listOf("curriculum", "outline"))
        if ("ticket" in terms || "train" in terms) terms.addAll(listOf("pnr", "irctc"))
        if ("assignment" in terms) terms.addAll(listOf("homework", "coursework"))
        if ("gpu" in terms) terms.addAll(listOf("cuda", "kernel", "warp", "gpgpu", "coalesced", "coalescing"))
        return terms.take(20).toSet()
    }
}
