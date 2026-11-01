// ignore_for_file: avoid_print
// 直连 IP 通路验证脚本（PC 上运行，验证 connectionFactory 直连 + SNI 是否可用）：
//   dart run tool/direct_ip_check.dart [IP]
// 不带参数用默认 CF 节点 IP。成功输出 OK 与实际使用的端点。
import 'dart:convert';
import 'dart:io';

import 'package:todo_app/sync/api_client.dart';

Future<void> main(List<String> args) async {
  final ip = args.isNotEmpty ? args.first : '104.21.68.252';
  final token =
      File('../server/.sync-token').readAsStringSync().trim();
  final config = SyncConfig(
    baseUrl: 'https://todoapi.example.com',
    fallbackUrls: ['https://todoapi.example.com:8443'],
    directIp: ip,
    token: token,
  );
  final api = ApiClient(config: config);
  try {
    final r = await api.getJson('/v1/sync/pull?since=0');
    print('OK ok=${r['ok']} 端点=${api.lastGoodEndpoint} 直连IP=$ip');
    final body = const JsonEncoder.withIndent(' ').convert(r);
    stdout.writeln(body.length > 200 ? '${body.substring(0, 200)}…' : body);
  } catch (e) {
    print('FAIL $e');
    exitCode = 1;
  } finally {
    api.close();
  }
}
