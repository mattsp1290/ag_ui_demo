import 'package:flutter/material.dart';
import 'package:ag_ui/ag_ui.dart';

/// Which page family renders an endpoint. Drives dispatch in `main.dart`.
enum FeatureKind {
  /// Generic chat bubbles (reasoning, image-gen).
  chat,

  /// Client-tool round-trip: define tools, model calls one, client executes and
  /// re-runs. `agentic_chat` (inline results) + `tool_based_generative_ui` (cards).
  clientTools,

  /// Client-tool round-trip with an approve/deny gate (`human_in_the_loop`).
  approval,

  /// Live state projection: STATE_SNAPSHOT + RFC-6902 STATE_DELTA stream
  /// (`agentic_generative_ui`, `shared_state`, `predictive_state_updates`).
  liveState,

  /// File-attachment multimodal input (vision, audio, document).
  multimodal,
}

class EndpointConfig {
  final String name;
  final String path;
  final String description;
  final IconData icon;
  final bool isMultimodal;
  final List<String> allowedExtensions;
  final FeatureKind featureKind;

  /// Client tool definitions sent with every run for this endpoint. Const-safe:
  /// `Tool` has a const constructor and the parameter maps are pure literals.
  final List<Tool> tools;

  const EndpointConfig({
    required this.name,
    required this.path,
    required this.description,
    required this.icon,
    this.isMultimodal = false,
    this.allowedExtensions = const [],
    this.featureKind = FeatureKind.chat,
    this.tools = const [],
  });

  static const List<EndpointConfig> availableEndpoints = [
    EndpointConfig(
      name: 'Agentic Chat',
      path: 'agentic_chat',
      description: 'Chat that can call client-defined tools',
      icon: Icons.chat,
      featureKind: FeatureKind.clientTools,
      tools: [
        Tool(
          name: 'get_current_time',
          description: 'Returns the current local time.',
          parameters: {'type': 'object', 'properties': {}, 'required': []},
        ),
        Tool(
          name: 'calculate',
          description:
              'Evaluates a simple arithmetic expression and returns the number.',
          parameters: {
            'type': 'object',
            'properties': {
              'expression': {
                'type': 'string',
                'description': 'e.g. "12 * 7 + 3"',
              },
            },
            'required': ['expression'],
          },
        ),
      ],
    ),
    EndpointConfig(
      name: 'Human in the Loop',
      path: 'human_in_the_loop',
      description: 'Agent proposes consequential actions; you approve or deny',
      icon: Icons.person_add,
      featureKind: FeatureKind.approval,
      tools: [
        Tool(
          name: 'send_email',
          description:
              'Sends an email. Consequential — must be approved before sending.',
          parameters: {
            'type': 'object',
            'properties': {
              'to': {'type': 'string'},
              'subject': {'type': 'string'},
              'body': {'type': 'string'},
            },
            'required': ['to', 'subject', 'body'],
          },
        ),
        Tool(
          name: 'delete_file',
          description:
              'Deletes a file. Consequential — must be approved before deleting.',
          parameters: {
            'type': 'object',
            'properties': {
              'path': {'type': 'string'},
            },
            'required': ['path'],
          },
        ),
      ],
    ),
    EndpointConfig(
      name: 'Generative UI',
      path: 'agentic_generative_ui',
      description: 'Animated checklist driven by streamed state deltas',
      icon: Icons.widgets,
      featureKind: FeatureKind.liveState,
    ),
    EndpointConfig(
      name: 'Tool-based UI',
      path: 'tool_based_generative_ui',
      description: 'Model renders UI cards via tool calls instead of prose',
      icon: Icons.build,
      featureKind: FeatureKind.clientTools,
      tools: [
        Tool(
          name: 'render_card',
          description:
              'Render a titled card with key/value facts and an optional image URL.',
          parameters: {
            'type': 'object',
            'properties': {
              'title': {'type': 'string'},
              'subtitle': {'type': 'string'},
              'facts': {
                'type': 'array',
                'items': {
                  'type': 'object',
                  'properties': {
                    'label': {'type': 'string'},
                    'value': {'type': 'string'},
                  },
                  'required': ['label', 'value'],
                },
              },
              'imageUrl': {'type': 'string'},
            },
            'required': ['title'],
          },
        ),
      ],
    ),
    EndpointConfig(
      name: 'Shared State',
      path: 'shared_state',
      description: 'Collaborative recipe card edited by agent + you',
      icon: Icons.sync,
      featureKind: FeatureKind.liveState,
    ),
    EndpointConfig(
      name: 'Predictive Updates',
      path: 'predictive_state_updates',
      description: 'Optimistic ghosted draft that commits to real state',
      icon: Icons.update,
      featureKind: FeatureKind.liveState,
    ),
    EndpointConfig(
      name: 'Image Gen',
      path: 'image-gen',
      description: 'Generate images from a text prompt using GPT-4o',
      icon: Icons.image_outlined,
    ),
    EndpointConfig(
      name: 'Vision',
      path: 'vision',
      description: 'Analyze images with GPT-4o vision',
      icon: Icons.image_search,
      isMultimodal: true,
      allowedExtensions: ['jpg', 'jpeg', 'png', 'gif', 'webp'],
      featureKind: FeatureKind.multimodal,
    ),
    EndpointConfig(
      name: 'Audio',
      path: 'audio',
      description: 'Transcribe audio with Whisper',
      icon: Icons.mic,
      isMultimodal: true,
      allowedExtensions: ['mp3', 'wav', 'm4a', 'ogg', 'webm'],
      featureKind: FeatureKind.multimodal,
    ),
    EndpointConfig(
      name: 'Document Q&A',
      path: 'document',
      description: 'Ask questions about a PDF',
      icon: Icons.description,
      isMultimodal: true,
      allowedExtensions: ['pdf'],
      featureKind: FeatureKind.multimodal,
    ),
    EndpointConfig(
      name: 'Reasoning Demo',
      path: 'reasoning',
      description: 'Streams live reasoning events and includes a ReasoningMessage '
          'in MESSAGES_SNAPSHOT. Exercises the new Dart ReasoningMessage type.',
      icon: Icons.psychology,
    ),
  ];
}
