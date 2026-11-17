// main.dart
import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:audio_service/audio_service.dart';
import 'package:drift/drift.dart' hide Column;
import 'package:drift_flutter/drift_flutter.dart';
import 'package:flutter/material.dart';

import 'style.dart';

class LibraryDatabase extends GeneratedDatabase {
  static const String _upsertTrackSql =
      'INSERT INTO library_tracks '
      '(id, data_json, audio_bytes, art_bytes, updated_at) '
      'VALUES (?, ?, ?, ?, ?) '
      'ON CONFLICT(id) DO UPDATE SET data_json = excluded.data_json, '
      'audio_bytes = CASE WHEN ? = 1 THEN excluded.audio_bytes '
      'ELSE library_tracks.audio_bytes END, '
      'art_bytes = CASE WHEN ? = 1 THEN excluded.art_bytes '
      'ELSE library_tracks.art_bytes END, '
      'updated_at = excluded.updated_at';

  LibraryDatabase()
    : super(
        driftDatabase(
          name: 'glass_player_library',
          web: DriftWebOptions(
            sqlite3Wasm: Uri.parse('sqlite3.wasm?v=20260823-mime-fix-1'),
            driftWorker: Uri.parse('drift_worker.js?v=20260823-mime-fix-1'),
          ),
        ),
      );

  @override
  int get schemaVersion => librarySchemaVersion;

