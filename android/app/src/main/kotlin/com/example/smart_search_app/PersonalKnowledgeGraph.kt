package com.example.smart_search_app

import android.content.ContentValues
import android.content.Context
import android.database.sqlite.SQLiteDatabase
import android.database.sqlite.SQLiteOpenHelper
import java.util.Calendar
import java.util.concurrent.atomic.AtomicLong

/**
 * Private, explainable knowledge graph backed by Android's bundled SQLite.
 *
 * It is opened only by background indexing, an explicit search, or a recorded
 * user action. Nothing in this store runs on the cold-start critical path.
 */
internal object PersonalKnowledgeGraph {
    private const val DATABASE_NAME = "personal_knowledge.db"
    private const val DATABASE_VERSION = 3
    private const val SOURCE_VERSION = "3"
    private const val MAX_ENTITY_TERMS = 8
    private val lock = Any()
    private val searchRevision = AtomicLong(0L)

    private class Helper(context: Context) :
        SQLiteOpenHelper(context, DATABASE_NAME, null, DATABASE_VERSION) {
        override fun onCreate(db: SQLiteDatabase) {
            db.execSQL(
                """CREATE TABLE files(
                    path TEXT PRIMARY KEY,
                    name TEXT NOT NULL,
                    mime_type TEXT NOT NULL,
                    folder TEXT NOT NULL DEFAULT '',
                    modified INTEGER NOT NULL DEFAULT 0,
                    size INTEGER NOT NULL DEFAULT 0,
                    summary TEXT NOT NULL DEFAULT '',
                    category TEXT NOT NULL DEFAULT 'document',
                    keywords TEXT NOT NULL DEFAULT '',
                    content_hash TEXT NOT NULL DEFAULT '',
                    last_opened INTEGER NOT NULL DEFAULT 0,
                    usage_count INTEGER NOT NULL DEFAULT 0
                )"""
            )
            db.execSQL(
                """CREATE TABLE chunks(
                    file_path TEXT NOT NULL,
                    chunk_index INTEGER NOT NULL,
                    content TEXT NOT NULL DEFAULT '',
                    embedding TEXT NOT NULL DEFAULT '',
                    file_embedding TEXT NOT NULL DEFAULT '',
                    headings TEXT NOT NULL DEFAULT '',
                    page_start INTEGER NOT NULL DEFAULT 0,
                    page_end INTEGER NOT NULL DEFAULT 0,
                    PRIMARY KEY(file_path, chunk_index),
                    FOREIGN KEY(file_path) REFERENCES files(path) ON DELETE CASCADE
                )"""
            )
            db.execSQL(
                """CREATE TABLE entities(
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    type TEXT NOT NULL,
                    label TEXT NOT NULL,
                    normalized TEXT NOT NULL,
                    UNIQUE(type, normalized)
                )"""
            )
            db.execSQL(
                """CREATE TABLE relations(
                    source_path TEXT NOT NULL,
                    entity_id INTEGER NOT NULL,
                    relationship TEXT NOT NULL,
                    weight REAL NOT NULL,
                    provenance TEXT NOT NULL,
                    PRIMARY KEY(source_path, entity_id, relationship),
                    FOREIGN KEY(source_path) REFERENCES files(path) ON DELETE CASCADE,
                    FOREIGN KEY(entity_id) REFERENCES entities(id) ON DELETE CASCADE
                )"""
            )
            db.execSQL(
                """CREATE TABLE file_links(
                    from_path TEXT NOT NULL,
                    to_path TEXT NOT NULL,
                    relationship TEXT NOT NULL,
                    weight REAL NOT NULL,
                    updated_at INTEGER NOT NULL,
                    PRIMARY KEY(from_path, to_path, relationship)
                )"""
            )
            db.execSQL(
                """CREATE TABLE usage_events(
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    kind TEXT NOT NULL,
                    target TEXT NOT NULL,
                    title TEXT NOT NULL,
                    occurred_at INTEGER NOT NULL
                )"""
            )
            db.execSQL("CREATE TABLE metadata(key TEXT PRIMARY KEY, value TEXT NOT NULL)")
            db.execSQL("CREATE INDEX relations_entity ON relations(entity_id)")
            db.execSQL("CREATE INDEX usage_target ON usage_events(target, occurred_at DESC)")
            db.execSQL("PRAGMA foreign_keys=ON")
        }

        override fun onUpgrade(db: SQLiteDatabase, oldVersion: Int, newVersion: Int) {
            if (oldVersion < 2) {
                db.execSQL("ALTER TABLE files ADD COLUMN content_hash TEXT NOT NULL DEFAULT ''")
            }
            if (oldVersion < 3) {
                db.execSQL("ALTER TABLE chunks ADD COLUMN file_embedding TEXT NOT NULL DEFAULT ''")
                db.execSQL("ALTER TABLE chunks ADD COLUMN headings TEXT NOT NULL DEFAULT ''")
            }
        }

        override fun onConfigure(db: SQLiteDatabase) {
            super.onConfigure(db)
            db.setForeignKeyConstraintsEnabled(true)
            db.enableWriteAheadLogging()
        }
    }

