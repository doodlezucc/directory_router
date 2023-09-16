import 'package:yaml/yaml.dart';

class Config {
  String hostname;
  int port;
  Map<String, Backend> backends;
  Map<String, Frontend> frontends;

  Config(YamlMap yaml)
      : hostname = yaml['hostname'],
        port = yaml['port'],
        backends = yaml['backend'] == null
            ? {}
            : Map.from(yaml['backend']).map((key, y) => MapEntry(
                key,
                Backend(
                  y['server_entry'],
                  y['hostname'],
                  y['port'],
                  y['auto_restart'] ?? false,
                ))),
        frontends = yaml['frontend'] == null
            ? {}
            : Map.from(yaml['frontend']).map((key, y) => MapEntry(
                key,
                Frontend(
                  y['directory'],
                  y['build_entry'],
                )));
}

class Backend {
  final String? serverEntry;
  final String? hostname;
  final int? port;
  final bool autoRestart;

  Backend(this.serverEntry, this.hostname, this.port, this.autoRestart);
}

class Frontend {
  final String directory;
  final String? buildEntry;

  Frontend(this.directory, this.buildEntry);
}
