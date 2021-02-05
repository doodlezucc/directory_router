class Config {
  String hostname;
  int port;
  Map<String, String> frontendDirectories;
  Map<String, String> backendDirectories;

  Config(Map<String, dynamic> json)
      : hostname = json['hostname'],
        port = json['port'],
        frontendDirectories = Map.from(json['frontend']),
        backendDirectories = Map.from(json['backend']);

  Config.example()
      : hostname = 'localhost',
        port = 8080,
        frontendDirectories = {'example': '../path/to/example_web_directory'},
        backendDirectories = {'big-app': '../path/to/dart_server/server.dart'};

  Map<String, dynamic> toJson() => {
        'hostname': hostname,
        'port': port,
        'frontend': frontendDirectories,
        'backend': backendDirectories,
      };
}
