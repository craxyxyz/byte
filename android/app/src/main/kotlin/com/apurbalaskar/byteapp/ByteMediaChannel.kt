// Byte © 2026 Apurba Laskar.
package com.apurbalaskar.byteapp

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import android.os.Build

// The playback notification's channel, made before the media service makes
// its own: same id (lib/player/byte_handler.dart byteAudioConfig), quiet, and
// fully visible on the lock screen, so the song, its picture, the seek bar and
// the buttons show there. Android only lets an app choose this when the
// channel is first made; after that it's the person's own setting.
object ByteMediaChannel {
    const val ID = "com.apurbalaskar.byte.playback"
    const val NAME = "Music playback"
    const val DESCRIPTION = "The song playing, with its controls, on the lock screen and in notifications"

    fun ensure(context: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        try {
            val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            if (nm.getNotificationChannel(ID) != null) return
            val channel = NotificationChannel(ID, NAME, NotificationManager.IMPORTANCE_LOW)
            channel.description = DESCRIPTION
            channel.lockscreenVisibility = Notification.VISIBILITY_PUBLIC
            channel.setShowBadge(false)
            channel.setSound(null, null)
            channel.enableVibration(false)
            nm.createNotificationChannel(channel)
        } catch (e: Exception) {}
    }
}
