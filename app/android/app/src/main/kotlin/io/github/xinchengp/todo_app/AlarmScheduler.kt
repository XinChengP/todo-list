package io.github.xinchengp.todo_app

import android.app.AlarmManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.AlarmClock
import android.util.Log
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * 荣耀 / MagicOS 适配的到点提醒。
 *
 * 为什么不只调 ACTION_SET_ALARM：
 * - 那只是"往系统闹钟列表里塞一条"，MagicOS 可能弹确认页、也可能被后台策略拦下
 * - 我们需要应用自己的闹钟：到点必须响，且能在锁屏上全屏唤起
 *
 * 这里用 [AlarmManager.setAlarmClock]（Android 官方给"用户可见闹钟"的 API）：
 * - 系统按闹钟对待：**Doze / 省电模式下也会准时触发**，参与免打扰的闹钟例外
 * - 会显示在系统状态栏的闹钟图标里，用户能看见"有闹钟在等"
 * - 触发后由 [ReminderReceiver] 拉起全屏 [AlarmActivity] 并响铃
 *
 * 同时保留"复制一份到系统时钟 App"（AlarmClock.ACTION_SET_ALARM）：
 * MagicOS 会把它显示在「时钟 → 闹钟」里，用户可自行管理，双保险。
 */
object AlarmScheduler {
    private const val TAG = "TodoAlarm"
    const val ACTION_FIRE = "io.github.xinchengp.todo_app.ALARM_FIRE"

    fun schedule(context: Context, atMs: Long, label: String, requestCode: Int): Boolean {
        return try {
            val am = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager

            // 1) 应用自己的精确闹钟（核心路径）
            val fire = Intent(context, ReminderReceiver::class.java).apply {
                action = ACTION_FIRE
                data = Uri.parse("todoapp://alarm/$requestCode") // 每条独立，避免覆盖
                putExtra("label", label)
            }
            val pi = PendingIntent.getBroadcast(
                context,
                requestCode,
                fire,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
            val show = Intent(context, MainActivity::class.java).apply {
                putExtra("from_alarm", true)
            }
            val showPi = PendingIntent.getActivity(
                context,
                requestCode,
                show,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
                // setAlarmClock 是系统认定的"闹钟"，最不容易被 ROM 管控
                am.setAlarmClock(AlarmManager.AlarmClockInfo(atMs, showPi), pi)
            } else {
                am.setExact(AlarmManager.RTC_WAKEUP, atMs, pi)
            }
            Log.i(TAG, "scheduled at=$atMs label=$label")
            true
        } catch (e: Exception) {
            Log.e(TAG, "schedule failed", e)
            false
        }
    }

    /**
     * 另外在系统时钟 App 里也登记一条（用户能在「时钟 → 闹钟」看到/管理）。
     * 失败静默：这只是双保险，不是主路径。
     */
    fun mirrorToClockApp(context: Context, hour: Int, minute: Int, label: String) {
        try {
            val i = Intent(AlarmClock.ACTION_SET_ALARM).apply {
                putExtra(AlarmClock.EXTRA_HOUR, hour)
                putExtra(AlarmClock.EXTRA_MINUTES, minute)
                putExtra(AlarmClock.EXTRA_MESSAGE, label)
                putExtra(AlarmClock.EXTRA_SKIP_UI, true)
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            context.startActivity(i)
        } catch (_: Exception) {
            // 没闹钟应用 / ROM 禁止后台启动界面：忽略
        }
    }

    fun cancel(context: Context, requestCode: Int) {
        try {
            val fire = Intent(context, ReminderReceiver::class.java).apply {
                action = ACTION_FIRE
                data = Uri.parse("todoapp://alarm/$requestCode")
            }
            val pi = PendingIntent.getBroadcast(
                context,
                requestCode,
                fire,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
            (context.getSystemService(Context.ALARM_SERVICE) as AlarmManager).cancel(pi)
        } catch (_: Exception) {
        }
    }
}

/** 闹钟触发：拉起全屏闹钟界面 */
class ReminderReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val label = intent.getStringExtra("label") ?: "任务提醒"
        val full = Intent(context, AlarmActivity::class.java).apply {
            addFlags(
                Intent.FLAG_ACTIVITY_NEW_TASK or
                    Intent.FLAG_ACTIVITY_CLEAR_TOP or
                    Intent.FLAG_ACTIVITY_EXCLUDE_FROM_RECENTS // 不进最近任务
            )
            putExtra("label", label)
        }
        try {
            context.startActivity(full)
        } catch (e: Exception) {
            Log.e("TodoAlarm", "start AlarmActivity failed", e)
        }
    }
}

/**
 * 开机后重新登记闹钟。
 * AlarmManager 的闹钟在重启后会丢失（setAlarmClock 也一样），
 * 这里开机时通知 Flutter 侧重新排程（Flutter 侧从数据库重算，简单可靠）。
 */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val action = intent.action ?: return
        if (action != Intent.ACTION_BOOT_COMPLETED &&
            action != Intent.ACTION_MY_PACKAGE_REPLACED &&
            action != "android.intent.action.QUICKBOOT_POWERON"
        ) {
            return
        }
        // 拉起主界面但不显示（Flutter 侧启动时会自动重排闹钟）
        try {
            val i = Intent(context, MainActivity::class.java).apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                putExtra("boot_restore", true)
            }
            context.startActivity(i)
        } catch (_: Exception) {
        }
    }
}
