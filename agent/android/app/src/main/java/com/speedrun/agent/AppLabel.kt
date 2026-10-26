package com.speedrun.agent

import android.content.pm.ApplicationInfo
import android.content.res.AssetManager
import android.content.res.Resources

/**
 * An installed app's name as the launcher and Android's "Open with" dialog show it, in the
 * device's language. Neither entry point has an app Context (the shell agent has none at all),
 * so: ApplicationInfo from the package manager service, then the label resource read from the
 * app's own APK.
 * Null, with a log line, when the hidden APIs are missing or the package is not installed.
 */
internal object AppLabel {
    fun of(packageName: String): String? = try {
        val info = applicationInfo(packageName)
        when {
            info == null -> null
            info.nonLocalizedLabel != null -> info.nonLocalizedLabel.toString()
            info.labelRes == 0 -> info.packageName
            else -> {
                val assets = AssetManager::class.java.getDeclaredConstructor().newInstance()
                AssetManager::class.java.getMethod("addAssetPath", String::class.java).invoke(assets, info.sourceDir)
                val system = Resources.getSystem()
                @Suppress("DEPRECATION")
                val res = Resources(assets, system.displayMetrics, system.configuration)
                res.getText(info.labelRes).toString().also { assets.close() }
            }
        }
    } catch (t: Throwable) {
        AgentLog.e("could not read the label of $packageName", cause(t))
        null
    }

    /** IPackageManager.getApplicationInfo(name, flags, userId): flags is a long since Android 13. */
    private fun applicationInfo(packageName: String): ApplicationInfo? {
        val pm = Class.forName("android.app.ActivityThread").getMethod("getPackageManager").invoke(null)
            ?: return null
        val method = pm.javaClass.methods.first {
            it.name == "getApplicationInfo" && it.parameterCount == 3 && it.parameterTypes[0] == String::class.java
        }
        val flags: Any = if (method.parameterTypes[1] == java.lang.Long.TYPE) 0L else 0
        return method.invoke(pm, packageName, flags, 0) as ApplicationInfo?
    }
}
