package com.example.smart_search_app

import android.app.Application
import android.net.Uri
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config
import java.io.File

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [28, 35], application = Application::class, manifest = Config.NONE)
class ImportedDocumentStoreTest {
    private val context get() = RuntimeEnvironment.getApplication()

    @Test fun subjectLabelsMakeGenericAttachmentNamesDiscoverable() {
        assertEquals(
            "Data Compression notes - unit1.pdf",
            ImportedDocumentStore.importedFileName("Data Compression", "unit1.pdf"),
        )
        assertEquals(
            "Algorithms notes - unit1.pdf",
            ImportedDocumentStore.importedFileName("Algorithms", "unit1.pdf"),
        )
        assertEquals(
            "Computer Networks notes - unit2.docx",
            ImportedDocumentStore.importedFileName("Computer Networks notes", "unit2.docx"),
        )
    }

    @Test fun longAttachmentNamesKeepTheirSearchableExtension() {
        val name = ImportedDocumentStore.importedFileName(
            "Data Compression", "lecture".repeat(40) + ".pdf",
        )
        assertTrue(name.length <= 160)
        assertTrue(name.endsWith(".pdf"))
        assertTrue(isSearchableFile(name, resolvedMimeType(name, null)))
    }

    @Test fun fileUriDescriptionUsesTheAttachmentNameOnWindowsAndAndroid() {
        val source = File(context.cacheDir, "unit1.pdf").apply { writeText("lecture content") }
        try {
            val description = ImportedDocumentStore.describe(context, Uri.fromFile(source))
            assertEquals("unit1.pdf", description["name"])
            assertEquals("application/pdf", description["type"])
        } finally {
            source.delete()
        }
    }
}