    private fun normalize(value: String): String = value.lowercase()
        .replace(Regex("[^\\p{L}\\p{N}]+"), " ")
        .replace(Regex("\\s+"), " ")
        .trim()

    private val queryStopWords = setOf(
        "a", "an", "and", "about", "all", "everything", "file", "files",
        "find", "for", "from", "in", "is", "me", "my", "of", "on", "related",
        "show", "that", "the", "this", "to", "used", "with"
    )

    private fun terms(value: String): List<String> = normalize(value).split(' ')
        .filter { it.length >= 2 && it !in queryStopWords }
        .distinct()
        .take(MAX_ENTITY_TERMS)

    private fun temporalRange(query: String, now: Long = System.currentTimeMillis()): Pair<Long, Long>? {
        val text = normalize(query)
        val day = 24 * 60 * 60 * 1000L
        if (text.contains("last week") || text.contains("past week")) {
            return Pair(now - 7 * day, now)
        }
        if (text.contains("recent") || text.contains("lately")) {
            return Pair(now - 30 * day, now)
        }
        if (text.contains("last month") || text.contains("past month")) {
            return Pair(now - 31 * day, now)
        }
        val calendar = Calendar.getInstance().apply { timeInMillis = now }
        fun startOfDay(): Long = calendar.apply {
            set(Calendar.HOUR_OF_DAY, 0)
            set(Calendar.MINUTE, 0)
            set(Calendar.SECOND, 0)
            set(Calendar.MILLISECOND, 0)
        }.timeInMillis
        if (text.contains("yesterday")) {
            val end = startOfDay()
            return Pair(end - day, end)
        }
        if (text.contains("today")) {
            return Pair(startOfDay(), now)
        }
        val weekdays = mapOf(
            "sunday" to Calendar.SUNDAY, "monday" to Calendar.MONDAY,
            "tuesday" to Calendar.TUESDAY, "wednesday" to Calendar.WEDNESDAY,
            "thursday" to Calendar.THURSDAY, "friday" to Calendar.FRIDAY,
            "saturday" to Calendar.SATURDAY,
        )
        val requestedDay = weekdays.entries.firstOrNull { text.contains("last ${it.key}") }
            ?: return null
        while (calendar.get(Calendar.DAY_OF_WEEK) != requestedDay.value) {
            calendar.add(Calendar.DAY_OF_YEAR, -1)
        }
        if (calendar.timeInMillis >= now - day) calendar.add(Calendar.DAY_OF_YEAR, -7)
        val start = startOfDay()
        return Pair(start, start + day)
    }