  @override
  Iterable<TableInfo> get allTables => const [];

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (_) => createSchema(),
    onUpgrade: (_, from, to) => migrateSchema(from, to),
    beforeOpen: (_) => createSchema(),
  );

  Future<void> createSchema() async {
    for (final statement in librarySchemaStatements) {
      await customStatement(statement);
    }
  }

  Future<void> migrateSchema(int from, int to) async {
    for (var version = from + 1; version <= to; version++) {
      for (final statement
          in libraryMigrationStatements[version] ?? const <String>[]) {
        await customStatement(statement);
      }
    }
    await createSchema();
  }

  Future<Map<String, Map<String, dynamic>>> loadTracks() async {
    final rows = await customSelect(
      'SELECT id, data_json, length(art_bytes) AS art_size '
      'FROM library_tracks',
    ).get();
    final result = <String, Map<String, dynamic>>{};
    for (final row in rows) {
      final id = row.data['id']?.toString() ?? '';
      if (id.isEmpty) continue;
      final data = _decodeLibraryMap(
        row.data['data_json']?.toString() ?? '{}',
        recordId: id,
        recordType: 'track',
      );
      if (data == null) continue;
      data['id'] = id;
      data['hasArtwork'] = ((row.data['art_size'] as num?)?.toInt() ?? 0) > 0;
      result[id] = data;
    }
    return result;
  }

  Future<Uint8List?> loadTrackBytes(String id) async {
    final row = await customSelect(
      'SELECT audio_bytes FROM library_tracks WHERE id = ?',
      variables: [Variable<String>(id)],
    ).getSingleOrNull();
    final bytes = _libraryBytes(row?.data['audio_bytes']);
    return bytes != null && bytes.isNotEmpty ? bytes : null;
  }

  Future<Uint8List?> loadTrackArtwork(String id) async {
    final row = await customSelect(
      'SELECT art_bytes FROM library_tracks WHERE id = ?',
      variables: [Variable<String>(id)],
    ).getSingleOrNull();
    final bytes = _libraryBytes(row?.data['art_bytes']);
    return bytes != null && bytes.isNotEmpty ? bytes : null;
  }

  Future<void> putTrack(String id, Map<String, dynamic> track) async {
    await putTracksBatch(<String, Map<String, dynamic>>{id: track});
  }

  Future<void> putTracksBatch(Map<String, Map<String, dynamic>> tracks) async {
    if (tracks.isEmpty) return;
    final updatedAt = DateTime.now().millisecondsSinceEpoch;
    await transaction(() async {
      await batch((batch) {
        for (final entry in tracks.entries) {
          final id = entry.key;
          final data = Map<String, dynamic>.from(entry.value)..['id'] = id;
          final audioWasProvided = data.containsKey('bytes');
          final artWasProvided = data.containsKey('art');
          final audioBytes =
              _libraryBytes(data.remove('bytes')) ?? Uint8List(0);
          final artBytes = _libraryBytes(data.remove('art')) ?? Uint8List(0);
          if (artWasProvided) data['hasArtwork'] = artBytes.isNotEmpty;
          batch.customStatement(_upsertTrackSql, <Object?>[
            id,
            jsonEncode(_encodeLibraryValue(data)),
            audioBytes,
            artBytes,
            updatedAt,
            audioWasProvided ? 1 : 0,
            artWasProvided ? 1 : 0,
          ]);
        }
      });
    });
  }

  Future<Map<String, Map<String, dynamic>>> loadPlaylists() async {
    final rows = await customSelect('SELECT * FROM library_playlists').get();
    final relationRows = await customSelect(
      'SELECT playlist_id, track_id FROM library_playlist_tracks '
      'ORDER BY playlist_id, position',
    ).get();
    final relations = <String, List<String>>{};
    for (final row in relationRows) {
      final playlistId = row.data['playlist_id']?.toString() ?? '';
      final trackId = row.data['track_id']?.toString() ?? '';
      if (playlistId.isEmpty || trackId.isEmpty) continue;
      relations.putIfAbsent(playlistId, () => <String>[]).add(trackId);
    }
    final result = <String, Map<String, dynamic>>{};
    for (final row in rows) {
      final id = row.data['id']?.toString() ?? '';
      if (id.isEmpty) continue;
      final data = _decodeLibraryMap(
        row.data['data_json']?.toString() ?? '{}',
        recordId: id,
        recordType: 'playlist',
      );
      if (data == null) continue;
      data['id'] = id;
      data['trackIds'] = relations[id] ?? <String>[];
      result[id] = data;
    }
    return result;
  }

  Future<void> putPlaylist(String id, Map<String, dynamic> playlist) async {
    final data = Map<String, dynamic>.from(playlist)..['id'] = id;
    final rawTrackIds = data.remove('trackIds');
    final trackIds = rawTrackIds is List
        ? rawTrackIds.map((trackId) => trackId.toString()).toList()
        : <String>[];

    await transaction(() async {
      await customInsert(
        'INSERT INTO library_playlists (id, data_json, updated_at) '
        'VALUES (?, ?, ?) '
        'ON CONFLICT(id) DO UPDATE SET data_json = excluded.data_json, '
        'updated_at = excluded.updated_at',
        variables: [
          Variable<String>(id),
          Variable<String>(jsonEncode(_encodeLibraryValue(data))),
          Variable<int>(DateTime.now().millisecondsSinceEpoch),
        ],
      );
      await customUpdate(
        'DELETE FROM library_playlist_tracks WHERE playlist_id = ?',
        variables: [Variable<String>(id)],
      );
      await batch((batch) {
        for (var index = 0; index < trackIds.length; index++) {
          batch.customStatement(
            'INSERT INTO library_playlist_tracks '
            '(playlist_id, position, track_id) VALUES (?, ?, ?)',
            [id, index, trackIds[index]],
          );
        }
      });
    });
  }

  Future<void> deletePlaylist(String id) async {
    await transaction(() async {
      await customUpdate(
        'DELETE FROM library_playlist_tracks WHERE playlist_id = ?',
        variables: [Variable<String>(id)],
      );
      await customUpdate(
        'DELETE FROM library_playlists WHERE id = ?',
        variables: [Variable<String>(id)],
      );
    });
  }

  Future<List<String>> loadQueue() async {
    final rows = await customSelect(
      'SELECT track_id FROM library_queue ORDER BY position',
    ).get();
    return rows.map((row) => row.data['track_id'].toString()).toList();
  }

  Future<void> replaceQueue(List<String> ids) async {
    await transaction(() async {
      await customStatement('DELETE FROM library_queue');
      await _insertQueueRows(ids);
    });
  }

  Future<void> _insertQueueRows(List<String> ids) async {
    await batch((batch) {
      for (var index = 0; index < ids.length; index++) {
        batch.customStatement(
          'INSERT INTO library_queue (position, track_id) VALUES (?, ?)',
          [index, ids[index]],
        );
      }
    });
  }

  Future<Set<String>> deleteTracksAndReferences(
    Set<String> ids,
    List<String> remainingQueue,
  ) async {
    if (ids.isEmpty) return <String>{};
    const chunkSize = 400;
    final idList = ids.toList();
    return transaction(() async {
      final affectedPlaylists = <String>{};
      for (var offset = 0; offset < idList.length; offset += chunkSize) {
        final end = min(offset + chunkSize, idList.length);
        final chunk = idList.sublist(offset, end);
        final placeholders = List.filled(chunk.length, '?').join(', ');
        final variables = chunk.map((id) => Variable<String>(id)).toList();
        final affectedRows = await customSelect(
          'SELECT DISTINCT playlist_id FROM library_playlist_tracks '
          'WHERE track_id IN ($placeholders)',
          variables: variables,
        ).get();
        affectedPlaylists.addAll(
          affectedRows
              .map((row) => row.data['playlist_id']?.toString() ?? '')
              .where((id) => id.isNotEmpty),
        );
        await customUpdate(
          'DELETE FROM library_playlist_tracks '
          'WHERE track_id IN ($placeholders)',
          variables: variables,
        );
        await customUpdate(
          'DELETE FROM library_tracks WHERE id IN ($placeholders)',
          variables: variables,
        );
      }
      await customStatement('DELETE FROM library_queue');
      await _insertQueueRows(remainingQueue);
      return affectedPlaylists;
    });
  }
}

