import 'dart:convert';

/// 字段级时间戳（与服务端 field_ts 列同构）。
/// 记录每个可同步字段最后一次被写入的毫秒时间戳，是冲突判定（Last-Write-Wins）的依据。
class FieldTs {
  FieldTs(this.map);

  final Map<String, int> map;

  static final FieldTs empty = FieldTs(const {});

  static FieldTs parse(String raw) {
    if (raw.isEmpty) return FieldTs({});
    try {
      final obj = jsonDecode(raw);
      if (obj is Map) {
        return FieldTs({
          for (final e in obj.entries)
            if (e.value is num) e.key.toString(): (e.value as num).toInt(),
        });
      }
    } catch (_) {
      // 损坏的 JSON 视为空时间戳，不影响本地使用
    }
    return FieldTs({});
  }

  /// 追加一批字段写入时间戳（同字段以新值覆盖）
  FieldTs withWrites(Map<String, int> writes) => FieldTs({...map, ...writes});

  int operator [](String field) => map[field] ?? 0;

  /// 所有字段时间戳的最大值（即服务器 updated_at 的语义）
  int get maxTs => map.values.fold(0, (m, v) => v > m ? v : m);

  String encode() => jsonEncode(map);
}

int _lastMs = 0;

/// 全项目统一使用的当前毫秒时间戳。
/// 单调递增：同一毫秒内连续调用会 +1，保证"同字段后写的必然赢"
/// （否则毫秒内两次写入时间戳相同，LWW 无法排序，服务端会按平局判服务器赢）。
int nowMs() {
  final n = DateTime.now().millisecondsSinceEpoch;
  _lastMs = n > _lastMs ? n : _lastMs + 1;
  return _lastMs;
}
