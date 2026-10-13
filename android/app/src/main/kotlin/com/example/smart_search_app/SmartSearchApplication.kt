package com.example.smart_search_app

import android.app.Application
import androidx.work.Configuration

/** Keep WorkManager's database and recovery work off the cold-launch path. */
class SmartSearchApplication : Application(), Configuration.Provider {
    override val workManagerConfiguration: Configuration
        get() = Configuration.Builder().build()
}
