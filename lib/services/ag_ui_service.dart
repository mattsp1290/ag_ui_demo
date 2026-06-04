import 'dart:async';
import 'package:ag_ui/ag_ui.dart';
import 'package:flutter/foundation.dart';

class AgUiService {
  late AgUiClient _client;
  final String baseUrl;
  final StreamController<ConnectionStatus> _connectionController =
      StreamController<ConnectionStatus>.broadcast();

  Stream<ConnectionStatus> get connectionStatus => _connectionController.stream;

  AgUiService({String? baseUrl})
      : baseUrl = baseUrl ??
          const String.fromEnvironment('AG_UI_BASE_URL',
              defaultValue: 'http://localhost:8000') {
    _initializeClient();
  }

  void _initializeClient() {
    _client = AgUiClient(
      config: AgUiClientConfig(
        baseUrl: baseUrl,
      ),
    );
    _connectionController.add(ConnectionStatus.disconnected);
  }

  Stream<BaseEvent> sendMessage(String endpoint, String message) async* {
    try {
      _connectionController.add(ConnectionStatus.connecting);

      final input = SimpleRunAgentInput(
        threadId: 'thread_${DateTime.now().millisecondsSinceEpoch}',
        runId: 'run_${DateTime.now().millisecondsSinceEpoch}',
        messages: [
          UserMessage(
            id: 'user_${DateTime.now().millisecondsSinceEpoch}',
            content: message,
          ),
        ],
        tools: [],
        context: [],
        state: <String, dynamic>{},
        forwardedProps: <String, dynamic>{},
      );

      _connectionController.add(ConnectionStatus.connected);

      await for (final event in _client.runAgent(endpoint, input)) {
        yield event;
      }

      _connectionController.add(ConnectionStatus.disconnected);
    } catch (e) {
      _connectionController.add(ConnectionStatus.error);
      debugPrint('Error sending message: $e');
      rethrow;
    }
  }

  Stream<BaseEvent> sendMultimodalMessage(
    String endpoint,
    List<InputContent> parts,
  ) async* {
    try {
      _connectionController.add(ConnectionStatus.connecting);

      final input = SimpleRunAgentInput(
        threadId: 'thread_${DateTime.now().millisecondsSinceEpoch}',
        runId: 'run_${DateTime.now().millisecondsSinceEpoch}',
        messages: [
          UserMessage.multimodal(
            id: 'user_${DateTime.now().millisecondsSinceEpoch}',
            parts: parts,
          ),
        ],
        tools: [],
        context: [],
        state: <String, dynamic>{},
        forwardedProps: <String, dynamic>{},
      );

      _connectionController.add(ConnectionStatus.connected);

      await for (final event in _client.runAgent(endpoint, input)) {
        yield event;
      }

      _connectionController.add(ConnectionStatus.disconnected);
    } catch (e) {
      _connectionController.add(ConnectionStatus.error);
      debugPrint('Error sending multimodal message: $e');
      rethrow;
    }
  }

  void dispose() {
    _connectionController.close();
  }
}

enum ConnectionStatus {
  connected,
  connecting,
  disconnected,
  error,
}