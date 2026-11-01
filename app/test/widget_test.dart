import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:todo_app/db/database.dart';
import 'package:todo_app/main.dart';
import 'package:todo_app/providers.dart';

// 加载态的 CircularProgressIndicator 是无限动画，pumpAndSettle 永不返回；
// 用固定帧推进等待 drift 流出数据
Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

Future<void> _pumpApp(WidgetTester tester, AppDatabase db) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [databaseProvider.overrideWithValue(db)],
      child: const TodoApp(),
    ),
  );
  await _settle(tester);
}

/// 测试体末尾必须显式卸载组件树并在假时间轴上推进一帧：
/// riverpod 释放 drift 查询流时会登记零延时清理 Timer，
/// 若留给自动 teardown 处理，FakeAsync 里就是 Pending timers 报错。
Future<void> _unmount(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(seconds: 1));
}

void main() {
  testWidgets('添加任务 → 勾选完成 → 筛选切换', (tester) async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);

    await _pumpApp(tester, db);

    // 输入并添加任务
    await tester.enterText(find.byType(TextField), '写周报');
    await tester.tap(find.byIcon(Icons.send));
    await _settle(tester);
    expect(find.text('写周报'), findsOneWidget);

    // 勾选完成
    await tester.tap(find.byType(Checkbox));
    await _settle(tester);

    // "进行中"里应没有它
    await tester.tap(find.text('进行中'));
    await _settle(tester);
    expect(find.text('写周报'), findsNothing);

    // "已完成"里应有它
    await tester.tap(find.text('已完成'));
    await _settle(tester);
    expect(find.text('写周报'), findsOneWidget);

    await _unmount(tester);
  });

  testWidgets('编辑任务：改标题和优先级', (tester) async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);

    await _pumpApp(tester, db);

    await tester.enterText(find.byType(TextField), '旧标题');
    await tester.tap(find.byIcon(Icons.send));
    await _settle(tester);

    // 点任务打开编辑对话框
    await tester.tap(find.text('旧标题'));
    await _settle(tester);

    await tester.enterText(find.byKey(const ValueKey('edit-title')), '新标题');
    await tester.tap(find.text('高'));
    await tester.tap(find.text('保存'));
    await _settle(tester);

    expect(find.text('新标题'), findsOneWidget);
    expect(find.byIcon(Icons.flag), findsOneWidget); // 优先级>0 显示旗帜

    await _unmount(tester);
  });
}
