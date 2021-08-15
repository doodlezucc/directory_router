import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as path;
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as io;
import 'package:watcher/watcher.dart';
import 'package:yaml/yaml.dart';

import 'config.dart';
import 'external_servers.dart';

const templateRoutes = 'bin/router_template.yaml';
const filePath = 'router.yaml';

final Map<Backend, ServerProcess> backendProcesses = {};
final Map<String, Process> frontendProcesses = {};
final client = http.Client();

void main(List<String> args) async {
  var config = await loadRoutes();

  var parser = ArgParser()..addOption('port', abbr: 'p');
  var result = parser.parse(args);

  // For Google Cloud Run, we respect the PORT environment variable
  var portStr = result['port'] ?? Platform.environment['PORT'];
  var port = portStr != null ? int.tryParse(portStr) : config.port;

  if (port == null) {
    stdout.writeln('Could not parse port value "$portStr" into a number.');
    // 64: command line usage error
    exitCode = 64;
    return;
  }

  Response _cors(Response response) => response.change(headers: {
        'Access-Control-Allow-Origin': '*',
        'Access-Control-Allow-Methods': 'GET, POST',
        'Access-Control-Allow-Headers': 'Origin, Content-Type, X-Auth-Token',
      });

  var _fixCORS = createMiddleware(responseHandler: _cors);

  var handler = const Pipeline()
      .addMiddleware(_fixCORS)
      .addHandler((request) => _echoRequest(request, config));

  listenToExit();

  var server = await io.serve(handler, config.hostname, port);
  print('Serving at http://${server.address.host}:${server.port}\n');

  await buildWebApps(config);
  await startExternalServers(config);
}

Future<void> buildWebApps(Config config) async {
  for (var frontend in config.frontends.values) {
    if (frontend.build_entry != null) {
      var entry = File(path.join(frontend.directory, frontend.build_entry));

      Future<void> build(bool force) async =>
          await dart2Js(entry, force: force);

      Watcher(frontend.directory, pollingDelay: Duration(minutes: 1))
          .events
          .listen((event) async {
        var file = path.basename(event.path);

        if (file.endsWith('.dart')) {
          print('Rebuilding ${frontend.directory} due to changes in $file');
          frontendProcesses[entry.path]?.kill(ProcessSignal.sigint);
          await build(true);
        }
      });

      await build(false);
    }
  }
}

Future<int> debugProcess(Process process) async {
  process
    ..stdout.listen((data) {
      var s = utf8.decode(data).trim();
      print(s.split('\n').map((line) => '- $line').join('\n'));
    })
    ..stderr.listen(stderr.add);

  return process.exitCode;
}

Future<void> dart2Js(File entry, {bool force = false}) async {
  print('Building web app "${entry.path}"...');
  if (!await entry.exists()) {
    return stderr.writeln('- Entry file does not exist!\n');
  }

  var output = File(entry.path + '.js');

  if (await output.exists()) {
    var outStat = await output.stat();
    var dirStat = await Directory(path.dirname(entry.path)).stat();

    if (!force &&
        !outStat.modified
            .isBefore(dirStat.modified.subtract(Duration(minutes: 1)))) {
      return print('- Already up to date!\n');
    }
  }

  var pubProcess = frontendProcesses[entry.path] = await Process.start(
    'pub',
    ['get', '--verbosity=warning'],
    runInShell: true,
  );
  frontendProcesses[entry.path] = pubProcess;
  if (await debugProcess(pubProcess) == -1) return;

  print('- Compiling...');
  var compileProcess = await Process.start(
    'dart2js',
    [
      '--no-source-maps',
      '-o',
      output.path,
      entry.path,
    ],
    runInShell: true,
  );
  frontendProcesses[entry.path] = compileProcess;
  if (await debugProcess(compileProcess) == -1) return;

  print('');
  return File(output.path + '.deps').delete();
}

void onExit() {
  if (backendProcesses.isNotEmpty) {
    print('Killing external servers');
    for (var sp in backendProcesses.values) {
      sp.process.kill();
    }
  }
  exit(0);
}

void listenToExit() {
  var shuttingDown = false;
  ProcessSignal.sigint.watch().forEach((signal) {
    if (!shuttingDown) {
      shuttingDown = true;
      onExit();
    }
  });
}

