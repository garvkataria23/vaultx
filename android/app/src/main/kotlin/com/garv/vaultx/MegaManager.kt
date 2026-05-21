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
        private const val KEY_BACKUP_HANDLE = "mega_backup_handle"
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
    private var cachedBackupFolder: MegaNode? = null
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
            cachedBackupFolder = null
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
        cachedBackupFolder = null
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
        cachedBackupFolder = null
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

            // Always fetch nodes before listing to ensure we see the latest uploads
            client.onLoginResult = { success, _ ->
                client.onLoginResult = null
                if (success) {
                    enumerateWithRetry(result, 0)
                } else {
                    Log.e(TAG, "fetchNodes failed during listBackupFiles")
                    result.success(mapOf<String, Any>("success" to false, "error" to "Failed to refresh nodes", "files" to emptyList<Map<String, Any>>()))
                }
            }
            Log.i(TAG, "FETCHING NODES for listBackupFiles...")
            client.fetchNodes()
        } catch (e: Exception) {
            Log.e(TAG, "listBackupFiles error: ${e.message}")
            result.success(mapOf<String, Any>("success" to false, "error" to (e.message ?: "Unknown error"), "files" to emptyList<Map<String, Any>>()))
        }
    }

    private fun enumerateWithRetry(result: MethodChannel.Result, attempt: Int) {
        val oldFolder = cachedBackupFolder
        val oldHash = if (oldFolder != null) System.identityHashCode(oldFolder) else 0
        val oldCount = if (oldFolder != null) client.megaApi.getNumChildren(oldFolder) else -1

        // Force fresh resolution from SDK by bypassing cache
        cachedBackupFolder = null
        val backupFolder = resolveBackupFolder()
        val freshHash = if (backupFolder != null) System.identityHashCode(backupFolder) else 0
        
        if (backupFolder == null) {
            Log.w(TAG, "BACKUP_FOLDER NOT FOUND (attempt $attempt)")
            if (attempt < 3) {
                Log.i(TAG, "RETRYING FOLDER RESOLUTION IN 2 SECONDS...")
                Handler(Looper.getMainLooper()).postDelayed({
                    enumerateWithRetry(result, attempt + 1)
                }, 2000L)
            } else {
                result.success(mapOf<String, Any>("success" to true, "files" to emptyList<Map<String, Any>>()))
            }
            return
        }

        val numChildren = client.megaApi.getNumChildren(backupFolder)
        val children = client.megaApi.getChildren(backupFolder)
        val childCount = children.size()
        
        Log.i(TAG, "ENUMERATION ATTEMPT $attempt:")
        Log.i(TAG, "CACHED NODE: hash=$oldHash children=$oldCount")
        Log.i(TAG, "FRESH NODE: hash=$freshHash children=$numChildren parent=${backupFolder.parentHandle} type=${backupFolder.type}")
        Log.i(TAG, "GET_CHILDREN: size=$childCount")
        Log.i(TAG, "FOLDER MODIFIED: ${backupFolder.modificationTime / 1000}")

        // Check if root children changed too
        val root = client.megaApi.rootNode
        if (root != null) {
            Log.i(TAG, "ROOT CHILD COUNT: ${client.megaApi.getNumChildren(root)}")
        }

        if (childCount == 0 && attempt < 3) {
            Log.i(TAG, "CHILDREN NOT FOUND IN CACHE, RETRYING ENUMERATION IN 2 SECONDS...")
            Handler(Looper.getMainLooper()).postDelayed({
                enumerateWithRetry(result, attempt + 1)
            }, 2000L)
            return
        }

        val files = mutableListOf<Map<String, Any>>()
        for (i in 0 until childCount) {
            val child = children.get(i)
            val name = child.name ?: "unnamed"
            val type = when(child.type) {
                MegaNode.TYPE_FILE -> "FILE"
                MegaNode.TYPE_FOLDER -> "FOLDER"
                else -> "OTHER(${child.type})"
            }
            Log.i(TAG, "CHILD ENUMERATED: name=\"$name\" type=$type handle=${child.base64Handle} size=${client.megaApi.getSize(child)}")
            
            files.add(mapOf(
                "name" to name,
                "handle" to child.base64Handle,
                "size" to client.megaApi.getSize(child),
                "modificationTime" to (child.modificationTime / 1000)
            ))
        }
        
        Log.i(TAG, "FINAL DETECTED BACKUP FILES COUNT: ${files.size}")
        result.success(mapOf<String, Any>("success" to true, "files" to files))
    }

    private fun resolveBackupFolder(): MegaNode? {
        // 1. Check in-memory cache
        cachedBackupFolder?.let {
            try {
                if (it.base64Handle.isNotBlank()) {
                    Log.i(TAG, "BACKUP FOLDER FOUND (in-memory cache) handle=${it.base64Handle}")
                    return it
                }
            } catch (_: Exception) {
                cachedBackupFolder = null
            }
        }

        // 2. Check persistent storage
        val storedHandle = securePrefs.getString(KEY_BACKUP_HANDLE, null)
        if (!storedHandle.isNullOrBlank()) {
            try {
                val handle = MegaApi.base64ToHandle(storedHandle)
                val node = client.megaApi.getNodeByHandle(handle)
                if (node != null && node.name == BACKUP_FOLDER) {
                    cachedBackupFolder = node
                    Log.i(TAG, "BACKUP FOLDER FOUND (persisted handle) handle=$storedHandle")
                    return node
                }
                Log.w(TAG, "Persisted handle invalid or node missing: $storedHandle")
            } catch (e: Exception) {
                Log.e(TAG, "Error resolving stored handle: ${e.message}")
            }
        }

        // 3. Search in root
        val root = client.megaApi.rootNode
        if (root != null) {
            val found = findChildByName(root, BACKUP_FOLDER)
            if (found != null) {
                val handle = found.base64Handle
                securePrefs.edit().putString(KEY_BACKUP_HANDLE, handle).apply()
                cachedBackupFolder = found
                Log.i(TAG, "BACKUP FOLDER FOUND (root search) handle=$handle")
                return found
            }
        }

        Log.w(TAG, "BACKUP FOLDER NOT RESOLVED")
        return null
    }

    private fun findChildByName(parent: MegaNode, targetName: String): MegaNode? {
        val targetClean = targetName.trim().lowercase()
        val children = client.megaApi.getChildren(parent)
        val parentName = parent.name ?: "ROOT"
        Log.i(TAG, "LOOKING IN \"$parentName\" - CHILD COUNT: ${children.size()}")
        
        for (i in 0 until children.size()) {
            val child = children.get(i)
            val childName = child.name ?: "unnamed"
            Log.i(TAG, "CHILD FOUND: name=\"$childName\" handle=${child.base64Handle}")
            
            if (childName.trim().lowercase() == targetClean) {
                Log.i(TAG, "MATCHED TARGET: \"$childName\" handle=${child.base64Handle}")
                return child
            }
        }
        return null
    }

    // ── Ensure Backup Folder ──────────────────────────────────────────────

    private fun handleEnsureBackupFolder(result: MethodChannel.Result) {
        try {
            if (!client.megaReady) {
                Log.w(TAG, "MEGA NOT READY for ensureBackupFolder")
                result.success(mapOf<String, Any>("success" to false, "error" to "MEGA NOT READY"))
                return
            }

            val existing = resolveBackupFolder()
            if (existing != null) {
                result.success(mapOf<String, Any>("success" to true, "handle" to existing.base64Handle, "created" to false))
                return
            }

            Log.w(TAG, "BACKUP FOLDER MISSING - REFRESHING NODES...")
            client.onLoginResult = { success, _ ->
                client.onLoginResult = null
                if (success) {
                    val refreshed = resolveBackupFolder()
                    if (refreshed != null) {
                        result.success(mapOf<String, Any>("success" to true, "handle" to refreshed.base64Handle, "created" to false))
                    } else {
                        Log.w(TAG, "AUTO CREATING BACKUP FOLDER")
                        client.onCreateFolderResult = { createSuccess, createError, node ->
                            client.onCreateFolderResult = null
                            if (createSuccess && node != null) {
                                cachedBackupFolder = node
                                securePrefs.edit().putString(KEY_BACKUP_HANDLE, node.base64Handle).apply()
                                Log.i(TAG, "BACKUP FOLDER CREATED handle=${node.base64Handle}")
                            }
                            result.success(mapOf<String, Any>(
                                "success" to createSuccess,
                                "handle" to (node?.base64Handle ?: ""),
                                "error" to (createError ?: ""),
                                "created" to true
                            ))
                        }
                        val root = client.megaApi.rootNode
                        if (root != null) {
                            client.createFolder(BACKUP_FOLDER, root)
                        } else {
                            result.success(mapOf<String, Any>("success" to false, "error" to "Root node null after fetchNodes"))
                        }
                    }
                } else {
                    result.success(mapOf<String, Any>("success" to false, "error" to "Failed to refresh nodes", "created" to false))
                }
            }
            client.fetchNodes()
        } catch (e: Exception) {
            Log.e(TAG, "ensureBackupFolder error: ${e.message}")
            result.success(mapOf<String, Any>("success" to false, "error" to (e.message ?: "Unknown error"), "created" to false))
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

            val backupFolder = resolveBackupFolder()

            if (backupFolder != null) {
                Log.i(TAG, "STARTING UPLOAD to handle=${backupFolder.base64Handle}")
                client.uploadFile(localPath, backupFolder)
            } else {
                Log.w(TAG, "BACKUP FOLDER MISSING - REFRESHING NODES...")
                client.onLoginResult = { success, _ ->
                    client.onLoginResult = null
                    if (success) {
                        val newBackupFolder = resolveBackupFolder()
                        if (newBackupFolder != null) {
                            Log.i(TAG, "STARTING UPLOAD to handle=${newBackupFolder.base64Handle}")
                            client.uploadFile(localPath, newBackupFolder)
                        } else {
                            Log.w(TAG, "AUTO CREATING BACKUP FOLDER")
                            client.onCreateFolderResult = { createSuccess, createError, folderNode ->
                                client.onCreateFolderResult = null
                                if (createSuccess && folderNode != null) {
                                    cachedBackupFolder = folderNode
                                    securePrefs.edit().putString(KEY_BACKUP_HANDLE, folderNode.base64Handle).apply()
                                    Log.i(TAG, "BACKUP FOLDER CREATED handle=${folderNode.base64Handle}")
                                    Log.i(TAG, "STARTING UPLOAD")
                                    client.uploadFile(localPath, folderNode)
                                } else {
                                    tempFile.delete()
                                    result.success(mapOf<String, Any>("success" to false, "error" to "Failed to create backup folder: ${createError ?: "unknown"}"))
                                }
                            }
                            val newRoot = client.megaApi.rootNode
                            if (newRoot != null) {
                                client.createFolder(BACKUP_FOLDER, newRoot)
                            } else {
                                tempFile.delete()
                                result.success(mapOf<String, Any>("success" to false, "error" to "Root node null after fetchNodes"))
                            }
                        }
                    } else {
                        Log.e(TAG, "REFRESH NODES FAILED DURING UPLOAD")
                        tempFile.delete()
                        result.success(mapOf<String, Any>("success" to false, "error" to "Failed to refresh nodes for upload"))
                    }
                }
                client.fetchNodes()
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
            client.onAccountDetailsResult = { success, error, usedBytes, totalBytes ->
                client.onAccountDetailsResult = null
                result.success(mapOf<String, Any>(
                    "success" to success,
                    "usedBytes" to usedBytes,
                    "totalBytes" to totalBytes,
                    "error" to (error ?: "")
                ))
            }
            client.megaApi.getAccountDetails()
        } catch (e: Exception) {
            Log.e(TAG, "getAccountQuota error: ${e.message}")
            result.success(mapOf<String, Any>("success" to false, "error" to (e.message ?: "Unknown error"), "usedBytes" to 0, "totalBytes" to 0))
        }
    }

    fun onDestroy() {}
}
