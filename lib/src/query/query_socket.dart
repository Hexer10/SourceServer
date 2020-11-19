import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:typed_buffer/typed_buffer.dart';

import 'models/query_player.dart';
import 'models/server_info.dart';
import 'models/server_os.dart';
import 'models/server_type.dart';
import 'models/server_vac.dart';
import 'models/server_visibility.dart';

abstract class QuerySocket {
  factory QuerySocket._(
          InternetAddress address, int port, RawDatagramSocket socket) =
      _QuerySocketImpl;

  /// Returns the info about this server.
  Future<ServerInfo> getInfo();

  /// Returns a list of currently connected players.
  Future<List<QueryPlayer>> getPlayers();

  /// Returns the server rules, or configuration variables in name/value pairs.
  /// Warning: In some games such as CS:GO this never completes without
  /// having installed a plugin on the server.
  Future<Map<String, String>> getRules();

  /// Closes the connection
  void close();

  /// Setup the connection to the remote server.
  /// This does not guarantee that the connection will be established successfully.
  static Future<QuerySocket> connect(dynamic address, int port,
      {int localPort = 6000}) async {
    assert(address is String || address is InternetAddress);
    if (address is String) {
      // ignore: parameter_assignments
      address = (await InternetAddress.lookup(address as String)).first;
    }

    final socket =
        await RawDatagramSocket.bind(InternetAddress.anyIPv4, localPort);
    return QuerySocket._(address as InternetAddress, port, socket);
  }
}

class _QuerySocketImpl implements QuerySocket {
  final InternetAddress address;
  final int port;
  final RawDatagramSocket socket;

  Completer<ServerInfo> infoCompleter;
  Completer<Uint8List> challengeCompleter;
  Completer<List<QueryPlayer>> playersCompleter;
  Completer<Map<String, String>> rulesCompleter;

  Uint8List challenge;

  _QuerySocketImpl(this.address, this.port, this.socket)
      : assert(socket != null) {
    socket.listen(onEvent);
  }

  Future<Uint8List> getChallenge() async {
    if (challenge != null) {
      return challenge;
    }
    // assert(!(challengeCompleter?.isCompleted ?? false));
    if (challengeCompleter != null) {
      return challengeCompleter.future;
    }
    challengeCompleter = Completer<Uint8List>();
    socket.send(QueryPacket.challenge.bytes, address, port);
    return challengeCompleter.future;
  }

  @override
  Future<ServerInfo> getInfo() {
    assert(!(infoCompleter?.isCompleted ?? false));
    if (infoCompleter != null) {
      return infoCompleter.future;
    }
    infoCompleter = Completer<ServerInfo>();
    socket.send(QueryPacket.info.bytes, address, port);
    return infoCompleter.future;
  }

  @override
  Future<List<QueryPlayer>> getPlayers() async {
    assert(!(playersCompleter?.isCompleted ?? false));
    if (playersCompleter != null) {
      return playersCompleter.future;
    }
    playersCompleter = Completer<List<QueryPlayer>>();
    // ignore: unawaited_futures
    getChallenge().then((value) =>
        socket.send(QueryPacket.players(value).bytes, address, port));
    return playersCompleter.future;
  }

  @override
  Future<Map<String, String>> getRules() async {
    assert(!(rulesCompleter?.isCompleted ?? false));
    if (rulesCompleter != null) {
      return rulesCompleter.future;
    }
    rulesCompleter = Completer<Map<String, String>>();
    // ignore: unawaited_futures
    getChallenge().then(
        (value) => socket.send(QueryPacket.rules(value).bytes, address, port));
    return rulesCompleter.future;
  }