class DriftLibraryBox {
  DriftLibraryBox.tracks(this.database) : storesTracks = true;
  DriftLibraryBox.playlists(this.database) : storesTracks = false;

  final LibraryDatabase database;
  final bool storesTracks;
  final Map<String, Map<String, dynamic>> _cache = {};

  Iterable<Map<String, dynamic>> get values => _cache.values;
  Iterable<String> get keys => _cache.keys;
  int get length => _cache.length;

  Map<String, dynamic>? get(dynamic key) {
    final value = _cache[key.toString()];
    return value == null ? null : Map<String, dynamic>.from(value);
  }

  Future<Uint8List?> loadTrackBytes(String id) {
    if (!storesTracks) return Future<Uint8List?>.value(null);
    return database.loadTrackBytes(id);
  }

  Future<Uint8List?> loadTrackArtwork(String id) {
    if (!storesTracks) return Future<Uint8List?>.value(null);
    return database.loadTrackArtwork(id);
  }

  Future<void> load() async {
    _cache
      ..clear()
      ..addAll(
        storesTracks
            ? await database.loadTracks()
            : await database.loadPlaylists(),
      );
  }

  Future<void> put(dynamic key, dynamic value) async {
    if (value is! Map) return;
    final id = key.toString();
    final data = Map<String, dynamic>.from(value)..['id'] = id;
    if (storesTracks) {
      await putAll(<String, Map<String, dynamic>>{id: data});
      return;
    } else {
      await database.putPlaylist(id, data);
    }
    _cache[id] = Map<String, dynamic>.from(data);
  }

