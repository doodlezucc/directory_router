import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:path/path.dart' as path;
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as io;

import 'config.dart';

// For Google Cloud Run, set _hostname to '0.0.0.0'.
const filePath = 'routes.json';

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
      .addMiddleware(logRequests())
      .addHandler((request) => _echoRequest(request, config));

  var server = await io.serve(handler, config.hostname, port);
  print('Serving at http://${server.address.host}:${server.port}');
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
  }
  return '';
}

Future<Response> _echoRequest(Request request, Config config) async {
  for (var entry in config.pathDirectories.entries) {
    if (request.url.path.startsWith(entry.key)) {
      var dirSubPath = request.url.path.substring(entry.key.length);
      if (dirSubPath.isEmpty) {
        return Response.seeOther(path.join(request.url.path, 'index.html'));
      }
      if (dirSubPath.startsWith('/')) {
        dirSubPath = dirSubPath.substring(1);
      }

      var file = File(path.join(entry.value, dirSubPath));

      if (await file.exists()) {
        var type = getMimeType(file);
        return Response(
          200,
          body: file.openRead(),
          headers: {'Content-Type': type},
        );
      }
    }
  }

  return Response.notFound('"${request.url}" not found.');
}
