import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../chub_account_provider.dart';
import '../crushon_account_provider.dart';
import '../janitor_account_provider.dart';
import '../services/chub_provider.dart' show chubHeaders;
import '../services/crushon_site_reader.dart';
import '../services/janitor_webview_proxy.dart';
import '../services/spicychat_provider.dart' show SpicyChatWebSession;
import '../spicychat_account_provider.dart';
import 'provider_chat_models.dart';
import 'provider_chat_parsers.dart';

/// What one refresh of the Provider Characters list produced.
class ProviderChatsResult {
  const ProviderChatsResult({required this.chats, required this.problems});

  final List<ProviderChatSummary> chats;

  /// Why a signed-in site could not be read, by site. A site missing from both
  /// [chats] and [problems] was not signed in.
  final Map<ProviderChatSite, String> problems;
}

typedef _Fetch = Future<dynamic> Function(String url);

/// Reads the chat history of the accounts the app is signed in to.
///
/// Every request goes through the account's own signed-in session (the same
/// web view the catalog already uses), never a password. Chats are only ever
/// read here: nothing is sent to a provider from this tab.
///
/// JanitorAI is read through `/hampter/chats`, the same endpoint family the
/// app already uses. SpicyChat, Chub and CrushOn do not publish a chat API, so
/// each tries its known addresses in turn and, when none answers, reports every
/// address it tried with the status it got.
class ProviderChatsService {
  ProviderChatsService(this._ref);

  final Ref _ref;

  static const _janitorBase = 'https://janitorai.com/hampter';
  static const _janitorAvatars = 'https://ella.janitorai.com/bot-avatars/';
  static const _spicyBase = 'https://prod.nd-api.com/v2';
  static const _chubBase = 'https://api.chub.ai';

  /// Sites the user is signed in to right now.
  Set<ProviderChatSite> signedInSites() => {
    if (_ref.read(janitorAccountProvider).isLoggedIn) ProviderChatSite.janitor,
    if (_ref.read(spicyChatAccountProvider).isLoggedIn)
      ProviderChatSite.spicychat,
    if (_ref.read(chubAccountProvider).isLoggedIn) ProviderChatSite.chub,
    if (_ref.read(crushOnAccountProvider).isLoggedIn) ProviderChatSite.crushon,
  };

  String? accountName(ProviderChatSite site) => switch (site) {
    ProviderChatSite.janitor => _ref.read(janitorAccountProvider).userName,
    ProviderChatSite.spicychat =>
      _ref.read(spicyChatAccountProvider).displayName,
    ProviderChatSite.chub => _ref.read(chubAccountProvider).userName,
    ProviderChatSite.crushon => _ref.read(crushOnAccountProvider).displayName,
    ProviderChatSite.file => null,
  };

  Future<ProviderChatsResult> listChats(Set<ProviderChatSite> sites) async {
    final signedIn = signedInSites();
    final chats = <ProviderChatSummary>[];
    final problems = <ProviderChatSite, String>{};
    final wanted = sites.where(signedIn.contains).toList();

    // One site at a time: they share web views, and a slow one must not hide
    // the others' rows.
    for (final site in wanted) {
      try {
        chats.addAll(await _list(site));
      } catch (e) {
        problems[site] = e.toString();
      }
    }
    chats.sort((a, b) => (b.updatedAtMs ?? 0).compareTo(a.updatedAtMs ?? 0));
    return ProviderChatsResult(chats: chats, problems: problems);
  }

  Future<ProviderChatTranscript> loadTranscript(
    ProviderChatSummary summary,
  ) async {
    switch (summary.site) {
      case ProviderChatSite.janitor:
        final json = await _janitorGet('$_janitorBase/chats/${summary.chatId}');
        return _withGreeting(
          parseProviderTranscript(json, summary: summary),
        );
      case ProviderChatSite.spicychat:
        return _firstTranscript(summary, await _spicyFetcher(), [
          '$_spicyBase/conversations/${summary.chatId}/messages',
          '$_spicyBase/conversations/${summary.chatId}',
          '$_spicyBase/chats/${summary.chatId}',
        ]);
      case ProviderChatSite.chub:
        return _firstTranscript(summary, _chubFetcher(), [
          '$_chubBase/chats/${summary.chatId}',
          '$_chubBase/api/chats/${summary.chatId}',
          '$_chubBase/api/chats/${summary.chatId}/messages',
        ]);
      case ProviderChatSite.crushon:
        return _firstTranscript(summary, _crushonFetcher(), [
          '/api/chat/history?chatId=${Uri.encodeQueryComponent(summary.chatId)}',
          '/api/chats/${summary.chatId}',
          '/api/conversations/${summary.chatId}',
        ]);
      case ProviderChatSite.file:
        throw const ProviderChatException('This chat was opened from a file.');
    }
  }

  // --------------------------------------------------------------- listing

