package com.garv.vaultx

import android.app.Activity
import android.app.Application
import android.content.Context
import android.content.SharedPreferences
import android.os.Bundle
import android.os.Handler
import android.os.Looper
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

class MegaManager private constructor(private val appContext: Context) : Application.ActivityLifecycleCallbacks {

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
    private lateinit var channel: MethodChannel

    @Volatile
    private var isRestoring = false
    private var pendingResult: MethodChannel.Result? = null
    private val restoreLock = Any()

    private var startedActivities = 0
    private var isLifecycleRegistered = false

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

        // Register lifecycle callbacks for app resume detection
        if (!isLifecycleRegistered) {
            (appContext as? Application)?.registerActivityLifecycleCallbacks(this)
            isLifecycleRegistered = true
        }

        sessionEmail = securePrefs.getString(KEY_EMAIL, null)
        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
        channel.setMethodCallHandler { call, result ->
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

        // AUTO RESTORE ON STARTUP
        // If a saved session exists, immediately begin restoring in the background.
        // Any subsequent method channel call to restoreSession will attach to this
        // in-progress restore rather than starting a duplicate.
        if (securePrefs.contains(KEY_SESSION)) {
            Log.i(TAG, "SESSION FOUND")
            Log.i(TAG, "AUTO RESTORE START")
            triggerRestore(null)
        }
    }

    override fun onActivityStarted(activity: Activity) {
        val wasBackground = startedActivities == 0
        startedActivities++
        if (wasBackground) {
            Log.i(TAG, "APP RESUME FROM BACKGROUND")
            if (securePrefs.contains(KEY_SESSION)) {
                if (megaClient?.megaReady != true) {
                    Log.i(TAG, "AUTO RESTORE START")
                    triggerRestore(null)
                }
            }
        }
    }

    override fun onActivityStopped(activity: Activity) {
        startedActivities--
    }

