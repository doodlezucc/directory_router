import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as path;
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as io;
import 'package:yaml/yaml.dart';

import 'config.dart';
import 'external_servers.dart';

const templateRoutes = 'bin/router_template.yaml';
const filePath = 'router.yaml';

final Map<Backend, ServerProcess> backendProcesses = {};
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
  await buildWebApps(config);
  await startExternalServers(config);

  var server = await io.serve(handler, config.hostname, port);
  print('Serving at http://${server.address.host}:${server.port}\n');
}

Future<void> buildWebApps(Config config) async {
  for (var frontend in config.frontends.values) {
    if (frontend.build_entry != null) {
      await dart2Js(File(path.join(frontend.directory, frontend.build_entry)));
    }
  }
}

Future<void> dart2Js(File entry) async {
  print('Building web app "${entry.path}"...');
  if (!await entry.exists()) {
    return stderr.writeln('- Entry file does not exist!\n');
  }

  var output = File(entry.path + '.js');

  if (await output.exists()) {
    var outStat = await output.stat();
    var dartStat = await entry.stat();
    if (outStat.modified.isAfter(dartStat.modified)) {
      return print('- Already up to date!\n');
    }
  }

  var process = await Process.start(
    'dart2js',
    [
      '--no-source-maps',
      '-o',
      output.path,
      entry.path,
    ],
    runInShell: true,
  );

  process.stdout.listen((data) {
    var s = utf8.decode(data).trim();
    print(s.split('\n').map((line) => '- $line').join('\n'));
  });
  process.stderr.listen((data) {
    stderr.add('- '.codeUnits + data);
  });

  await process.exitCode;
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
  }
  return null;
}

Future<Response> process(Request request, String match,
    Future<Response> Function(String subPath) generateResponse) async {
  if (request.url.path.startsWith(match)) {
    var dirSubPath = request.url.path.substring(match.length);

    if (dirSubPath.isEmpty || dirSubPath.endsWith('/')) {
      return Response.seeOther('/' + path.join(request.url.path, 'index'));
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
        scheme: 'http',
        host: backend.hostname ?? config.hostname,
        port: process?.port ?? backend.port,
        path: subPath,
        queryParameters: request.url.queryParameters,
      );

      var myReq = http.StreamedRequest(request.method, uri);
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
      var file = File(path.join(entry.value.directory, subPath));

      if (await file.exists() ||
          await (file = File(file.path + '.html')).exists()) {
        var type = getMimeType(file.path) ?? 'text/plain';
        return Response(
          200,
          body: file.openRead(),
          headers: {'Content-Type': type},
        );
      }
      return null;
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
