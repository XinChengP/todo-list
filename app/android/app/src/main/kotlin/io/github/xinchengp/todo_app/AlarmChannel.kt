package io.github.xinchengp.todo_app

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.provider.AlarmClock
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * 把任务提醒交给**系统闹钟 App**（而不是自己发通知）。
 *
 * 为什么这么做：
 * - 荣耀/华为等 ROM 对第三方后台进程和通知管控很严，自建通知经常被静默延迟或吞掉；
 *   系统闹钟走的是 AlarmManager + 系统时钟应用，不受这些限制
 * - 响铃、震动、全屏、锁屏显示、稍后提醒，全部由系统闹钟负责，体验就是"闹钟"
 *
 * 限制（如实告诉用户）：
 * - 系统闹钟是**一次性**的：到点响过后不会自动排下一次；
 *   周期任务的后续提醒由 App 下次启动/回前台时重新登记
 * - 需要系统里有闹钟应用（Android 标准 API，绝大多数 ROM 都有）
 */
class AlarmChannel(private val activity: Activity) {

    companion object {
        const val CHANNEL = "todo/system_alarm"

        fun register(engine: FlutterEngine, activity: Activity) {
            val ch = MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL)
            val impl = AlarmChannel(activity)
            ch.setMethodCallHandler { call, result ->
                when (call.method) {
                    "setAlarm" -> {
                        val hour = call.argument<Int>("hour") ?: 0
                        val minute = call.argument<Int>("minute") ?: 0
                        val label = call.argument<String>("label") ?: "任务提醒"
                        val skipUi = call.argument<Boolean>("skipUi") ?: true
                        result.success(impl.setAlarm(hour, minute, label, skipUi))
                    }
                    "isSupported" -> result.success(impl.isSupported())
                    "openAlarmApp" -> result.success(impl.openAlarmApp())
                    else -> result.notImplemented()
                }
            }
        }
    }

    /** 系统里是否有能接收 ACTION_SET_ALARM 的应用 */
    private fun isSupported(): Boolean {
        val intent = Intent(AlarmClock.ACTION_SET_ALARM).apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        return activity.packageManager.queryIntentActivities(intent, 0).isNotEmpty()
    }

    /**
     * 登记一个系统闹钟。
     * @param skipUi true 时直接创建（不弹系统确认页），App 在后台也能用
     * @return true 表示已交给系统闹钟
     */
    private fun setAlarm(hour: Int, minute: Int, label: String, skipUi: Boolean): Boolean {
        return try {
            val intent = Intent(AlarmClock.ACTION_SET_ALARM).apply {
                putExtra(AlarmClock.EXTRA_HOUR, hour)
                putExtra(AlarmClock.EXTRA_MINUTES, minute)
                putExtra(AlarmClock.EXTRA_MESSAGE, label)
                putExtra(AlarmClock.EXTRA_SKIP_UI, skipUi)
                // 不振动/不响铃的闹钟没意义，这里显式要求
                putExtra(AlarmClock.EXTRA_VIBRATE, true)
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            activity.startActivity(intent)
            true
        } catch (e: Exception) {
            // 部分 ROM 不支持 EXTRA_SKIP_UI，退化成打开系统闹钟页让用户确认
            try {
                val fallback = Intent(AlarmClock.ACTION_SET_ALARM).apply {
                    putExtra(AlarmClock.EXTRA_HOUR, hour)
                    putExtra(AlarmClock.EXTRA_MINUTES, minute)
                    putExtra(AlarmClock.EXTRA_MESSAGE, label)
                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                }
                activity.startActivity(fallback)
                true
            } catch (_: Exception) {
                false
            }
        }
    }

    /** 打开系统闹钟列表（诊断页用，方便用户核对） */
    private fun openAlarmApp(): Boolean {
        return try {
            val intent = Intent(AlarmClock.ACTION_SHOW_ALARMS).apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            activity.startActivity(intent)
            true
        } catch (_: Exception) {
            false
        }
    }
}
