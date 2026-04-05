package com.app.rtmp_publisher

import android.app.Activity
import android.content.Context
import android.graphics.Bitmap
import android.graphics.Point
import android.hardware.camera2.CameraAccessException
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraManager
import android.hardware.camera2.CameraMetadata
import android.util.Log
import android.view.MotionEvent
import android.view.ScaleGestureDetector
import android.view.SurfaceHolder
import android.view.View
import android.widget.Toast
import com.pedro.encoder.input.video.CameraHelper.Facing.BACK
import com.pedro.encoder.input.video.CameraHelper.Facing.FRONT
import com.pedro.rtplibrary.rtmp.RtmpCamera2
import com.pedro.rtplibrary.view.LightOpenGlView
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.platform.PlatformView
import net.ossrs.rtmp.ConnectCheckerRtmp
import java.io.*


class CameraNativeView(
    private var activity: Activity? = null,
    private var enableAudio: Boolean = false,
    private val preset: Camera.ResolutionPreset,
    private var cameraName: String,
    private var dartMessenger: DartMessenger? = null
) :
    PlatformView,
    SurfaceHolder.Callback,
    ConnectCheckerRtmp {

    private val glView = LightOpenGlView(activity)
    private val rtmpCamera: RtmpCamera2

    private var isSurfaceCreated = false
    private var fps = 0

    // Zoom state — back camera only
    private var currentZoom = 1.0f
    private lateinit var scaleGestureDetector: ScaleGestureDetector

    init {
        glView.isKeepAspectRatio = true
        glView.holder.addCallback(this)
        rtmpCamera = RtmpCamera2(glView, this)
        rtmpCamera.setReTries(10)
        rtmpCamera.setFpsListener { fps = it }

        // Native ScaleGestureDetector for smooth pinch-to-zoom on back camera.
        // We accumulate zoom relative to the per-gesture baseline so each new
        // pinch starts from the current level, not from 1x.
        scaleGestureDetector = ScaleGestureDetector(
            activity!!, object : ScaleGestureDetector.SimpleOnScaleGestureListener() {

                override fun onScaleBegin(detector: ScaleGestureDetector): Boolean {
                    // currentZoom already holds the level from any previous gesture
                    return true
                }

                override fun onScale(detector: ScaleGestureDetector): Boolean {
                    if (isFrontFacing(cameraName)) return false // back camera only
                    // scaleFactor is a per-event delta (e.g. 1.02 = 2% bigger this frame).
                    // Multiply into currentZoom so each frame accumulates smoothly.
                    val newZoom = (currentZoom * detector.scaleFactor)
                        .coerceIn(1.0f, rtmpCamera.getMaxZoom().coerceAtLeast(1.0f))
                    if (kotlin.math.abs(newZoom - currentZoom) < 0.01f) return false
                    currentZoom = newZoom
                    try {
                        rtmpCamera.setZoom(newZoom)
                        Log.d("CameraNativeView", "zoom: ${"%.2f".format(newZoom)}")
                    } catch (e: Exception) {
                        Log.w("CameraNativeView", "setZoom error: ${e.message}")
                    }
                    return true
                }
            }
        )

        // Route multi-finger touches to the ScaleGestureDetector.
        glView.setOnTouchListener { _, event ->
            if (event.pointerCount >= 2) {
                scaleGestureDetector.onTouchEvent(event)
            }
            true
        }
    }

    override fun surfaceCreated(holder: SurfaceHolder) {
        Log.d("CameraNativeView", "surfaceCreated")
        isSurfaceCreated = true
        startPreview(cameraName)
    }

    override fun surfaceChanged(p0: SurfaceHolder, p1: Int, p2: Int, p3: Int) {
        // No-op: pedro handles surface dimension changes internally
    }

    override fun surfaceDestroyed(p0: SurfaceHolder) {
        Log.d("CameraNativeView", "surfaceDestroyed — stopping preview/stream")
        isSurfaceCreated = false
        if (rtmpCamera.isOnPreview) rtmpCamera.stopPreview()
        if (rtmpCamera.isStreaming) rtmpCamera.stopStream()
    }

    override fun onAuthSuccessRtmp() {
    }

    override fun onNewBitrateRtmp(bitrate: Long) {
    }

    override fun onConnectionSuccessRtmp() {
    }

    override fun onConnectionFailedRtmp(reason: String) {
        activity?.runOnUiThread { //Wait 5s and retry connect stream
            if (rtmpCamera.reTry(5000, reason)) {
                dartMessenger?.send(DartMessenger.EventType.RTMP_RETRY, reason)
            } else {
                dartMessenger?.send(DartMessenger.EventType.RTMP_STOPPED, "Failed retry")
                rtmpCamera.stopStream()
            }
        }
    }

    override fun onAuthErrorRtmp() {
        activity?.runOnUiThread {
            dartMessenger?.send(DartMessenger.EventType.ERROR, "Auth error")
        }
    }

    override fun onDisconnectRtmp() {
        activity?.runOnUiThread {
            dartMessenger?.send(DartMessenger.EventType.RTMP_STOPPED, "Disconnected")
        }
    }

    fun close() {
        Log.d("CameraNativeView", "close")
    }

    /**
     * Switch between front and back camera using pedro's built-in method.
     * This avoids the dispose+recreate pattern on the Flutter side, which
     * caused the SurfaceManager.eglSetup crash reported in Firebase.
     */
    fun switchCamera() {
        Log.d("CameraNativeView", "switchCamera")
        try {
            rtmpCamera.switchCamera()
            currentZoom = 1.0f  // reset zoom — new camera starts at 1x
            // Update tracked camera name to reflect the active camera
            val cameraManager = activity?.getSystemService(Context.CAMERA_SERVICE) as? CameraManager
            if (cameraManager != null) {
                for (id in cameraManager.cameraIdList) {
                    val chars = cameraManager.getCameraCharacteristics(id)
                    val facing = chars.get(CameraCharacteristics.LENS_FACING)
                    val isFront = facing == CameraMetadata.LENS_FACING_FRONT
                    // pedro's switchCamera toggles the facing; determine new cameraName
                    if (isFrontFacing(cameraName) != isFront) {
                        cameraName = id
                        break
                    }
                }
            }
        } catch (e: Exception) {
            Log.e("CameraNativeView", "switchCamera error: ${e.message}")
        }
    }

    /**
     * Forward a MotionEvent from Flutter's GestureDetector to pedro's built-in
     * zoom handler. Pedro uses ScaleGestureDetector internally to compute the
     * zoom level from pinch events, then applies SCALER_CROP_REGION to Camera2.
     * Only called for the back camera (zoom not supported on front camera).
     */
    fun handleZoom(event: MotionEvent) {
        if (isFrontFacing(cameraName)) return  // zoom only on main camera
        try {
            rtmpCamera.setZoom(event)
        } catch (e: Exception) {
            Log.w("CameraNativeView", "setZoom error: ${e.message}")
        }
    }

    fun takePicture(filePath: String, result: MethodChannel.Result) {
        Log.d("CameraNativeView", "takePicture filePath: $filePath result: $result")
        val file: File = File(filePath)
        if (file.exists()) {
            result.error("fileExists", "File at path '$filePath' already exists. Cannot overwrite.", null)
            return
        }
        glView.takePhoto {
            try {
                val outputStream: OutputStream = BufferedOutputStream(FileOutputStream(file))
                it.compress(Bitmap.CompressFormat.JPEG, 100, outputStream)
                outputStream.close()
                view.post { result.success(null) }
            } catch (e: IOException) {
                result.error("IOError", "Failed saving image", null)
            }
        }
    }

    fun startVideoRecording(filePath: String?, result: MethodChannel.Result) {
        if (filePath == null) {
            result.error("fileExists", "Must specify a filePath.", null)
            return
        }

        val file = File(filePath)
        if (file.exists()) {
            result.error("fileExists", "File at path '$filePath' already exists. Cannot overwrite.", null)
            return
        }
        Log.d("CameraNativeView", "startVideoRecording filePath: $filePath result: $result")


        val streamingSize = CameraUtils.getBestAvailableCamcorderProfileForResolutionPreset(cameraName, preset)
        /*if (rtmpCamera.isRecording || rtmpCamera.prepareAudio() && rtmpCamera.prepareVideo(
                streamingSize.videoFrameWidth,
                streamingSize.videoFrameHeight,
                streamingSize.videoBitRate
            )*/

        if (!rtmpCamera.isStreaming()) {
            if (rtmpCamera.prepareAudio() && rtmpCamera.prepareVideo(
                    streamingSize.videoFrameWidth,
                    streamingSize.videoFrameHeight,
                    streamingSize.videoBitRate
                )
            ) {
                rtmpCamera.startRecord(filePath)
            }
        } else {
            rtmpCamera.startRecord(filePath)
        }
    }


    fun startVideoStreaming(url: String?, bitrate: Int?, result: MethodChannel.Result) {
        Log.d("CameraNativeView", "startVideoStreaming url: $url")
        if (url == null) {
            result.error("startVideoStreaming", "Must specify a url.", null)
            return
        }

        try {
            if (!rtmpCamera.isStreaming) {
                val streamingSize = CameraUtils.getBestAvailableCamcorderProfileForResolutionPreset(cameraName, preset)
                if (rtmpCamera.isRecording || rtmpCamera.prepareAudio() && rtmpCamera.prepareVideo(
                        streamingSize.videoFrameWidth,
                        streamingSize.videoFrameHeight,
                        bitrate ?: streamingSize.videoBitRate
                    )
                ) {
                    // ready to start streaming
                    rtmpCamera.startStream(url)
                } else {
                    result.error("videoStreamingFailed", "Error preparing stream, This device cant do it", null)
                    return
                }
            } else {
                rtmpCamera.stopStream()
            }
            result.success(null)
        } catch (e: CameraAccessException) {
            result.error("videoStreamingFailed", e.message, null)
        } catch (e: IOException) {
            result.error("videoStreamingFailed", e.message, null)
        }
    }

    fun startVideoRecordingAndStreaming(filePath: String?, url: String?, bitrate: Int?, result: MethodChannel.Result) {
        if (filePath == null) {
            result.error("fileExists", "Must specify a filePath.", null)
            return
        }
        if (File(filePath).exists()) {
            result.error("fileExists", "File at path '$filePath' already exists.", null)
            return
        }
        if (url == null) {
            result.error("fileExists", "Must specify a url.", null)
            return
        }
        try {
            startVideoRecording(filePath, result)
            startVideoStreaming(url, bitrate, result)
        } catch (e: CameraAccessException) {
            result.error("videoRecordingFailed", e.message, null)
        } catch (e: IOException) {
            result.error("videoRecordingFailed", e.message, null)
        }
    }

    fun pauseVideoStreaming(result: Any) {
        // TODO: Implement pause video streaming
    }

    fun resumeVideoStreaming(result: Any) {
        // TODO: Implement resume video streaming
    }

    fun stopVideoRecordingOrStreaming(result: MethodChannel.Result) {
        try {
            rtmpCamera.apply {
                if (isStreaming) stopStream()
                if (isRecording) stopRecord()
            }
            result.success(null)
        } catch (e: CameraAccessException) {
            result.error("videoRecordingFailed", e.message, null)
        } catch (e: IllegalStateException) {
            result.error("videoRecordingFailed", e.message, null)
        }
    }

    fun stopVideoRecording(result: MethodChannel.Result) {
        try {
            rtmpCamera.apply {
                if (isRecording) stopRecord()
            }
            result.success(null)
        } catch (e: CameraAccessException) {
            result.error("stopVideoRecordingFailed", e.message, null)
        } catch (e: IllegalStateException) {
            result.error("stopVideoRecordingFailed", e.message, null)
        }
    }

    fun stopVideoStreaming(result: MethodChannel.Result) {
        try {
            rtmpCamera.apply {
                if (isStreaming) stopStream()
            }
            result.success(null)
        } catch (e: CameraAccessException) {
            result.error("stopVideoStreamingFailed", e.message, null)
        } catch (e: IllegalStateException) {
            result.error("stopVideoStreamingFailed", e.message, null)
        }
    }

    fun pauseVideoRecording(result: Any) {
        // TODO: Implement pause Video Recording
    }

    fun resumeVideoRecording(result: Any) {
        // TODO: Implement resume video recording
    }

    fun startPreviewWithImageStream(imageStreamChannel: Any) {
        // TODO: Implement start preview with image stream
    }

    fun startPreview(cameraNameArg: String? = null) {
        val targetCamera = if (cameraNameArg.isNullOrEmpty()) {
            cameraName
        } else {
            cameraNameArg
        }
        cameraName = targetCamera
        val previewSize = CameraUtils.computeBestPreviewSize(cameraName, preset)

        Log.d("CameraNativeView", "startPreview: $preset")
        if (isSurfaceCreated) {
            try {
                if (rtmpCamera.isOnPreview) {
                    rtmpCamera.stopPreview()
                }

                rtmpCamera.startPreview(if (isFrontFacing(targetCamera)) FRONT else BACK, previewSize.width, previewSize.height)
            } catch (e: CameraAccessException) {
//                close()
                activity?.runOnUiThread { dartMessenger?.send(DartMessenger.EventType.ERROR, "CameraAccessException") }
                return
            }
        }
    }

    fun getStreamStatistics(result: MethodChannel.Result) {
        val ret = hashMapOf<String, Any>()
        ret["cacheSize"] = rtmpCamera.cacheSize
        ret["sentAudioFrames"] = rtmpCamera.sentAudioFrames
        ret["sentVideoFrames"] = rtmpCamera.sentVideoFrames
        ret["droppedAudioFrames"] = rtmpCamera.droppedAudioFrames
        ret["droppedVideoFrames"] = rtmpCamera.droppedVideoFrames
        ret["isAudioMuted"] = rtmpCamera.isAudioMuted
        ret["bitrate"] = rtmpCamera.bitrate
        ret["width"] = rtmpCamera.streamWidth
        ret["height"] = rtmpCamera.streamHeight
        ret["fps"] = fps
        result.success(ret)
    }

    fun getMinZoomLevel(): Float = 1.0f

    fun getMaxZoomLevel(): Float {
        return try {
            // pedro exposes getMaxZoom() directly on Camera2Base
            rtmpCamera.getMaxZoom()
        } catch (e: Exception) {
            Log.w("CameraNativeView", "getMaxZoomLevel error: ${e.message}")
            8.0f
        }
    }

    fun setZoomLevel(zoom: Float) {
        if (isFrontFacing(cameraName)) return
        try {
            // pedro 1.9.6 Camera2Base.setZoom(float) applies SCALER_CROP_REGION
            // (or CONTROL_ZOOM_RATIO on newer devices) directly on the capture session.
            rtmpCamera.setZoom(zoom)
            Log.d("CameraNativeView", "setZoomLevel: $zoom")
        } catch (e: Exception) {
            Log.w("CameraNativeView", "setZoomLevel error: ${e.message}")
        }
    }

    fun isFrontCamera(): Boolean = isFrontFacing(cameraName)

    override fun getView(): View {
        return glView
    }

    override fun dispose() {
        isSurfaceCreated = false
        activity = null
    }

    private fun isFrontFacing(cameraName: String): Boolean {
        val cameraManager = activity?.getSystemService(Context.CAMERA_SERVICE) as CameraManager
        val characteristics = cameraManager.getCameraCharacteristics(cameraName)
        return characteristics.get(CameraCharacteristics.LENS_FACING) == CameraMetadata.LENS_FACING_FRONT
    }
}
