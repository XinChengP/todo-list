import 'package:flutter/material.dart';

import '../repo/repeat.dart';
import 'format.dart' show dueLabel;

/// 规则编辑结果：changed=false 表示取消
typedef RepeatRuleResult = ({bool changed, RepeatRule? rule});

/// 周期规则编辑器（P1）：每周多选 / 每月指定日·月末·第 N 个周几 / 每年 / 结束条件
Future<RepeatRuleResult?> showRepeatRuleDialog(
  BuildContext context, {
  RepeatRule? initial,
  int? dueAt,
}) {
  return showDialog<RepeatRuleResult>(
    context: context,
    builder: (_) => _RepeatRuleDialog(initial: initial, dueAt: dueAt),
  );
}

const _wdNames = ['一', '二', '三', '四', '五', '六', '日'];

class _RepeatRuleDialog extends StatefulWidget {
  const _RepeatRuleDialog({this.initial, this.dueAt});

  final RepeatRule? initial;
  final int? dueAt;

  @override
  State<_RepeatRuleDialog> createState() => _RepeatRuleDialogState();
}

class _RepeatRuleDialogState extends State<_RepeatRuleDialog> {
  late String _unit;
  late int _n;
  late List<int> _weekdays;
  late String _monthMode;
  late int _dowIndex;
  late int _anchorDay;
  late int _yearMonth;
  late bool _enabled;
  late bool _hasUntil;
  late bool _hasMax;
  int? _until;
  late int _max;

  @override
  void initState() {
    super.initState();
    final r = widget.initial;
    _unit = r?.unit ?? 'day';
    _n = r?.n ?? 1;
    _weekdays = [...(r?.weekdays ?? const [])];
    _monthMode = r?.monthMode ?? 'dom';
    _dowIndex = r?.dowIndex ?? 1;
    _anchorDay = r?.anchorDay ??
        _dayOf(widget.dueAt) ??
        DateTime.now().day;
    _yearMonth = r?.month ?? DateTime.now().month;
    _enabled = r != null;
    _hasUntil = r?.until != null;
    _hasMax = r?.max != null;
    _until = r?.until;
    _max = r?.max ?? 10;
  }

  static int? _dayOf(int? ms) =>
      ms == null ? null : DateTime.fromMillisecondsSinceEpoch(ms).day;

