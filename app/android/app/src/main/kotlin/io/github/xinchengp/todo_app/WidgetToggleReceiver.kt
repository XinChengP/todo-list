package io.github.xinchengp.todo_app

import android.appwidget.AppWidgetManager
import android.content.BroadcastReceiver
import android.content.ComponentName
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.database.sqlite.SQLiteDatabase
import org.json.JSONObject

/**
 * 桌面卡片「圆点」点击的本地处理：直接写 SQLite + 更新卡片快照 + 刷新卡片，
 * **不拉起 App 界面**（用广播而不是 Activity，系统不会把应用切到前台）。
 *
 * 写入规则必须与 Dart 侧 TaskRepository._editField 完全一致：
 * - completed_at 取反（完成写时间戳 / 取消完成写 NULL）
 * - field_ts["completed_at"] = now（字段级 LWW 时间戳）
 * - updated_at = now，dirty = 1（等下次 App 启动/手动同步时上传）
 * - now 按行单调递增：同一毫秒连点两次也不会因时间戳相同而丢一次修改
 *
 * 交互约定：勾选后**任务原地保留**，只是变成 ✓ + 删除线 + 置灰；
 * 快照的增删排序仍由 App 负责，等 App 下次刷新卡片时它才自然消失。
 */
class WidgetToggleReceiver : BroadcastReceiver() {

    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != ACTION_TOGGLE) return
        val id = intent.data?.getQueryParameter("id")
        if (id.isNullOrEmpty()) return

        // onReceive 只有约 10 秒且不允许阻塞主线程，goAsync + 工作线程
        val appContext = context.applicationContext
        val pending = goAsync()
        Thread {
            try {
                toggle(appContext, id)
            } catch (_: Throwable) {
                // 数据库被锁/文件缺失：静默失败，卡片保持原状
            } finally {
                pending.finish()
            }
        }.start()
    }

    private fun toggle(context: Context, id: String) {
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        // 路径由 App 启动时写入（Flutter 侧 path_provider 的真实路径，避免硬编码）
        val dbPath = prefs.getString(KEY_DB_PATH, null) ?: return

        val nowDone: Boolean
        val db = SQLiteDatabase.openDatabase(dbPath, null, SQLiteDatabase.OPEN_READWRITE)
        try {
            // 用 rawQuery 执行 pragma：execSQL 对返回结果集的 pragma 兼容性不稳定
            db.rawQuery("PRAGMA busy_timeout = 3000", null).use { it.moveToFirst() }
            nowDone = flipCompleted(db, id) ?: return
        } finally {
            db.close()
        }

        updateSnapshotInPlace(prefs, id, nowDone)
        refreshWidgets(context)
    }

    /**
     * 切换完成状态。返回切换后的完成状态；任务不存在/已删除时返回 null。
     */
    private fun flipCompleted(db: SQLiteDatabase, id: String): Boolean? {
        var completedAt: Long? = null
        var updatedAt = 0L
        var fieldTs = JSONObject()
        db.rawQuery(
            "SELECT completed_at, updated_at, field_ts FROM tasks " +
                "WHERE id = ? AND deleted_at IS NULL",
            arrayOf(id),
        ).use { c ->
            if (!c.moveToFirst()) return null
            completedAt = if (c.isNull(0)) null else c.getLong(0)
            updatedAt = c.getLong(1)
            fieldTs = runCatching { JSONObject(c.getString(2) ?: "{}") }
                .getOrDefault(JSONObject())
        }

        val now = maxOf(
            System.currentTimeMillis(),
            updatedAt + 1,
            fieldTs.optLong("completed_at", 0L) + 1,
        )
        fieldTs.put("completed_at", now)

        val markingDone = completedAt == null
        val values = ContentValues().apply {
            if (markingDone) put("completed_at", now) else putNull("completed_at")
            put("updated_at", now)
            put("field_ts", fieldTs.toString())
            put("dirty", 1)
        }
        return if (db.update("tasks", values, "id = ?", arrayOf(id)) > 0) markingDone else null
    }

    /**
     * 只翻转快照里这一行的 done 标记（任务留在原位），并同步活跃计数。
     * 不做增删/重排：那部分保持 App 侧为唯一权威，避免原生重复业务规则。
     */
    private fun updateSnapshotInPlace(prefs: SharedPreferences, id: String, done: Boolean) {
        val raw = prefs.getString(KEY_SNAPSHOT, null) ?: return
        val obj = runCatching { JSONObject(raw) }.getOrNull() ?: return
        val arr = obj.optJSONArray("tasks") ?: return

        var changed = false
        var removed = false
        for (i in 0 until arr.length()) {
            val t = arr.optJSONObject(i) ?: continue
            if (t.optString("id") != id) continue
            val repeating = t.optString("repeat", "").isNotEmpty()
            if (repeating && done) {
                // 周期任务：勾掉的是"这一次"，直接从卡片移除；
                // App 下次刷新快照时会带着新日期回来（不会先显示一个已完成占位）
                arr.remove(i)
                removed = true
                changed = true
            } else if (t.optBoolean("done") != done) {
                t.put("done", done)
                changed = true
            }
            break
        }
        if (!changed) return

        val count = obj.optInt("activeCount", 0)
        obj.put(
            "activeCount",
            if (removed) (count - 1).coerceAtLeast(0)
            else (count + if (done) -1 else 1).coerceAtLeast(0),
        )
        obj.put("updatedAt", System.currentTimeMillis())
        prefs.edit().putString(KEY_SNAPSHOT, obj.toString()).commit()
    }

    /** 所有尺寸的 Provider 都刷新（卡片立即显示新状态） */
    private fun refreshWidgets(context: Context) {
        val manager = AppWidgetManager.getInstance(context)
        for (cls in PROVIDERS) {
            val ids = manager.getAppWidgetIds(ComponentName(context, cls))
            if (ids.isEmpty()) continue
            context.sendBroadcast(
                Intent(context, cls).apply {
                    action = AppWidgetManager.ACTION_APPWIDGET_UPDATE
                    putExtra(AppWidgetManager.EXTRA_APPWIDGET_IDS, ids)
                },
            )
        }
    }

    companion object {
        const val ACTION_TOGGLE = "io.github.xinchengp.todo_app.action.WIDGET_TOGGLE"

        // 与 home_widget 插件共用同一个 SharedPreferences 文件
        private const val PREFS = "HomeWidgetPreferences"
        private const val KEY_SNAPSHOT = "todo_snapshot"
        private const val KEY_DB_PATH = "todo_db_path"

        private val PROVIDERS = listOf(
            TodoWidgetProvider::class.java,
            TodoWidgetProvider2x2::class.java,
            TodoWidgetProvider4x4::class.java,
        )
    }
}