    fun syncFromCurrentIndex(context: Context) = synchronized(lock) {
        val indexedFiles = DocumentIndexDatabase.graphFiles(context)
        val helper = Helper(context.applicationContext)
        val db = helper.writableDatabase
        try {
            val expectedStamp = "${DocumentIndexDatabase.revisionStamp(context)}:$SOURCE_VERSION"
            val currentStamp = db.rawQuery(
                "SELECT value FROM metadata WHERE key='source_stamp'", null
            ).use { if (it.moveToFirst()) it.getString(0) else "" }
            if (currentStamp == expectedStamp) return@synchronized
            val currentPaths = indexedFiles.mapNotNull { it["path"] }.toSet()

            db.beginTransaction()
            try {
                data class ExistingFile(
                    val signature: String,
                    val usageCount: Int,
                    val lastOpened: Long,
                )
                val existingFiles = mutableMapOf<String, ExistingFile>()
                db.rawQuery(
                    "SELECT path, content_hash, usage_count, last_opened FROM files",
                    null,
                ).use { cursor ->
                    while (cursor.moveToNext()) {
                        existingFiles[cursor.getString(0)] = ExistingFile(
                            signature = cursor.getString(1),
                            usageCount = cursor.getInt(2),
                            lastOpened = cursor.getLong(3),
                        )
                    }
                }

                // Remove only files Android no longer exposes or the user has
                // excluded. Foreign keys cascade to chunks and relations.
                existingFiles.keys.filterNot(currentPaths::contains).forEach { path ->
                    db.delete("files", "path=?", arrayOf(path))
                }

                indexedFiles.forEach { first ->
                    val path = first["path"] ?: return@forEach
                    val signature = listOf(
                        first["hash"].orEmpty(),
                        first["modified"].orEmpty(),
                        first["folder"].orEmpty(),
                        first["profileVersion"].orEmpty(),
                        first["extractionVersion"].orEmpty(),
                        first["chunkCount"].orEmpty(),
                    ).joinToString(":")
                    val existing = existingFiles[path]
                    if (existing?.signature == signature) return@forEach
                    val chunks = DocumentIndexDatabase.chunksForFile(context, path)

                    // Replace just this file's derived knowledge. Usage remains
                    // stable because it is behavioral data, not index output.
                    db.delete("relations", "source_path=?", arrayOf(path))
                    db.delete("chunks", "file_path=?", arrayOf(path))
                    val file = ContentValues().apply {
                        put("path", path)
                        put("name", first["name"].orEmpty())
                        put("mime_type", first["type"] ?: "application/octet-stream")
                        put("folder", first["folder"].orEmpty())
                        put("modified", first["modified"]?.toLongOrNull() ?: 0L)
                        put("size", first["size"]?.toLongOrNull() ?: 0L)
                        put("summary", first["summary"].orEmpty())
                        put("category", first["category"] ?: "document")
                        put("keywords", first["keywords"].orEmpty())
                        put("content_hash", signature)
                        put("usage_count", existing?.usageCount ?: 0)
                        put("last_opened", existing?.lastOpened ?: 0L)
                    }
                    db.insertWithOnConflict(
                        "files", null, file, SQLiteDatabase.CONFLICT_REPLACE
                    )

                    chunks.forEach { chunk ->
                        db.insertWithOnConflict("chunks", null, ContentValues().apply {
                            put("file_path", path)
                            put("chunk_index", chunk["chunkIndex"]?.toIntOrNull() ?: 0)
                            put("content", chunk["content"].orEmpty())
                            put("embedding", chunk["embedding"].orEmpty())
                            put("file_embedding", chunk["fileEmbedding"].orEmpty())
                            put("headings", chunk["headings"].orEmpty())
                            put("page_start", chunk["pageStart"]?.toIntOrNull() ?: 0)
                            put("page_end", chunk["pageEnd"]?.toIntOrNull() ?: 0)
                        }, SQLiteDatabase.CONFLICT_REPLACE)
                    }

                    addEntityRelation(db, path, "category",
                        first["category"] ?: "document", "IS_A", 0.65, "classifier")
                    addEntityRelation(db, path, "folder", first["folder"].orEmpty(),
                        "LOCATED_IN", 0.8, "metadata")
                    first["keywords"].orEmpty().split('|').asSequence()
                        .map { it.trim() }.filter { it.length >= 3 }.distinct().take(16)
                        .forEach { keyword -> addEntityRelation(
                            db, path, "topic", keyword, "MENTIONS", 0.7, "local_extraction")
                        }
                }

                db.execSQL(
                    "DELETE FROM file_links WHERE from_path NOT IN (SELECT path FROM files) " +
                        "OR to_path NOT IN (SELECT path FROM files)"
                )
                db.execSQL(
                    "DELETE FROM entities WHERE id NOT IN (SELECT entity_id FROM relations)"
                )

                db.insertWithOnConflict("metadata", null, ContentValues().apply {
                    put("key", "source_stamp")
                    put("value", expectedStamp)
                }, SQLiteDatabase.CONFLICT_REPLACE)
                db.insertWithOnConflict("metadata", null, ContentValues().apply {
                    put("key", "last_sync")
                    put("value", System.currentTimeMillis().toString())
                }, SQLiteDatabase.CONFLICT_REPLACE)
                db.setTransactionSuccessful()
            } finally {
                db.endTransaction()
            }
            searchRevision.incrementAndGet()
        } finally {
            db.close()
            helper.close()
        }
    }