    override fun onActivityCreated(activity: Activity, savedInstanceState: Bundle?) {}
    override fun onActivityResumed(activity: Activity) {}
    override fun onActivityPaused(activity: Activity) {}
    override fun onActivitySaveInstanceState(activity: Activity, outState: Bundle) {}
    override fun onActivityDestroyed(activity: Activity) {}

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
            "isLoggedIn" -> {
                val loggedIn = megaClient?.megaApi?.isLoggedIn() ?: 0
                result.success(loggedIn != 0)
            }
            "isReady" -> {
                val ready = megaClient?.megaReady == true && megaClient?.megaApi?.rootNode != null
                result.success(ready)
            }
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
                client.onLoginResult = null
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
                Log.i(TAG, "Session cleared on explicit logout")
                result.success(mapOf<String, Any>("success" to true))
            }
            client.logout()
        } catch (e: Exception) {
            sessionEmail = null
            securePrefs.edit().remove(KEY_SESSION).remove(KEY_EMAIL).apply()
            Log.i(TAG, "Session cleared on explicit logout (fallback)")
            result.success(mapOf<String, Any>("success" to true))
        }
    }

    // ── Restore Session ───────────────────────────────────────────────────

    /// Called from the method channel (Dart) for on-demand restore.
    /// If a restore is already in progress (from startup or app resume),
    /// the result callback is queued and will be notified on completion.
    private fun handleRestoreSession(result: MethodChannel.Result) {
        val session = securePrefs.getString(KEY_SESSION, null)
        if (session.isNullOrBlank()) {
            Log.i(TAG, "No saved session — cannot restore")
            result.success(mapOf("success" to false, "error" to "No saved session"))
            return
        }
        triggerRestore(result)
    }

    /// Core entry point for all restore attempts.
    /// [result] may be null when called from auto-restore (startup/app-resume).
    /// If a restore is already running, [result] is queued.
    private fun triggerRestore(result: MethodChannel.Result?) {
        synchronized(restoreLock) {
            if (isRestoring) {
                if (result != null) {
                    pendingResult = result
                    Log.d(TAG, "Restore in progress — result queued for notification")
                }
                return
            }
            pendingResult = result
            isRestoring = true
        }
        performRestore(0)
    }

    private fun performRestore(retryCount: Int) {
        val session = securePrefs.getString(KEY_SESSION, null) ?: ""
        if (session.isBlank()) {
            completeRestore(success = false, error = "No saved session")
            return
        }

        val email = securePrefs.getString(KEY_EMAIL, null)
        sessionEmail = email

        if (retryCount > 0) {
            Log.i(TAG, "RESTORE FAILED RETRYING  (attempt ${retryCount + 1})")
        }

        // Case 1: Already logged in and fully ready
        if (client.megaApi.isLoggedIn() != 0) {
            if (client.megaReady && client.megaApi.rootNode != null) {
                Log.i(TAG, "ROOT NODE READY")
                Log.i(TAG, "AUTO LOGIN SUCCESS")
                completeRestore(success = true, error = null)
                return
            }
            // Case 2: Logged in but nodes not yet fetched
            Log.i(TAG, "FETCH NODES START")
            client.onLoginResult = { success, error ->
                client.onLoginResult = null
                if (success && client.megaReady && client.megaApi.rootNode != null) {
                    Log.i(TAG, "ROOT NODE READY")
                    Log.i(TAG, "AUTO LOGIN SUCCESS")
                    completeRestore(success = true, error = null)
                } else {
                    retryOrFail(retryCount, error ?: "Nodes not ready after fetchNodes")
                }
            }
            client.fetchNodes()
            return
        }

        // Case 3: Not logged in — perform fastLogin with saved session
        // No custom listener needed: MegaClient's global request listener handles
        // TYPE_LOGIN → auto-fetchNodes → TYPE_FETCH_NODES → onLoginResult automatically.
        Log.i(TAG, "FAST LOGIN START")
        client.onLoginResult = { success, error ->
            client.onLoginResult = null
            if (success && client.megaReady && client.megaApi.rootNode != null) {
                Log.i(TAG, "ROOT NODE READY")
                Log.i(TAG, "AUTO LOGIN SUCCESS")
                completeRestore(success = true, error = null)
            } else {
                // API_ESID (session invalid) — don't retry
                if (error?.contains("API_ESID") == true || error?.contains("code=-15") == true) {
                    Log.i(TAG, "KEEPING SAVED SESSION  (session invalid — user must re-login)")
                    completeRestore(success = false, error = error)
                } else {
                    retryOrFail(retryCount, error ?: "Nodes not ready after fast login")
                }
            }
        }
        client.megaApi.fastLogin(session)
    }

    private fun retryOrFail(retryCount: Int, errorMsg: String) {
        if (retryCount < 2) {
            Log.i(TAG, "RESTORE FAILED RETRYING  (attempt ${retryCount + 1}, error=$errorMsg)")
            val delayMs = if (retryCount == 0) 2000L else 5000L
            Handler(Looper.getMainLooper()).postDelayed({
                performRestore(retryCount + 1)
            }, delayMs)
        } else {
            Log.i(TAG, "KEEPING SAVED SESSION  (restore exhausted 3 attempts)")
            completeRestore(success = false, error = errorMsg)
        }
    }

    private fun completeRestore(success: Boolean, error: String?) {
        isRestoring = false
        val result: MethodChannel.Result?
        synchronized(restoreLock) {
            result = pendingResult
            pendingResult = null
        }
        if (success) {
            Log.i(TAG, "AUTO LOGIN SUCCESS")
        } else {
            Log.i(TAG, "KEEPING SAVED SESSION  (session+email preserved)")
        }
        // Only notify if someone is waiting on a result
        result?.success(mapOf("success" to success, "error" to (error ?: "")))
    }

    // ── Fetch Nodes ───────────────────────────────────────────────────────

    private fun handleFetchNodes(result: MethodChannel.Result) {
        try {
            client.onLoginResult = { success, error ->
                client.onLoginResult = null
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
            if (!client.megaReady) {
                Log.w(TAG, "MEGA NOT READY for listBackupFiles")
                result.success(mapOf<String, Any>("success" to false, "error" to "MEGA NOT READY", "files" to emptyList<Map<String, Any>>()))
                return
            }

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
            if (!client.megaReady) {
                Log.w(TAG, "MEGA NOT READY for ensureBackupFolder")
                result.success(mapOf<String, Any>("success" to false, "error" to "MEGA NOT READY"))
                return
            }

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

            if (!client.megaReady) {
                Log.w(TAG, "MEGA NOT READY for uploadFile")
                result.success(mapOf<String, Any>("success" to false, "error" to "MEGA NOT READY"))
                return
            }

            val bytes = Base64.decode(dataBase64, Base64.NO_WRAP)
            val tempDir = File(appContext.cacheDir, "mega_uploads").also { it.mkdirs() }
            val tempFile = File(tempDir, fileName)
            tempFile.writeBytes(bytes)
            val localPath = tempFile.absolutePath

            client.onUploadProgress = { path, uploaded, total ->
                if (path == localPath) {
                    appContext.mainExecutor.execute {
                        channel.invokeMethod("onUploadProgress", mapOf(
                            "fileName" to fileName,
                            "uploaded" to uploaded,
                            "total" to total
                        ))
                    }
                }
            }

            client.onUploadResult = { path, success, error, _ ->
                if (path == localPath) {
                    tempFile.delete()
                    client.onUploadProgress = null
                    client.onUploadResult = null
                    if (success) {
                        Log.i(TAG, "UPLOAD COMPLETE: $fileName")
                    } else {
                        Log.e(TAG, "UPLOAD FAILED: $fileName - $error")
                    }
                    result.success(mapOf<String, Any>("success" to success, "error" to (error ?: "")))
                }
            }

            val root = client.megaApi.rootNode
            if (root == null) {
                tempFile.delete()
                result.success(mapOf<String, Any>("success" to false, "error" to "Root node not available"))
                return
            }
            Log.i(TAG, "ROOT NODE READY")

            val backupFolder = client.megaApi.getChildNode(root, BACKUP_FOLDER)
            if (backupFolder == null) {
                Log.w(TAG, "BACKUP FOLDER MISSING")
                client.onLoginResult = { success, _ ->
                    client.onLoginResult = null
                    if (success) {
                        val newRoot = client.megaApi.rootNode
                        val newBackupFolder = if (newRoot != null) client.megaApi.getChildNode(newRoot, BACKUP_FOLDER) else null
                        if (newBackupFolder != null) {
                            Log.i(TAG, "BACKUP FOLDER FOUND")
                            Log.i(TAG, "STARTING UPLOAD")
                            client.uploadFile(localPath, newBackupFolder)
                        } else {
                            Log.w(TAG, "AUTO CREATING BACKUP FOLDER")
                            client.onCreateFolderResult = { createSuccess, createError, folderNode ->
                                client.onCreateFolderResult = null
                                if (createSuccess && folderNode != null) {
                                    Log.i(TAG, "BACKUP FOLDER CREATED")
                                    Log.i(TAG, "STARTING UPLOAD")
                                    client.uploadFile(localPath, folderNode)
                                } else {
                                    tempFile.delete()
                                    result.success(mapOf<String, Any>("success" to false, "error" to "Failed to create backup folder: ${createError ?: "unknown"}"))
                                }
                            }
                            client.createFolder(BACKUP_FOLDER, newRoot ?: root)
                        }
                    } else {
                        Log.e(TAG, "REFRESH NODES FAILED DURING UPLOAD")
                        tempFile.delete()
                        result.success(mapOf<String, Any>("success" to false, "error" to "Failed to refresh nodes for upload"))
                    }
                }
                client.fetchNodes()
            } else {
                Log.i(TAG, "BACKUP FOLDER FOUND")
                Log.i(TAG, "STARTING UPLOAD")
                client.uploadFile(localPath, backupFolder)
            }
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
            val localPath = tempFile.absolutePath

            client.onDownloadResult = { path, success, error, downloadPath ->
                if (path == localPath) {
                    client.onDownloadResult = null
                    if (success && downloadPath != null) {
                        try {
                            val data = File(downloadPath).readBytes()
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
            }
            client.downloadFile(node.handle, localPath)
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