  Future<void> putAll(Map<String, Map<String, dynamic>> values) async {
    if (!storesTracks || values.isEmpty) return;
    await database.putTracksBatch(values);
    for (final entry in values.entries) {
      final id = entry.key;
      final cachedData = Map<String, dynamic>.from(entry.value)..['id'] = id;
      cachedData.remove('bytes');
      final artworkWasProvided = cachedData.containsKey('art');
      final artwork = _libraryBytes(cachedData.remove('art'));
      if (artworkWasProvided) {
        cachedData['hasArtwork'] = artwork != null && artwork.isNotEmpty;
      }
      if (artwork != null && artwork.isNotEmpty) {
        cacheTrackArtwork(id, artwork);
      }
      _cache[id] = cachedData;
    }
  }

  Future<Set<String>> deleteTracksAndReferences(
    Set<String> ids,
    List<String> remainingQueue,
  ) async {
    if (!storesTracks) return <String>{};
    final affected = await database.deleteTracksAndReferences(
      ids,
      remainingQueue,
    );
    for (final id in ids) {
      _cache.remove(id);
    }
    return affected;
  }

  void removeTrackReferencesFromCache(
    Set<String> trackIds,
    Set<String> affectedPlaylists,
  ) {
    if (storesTracks) return;
    for (final playlistId in affectedPlaylists) {
      final playlist = _cache[playlistId];
      if (playlist == null) continue;
      final ids = (playlist['trackIds'] is List)
          ? (playlist['trackIds'] as List)
                .map((value) => value.toString())
                .where((id) => !trackIds.contains(id))
                .toList()
          : <String>[];
      playlist['trackIds'] = ids;
    }
  }

  Future<void> delete(dynamic key) async {
    final id = key.toString();
    if (storesTracks) {
      final queue = (await database.loadQueue())
        ..removeWhere((item) => item == id);
      await deleteTracksAndReferences(<String>{id}, queue);
    } else {
      await database.deletePlaylist(id);
    }
    _cache.remove(id);
  }
}

LibraryDatabase? _libraryDatabase;

Uint8List? _libraryBytes(dynamic value) {
  if (value is Uint8List) return value;
  if (value is List) {
    try {
      final bytes = <int>[];
      for (final item in value) {
        if (item is! num || item < 0 || item > 255) return null;
        bytes.add(item.toInt());
      }
      return Uint8List.fromList(bytes);
    } catch (error) {
      debugPrint('Invalid library byte value: $error');
    }
  }
  return null;
}

dynamic _encodeLibraryValue(dynamic value) {
  if (value is Uint8List) {
    return {'__type': 'bytes', 'data': base64Encode(value)};
  }
  if (value is Map) {
    return value.map(
      (key, item) => MapEntry(key.toString(), _encodeLibraryValue(item)),
    );
  }
  if (value is List) return value.map(_encodeLibraryValue).toList();
  return value;
}

dynamic _decodeLibraryValue(dynamic value) {
  if (value is Map) {
    final map = Map<String, dynamic>.from(value);
    if (map['__type'] == 'bytes' && map['data'] is String) {
      try {
        return base64Decode(map['data'] as String);
      } catch (error) {
        debugPrint('Invalid base64 value in library data: $error');
        return null;
      }
    }
    return map.map((key, item) => MapEntry(key, _decodeLibraryValue(item)));
  }
  if (value is List) return value.map(_decodeLibraryValue).toList();
  return value;
}

Map<String, dynamic>? _decodeLibraryMap(
  String source, {
  required String recordId,
  required String recordType,
}) {
  try {
    final decoded = jsonDecode(source);
    final restored = _decodeLibraryValue(decoded);
    if (restored is Map) return Map<String, dynamic>.from(restored);
    debugPrint('Invalid $recordType library record $recordId: not a map');
  } catch (error) {
    debugPrint('Invalid $recordType library record $recordId: $error');
  }
  return null;
}

