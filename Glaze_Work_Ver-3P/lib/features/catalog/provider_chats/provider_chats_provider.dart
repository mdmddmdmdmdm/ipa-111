import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'provider_chat_models.dart';
import 'provider_chats_service.dart';

class ProviderChatsState {
  const ProviderChatsState({
    this.loading = false,
    this.loaded = false,
    this.chats = const [],
    this.problems = const {},
    this.filter,
  });

  final bool loading;
  final bool loaded;
  final List<ProviderChatSummary> chats;
  final Map<ProviderChatSite, String> problems;

  /// The one site being looked at, or null for every signed-in site.
  final ProviderChatSite? filter;

  List<ProviderChatSummary> get visible => filter == null
      ? chats
      : chats.where((c) => c.site == filter).toList();

  ProviderChatsState copyWith({
    bool? loading,
    bool? loaded,
    List<ProviderChatSummary>? chats,
    Map<ProviderChatSite, String>? problems,
    ProviderChatSite? filter,
    bool clearFilter = false,
  }) => ProviderChatsState(
    loading: loading ?? this.loading,
    loaded: loaded ?? this.loaded,
    chats: chats ?? this.chats,
    problems: problems ?? this.problems,
    filter: clearFilter ? null : (filter ?? this.filter),
  );
}

class ProviderChatsNotifier extends Notifier<ProviderChatsState> {
  @override
  ProviderChatsState build() => const ProviderChatsState();

  /// Reads the chat list of every signed-in provider again.
  Future<void> refresh() async {
    if (state.loading) return;
    state = state.copyWith(loading: true);
    ProviderChatsResult result;
    try {
      final service = ref.read(providerChatsServiceProvider);
      result = await service.listChats(service.signedInSites());
    } catch (e) {
      if (!ref.mounted) return;
      state = state.copyWith(
        loading: false,
        loaded: true,
        problems: {ProviderChatSite.file: e.toString()},
      );
      return;
    }
    if (!ref.mounted) return;
    state = state.copyWith(
      loading: false,
      loaded: true,
      chats: result.chats,
      problems: result.problems,
    );
  }

  void setFilter(ProviderChatSite? site) {
    state = site == null
        ? state.copyWith(clearFilter: true)
        : state.copyWith(filter: site);
  }
}

final providerChatsProvider =
    NotifierProvider<ProviderChatsNotifier, ProviderChatsState>(
      ProviderChatsNotifier.new,
    );