    fun cacheRevision(): Long = searchRevision.get()

    fun exportRelations(context: Context, paths: Set<String>): List<Map<String, String>> =
        synchronized(lock) {
            if (paths.isEmpty()) return@synchronized emptyList()
            val helper = Helper(context.applicationContext)
            val db = helper.readableDatabase
            try {
                paths.flatMap { path ->
                    db.rawQuery(
                        """SELECT e.type,e.label,r.relationship,r.weight,r.provenance
                           FROM relations r JOIN entities e ON e.id=r.entity_id
                           WHERE r.source_path=?""",
                        arrayOf(path),
                    ).use { cursor ->
                        buildList {
                            while (cursor.moveToNext()) {
                                add(mapOf(
                                    "path" to path,
                                    "entityType" to cursor.getString(0),
                                    "label" to cursor.getString(1),
                                    "relationship" to cursor.getString(2),
                                    "weight" to cursor.getDouble(3).toString(),
                                    "provenance" to cursor.getString(4),
                                ))
                            }
                        }
                    }
                }
            } finally {
                db.close()
                helper.close()
            }
        }

    private fun addEntityRelation(
        db: SQLiteDatabase,
        path: String,
        type: String,
        label: String,
        relationship: String,
        weight: Double,
        provenance: String,
    ) {
        val normalized = normalize(label)
        if (normalized.isBlank()) return
        db.insertWithOnConflict("entities", null, ContentValues().apply {
            put("type", type)
            put("label", label.trim())
            put("normalized", normalized)
        }, SQLiteDatabase.CONFLICT_IGNORE)
        val entityId = db.rawQuery(
            "SELECT id FROM entities WHERE type=? AND normalized=?",
            arrayOf(type, normalized)
        ).use { if (it.moveToFirst()) it.getLong(0) else return }
        db.insertWithOnConflict("relations", null, ContentValues().apply {
            put("source_path", path)
            put("entity_id", entityId)
            put("relationship", relationship)
            put("weight", weight)
            put("provenance", provenance)
        }, SQLiteDatabase.CONFLICT_REPLACE)
    }

