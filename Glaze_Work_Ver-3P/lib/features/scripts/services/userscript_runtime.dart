import 'dart:collection';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../models/user_script.dart';
import '../user_scripts_provider.dart';

/// A menu entry a script registered with `GM_registerMenuCommand`.
class ScriptMenuCommand {
  final String scriptId;
  final String commandId;
  final String title;
  const ScriptMenuCommand(this.scriptId, this.commandId, this.title);
}

/// What the page tells the app about running scripts.
class ScriptHostCallbacks {
  final void Function(String scriptId)? onRan;
  final void Function(String scriptId, String message)? onError;
  final void Function(ScriptMenuCommand command)? onMenuAdded;
  final void Function(String scriptId, String commandId)? onMenuRemoved;
  final void Function(String url)? onOpenUrl;
  final void Function(String message)? onToast;

  const ScriptHostCallbacks({
    this.onRan,
    this.onError,
    this.onMenuAdded,
    this.onMenuRemoved,
    this.onOpenUrl,
    this.onToast,
  });
}

/// Turns saved userscripts into scripts a web view runs, with a Tampermonkey
/// style `GM_*` API behind them.
///
/// Every script becomes one page script of its own, wrapped so that:
/// - it only runs on pages its `@match`/`@include` (and the user's whitelist /
///   blacklist) allow, in the top frame unless the user chose all frames;
/// - an error inside it cannot stop the other scripts;
/// - the page gets whatever UI the script builds (the scripts run in the
///   page itself, so overlays, buttons and panels appear in the web view).
class UserScriptRuntime {
  UserScriptRuntime._();

