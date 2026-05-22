package com.garv.vaultx

import android.content.Context
import android.util.Log
import nz.mega.sdk.MegaApi
import nz.mega.sdk.MegaError
import nz.mega.sdk.MegaNode
import nz.mega.sdk.MegaRequest
import nz.mega.sdk.MegaRequestListener
import nz.mega.sdk.MegaTransfer
import nz.mega.sdk.MegaTransferListener
import java.io.File

class MegaClient private constructor(
    context: Context,
    appKey: String,
    userAgent: String
) {
    val megaApi: MegaApi = MegaApi(appKey, userAgent, context.cacheDir.absolutePath)

    var onLoginResult: ((Boolean, String?) -> Unit)? = null
    var onUploadResult: ((String, Boolean, String?, Long?) -> Unit)? = null
    var onUploadProgress: ((String, Long, Long) -> Unit)? = null
    var onDownloadResult: ((String, Boolean, String?, String?) -> Unit)? = null
    var onDownloadProgress: ((String, Long, Long) -> Unit)? = null
    var onLogoutResult: ((Boolean, String?) -> Unit)? = null
    var onTransferStart: ((String, Long) -> Unit)? = null
    var onCreateFolderResult: ((Boolean, String?, MegaNode?) -> Unit)? = null
    var onAccountDetailsResult: ((Boolean, String?, Long, Long) -> Unit)? = null
    var onNodesUpdate: (() -> Unit)? = null

    var megaReady: Boolean = false
        private set

    companion object {
        private const val TAG = "MegaClient"

        @Volatile
        private var instance: MegaClient? = null

        fun getInstance(
            context: Context, appKey: String, userAgent: String
        ): MegaClient {
            return instance ?: synchronized(this) {
                instance ?: MegaClient(
                    context.applicationContext, appKey, userAgent
                ).also { instance = it }
            }
        }

        fun resetInstance() {
            synchronized(this) {
                instance?.destroy()
                instance = null
            }
        }
    }

    private val requestListener = object : MegaRequestListener() {
        override fun onRequestStart(api: MegaApi, request: MegaRequest) {}

        override fun onRequestFinish(api: MegaApi, request: MegaRequest, e: MegaError) {
            when (request.type) {
                MegaRequest.TYPE_LOGIN -> {
                    if (e.errorCode == MegaError.API_OK) {
                        Log.i(TAG, "LOGIN SUCCESS - FETCHING NODES")
                        megaReady = false
                        megaApi.fetchNodes()
                    } else {
                        Log.e(TAG, "LOGIN FAILED: ${e.errorString} (code=${e.errorCode})")
                        onLoginResult?.invoke(false, "Login failed: ${e.errorString} (code=${e.errorCode})")
                    }
                }
                MegaRequest.TYPE_FETCH_NODES -> {
                    val success = e.errorCode == MegaError.API_OK
                    val root = megaApi.rootNode
                    val actuallyReady = success && root != null
                    
                    megaReady = actuallyReady
                    if (actuallyReady) {
                        Log.i(TAG, "FETCH NODES SUCCESS - MEGA READY TRUE (root ok)")
                        onNodesUpdate?.invoke()
                    } else {
                        Log.e(TAG, "FETCH NODES NOT READY: success=$success, root=${root != null}")
                    }
                    
                    onLoginResult?.invoke(
                        actuallyReady,
                        if (!success) "fetchNodes failed: ${e.errorString} (code=${e.errorCode})" 
                        else if (root == null) "Root node null after fetchNodes" 
                        else null
                    )
                }
                MegaRequest.TYPE_LOGOUT -> {
                    megaReady = false
                    Log.i(TAG, "Logout completed")
                    onLogoutResult?.invoke(
                        e.errorCode == MegaError.API_OK,
                        if (e.errorCode != MegaError.API_OK) "Logout failed: ${e.errorString} (code=${e.errorCode})" else null
                    )
                }
                MegaRequest.TYPE_CREATE_FOLDER -> {
                    val ok = e.errorCode == MegaError.API_OK
                    val folder = if (ok) megaApi.getNodeByHandle(request.nodeHandle) else null
                    onCreateFolderResult?.invoke(
                        ok,
                        if (!ok) "Create folder failed: ${e.errorString} (code=${e.errorCode})" else null,
                        folder
                    )
                }
                MegaRequest.TYPE_ACCOUNT_DETAILS -> {
                    val ok = e.errorCode == MegaError.API_OK
                    if (ok) {
                        try {
                            val details = request.megaAccountDetails
                            onAccountDetailsResult?.invoke(true, null, details.storageUsed, details.storageMax)
                        } catch (ex: Exception) {
                            onAccountDetailsResult?.invoke(false, "Failed to parse account details: ${ex.message}", 0, 0)
                        }
                    } else {
                        onAccountDetailsResult?.invoke(false, "Account details failed: ${e.errorString} (code=${e.errorCode})", 0, 0)
                    }
                }
            }
        }

        override fun onRequestUpdate(api: MegaApi, request: MegaRequest) {}

        override fun onRequestTemporaryError(api: MegaApi, request: MegaRequest, e: MegaError) {
            Log.w(TAG, "Request temporary error: ${e.errorString} (code=${e.errorCode})")
        }
    }

    private fun errorName(code: Int): String = when (code) {
        MegaError.API_EACCESS -> "API_EACCESS"
        MegaError.API_ENOENT -> "API_ENOENT"
        MegaError.API_EARGS -> "API_EARGS"
        MegaError.API_EEXIST -> "API_EEXIST"
        MegaError.API_EKEY -> "API_EKEY"
        MegaError.API_EBLOCKED -> "API_EBLOCKED"
        MegaError.API_ETOOMANY -> "API_ETOOMANY"
        MegaError.API_ESID -> "API_ESID"
        MegaError.API_ETEMPUNAVAIL -> "API_ETEMPUNAVAIL"
        MegaError.API_ERANGE -> "API_ERANGE"
        MegaError.API_EINTERNAL -> "API_EINTERNAL"
        else -> "API_UNKNOWN($code)"
    }

    private val transferListener = object : MegaTransferListener() {
        override fun onTransferStart(api: MegaApi, transfer: MegaTransfer) {
            val fileName = transfer.fileName ?: "unknown"
            val totalBytes = transfer.totalBytes
            Log.i(TAG, "onTransferStart: fileName=$fileName totalBytes=$totalBytes")
            onTransferStart?.invoke(fileName, totalBytes)
        }

        override fun onTransferFinish(api: MegaApi, transfer: MegaTransfer, e: MegaError) {
            val fileName = transfer.fileName ?: "unknown"
            val success = e.errorCode == MegaError.API_OK
            val errName = errorName(e.errorCode)
            val errString = e.errorString ?: "Unknown error"
            val transferPath = transfer.path ?: ""

            if (success) {
                Log.i(TAG, "onTransferFinish SUCCESS: $fileName at $transferPath")
            } else {
                Log.e(TAG, "onTransferFinish FAILURE: $fileName - $errName: $errString at $transferPath")
            }

            when (transfer.type) {
                MegaTransfer.TYPE_UPLOAD -> {
                    onUploadResult?.invoke(
                        transferPath,
                        success,
                        if (!success) "$errName: $errString" else null,
                        if (success) transfer.nodeHandle else null
                    )
                }
                MegaTransfer.TYPE_DOWNLOAD -> {
                    onDownloadResult?.invoke(
                        transferPath,
                        success,
                        if (!success) "$errName: $errString" else null,
                        if (success) transfer.path else null
                    )
                }
            }
        }

        override fun onTransferUpdate(api: MegaApi, transfer: MegaTransfer) {
            val fileName = transfer.fileName ?: "unknown"
            val transferPath = transfer.path ?: ""
            val pct = if (transfer.totalBytes > 0) {
                (transfer.transferredBytes * 100 / transfer.totalBytes)
            } else 0
            
            when (transfer.type) {
                MegaTransfer.TYPE_UPLOAD -> {
                    if (pct % 20 == 0L) {
                        Log.d(TAG, "Upload progress: $fileName $pct%")
                    }
                    onUploadProgress?.invoke(transferPath, transfer.transferredBytes, transfer.totalBytes)
                }
                MegaTransfer.TYPE_DOWNLOAD -> {
                    Log.d(TAG, "Download progress: $fileName $pct%")
                    onDownloadProgress?.invoke(transferPath, transfer.transferredBytes, transfer.totalBytes)
                }
            }
        }

        override fun onTransferTemporaryError(api: MegaApi, transfer: MegaTransfer, e: MegaError) {
            Log.w(TAG, "Transfer temporary error: ${e.errorString} (code=${e.errorCode})")
        }

        override fun onFolderTransferUpdate(
            api: MegaApi, transfer: MegaTransfer, arg0: Int,
            arg1: Long, arg2: Long, arg3: Long,
            arg4: String, arg5: String
        ) {}

        override fun onTransferData(api: MegaApi, transfer: MegaTransfer, data: String): Boolean = false
    }

    init {
        Log.i(TAG, "MegaClient initialized. MegaApi hash: ${System.identityHashCode(megaApi)}")
        megaApi.addRequestListener(requestListener)
        megaApi.addTransferListener(transferListener)
    }

    fun login(email: String, password: String) {
        if (email.isBlank() || password.isBlank()) {
            Log.e(TAG, "Login failed: email or password is empty")
            onLoginResult?.invoke(false, "Email and password cannot be empty")
            return
        }
        megaReady = false
        Log.i(TAG, "Login called for $email")
        megaApi.login(email, password)
    }

    fun uploadFile(localPath: String, parentNode: MegaNode? = null) {
        Log.i(TAG, "Upload request: $localPath")
        if (!megaReady) {
            Log.e(TAG, "UPLOAD FAILED: MEGA NOT READY")
            onUploadResult?.invoke(localPath, false, "MEGA NOT READY", null)
            return
        }

        val target = parentNode ?: megaApi.rootNode
        if (target == null) {
            Log.e(TAG, "UPLOAD FAILED: TARGET NODE NULL")
            megaApi.fetchNodes()
            onUploadResult?.invoke(localPath, false, "TARGET NODE NULL", null)
            return
        }

        val file = File(localPath)
        if (!file.exists()) {
            Log.e(TAG, "UPLOAD FAILED: FILE MISSING: $localPath")
            onUploadResult?.invoke(localPath, false, "FILE NOT FOUND", null)
            return
        }
        if (file.length() == 0L) {
            Log.e(TAG, "UPLOAD FAILED: EMPTY FILE: $localPath")
            onUploadResult?.invoke(localPath, false, "EMPTY BACKUP FILE", null)
            return
        }

        Log.i(TAG, "Starting upload of ${file.name} (${file.length()} bytes) to ${target.name}")
        megaApi.startUpload(localPath, target, null, null)
    }

    fun downloadFile(nodeHandle: Long, localPath: String) {
        val node = megaApi.getNodeByHandle(nodeHandle)
        if (node == null) {
            Log.e(TAG, "Download failed: node not found for handle $nodeHandle")
            onDownloadResult?.invoke(localPath, false, "Node not found", null)
            return
        }
        if (!megaReady) {
            Log.e(TAG, "Download failed: fetchNodes not completed")
            onDownloadResult?.invoke(localPath, false, "Download not ready. Complete login and node fetch first.", null)
            return
        }
        Log.i(TAG, "Starting download: $localPath")
        megaApi.startDownload(node, localPath, null, null, false, null, 0, 0, false)
    }

    fun fetchNodes() {
        megaReady = false
        Log.i(TAG, "fetchNodes called (explicit)")
        megaApi.fetchNodes()
    }

    fun createFolder(name: String, parent: MegaNode? = null) {
        val target = parent ?: megaApi.rootNode
        if (target == null) {
            onCreateFolderResult?.invoke(false, "Parent node null", null)
            return
        }
        if (!megaReady) {
            Log.e(TAG, "MEGA NOT READY for createFolder")
            onCreateFolderResult?.invoke(false, "MEGA NOT READY", null)
            return
        }
        Log.i(TAG, "Creating folder: $name")
        megaApi.createFolder(name, target)
    }

    fun logout() {
        Log.i(TAG, "Logout called")
        megaApi.logout(false, null)
    }

    fun destroy() {
        megaApi.removeRequestListener(requestListener)
        megaApi.removeTransferListener(transferListener)
    }
}