  void parseInfo(Uint8List bytes) {
    final read = ReadBuffer.fromUint8List(bytes);

    final protocol = read.uint8;
    final name = read.nullTerminatedUtf8String;
    final map = read.nullTerminatedUtf8String;
    final folder = read.nullTerminatedUtf8String;
    final game = read.nullTerminatedUtf8String;
    final id = read.int16;
    final players = read.uint8;
    final maxPlayers = read.uint8;
    final bots = read.uint8;
    final type = ServerType(read.uint8);
    final os = ServerOS(read.uint8);
    final visibility = ServerVisibility(read.uint8);
    final vac = ServerVAC(read.uint8);
    /* TODO: Add TheShip flags*/
    final version = read.nullTerminatedUtf8String;
    var info = ServerInfo(
        protocol: protocol,
        name: name,
        map: map,
        folder: folder,
        game: game,
        id: id,
        players: players,
        maxPlayers: maxPlayers,
        bots: bots,
        type: type,
        os: os,
        visibility: visibility,
        vac: vac,
        version: version);
    if (read.canReadMore) {
      final edf = read.uint8;
      int port;
      int steamId;
      int tvPort;
      String tvName;
      String keywords;
      int gameId;

      if (edf & 0x80 != 0) {
        port = read.uint8;
      }
      if (edf & 0x10 != 0) {
        steamId = read.int64;
      }
      if (edf & 0x40 != 0) {
        tvPort = read.uint8;
        tvName = read.nullTerminatedUtf8String;
      }
      if (edf & 0x20 != 0) {
        keywords = read.nullTerminatedUtf8String;
      }
      if (edf & 0x01 != 0) {
        gameId = read.int64;
      }
      info = info.copyWith(
          port: port,
          steamId: steamId,
          tvPort: tvPort,
          tvName: tvName,
          keywords: keywords,
          gameId: gameId);
    }

    infoCompleter.complete(info);
    infoCompleter = null;
  }

  void parseChallenge(Uint8List bytes) {
    challenge = bytes;
    challengeCompleter.complete(challenge);
    challengeCompleter = null;
  }

  void parsePlayers(Uint8List bytes) {
    assert(playersCompleter != null);
    assert(!playersCompleter.isCompleted);
    final read = ReadBuffer.fromUint8List(bytes.sublist(1));
    final players = <QueryPlayer>[];
    while (read.canReadMore) {
      players.add(QueryPlayer(
          index: read.uint8,
          name: read.nullTerminatedUtf8String,
          score: read.int32,
          duration: read.float));
      /* TODO: Add TheShip params */
    }
    playersCompleter.complete(players);
    playersCompleter = null;
  }

  void parseRules(Uint8List bytes) {
    assert(rulesCompleter != null);
    assert(!rulesCompleter.isCompleted);
    final read = ReadBuffer.fromUint8List(bytes.sublist(2));
    final rules = <String, String>{};
    while (read.canReadMore) {
      final key = read.nullTerminatedUtf8String;
      final value = read.nullTerminatedUtf8String;
      rules[key] = value;
    }
    rulesCompleter.complete(rules);
    rulesCompleter = null;
  }

  void onEvent(RawSocketEvent event) {
    if (event != RawSocketEvent.read) {
      return;
    }
    final datagram = socket.receive();
    final data = datagram.data;
    final header = data[4];

    if (header == 0x49) {
      parseInfo(data.sublist(5));
    } else if (header == 0x41) {
      parseChallenge(data.sublist(5));
    } else if (header == 0x44) {
      parsePlayers(data.sublist(5));
    } else if (header == 0x45) {
      parseRules(data.sublist(5));
    } else {
      throw SocketException('Unrecognized header: $header');
    }
  }

  @override
  void close() => socket.close();

}

class QueryPacket {
  static const QueryPacket info = QueryPacket([
    0xff,
    0xff,
    0xff,
    0xff,
    0x54, // T
    0x53, // Source Engine Query
    0x6f,
    0x75,
    0x72,
    0x63,
    0x65,
    0x20,
    0x45,
    0x6e,
    0x67,
    0x69,
    0x6e,
    0x65,
    0x20,
    0x51,
    0x75,
    0x65,
    0x72,
    0x79,
    0x0
  ]);

  static const QueryPacket challenge =
      QueryPacket([0xff, 0xff, 0xff, 0xff, 0x55, 0xff, 0xff, 0xff, 0xff]);

  final List<int> bytes;

  const QueryPacket(this.bytes);

  QueryPacket.players(Uint8List challenge)
      : bytes = [0xff, 0xff, 0xff, 0xff, 0x55, ...challenge];


  QueryPacket.rules(Uint8List challenge)
      : bytes = [0xff, 0xff, 0xff, 0xff, 0x56, ...challenge];
}