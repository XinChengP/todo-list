import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

/// 同步服务器配置（设置界面填入，存 settings 表）
class SyncConfig {
  const SyncConfig({
    required this.baseUrl,
    this.fallbackUrls = const [],
    this.preferredEndpoint,
    this.directIp,
    required this.token,
  });

  final String baseUrl;
  /// 备用地址（如 https://todoapi.example.com:8443），主地址失败时自动切换
  final List<String> fallbackUrls;
  /// 上次成功的端点（持久化），优先尝试
  final String? preferredEndpoint;
  /// 直连 IP（选填）：设备 DNS 解析失败/被劫持时，TCP 直连该 IP 并以域名做
  /// SNI + 证书校验（Cloudflare 边缘任播 IP 均可服务任意 CF 域名）
  final String? directIp;
  final String token;
}

class SyncAuthException implements Exception {
  SyncAuthException(this.message);
  final String message;
  @override
  String toString() => message;
}

class SyncNetworkException implements Exception {
  SyncNetworkException(this.message);
  final String message;
  @override
  String toString() => '网络错误：$message';
}

class SyncRequestException implements Exception {
  SyncRequestException(this.status, this.message);
  final int status;
  final String message;
  @override
  String toString() => '请求失败($status)：$message';
}

class _RetryableHttpError implements Exception {
  _RetryableHttpError(this.status, this.message);
  final int status;
  final String message;
}

/// 同步 API 客户端：Bearer 鉴权 + 超时 + 网络抖动重试（指数退避）
/// + **多端点自动回退**（主地址失败自动切备用端口/地址，记住成功端点）。
///
/// 国内直连 Cloudflare 的可达性按时段波动（晚高峰常见 443 劣化、非标端口存活），
/// 单一端点 + 重试扛不住全断时段；401/4xx 属于确定性错误，不重试不换端点。
class ApiClient {
  ApiClient({
    required SyncConfig config,
    http.Client? client,
    this.timeout = const Duration(seconds: 15),
    this.retries = 3,
  })  : baseUrls = _orderedUrls(config),
        token = config.token,
        _client = _makeClient(config, client) {
    final preferred = config.preferredEndpoint?.trim().replaceAll(RegExp(r'/+$'), '');
    if (preferred != null && preferred.isNotEmpty) {
      final i = baseUrls.indexOf(preferred);
      if (i > 0) {
        baseUrls.removeAt(i);
        baseUrls.insert(0, preferred);
      }
    }
  }

  /// 连接策略（专为"设备 DNS 解析失败 + CF 可达性波动"环境设计）：
  /// 1) DoH 解析与直连 IP **并行**进行（互不阻塞）
  /// 2) 直连先试（5 秒快速失败）；失败后 DoH 解析出的候选 IP **并行竞速**
  ///    （最先连上的胜出，其余销毁），避免串行等待
  /// 3) 系统解析兜底
  /// 最后统一 TLS：SNI + 证书校验仍按域名（安全不降级）。
  static http.Client _makeClient(SyncConfig config, http.Client? provided) {
    if (provided != null) return provided;
    final ip = config.directIp?.trim() ?? '';
    if (ip.isEmpty) return http.Client();
    final inner = io.HttpClient()
      ..connectionFactory = (Uri uri, String? proxyHost, int? proxyPort) async {
        // DoH 与直连并行解析，不互相阻塞
        final dohFuture =
            _resolveViaDoh(uri.host).catchError((Object e) => const <String>[]);
        io.Socket? socketBuf;
        final fails = <String>[];
        if (ip.isNotEmpty) {
          try {
            final directTask = await io.Socket.startConnect(ip, uri.port);
            socketBuf = await directTask.socket
                .timeout(const Duration(seconds: 5), onTimeout: () {
              throw const io.SocketException('连接超时');
            });
          } catch (e) {
            fails.add('直连$ip:${_shortErr(e)}');
          }
        } else {
          fails.add('直连未配置');
        }
        if (socketBuf == null) {
          final dohIps = await dohFuture;
          if (dohIps.isEmpty) {
            fails.add('DoH:无结果');
          } else {
            try {
              socketBuf = await _raceConnect(dohIps, uri.port)
                  .timeout(const Duration(seconds: 8), onTimeout: () {
                throw const io.SocketException('竞速超时');
              });
            } catch (e) {
              fails.add('DoH竞速:${_shortErr(e)}');
            }
          }
        }
        if (socketBuf == null) {
          try {
            final fallbackTask =
                await io.Socket.startConnect(uri.host, uri.port);
            socketBuf = await fallbackTask.socket;
          } catch (e) {
            fails.add('系统:${_shortErr(e)}');
          }
        }
        if (socketBuf == null) {
          throw io.SocketException('连接链全部失败（${fails.join('；')}）');
        }
        final secure = await io.SecureSocket.secure(socketBuf, host: uri.host)
            .catchError((e) {
          fails.add('TLS:${_shortErr(e)}');
          throw io.SocketException('连接链全部失败（${fails.join('；')}）');
        });
        return io.ConnectionTask.fromSocket(
          Future<io.Socket>.value(secure),
          () {},
        );
      };
    return IOClient(inner);
  }