void configureLibraryStorage() {
  libraryStorageInitializer =
      (legacyTracks, legacyPlaylists, legacyQueue) async {
        final database = _libraryDatabase ??= LibraryDatabase();
        await database.createSchema();

        final trackStore = DriftLibraryBox.tracks(database);
        final playlistStore = DriftLibraryBox.playlists(database);
        await trackStore.load();
        await playlistStore.load();

        for (final track in legacyTracks) {
          final id = track['id']?.toString() ?? '';
          if (id.isNotEmpty) await trackStore.put(id, track);
        }
        for (final playlist in legacyPlaylists) {
          final id = playlist['id']?.toString() ?? '';
          if (id.isNotEmpty) await playlistStore.put(id, playlist);
        }

        tracksBox = trackStore;
        playlistsBox = playlistStore;
        var storedQueue = await database.loadQueue();
        if (storedQueue.isEmpty && legacyQueue.isNotEmpty) {
          await database.replaceQueue(legacyQueue);
          storedQueue = List<String>.from(legacyQueue);
        }
        queueIds.value = storedQueue;
        libraryQueueSaver = database.replaceQueue;
      };
}

Future<void> _bootstrapApp() async {
  libraryStatus.value = 'initializing';
  libraryErrorMessage.value = null;
  var libraryReady = false;
  try {
    await ensureBoxes();
    libraryReady = true;
    libraryStatus.value = 'ready';
  } catch (error, stackTrace) {
    libraryStatus.value = 'error';
    libraryErrorMessage.value = error.toString();
    debugPrint('Library initialization failed: $error');
    debugPrintStack(stackTrace: stackTrace);
  }

  if (libraryReady) {
    unawaited(_refreshLibraryInBackground());
  }
}

Future<void> _initializeAudioSystem() async {
  if (audioHandler != null) return;
  try {
    await ensureAudio();
    audioHandler = await AudioService.init(
      builder: () => AppAudioHandler(),
      config: AudioServiceConfig(
        androidNotificationChannelId: 'glass.player.playback',
        androidNotificationChannelName: 'Playback',
        androidStopForegroundOnPause: true,
        androidNotificationOngoing: false,
        androidResumeOnClick: true,
      ),
    );
  } catch (error, stackTrace) {
    audioHandler = null;
    debugPrint('Audio system initialization failed: $error');
    debugPrintStack(stackTrace: stackTrace);
    rethrow;
  }
}

Future<void> _refreshLibraryInBackground() async {
  await Future<void>.delayed(
    Duration(milliseconds: startupPerformance['backgroundWorkDelayMs'] as int),
  );
  await runAutomaticLibraryMaintenance();
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  configureLibraryStorage();
  libraryRetryAction = () => unawaited(_bootstrapApp());
  audioServiceInitializer = _initializeAudioSystem;
  try {
    await initializePreferences();
  } catch (error, stackTrace) {
    debugPrint('Preferences initialization failed: $error');
    debugPrintStack(stackTrace: stackTrace);
  }
  try {
    await ensureAudioService();
  } catch (_) {
    // Playback retries lazily on the first user action.
  }
  runApp(const App());

  WidgetsBinding.instance.addPostFrameCallback((_) async {
    await _bootstrapApp();
  });
}

