package app.calculatorspace.calculator_messenger

import android.content.ComponentName
import android.content.Context
import android.content.pm.PackageManager

/**
 * Launcher aliases change only the Android launcher presentation.
 * MainActivity remains enabled for app links, calls and private PIN security.
 */
object LauncherIconSwitcher {
    private val aliases = linkedMapOf(
        "classic" to "LauncherClassic",
        "midnight" to "LauncherMidnight",
        "graphite" to "LauncherGraphite",
        "sunrise" to "LauncherSunrise",
    )
    private fun component(context: Context, name: String) =
        ComponentName(context.packageName, context.packageName + "." + name)

    fun current(context: Context): String {
        val pm = context.packageManager
        for ((id, name) in aliases) {
            val state = pm.getComponentEnabledSetting(component(context, name))
            if (id == "classic" && state == PackageManager.COMPONENT_ENABLED_STATE_DEFAULT) return id
            if (state == PackageManager.COMPONENT_ENABLED_STATE_ENABLED) return id
        }
        return "classic"
    }

    fun set(context: Context, selected: String): String {
        require(aliases.containsKey(selected)) { "Unknown calculator icon" }
        val pm = context.packageManager
        val chosen = component(context, aliases.getValue(selected))
        // Enable the new launcher entry BEFORE removing the prior one.
        pm.setComponentEnabledSetting(chosen, PackageManager.COMPONENT_ENABLED_STATE_ENABLED, PackageManager.DONT_KILL_APP)
        for ((id, name) in aliases) {
            if (id != selected) {
                pm.setComponentEnabledSetting(component(context, name),
                    PackageManager.COMPONENT_ENABLED_STATE_DISABLED, PackageManager.DONT_KILL_APP)
            }
        }
        return selected
    }
}
