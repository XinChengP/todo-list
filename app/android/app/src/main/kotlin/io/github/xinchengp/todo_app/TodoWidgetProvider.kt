package io.github.xinchengp.todo_app

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.Context
import android.content.Intent
import android.graphics.Paint
import android.net.Uri
import android.os.Bundle
import android.view.View
import android.widget.RemoteViews
import androidx.core.content.ContextCompat
import es.antonborri.home_widget.HomeWidgetLaunchIntent
import org.json.JSONObject

/**
 * 荣耀/MagicOS 服务卡片 Provider（2x2 与 4x2 两个尺寸变体共享本类）。
 *
 * 数据来源：home_widget 插件的 SharedPreferences（文件名固定 HomeWidgetPreferences），
 * Flutter 侧每次任务变化都会写入 key = "todo_snapshot" 的 JSON 快照并触发刷新。
 *
 * 交互（两个点击区域在布局上完全并列，不存在互相遮挡）：
 * - 点标题 / 信息区 / 卡片空白 → 打开应用（todoapp://widget-open）
 * - 点任务左侧圆点 → 发广播给 [WidgetToggleReceiver]，在本地直接写库并重渲染卡片，
 *   不启动 Activity，所以不会跳进 App
 *
 * 打开 App 的 PendingIntent 必须用 home_widget 的 [HomeWidgetLaunchIntent]：
 * 1. 它带 HOME_WIDGET_LAUNCH_ACTION，插件才会把 URI 交给 Dart 的 widgetClicked
 *    / initiallyLaunchedFromHomeWidget（手写 ACTION_VIEW 会被插件忽略）；
 * 2. targetSdk>=35 时它会带上 MODE_BACKGROUND_ACTIVITY_START_ALLOWED，
 *    否则 Android 15+ 会静默拦截"后台 App 由 PendingIntent 拉起 Activity"。
 *
 * 荣耀规范适配：
 * - 尺寸自适应：官方标准尺寸 1x2/2x2/2x4/4x4，按卡片实际高度动态决定任务行数
 * - 深色模式：颜色全部走 values/values-night 颜色资源，系统切换自动换肤
 */
