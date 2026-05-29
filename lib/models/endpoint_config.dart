import 'package:flutter/material.dart';

class EndpointConfig {
  final String name;
  final String path;
  final String description;
  final IconData icon;

  const EndpointConfig({
    required this.name,
    required this.path,
    required this.description,
    required this.icon,
  });

  static const List<EndpointConfig> availableEndpoints = [
    EndpointConfig(
      name: 'Agentic Chat',
      path: 'agentic_chat',
      description: 'Basic chat functionality with AI agent',
      icon: Icons.chat,
    ),
    EndpointConfig(
      name: 'Human in the Loop',
      path: 'human_in_the_loop',
      description: 'Chat with human approval steps',
      icon: Icons.person_add,
    ),
    EndpointConfig(
      name: 'Generative UI',
      path: 'agentic_generative_ui',
      description: 'Chat with generative UI components',
      icon: Icons.widgets,
    ),
    EndpointConfig(
      name: 'Tool-based UI',
      path: 'tool_based_generative_ui',
      description: 'Chat with tool calls and UI generation',
      icon: Icons.build,
    ),
    EndpointConfig(
      name: 'Shared State',
      path: 'shared_state',
      description: 'Chat with shared state management',
      icon: Icons.sync,
    ),
    EndpointConfig(
      name: 'Predictive Updates',
      path: 'predictive_state_updates',
      description: 'Chat with predictive state updates',
      icon: Icons.update,
    ),
    EndpointConfig(
      name: 'Image Gen',
      path: 'image-gen',
      description: 'Generate images from a text prompt using GPT-4o',
      icon: Icons.image_outlined,
    ),
  ];
}