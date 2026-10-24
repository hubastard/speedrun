package com.speedrun.agent

import android.content.pm.PackageInfo
import android.content.pm.PermissionInfo
import android.os.IBinder

/**
 * The permissions an app requests and their state, straight from the system services: what
 * `dumpsys package` prints, without dumping ~250 KB of text to read a few lines (launchApp
 * checks them on every launch). Null, with a log line, when the hidden APIs are missing; the
 * host then falls back to dumpsys.
 */
internal object Permissions {
    class Requested(val name: String, val runtime: Boolean, val granted: Boolean, val appOpMode: Int)

    private const val GET_PERMISSIONS = 0x1000 // PackageManager.GET_PERMISSIONS
    private const val NO_APP_OP = 255
    private val runtimeByName = HashMap<String, Boolean>()

    fun of(packageName: String): List<Requested>? = try {
        val info = packageInfo(packageName)
        if (info == null) emptyList() else {
            val names = info.requestedPermissions ?: emptyArray()
            val flags = info.requestedPermissionsFlags ?: IntArray(names.size)
            names.mapIndexed { i, name ->
                val granted = flags[i] and PackageInfo.REQUESTED_PERMISSION_GRANTED != 0
                val mode = if (name == "android.permission.MANAGE_EXTERNAL_STORAGE") {
                    appOpMode("android:manage_external_storage", info.applicationInfo?.uid ?: -1, packageName)
                } else NO_APP_OP
                Requested(name, isRuntime(name), granted, mode)
            }
        }
    } catch (t: Throwable) {
        AgentLog.e("could not read the permissions of $packageName", cause(t))
        null
    }

    /** IPackageManager.getPackageInfo(name, flags, userId): flags is a long since Android 13. */
    private fun packageInfo(packageName: String): PackageInfo? {
        val pm = Class.forName("android.app.ActivityThread").getMethod("getPackageManager").invoke(null)
            ?: return null
        val method = pm.javaClass.methods.first {
            it.name == "getPackageInfo" && it.parameterCount == 3 && it.parameterTypes[0] == String::class.java
        }
        val flags: Any = if (method.parameterTypes[1] == java.lang.Long.TYPE) GET_PERMISSIONS.toLong() else GET_PERMISSIONS
        return method.invoke(pm, packageName, flags, 0) as PackageInfo?
    }

    /** A runtime ("dangerous") permission: the only kind `pm grant`/`revoke` change. */
    private fun isRuntime(name: String): Boolean = runtimeByName.getOrPut(name) {
        val info = permissionInfo(name) ?: return@getOrPut false
        info.protection == PermissionInfo.PROTECTION_DANGEROUS
    }

    /** IPermissionManager (Android 11+) or IPackageManager: getPermissionInfo(name, pkg, flags). */
    private fun permissionInfo(name: String): PermissionInfo? {
        for (service in listOf("permissionmgr", "package")) {
            val binder = try {
                Class.forName("android.os.ServiceManager").getMethod("getService", String::class.java)
                    .invoke(null, service) as IBinder? ?: continue
            } catch (t: Throwable) { continue }
            val stub = if (service == "permissionmgr") "android.permission.IPermissionManager\$Stub" else "android.content.pm.IPackageManager\$Stub"
            val manager = try {
                Class.forName(stub).getMethod("asInterface", IBinder::class.java).invoke(null, binder) ?: continue
            } catch (t: Throwable) { continue }
            val method = manager.javaClass.methods.firstOrNull {
                it.name == "getPermissionInfo" && it.parameterCount == 3 && it.parameterTypes[0] == String::class.java
            } ?: continue
            return method.invoke(manager, name, "com.android.shell", 0) as PermissionInfo?
        }
        return null
    }

    /** IAppOpsService.checkOperation: 0 allowed, 1 ignored, 2 errored (deny), 3 default. */
    private fun appOpMode(op: String, uid: Int, packageName: String): Int {
        if (uid < 0) return NO_APP_OP
        val code = Class.forName("android.app.AppOpsManager").getMethod("strOpToOp", String::class.java).invoke(null, op) as Int
        val binder = Class.forName("android.os.ServiceManager").getMethod("getService", String::class.java)
            .invoke(null, "appops") as IBinder
        val service = Class.forName("com.android.internal.app.IAppOpsService\$Stub")
            .getMethod("asInterface", IBinder::class.java).invoke(null, binder)
        val check = service.javaClass.getMethod("checkOperation", Int::class.javaPrimitiveType, Int::class.javaPrimitiveType, String::class.java)
        return check.invoke(service, code, uid, packageName) as Int
    }
}