  static const _template = r'''
(function () {
  var D = /*__DATA__*/;
  try {
    var KEY = '__glazeUS_' + D.id;
    if (window[KEY]) return;
    if (!D.allFrames && window.top !== window) return;

    function toRe(p) {
      p = String(p).trim();
      if (!p) return null;
      if (p === '*' || p === '<all_urls>') return /^.*$/;
      var last = p.lastIndexOf('/');
      if (p.length > 2 && p.charAt(0) === '/' && last > 0) {
        try { return new RegExp(p.slice(1, last), p.slice(last + 1).indexOf('i') >= 0 ? 'i' : ''); }
        catch (e) { return null; }
      }
      function esc(x) { return x.replace(/[.+?^${}()|[\]\\]/g, '\\$&').replace(/\*/g, '.*'); }
      // `https://*.site.com/*` also matches `https://site.com/...`.
      var sub = p.match(/^([^:\/]+:\/\/)\*\.(.*)$/);
      try {
        if (sub) return new RegExp('^' + esc(sub[1]) + '(?:[^/]*\\.)?' + esc(sub[2]) + '$', 'i');
        return new RegExp('^' + esc(p) + '$', 'i');
      } catch (e) { return null; }
    }
    function any(list, url) {
      for (var i = 0; i < list.length; i++) {
        var r = toRe(list[i]);
        if (r && r.test(url)) return true;
      }
      return false;
    }
    var href = location.href;
    if (D.includes.length && !any(D.includes, href)) return;
    if (D.excludes.length && any(D.excludes, href)) return;
    if (D.whitelist.length && !any(D.whitelist, href)) return;
    if (D.blacklist.length && any(D.blacklist, href)) return;
    window[KEY] = true;

    var fi = function () { return window.flutter_inappwebview; };
    function send() {
      try {
        var f = fi();
        if (f && f.callHandler) f.callHandler.apply(f, arguments).catch(function () {});
      } catch (e) {}
    }
    function ask() {
      var f = fi();
      if (f && f.callHandler) return f.callHandler.apply(f, arguments);
      return Promise.reject(new Error('bridge unavailable'));
    }

    var values = D.values || {};
    var cmdSeq = 0;
    window.__glazeCmds = window.__glazeCmds || {};

    var GM_info = {
      script: {
        name: D.name, namespace: D.namespace, version: D.version,
        description: D.description, author: D.author, grant: D.grants,
        matches: D.includes, excludes: D.excludes, 'run-at': D.runAt
      },
      scriptHandler: 'Glaze', version: '1.0', scriptMetaStr: ''
    };
    function GM_getValue(k, d) {
      if (Object.prototype.hasOwnProperty.call(values, k)) {
        try { return JSON.parse(values[k]); } catch (e) { return values[k]; }
      }
      return d;
    }
    function GM_setValue(k, v) {
      var s = JSON.stringify(v);
      values[k] = s;
      send('glazeGmSetValue', D.id, String(k), s);
    }
    function GM_deleteValue(k) { delete values[k]; send('glazeGmDeleteValue', D.id, String(k)); }
    function GM_listValues() { return Object.keys(values); }
    function GM_addStyle(css) {
      var st = document.createElement('style');
      st.textContent = css;
      (document.head || document.documentElement).appendChild(st);
      return st;
    }
    function GM_log() { try { console.log.apply(console, arguments); } catch (e) {} }
    function GM_setClipboard(t) { send('glazeGmClipboard', String(t)); }
    function GM_openInTab(u) { send('glazeGmOpenUrl', String(u)); return { close: function () {} }; }
    function GM_notification(a, b) {
      var msg = typeof a === 'string' ? a : (a && (a.text || a.title)) || '';
      send('glazeGmToast', String(msg));
    }
    function GM_registerMenuCommand(name, fn) {
      var id = 'c' + (++cmdSeq);
      window.__glazeCmds[D.id + ':' + id] = fn;
      send('glazeGmMenu', D.id, id, String(name));
      return id;
    }
    function GM_unregisterMenuCommand(id) {
      delete window.__glazeCmds[D.id + ':' + id];
      send('glazeGmMenuRemove', D.id, String(id));
    }
    function GM_xmlhttpRequest(d) {
      var aborted = false;
      var req = {
        method: d.method || 'GET', url: d.url, headers: d.headers || {},
        data: d.data == null ? null : (typeof d.data === 'string' ? d.data : String(d.data)),
        timeout: d.timeout || 0
      };
      ask('glazeGmXhr', JSON.stringify(req)).then(function (r) {
        if (aborted) return;
        if (!r || r.error) {
          if (d.onerror) d.onerror({ error: (r && r.error) || 'failed', status: 0, responseText: '' });
          return;
        }
        var resp = {
          status: r.status, statusText: r.statusText || '', readyState: 4,
          responseText: r.responseText || '', response: r.responseText || '',
          responseHeaders: r.responseHeaders || '', finalUrl: r.finalUrl || d.url,
          context: d.context
        };
        if (d.responseType === 'json') { try { resp.response = JSON.parse(resp.responseText); } catch (e) {} }
        if (d.onload) d.onload(resp);
        if (d.onloadend) d.onloadend(resp);
      }).catch(function (e) {
        if (!aborted && d.onerror) d.onerror({ error: String(e), status: 0, responseText: '' });
      });
      return { abort: function () { aborted = true; if (d.onabort) d.onabort({}); } };
    }
    var GM = {
      info: GM_info,
      getValue: function (k, d) { return Promise.resolve(GM_getValue(k, d)); },
      setValue: function (k, v) { GM_setValue(k, v); return Promise.resolve(); },
      deleteValue: function (k) { GM_deleteValue(k); return Promise.resolve(); },
      listValues: function () { return Promise.resolve(GM_listValues()); },
      addStyle: function (c) { return Promise.resolve(GM_addStyle(c)); },
      log: GM_log,
      setClipboard: function (t) { GM_setClipboard(t); return Promise.resolve(); },
      openInTab: GM_openInTab,
      notification: GM_notification,
      registerMenuCommand: GM_registerMenuCommand,
      unregisterMenuCommand: GM_unregisterMenuCommand,
      xmlHttpRequest: function (d) {
        return new Promise(function (res, rej) {
          var o = {};
          for (var k in d) o[k] = d[k];
          o.onload = res; o.onerror = rej;
          GM_xmlhttpRequest(o);
        });
      }
    };
    var unsafeWindow = window;

    var run = function () {
      try {
        (function (GM_info, GM, GM_getValue, GM_setValue, GM_deleteValue, GM_listValues,
                   GM_addStyle, GM_log, GM_setClipboard, GM_openInTab, GM_notification,
                   GM_registerMenuCommand, GM_unregisterMenuCommand, GM_xmlhttpRequest,
                   unsafeWindow) {
/*__CODE__*/
        }).call(window, GM_info, GM, GM_getValue, GM_setValue, GM_deleteValue, GM_listValues,
                GM_addStyle, GM_log, GM_setClipboard, GM_openInTab, GM_notification,
                GM_registerMenuCommand, GM_unregisterMenuCommand, GM_xmlhttpRequest,
                unsafeWindow);
        send('glazeScriptRan', D.id);
      } catch (e) {
        send('glazeScriptError', D.id, String((e && e.stack) || e));
      }
    };
    if (D.runAt === 'document-idle' && document.readyState !== 'complete') {
      window.addEventListener('load', function () { setTimeout(run, 0); });
    } else {
      run();
    }
  } catch (e) {
    try {
      var f = window.flutter_inappwebview;
      if (f && f.callHandler) f.callHandler('glazeScriptError', D.id, String(e));
    } catch (e2) {}
  }
})();
''';

