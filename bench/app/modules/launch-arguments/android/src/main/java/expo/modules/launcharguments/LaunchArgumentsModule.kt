package expo.modules.launcharguments

import expo.modules.kotlin.modules.Module
import expo.modules.kotlin.modules.ModuleDefinition

// launchApp's arguments arrive as the launch intent's extras.
class LaunchArgumentsModule : Module() {
  override fun definition() = ModuleDefinition {
    Name("LaunchArguments")

    Function("get") {
      val extras = appContext.currentActivity?.intent?.extras
      val out = mutableMapOf<String, String>()
      extras?.keySet()?.forEach { key ->
        @Suppress("DEPRECATION")
        out[key] = extras.get(key)?.toString() ?: ""
      }
      out
    }
  }
}
