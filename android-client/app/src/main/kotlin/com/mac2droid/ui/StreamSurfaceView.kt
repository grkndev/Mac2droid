package com.mac2droid.ui

import android.content.Context
import android.util.AttributeSet
import android.view.Surface
import android.view.SurfaceHolder
import android.view.SurfaceView

/**
 * SurfaceView for displaying decoded video stream
 */
class StreamSurfaceView @JvmOverloads constructor(
    context: Context,
    attrs: AttributeSet? = null,
    defStyleAttr: Int = 0
) : SurfaceView(context, attrs, defStyleAttr), SurfaceHolder.Callback {

    // Callback when surface is ready
    var onSurfaceReady: ((Surface) -> Unit)? = null

    // Callback when surface is destroyed
    var onSurfaceDestroyed: (() -> Unit)? = null

    // Target aspect ratio
    private var targetAspectRatio: Float = 16f / 9f

    init {
        holder.addCallback(this)

        // Keep screen on while streaming
        keepScreenOn = true
    }

    /**
     * Set target video dimensions for aspect ratio
     */
    fun setVideoSize(width: Int, height: Int) {
        if (width > 0 && height > 0) {
            targetAspectRatio = width.toFloat() / height.toFloat()
            android.util.Log.d("StreamSurfaceView", "setVideoSize: $width x $height, aspectRatio=$targetAspectRatio")
            requestLayout()
        }
    }

    override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
        val maxWidth = MeasureSpec.getSize(widthMeasureSpec)
        val maxHeight = MeasureSpec.getSize(heightMeasureSpec)

        if (maxWidth == 0 || maxHeight == 0) {
            setMeasuredDimension(maxWidth, maxHeight)
            return
        }

        val viewAspectRatio = maxWidth.toFloat() / maxHeight.toFloat()

        val newWidth: Int
        val newHeight: Int

        if (viewAspectRatio > targetAspectRatio) {
            // View is wider than video - fit to height, pillarbox (black bars on sides)
            newHeight = maxHeight
            newWidth = (maxHeight * targetAspectRatio).toInt()
        } else {
            // View is taller than video - fit to width, letterbox (black bars top/bottom)
            newWidth = maxWidth
            newHeight = (maxWidth / targetAspectRatio).toInt()
        }

        android.util.Log.d("StreamSurfaceView", "onMeasure: max=$maxWidth x $maxHeight, target ratio=$targetAspectRatio, result=$newWidth x $newHeight")
        setMeasuredDimension(newWidth, newHeight)
    }

    override fun surfaceCreated(holder: SurfaceHolder) {
        onSurfaceReady?.invoke(holder.surface)
    }

    override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) {
        // Surface size changed - could handle resize here
    }

    override fun surfaceDestroyed(holder: SurfaceHolder) {
        onSurfaceDestroyed?.invoke()
    }
}