  RepeatRule? _build() {
    if (!_enabled) return null;
    if (_unit == 'week' && _weekdays.isEmpty) _weekdays = [DateTime.now().weekday];
    return RepeatRule(
      unit: _unit,
      n: _n.clamp(1, 99),
      weekdays: _unit == 'week' || (_unit == 'month' && _monthMode == 'dow')
          ? (_weekdays.isEmpty ? [DateTime.now().weekday] : _weekdays)
          : const [],
      monthMode: _monthMode,
      dowIndex: _unit == 'month' && _monthMode == 'dow' ? _dowIndex : null,
      anchorDay: _unit == 'year' || (_unit == 'month' && _monthMode == 'dom')
          ? _anchorDay.clamp(1, 31)
          : _anchorDay.clamp(1, 31),
      month: _unit == 'year' ? _yearMonth : null,
      until: _hasUntil ? _until : null,
      max: _hasMax ? _max.clamp(1, 999) : null,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final preview = _build();
    final next = preview == null
        ? null
        : nextAfter(
            preview,
            from: DateTime.fromMillisecondsSinceEpoch(
                widget.dueAt ?? DateTime.now().millisecondsSinceEpoch),
          );

    return AlertDialog(
      title: const Text('重复'),
      content: SizedBox(
        width: double.infinity,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              DropdownButton<String>(
                isExpanded: true,
                value: _enabled ? _unit : 'none',
                items: const [
                  DropdownMenuItem(value: 'none', child: Text('不重复')),
                  DropdownMenuItem(value: 'day', child: Text('每天')),
                  DropdownMenuItem(value: 'week', child: Text('每周')),
                  DropdownMenuItem(value: 'month', child: Text('每月')),
                  DropdownMenuItem(value: 'year', child: Text('每年')),
                ],
                onChanged: (v) => setState(() {
                  if (v == null) return;
                  if (v == 'none') {
                    _enabled = false;
                  } else {
                    _enabled = true;
                    _unit = v;
                    if (_unit == 'week' && _weekdays.isEmpty) {
                      _weekdays = [DateTime.now().weekday];
                    }
                  }
                }),
              ),
              if (_enabled) ...[
                const SizedBox(height: 8),
                Row(
                  children: [
                    const Text('每'),
                    const SizedBox(width: 8),
                    SizedBox(
                      width: 64,
                      child: TextFormField(
                        key: const ValueKey('repeat-n'),
                        initialValue: '$_n',
                        keyboardType: TextInputType.number,
                        textAlign: TextAlign.center,
                        decoration: const InputDecoration(isDense: true),
                        onChanged: (s) {
                          final v = int.tryParse(s);
                          if (v != null) setState(() => _n = v.clamp(1, 99));
                        },
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(repeatUnitName(_unit)),
                  ],
                ),
                const SizedBox(height: 8),

                // 每周：星期多选
                if (_unit == 'week') ...[
                  Wrap(
                    spacing: 6,
                    children: [
                      for (final w in const [1, 2, 3, 4, 5, 6, 7])
                        FilterChip(
                          label: Text('周${_wdNames[w - 1]}'),
                          selected: _weekdays.contains(w),
                          onSelected: (on) => setState(() {
                            if (on) {
                              _weekdays.add(w);
                            } else {
                              _weekdays.remove(w);
                            }
                            _weekdays.sort();
                          }),
                        ),
                      ActionChip(
                        label: const Text('工作日'),
                        onPressed: () =>
                            setState(() => _weekdays = [1, 2, 3, 4, 5]),
                      ),
                    ],
                  ),
                ],

                // 每月：指定日 / 月末 / 第 N 个周几
                if (_unit == 'month') ...[
                  SegmentedButton<String>(
                    segments: const [
                      ButtonSegment(value: 'dom', label: Text('指定日')),
                      ButtonSegment(value: 'last', label: Text('月末')),
                      ButtonSegment(value: 'dow', label: Text('第 N 个')),
                    ],
                    selected: {_monthMode},
                    onSelectionChanged: (s) =>
                        setState(() => _monthMode = s.first),
                  ),
                  const SizedBox(height: 8),
                  if (_monthMode == 'dom')
                    Row(
                      children: [
                        const Text('日'),
                        const SizedBox(width: 8),
                        SizedBox(
                          width: 64,
                          child: TextFormField(
                            initialValue: '$_anchorDay',
                            keyboardType: TextInputType.number,
                            textAlign: TextAlign.center,
                            decoration: const InputDecoration(
                                isDense: true, helperText: '29-31 会自动夹紧'),
                            onChanged: (s) {
                              final v = int.tryParse(s);
                              if (v != null) {
                                setState(() => _anchorDay = v.clamp(1, 31));
                              }
                            },
                          ),
                        ),
                      ],
                    ),
                  if (_monthMode == 'dow')
                    Row(
                      children: [
                        DropdownButton<int>(
                          value: _dowIndex,
                          items: const [
                            DropdownMenuItem(value: 1, child: Text('第 1 个')),
                            DropdownMenuItem(value: 2, child: Text('第 2 个')),
                            DropdownMenuItem(value: 3, child: Text('第 3 个')),
                            DropdownMenuItem(value: 4, child: Text('第 4 个')),
                            DropdownMenuItem(value: -1, child: Text('最后一个')),
                          ],
                          onChanged: (v) =>
                              setState(() => _dowIndex = v ?? 1),
                        ),
                        const SizedBox(width: 8),
                        DropdownButton<int>(
                          value: _weekdays.isEmpty ? 1 : _weekdays.first,
                          items: [
                            for (final w in const [1, 2, 3, 4, 5, 6, 7])
                              DropdownMenuItem(
                                  value: w, child: Text('周${_wdNames[w - 1]}')),
                          ],
                          onChanged: (v) =>
                              setState(() => _weekdays = [v ?? 1]),
                        ),
                      ],
                    ),
                ],

                // 每年：月 + 日
                if (_unit == 'year') ...[
                  Row(
                    children: [
                      const Text('每年'),
                      const SizedBox(width: 8),
                      SizedBox(
                        width: 56,
                        child: TextFormField(
                          initialValue: '$_yearMonth',
                          keyboardType: TextInputType.number,
                          textAlign: TextAlign.center,
                          decoration: const InputDecoration(isDense: true),
                          onChanged: (s) {
                            final v = int.tryParse(s);
                            if (v != null) {
                              setState(() => _yearMonth = v.clamp(1, 12));
                            }
                          },
                        ),
                      ),
                      const Text(' 月 '),
                      SizedBox(
                        width: 56,
                        child: TextFormField(
                          initialValue: '$_anchorDay',
                          keyboardType: TextInputType.number,
                          textAlign: TextAlign.center,
                          decoration: const InputDecoration(isDense: true),
                          onChanged: (s) {
                            final v = int.tryParse(s);
                            if (v != null) {
                              setState(() => _anchorDay = v.clamp(1, 31));
                            }
                          },
                        ),
                      ),
                      const Text(' 日'),
                    ],
                  ),
                ],

                const Divider(height: 24),
                // 结束条件
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  value: _hasMax,
                  title: const Text('完成指定次数后结束'),
                  subtitle: _hasMax
                      ? Row(
                          children: [
                            const Text('共'),
                            SizedBox(
                              width: 64,
                              child: TextFormField(
                                initialValue: '$_max',
                                keyboardType: TextInputType.number,
                                textAlign: TextAlign.center,
                                decoration:
                                    const InputDecoration(isDense: true),
                                onChanged: (s) {
                                  final v = int.tryParse(s);
                                  if (v != null) {
                                    setState(() => _max = v.clamp(1, 999));
                                  }
                                },
                              ),
                            ),
                            const Text(' 次'),
                          ],
                        )
                      : null,
                  onChanged: (v) => setState(() => _hasMax = v ?? false),
                ),
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  value: _hasUntil,
                  title: const Text('到指定日期结束'),
                  subtitle: _hasUntil
                      ? Row(
                          children: [
                            Text(_until == null
                                ? '未选择'
                                : dueLabel(_until!)),
                            const SizedBox(width: 8),
                            OutlinedButton(
                              onPressed: () async {
                                final picked = await showDatePicker(
                                  context: context,
                                  initialDate: _until == null
                                      ? DateTime.now()
                                      : DateTime.fromMillisecondsSinceEpoch(_until!),
                                  firstDate: DateTime(2020),
                                  lastDate: DateTime(2100),
                                );
                                if (picked != null) {
                                  setState(() => _until = DateTime(picked.year,
                                          picked.month, picked.day, 23, 59)
                                      .millisecondsSinceEpoch);
                                }
                              },
                              child: const Text('选择'),
                            ),
                          ],
                        )
                      : null,
                  onChanged: (v) => setState(() => _hasUntil = v ?? false),
                ),

                const SizedBox(height: 8),
                Text(
                  next == null
                      ? ''
                      : '下次：${dueLabel(next.millisecondsSinceEpoch)}'
                          '${preview == null ? '' : '（${preview.describe()}）'}',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.primary),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, (changed: false, rule: null)),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () =>
              Navigator.pop(context, (changed: true, rule: _build())),
          child: const Text('确定'),
        ),
      ],
    );
  }
}
