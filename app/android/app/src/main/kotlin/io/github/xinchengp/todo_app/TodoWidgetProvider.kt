package io.github.xinchengp.todo_app

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.view.View
import android.widget.RemoteViews
import androidx.core.content.ContextCompat
import org.json.JSONObject

/**
 * 荣耀/MagicOS 服务卡片 Provider（2x2 与 4x2 两个尺寸变体共享本类）。
 *
 * 数据来源：home_widget 插件的 SharedPreferences（文件名固定 HomeWidgetPreferences），
 * Flutter 侧每次任务变化都会写入 key = "todo_snapshot" 的 JSON 快照并触发刷新。
 *
 * 交互：
 * - 点卡片其他区域 → 打开应用
 * - 点任务左侧圆点 → 深链接 todoapp://widget-toggle?id=xxx，
 *   App 内接收后切换完成状态并静默同步
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
                        ),
                    )
                }
            }
            Snapshot(tasks, obj.optInt("activeCount", 0))
        }.getOrDefault(Snapshot(emptyList(), 0))
    }

    private fun render(context: Context, manager: AppWidgetManager, appWidgetId: Int) {
        val snap = readSnapshot(context)

        // 依卡片实际高度决定任务行数（对应官方标准尺寸档位）
        val opts = manager.getAppWidgetOptions(appWidgetId)
        val heightDp = maxOf(
            opts.getInt(AppWidgetManager.OPTION_APPWIDGET_MAX_HEIGHT),
            opts.getInt(AppWidgetManager.OPTION_APPWIDGET_MIN_HEIGHT),
        )
        val rowCount = if (heightDp <= 0) 3 else ((heightDp - 74) / 38).coerceIn(1, 5)

        val views = RemoteViews(context.packageName, R.layout.todo_widget)
        views.setTextViewText(R.id.title, "待办")
        views.setTextViewText(R.id.count, "${snap.activeCount} 项")

        val titleColor = ContextCompat.getColor(context, R.color.pill_text)
        val doneColor = ContextCompat.getColor(context, R.color.done_text)
        val accentColor = ContextCompat.getColor(context, R.color.accent)
        val markColor = ContextCompat.getColor(context, R.color.circle_mark)
        val metaColor = ContextCompat.getColor(context, R.color.count_text)
        val urgentColor = ContextCompat.getColor(context, R.color.meta_urgent)

        val openApp = openAppIntent(context)
        views.setOnClickPendingIntent(R.id.widget_root, openApp)

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
            val priorityMark = if (task.priority >= 3) " ‼" else ""
            views.setTextViewText(
                titleIds[i],
                (if (task.done) "✓ " else "") + task.title + priorityMark,
            )
            views.setTextColor(titleIds[i], if (task.done) doneColor else titleColor)

            // 元信息：截止日期（逾期红色）+ 重要级
            val metaParts = mutableListOf<String>()
            if (task.dueLabel != null) metaParts.add(task.dueLabel)
            if (task.priority > 0) metaParts.add("P${task.priority}")
            views.setViewVisibility(metaIds[i], View.VISIBLE)
            views.setTextViewText(metaIds[i], metaParts.joinToString(" · "))
            views.setTextColor(
                metaIds[i],
                if (!task.done && task.overdue) urgentColor else metaColor,
            )

            // 点击圆点 → 打开应用并切换该任务的完成状态
            val toggleIntent = Intent(
                Intent.ACTION_VIEW,
                Uri.parse("todoapp://widget-toggle?id=${Uri.encode(task.id)}"),
            ).apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
                component = ComponentName(context.packageName, "$context.packageName.MainActivity")
            }
            views.setOnClickPendingIntent(
                markIds[i],
                PendingIntent.getActivity(
                    context,
                    i + 1, // 每行独立 requestCode，配合不同 data URI 互不覆盖
                    toggleIntent,
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
                ),
            )
        }

        manager.updateAppWidget(appWidgetId, views)
    }

    private fun openAppIntent(context: Context): PendingIntent =
        PendingIntent.getActivity(
            context,
            0,
            Intent(Intent.ACTION_VIEW, Uri.parse("todoapp://widget-open")).apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
                component = ComponentName(context.packageName, "$context.packageName.MainActivity")
            },
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )

    companion object {
        private val rowIds =
            intArrayOf(R.id.row_0, R.id.row_1, R.id.row_2, R.id.row_3, R.id.row_4)
        private val markIds =
            intArrayOf(R.id.mark_0, R.id.mark_1, R.id.mark_2, R.id.mark_3, R.id.mark_4)
        private val titleIds =
            intArrayOf(R.id.title_0, R.id.title_1, R.id.title_2, R.id.title_3, R.id.title_4)
        private val metaIds =
            intArrayOf(R.id.meta_0, R.id.meta_1, R.id.meta_2, R.id.meta_3, R.id.meta_4)
    }
}
