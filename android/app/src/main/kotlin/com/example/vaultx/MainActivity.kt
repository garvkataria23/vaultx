package com.example.vaultx

import android.content.pm.ApplicationInfo
import android.content.pm.PackageManager
import android.content.ComponentName
import android.os.Build
import android.os.Debug
import android.view.KeyEvent
import android.view.WindowManager
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64

class MainActivity : FlutterFragmentActivity() {
    private val keyAlias = "vaultx_device_bound_key"
    private var volumeChannel: MethodChannel? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        volumeChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "vaultx/volume_keys")
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "vaultx/security").setMethodCallHandler { call, result ->
            when (call.method) {
                "enableSecureWindow" -> {
                    window.setFlags(WindowManager.LayoutParams.FLAG_SECURE, WindowManager.LayoutParams.FLAG_SECURE)
                    result.success(true)
                }
                "devicePosture" -> result.success(
                    mapOf(
                        "platform" to "android-${Build.VERSION.SDK_INT}",
                        "rooted" to isProbablyRooted(),
                        "debuggable" to isDebuggable()
                    )
                )
                "keystoreReady" -> {
                    ensureKeystoreKey()
                    result.success(true)
                }
                "keystoreReset" -> {
                    resetKeystoreKey()
                    result.success(true)
                }
                "keystoreWrap" -> {
                    val plain = call.argument<String>("plain")
                    if (plain == null) {
                        result.error("vaultx_missing_plain", "Missing plaintext payload", null)
                    } else {
                        result.success(wrapWithKeystore(plain))
                    }
                }
                "keystoreUnwrap" -> {
                    val wrapped = call.argument<String>("wrapped")
                    if (wrapped == null) {
                        result.error("vaultx_missing_wrapped", "Missing wrapped payload", null)
                    } else {
                        result.success(unwrapWithKeystore(wrapped))
                    }
                }
                "setDecoyLauncherEnabled" -> {
                    val enabled = call.argument<Boolean>("enabled") ?: false
                    setDecoyLauncherEnabled(enabled)
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun setDecoyLauncherEnabled(enabled: Boolean) {
        val pm = packageManager
        val vault = ComponentName(packageName, "$packageName.VaultXLauncher")
        val calc = ComponentName(packageName, "$packageName.CalculatorLauncher")
        pm.setComponentEnabledSetting(
            calc,
            if (enabled) PackageManager.COMPONENT_ENABLED_STATE_ENABLED
            else PackageManager.COMPONENT_ENABLED_STATE_DISABLED,
            PackageManager.DONT_KILL_APP
        )
        pm.setComponentEnabledSetting(
            vault,
            if (enabled) PackageManager.COMPONENT_ENABLED_STATE_DISABLED
            else PackageManager.COMPONENT_ENABLED_STATE_ENABLED,
            PackageManager.DONT_KILL_APP
        )
    }

    private fun ensureKeystoreKey(): SecretKey {
        val keyStore = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        if (!keyStore.containsAlias(keyAlias)) {
            val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
            val spec = KeyGenParameterSpec.Builder(
                keyAlias,
                KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT
            )
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setRandomizedEncryptionRequired(true)
                .build()
            generator.init(spec)
            generator.generateKey()
        }
        return (keyStore.getEntry(keyAlias, null) as KeyStore.SecretKeyEntry).secretKey
    }

    private fun resetKeystoreKey() {
        val keyStore = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        if (keyStore.containsAlias(keyAlias)) {
            keyStore.deleteEntry(keyAlias)
        }
        ensureKeystoreKey()
    }

    private fun wrapWithKeystore(plainBase64: String): Map<String, String> {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, ensureKeystoreKey())
        val encrypted = cipher.doFinal(Base64.decode(plainBase64, Base64.NO_WRAP))
        return mapOf(
            "iv" to Base64.encodeToString(cipher.iv, Base64.NO_WRAP),
            "ct" to Base64.encodeToString(encrypted, Base64.NO_WRAP)
        )
    }

    private fun unwrapWithKeystore(wrappedJson: String): String {
        val parts = wrappedJson.split(".")
        val iv = Base64.decode(parts[0], Base64.NO_WRAP)
        val ct = Base64.decode(parts[1], Base64.NO_WRAP)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, ensureKeystoreKey(), GCMParameterSpec(128, iv))
        return Base64.encodeToString(cipher.doFinal(ct), Base64.NO_WRAP)
    }

    private fun isDebuggable(): Boolean {
        return (applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE) != 0 || Debug.isDebuggerConnected()
    }

    private fun isProbablyRooted(): Boolean {
        val paths = arrayOf(
            "/system/app/Superuser.apk",
            "/sbin/su",
            "/system/bin/su",
            "/system/xbin/su",
            "/data/local/xbin/su",
            "/data/local/bin/su",
            "/system/sd/xbin/su",
            "/system/bin/failsafe/su",
            "/data/local/su",
            "/su/bin/su"
        )
        return paths.any { File(it).exists() }
    }

    override fun dispatchKeyEvent(event: KeyEvent): Boolean {
        if (event.action == KeyEvent.ACTION_DOWN) {
            when (event.keyCode) {
                KeyEvent.KEYCODE_VOLUME_UP -> {
                    volumeChannel?.invokeMethod("volumeKey", mapOf("key" to "up"))
                }
                KeyEvent.KEYCODE_VOLUME_DOWN -> {
                    volumeChannel?.invokeMethod("volumeKey", mapOf("key" to "down"))
                }
            }
        }
        return super.dispatchKeyEvent(event)
    }
}