  /// The page script that runs [script], or null when it is switched off.
  static UserScript? _wrap(
    GlazeUserScript script,
    Map<String, String> values,
  ) {
    if (!script.enabled) return null;
    final data = jsonEncode({
      'id': script.id,
      'name': script.name,
      'namespace': script.namespace,
      'version': script.version,
      'description': script.description,
      'author': script.author,
      'grants': script.grants,
      'runAt': script.runAt,
      'includes': script.matches,
      'excludes': script.excludes,
      'whitelist': script.whitelist,
      'blacklist': script.blacklist,
      'allFrames': script.allFrames,
      'values': values,
    });
    final code = StringBuffer();
    for (final url in script.requires) {
      final lib = script.requireCode[url];
      if (lib != null && lib.isNotEmpty) code.writeln('$lib\n;');
    }
    code.write(script.code);
    // The data is JSON, so a stray `</script>` or `$` in it is harmless here:
    // the template is plain text and is filled with no interpolation.
    final source = _template
        .replaceFirst('/*__DATA__*/', data)
        .replaceFirst('/*__CODE__*/', code.toString());
    return UserScript(
      source: source,
      injectionTime: script.runAt == 'document-start'
          ? UserScriptInjectionTime.AT_DOCUMENT_START
          : UserScriptInjectionTime.AT_DOCUMENT_END,
      forMainFrameOnly: !script.allFrames,
    );
  }

  /// The web view scripts for every enabled script in [scripts] (or only the
  /// one named by [onlyId]).
  static Future<UnmodifiableListView<UserScript>> build(
    List<GlazeUserScript> scripts, {
    String? onlyId,
  }) async {
    final out = <UserScript>[];
    for (final s in scripts) {
      if (onlyId != null && s.id != onlyId) continue;
      final values = await ScriptValueStore.instance.valuesFor(s.id);
      final wrapped = _wrap(onlyId != null ? s.copyWith(enabled: true) : s, values);
      if (wrapped != null) out.add(wrapped);
    }
    return UnmodifiableListView<UserScript>(out);
  }

