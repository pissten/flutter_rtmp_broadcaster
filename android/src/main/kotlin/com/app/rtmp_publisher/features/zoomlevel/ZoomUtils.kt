package com.app.rtmp_publisher.features.zoomlevel

import android.graphics.Rect
import androidx.core.math.MathUtils

/**
 * Utility class containing methods that assist with zoom features in the Camera2 API.
 */
object ZoomUtils {
    /**
     * Computes an image sensor area based on the supplied zoom settings.
     *
     * The returned image sensor area can be applied to the Camera2 API in
     * order to control zoom levels. This method of zoom should only be used for Android versions <=
     * 11 as past that, the newer computeZoomRatio() functional can be used.
     *
     * @param zoom The desired zoom level.
     * @param sensorArraySize The current area of the image sensor.
     * @param minimumZoomLevel The minimum supported zoom level.
     * @param maximumZoomLevel The maximum supported zoom level.
     * @return An image sensor area based on the supplied zoom settings
     */
    fun computeZoomRect(
        zoom: Float,
        sensorArraySize: Rect,
        minimumZoomLevel: Float,
        maximumZoomLevel: Float
    ): Rect {
        val newZoom = computeZoomRatio(zoom, minimumZoomLevel, maximumZoomLevel)

        val centerX = sensorArraySize.width() / 2
        val centerY = sensorArraySize.height() / 2
        val deltaX = (0.5f * sensorArraySize.width() / newZoom).toInt()
        val deltaY = (0.5f * sensorArraySize.height() / newZoom).toInt()

        return Rect(centerX - deltaX, centerY - deltaY, centerX + deltaX, centerY + deltaY)
    }

    fun computeZoomRatio(zoom: Float, minimumZoomLevel: Float, maximumZoomLevel: Float): Float {
        return MathUtils.clamp(zoom, minimumZoomLevel, maximumZoomLevel)
    }
}
