import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:hasura_connect/src/core/hasura.dart';
import 'package:hasura_connect/src/exceptions/hasura_error.dart';
import 'package:hasura_connect/src/services/local_storage.dart';
import 'package:hasura_connect/src/snapshot/snapshot.dart';
import 'package:hasura_connect/src/snapshot/snapshot_data.dart';
import 'package:hasura_connect/src/snapshot/snapshot_info.dart';
import 'package:hasura_connect/src/utils/utils.dart' as utils;
import 'package:http/io_client.dart';
import 'package:http_parser/http_parser.dart';
import 'package:websocket/websocket.dart';
import 'package:http/http.dart';

import '../../hasura_connect.dart';

// implementação amanda
IOClient _defaultClient = IOClient(
  HttpClient(
    context: SecurityContext.defaultContext,
  ),
);

class HasuraConnectBase implements HasuraConnect {
  final _controller = StreamController.broadcast();
  final Map<String, SnapshotData> _snapmap = {};
  Map<String, String> _headers;
  final LocalStorage Function() localStorageDelegate;
  // variable for add security context
  Client _httpClient;

  LocalStorage _localStorageMutation;
  LocalStorage _localStorageCache;
  WebSocket _channelPromisse;
  bool _isDisconnected = false;
  bool _isConnected = false;
  Completer<bool> _onConnect = Completer<bool>();

  final String url;

  Future<String> Function(bool isError) _token;

  HasuraConnectBase(this.url,
      {Map<String, dynamic> headers,
      this.localStorageDelegate,
      Future<String> Function(bool isError) token,
      Client httpClient}) {
    _token = token;
    _headers = headers ?? <String, String>{};
    _localStorageMutation = localStorageDelegate();
    _localStorageCache = localStorageDelegate();
    _localStorageMutation.init('hasura_mutations');
    _localStorageCache.init('hasura_cache');
    // fallback
    _httpClient = httpClient ?? _defaultClient;
  }

  final _init = {
    'payload': {
      'headers': {'content-type': 'application/json'}
    },
    'type': 'connection_init'
  };

  @override
  bool get isConnected => _isConnected;

  @override
  Map<String, String> get headers => UnmodifiableMapView(_headers);

  @override
  void changeToken(Future<String> Function(bool isError) token) {
    _token = token;
  }

  @override
  void addHeader(String key, String value) {
    _headers[key] = value;
  }

  @override
  void removeHeader(String key) {
    _headers.remove(key);
  }

  @override
  void removeAllHeader() {
    _headers.clear();
  }

  Stream _generateStream(String key) {
    return _controller.stream.where((data) => data['id'] == key).transform(
      StreamTransformer.fromHandlers(
        handleData: (data, sink) {
          if (data['type'] == 'data') {
            sink.add(data['payload']);
          } else if (data['type'] == 'error') {
            if ((data['payload'] as Map).containsKey('errors')) {
              sink.addError(HasuraError.fromJson(data['payload']['errors'][0]));
            } else {
              sink.addError(HasuraError.fromJson(data['payload']));
            }
          }
        },
      ),
    ).asBroadcastStream();
  }

  Stream _generateFutureQueryStream(Future query) {
    return Stream.fromFuture(query).asBroadcastStream();
  }

  @override
  Snapshot subscription(String query,
      {String key, Map<String, dynamic> variables}) {
    if (query.trim().split(' ')[0] != 'subscription') {
      query = 'subscription $query';
    }

    key = key ?? utils.generateBase(query);

    final info = SnapshotInfo(key: key, query: query, variables: variables);
    // _localStorage.addSubscription(info);
    return _generateSnapshot(info);
  }

  @override
  Snapshot cachedQuery(String query,
      {String key, Map<String, dynamic> variables}) {
    if (query.trimLeft().split(' ')[0] != 'query') {
      query = 'query $query';
    }

    key = key ?? utils.generateBase(query);

    var jsonMap = {'query': query, 'variables': variables};
    final info = SnapshotInfo(
        key: key, query: query, variables: variables, isQuery: true);
    return _generateSnapshot(info, futureQuery: _sendPost(jsonMap));
  }

  Snapshot _generateSnapshot(SnapshotInfo info, {Future futureQuery}) {
    if (_snapmap.keys.isEmpty && futureQuery == null) {
      _connect();
    }

    if (_snapmap.containsKey(info.key) && futureQuery == null) {
      return _snapmap[info.key];
    }

    if (_isConnected && futureQuery == null) {
      _channelPromisse.addUtf8Text(
          _getDocument(info.query, info.key, info.variables).codeUnits);
    }

    var snap = SnapshotData(
        info,
        info.isQuery
            ? _generateFutureQueryStream(futureQuery)
            : _generateStream(info.key), () async {
      if (futureQuery == null) {
        _stopStream(info.key);
        _snapmap.remove(info.key);
        if (_snapmap.keys.isEmpty) {
          await _disconnect();
        }
      }
    }, (snapshotInternal) {
      _stopStream(info.key);
      if (_isConnected) {
        _channelPromisse.addUtf8Text(_getDocument(snapshotInternal.info.query,
                snapshotInternal.info.key, snapshotInternal.info.variables)
            .codeUnits);
      }
    }, conn: this, localStorageCache: _localStorageCache);

    if (futureQuery == null) {
      _snapmap[info.key] = snap;
    }
    return snap;
  }