    fun search(context: Context, query: String, limit: Int = 80): List<Map<String, String>> {
            // The graph is refreshed by document-index batches. Searching must
            // only read that prepared snapshot; rebuilding it here turns every
            // query into a full index synchronization on large libraries.
            val tokens = terms(query)
            val timeRange = temporalRange(query)
            if (tokens.isEmpty() && timeRange == null) return emptyList()
            val helper = Helper(context.applicationContext)
            val db = helper.readableDatabase
            try {
                data class Match(var score: Double = 0.0, val reasons: LinkedHashSet<String> = linkedSetOf())
                val matches = linkedMapOf<String, Match>()
                tokens.forEach { token ->
                    db.rawQuery(
                        """SELECT r.source_path, e.label, e.type, r.relationship, r.weight
                           FROM entities e JOIN relations r ON r.entity_id=e.id
                           WHERE e.normalized=? OR e.normalized LIKE ? OR e.normalized LIKE ?
                           LIMIT 300""",
                        arrayOf(token, "$token %", "% $token%")
                    ).use { cursor ->
                        while (cursor.moveToNext()) {
                            val path = cursor.getString(0)
                            val label = cursor.getString(1)
                            val type = cursor.getString(2)
                            val relation = cursor.getString(3)
                            val weight = cursor.getDouble(4)
                            val exact = normalize(label) == token
                            val match = matches.getOrPut(path) { Match() }
                            match.score += weight * if (exact) 1.0 else 0.72
                            match.reasons += when (relation) {
                                "LOCATED_IN" -> "Located in $label"
                                "IS_A" -> "Classified as ${label.replace('_', ' ')}"
                                else -> "Mentions $label"
                            }
                        }
                    }
                }

                if (timeRange != null) {
                    db.rawQuery(
                        """SELECT path,name,last_opened,modified FROM files
                           WHERE (last_opened>=? AND last_opened<?)
                              OR (modified*1000>=? AND modified*1000<?)
                           ORDER BY MAX(last_opened,modified*1000) DESC LIMIT 120""",
                        arrayOf(
                            timeRange.first.toString(), timeRange.second.toString(),
                            timeRange.first.toString(), timeRange.second.toString(),
                        )
                    ).use { cursor ->
                        while (cursor.moveToNext()) {
                            val match = matches.getOrPut(cursor.getString(0)) { Match() }
                            match.score += 0.9
                            match.reasons += if (cursor.getLong(2) >= timeRange.first) {
                                "Opened in the requested time"
                            } else {
                                "Modified in the requested time"
                            }
                        }
                    }
                }

                val directPaths = matches.keys.take(30)
                if (directPaths.isNotEmpty()) {
                    val placeholders = directPaths.joinToString(",") { "?" }
                    val seenPerSource = mutableMapOf<String, Int>()
                    db.rawQuery(
                        """SELECT from_path,to_path,relationship,weight FROM file_links
                           WHERE from_path IN ($placeholders)
                           ORDER BY from_path,weight DESC""",
                        directPaths.toTypedArray(),
                    ).use { cursor ->
                        while (cursor.moveToNext()) {
                            val source = cursor.getString(0)
                            val count = seenPerSource[source] ?: 0
                            if (count >= 12) continue
                            seenPerSource[source] = count + 1
                            val related = matches.getOrPut(cursor.getString(1)) { Match() }
                            related.score += cursor.getDouble(3) * 0.55
                            related.reasons += when (cursor.getString(2)) {
                                "OPENED_WITH" -> "Often opened with another matching file"
                                else -> "Related to another matching file"
                            }
                        }
                    }
                }

                data class FileRow(
                    val path: String,
                    val name: String,
                    val mimeType: String,
                    val modified: Long,
                    val size: Long,
                    val summary: String,
                    val category: String,
                    val keywords: String,
                    val lastOpened: Long,
                    val usageCount: Int,
                )
                data class ChunkRow(
                    val content: String,
                    val embedding: String,
                    val fileEmbedding: String,
                    val headings: String,
                    val pageStart: Int,
                    val pageEnd: Int,
                )
                val topEntries = matches.entries.sortedByDescending { it.value.score }.take(limit)
                if (topEntries.isEmpty()) return emptyList()
                val paths = topEntries.map { it.key }
                val placeholders = paths.joinToString(",") { "?" }
                val files = mutableMapOf<String, FileRow>()
                db.rawQuery(
                    """SELECT path,name,mime_type,modified,size,summary,category,keywords,last_opened,usage_count
                       FROM files WHERE path IN ($placeholders)""",
                    paths.toTypedArray(),
                ).use { cursor ->
                    while (cursor.moveToNext()) {
                        val path = cursor.getString(0)
                        files[path] = FileRow(
                            path = path,
                            name = cursor.getString(1),
                            mimeType = cursor.getString(2),
                            modified = cursor.getLong(3),
                            size = cursor.getLong(4),
                            summary = cursor.getString(5),
                            category = cursor.getString(6),
                            keywords = cursor.getString(7),
                            lastOpened = cursor.getLong(8),
                            usageCount = cursor.getInt(9),
                        )
                    }
                }
                val chunks = mutableMapOf<String, ChunkRow>()
                db.rawQuery(
                    """SELECT file_path,content,embedding,file_embedding,headings,page_start,page_end
                       FROM chunks WHERE file_path IN ($placeholders)
                       ORDER BY file_path,chunk_index""",
                    paths.toTypedArray(),
                ).use { cursor ->
                    while (cursor.moveToNext()) {
                        val path = cursor.getString(0)
                        if (path in chunks) continue
                        chunks[path] = ChunkRow(
                            content = cursor.getString(1).take(2400),
                            embedding = cursor.getString(2),
                            fileEmbedding = cursor.getString(3),
                            headings = cursor.getString(4),
                            pageStart = cursor.getInt(5),
                            pageEnd = cursor.getInt(6),
                        )
                    }
                }

                return topEntries.mapIndexedNotNull { graphIndex, entry ->
                    val file = files[entry.key] ?: return@mapIndexedNotNull null
                    val chunk = chunks[entry.key]
                    mutableMapOf(
                        "path" to file.path,
                        "sourcePath" to file.path,
                        "name" to file.name,
                        "type" to file.mimeType,
                        "modified" to file.modified.toString(),
                        "size" to file.size.toString(),
                        "summary" to file.summary,
                        "category" to file.category,
                        "keywords" to file.keywords,
                        "content" to chunk?.content.orEmpty(),
                        "embedding" to chunk?.embedding.orEmpty(),
                        "chunkEmbedding" to chunk?.embedding.orEmpty(),
                        "fileEmbedding" to chunk?.fileEmbedding.orEmpty(),
                        "headings" to chunk?.headings.orEmpty(),
                        "pageStart" to (chunk?.pageStart ?: 0).toString(),
                        "pageEnd" to (chunk?.pageEnd ?: 0).toString(),
                        "graphScore" to entry.value.score.coerceAtMost(4.0).toString(),
                        "graphRank" to (graphIndex + 1).toString(),
                        "graphReasons" to entry.value.reasons.take(3).joinToString("|"),
                        "lastOpened" to file.lastOpened.toString(),
                        "usageCount" to file.usageCount.toString(),
                    )
                }
            } finally {
                db.close()
                helper.close()
            }
    }

