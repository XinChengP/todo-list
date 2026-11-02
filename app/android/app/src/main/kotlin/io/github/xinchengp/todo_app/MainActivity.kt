package io.github.xinchengp.todo_app

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // 桌面卡片点击的启动 Intent 只能消费一次：Dart 处理完后清掉 data，
        // 否则进程被系统回收重建时同一个 URI 会再次执行（完成状态被又翻回去）。
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "todo/widget_intent")
            .setMethodCallHandler { call, result ->
                if (call.method == "consumeInitialIntent") {
                    intent?.data = null
                    result.success(null)
                } else {
                    result.notImplemented()
                }
            }
    }
}