  void _stopStream(String key) {
    var stop = {'id': key, 'type': 'stop'};
    if (_isConnected) _channelPromisse.addUtf8Text(jsonEncode(stop).codeUnits);
  }

  String _getDocument(
      String query, String key, Map<String, dynamic> variables) {
    return jsonEncode({
      'id': key,
      'payload': {
        'query': query,
        'variables': variables,
      },
      'type': 'start'
    });
  }

  void _addToken([bool isError = false]) async {
    if (_token != null) {
      var t = await _token(isError);
      if (t != null) {
        (_init['payload'] as Map)['headers']['Authorization'] = t;
      }
    }
  }

  void _connect() async {
    print('hasura connecting...');
    try {
      _channelPromisse = await WebSocket.connect(url.replaceFirst('http', 'ws'),
          protocols: ['graphql-ws']); //graphql-subscriptions
      await _addToken();
      if (_headers != null) {
        for (var key in _headers?.keys) {
          (_init['payload'] as Map)['headers'][key] = _headers[key];
        }
      }
      _channelPromisse.addUtf8Text(jsonEncode(_init).codeUnits);
      var _sub = _channelPromisse.stream.listen((data) async {
        data = jsonDecode(data);
        if (data['type'] == 'data' || data['type'] == 'error') {
          _controller.add(data);
        } else if (data['type'] == 'connection_ack') {
          print('HASURA CONNECT!');
          _isConnected = true;

          for (var key in _snapmap.keys) {
            _channelPromisse.addUtf8Text(_getDocument(_snapmap[key].info.query,
                    _snapmap[key].info.key, _snapmap[key].info.variables)
                .codeUnits);
          }

          var mutationCache = await _localStorageMutation.getAll();
          for (var key in mutationCache.keys) {
            await _sendPost(mutationCache[key], key);
          }
        } else if (data['type'] == 'connection_error') {
          print('Try again...');
          await Future.delayed(Duration(seconds: 2));
          await _addToken(true);
          _channelPromisse.addUtf8Text(jsonEncode(_init).codeUnits);
        } else if (data['type'] == 'ka') {
        } else {
          print(data);
        }
      });
      _sub.onError((e) {
        print(e);
      });
      await _channelPromisse.done;
      await _sub.cancel();
      _isConnected = false;
      if (!_isDisconnected) {
        await Future.delayed(Duration(milliseconds: 3000));
        if (_onConnect.isCompleted) {
          _onConnect = Completer<bool>();
        }
        _connect();
      }
    } catch (e) {
      print(e);
      if (!_isDisconnected) {
        await Future.delayed(Duration(milliseconds: 3000));

        if (_onConnect.isCompleted) {
          _onConnect = Completer<bool>();
        }
        _connect();
      }
    }
  }

  void _disconnect() async {
    var disconect = {'type': 'connection_terminate'};
    if (_isConnected) {
      _channelPromisse.addUtf8Text(jsonEncode(disconect).codeUnits);
    }
    _isDisconnected = true;
    await Future.delayed(Duration(milliseconds: 300));
    if (_channelPromisse?.closeCode != null) {
      await _channelPromisse.close();
    }
    print('disconnected hasura');
  }

  @override
  Future query(String doc, {Map<String, dynamic> variables}) async {
    if (doc.trimLeft().split(' ')[0] != 'query') {
      doc = 'query $doc';
    }
    var jsonMap = {'query': doc, 'variables': variables};

    return await _sendPost(jsonMap);
  }

  @override
  Future mutation(String doc,
      {Map<String, dynamic> variables, bool tryAgain = true}) async {
    if (doc.trim().split(' ')[0] != 'mutation') {
      doc = 'mutation $doc';
    }
    var jsonMap = {'query': doc, 'variables': variables};
    var hash = utils.randomString(15);
    await _localStorageMutation.put(hash, jsonMap);
    return await _sendPost(jsonMap, hash);
  }

  Future _sendPost(Map jsonMap, [String hash]) async {
    // var jsonString = jsonEncode(jsonMap);

    Map<String, String> headersLocal = {
      'Content-type': 'application/json',
      'Accept': 'application/json'
    };

    if (_token != null) {
      String t = await _token(false);
      if (t != null) {
        headersLocal['Authorization'] = t;
      }
    }

    if (_headers != null) {
      for (var key in _headers?.keys) {
        headersLocal[key] = _headers[key];
      }
    }

    var request = await _prepareRequest(url, jsonMap, headersLocal);
    try {
      StreamedResponse response = await _httpClient.send(request);
      Map<String, dynamic> json = await _parseResponse(response);

      if (hash != null) {
        await _localStorageMutation.remove(hash);
      }
      if (json.containsKey('errors')) {
        throw HasuraError.fromJson(json['errors'][0]);
      }
      return json;
    } on SocketException catch (_) {
      throw HasuraError('connection error', null);
    } catch (e) {
      rethrow;
    } finally {
      // client.close();
    }
  }

