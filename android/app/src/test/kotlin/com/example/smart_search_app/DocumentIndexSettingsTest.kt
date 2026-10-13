package com.example.smart_search_app

import android.app.Application
import android.content.Context
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [28, 35], application = Application::class, manifest = Config.NONE)
class DocumentIndexSettingsTest {
    private val context get() = RuntimeEnvironment.getApplication()
    private val preferences get() = context.getSharedPreferences(
        "smart_search_cache",
        Context.MODE_PRIVATE,
    )

    @Before
    fun clearSettings() {
        preferences.edit().clear().commit()
    }

    @Test
    fun fourSpeedsHaveStrictlyDescendingResourceProfiles() {
        val ultraFast = documentIndexWorkPolicy(INDEX_MODE_ULTRA_FAST, true)
        val fast = documentIndexWorkPolicy(INDEX_MODE_FAST, true)
        val balanced = documentIndexWorkPolicy(INDEX_MODE_BALANCED, true)
        val slow = documentIndexWorkPolicy(INDEX_MODE_SLOW, true)

        assertEquals(listOf(24, 12, 6, 1), listOf(
            ultraFast.batchSize,
            fast.batchSize,
            balanced.batchSize,
            slow.batchSize,
        ))
        assertTrue(ultraFast.maxBatchRuntimeMs > fast.maxBatchRuntimeMs)
        assertTrue(fast.maxBatchRuntimeMs > balanced.maxBatchRuntimeMs)
        assertTrue(balanced.maxBatchRuntimeMs > slow.maxBatchRuntimeMs)
        assertTrue(ultraFast.nextBatchDelayMs < fast.nextBatchDelayMs)
        assertTrue(fast.nextBatchDelayMs < balanced.nextBatchDelayMs)
        assertTrue(balanced.nextBatchDelayMs < slow.nextBatchDelayMs)

        assertFalse(ultraFast.requiresBatteryNotLow)
        assertFalse(ultraFast.requiresCharging)
        assertFalse(ultraFast.requiresDeviceIdle)
        assertTrue(fast.requiresBatteryNotLow)
        assertFalse(fast.requiresCharging)
        assertFalse(fast.requiresDeviceIdle)
        assertTrue(balanced.requiresCharging)
        assertTrue(balanced.requiresDeviceIdle)
        assertTrue(slow.requiresCharging)
        assertTrue(slow.requiresDeviceIdle)
    }

    @Test
    fun scheduleAffectsBalancedAndSlowButNotFasterModes() {
        val ultraFast = documentIndexWorkPolicy(INDEX_MODE_ULTRA_FAST, false)
        val fast = documentIndexWorkPolicy(INDEX_MODE_FAST, false)
        val balanced = documentIndexWorkPolicy(INDEX_MODE_BALANCED, false)
        val slow = documentIndexWorkPolicy(INDEX_MODE_SLOW, false)

        assertTrue(ultraFast.mayRunNow)
        assertTrue(ultraFast.processesHeavyFiles)
        assertTrue(fast.mayRunNow)
        assertTrue(fast.processesHeavyFiles)
        assertTrue(balanced.mayRunNow)
        assertFalse(balanced.processesHeavyFiles)
        assertFalse(slow.mayRunNow)
        assertFalse(slow.processesHeavyFiles)
    }

    @Test
    fun legacyModesMigrateToTheEquivalentFourSpeedChoice() {
        assertEquals(INDEX_MODE_FAST, normalizedDocumentIndexMode("faster"))
        assertEquals(INDEX_MODE_SLOW, normalizedDocumentIndexMode("charging_only"))
        assertEquals(INDEX_MODE_BALANCED, normalizedDocumentIndexMode("unknown"))
    }

    @Test
    fun restartAdvancesGenerationAndResetsProgressWithoutLosingPreferences() {
        preferences.edit()
            .putLong("document_index_generation", 9L)
            .putInt("document_index_cursor", 37)
            .putInt("document_index_total", 80)
            .putBoolean("document_index_complete", true)
            .putBoolean("document_index_paused_for_search", true)
            .putLong("document_index_last_scan", 1234L)
            .putString("document_index_mode", INDEX_MODE_FAST)
            .putStringSet("excluded_document_folders", setOf("Private/"))
            .commit()

        val generation = DocumentIndexer.beginFreshIndexGeneration(context)

        assertEquals(10L, generation)
        assertEquals(10L, preferences.getLong("document_index_generation", 0L))
        assertEquals(0, preferences.getInt("document_index_cursor", -1))
        assertEquals(0, preferences.getInt("document_index_total", -1))
        assertFalse(preferences.getBoolean("document_index_complete", true))
        assertFalse(preferences.getBoolean("document_index_paused_for_search", true))
        assertEquals(0L, preferences.getLong("document_index_last_scan", -1L))
        assertEquals("queued", preferences.getString("document_index_state", null))
        assertEquals(INDEX_MODE_FAST, documentIndexMode(context))
        assertEquals(
            setOf("Private/"),
            preferences.getStringSet("excluded_document_folders", emptySet()),
        )
    }
}
