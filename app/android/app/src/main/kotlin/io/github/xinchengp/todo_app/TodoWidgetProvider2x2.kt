package io.github.xinchengp.todo_app

/**
 * 2x2 尺寸的卡片变体：MagicOS 卡片选择器按 Provider 区分默认尺寸，
 * 复用 TodoWidgetProvider 的全部渲染逻辑（本身已按卡片高度自适应行数）。
 */
class TodoWidgetProvider2x2 : TodoWidgetProvider()
