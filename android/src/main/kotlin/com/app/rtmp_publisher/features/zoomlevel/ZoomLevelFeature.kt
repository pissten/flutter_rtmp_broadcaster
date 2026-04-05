package com.app.rtmp_publisher.features.zoomlevel

import android.graphics.Rect
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CaptureRequest
import android.os.Build

/**
 * Controls the zoom configuration on the Camera2 API.
 */
class ZoomLevelFeature(private val characteristics: CameraCharacteristics) {
    companion object {
        private const val DEFAULT_ZOOM_LEVEL = 1.0f
    }

    private val hasSupport: Boolean
    private val sensorArraySize: Rect?
    var currentSetting: Float = DEFAULT_ZOOM_LEVEL
        private set
    val minimumZoomLevel: Float
    val maximumZoomLevel: Float

    init {
        sensorArraySize = characteristics.get(CameraCharacteristics.SENSOR_INFO_ACTIVE_ARRAY_SIZE)

        if (sensorArraySize == null) {
            minimumZoomLevel = DEFAULT_ZOOM_LEVEL
            maximumZoomLevel = DEFAULT_ZOOM_LEVEL
            hasSupport = false
        } else {
            // On Android 11+ CONTROL_ZOOM_RATIO_RANGE should be used to get the zoom ratio directly
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                val zoomRange = characteristics.get(CameraCharacteristics.CONTROL_ZOOM_RATIO_RANGE)
                minimumZoomLevel = zoomRange?.lower ?: DEFAULT_ZOOM_LEVEL
                maximumZoomLevel = zoomRange?.upper ?: DEFAULT_ZOOM_LEVEL
            } else {
                minimumZoomLevel = DEFAULT_ZOOM_LEVEL
                val maxDigitalZoom = characteristics.get(CameraCharacteristics.SCALER_AVAILABLE_MAX_DIGITAL_ZOOM)
                maximumZoomLevel = if (maxDigitalZoom == null || maxDigitalZoom < minimumZoomLevel) {
                    minimumZoomLevel
                } else {
                    maxDigitalZoom
                }
            }

            hasSupport = maximumZoomLevel > minimumZoomLevel
        }
    }

    fun setValue(value: Float) {
        currentSetting = value
    }

    fun checkIsSupported(): Boolean {
        return hasSupport
    }

    fun updateBuilder(requestBuilder: CaptureRequest.Builder) {
        if (!checkIsSupported()) {
            return
        }

        // On Android 11+ CONTROL_ZOOM_RATIO can be set to a zoom ratio and the camera feed will compute
        // how to zoom on its own accounting for multiple logical cameras.
        // Prior the image cropping window must be calculated and set manually.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            requestBuilder.set(
                CaptureRequest.CONTROL_ZOOM_RATIO,
                ZoomUtils.computeZoomRatio(currentSetting, minimumZoomLevel, maximumZoomLevel)
            )
        } else {
            sensorArraySize?.let {
                val computedZoom = ZoomUtils.computeZoomRect(
                    currentSetting,
                    it,
                    minimumZoomLevel,
                    maximumZoomLevel
                )
                requestBuilder.set(CaptureRequest.SCALER_CROP_REGION, computedZoom)
            }
        }
    }
}
