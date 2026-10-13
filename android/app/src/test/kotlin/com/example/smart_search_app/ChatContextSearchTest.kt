package com.example.smart_search_app

import android.app.Application
import android.content.Context
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config
import org.robolectric.annotation.SQLiteMode

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [28], application = Application::class, manifest = Config.NONE)
@SQLiteMode(SQLiteMode.Mode.NATIVE)
class ChatContextSearchTest {
    private val context get() = RuntimeEnvironment.getApplication()
    @Before fun setUp() {
        context.getSharedPreferences("smart_search_cache", Context.MODE_PRIVATE).edit().clear().commit()
        DocumentIndexDatabase.clear(context)
        PersonalKnowledgeGraph.clear(context)
        DocumentIndexer.clearCachesAfterImportChange()
    }
    @After fun tearDown() = setUp()

    private fun insert(index: Int, folder: String = "Documents/") {
        val source = mapOf("path" to "content://notes/$index", "name" to "Notes $index.pdf",
            "type" to "application/pdf", "folder" to folder, "size" to "100", "modified" to "1")
        val chunk = source + mapOf("content" to "Physics: light travels at c. ".repeat(200),
            "chunkIndex" to "0", "summary" to "Physics notes", "embedding" to "")
        DocumentIndexDatabase.commitFile(context, source, listOf(chunk), "", "hash-$index", 1L, true, true)
    }

    @Test fun returnsBoundedEvidenceWithoutVectorsOrFullIndex() {
        repeat(8) { insert(it) }
        val hits = ChatContextSearch.search(context, "physics")
        assertEquals(5, hits.size)
        assertEquals(5, hits.map { it["path"] }.toSet().size)
        assertTrue(hits.all { it.getValue("content").length <= 2400 })
        assertTrue(hits.all { it.keys == setOf("path", "name", "content", "retrievalReasons") })
        assertTrue(ChatContextSearch.search(context, "unmatchedgibberish").isEmpty())
    }

    @Test fun respectsExcludedFoldersEvenAfterQueryWasCached() {
        insert(0, "Private/")
        insert(1)
        assertEquals(2, ChatContextSearch.search(context, "physics").size)
        context.getSharedPreferences("smart_search_cache", Context.MODE_PRIVATE).edit()
            .putStringSet("excluded_document_folders", setOf("Private/")).commit()
        val hits = ChatContextSearch.search(context, "physics")
        assertEquals(listOf("content://notes/1"), hits.map { it["path"] })
    }

    @Test fun blankQuestionDoesNotOpenOrCreateIndex() {
        assertTrue(ChatContextSearch.search(context, "  ").isEmpty())
        assertFalse(context.getDatabasePath("document_index_v2.db").exists())
    }

    @Test fun includesPreparedKnowledgeGraphRelations() {
        insert(0, "Documents/Research/")
        PersonalKnowledgeGraph.syncFromCurrentIndex(context)
        val hits = ChatContextSearch.search(context, "research")
        assertEquals(1, hits.size)
        assertEquals("content://notes/0", hits.single()["path"])
        assertTrue(hits.single().getValue("retrievalReasons").isNotBlank())
    }
}
