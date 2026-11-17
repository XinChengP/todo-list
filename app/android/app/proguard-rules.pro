# ---------- flutter_local_notifications ----------
# 插件用 Gson 读写"已排程通知"列表（TypeToken<List<ScheduledNotification>>）。
# release 构建默认开 R8，会裁掉泛型签名 → 抛 "Missing type parameter"，
# 导致每次 zonedSchedule 在 loadScheduledNotifications 阶段就失败（一条都排不上）。
-keep class com.dexterous.flutterlocalnotifications.** { *; }
-keepattributes Signature
-keepattributes *Annotation*
-keep class com.google.gson.** { *; }
-keepclassmembers,allowobfuscation class * {
    @com.google.gson.annotations.SerializedName <fields>;
}