  ///finalize Hasura connection
  void dispose() async {
    _httpClient.close();
    _disconnect();
    _snapmap.clear();
    await _localStorageMutation.close();
    await _localStorageCache.close();
    await _controller.close();
  }
}

Future<Map<String, MultipartFile>> _getFileMap(
  dynamic body, {
  Map<String, MultipartFile> currentMap,
  List<String> currentPath = const <String>[],
}) async {
  currentMap ??= <String, MultipartFile>{};
  if (body is Map<String, dynamic>) {
    final Iterable<MapEntry<String, dynamic>> entries = body.entries;
    for (MapEntry<String, dynamic> element in entries) {
      currentMap.addAll(await _getFileMap(
        element.value,
        currentMap: currentMap,
        currentPath: List<String>.from(currentPath)..add(element.key),
      ));
    }
    return currentMap;
  }
  if (body is List<dynamic>) {
    for (int i = 0; i < body.length; i++) {
      currentMap.addAll(await _getFileMap(
        body[i],
        currentMap: currentMap,
        currentPath: List<String>.from(currentPath)..add(i.toString()),
      ));
    }
    return currentMap;
  }
  if (body is MultipartFile) {
    return currentMap
      ..addAll(<String, MultipartFile>{currentPath.join('.'): body});
  }

  // else should only be either String, num, null; NOTHING else
  return currentMap;
}

Future<BaseRequest> _prepareRequest(
  String url,
  Map<String, dynamic> body,
  Map<String, String> httpHeaders,
) async {
  final Map<String, MultipartFile> fileMap = await _getFileMap(body);
  if (fileMap.isEmpty) {
    final Request r = Request('post', Uri.parse(url));
    r.headers.addAll(httpHeaders);
    r.body = json.encode(body);
    return r;
  }

  final MultipartRequest r = MultipartRequest('post', Uri.parse(url));
  r.headers.addAll(httpHeaders);
  r.fields['operations'] = json.encode(body, toEncodable: (dynamic object) {
    if (object is MultipartFile) {
      return null;
    }
    return object.toJson();
  });
  final Map<String, List<String>> fileMapping = <String, List<String>>{};
  final List<MultipartFile> fileList = <MultipartFile>[];

  final List<MapEntry<String, MultipartFile>> fileMapEntries =
      fileMap.entries.toList(growable: false);

  for (int i = 0; i < fileMapEntries.length; i++) {
    final MapEntry<String, MultipartFile> entry = fileMapEntries[i];
    final String indexString = i.toString();
    fileMapping.addAll(<String, List<String>>{
      indexString: <String>[entry.key],
    });
    final MultipartFile f = entry.value;
    fileList.add(MultipartFile(
      indexString,
      f.finalize(),
      f.length,
      contentType: f.contentType,
      filename: f.filename,
    ));
  }

  r.fields['map'] = json.encode(fileMapping);

  r.files.addAll(fileList);
  return r;
}

Future<Map<String, dynamic>> _parseResponse(StreamedResponse response) async {
  final int statusCode = response.statusCode;
  final Encoding encoding = _determineEncodingFromResponse(response);
  // @todo limit bodyBytes
  final Uint8List responseByte = await response.stream.toBytes();
  final String decodedBody = encoding.decode(responseByte);
  final Map<String, dynamic> jsonResponse = jsonDecode(decodedBody);

  if (jsonResponse['data'] == null && jsonResponse['errors']) {
    if (statusCode < 200 || statusCode >= 400) {
      throw HasuraError(
        'Network Error: $statusCode $decodedBody',
        null,
      );
    }
    throw HasuraError('Invalid response body: $decodedBody', null);
  }

  return jsonResponse;
}

/// Returns the charset encoding for the given response.
///
/// The default fallback encoding is set to UTF-8 according to the IETF RFC4627 standard
/// which specifies the application/json media type:
///   "JSON text SHALL be encoded in Unicode. The default encoding is UTF-8."
Encoding _determineEncodingFromResponse(BaseResponse response,
    [Encoding fallback = utf8]) {
  final String contentType = response.headers['content-type'];

  if (contentType == null) {
    return fallback;
  }

  final MediaType mediaType = MediaType.parse(contentType);
  final String charset = mediaType.parameters['charset'];

  if (charset == null) {
    return fallback;
  }

  final Encoding encoding = Encoding.getByName(charset);

  return encoding == null ? fallback : encoding;
}

/*



*/
