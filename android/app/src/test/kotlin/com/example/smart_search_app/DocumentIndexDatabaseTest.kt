package com.example.smart_search_app

import android.app.Application
import android.content.Context
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config
import org.robolectric.annotation.SQLiteMode
import java.io.File

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [28], application = Application::class, manifest = Config.NONE)
@SQLiteMode(SQLiteMode.Mode.NATIVE)
class DocumentIndexDatabaseTest {
    private val context get() = RuntimeEnvironment.getApplication()
    private val preferences get() = context.getSharedPreferences(
        "smart_search_cache", Context.MODE_PRIVATE
    )

    @Before fun setUp() {
        DocumentIndexDatabase.clear(context)
        preferences.edit().putInt("document_index_storage_version", 2).commit()
    }

    @After fun tearDown() {
        DocumentIndexDatabase.clear(context)
        File(context.filesDir, "document_index.json").delete()
        File(context.filesDir, "document_index.json.tmp").delete()
    }

    private fun source(path: String = "content://book") = mapOf(
        "path" to path,
        "name" to "Book.pdf",
        "type" to "application/pdf",
        "modified" to "10",
        "size" to "5000",
        "folder" to "Documents/",
    )

    private fun chunk(index: Int, content: String) = source() + mapOf(
        "chunkIndex" to index.toString(),
        "content" to content,
        "bytes" to content.length.toString(),
        "embedding" to "AQI=",
        "chunkEmbedding" to "AQI=",
        "summary" to "Book section $index",
        "keywords" to "book|section",
        "category" to "document",
        "profileVersion" to "6",
        "extractionVersion" to "7",
        "pageStart" to (index * 5 + 1).toString(),
        "pageEnd" to ((index + 1) * 5).toString(),
    )

    @Test fun storageUpgradeDiscardsJsonAndStartsAtZero() {
        DocumentIndexDatabase.clear(context)
        preferences.edit()
            .putInt("document_index_storage_version", 0)
            .putInt("document_index_cursor", 826)
            .putString("document_index_state", "paused_memory")
            .commit()
        val legacy = File(context.filesDir, "document_index.json")
        legacy.writeText("[{\"name\":\"must-not-import.pdf\"}]")

        assertTrue(DocumentIndexDatabase.ensureFreshStorage(context))

        assertFalse(legacy.exists())
        assertEquals(0, preferences.getInt("document_index_cursor", -1))
        assertEquals("queued", preferences.getString("document_index_state", ""))
        assertTrue(DocumentIndexDatabase.representativeRows(context).isEmpty())
    }

    @Test fun multiSectionDocumentCommitsIncrementallyWithoutLosingEarlierPages() {
        DocumentIndexDatabase.commitFile(
            context, source(), listOf(chunk(0, "introduction and syllabus")),
            "AQI=", "book-hash", 3L, true, false,
        )
        DocumentIndexDatabase.commitFile(
            context, source(), listOf(chunk(1, "advanced CUDA memory chapter")),
            "AQI=", "book-hash", 3L, false, true,
        )

        val chunks = DocumentIndexDatabase.chunksForFile(context, "content://book")
        assertEquals(2, chunks.size)
        assertEquals("introduction and syllabus", chunks[0]["content"])
        assertEquals("advanced CUDA memory chapter", chunks[1]["content"])
        assertEquals(1, DocumentIndexDatabase.countCompleteFiles(context, 3L))
        assertEquals("content://book", LocalDocumentSearch.search(context, "CUDA").single()["path"])
    }

    @Test fun eachCommitAddsRowsWithoutCreatingOrRewritingJson() {
        // The former JSON implementation failed on the connected phone at
        // 826 files. Cross that boundary with independent SQLite commits.
        repeat(1_000) { index ->
            val path = "content://image/$index"
            val file = source(path) + mapOf("name" to "Image $index.jpg", "type" to "image/jpeg")
            val section = chunk(0, "recognized text number $index") + file
            DocumentIndexDatabase.commitFile(
                context, file, listOf(section), "AQI=", "hash-$index", 5L, true, true,
            )
        }

        assertEquals(1_000, DocumentIndexDatabase.countIndexedFiles(context, 5L))
        assertEquals(1_000, DocumentIndexDatabase.countCompleteFiles(context, 5L))
        assertFalse(File(context.filesDir, "document_index.json").exists())
    }
}
