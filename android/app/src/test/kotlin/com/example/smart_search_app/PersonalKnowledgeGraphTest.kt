package com.example.smart_search_app

import android.app.Application
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config
import org.robolectric.annotation.SQLiteMode

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [28, 35], application = Application::class, manifest = Config.NONE)
@SQLiteMode(SQLiteMode.Mode.NATIVE)
class PersonalKnowledgeGraphTest {
    private val context get() = RuntimeEnvironment.getApplication()

    @Before fun setUp() {
        PersonalKnowledgeGraph.clear(context)
        DocumentIndexDatabase.clear(context)
    }

    @After fun tearDown() {
        PersonalKnowledgeGraph.clear(context)
        DocumentIndexDatabase.clear(context)
    }

    private fun writeRows(vararg rows: Map<String, Any>) {
        DocumentIndexDatabase.clear(context)
        rows.forEach { raw ->
            val row = raw.mapValues { it.value.toString() }
            val path = row["sourcePath"] ?: row["path"].orEmpty()
            val source = row + ("path" to path)
            DocumentIndexDatabase.commitFile(
                context,
                source,
                listOf(source),
                row["fileEmbedding"].orEmpty(),
                row["hash"].orEmpty(),
                1L,
                true,
                true,
            )
        }
    }

    private fun row(
        path: String,
        name: String,
        keywords: String,
        modified: Long = 1,
    ) = mapOf<String, Any>(
        "path" to "$path#0",
        "sourcePath" to path,
        "name" to name,
        "type" to "application/pdf",
        "folder" to "Documents/Research/",
        "modified" to modified,
        "size" to 1200,
        "summary" to "Private local summary for $name",
        "category" to "research",
        "keywords" to keywords,
        "content" to "Locally extracted content for $name",
        "hash" to "hash-$modified-$name",
        "profileVersion" to "1",
        "extractionVersion" to "1",
        "chunkIndex" to 0,
    )

    @Test fun mergingChunksRetainsSubjectEvidenceFromEarlierPages() {
        val hits = PersonalKnowledgeGraph.mergeSearchResults(context, "CUDA notes", listOf(
            mapOf("sourcePath" to "content://paper", "path" to "chunk-0",
                "name" to "GPU paper.pdf", "content" to "CUDA memory optimization"),
            mapOf("sourcePath" to "content://paper", "path" to "chunk-1",
                "name" to "GPU paper.pdf", "content" to "Lecture notes and references")
        ))
        assertEquals(1, hits.size)
        assertEquals("content://paper", hits.single()["path"])
        assertTrue(hits.single().getValue("content").contains("CUDA"))
        assertTrue(hits.single().getValue("content").contains("Lecture notes"))
    }

    @Test fun topicAndFolderRelationsAreExplainable() {
        writeRows(row("content://cuda", "CUDA notes.pdf", "cuda|gpu|kernel"))
        PersonalKnowledgeGraph.syncFromCurrentIndex(context)

        val hit = PersonalKnowledgeGraph.search(context, "cuda").single()
        assertEquals("CUDA notes.pdf", hit["name"])
        assertTrue(hit.getValue("graphReasons").contains("Mentions CUDA", ignoreCase = true))
        assertEquals(1, PersonalKnowledgeGraph.status(context)["files"])
    }

    @Test fun searchReadsTheLastIndexedGraphSnapshot() {
        val cuda = row("content://cuda", "CUDA notes.pdf", "cuda|gpu|kernel")
        writeRows(cuda)
        PersonalKnowledgeGraph.syncFromCurrentIndex(context)

        // Simulate a document-index change that has not completed its next
        // background graph-sync step. Querying must not perform that sync.
        writeRows(cuda, row("content://aadhar", "Aadhar card.pdf", "aadhar|identity", 2))

        assertTrue(PersonalKnowledgeGraph.search(context, "aadhar").isEmpty())
        assertEquals(1, PersonalKnowledgeGraph.status(context)["files"])

        PersonalKnowledgeGraph.syncFromCurrentIndex(context)
        assertEquals("Aadhar card.pdf", PersonalKnowledgeGraph.search(context, "aadhar")
            .single()["name"])
    }

    @Test fun incrementalSyncPreservesUsageAndLearnsCoOpenedFiles() {
        val cuda = row("content://cuda", "CUDA notes.pdf", "cuda|gpu")
        val results = row("content://results", "Results.csv", "benchmark")
        writeRows(cuda, results)
        PersonalKnowledgeGraph.syncFromCurrentIndex(context)
        PersonalKnowledgeGraph.recordUsage(
            context, "document", "content://cuda", "CUDA notes.pdf"
        )
        PersonalKnowledgeGraph.recordUsage(
            context, "document", "content://results", "Results.csv"
        )

        writeRows(cuda, results, row("content://new", "New.pdf", "unrelated", 2))
        PersonalKnowledgeGraph.syncFromCurrentIndex(context)

        val hits = PersonalKnowledgeGraph.search(context, "cuda")
        val direct = hits.first { it["path"] == "content://cuda" }
        val related = hits.first { it["path"] == "content://results" }
        assertEquals("1", direct["usageCount"])
        assertTrue(related.getValue("graphReasons").contains("opened with", ignoreCase = true))
        assertEquals(3, PersonalKnowledgeGraph.status(context)["files"])
    }
}
