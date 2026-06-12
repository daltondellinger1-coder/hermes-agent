package com.hermes.pocketmode

import android.Manifest
import android.app.Activity
import android.content.pm.PackageManager
import android.media.MediaRecorder
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.speech.tts.TextToSpeech
import android.speech.tts.UtteranceProgressListener
import android.util.Base64
import android.view.ViewGroup
import android.view.Window
import android.webkit.JavascriptInterface
import android.webkit.PermissionRequest
import android.webkit.WebChromeClient
import android.webkit.WebSettings
import android.webkit.WebView
import android.webkit.WebViewClient
import android.widget.FrameLayout
import android.widget.TextView
import java.io.File
import java.util.Locale

class MainActivity : Activity() {
    private lateinit var webView: WebView
    private lateinit var loadingView: TextView
    private var pendingAudioRequest: PermissionRequest? = null
    private var nativeRecorder: MediaRecorder? = null
    private var nativeAudioFile: File? = null
    private var tts: TextToSpeech? = null
    private var ttsReady = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        requestWindowFeature(Window.FEATURE_NO_TITLE)
        buildUi()
        initTextToSpeech()
        if (requestRuntimePermissions()) {
            webView.loadUrl(DEFAULT_COCKPIT_URL)
        }
    }

    override fun onDestroy() {
        stopNativeRecorderSilently()
        try {
            tts?.stop()
            tts?.shutdown()
        } catch (_: Exception) {
        }
        webView.destroy()
        super.onDestroy()
    }

    private fun buildUi() {
        val root = FrameLayout(this).apply {
            setBackgroundColor(0xFF061F1D.toInt())
        }

        loadingView = TextView(this).apply {
            text = "Loading Hermes Cockpit…"
            textSize = 18f
            setTextColor(0xFFFFF3DC.toInt())
            setPadding(36, 64, 36, 36)
        }
        root.addView(
            loadingView,
            FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.WRAP_CONTENT,
            ),
        )

        webView = WebView(this).apply {
            layoutParams = FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.MATCH_PARENT,
            )
            setBackgroundColor(0xFF061F1D.toInt())
            webViewClient = object : WebViewClient() {
                override fun onPageFinished(view: WebView?, url: String?) {
                    loadingView.visibility = TextView.GONE
                }
            }
            webChromeClient = object : WebChromeClient() {
                override fun onPermissionRequest(request: PermissionRequest) {
                    runOnUiThread {
                        val allowed = request.resources.filter { it == PermissionRequest.RESOURCE_AUDIO_CAPTURE }
                        if (allowed.isNotEmpty() && hasAudioPermission()) {
                            request.grant(allowed.toTypedArray())
                        } else if (allowed.isNotEmpty()) {
                            pendingAudioRequest = request
                            requestPermissions(arrayOf(Manifest.permission.RECORD_AUDIO), REQUEST_PERMISSIONS)
                        } else {
                            request.deny()
                        }
                    }
                }
            }
            settings.javaScriptEnabled = true
            settings.domStorageEnabled = true
            settings.mediaPlaybackRequiresUserGesture = false
            settings.cacheMode = WebSettings.LOAD_DEFAULT
            addJavascriptInterface(AndroidAudioBridge(), "HermesAndroidAudio")
            addJavascriptInterface(AndroidSpeechBridge(), "HermesAndroidSpeech")
        }
        root.addView(webView)

        setContentView(root)
    }

    private fun requestRuntimePermissions(): Boolean {
        val permissions = mutableListOf<String>()
        if (!hasAudioPermission()) {
            permissions += Manifest.permission.RECORD_AUDIO
        }
        if (
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
        ) {
            permissions += Manifest.permission.POST_NOTIFICATIONS
        }
        if (permissions.isNotEmpty()) {
            requestPermissions(permissions.toTypedArray(), REQUEST_PERMISSIONS)
            return false
        }
        return true
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != REQUEST_PERMISSIONS) return

        val audioGranted = hasAudioPermission()
        val request = pendingAudioRequest
        pendingAudioRequest = null
        if (request != null) {
            if (audioGranted) {
                request.grant(arrayOf(PermissionRequest.RESOURCE_AUDIO_CAPTURE))
            } else {
                request.deny()
            }
        }

        if (audioGranted && webView.url == null) {
            webView.loadUrl(DEFAULT_COCKPIT_URL)
        } else if (!audioGranted && webView.url == null) {
            loadingView.text = "Hermes Cockpit needs microphone permission for hold-to-talk. Enable Microphone in Android App info → Permissions, then reopen."
        }
    }

    private fun hasAudioPermission(): Boolean =
        checkSelfPermission(Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED

    private fun initTextToSpeech() {
        tts = TextToSpeech(this) { status ->
            ttsReady = status == TextToSpeech.SUCCESS
            if (ttsReady) {
                tts?.language = Locale.US
                tts?.setSpeechRate(1.03f)
                tts?.setOnUtteranceProgressListener(object : UtteranceProgressListener() {
                    override fun onStart(utteranceId: String?) {
                        emitNativeSpeechEvent("start")
                    }

                    override fun onDone(utteranceId: String?) {
                        emitNativeSpeechEvent("done")
                    }

                    @Deprecated("Deprecated in Java")
                    override fun onError(utteranceId: String?) {
                        emitNativeSpeechEvent("error")
                    }

                    override fun onError(utteranceId: String?, errorCode: Int) {
                        emitNativeSpeechEvent("error", errorCode.toString())
                    }
                })
            }
        }
    }

    private fun emitNativeSpeechEvent(state: String, error: String? = null) {
        val safeState = state.replace("\\", "\\\\").replace("'", "\\'")
        val safeError = error?.replace("\\", "\\\\")?.replace("'", "\\'") ?: ""
        val script = "window.dispatchEvent(new CustomEvent('hermes-native-speech',{detail:{state:'${safeState}',error:'${safeError}'}}));"
        runOnUiThread { webView.evaluateJavascript(script, null) }
    }

    private fun stopNativeRecorderSilently() {
        try {
            nativeRecorder?.stop()
        } catch (_: Exception) {
        }
        try {
            nativeRecorder?.release()
        } catch (_: Exception) {
        }
        nativeRecorder = null
    }

    private fun emitNativeAudioResult(ok: Boolean, base64: String? = null, error: String? = null) {
        val safeBase64 = base64?.replace("\\", "\\\\")?.replace("'", "\\'") ?: ""
        val safeError = error?.replace("\\", "\\\\")?.replace("'", "\\'") ?: ""
        val script = "window.dispatchEvent(new CustomEvent('hermes-native-audio',{detail:{ok:${ok},mime:'audio/mp4',base64:'${safeBase64}',error:'${safeError}'}}));"
        runOnUiThread { webView.evaluateJavascript(script, null) }
    }

    inner class AndroidAudioBridge {
        @JavascriptInterface
        fun startRecording(): String {
            if (!hasAudioPermission()) return "NO_PERMISSION"
            return try {
                stopNativeRecorderSilently()
                val file = File.createTempFile("hermes-cockpit-", ".m4a", cacheDir)
                nativeAudioFile = file
                val recorder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) MediaRecorder(this@MainActivity) else MediaRecorder()
                recorder.setAudioSource(MediaRecorder.AudioSource.MIC)
                recorder.setOutputFormat(MediaRecorder.OutputFormat.MPEG_4)
                recorder.setAudioEncoder(MediaRecorder.AudioEncoder.AAC)
                recorder.setAudioSamplingRate(16000)
                recorder.setAudioEncodingBitRate(64000)
                recorder.setOutputFile(file.absolutePath)
                recorder.prepare()
                recorder.start()
                nativeRecorder = recorder
                "OK"
            } catch (error: Exception) {
                stopNativeRecorderSilently()
                "ERROR: ${error.javaClass.simpleName}: ${error.message ?: "unknown"}"
            }
        }

        @JavascriptInterface
        fun stopRecording() {
            Handler(Looper.getMainLooper()).post {
                try {
                    val recorder = nativeRecorder ?: run {
                        emitNativeAudioResult(false, error = "Native recorder was not active")
                        return@post
                    }
                    try {
                        recorder.stop()
                    } finally {
                        recorder.release()
                        nativeRecorder = null
                    }
                    val file = nativeAudioFile
                    if (file == null || !file.exists() || file.length() < 700) {
                        emitNativeAudioResult(false, error = "Native recorder produced no audio")
                        return@post
                    }
                    val encoded = Base64.encodeToString(file.readBytes(), Base64.NO_WRAP)
                    emitNativeAudioResult(true, base64 = encoded)
                    file.delete()
                } catch (error: Exception) {
                    stopNativeRecorderSilently()
                    emitNativeAudioResult(false, error = "${error.javaClass.simpleName}: ${error.message ?: "unknown"}")
                }
            }
        }
    }

    inner class AndroidSpeechBridge {
        @JavascriptInterface
        fun speak(text: String): String {
            val clean = text.trim()
            if (clean.isEmpty()) return "EMPTY"
            if (!ttsReady || tts == null) return "NOT_READY"
            return try {
                Handler(Looper.getMainLooper()).post {
                    tts?.stop()
                    tts?.speak(clean.take(700), TextToSpeech.QUEUE_FLUSH, null, "hermes-${System.currentTimeMillis()}")
                }
                "OK"
            } catch (error: Exception) {
                "ERROR: ${error.javaClass.simpleName}: ${error.message ?: "unknown"}"
            }
        }

        @JavascriptInterface
        fun stop() {
            Handler(Looper.getMainLooper()).post { tts?.stop() }
        }
    }

    companion object {
        private const val REQUEST_PERMISSIONS = 10
        private const val DEFAULT_COCKPIT_URL = "https://desktop-vcb4ksf-1.tail87092b.ts.net/cockpit"
    }
}