class App extends StatelessWidget {
  const App({super.key});
  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder2<double, String>(
      first: textScale,
      second: themeId,
      builder: (context, scale, theme, _) {
        return MaterialApp(
          debugShowCheckedModeBanner: false,
          title: texts['app'] ?? 'Glass Player',
          theme: appMaterialTheme(theme),
          builder: (context, child) {
            final media = MediaQuery.of(context);
            return MediaQuery(
              data: media.copyWith(textScaler: TextScaler.linear(scale)),
              child: child ?? const SizedBox.shrink(),
            );
          },
          home: const HomePage(),
        );
      },
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      backgroundMetadataWorkEnabled = true;
      scheduleAutomaticLibraryScan();
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      backgroundMetadataWorkEnabled = false;
    }
  }

  @override
  void dispose() {
    backgroundMetadataWorkEnabled = false;
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<double>(
      valueListenable: uiScale,
      builder: (context, scale, _) {
        final el = elOf(context);

        return Scaffold(
          drawer: ValueListenableBuilder<String>(
            valueListenable: themeId,
            builder: (_, __, ___) => appDrawer(el),
          ),
          backgroundColor: Colors.transparent,
          body: ValueListenableBuilder<String>(
            valueListenable: backgroundId,
            builder: (context, bgId, _) {
              return BackdropGroup(
                child: Stack(
                  children: [
                    Positioned.fill(child: AnimatedAppBackground(id: bgId)),
                    SafeArea(
                      child: AnimatedSwitcher(
                        duration: Duration(
                          milliseconds:
                              responsiveLayout['themeTransitionMs'] as int,
                        ),
                        child: KeyedSubtree(
                          key: ValueKey(themeId.value),
                          child: ValueListenableBuilder<String>(
                            valueListenable: currentPage,
                            builder: (context, page, _) {
                              if (page == 'now') {
                                return nowPlayingView(el);
                              }

                              Widget pageColumn({required bool showMini}) {
                                return Column(
                                  children: [
                                    topBar(context, el),
                                    scanStatusBar(el),
                                    SizedBox(height: el),
                                    Expanded(
                                      child: glass(switch (page) {
                                        'playlists' => playlistsView(el),
                                        'playlist' => playlistView(el),
                                        'queue' => queueView(el),
                                        'settings' => scrollY(settingsView(el)),
                                        _ => libraryView(el),
                                      }, el),
                                    ),
                                    if (showMini) ...[
                                      SizedBox(height: el * .6),
                                      ValueListenableBuilder<String?>(
                                        valueListenable: currentId,
                                        builder: (_, id, __) {
                                          if (id == null) {
                                            return const SizedBox.shrink();
                                          }
                                          return glass(
                                            InkWell(
                                              onTap: () =>
                                                  openNowPlayingForContext(
                                                    context,
                                                  ),
                                              child: miniPlayer(el),
                                            ),
                                            el,
                                          );
                                        },
                                      ),
                                    ],
                                  ],
                                );
                              }

                              final wide =
                                  page == 'home' &&
                                  usesWideSplitLayout(context);
                              if (!wide) {
                                return Padding(
                                  padding: EdgeInsets.all(el * 1.2),
                                  child: pageColumn(showMini: true),
                                );
                              }

                              return ValueListenableBuilder2<String?, bool>(
                                first: currentId,
                                second: widePlayerPanelVisible,
                                builder: (context, id, playerVisible, _) {
                                  final showPlayer =
                                      id != null && playerVisible;
                                  if (!showPlayer) {
                                    return Padding(
                                      padding: EdgeInsets.all(el * 1.2),
                                      child: pageColumn(showMini: true),
                                    );
                                  }

                                  final gap =
                                      responsiveLayout['widePaneGap'] as double;
                                  final libraryShare =
                                      responsiveLayout['wideLibraryShare']
                                          as double;
                                  final playerShare =
                                      responsiveLayout['widePlayerShare']
                                          as double;
                                  return Padding(
                                    padding: EdgeInsets.all(el * 1.2),
                                    child: LayoutBuilder(
                                      builder: (context, constraints) {
                                        final paneWidth = max(
                                          0.0,
                                          constraints.maxWidth - gap,
                                        );
                                        return Row(
                                          children: [
                                            SizedBox(
                                              width: paneWidth * libraryShare,
                                              child: pageColumn(
                                                showMini: false,
                                              ),
                                            ),
                                            SizedBox(width: gap),
                                            SizedBox(
                                              width: paneWidth * playerShare,
                                              child: glass(
                                                nowPlayingView(
                                                  el,
                                                  embedded: true,
                                                  onClose: closeWidePlayerPanel,
                                                  onExpand:
                                                      expandWidePlayerPanel,
                                                ),
                                                el,
                                              ),
                                            ),
                                          ],
                                        );
                                      },
                                    ),
                                  );
                                },
                              );
                            },
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        );
      },
    );
  }
}
