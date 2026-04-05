package com.app.rtmp_publisher

import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CaptureRequest
import android.graphics.Rect

/**
 * Helper class for managing camera zoom functionality
 */
class CameraZoom(private val characteristics: CameraCharacteristics) {
    private val sensorRect: Rect = characteristics.get(CameraCharacteristics.SENSOR_INFO_ACTIVE_ARRAY_SIZE)!!
    private val maxDigitalZoom: Float = characteristics.get(CameraCharacteristics.SCALER_AVAILABLE_MAX_DIGITAL_ZOOM) ?: 1.0f
    
    val minZoom: Float = 1.0f
    val maxZoom: Float = maxDigitalZoom
    
    /**
     * Calculate crop region for given zoom level
     */
    fun getCropRegionForZoom(zoom: Float): Rect {
        val clampedZoom = zoom.coerceIn(minZoom, maxZoom)
        
        val centerX = sensorRect.width() / 2
        val centerY = sensorRect.height() / 2
        val deltaX = (0.5f * sensorRect.width() / clampedZoom).toInt()
        val deltaY = (0.5f * sensorRect.height() / clampedZoom).toInt()
        
        return Rect(
            centerX - deltaX,
            centerY - deltaY,
            centerX + deltaX,
            centerY + deltaY
        )
    }
    
    /**
     * Apply zoom to capture request builder
     */
    fun applyZoom(builder: CaptureRequest.Builder, zoom: Float) {
        val cropRegion = getCropRegionForZoom(zoom)
        builder.set(CaptureRequest.SCALER_CROP_REGION, cropRegion)
    }
}
