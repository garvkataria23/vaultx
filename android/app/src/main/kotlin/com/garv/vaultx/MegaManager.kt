package com.garv.vaultx

import android.content.Context
import android.content.SharedPreferences
import android.util.Base64
import android.util.Log
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import nz.mega.sdk.MegaApi
import nz.mega.sdk.MegaError
import nz.mega.sdk.MegaNode
import nz.mega.sdk.MegaRequest
import nz.mega.sdk.MegaRequestListener
import java.io.File

class MegaManager private constructor(private val appContext: Context) {

    companion object {
        private const val TAG = "MegaManager"
        private const val CHANNEL = "vaultx/mega"
        private const val BACKUP_FOLDER = "VaultX_Backups"
        private const val PREFS_NAME = "mega_secure_prefs"
        private const val KEY_SESSION = "mega_session"
        private const val KEY_EMAIL = "mega_email"
        private const val APP_KEY = "VaultX"
        private const val USER_AGENT = "VaultX/1.0"

        @Volatile
        private var instance: MegaManager? = null

        fun getInstance(context: Context): MegaManager {
            return instance ?: synchronized(this) {
                instance ?: MegaManager(context.applicationContext).also { instance = it }
            }
        }
    }

    private var megaClient: MegaClient? = null
    private var sessionEmail: String? = null
    private lateinit var securePrefs: SharedPreferences

