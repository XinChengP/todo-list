package io.github.xinchengp.todo_app

import android.app.KeyguardManager
import android.content.Context
import android.media.AudioAttributes
import android.media.AudioManager
import android.media.MediaPlayer
import android.media.RingtoneManager
import android.os.Build
import android.os.Bundle
import android.os.VibrationEffect
import android.os.Vibrator
import android.view.WindowManager
import android.widget.Button
import android.widget.LinearLayout
import android.widget.TextView
import io.flutter.embedding.android.FlutterActivity
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * 全屏闹钟界面（原生实现，不走 Flutter）。
 *
 * 为什么用原生而不是 Flutter：
 * - 闹钟要在锁屏上**立刻**显示，Flutter 首帧有延迟
 * - 这个页面只有标题 + 两个按钮，原生更稳，也不依赖 Flutter 引擎是否被回收
 *
 * 荣耀/MagicOS 关键点：
 * - setShowWhenLocked / setTurnScreenOn + FLAG_KEEP_SCREEN_ON：锁屏也能亮屏显示
 * - 播放系统闹钟铃声（Alarm 音频流）+ 循环震动，直到用户操作
 */
class AlarmActivity : FlutterActivity() {

    private var player: MediaPlayer? = null
    private var vibrator: Vibrator? = null
    private var label: String = "任务提醒"

    override fun onCreate(savedInstanceState: Bundle?) {
        // 必须在 super.onCreate 之前设置窗口属性
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
            setShowWhenLocked(true)
            setTurnScreenOn(true)
        } else {
            @Suppress("DEPRECATION")
            window.addFlags(
                WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or
                    WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON
            )
        }
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)

        super.onCreate(savedInstanceState)

        // 锁屏状态下也可以直接显示
        val km = getSystemService(Context.KEYGUARD_SERVICE) as KeyguardManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            km.requestDismissKeyguard(this, null)
        }

        label = intent.getStringExtra("label") ?: "任务提醒"
        // 不渲染 Flutter 内容：用原生布局盖住（引擎照常初始化，返回后主页可用）
        setContentView(buildLayout())
        startRinging()
    }

    private fun buildLayout(): LinearLayout {
        val now = SimpleDateFormat("HH:mm", Locale.getDefault()).format(Date())
        return LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setBackgroundColor(0xFF10151C.toInt())
            setPadding(64, 220, 64, 160)
            gravity = android.view.Gravity.CENTER_HORIZONTAL

            addView(TextView(this@AlarmActivity).apply {
                text = now
                textSize = 64f
                setTextColor(0xFFFFFFFF.toInt())
                gravity = android.view.Gravity.CENTER
            })

            addView(TextView(this@AlarmActivity).apply {
                text = label
                textSize = 22f
                setTextColor(0xFFE6EDF3.toInt())
                gravity = android.view.Gravity.CENTER
                setPadding(0, 40, 0, 0)
            })

            addView(TextView(this@AlarmActivity).apply {
                text = "任务清单 · 到点提醒"
                textSize = 13f
                setTextColor(0xFF8B98A5.toInt())
                gravity = android.view.Gravity.CENTER
                setPadding(0, 12, 0, 0)
            })

            addView(Button(this@AlarmActivity).apply {
                text = "知道了"
                textSize = 17f
                setOnClickListener { finishAndStop() }
                (layoutParams as? LinearLayout.LayoutParams)?.topMargin = 120
            }, LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT,
                LinearLayout.LayoutParams.WRAP_CONTENT
            ).apply { topMargin = 120 })

            addView(Button(this@AlarmActivity).apply {
                text = "稍后 5 分钟"
                textSize = 15f
                setOnClickListener {
                    // 5 分钟后重响
                    AlarmScheduler.schedule(
                        this@AlarmActivity,
                        System.currentTimeMillis() + 5 * 60 * 1000L,
                        label,
                        990001,
                    )
                    finishAndStop()
                }
            }, LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT,
                LinearLayout.LayoutParams.WRAP_CONTENT
            ).apply { topMargin = 16 })
        }
    }

    private fun startRinging() {
        // 闹钟铃声（走 ALARM 音频流：不受媒体音量影响，静音模式也能响）
        try {
            val uri = RingtoneManager.getDefaultUri(RingtoneManager.TYPE_ALARM)
                ?: RingtoneManager.getDefaultUri(RingtoneManager.TYPE_RINGTONE)
            player = MediaPlayer().apply {
                setAudioAttributes(
                    AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_ALARM)
                        .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                        .build()
                )
                setDataSource(this@AlarmActivity, uri)
                isLooping = true
                prepare()
                start()
            }
        } catch (_: Exception) {
        }

        try {
            vibrator = getSystemService(Context.VIBRATOR_SERVICE) as Vibrator
            val pattern = longArrayOf(0, 600, 600)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                vibrator?.vibrate(VibrationEffect.createWaveform(pattern, 0))
            } else {
                @Suppress("DEPRECATION")
                vibrator?.vibrate(pattern, 0)
            }
        } catch (_: Exception) {
        }

        // 兜底：把闹钟音量拉满，避免用户之前把闹钟调成 0 就完全听不到
        try {
            val am = getSystemService(Context.AUDIO_SERVICE) as AudioManager
            val max = am.getStreamMaxVolume(AudioManager.STREAM_ALARM)
            if (am.getStreamVolume(AudioManager.STREAM_ALARM) < max / 2) {
                am.setStreamVolume(AudioManager.STREAM_ALARM, max / 2, 0)
            }
        } catch (_: Exception) {
        }
    }

    private fun finishAndStop() {
        try {
            player?.stop()
            player?.release()
        } catch (_: Exception) {
        }
        player = null
        try {
            vibrator?.cancel()
        } catch (_: Exception) {
        }
        vibrator = null
        finish()
    }

    override fun onDestroy() {
        try {
            player?.stop()
            player?.release()
        } catch (_: Exception) {
        }
        try {
            vibrator?.cancel()
        } catch (_: Exception) {
        }
        super.onDestroy()
    }
}
