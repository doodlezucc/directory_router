class Config {
  String hostname;
  int port;
  Map<String, String> pathDirectories;

  Config(Map<String, dynamic> json)
      : hostname = json['hostname'],
        port = json['port'],
        pathDirectories = Map.from(json['directories']);

  Config.example()
      : hostname = 'localhost',
        port = 8080,
        pathDirectories = {'example': '../path/to/example_web_directory'};

  Map<String, dynamic> toJson() => {
        'hostname': hostname,
        'port': port,
        'directories': pathDirectories,
      };
}
