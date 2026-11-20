import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'browser_page.dart';

/// 给 agent 用的浏览器控制口。
///
/// App 在 loopback 上开一个很小的 HTTP 服务，PRoot 里的 DSH 工具（`bash` 够用）
/// 用 curl 就能操作内置浏览器 —— Node 和 Flutter 之间不需要新的通道：
///
///   GET  /current        当前标签的 url / title / tabs / loading
///   POST /open?url=…     在当前标签打开（没有标签就新建）
///   GET  /read           当前页面的可见正文（截断 20000 字）
///
/// 只绑 127.0.0.1，不对外网开放。
abstract final class BrowserBridge {
  static const port = 39871;

  static HttpServer? _server;

  /// 起服务；端口被占或失败就安静放弃——浏览器照常能用，只是工具接不进来。
  static Future<void> start() async {
    if (_server != null) return;
    try {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
      _server = server;
      unawaited(server.forEach(_handle).catchError((_) {}));
    } catch (_) {
      _server = null;
    }
  }

  static Future<void> _handle(HttpRequest request) async {
    final response = request.response;
    response.headers.contentType = ContentType.json;
    final browser = activeBrowser;

    void reply(Object? body) => response.write(jsonEncode(body));

    try {
      switch ((request.method, request.uri.path)) {
        case ('GET', '/current'):
          reply(browser?.current() ?? const <String, Object?>{'url': null});
        case ('GET', '/open') || ('POST', '/open'):
          var url = request.uri.queryParameters['url'] ?? '';
          if (url.isEmpty) url = (await utf8.decoder.bind(request).join()).trim();
          if (url.isEmpty) {
            response.statusCode = HttpStatus.badRequest;
            reply(const {'error': 'url required'});
          } else if (browser == null) {
            response.statusCode = HttpStatus.serviceUnavailable;
            reply(const {'error': 'browser not ready'});
          } else {
            await browser.openUrl(url);
            reply({'ok': true, 'opened': url});
          }
        case ('GET', '/read'):
          final text = await browser?.readText() ?? '';
          reply({'url': browser?.current()['url'], 'text': text});
        default:
          response.statusCode = HttpStatus.notFound;
          reply(const {
            'error': 'unknown route',
            'routes': ['GET /current', 'GET|POST /open?url=', 'GET /read'],
          });
      }
    } catch (error) {
      response.statusCode = HttpStatus.internalServerError;
      reply({'error': '$error'});
    } finally {
      await response.close();
    }
  }
}
