import 'dart:math';
import 'package:smart_search_app/features/chat/domain/chat_document_context.dart';

enum ChatRole { user, assistant }

enum MessageStatus { complete, streaming, interrupted, failed }

String newChatId() {
  final random = Random.secure();
  return List.generate(
      16, (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
}

class ChatMessage {
  const ChatMessage({
    required this.id,
    required this.role,
    required this.text,
    required this.createdAt,
    this.status = MessageStatus.complete,
    this.notice,
    this.model,
    this.documentContext,
  });

  final String id;
  final ChatRole role;
  final String text;
  final DateTime createdAt;
  final MessageStatus status;
  final String? notice;
  final String? model;
  final ChatDocumentContext? documentContext;

  ChatMessage copyWith(
          {String? text,
          MessageStatus? status,
          String? notice,
          ChatDocumentContext? documentContext}) =>
      ChatMessage(
        id: id,
        role: role,
        text: text ?? this.text,
        createdAt: createdAt,
        status: status ?? this.status,
        notice: notice,
        model: model,
        documentContext: documentContext ?? this.documentContext,
      );

  Map<String, Object?> toJson() => {
        'id': id,
        'role': role.name,
        'text': text,
        'createdAt': createdAt.toIso8601String(),
        'status': status.name,
        'notice': notice,
        'model': model,
        if (documentContext != null)
          'documentContext': documentContext!.toJson(),
      };

  factory ChatMessage.fromJson(Map<String, dynamic> json) => ChatMessage(
        id: json['id'] as String,
        role: ChatRole.values.byName(json['role'] as String),
        text: json['text'] as String,
        createdAt: DateTime.parse(json['createdAt'] as String),
        status: MessageStatus.values.byName(json['status'] as String),
        notice: json['notice'] as String?,
        model: json['model'] as String?,
        documentContext: json['documentContext'] is Map
            ? ChatDocumentContext.fromJson(
                Map<String, dynamic>.from(json['documentContext'] as Map))
            : null,
      );
}

class ChatThread {
  ChatThread({
    required this.id,
    required this.title,
    required this.createdAt,
    required this.updatedAt,
    List<ChatMessage> messages = const [],
    this.useIndexedContext = true,
  }) : messages = List.unmodifiable(messages);

  final String id;
  final String title;
  final DateTime createdAt;
  final DateTime updatedAt;
  final List<ChatMessage> messages;
  final bool useIndexedContext;

  ChatThread copyWith(
          {String? title,
          List<ChatMessage>? messages,
          DateTime? updatedAt,
          bool? useIndexedContext}) =>
      ChatThread(
        id: id,
        title: title ?? this.title,
        createdAt: createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
        messages: messages ?? this.messages,
        useIndexedContext: useIndexedContext ?? this.useIndexedContext,
      );

  Map<String, Object?> toJson() => {
        'version': 1,
        'id': id,
        'title': title,
        'createdAt': createdAt.toIso8601String(),
        'updatedAt': updatedAt.toIso8601String(),
        'messages': messages.map((m) => m.toJson()).toList(),
        'useIndexedContext': useIndexedContext,
      };

  factory ChatThread.fromJson(Map<String, dynamic> json) {
    if (json['version'] != 1) {
      throw const FormatException('Unsupported chat version');
    }
    return ChatThread(
      id: json['id'] as String,
      title: json['title'] as String,
      createdAt: DateTime.parse(json['createdAt'] as String),
      updatedAt: DateTime.parse(json['updatedAt'] as String),
      useIndexedContext: json['useIndexedContext'] as bool? ?? true,
      messages: (json['messages'] as List)
          .map((m) => ChatMessage.fromJson(Map<String, dynamic>.from(m as Map)))
          .toList(),
    );
  }
}