Future<void> startExternalServers(Config config) async {
  var port = config.port;
  for (var backend in config.backends.values) {
    if (backend.server_entry != null) {
      var name = backend.server_entry;
      backendProcesses[backend] = await startExternalServer(
        name,
        backend.port ?? ++port,
        backend.server_entry,
        backend.auto_restart,
      );
      print('Starting "$name"');
    }
  }
  if (config.backends.isNotEmpty) print('');
}

Future<Config> loadRoutes() async {
  var file = File(filePath);
  if (!await file.exists()) {
    await file.create();

    var template = File(templateRoutes);
    if (!await template.exists()) {
      throw '''Could not generate routes.yaml because
      routes_template.yaml does not exist!''';
    }

    await file.writeAsBytes(await template.readAsBytes());
    print('Created example config file at "${path.absolute(filePath)}"');
    return exit(0);
  }

  var data = await file.readAsString();
  return Config(loadYaml(data));
}

String getMimeType(String filePath) {
  switch (path.extension(filePath)) {
    case '.html':
      return 'text/html';
    case '.css':
      return 'text/css';
    case '.js':
      return 'text/javascript';
    case '.svg':
      return 'image/svg+xml';
    case '.ico':
      return 'image/x-icon';
    case '.png':
      return 'image/png';
    case '.jpg':
      return 'image/jpeg';
    case '.xml':
      return 'text/xml';
    case '.mp4':
      return 'video/mp4';
    case '.mp3':
      return 'audio/mpeg';
    case '.ogg':
      return 'audio/ogg';
    case '.wav':
      return 'audio/wav';
  }
  return null;
}

Future<Response> process(Request request, String match,
    Future<Response> Function(String subPath) generateResponse) async {
  if (request.url.path.startsWith(match)) {
    var dirSubPath = request.url.path.substring(match.length);

    if (dirSubPath.isEmpty || dirSubPath.endsWith('/')) {
      return Response.seeOther('/' + path.join(request.url.path, 'home'));
    }
    if (dirSubPath.startsWith('/')) {
      dirSubPath = dirSubPath.substring(1);
    }

    return generateResponse(dirSubPath);
  }
  return null;
}

Future<Response> processBackend(Request request, Config config) async {
  for (var entry in config.backends.entries) {
    var backend = entry.value;
    var response = await process(request, entry.key, (subPath) async {
      var process = backendProcesses[backend];
      var uri = Uri(
        scheme: request.requestedUri.scheme,
        host: backend.hostname ?? config.hostname,
        port: process?.port ?? backend.port,
        path: subPath,
        queryParameters: request.url.queryParameters,
      );

      var myReq = http.StreamedRequest(request.method, uri)
        ..headers.addAll(request.headers);
      request.read().listen(
            myReq.sink.add,
            onDone: myReq.sink.close,
          );
      var response = await client.send(myReq);
      var body = response.stream;

      return Response(
        response.statusCode,
        body: body,
        headers: response.headers
          // idk why but http_parser fails if "transfer-encoding"
          // is set to "chunked"
          ..removeWhere(
              (key, value) => key.toLowerCase() == 'transfer-encoding'),
      );
    });
    if (response != null) {
      return response;
    }
  }
  return null;
}

Future<Response> processFrontend(Request request, Config config) async {
  for (var entry in config.frontends.entries) {
    var response = await process(request, entry.key, (subPath) async {
      if (subPath == 'home' || subPath == 'index') {
        subPath = 'index.html';
      }

      var file = File(path.join(entry.value.directory, subPath));

      if (!await file.exists()) {
        file = File(file.path + '.html');
        if (!await file.exists()) {
          return null;
        }
      }

      var type = getMimeType(file.path) ?? 'text/plain';
      return Response(
        200,
        body: file.openRead(),
        headers: {'Content-Type': type},
      );
    });
    if (response != null) return response;
  }
  return null;
}

Response logResponse(Request request, Response response) {
  print('${DateTime.now().toIso8601String()} '
      '${request.method.padRight(7)} [${response.statusCode}] '
      '${request.url}');
  return response;
}

Future<Response> _echoRequest(Request request, Config config) async {
  return (await processBackend(request, config)) ??
      logResponse(
          request,
          await processFrontend(request, config) ??
              Response.notFound('"${request.url}" not found.'));
}
