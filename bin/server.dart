import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as path;
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as io;

import 'config.dart';
import 'external_servers.dart';

const filePath = 'routes.json';

final Map<String, ServerProcess> directoryProcesses = {};
final client = http.Client();

void test() async {
  var dirSubPath = 'index.html';

  var uri = Uri(
    scheme: 'http',
    host: 'localhost',
    port: 8081,
    path: dirSubPath,
  );

  var myReq = http.Request('GET', uri);
  //..headers.addAll(request.headers)
  //..bodyBytes = ;

  var response = await client.send(myReq);

  var body = await response.stream;

  var shRes = Response(
    response.statusCode,
    body: body,
    headers: response.headers,
  );
  print(shRes.statusCode);
  print(body);
}

void main(List<String> args) async {
  var config = await loadRoutes();
  print('Loaded config file');

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
  await startExternalServers(config);

  var server = await io.serve(handler, config.hostname, port);
  print('Serving at http://${server.address.host}:${server.port}');

  //await test();

  await Future.delayed(Duration(seconds: 1));
  //onExit();
}

void onExit() {
  print('Killing external servers');
  for (var sp in directoryProcesses.values) {
    sp.process.kill();
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
  for (var serverDartFile in config.backendDirectories.values) {
    var name = serverDartFile;
    directoryProcesses[name] =
        await startExternalServer(name, ++port, serverDartFile);
    print('Starting [$name]...');
  }
}

Future<Config> loadRoutes() async {
  var file = File(filePath);
  if (!await file.exists()) {
    await file.create();

    await file
        .writeAsString(JsonEncoder.withIndent('  ').convert(Config.example()));
    print('Created example config file at "${path.absolute(filePath)}"');
    return exit(0);
  }

  var data = await file.readAsString();
  return Config(jsonDecode(data));
}

String getMimeType(File f) {
  switch (path.extension(f.path)) {
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
  return 'text/plain';
}

Future<Response> process(Request request, String match,
    Future<Response> Function(String subPath) generateResponse) async {
  if (request.url.path.startsWith(match)) {
    var dirSubPath = request.url.path.substring(match.length);

    if (dirSubPath.isEmpty) {
      return Response.seeOther(path.join(request.url.path, 'index.html'));
    }
    if (dirSubPath.startsWith('/')) {
      dirSubPath = dirSubPath.substring(1);
    }

    return generateResponse(dirSubPath);
  }
  return null;
}

Future<Response> processBackend(Request request, Config config) async {
  Response response;
  for (var entry in config.backendDirectories.entries) {
    response = await process(request, entry.key, (subPath) async {
      var process = directoryProcesses[entry.value];
      var uri = Uri(
        scheme: 'http',
        host: config.hostname,
        port: process.port,
        path: subPath,
        queryParameters: request.url.queryParameters,
      );

      var myReq = http.StreamedRequest(request.method, uri);
      request.read().listen(
            myReq.sink.add,
            onDone: () => myReq.sink.close(),
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
  }
  return response;
}

Future<Response> processFrontend(Request request, Config config) async {
  for (var entry in config.frontendDirectories.entries) {
    var response = await process(request, entry.key, (subPath) async {
      var file = File(path.join(entry.value, subPath));

      if (await file.exists()) {
        var type = getMimeType(file);
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

Response notFound(Request request, Config config) {
  print('404: "${request.url}" not found.');
  return Response.notFound('"${request.url}" not found.');
}

Future<Response> _echoRequest(Request request, Config config) async {
  return (await processBackend(request, config)) ??
      (await processFrontend(request, config)) ??
      notFound(request, config);
}