    fun mergeSearchResults(
        context: Context,
        query: String,
        keywordMatches: List<Map<String, String>>,
        semanticMatches: List<Map<String, String>> = emptyList(),
        graphMatches: List<Map<String, String>>? = null,
    ): List<Map<String, String>> {
        val merged = linkedMapOf<String, MutableMap<String, String>>()
        keywordMatches.groupBy { it["sourcePath"] ?: it["path"] }
            .forEach { (path, chunks) ->
            if (path == null) return@forEach
            merged[path] = chunks.first().toMutableMap().apply {
                put("path", path)
                // Keep matching passages across pages; overwriting by path
                // discarded earlier subject evidence from multi-chunk PDFs.
                put("content", chunks.map { it["content"].orEmpty() }
                    .filter { it.isNotBlank() }.distinct()
                    .joinToString("\n").take(32000))
                putIfAbsent("retrievalReasons", "Keyword or content match")
            }
        }
        semanticMatches.forEach { semanticRow ->
            val path = semanticRow["sourcePath"] ?: semanticRow["path"] ?: return@forEach
            val existing = merged[path]
            if (existing == null) {
                merged[path] = semanticRow.toMutableMap()
            } else {
                val excerpts = listOf(
                    existing["content"].orEmpty(),
                    semanticRow["content"].orEmpty(),
                ).filter { it.isNotBlank() }.distinct().joinToString("\n").take(32000)
                existing["content"] = excerpts
                existing.putAll(semanticRow.filterKeys { it in setOf(
                    "embedding", "chunkEmbedding", "fileEmbedding", "headings",
                    "semanticRank", "semanticScore"
                ) })
                val reasons = listOf(
                    existing["retrievalReasons"].orEmpty(),
                    semanticRow["retrievalReasons"].orEmpty(),
                ).filter { it.isNotBlank() }.joinToString("|")
                existing["retrievalReasons"] = reasons
            }
        }
        (graphMatches ?: search(context, query)).forEach { graphRow ->
            val path = graphRow["path"] ?: return@forEach
            val existing = merged[path]
            if (existing == null) {
                merged[path] = graphRow.toMutableMap().apply {
                    put("retrievalReasons", graphRow["graphReasons"].orEmpty())
                }
            } else {
                existing.putAll(graphRow.filterKeys { it in setOf(
                    "graphScore", "graphRank", "graphReasons", "lastOpened", "usageCount"
                ) })
                val reasons = listOf(
                    existing["retrievalReasons"].orEmpty(),
                    graphRow["graphReasons"].orEmpty()
                ).filter { it.isNotBlank() }.joinToString("|")
                existing["retrievalReasons"] = reasons
            }
        }
        return merged.values.toList()
    }

