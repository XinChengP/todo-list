package io.github.xinchengp.todo_app

/**
 * 4x4 尺寸的卡片变体（320x336dp）：高度足够，最多显示 5 条任务。
 * 与 2x2/4x2 共用 TodoWidgetProvider 的渲染逻辑（按卡片高度自适应行数）。
 */
class TodoWidgetProvider4x4 : TodoWidgetProvider()