    fun setupChannel(flutterEngine: FlutterEngine) {
        val masterKey = MasterKey.Builder(appContext)
            .setKeyScheme(MasterKey.KeyScheme.AES256_GCM)
            .build()
        securePrefs = EncryptedSharedPreferences.create(
            appContext,
            PREFS_NAME,
            masterKey,
            EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
            EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM
        )

        sessionEmail = securePrefs.getString(KEY_EMAIL, null)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                try {
                    handleMethodCall(call, result)
                } catch (t: Throwable) {
                    Log.e(TAG, "MEGA METHOD FAILED: ${call.method}", t)
                    result.success(mapOf<String, Any>(
                        "success" to false,
                        "error" to "MEGA INIT FAILED: ${t.message.orEmpty()}"
                    ))
                }
            }
    }

    private fun handleMethodCall(call: MethodCall, result: MethodChannel.Result) {
        Log.d(TAG, "Method called: ${call.method}")
        when (call.method) {
            "login" -> handleLogin(call, result)
            "logout" -> handleLogout(result)
            "restoreSession" -> handleRestoreSession(result)
            "fetchNodes" -> handleFetchNodes(result)
            "listBackupFiles" -> handleListBackupFiles(result)
            "ensureBackupFolder" -> handleEnsureBackupFolder(result)
            "uploadFile" -> handleUploadFile(call, result)
            "downloadFile" -> handleDownloadFile(call, result)
            "deleteNode" -> handleDeleteNode(call, result)
            "getAccountQuota" -> handleGetAccountQuota(result)
            "getSessionEmail" -> result.success(sessionEmail)
            "isLoggedIn" -> result.success(megaClient?.megaApi?.isLoggedIn() != 0)
            else -> result.notImplemented()
        }
    }

    private val client: MegaClient
        get() = initializeMega()

    private fun initializeMega(): MegaClient {
        megaClient?.let { return it }
        return try {
            MegaClient.getInstance(appContext, APP_KEY, USER_AGENT).also {
                megaClient = it
            }
        } catch (e: UnsatisfiedLinkError) {
            Log.e("VaultX", "MEGA INIT FAILED", e)
            throw IllegalStateException("MEGA NATIVE LIBRARY MISSING: libmega.so", e)
        } catch (t: Throwable) {
            Log.e("VaultX", "MEGA INIT FAILED", t)
            throw IllegalStateException("MEGA INIT FAILED: ${t.message.orEmpty()}", t)
        }
    }

    // ── Login ─────────────────────────────────────────────────────────────

    private fun handleLogin(call: MethodCall, result: MethodChannel.Result) {
        val email = call.argument<String>("email") ?: ""
        val password = call.argument<String>("password") ?: ""

        try {
            client.onLoginResult = { success, error ->
                if (success) {
                    sessionEmail = email
                    val session = client.megaApi.dumpSession()
                    securePrefs.edit().putString(KEY_SESSION, session ?: "").apply()
                    securePrefs.edit().putString(KEY_EMAIL, email).apply()
                    Log.i(TAG, "Session saved for $email")
                }
                result.success(mapOf<String, Any>("success" to success, "error" to (error ?: "")))
            }
            client.login(email, password)
        } catch (e: Exception) {
            Log.e(TAG, "Login error: ${e.message}")
            result.success(mapOf<String, Any>("success" to false, "error" to (e.message ?: "Unknown error")))
        }
    }

    // ── Logout ────────────────────────────────────────────────────────────

    private fun handleLogout(result: MethodChannel.Result) {
        try {
            client.onLogoutResult = { _, _ ->
                sessionEmail = null
                securePrefs.edit().remove(KEY_SESSION).remove(KEY_EMAIL).apply()
                result.success(mapOf<String, Any>("success" to true))
            }
            client.logout()
        } catch (e: Exception) {
            sessionEmail = null
            securePrefs.edit().remove(KEY_SESSION).remove(KEY_EMAIL).apply()
            result.success(mapOf<String, Any>("success" to true))
        }
    }

    // ── Restore Session ───────────────────────────────────────────────────

    private fun handleRestoreSession(result: MethodChannel.Result) {
        try {
            val session = securePrefs.getString(KEY_SESSION, null)
            if (session.isNullOrBlank()) {
                Log.w(TAG, "No saved session to restore")
                result.success(mapOf<String, Any>("success" to false, "error" to "No saved session"))
                return
            }
            val email = securePrefs.getString(KEY_EMAIL, null)
            sessionEmail = email

            // Check if already logged in before trying restore
            if (megaClient?.megaApi?.isLoggedIn() != 0) {
                Log.i(TAG, "Already logged in, reusing existing session")
                // Already logged in — just ensure nodes are fetched
                if (!client.megaReady) {
                    client.fetchNodes()
                    client.onLoginResult = { success, error ->
                        if (success) Log.i(TAG, "Nodes fetched for $email")
                        result.success(mapOf<String, Any>("success" to success, "error" to (error ?: "")))
                    }
                } else {
                    result.success(mapOf<String, Any>("success" to true, "error" to ""))
                }
                return
            }

            client.onLoginResult = { success, error ->
                if (success) {
                    Log.i(TAG, "Session restored for $email")
                    // fetchNodes is already called by the request listener after fastLogin
                } else {
                    Log.e(TAG, "Session restore failed: $error")
                    // Do NOT clear saved session — it may be a transient network issue
                }
                result.success(mapOf<String, Any>("success" to success, "error" to (error ?: "")))
            }
            client.megaApi.fastLogin(session)
        } catch (e: Exception) {
            Log.e(TAG, "restoreSession error: ${e.message}")
            result.success(mapOf<String, Any>("success" to false, "error" to (e.message ?: "Unknown error")))
        }
    }

    // ── Fetch Nodes ───────────────────────────────────────────────────────

    private fun handleFetchNodes(result: MethodChannel.Result) {
        try {
            client.onLoginResult = { success, error ->
                result.success(mapOf<String, Any>("success" to success, "error" to (error ?: "")))
            }
            client.fetchNodes()
        } catch (e: Exception) {
            Log.e(TAG, "fetchNodes error: ${e.message}")
            result.success(mapOf<String, Any>("success" to false, "error" to (e.message ?: "Unknown error")))
        }
    }

    // ── List Backup Files ─────────────────────────────────────────────────

    private fun handleListBackupFiles(result: MethodChannel.Result) {
        try {
            val root = client.megaApi.rootNode
            if (root == null) {
                result.success(mapOf<String, Any>("success" to true, "files" to emptyList<Map<String, Any>>()))
                return
            }

            val backupFolder = client.megaApi.getChildNode(root, BACKUP_FOLDER)
            if (backupFolder == null) {
                result.success(mapOf<String, Any>("success" to true, "files" to emptyList<Map<String, Any>>()))
                return
            }

            val children = client.megaApi.getChildren(backupFolder)
            val files = mutableListOf<Map<String, Any>>()
            for (i in 0 until children.size()) {
                val child = children.get(i)
                files.add(mapOf(
                    "name" to child.name,
                    "handle" to child.base64Handle,
                    "size" to client.megaApi.getSize(child),
                    "modificationTime" to (child.modificationTime / 1000)
                ))
            }
            result.success(mapOf<String, Any>("success" to true, "files" to files))
        } catch (e: Exception) {
            Log.e(TAG, "listBackupFiles error: ${e.message}")
            result.success(mapOf<String, Any>("success" to false, "error" to (e.message ?: "Unknown error"), "files" to emptyList<Map<String, Any>>()))
        }
    }

    // ── Ensure Backup Folder ──────────────────────────────────────────────

    private fun handleEnsureBackupFolder(result: MethodChannel.Result) {
        try {
            val root = client.megaApi.rootNode
            if (root == null) {
                result.success(mapOf<String, Any>("success" to false, "error" to "Root node not available"))
                return
            }

            val existing = client.megaApi.getChildNode(root, BACKUP_FOLDER)
            if (existing != null) {
                result.success(mapOf<String, Any>("success" to true, "handle" to existing.base64Handle, "created" to false))
                return
            }

            client.onCreateFolderResult = { success, error, node ->
                result.success(mapOf<String, Any>(
                    "success" to success,
                    "handle" to (node?.base64Handle ?: ""),
                    "error" to (error ?: ""),
                    "created" to true
                ))
            }
            client.createFolder(BACKUP_FOLDER, root)
        } catch (e: Exception) {
            Log.e(TAG, "ensureBackupFolder error: ${e.message}")
            result.success(mapOf<String, Any>("success" to false, "error" to (e.message ?: "Unknown error")))
        }
    }

    // ── Upload File ───────────────────────────────────────────────────────

    private fun handleUploadFile(call: MethodCall, result: MethodChannel.Result) {
        try {
            val dataBase64 = call.argument<String>("data") ?: ""
            val fileName = call.argument<String>("fileName") ?: ""
            if (dataBase64.isBlank() || fileName.isBlank()) {
                result.success(mapOf<String, Any>("success" to false, "error" to "Missing data or fileName"))
                return
            }

            val bytes = Base64.decode(dataBase64, Base64.NO_WRAP)
            val tempDir = File(appContext.cacheDir, "mega_uploads").also { it.mkdirs() }
            val tempFile = File(tempDir, fileName)
            tempFile.writeBytes(bytes)

            client.onUploadResult = { success, error, _ ->
                tempFile.delete()
                result.success(mapOf<String, Any>("success" to success, "error" to (error ?: "")))
            }

            val root = client.megaApi.rootNode
            if (root == null) {
                tempFile.delete()
                result.success(mapOf<String, Any>("success" to false, "error" to "Root node not available"))
                return
            }

            val backupFolder = client.megaApi.getChildNode(root, BACKUP_FOLDER)
            client.uploadFile(tempFile.absolutePath, backupFolder)
        } catch (e: Exception) {
            Log.e(TAG, "uploadFile error: ${e.message}")
            result.success(mapOf<String, Any>("success" to false, "error" to (e.message ?: "Unknown error")))
        }
    }

    // ── Download File ─────────────────────────────────────────────────────

    private fun handleDownloadFile(call: MethodCall, result: MethodChannel.Result) {
        try {
            val handleStr = call.argument<String>("handle") ?: ""
            if (handleStr.isBlank()) {
                result.success(mapOf<String, Any>("success" to false, "error" to "Missing handle"))
                return
            }

            val nodeHandle = MegaApi.base64ToHandle(handleStr)
            val node = client.megaApi.getNodeByHandle(nodeHandle)
            if (node == null) {
                result.success(mapOf<String, Any>("success" to false, "error" to "Node not found"))
                return
            }

            val tempDir = File(appContext.cacheDir, "mega_downloads").also { it.mkdirs() }
            val tempFile = File(tempDir, "${node.handle}.bin")

            client.onDownloadResult = { success, error, path ->
                if (success && path != null) {
                    try {
                        val data = File(path).readBytes()
                        val dataBase64 = Base64.encodeToString(data, Base64.NO_WRAP)
                        result.success(mapOf<String, Any>("success" to true, "data" to dataBase64))
                    } catch (e: Exception) {
                        result.success(mapOf<String, Any>("success" to false, "error" to "Failed to read downloaded file: ${e.message}"))
                    }
                } else {
                    result.success(mapOf<String, Any>("success" to false, "error" to (error ?: "Download failed")))
                }
                tempFile.delete()
            }
            client.downloadFile(node.handle, tempFile.absolutePath)
        } catch (e: Exception) {
            Log.e(TAG, "downloadFile error: ${e.message}")
            result.success(mapOf<String, Any>("success" to false, "error" to (e.message ?: "Unknown error")))
        }
    }

    // ── Delete Node ───────────────────────────────────────────────────────

    private fun handleDeleteNode(call: MethodCall, result: MethodChannel.Result) {
        try {
            val handleStr = call.argument<String>("handle") ?: ""
            if (handleStr.isBlank()) {
                result.success(mapOf<String, Any>("success" to false, "error" to "Missing handle"))
                return
            }

            val nodeHandle = MegaApi.base64ToHandle(handleStr)
            val node = client.megaApi.getNodeByHandle(nodeHandle)
            if (node == null) {
                result.success(mapOf<String, Any>("success" to false, "error" to "Node not found"))
                return
            }

            val deleteListener = object : MegaRequestListener() {
                override fun onRequestStart(api: nz.mega.sdk.MegaApi, request: MegaRequest) {}
                override fun onRequestUpdate(api: nz.mega.sdk.MegaApi, request: MegaRequest) {}
                override fun onRequestFinish(api: nz.mega.sdk.MegaApi, request: MegaRequest, e: MegaError) {
                    if (request.type == MegaRequest.TYPE_REMOVE) {
                        val ok = e.errorCode == MegaError.API_OK
                        result.success(mapOf<String, Any>(
                            "success" to ok,
                            "error" to if (!ok) "Delete failed: ${e.errorString} (code=${e.errorCode})" else ""
                        ))
                        api.removeRequestListener(this)
                    }
                }
                override fun onRequestTemporaryError(api: nz.mega.sdk.MegaApi, request: MegaRequest, e: MegaError) {}
            }
            client.megaApi.addRequestListener(deleteListener)
            client.megaApi.remove(node)
        } catch (e: Exception) {
            Log.e(TAG, "deleteNode error: ${e.message}")
            result.success(mapOf<String, Any>("success" to false, "error" to (e.message ?: "Unknown error")))
        }
    }

    // ── Account Quota ─────────────────────────────────────────────────────

    private fun handleGetAccountQuota(result: MethodChannel.Result) {
        try {
            val accountListener = object : MegaRequestListener() {
                override fun onRequestStart(api: nz.mega.sdk.MegaApi, request: MegaRequest) {}
                override fun onRequestUpdate(api: nz.mega.sdk.MegaApi, request: MegaRequest) {}
                override fun onRequestFinish(api: nz.mega.sdk.MegaApi, request: MegaRequest, e: MegaError) {
                    if (request.type == MegaRequest.TYPE_ACCOUNT_DETAILS) {
                        if (e.errorCode == MegaError.API_OK) {
                            try {
                                val details = request.megaAccountDetails
                                result.success(mapOf<String, Any>(
                                    "success" to true,
                                    "usedBytes" to details.storageUsed,
                                    "totalBytes" to details.storageMax
                                ))
                            } catch (ex: Exception) {
                                result.success(mapOf<String, Any>("success" to false, "error" to "Failed to parse account details", "usedBytes" to 0, "totalBytes" to 0))
                            }
                        } else {
                            result.success(mapOf<String, Any>("success" to false, "error" to "Account details failed: ${e.errorString} (code=${e.errorCode})", "usedBytes" to 0, "totalBytes" to 0))
                        }
                        api.removeRequestListener(this)
                    }
                }
                override fun onRequestTemporaryError(api: nz.mega.sdk.MegaApi, request: MegaRequest, e: MegaError) {}
            }
            client.megaApi.addRequestListener(accountListener)
            client.megaApi.getAccountDetails()
        } catch (e: Exception) {
            Log.e(TAG, "getAccountQuota error: ${e.message}")
            result.success(mapOf<String, Any>("success" to false, "error" to (e.message ?: "Unknown error"), "usedBytes" to 0, "totalBytes" to 0))
        }
    }

    fun onDestroy() {}
}
