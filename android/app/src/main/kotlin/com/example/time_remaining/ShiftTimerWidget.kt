package com.example.time_remaining

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.widget.RemoteViews
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

class ShiftTimerWidget : AppWidgetProvider() {

    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray,
    ) {
        for (appWidgetId in appWidgetIds) {
            updateAppWidget(context, appWidgetManager, appWidgetId)
        }
    }

    override fun onReceive(context: Context, intent: Intent) {
        super.onReceive(context, intent)

        // Ensure widgets refresh when explicitly requested (e.g. from system)
        if (intent.action == AppWidgetManager.ACTION_APPWIDGET_UPDATE) {
            val manager = AppWidgetManager.getInstance(context)
            val componentName = ComponentName(context, ShiftTimerWidget::class.java)
            val ids = manager.getAppWidgetIds(componentName)
            onUpdate(context, manager, ids)
        }
    }

    private fun updateAppWidget(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetId: Int,
    ) {
        val views = RemoteViews(context.packageName, R.layout.widget_shift_timer)

        val prefs = context.getSharedPreferences(
            "FlutterSharedPreferences",
            Context.MODE_PRIVATE,
        )

        // Flutter stores int under key "flutter.exit_time" etc.
        val exitTimeMillis =
            if (prefs.contains("flutter.exit_time")) prefs.getLong("flutter.exit_time", 0L)
            else 0L
        val isRunning =
            if (prefs.contains("flutter.is_running")) prefs.getBoolean("flutter.is_running", false)
            else false

        if (isRunning && exitTimeMillis > 0L) {
            val now = System.currentTimeMillis()
            val remainingMillis = exitTimeMillis - now

            if (remainingMillis > 0) {
                val totalSeconds = remainingMillis / 1000
                val hours = totalSeconds / 3600
                val minutes = (totalSeconds % 3600) / 60
                val seconds = totalSeconds % 60

                val timeRemainingText =
                    String.format(Locale.getDefault(), "%02d:%02d:%02d", hours, minutes, seconds)
                views.setTextViewText(R.id.text_time_remaining, timeRemainingText)

                val endTimeText = formatEndTime(exitTimeMillis)
                views.setTextViewText(
                    R.id.text_end_time,
                    "Ends at $endTimeText",
                )

                views.setTextViewText(R.id.text_status, "Session running")
            } else {
                views.setTextViewText(R.id.text_time_remaining, "00:00:00")
                views.setTextViewText(R.id.text_end_time, "Session ended")
                views.setTextViewText(R.id.text_status, "Not running")
            }
        } else {
            views.setTextViewText(R.id.text_time_remaining, "--:--:--")
            views.setTextViewText(R.id.text_end_time, "No active session")
            views.setTextViewText(R.id.text_status, "Not running")
        }

        // Tap on widget opens the main app
        val intent = Intent(context, MainActivity::class.java)
        val pendingIntent = PendingIntent.getActivity(
            context,
            0,
            intent,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        views.setOnClickPendingIntent(R.id.text_time_remaining, pendingIntent)
        views.setOnClickPendingIntent(R.id.text_end_time, pendingIntent)
        views.setOnClickPendingIntent(R.id.text_status, pendingIntent)

        appWidgetManager.updateAppWidget(appWidgetId, views)
    }

    private fun formatEndTime(exitTimeMillis: Long): String {
        val date = Date(exitTimeMillis)
        val formatter = SimpleDateFormat("hh:mm a", Locale.getDefault())
        return formatter.format(date)
    }
}

