package io.github.xinchengp.todo_app

import android.app.Activity
import android.content.Intent
import android.provider.AlarmClock
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Dart ↔ 原生闹钟桥。
 *
 * Android 走 [AlarmScheduler]（AlarmManager.setAlarmClock + 全屏 AlarmActivity），
 * 而不是自建通知 —— 荣耀/华为的后台管控会吞通知，但系统闹钟不会被吞。
 */
class AlarmChannel(private val activity: Activity) {

    companion object {
        const val CHANNEL = "todo/system_alarm"

        fun register(engine: FlutterEngine, activity: Activity) {
            val ch = MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL)
            val impl = AlarmChannel(activity)
            ch.setMethodCallHandler { call, result ->
                when (call.method) {
                    "isSupported" -> result.success(true)
                    "setAlarm" -> {
                        val atMs = call.argument<Long>("atMs")
                        val label = call.argument<String>("label") ?: "任务提醒"
                        val code = call.argument<Int>("requestCode")
                            ?: (label.hashCode() and 0x7fffffff)
                        val mirror = call.argument<Boolean>("mirrorToClockApp") ?: false
                        val ok = AlarmScheduler.schedule(activity, atMs!!, label, code)
                        if (ok && mirror) {
                            val d = java.util.Calendar.getInstance().apply { timeInMillis = atMs }
                            AlarmScheduler.mirrorToClockApp(
                                activity,
                                d.get(java.util.Calendar.HOUR_OF_DAY),
                                d.get(java.util.Calendar.MINUTE),
                                label,
                            )
                        }
                        result.success(ok)
                    }
                    "cancelAlarm" -> {
                        AlarmScheduler.cancel(activity, call.argument<Int>("requestCode")!!)
                        result.success(true)
                    }
                    "openAlarmApp" -> {
                        activity.startActivity(
                            Intent(AlarmClock.ACTION_SHOW_ALARMS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        )
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }
        }
    }
}
