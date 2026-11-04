import 'dart:async';

import 'package:flutter/foundation.dart';

import '../api/hub_client.dart';
import '../models/chat.dart';

/// The chats, and the one that is open.
///
/// A chat is not an agent: there is no session on the other side, so there is
/// nothing to keep alive and nothing to poll. The list is read when the view
/// opens, and a chat's messages when it is opened.
class ChatsState extends ChangeNotifier {
  ChatsState(this.client);

  HubClient client;

  List<Chat> chats = const [];
  bool loading = false;
  String? error;

  /// The catalogue, read once: OpenRouter's models plus the Claude ones.
  List<ModelInfo> models = const [];

  Future<void> load() async {
    loading = true;
    notifyListeners();
    try {
      chats = await client.chats();
      error = null;
    } on HubException catch (e) {
      error = e.message;
    }
    loading = false;
    notifyListeners();
    if (models.isEmpty) unawaited(loadModels());
  }

  Future<void> loadModels() async {
    try {
      models = await client.models();
      notifyListeners();
    } on HubException {
      // the picker falls back to the models already in use
    }
  }

  ModelInfo? model(String id) {
    for (final m in models) {
      if (m.id == id) return m;
    }
    return null;
  }

  /// A new chat, or an agent's conversation forked into one. The agent itself
  /// is left alone: only its words are copied.
  Future<Chat?> start({String? model, String? title, String? fromAgent, List<ChatTurn> messages = const []}) async {
    try {
      final chat = await client.newChat(model: model, title: title, fromAgent: fromAgent, messages: messages);
      chats = [chat, ...chats];
      error = null;
      notifyListeners();
      return chat;
    } on HubException catch (e) {
      error = e.message;
      notifyListeners();
      return null;
    }
  }

  Future<void> remove(int id) async {
    try {
      await client.deleteChat(id);
      chats = [for (final c in chats) if (c.id != id) c];
      notifyListeners();
    } on HubException catch (e) {
      error = e.message;
      notifyListeners();
    }
  }

  void replace(Chat chat) {
    chats = [for (final c in chats) if (c.id == chat.id) chat else c];
    notifyListeners();
  }
}

/// One open chat: its messages, and the waiting while the model answers.
class ChatSession extends ChangeNotifier {
  ChatSession(this.client, this.id);

  final HubClient client;
  final int id;

  Chat? chat;
  List<ChatTurn> messages = const [];
  bool loading = false;

  /// What was said and not answered yet, shown while the model works. A chat
  /// has no streaming: the answer arrives whole or not at all.
  String? pending;
  bool sending = false;
  String? error;

  /// Text typed and not sent.
  String draft = '';

  Future<void> load() async {
    loading = true;
    notifyListeners();
    try {
      final page = await client.chat(id);
      chat = page.chat;
      messages = page.messages;
      error = null;
    } on HubException catch (e) {
      error = e.message;
    }
    loading = false;
    notifyListeners();
  }

  Future<void> send(String text) async {
    if (text.trim().isEmpty || sending) return;
    pending = text;
    sending = true;
    error = null;
    notifyListeners();
    try {
      await client.say(id, text);
      await load();
    } on HubException catch (e) {
      error = e.message;
      await load();
    }
    pending = null;
    sending = false;
    notifyListeners();
  }

  /// Rewrites one of his messages. Everything after it goes, because the whole
  /// history is what the model is given: the chat carries on from there.
  Future<void> edit(int message, String text) async {
    try {
      await client.editChat(id, message, text);
      await load();
    } on HubException catch (e) {
      error = e.message;
      notifyListeners();
    }
  }

  Future<Chat?> set({String? model, String? title, Map<String, dynamic>? params}) async {
    try {
      final updated = await client.patchChat(id, model: model, title: title, params: params);
      chat = updated;
      notifyListeners();
      return updated;
    } on HubException catch (e) {
      error = e.message;
      notifyListeners();
      return null;
    }
  }

  /// What this chat reads as, for an agent to take it on.
  Future<String?> render() async {
    try {
      return await client.renderChat(id);
    } on HubException catch (e) {
      error = e.message;
      notifyListeners();
      return null;
    }
  }

  /// What the chat has cost so far, where the provider said.
  double get spent => messages.fold(0, (sum, m) => sum + (m.cost ?? 0));
}
