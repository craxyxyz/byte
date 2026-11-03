package com.apurbalaskar.byteapp

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.PorterDuff
import android.graphics.PorterDuffXfermode
import android.graphics.RectF
import android.view.KeyEvent
import android.widget.RemoteViews
import java.io.File

// Byte © 2026 Apurba Laskar. The home-screen player widget: cover,
// title / artist, previous · play-pause · next. The app tells it what's
// playing ("byte/widget" channel); the buttons go to the player as media
// buttons, the same way headphones do.
class ByteWidget : AppWidgetProvider() {
    override fun onUpdate(ctx: Context, mgr: AppWidgetManager, ids: IntArray) {
        for (id in ids) mgr.updateAppWidget(id, views(ctx))
    }

    companion object {
        private const val PREFS = "byte_widget"
        private const val MEDIA_BUTTON_RECEIVER = "com.ryanheise.audioservice.MediaButtonReceiver"

        /** Saves what's playing and redraws every Byte widget on the home screen. */
        fun push(ctx: Context, title: String?, artist: String?, playing: Boolean, artPath: String?) {
            ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
                .putString("title", title)
                .putString("artist", artist)
                .putBoolean("playing", playing)
                .putString("art", artPath)
                .apply()
            refresh(ctx)
        }

        fun refresh(ctx: Context) {
            val mgr = AppWidgetManager.getInstance(ctx)
            val ids = mgr.getAppWidgetIds(ComponentName(ctx, ByteWidget::class.java))
            if (ids.isEmpty()) return
            val v = views(ctx)
            for (id in ids) {
                try { mgr.updateAppWidget(id, v) } catch (e: Throwable) {}
            }
        }

        private fun mediaButton(ctx: Context, code: Int, keyCode: Int): PendingIntent {
            val i = Intent(Intent.ACTION_MEDIA_BUTTON)
                .setComponent(ComponentName(ctx, MEDIA_BUTTON_RECEIVER))
                .putExtra(Intent.EXTRA_KEY_EVENT, KeyEvent(KeyEvent.ACTION_DOWN, keyCode))
            return PendingIntent.getBroadcast(ctx, code, i, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        }

        private fun rounded(src: Bitmap, radiusPx: Float): Bitmap {
            val out = Bitmap.createBitmap(src.width, src.height, Bitmap.Config.ARGB_8888)
            val c = Canvas(out)
            val p = Paint(Paint.ANTI_ALIAS_FLAG)
            c.drawRoundRect(RectF(0f, 0f, src.width.toFloat(), src.height.toFloat()), radiusPx, radiusPx, p)
            p.xfermode = PorterDuffXfermode(PorterDuff.Mode.SRC_IN)
            c.drawBitmap(src, 0f, 0f, p)
            return out
        }

        private fun cover(path: String?): Bitmap? {
            if (path.isNullOrEmpty() || !File(path).exists()) return null
            return try {
                val o = BitmapFactory.Options().apply { inJustDecodeBounds = true }
                BitmapFactory.decodeFile(path, o)
                var sample = 1
                while (o.outWidth / (sample * 2) >= 300) sample *= 2
                val b = BitmapFactory.decodeFile(path, BitmapFactory.Options().apply { inSampleSize = sample }) ?: return null
                val s = Bitmap.createScaledBitmap(b, 300, 300, true)
                rounded(s, 48f)
            } catch (e: Throwable) {
                null
            }
        }

        fun views(ctx: Context): RemoteViews {
            val p = ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            val v = RemoteViews(ctx.packageName, R.layout.byte_widget)
            val title = p.getString("title", null)
            v.setTextViewText(R.id.widget_title, title ?: "Byte")
            v.setTextViewText(R.id.widget_artist, if (title == null) "Tap to open" else (p.getString("artist", "") ?: ""))
            val playing = p.getBoolean("playing", false)
            v.setImageViewResource(R.id.widget_play, if (playing) R.drawable.byte_widget_pause else R.drawable.byte_widget_play)
            val art = cover(p.getString("art", null))
            if (art != null) v.setImageViewBitmap(R.id.widget_cover, art) else v.setImageViewResource(R.id.widget_cover, R.drawable.byte_widget_placeholder)

            val open = Intent(ctx, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
            val openPi = PendingIntent.getActivity(ctx, 40, open, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
            v.setOnClickPendingIntent(R.id.widget_cover, openPi)
            v.setOnClickPendingIntent(R.id.widget_title, openPi)
            v.setOnClickPendingIntent(R.id.widget_artist, openPi)
            v.setOnClickPendingIntent(R.id.widget_prev, mediaButton(ctx, 41, KeyEvent.KEYCODE_MEDIA_PREVIOUS))
            // Nothing loaded yet: the play button opens Byte instead.
            v.setOnClickPendingIntent(
                R.id.widget_play,
                if (title == null) openPi else mediaButton(ctx, 42, if (playing) KeyEvent.KEYCODE_MEDIA_PAUSE else KeyEvent.KEYCODE_MEDIA_PLAY),
            )
            v.setOnClickPendingIntent(R.id.widget_next, mediaButton(ctx, 43, KeyEvent.KEYCODE_MEDIA_NEXT))
            return v
        }
    }
}