  /// 并发连接多个候选 IP：最先连上的胜出，其余连接到达后直接销毁
  static Future<io.Socket> _raceConnect(List<String> ips, int port,
      {Duration timeout = const Duration(seconds: 6)}) {
    final completer = Completer<io.Socket>();
    var settled = false;
    var pending = ips.length;

    void failOne(String ip, Object e) {
      pending--;
      if (pending == 0 && !settled) {
        settled = true;
        completer.completeError(
            io.SocketException('全部候选连接失败（${ips.join(', ')}）：$e'));
      }
    }

    for (final ipAddr in ips) {
      io.Socket.startConnect(ipAddr, port).then((task) {
        task.socket.then((s) {
          if (settled) {
            s.destroy(); // 竞速已结束，销毁迟到者
            return;
          }
          settled = true;
          completer.complete(s);
        }, onError: (Object e) => failOne(ipAddr, e));
      }, onError: (Object e) => failOne(ipAddr, e));
    }
    return completer.future.timeout(timeout, onTimeout: () {
      settled = true; // 迟到的成功连接会被上面的分支销毁
      throw io.SocketException('候选 IP 竞速超时（${ips.join(', ')}）');
    });
  }

  /// 压缩异常文本，用于连接链诊断信息
  static String _shortErr(Object e) {
    var s = e
        .toString()
        .replaceAll('SocketException: ', '')
        .replaceAll('ClientException: ', '')
        .replaceAll('Failed host lookup: ', '解析失败:');
    return s.length > 90 ? '${s.substring(0, 90)}…' : s;
  }

  static void _invalidateDohCache() {
    _dohCacheAt = null;
  }

  // ---- DoH（阿里 DNS JSON API：纯 IP 端点 223.5.5.5 + SNI 兜底，绕过设备 DNS） ----

  static final Map<String, List<String>> _dohCache = {};
  static DateTime? _dohCacheAt;

  static Future<List<String>> _resolveViaDoh(String host) async {
    final cached = _dohCache[host];
    if (cached != null &&
        _dohCacheAt != null &&
        DateTime.now().difference(_dohCacheAt!) < const Duration(minutes: 10)) {
      return cached;
    }
    final ips = <String>[];
    // attempt 0: 直连 https://223.5.5.5（AliDNS 证书通常含 IP SAN）
    // attempt 1: 同 IP 但 SNI 用 dns.alidns.com（证书不含 IP SAN 时的兜底）
    for (var attempt = 0; attempt < 2 && ips.isEmpty; attempt++) {
      try {
        final client = io.HttpClient();
        if (attempt == 1) {
          client.connectionFactory = (Uri uri, String? ph, int? pp) async {
            final t = await io.Socket.startConnect('223.5.5.5', uri.port);
            final socket = await t.socket;
            final secure = await io.SecureSocket.secure(
              socket,
              host: 'dns.alidns.com',
            );
            return io.ConnectionTask.fromSocket(
              Future<io.Socket>.value(secure),
              () {},
            );
          };
        }
        final wrapped = IOClient(client);
        try {
          final resp = await wrapped
              .get(Uri.parse('https://223.5.5.5/resolve?name=$host&type=A'))
              .timeout(const Duration(seconds: 6));
          final data = jsonDecode(resp.body) as Map<String, dynamic>;
          final answers = data['Answer'] as List?;
          if (answers != null) {
            for (final a in answers) {
              if (a is Map && a['type'] == 1 && a['data'] is String) {
                ips.add(a['data'] as String);
              }
            }
          }
        } finally {
          wrapped.close();
        }
      } catch (_) {}
    }
    _dohCache[host] = ips;
    _dohCacheAt = DateTime.now();
    return ips;
  }