    fun recordUsage(context: Context, kind: String, target: String, title: String) = synchronized(lock) {
        if (target.isBlank()) return@synchronized
        val helper = Helper(context.applicationContext)
        val db = helper.writableDatabase
        val now = System.currentTimeMillis()
        try {
            db.beginTransaction()
            try {
                db.insert("usage_events", null, ContentValues().apply {
                    put("kind", kind)
                    put("target", target)
                    put("title", title)
                    put("occurred_at", now)
                })
                db.delete("usage_events", "id NOT IN (SELECT id FROM usage_events ORDER BY occurred_at DESC LIMIT 5000)", null)
                if (kind == "document") {
                    val previous = db.rawQuery(
                        """SELECT target FROM usage_events
                           WHERE kind='document' AND target<>? AND occurred_at>=?
                           ORDER BY occurred_at DESC LIMIT 1""",
                        arrayOf(target, (now - 15 * 60 * 1000L).toString())
                    ).use { if (it.moveToFirst()) it.getString(0) else null }
                    db.execSQL(
                        "UPDATE files SET usage_count=usage_count+1,last_opened=? WHERE path=?",
                        arrayOf<Any>(now, target)
                    )
                    if (previous != null) {
                        upsertLink(db, target, previous, now)
                        upsertLink(db, previous, target, now)
                    }
                }
                db.setTransactionSuccessful()
            } finally { db.endTransaction() }
            searchRevision.incrementAndGet()
        } finally {
            db.close()
            helper.close()
        }
    }

    private fun upsertLink(db: SQLiteDatabase, from: String, to: String, now: Long) {
        db.execSQL(
            """INSERT OR IGNORE INTO file_links(from_path,to_path,relationship,weight,updated_at)
               VALUES(?,?,'OPENED_WITH',0.1,?)""",
            arrayOf<Any>(from, to, now)
        )
        db.execSQL(
            """UPDATE file_links SET weight=MIN(1.0,weight+0.1),updated_at=?
               WHERE from_path=? AND to_path=? AND relationship='OPENED_WITH'""",
            arrayOf<Any>(now, from, to)
        )
    }

    fun status(context: Context): Map<String, Any> {
        val helper = Helper(context.applicationContext)
        val db = helper.readableDatabase
        return try {
            fun count(table: String): Int = db.rawQuery("SELECT COUNT(*) FROM $table", null)
                .use { if (it.moveToFirst()) it.getInt(0) else 0 }
            mapOf(
                "files" to count("files"),
                "chunks" to count("chunks"),
                "entities" to count("entities"),
                "relations" to count("relations"),
                "usageEvents" to count("usage_events"),
                "lastSync" to db.rawQuery(
                    "SELECT value FROM metadata WHERE key='last_sync'", null
                ).use { if (it.moveToFirst()) it.getString(0).toLongOrNull() ?: 0L else 0L }
            )
        } finally {
            db.close()
            helper.close()
        }
    }

    fun clear(context: Context): Boolean = synchronized(lock) {
        val cleared = context.deleteDatabase(DATABASE_NAME)
        searchRevision.incrementAndGet()
        cleared
    }
}
