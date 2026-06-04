import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'models/endpoint_config.dart';
import 'pages/chat_page.dart';
import 'pages/multimodal_chat_page.dart';

void main() {
  runApp(MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider(
      create: (context) => ChatAppState(),
      child: MaterialApp(
        title: 'AG-UI Chat Demo',
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
          useMaterial3: true,
        ),
        home: MyHomePage(),
      ),
    );
  }
}

class ChatAppState extends ChangeNotifier {
  int _selectedEndpointIndex = 0;
  final List<EndpointConfig> endpoints = EndpointConfig.availableEndpoints;

  int get selectedEndpointIndex => _selectedEndpointIndex;
  EndpointConfig get selectedEndpoint => endpoints[_selectedEndpointIndex];

  void selectEndpoint(int index) {
    if (index >= 0 && index < endpoints.length) {
      _selectedEndpointIndex = index;
      notifyListeners();
    }
  }
}

class MyHomePage extends StatefulWidget {
  @override
  State<MyHomePage> createState() => _MyHomePageState();
}

class _MyHomePageState extends State<MyHomePage> {
  @override
  Widget build(BuildContext context) {
    final appState = context.watch<ChatAppState>();
    final selectedIndex = appState.selectedEndpointIndex;
    final endpoint = appState.selectedEndpoint;

    Widget page = endpoint.isMultimodal
        ? MultimodalChatPage(
            key: ValueKey(endpoint.path),
            endpoint: endpoint,
          )
        : ChatPage(
            key: ValueKey(endpoint.path),
            endpoint: endpoint,
          );

    return LayoutBuilder(
      builder: (context, constraints) {
        return Scaffold(
          body: Row(
            children: [
              SafeArea(
                child: NavigationRail(
                  extended: constraints.maxWidth >= 900,
                  destinations: appState.endpoints.map((endpoint) {
                    return NavigationRailDestination(
                      icon: Icon(endpoint.icon),
                      label: Text(endpoint.name),
                    );
                  }).toList(),
                  selectedIndex: selectedIndex,
                  onDestinationSelected: (value) {
                    appState.selectEndpoint(value);
                  },
                ),
              ),
              Expanded(
                child: page,
              ),
            ],
          ),
        );
      },
    );
  }
}