  Future<List<ProviderChatSummary>> _list(ProviderChatSite site) async {
    final label = accountName(site);
    switch (site) {
      case ProviderChatSite.janitor:
        final json = await _janitorGet('$_janitorBase/chats');
        return parseProviderChatList(
          json,
          site: site,
          accountLabel: label,
          avatarBase: _janitorAvatars,
          characterUrl: (id) => 'https://janitorai.com/characters/$id',
        );
      case ProviderChatSite.spicychat:
        return _firstList(site, label, await _spicyFetcher(), [
          '$_spicyBase/conversations',
          '$_spicyBase/chats',
          '$_spicyBase/users/me/conversations',
        ], characterUrl: (id) => 'https://spicychat.ai/chatbot/$id');
      case ProviderChatSite.chub:
        return _firstList(site, label, _chubFetcher(), [
          '$_chubBase/chats',
          '$_chubBase/api/chats',
          '$_chubBase/api/chats?first=100',
        ], characterUrl: (id) => 'https://chub.ai/characters/$id');
      case ProviderChatSite.crushon:
        return _firstList(site, label, _crushonFetcher(), [
          '/api/chat/list',
          '/api/chats',
          '/api/conversations',
        ], characterUrl: (id) => 'https://crushon.ai/character/$id');
      case ProviderChatSite.file:
        return const [];
    }
  }

  Future<List<ProviderChatSummary>> _firstList(
    ProviderChatSite site,
    String? label,
    _Fetch fetch,
    List<String> urls, {
    String Function(String id)? characterUrl,
  }) async {
    final tried = <String>[];
    for (final url in urls) {
      try {
        final json = await fetch(url);
        final rows = parseProviderChatList(
          json,
          site: site,
          accountLabel: label,
          characterUrl: characterUrl,
        );
        if (rows.isNotEmpty) return rows;
        tried.add('$url → answered, but no chats in it');
      } catch (e) {
        tried.add('$url → $e');
      }
    }
    throw ProviderChatException(
      '${site.label} did not return a chat list.',
      detail: tried.join('\n'),
    );
  }

  Future<ProviderChatTranscript> _firstTranscript(
    ProviderChatSummary summary,
    _Fetch fetch,
    List<String> urls,
  ) async {
    final tried = <String>[];
    for (final url in urls) {
      try {
        final json = await fetch(url);
        final parsed = parseProviderTranscript(json, summary: summary);
        if (parsed.messages.isNotEmpty) return _withGreeting(parsed);
        tried.add('$url → answered, but no messages in it');
      } catch (e) {
        tried.add('$url → $e');
      }
    }
    throw ProviderChatException(
      '${summary.site.label} did not return this chat.',
      detail: tried.join('\n'),
    );
  }

  /// A chat that arrives without its opening message gets the character's
  /// first greeting put back in front, so the story starts where it started.
  ProviderChatTranscript _withGreeting(ProviderChatTranscript t) {
    if (t.greetings.isEmpty) return t;
    final startsWithUser = t.messages.isNotEmpty && t.messages.first.isUser;
    if (t.messages.isNotEmpty && !startsWithUser) return t;
    return ProviderChatTranscript(
      summary: t.summary,
      messages: [
        ProviderChatMessage(isUser: false, text: t.greetings.first),
        ...t.messages,
      ],
      memory: t.memory,
      userName: t.userName,
      greetings: t.greetings,
    );
  }

  // -------------------------------------------------------------- fetchers

  Future<dynamic> _janitorGet(String url) async {
    final body = await JanitorWebViewProxy.instance.fetch(url);
    return jsonDecode(body);
  }

  Future<_Fetch> _spicyFetcher() async {
    final token = await SpicyChatWebSession.instance.getAccessToken();
    if (token == null || token.isEmpty) {
      throw const ProviderChatException(
        'SpicyChat session expired. Sign in to SpicyChat again.',
      );
    }
    return _dioFetcher({
      'Accept': 'application/json',
      'Authorization': 'Bearer $token',
      'x-app-id': 'spicychat',
      'Origin': 'https://spicychat.ai',
      'Referer': 'https://spicychat.ai/',
    });
  }

  _Fetch _chubFetcher() =>
      _dioFetcher(chubHeaders(apiKey: _ref.read(chubAccountProvider).apiKey));

  _Fetch _crushonFetcher() => (url) async {
    final r = await CrushOnSiteReader.instance.fetchSessionJson(url);
    final status = (r['status'] as num?)?.toInt() ?? 0;
    if (status < 200 || status >= 300) throw 'HTTP $status';
    return jsonDecode((r['body'] ?? '').toString());
  };

  _Fetch _dioFetcher(Map<String, String> headers) {
    final dio = Dio(
      BaseOptions(
        connectTimeout: const Duration(seconds: 20),
        receiveTimeout: const Duration(seconds: 30),
        validateStatus: (_) => true,
      ),
    );
    return (url) async {
      final res = await dio.get<dynamic>(url, options: Options(headers: headers));
      final status = res.statusCode ?? 0;
      if (status < 200 || status >= 300) throw 'HTTP $status';
      final data = res.data;
      if (data is String) return jsonDecode(data);
      return data;
    };
  }
}

final providerChatsServiceProvider = Provider<ProviderChatsService>(
  (ref) => ProviderChatsService(ref),
);
