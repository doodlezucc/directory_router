import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as path;
import 'package:watcher/watcher.dart';

class ServerProcess {
  final String name;
  final int port;
  Process _process;
  Process get process => _process;
  bool _booting = false;

  ServerProcess(this.name, this.port, Process process) : _process = process;
}

Future<ServerProcess> startExternalServer(
    String name, int port, String serverDartFile) async {
  var cwd = path.dirname(serverDartFile);
  if (cwd.endsWith('/bin')) cwd = path.dirname(cwd);

  Future<Process> startProcess() async {
    return await Process.start(
      'dart',
      [
        serverDartFile,
        '-p',
        '$port',
      ],
      workingDirectory: cwd,
    )
      ..stdout.listen((data) {
        var s = utf8.decode(data);
        print(s.trimRight().split('\n').map((e) => '[$name] $e').join('\n'));
      })
      ..stderr.listen(stderr.add);
  }

  var process = await startProcess();
  var out = ServerProcess(name, port, process);

  Watcher(cwd, pollingDelay: Duration(minutes: 1)).events.listen((event) async {
    var file = path.basename(event.path);
    if (out._booting ||
            file.endsWith('FETCH_HEAD') || // It's a git thing
            file.endsWith('.swp') // Apparently created by Vim
        ) {
      return;
    }

    out._booting = true;
    out._process.kill();
    await out._process.exitCode;
    print(' $name - RESTART due to changes in $file');
    out._process = await startProcess();
    out._booting = false;
  });

  return out;
}
