import 'dart:convert';
import 'package:flutter/material.dart';
import '../models/chat_message.dart';

class ChatMessageWidget extends StatelessWidget {
  final ChatMessage message;

  const ChatMessageWidget({Key? key, required this.message}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    if (message.type == ChatMessageType.image) {
      final base64Str = message.content.split(',').last;
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            CircleAvatar(
              radius: 16,
              backgroundColor: theme.colorScheme.primary,
              child: Icon(Icons.image, size: 20, color: theme.colorScheme.onPrimary),
            ),
            const SizedBox(width: 8),
            Flexible(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: Image.memory(
                  base64Decode(base64Str),
                  fit: BoxFit.contain,
                  width: 300,
                  errorBuilder: (_, __, ___) => const Text('(image failed to load)'),
                ),
              ),
            ),
          ],
        ),
      );
    }

    final isUser = message.type == ChatMessageType.user;
    final isAssistant = message.type == ChatMessageType.assistant;
    final isTool = message.type == ChatMessageType.tool;
    final isThinking = message.type == ChatMessageType.thinking;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Row(
        mainAxisAlignment:
            isUser ? MainAxisAlignment.end : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!isUser) ...[
            CircleAvatar(
              radius: 16,
              backgroundColor: isAssistant
                  ? theme.colorScheme.primary
                  : isTool
                      ? theme.colorScheme.secondary
                      : isThinking
                          ? theme.colorScheme.tertiary
                          : theme.colorScheme.surface,
              child: Icon(
                isAssistant
                    ? Icons.smart_toy
                    : isTool
                        ? Icons.build
                        : isThinking
                            ? Icons.psychology
                            : Icons.info,
                size: 20,
                color: theme.colorScheme.onPrimary,
              ),
            ),
            const SizedBox(width: 8),
          ],
          Flexible(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              decoration: BoxDecoration(
                color: isUser
                    ? theme.colorScheme.primaryContainer
                    : isThinking
                        ? theme.colorScheme.tertiaryContainer.withOpacity(0.5)
                        : theme.colorScheme.surfaceVariant,
                borderRadius: BorderRadius.only(
                  topLeft: Radius.circular(isUser ? 20 : 4),
                  topRight: Radius.circular(isUser ? 4 : 20),
                  bottomLeft: const Radius.circular(20),
                  bottomRight: const Radius.circular(20),
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (isTool && message.toolName != null) ...[
                    Row(
                      children: [
                        Icon(
                          Icons.functions,
                          size: 16,
                          color: theme.colorScheme.secondary,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          message.toolName!,
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            color: theme.colorScheme.secondary,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                  ],
                  Text(
                    message.content,
                    style: TextStyle(
                      color: isUser
                          ? theme.colorScheme.onPrimaryContainer
                          : isThinking
                              ? theme.colorScheme.onTertiaryContainer
                              : theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  if (message.isStreaming) ...[
                    const SizedBox(height: 4),
                    SizedBox(
                      width: 20,
                      height: 2,
                      child: LinearProgressIndicator(
                        backgroundColor: Colors.transparent,
                        valueColor: AlwaysStoppedAnimation<Color>(
                          theme.colorScheme.primary.withOpacity(0.5),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
          if (isUser) ...[
            const SizedBox(width: 8),
            CircleAvatar(
              radius: 16,
              backgroundColor: theme.colorScheme.primary,
              child: Icon(
                Icons.person,
                size: 20,
                color: theme.colorScheme.onPrimary,
              ),
            ),
          ],
        ],
      ),
    );
  }
}