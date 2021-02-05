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
  final String server_entry;
  final String hostname;
  final int port;

  Backend(this.server_entry, this.hostname, this.port);
}

class Frontend {
  final String directory;
  final String build_entry;

  Frontend(this.directory, this.build_entry);
}