open class TodoWidgetProvider : AppWidgetProvider() {

    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray,
    ) {
        for (appWidgetId in appWidgetIds) {
            render(context, appWidgetManager, appWidgetId)
        }
    }

    // MagicOS 卡片被拖拽/改变尺寸时触发重排（每种标准尺寸一次）
    override fun onAppWidgetOptionsChanged(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetId: Int,
        newOptions: Bundle,
    ) {
        render(context, appWidgetManager, appWidgetId)
    }

    private data class TaskInfo(
        val id: String,
        val title: String,
        val done: Boolean,
        val dueLabel: String?,
        val priority: Int,
        val overdue: Boolean,
        val repeatLabel: String,
    )

    private data class Snapshot(val tasks: List<TaskInfo>, val activeCount: Int)

    private fun readSnapshot(context: Context): Snapshot {
        val raw = runCatching {
            context.getSharedPreferences("HomeWidgetPreferences", Context.MODE_PRIVATE)
                .getString("todo_snapshot", null)
        }.getOrNull() ?: return Snapshot(emptyList(), 0)
        return runCatching {
            val obj = JSONObject(raw)
            val tasks = mutableListOf<TaskInfo>()
            val arr = obj.optJSONArray("tasks")
            if (arr != null) {
                for (i in 0 until arr.length()) {
                    val t = arr.getJSONObject(i)
                    tasks.add(
                        TaskInfo(
                            id = t.optString("id", ""),
                            title = t.optString("title", ""),
                            done = t.optBoolean("done", false),
                            dueLabel = if (t.isNull("due")) null else t.optString("due"),
                            priority = t.optInt("priority", 0),
                            overdue = t.optBoolean("overdue", false),
                            repeatLabel = t.optString("repeat", ""),
                        ),
                    )
                }
            }
            Snapshot(tasks, obj.optInt("activeCount", 0))
        }.getOrDefault(Snapshot(emptyList(), 0))
    }

    private fun render(context: Context, manager: AppWidgetManager, appWidgetId: Int) {
        val snap = readSnapshot(context)

        // 依卡片实际高度决定任务行数（对应官方标准尺寸档位）：
        // 固定开销 = 上下内边距 16 + 标题栏 ~19 + 栏后间距 4 ≈ 39dp，
        // 每行约 35dp、行间距 3dp → 第 n 行需要 38n-3dp。
        // 152dp 高（2x2 / 2x4）→ 3 行；336dp 高（4x4）→ 5 行。
        val opts = manager.getAppWidgetOptions(appWidgetId)
        val heightDp = maxOf(
            opts.getInt(AppWidgetManager.OPTION_APPWIDGET_MAX_HEIGHT),
            opts.getInt(AppWidgetManager.OPTION_APPWIDGET_MIN_HEIGHT),
        )
        val rowCount = if (heightDp <= 0) 3 else ((heightDp - 36) / 38).coerceIn(1, 5)

        val views = RemoteViews(context.packageName, R.layout.todo_widget)
        views.setTextViewText(R.id.title, "待办")
        views.setTextViewText(R.id.count, "${snap.activeCount} 项")

        val titleColor = ContextCompat.getColor(context, R.color.pill_text)
        val doneColor = ContextCompat.getColor(context, R.color.done_text)
        val accentColor = ContextCompat.getColor(context, R.color.accent)
        val markColor = ContextCompat.getColor(context, R.color.circle_mark)
        val metaColor = ContextCompat.getColor(context, R.color.count_text)
        val urgentColor = ContextCompat.getColor(context, R.color.meta_urgent)

        // 打开应用：标题栏 / 每行信息区 / 底部空白（均与圆点兄弟级，不会抢圆点命中）
        val openApp = launchIntent(context, Uri.parse("todoapp://widget-open"))
        views.setOnClickPendingIntent(R.id.header_bar, openApp)
        views.setOnClickPendingIntent(R.id.spacer, openApp)

        for (i in 0 until 5) {
            if (i >= rowCount) {
                views.setViewVisibility(rowIds[i], View.GONE)
                continue
            }
            val task = snap.tasks.getOrNull(i)
            if (task == null) {
                views.setViewVisibility(rowIds[i], View.GONE)
                continue
            }
            views.setViewVisibility(rowIds[i], View.VISIBLE)

            // 圆点标记 + 文本
            views.setTextViewText(markIds[i], if (task.done) "●" else "○")
            views.setTextColor(markIds[i], if (task.done) accentColor else markColor)
            views.setContentDescription(
                markIds[i],
                if (task.done) "标记「${task.title}」为未完成" else "标记「${task.title}」为已完成",
            )
            val priorityMark = if (task.priority >= 3) " ‼" else ""
            views.setTextViewText(
                titleIds[i],
                (if (task.done) "✓ " else "") + task.title + priorityMark,
            )
            views.setTextColor(titleIds[i], if (task.done) doneColor else titleColor)
            // 完成后加删除线，让"已勾选但还留在卡片上"一眼可辨
            views.setInt(
                titleIds[i],
                "setPaintFlags",
                if (task.done) {
                    Paint.STRIKE_THRU_TEXT_FLAG or Paint.ANTI_ALIAS_FLAG
                } else {
                    Paint.ANTI_ALIAS_FLAG
                },
            )

            // 元信息：截止日期（逾期红色）+ 周期标记 + 重要级
            val metaParts = mutableListOf<String>()
            if (!task.dueLabel.isNullOrEmpty()) metaParts.add(task.dueLabel)
            if (task.repeatLabel.isNotEmpty()) metaParts.add("↻ ${task.repeatLabel}")
            if (task.priority > 0) metaParts.add("P${task.priority}")
            views.setViewVisibility(metaIds[i], View.VISIBLE)
            views.setTextViewText(metaIds[i], metaParts.joinToString(" · "))
            views.setTextColor(
                metaIds[i],
                if (!task.done && task.overdue) urgentColor else metaColor,
            )

            // 信息区（任务名 + 元信息）→ 打开应用
            views.setOnClickPendingIntent(infoIds[i], openApp)

            // 圆点独立命中 → 本地切换完成状态（广播，不拉起 App 界面）
            views.setOnClickPendingIntent(markIds[i], togglePendingIntent(context, i, task.id))
        }

        manager.updateAppWidget(appWidgetId, views)
    }

    /**
     * 构造带 home_widget 启动 action 的 PendingIntent（用于打开 App）。
     * 插件只认这个 action；SDK 35+ 同时写入后台拉起白名单参数。
     */
    private fun launchIntent(context: Context, uri: Uri) =
        HomeWidgetLaunchIntent.getActivity(context, MainActivity::class.java, uri)

    /**
     * 圆点点击：发广播给 [WidgetToggleReceiver] 本地写库，
     * 不经过 Activity，所以桌面点一下不会跳进 App。
     */
    private fun togglePendingIntent(context: Context, row: Int, taskId: String) =
        PendingIntent.getBroadcast(
            context,
            TOGGLE_REQUEST_BASE + row, // 每行独立 requestCode，避免 PendingIntent 互相覆盖
            Intent(context, WidgetToggleReceiver::class.java).apply {
                action = WidgetToggleReceiver.ACTION_TOGGLE
                data = Uri.Builder()
                    .scheme("todoapp")
                    .authority("widget-toggle")
                    .appendQueryParameter("id", taskId)
                    .build()
            },
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )

    companion object {
        // 圆点广播的 requestCode 起点（0 留给"打开应用"的 PendingIntent）
        private const val TOGGLE_REQUEST_BASE = 100

        private val rowIds =
            intArrayOf(R.id.row_0, R.id.row_1, R.id.row_2, R.id.row_3, R.id.row_4)
        private val markIds =
            intArrayOf(R.id.mark_0, R.id.mark_1, R.id.mark_2, R.id.mark_3, R.id.mark_4)
        private val infoIds =
            intArrayOf(R.id.info_0, R.id.info_1, R.id.info_2, R.id.info_3, R.id.info_4)
        private val titleIds =
            intArrayOf(R.id.title_0, R.id.title_1, R.id.title_2, R.id.title_3, R.id.title_4)
        private val metaIds =
            intArrayOf(R.id.meta_0, R.id.meta_1, R.id.meta_2, R.id.meta_3, R.id.meta_4)
    }
}
