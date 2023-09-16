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
  final String? server_entry;
  final String? hostname;
  final int? port;
  final bool auto_restart;

  Backend(this.server_entry, this.hostname, this.port, this.auto_restart);
}

class Frontend {
  final String directory;
  final String? build_entry;

  Frontend(this.directory, this.build_entry);
}
