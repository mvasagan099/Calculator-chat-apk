package app.calculatorspace.calculator_messenger

import android.content.Context
import android.content.pm.PackageManager
import java.security.MessageDigest
import android.os.Build
import android.os.Process

object InstalledAppIdentity {
    @Suppress("DEPRECATION")
    fun read(context: Context): Map<String, Any> {
        val info = context.packageManager.getPackageInfo(context.packageName, PackageManager.GET_SIGNING_CERTIFICATES)
        val signers = info.signingInfo?.apkContentsSigners
        require(signers != null && signers.size == 1)
        val digest = MessageDigest.getInstance("SHA-256").digest(signers[0].toByteArray())
            .joinToString("") { "%02X".format(it.toInt() and 0xff) }
        val allowed = if (Process.is64Bit()) listOf("arm64-v8a", "x86_64") else listOf("armeabi-v7a")
        val abi = Build.SUPPORTED_ABIS.first { it in allowed }
        return mapOf("package_id" to context.packageName, "build_number" to info.longVersionCode, "certificate_sha256" to digest, "abi" to abi)
    }
}