  static List<String> _orderedUrls(SyncConfig config) {
    final clean = [
      config.baseUrl,
      ...config.fallbackUrls,
    ].map((u) => u.trim().replaceAll(RegExp(r'/+$'), '')).where((u) => u.isNotEmpty).toSet().toList();
    return clean.isEmpty ? const [] : clean;
  }

  final List<String> baseUrls;
  final String token;
  final Duration timeout;
  final int retries;
  final http.Client _client;

  int _endpointIndex = 0;
  String? _lastGoodEndpoint;

  /// 本次会话中最后成功的端点（供持久化，下次优先尝试）
  String? get lastGoodEndpoint => _lastGoodEndpoint;

  Future<Map<String, dynamic>> getJson(String path,
          {Duration? timeout, int? retries}) =>
      _run('GET', path, null, timeout: timeout, retries: retries);

  Future<Map<String, dynamic>> postJson(String path, Map<String, dynamic> body,
          {Duration? timeout, int? retries}) =>
      _run('POST', path, body, timeout: timeout, retries: retries);

  Future<Map<String, dynamic>> _run(String method, String path,
      Map<String, dynamic>? body,
      {Duration? timeout, int? retries}) async {
    final effTimeout = timeout ?? this.timeout;
    final effRetries = retries ?? this.retries;
    Object? lastError;
    final attempted = <String>{};
    for (var attempt = 1; attempt <= effRetries + 1; attempt++) {
      final lastAttempt = attempt > effRetries;
      final baseUrl = baseUrls[_endpointIndex % baseUrls.length];
      try {
        final req = http.Request(method, Uri.parse('$baseUrl$path'))
          ..headers['Authorization'] = 'Bearer $token';
        if (body != null) {
          req.headers['Content-Type'] = 'application/json';
          req.body = jsonEncode(body);
        }
        final streamed = await _client.send(req).timeout(effTimeout);
        final resp = await http.Response.fromStream(streamed).timeout(effTimeout);
        Map<String, dynamic> decoded;
        try {
          decoded = resp.body.isEmpty
              ? <String, dynamic>{}
              : jsonDecode(resp.body) as Map<String, dynamic>;
        } on FormatException {
          // 返回了 HTML 错误页（CF 1016/1020）或运营商劫持页：
          // 视为该路径失效 → 轮换端点/IP 并强制 DoH 重新解析
          _invalidateDohCache();
          throw _RetryableHttpError(
              resp.statusCode,
              'non-JSON response: ${resp.body.length > 60 ? resp.body.substring(0, 60) : resp.body}');
        }

        if (resp.statusCode == 401) {
          throw SyncAuthException('令牌无效，请在设置中检查同步令牌');
        }
        if (resp.statusCode >= 400) {
          final err = decoded['error'] as String? ?? resp.reasonPhrase ?? '';
          if (resp.statusCode >= 500) {
            throw _RetryableHttpError(resp.statusCode, err);
          }
          throw SyncRequestException(resp.statusCode, err);
        }
        _lastGoodEndpoint = baseUrl;
        return decoded;
      } on SyncAuthException {
        rethrow;
      } on SyncRequestException {
        rethrow;
      } on _RetryableHttpError catch (e) {
        lastError = e;
        attempted.add(baseUrl);
        if (lastAttempt) {
          throw SyncNetworkException('HTTP ${e.status}: ${e.message}');
        }
      } on Exception catch (e) {
        // 超时 / 连接被重置 / SSL 抖动等网络层错误
        lastError = e;
        attempted.add(baseUrl);
        if (lastAttempt) throw SyncNetworkException(e.toString());
      }
      // 网络层失败 → 下次尝试切换到下一个端点，并强制 DoH 重新解析新 IP
      _invalidateDohCache();
      _endpointIndex = (_endpointIndex + 1) % baseUrls.length;
      await Future<void>.delayed(Duration(milliseconds: 800 * (1 << (attempt - 1))));
    }
    final tried = attempted.isEmpty ? '无' : attempted.join(' / ');
    throw SyncNetworkException('所有端点均失败 $tried：$lastError');
  }

  void close() => _client.close();
}