  /// Connects the `GM_*` calls of the page to the app.
  static void registerHandlers(
    InAppWebViewController controller,
    ScriptHostCallbacks host,
  ) {
    String arg(JavaScriptHandlerFunctionData d, int i) =>
        d.args.length > i ? '${d.args[i]}' : '';

    controller.addJavaScriptHandler(
      handlerName: 'glazeScriptRan',
      callback: (JavaScriptHandlerFunctionData d) {
        host.onRan?.call(arg(d, 0));
        return null;
      },
    );
    controller.addJavaScriptHandler(
      handlerName: 'glazeScriptError',
      callback: (JavaScriptHandlerFunctionData d) {
        host.onError?.call(arg(d, 0), arg(d, 1));
        return null;
      },
    );
    controller.addJavaScriptHandler(
      handlerName: 'glazeGmSetValue',
      callback: (JavaScriptHandlerFunctionData d) {
        ScriptValueStore.instance.set(arg(d, 0), arg(d, 1), arg(d, 2));
        return null;
      },
    );
    controller.addJavaScriptHandler(
      handlerName: 'glazeGmDeleteValue',
      callback: (JavaScriptHandlerFunctionData d) {
        ScriptValueStore.instance.delete(arg(d, 0), arg(d, 1));
        return null;
      },
    );
    controller.addJavaScriptHandler(
      handlerName: 'glazeGmClipboard',
      callback: (JavaScriptHandlerFunctionData d) {
        Clipboard.setData(ClipboardData(text: arg(d, 0)));
        host.onToast?.call('Copied');
        return null;
      },
    );
    controller.addJavaScriptHandler(
      handlerName: 'glazeGmOpenUrl',
      callback: (JavaScriptHandlerFunctionData d) {
        host.onOpenUrl?.call(arg(d, 0));
        return null;
      },
    );
    controller.addJavaScriptHandler(
      handlerName: 'glazeGmToast',
      callback: (JavaScriptHandlerFunctionData d) {
        host.onToast?.call(arg(d, 0));
        return null;
      },
    );
    controller.addJavaScriptHandler(
      handlerName: 'glazeGmMenu',
      callback: (JavaScriptHandlerFunctionData d) {
        host.onMenuAdded?.call(
          ScriptMenuCommand(arg(d, 0), arg(d, 1), arg(d, 2)),
        );
        return null;
      },
    );
    controller.addJavaScriptHandler(
      handlerName: 'glazeGmMenuRemove',
      callback: (JavaScriptHandlerFunctionData d) {
        host.onMenuRemoved?.call(arg(d, 0), arg(d, 1));
        return null;
      },
    );
    controller.addJavaScriptHandler(
      handlerName: 'glazeGmXhr',
      callback: (JavaScriptHandlerFunctionData d) => _xhr(arg(d, 0)),
    );
  }

  static final Dio _dio = Dio(
    BaseOptions(
      responseType: ResponseType.plain,
      followRedirects: true,
      validateStatus: (_) => true,
    ),
  );

  static Future<Map<String, dynamic>> _xhr(String raw) async {
    try {
      final req = jsonDecode(raw) as Map;
      final method = '${req['method'] ?? 'GET'}'.toUpperCase();
      final headers = <String, dynamic>{};
      final h = req['headers'];
      if (h is Map) {
        for (final e in h.entries) {
          headers[e.key.toString()] = e.value.toString();
        }
      }
      final timeout = (req['timeout'] as num?)?.toInt() ?? 0;
      final res = await _dio.request<String>(
        '${req['url']}',
        data: req['data'],
        options: Options(
          method: method,
          headers: headers,
          sendTimeout: timeout > 0 ? Duration(milliseconds: timeout) : null,
          receiveTimeout: timeout > 0
              ? Duration(milliseconds: timeout)
              : const Duration(seconds: 60),
        ),
      );
      final headerText = StringBuffer();
      res.headers.forEach((name, values) {
        for (final v in values) {
          headerText.write('$name: $v\r\n');
        }
      });
      return {
        'status': res.statusCode ?? 0,
        'statusText': res.statusMessage ?? '',
        'responseText': res.data ?? '',
        'responseHeaders': headerText.toString(),
        'finalUrl': res.realUri.toString(),
      };
    } catch (e) {
      return {'error': e.toString()};
    }
  }

  /// Runs a menu command a script registered, in the page.
  static Future<void> runCommand(
    InAppWebViewController controller,
    ScriptMenuCommand command,
  ) async {
    final key = jsonEncode('${command.scriptId}:${command.commandId}');
    try {
      await controller.evaluateJavascript(
        source:
            '(function(){try{var f=(window.__glazeCmds||{})[$key];if(f)f();}catch(e){}})();',
      );
    } catch (_) {}
  }
}
