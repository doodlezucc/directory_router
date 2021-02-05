import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as path;

class ServerProcess {
  final String name;
  final int port;
  final Process process;

  ServerProcess(this.name, this.port, this.process);
}

Future<ServerProcess> startExternalServer(
    String name, int port, String serverDartFile) async {
  var cwd = path.dirname(serverDartFile);
  if (cwd.endsWith('/bin')) cwd = path.dirname(cwd);

  var process = await Process.start(
    'dart',
    [
      serverDartFile,
      '-p',
      '$port',
    ],
    workingDirectory: cwd,
  );

  process.stdout.listen((data) {
    var s = utf8.decode(data);
    print(s.trimRight().split('\n').map((e) => '[$name] $e').join('\n'));
  });
  process.stderr.listen((data) {
    stderr.add(data);
  });

  return ServerProcess(name, port, process);
}
