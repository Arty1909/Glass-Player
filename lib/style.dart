// style.dart
import 'dart:async';
import 'dart:collection';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui';
import 'package:dart_tags/dart_tags.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:path/path.dart' as p;
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart'
    show kIsWeb, defaultTargetPlatform, TargetPlatform, ValueListenable;
import 'package:flutter_media_metadata/flutter_media_metadata.dart';
import 'package:universal_io/io.dart' as io;
import 'package:flip_card/flip_card.dart';
import 'package:audio_service/audio_service.dart';

BaseAudioHandler? audioHandler;

final String defaultArtPath = 'assets/images/default_cover.png';
final List<String> audioExt = ['mp3', 'm4a', 'aac', 'wav', 'flac', 'ogg'];
final Map<String, dynamic> startupPerformance = {'backgroundWorkDelayMs': 450};

final Map<String, dynamic> webMediaTransferConfig = {
  'preferReadStream': true,
  'readSequential': true,
  'metadataTimeoutMs': 6000,
  'maxCachedTracks': 2,
  'signatureSampleBytes': 65536,
};

final Map<String, dynamic> libraryPerformance = {
  'resumeScanDebounceMs': 1500,
  'minimumScanIntervalMs': 120000,
  'artworkBatchSize': 12,
  'artworkCacheSize': 48,
  'artworkCacheMaxBytes': 67108864,
  'artworkUiNotifyDebounceMs': 80,
  'artworkDecodeMaxPx': 2048,
  'scanBatchSize': 40,
  'eventLoopYieldMs': 1,
  'thumbnailDecodeScale': 2.0,
  'lastSuccessfulScanPreference': 'lastSuccessfulLibraryScanAt',
};

final Map<String, dynamic> responsiveLayout = {
  'compactWidth': 640.0,
  'mediumWidth': 1008.0,
  'desktopWidth': 1008.0,
  'wideSplitBreakpoint': 1180.0,
  'wideLibraryShare': 0.38,
  'widePlayerShare': 0.62,
  'widePaneGap': 20.0,
  'maxPlayerContentWidth': 1120.0,
  'maxPlayerDetailsWidth': 520.0,
  'compactPlayerCover': 360.0,
  'mediumPlayerCover': 420.0,
  'desktopPlayerCover': 420.0,
  'desktopCoverShare': 0.43,
  'playerDesktopGap': 48.0,
  'compactScreenPadding': 16.0,
  'mediumScreenPadding': 24.0,
  'desktopScreenPadding': 32.0,
  'settingsMaxWidth': 720.0,
  'searchMaxWidth': 420.0,
  'searchCompactMaxWidth': 220.0,
  'searchHeightFactor': 2.6,
  'searchHorizontalPaddingFactor': 0.8,
  'themeTransitionMs': 650,
  'backgroundAnimationMs': 10000,
  'miniPlayerCompactWidth': 520.0,
  'sheetMaxHeightFactor': 0.78,
  'compactPadding': 0.75,
  'regularPadding': 1.2,
  'widePadding': 1.6,
};

final Map<String, dynamic> uiScaleSettings = {
  'min': 0.80,
  'max': 1.40,
  'divisions': 12,
};

final List<String> playbackModes = [
  'order',
  'repeatAll',
  'repeatOne',
  'shuffle',
];
final Map<String, IconData> playbackModeIcons = {
  'order': Icons.format_list_bulleted_rounded,
  'repeatAll': Icons.repeat_rounded,
  'repeatOne': Icons.repeat_one_rounded,
  'shuffle': Icons.shuffle_rounded,
};
final List<String> sortOptionIds = [
  'byName',
  'byArtist',
  'byDate',
  'byDuration',
];
final List<Map<String, String>> navigationMenu = [
  {'id': 'home', 'icon': 'playlist', 'title': 'library'},
  {'id': 'playlists', 'icon': 'playlist', 'title': 'playlists'},
  {'id': 'queue', 'icon': 'queue', 'title': 'queue'},
  {'id': 'settings', 'icon': 'settings', 'title': 'settings'},
];
final Map<String, String> pageTitleTextKeys = {
  'home': 'home',
  'playlists': 'playlists',
  'queue': 'queue',
  'settings': 'settings',
};

// All automatic music scan locations are stored in arrays.
final Map<TargetPlatform, List<String>> automaticMusicFolders = {
  TargetPlatform.windows: ['Music', 'Downloads'],
  TargetPlatform.linux: ['Music', 'Downloads'],
  TargetPlatform.macOS: ['Music', 'Downloads'],
  TargetPlatform.android: <String>[],
  TargetPlatform.iOS: <String>[],
  TargetPlatform.fuchsia: <String>[],
};
final List<String> windowsMediaDriveLetters = [
  'D',
  'E',
  'F',
  'G',
  'H',
  'I',
  'J',
  'K',
  'L',
  'M',
  'N',
  'O',
  'P',
  'Q',
  'R',
  'S',
  'T',
  'U',
  'V',
  'W',
  'X',
  'Y',
  'Z',
];
final List<String> unixExternalMediaFolders = ['media', 'run/media'];
final List<String> macExternalMediaFolders = ['/Volumes'];
const MethodChannel deviceMediaChannel = MethodChannel(
  'glass.player/device_media',
);
final Set<String> _androidArtworkRequests = <String>{};
dynamic tracksBox;
dynamic playlistsBox;
Box? prefsBox;

Future<void> Function(
  List<Map<String, dynamic>> legacyTracks,
  List<Map<String, dynamic>> legacyPlaylists,
  List<String> legacyQueue,
)?
libraryStorageInitializer;
Future<void> Function(List<String> ids)? libraryQueueSaver;
Future<void> libraryQueueWriteChain = Future<void>.value();
Future<void> Function()? audioServiceInitializer;
Future<void>? _audioServiceInitialization;
VoidCallback? libraryRetryAction;

final libraryStatus = ValueNotifier<String>('initializing');
final libraryErrorMessage = ValueNotifier<String?>(null);
final scanErrorMessage = ValueNotifier<String?>(null);
final libraryOperationErrorMessage = ValueNotifier<String?>(null);
bool backgroundMetadataWorkEnabled = true;

final List<String> librarySchemaStatements = [
  '''CREATE TABLE IF NOT EXISTS library_tracks (
    id TEXT PRIMARY KEY,
    data_json TEXT NOT NULL DEFAULT '{}',
    audio_bytes BLOB,
    art_bytes BLOB,
    updated_at INTEGER NOT NULL
  )''',
  '''CREATE TABLE IF NOT EXISTS library_playlists (
    id TEXT PRIMARY KEY,
    data_json TEXT NOT NULL DEFAULT '{}',
    updated_at INTEGER NOT NULL
  )''',
  '''CREATE TABLE IF NOT EXISTS library_playlist_tracks (
    playlist_id TEXT NOT NULL,
    position INTEGER NOT NULL,
    track_id TEXT NOT NULL,
    PRIMARY KEY (playlist_id, position)
  )''',
  'CREATE INDEX IF NOT EXISTS idx_playlist_tracks_track '
      'ON library_playlist_tracks(track_id)',
  '''CREATE TABLE IF NOT EXISTS library_queue (
    position INTEGER PRIMARY KEY,
    track_id TEXT NOT NULL
  )''',
  'CREATE INDEX IF NOT EXISTS idx_library_queue_track '
      'ON library_queue(track_id)',
];
const int librarySchemaVersion = 2;
final Map<int, List<String>> libraryMigrationStatements = {
  2: [
    'CREATE INDEX IF NOT EXISTS idx_playlist_tracks_track '
        'ON library_playlist_tracks(track_id)',
    'CREATE INDEX IF NOT EXISTS idx_library_queue_track '
        'ON library_queue(track_id)',
  ],
};
final tracksList = ValueNotifier<List<Map<String, dynamic>>>([]);
final isScanningLibrary = ValueNotifier<bool>(false);
bool automaticScanInProgress = false;
DateTime? _lastAutomaticScanAt;
Timer? _automaticScanDebounce;
String currentSort = 'byDate';
final currentPage = ValueNotifier<String>('home');
final List<String> pageHistory = [];
final widePlayerPanelVisible = ValueNotifier<bool>(true);

bool usesWideSplitLayout(BuildContext context) =>
    MediaQuery.sizeOf(context).width >=
    (responsiveLayout['wideSplitBreakpoint'] as double);

void openNowPlayingForContext(BuildContext context) {
  if (usesWideSplitLayout(context)) {
    widePlayerPanelVisible.value = true;
    if (currentPage.value != 'home') setPage('home');
    return;
  }
  setPage('now');
}

void playSelectedTrack(BuildContext context, String id, {int? queuePosition}) {
  openNowPlayingForContext(context);
  unawaited(playById(id, queuePosition: queuePosition));
}

void closeWidePlayerPanel() {
  widePlayerPanelVisible.value = false;
}

void expandWidePlayerPanel() {
  widePlayerPanelVisible.value = true;
  setPage('now');
}

void _leaveTransientLibraryModes(String from, String to) {
  if (from == 'home' && to != 'home') {
    isSearchMode.value = false;
    clearSearch();
    _cancelSelectionMode();
  }
}

void setPage(String id, {bool remember = true}) {
  final previous = currentPage.value;
  if (previous == id) return;
  _leaveTransientLibraryModes(previous, id);
  if (remember && (pageHistory.isEmpty || pageHistory.last != previous)) {
    pageHistory.add(previous);
  }
  currentPage.value = id;
}

void goBackPage() {
  if (pageHistory.isEmpty) {
    _leaveTransientLibraryModes(currentPage.value, 'home');
    currentPage.value = 'home';
    return;
  }
  final next = pageHistory.removeLast();
  _leaveTransientLibraryModes(currentPage.value, next);
  currentPage.value = next;
}

void replacePage(String id) {
  _leaveTransientLibraryModes(currentPage.value, id);
  currentPage.value = id;
}

final currentPlaylistId = ValueNotifier<String?>(null);
void openPlaylist(String id) {
  currentPlaylistId.value = id;
  setPage('playlist');
}

final isSearchMode = ValueNotifier<bool>(false);

final isSelectionMode = ValueNotifier<bool>(false);
final selectedTrackIds = ValueNotifier<Set<String>>({});

final playbackMode = ValueNotifier<String>('order');
void setPlayMode(String m) {
  if (!playbackModes.contains(m)) return;
  playbackMode.value = m;
  prefsBox?.put('playbackMode', m);
  final handler = audioHandler;
  if (handler is AppAudioHandler) handler.syncPlaybackMode();
}

final audio = AudioPlayer();
bool audioInited = false;
Future<void>? _audioInitialization;
Future<void> _playbackCommandChain = Future<void>.value();
int _playbackRequestGeneration = 0;
int _activeQueuePosition = -1;
bool _notificationPermissionRequestedThisSession = false;

final isPlaying = ValueNotifier<bool>(false);
final currentId = RefreshableValueNotifier<String?>(null);
final positionMs = ValueNotifier<int>(0);
final durationMs = ValueNotifier<int>(0);
final playlistsList = ValueNotifier<List<Map<String, dynamic>>>([]);

class RefreshableValueNotifier<T> extends ValueNotifier<T> {
  RefreshableValueNotifier(super.value);
  void refresh() => notifyListeners();
}

final backgroundId = RefreshableValueNotifier<String>('sky');

final Map<String, Uint8List> webBytes = {};
final LinkedHashMap<String, Uint8List> artworkBytesCache = LinkedHashMap();
final Set<String> _artworkLoads = <String>{};
final Set<String> _oversizedArtworkIds = <String>{};
int _artworkCacheBytes = 0;
Timer? _artworkUiNotifyDebounce;

void _scheduleArtworkUiNotify() {
  _artworkUiNotifyDebounce?.cancel();
  _artworkUiNotifyDebounce = Timer(
    Duration(
      milliseconds: libraryPerformance['artworkUiNotifyDebounceMs'] as int,
    ),
    () => tracksList.value = List<Map<String, dynamic>>.from(tracksList.value),
  );
}

void removeCachedTrackArtwork(String id) {
  final removed = artworkBytesCache.remove(id);
  if (removed != null) _artworkCacheBytes -= removed.lengthInBytes;
  _oversizedArtworkIds.remove(id);
}

void cacheTrackArtwork(String id, Uint8List bytes, {bool notify = false}) {
  if (id.isEmpty || bytes.isEmpty) return;
  removeCachedTrackArtwork(id);
  final byteLimit = libraryPerformance['artworkCacheMaxBytes'] as int;
  if (bytes.lengthInBytes > byteLimit) {
    _oversizedArtworkIds.add(id);
    if (notify) _scheduleArtworkUiNotify();
    return;
  }
  artworkBytesCache
    ..remove(id)
    ..[id] = bytes;
  _artworkCacheBytes += bytes.lengthInBytes;
  final itemLimit = libraryPerformance['artworkCacheSize'] as int;
  while (artworkBytesCache.length > itemLimit ||
      _artworkCacheBytes > byteLimit) {
    String? candidate;
    for (final key in artworkBytesCache.keys) {
      if (key != id && key != currentId.value) {
        candidate = key;
        break;
      }
    }
    final removed = artworkBytesCache.remove(
      candidate ?? artworkBytesCache.keys.first,
    );
    if (removed != null) _artworkCacheBytes -= removed.lengthInBytes;
  }
  if (notify) _scheduleArtworkUiNotify();
}

Future<void> _ensureTrackArtworkLoaded(String id) async {
  if (id.isEmpty ||
      artworkBytesCache.containsKey(id) ||
      _oversizedArtworkIds.contains(id) ||
      !_artworkLoads.add(id)) {
    return;
  }
  try {
    final bytes = await tracksBox?.loadTrackArtwork(id);
    if (bytes is Uint8List && bytes.isNotEmpty) {
      cacheTrackArtwork(id, bytes, notify: true);
      if (currentId.value == id) currentId.refresh();
    }
  } catch (error) {
    debugPrint('Artwork load failed for $id: $error');
  } finally {
    _artworkLoads.remove(id);
  }
}

void _cacheWebTrackBytes(String id, Uint8List bytes) {
  webBytes.remove(id);
  webBytes[id] = bytes;
  final limit = webMediaTransferConfig['maxCachedTracks'] as int;
  while (webBytes.length > limit) {
    String? candidate;
    for (final key in webBytes.keys) {
      if (key != id && key != currentId.value) {
        candidate = key;
        break;
      }
    }
    candidate ??= webBytes.keys.first;
    webBytes.remove(candidate);
  }
}

final searchQuery = ValueNotifier<String>('');
final searchController = TextEditingController();
void clearSearch() {
  searchController.clear();
  searchQuery.value = '';
}

/* ========= data ========= */

final Map<String, String> texts = {
  'app': 'Glass Player',
  'home': 'Listen now',
  'library': 'Library',
  'playlists': 'Playlists',
  'queue': 'Queue',
  'nowPlaying': 'Now playing',
  'settings': 'Settings',
  'createPlaylist': 'Create playlist',
  'importFiles': 'Import files',
  'sort': 'Sort',
  'search': 'Search',
  'byName': 'By name',
  'byArtist': 'By artist',
  'byDate': 'Recently added',
  'byDuration': 'By duration',
  'noTracks': 'No tracks yet',
  'emptyLibraryAutoCta':
      'Music from this device will appear after automatic scanning.',
  'emptyLibraryManualCta': 'Choose audio files to add music to the library.',
  'trackSample': 'Psychedelic',
  'artistSample': 'D3m0n X Diablo',
  'unknown': 'Unknown',
  'addToPlaylist': 'Add to playlist',
  'newPlaylist': 'New playlist',
  'playlistName': 'Playlist name',
  'create': 'Create',
  'cancel': 'Cancel',
  'close': 'Close',
  'authorMark': 'Author mark',
  'authorSignature': 'This app was created by Arty 💜',
  'emptyPlaylists': 'No playlists yet',
  'playNext': 'Play next',
  'addToQueue': 'Add to queue',
  'removeFromQueue': 'Remove from queue',
  'clearQueue': 'Clear queue',
  'emptyQueue': 'Queue is empty',
  'playAll': 'Play all',
  'addAllToQueue': 'Add all to queue',
  'rename': 'Rename',
  'delete': 'Delete',
  'confirmDelete': 'Delete this playlist?',
  'deleteFromLibrary': 'Delete from library',
  'trackInformation': 'Track information',
  'playing': 'Playing',
  'paused': 'Paused',
  'confirmDeleteTrack':
      'Delete this track from library? It will be removed from all playlists and the queue.',
  'noResults': 'No results',
  'save': 'Save',
  'themes': 'Themes',
  'sizes': 'Sizes',
  'uiScale': 'Overall UI size',
  'textSize': 'Text size',
  'textSizeHint': 'Changes text without resizing buttons and artwork',
  'lyricsAnimation': 'Lyrics animation',
  'lyricsAnimationOff': 'Off',
  'lyricsAnimationSmooth': 'Smooth',
  'lyricsAnimationSynced': 'Synced',
  'lyricsTiming': 'Lyrics timing',
  'lyricsTimingValue': '{value} sec',
  'reset': 'Reset',
  'expand': 'Expand',
  'editLyrics': 'Edit lyrics',
  'addLyrics': 'Add lyrics',
  'noLyrics': 'No lyrics found for this track.',
  'small': 'Small',
  'normal': 'Normal',
  'large': 'Large',
  'xl': 'XL',
  'back': 'Back',
  'backgrounds': 'Backgrounds',
  'selectAll': 'Select All',
  'selectTracks': 'Select Tracks',
  'selectedTemplate': '{count} selected',
  'bulkDeleteTemplate': 'Delete {count} tracks from library?',
  'titleLabel': 'Title',
  'artistLabel': 'Artist',
  'albumLabel': 'Album',
  'durationLabel': 'Duration',
  'formatLabel': 'Format',
  'fileNameLabel': 'File name',
  'locationLabel': 'Location',
  'sizeLabel': 'Size',
  'addedLabel': 'Added',
  'coverArtLabel': 'Cover art',
  'yes': 'Yes',
  'no': 'No',
  'notAvailable': 'N/A',
  'initializingLibrary': 'Opening music library…',
  'libraryOpenFailed': 'Could not open the music library.',
  'retry': 'Retry',
  'scanningLibrary': 'Scanning device music…',
  'scanFailed': 'Could not scan device music. Check media access and retry.',
  'webStorageFailed':
      'A selected file could not be saved. Browser storage may be full.',
  'webImportPartial': 'Some files could not be imported.',
  'queueSaveFailed': 'Could not save the queue',
  'deleteTracksFailed': 'Could not delete tracks',
  'emptyPlaylistName': 'Playlist name cannot be empty.',
};

String textTemplate(String key, Map<String, Object> values) {
  var result = texts[key] ?? '';
  for (final entry in values.entries) {
    result = result.replaceAll('{${entry.key}}', entry.value.toString());
  }
  return result;
}

final Map<String, Color> colors = {
  'bg1': const Color(0xFFBFD9FF),
  'bg2': const Color(0xFF9FC3FF),
  'glass': const Color(0x44FFFFFF), // более прозрачное стекло
  'glassBorder': const Color(0x22FFFFFF),
  'text': Colors.white,
  'textDim': Colors.white70,
  'accent': const Color(0xFF7A4DFF),
  'accentDim': const Color(0x337A4DFF),
  'chipBackground': const Color(0xCC35364A),
  'chipSelected': const Color(0xE25E43D0),
  'chipText': Colors.white,
  'chipSelectedText': Colors.white,
  'chipBorder': const Color(0x55FFFFFF),
  'shadow': const Color(0x33000000),
};

final Map<String, double> sizes = {
  'minEl': 8,
  'maxEl': 24,
  'blur': 20,
  'radiusK': 2.4,
};

final Map<String, double> playerTypography = {
  'desktopHeader': 22.0,
  'desktopTitle': 32.0,
  'desktopArtist': 18.0,
  'desktopTime': 14.0,
  'desktopSettingsTitle': 26.0,
  'desktopSectionTitle': 20.0,
  'compactHeaderFactor': 1.2,
  'compactTitleFactor': 1.6,
  'compactArtistFactor': 1.05,
  'compactTimeFactor': 0.9,
};

final Map<String, dynamic> authorMarkPresentation = {
  'color': const Color(0xFFAB84CE),
  'iconSize': 22.0,
  'dialogIconSize': 48.0,
  'tapsToReveal': 19,
  'tapResetMs': 3000,
};

final Map<String, dynamic> lyricPresentation = {
  'animationMs': 280,
  'scrollAnimationMs': 420,
  'manualScrollResumeDelayMs': 2200,
  'entryLineDurationMs': 400,
  'entryLineStaggerMs': 45,
  'entrySlideOffset': 0.055,
  'smoothScrollTickerMs': 1000,
  'smoothScrollFollowFactor': 0.10,
  'smoothScrollSnapDistance': 0.35,
  'activeScale': 1.06,
  'inactiveOpacity': 0.40,
  'lineHeight': 1.55,
  'linePadding': 8.0,
  'baseFontFactor': 1.05,
  'scrollAlignment': 0.45,
  'offsetMinMs': -5000,
  'offsetMaxMs': 5000,
  'offsetStepMs': 100,
  'modes': const <String>['off', 'smooth', 'synced'],
  'modeTextKeys': const <String, String>{
    'off': 'lyricsAnimationOff',
    'smooth': 'lyricsAnimationSmooth',
    'synced': 'lyricsAnimationSynced',
  },
};

List<String> get lyricsAnimationModes =>
    (lyricPresentation['modes'] as List).cast<String>();

Map<String, String> get lyricsAnimationModeTextKeys =>
    (lyricPresentation['modeTextKeys'] as Map).cast<String, String>();

final Map<String, dynamic> musicVisualizerSettings = {
  'tickerDurationMs': 1000,
  'heightFactor': 2.4,
  'minimumHeightFactor': 0.16,
  'speed': 5.2,
  'secondarySpeed': 2.7,
  'cornerRadiusFactor': 0.22,
  'horizontalPaddingFactor': 0.65,
  'verticalPaddingFactor': 0.35,
};

final List<double> musicVisualizerBarPattern = [
  0.42,
  0.68,
  0.88,
  0.58,
  0.96,
  0.74,
  0.50,
  0.82,
  0.62,
  0.92,
  0.55,
  0.76,
  0.46,
  0.86,
  0.66,
  0.98,
  0.60,
  0.80,
];

final Map<String, IconData> iconsMap = {
  'menu': Icons.menu_rounded,
  'more': Icons.more_horiz_rounded,
  'search': Icons.search_rounded,
  'add': Icons.add_rounded,
  'playlist': Icons.queue_music_rounded,
  'queue': Icons.queue_play_next_rounded,
  'settings': Icons.settings_rounded,
  'sort': Icons.sort_rounded,
  'play': Icons.play_arrow_rounded,
  'pause': Icons.pause_rounded,
  'prev': Icons.skip_previous_rounded,
  'next': Icons.skip_next_rounded,
  'drag': Icons.drag_indicator_rounded,
  'shuffle': Icons.shuffle_rounded,
  'repeat': Icons.repeat_rounded,
  'repeatOne': Icons.repeat_one_rounded,
  'order': Icons.format_list_bulleted_rounded,
  'back': Icons.arrow_back_rounded,
  'close': Icons.close_rounded,
  'info': Icons.info_outline_rounded,
  'theme': Icons.color_lens_rounded,
  'size': Icons.straighten_rounded,
  'textSize': Icons.text_fields_rounded,
  'karaoke': Icons.mic_rounded,
  'karaokeOff': Icons.mic_none_rounded,
  'delete': Icons.delete_outline_rounded,
  'selected': Icons.check_circle_rounded,
  'select': Icons.radio_button_unchecked_rounded,
  'selectTracks': Icons.check_box_outline_blank_rounded,
  'upload': Icons.file_upload_rounded,
  'playlistAdd': Icons.playlist_add_rounded,
  'playlistPlay': Icons.playlist_play_rounded,
  'playFilled': Icons.play_circle_fill_rounded,
  'remove': Icons.remove_circle_outline,
  'rename': Icons.drive_file_rename_outline_rounded,
};

Widget scrollY(Widget child) {
  return LayoutBuilder(
    builder: (ctx, c) => SingleChildScrollView(
      padding: EdgeInsets.zero,
      physics: const ClampingScrollPhysics(),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          minHeight: c.maxHeight,
        ), // заполняем доступную высоту
        child: child,
      ),
    ),
  );
}

/* ========= registries ========= */

typedef IconButtonBuilder =
    Widget Function(IconData icon, VoidCallback onTap, double el);

final Map<String, IconButtonBuilder> iconButtons = {
  'circle': (icon, onTap, el) => Material(
    type: MaterialType.transparency,
    child: InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(el * (sizes['radiusK'] ?? 2.4)),
      child: Container(
        width: el * 2.6,
        height: el * 2.6,
        decoration: BoxDecoration(
          color: colors['glass'],
          borderRadius: BorderRadius.circular(el * (sizes['radiusK'] ?? 2.4)),
          border: Border.all(color: colors['glassBorder']!, width: 1),
          boxShadow: [
            BoxShadow(
              color: colors['shadow']!,
              blurRadius: el,
              offset: Offset(0, el * .3),
            ),
          ],
        ),
        alignment: Alignment.center,
        child: Icon(icon, size: el * 1.6, color: colors['text']),
      ),
    ),
  ),
};

final Map<String, dynamic> buttons = {
  'icon': (IconData icon, VoidCallback onTap, double el) =>
      iconButtons['circle']!(icon, onTap, el),

  'pill': (String text, IconData icon, VoidCallback onTap, double el) =>
      Material(
        type: MaterialType.transparency,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(el * (sizes['radiusK'] ?? 2.4)),
          child: Container(
            padding: EdgeInsets.symmetric(
              horizontal: el * 1.2,
              vertical: el * 1.0,
            ),
            decoration: BoxDecoration(
              color: colors['glass'],
              borderRadius: BorderRadius.circular(
                el * (sizes['radiusK'] ?? 2.4),
              ),
              border: Border.all(color: colors['glassBorder']!, width: 1),
              boxShadow: [
                BoxShadow(
                  color: colors['shadow']!,
                  blurRadius: el,
                  offset: Offset(0, el * .3),
                ),
              ],
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: el * 1.4, color: colors['text']),
                SizedBox(width: el * .6),
                Text(
                  text,
                  style: TextStyle(color: colors['text'], fontSize: el * 1.05),
                ),
              ],
            ),
          ),
        ),
      ),
};

/* ========= helpers ========= */

double elOf(BuildContext ctx) {
  final s = MediaQuery.of(ctx).size;
  final base = min(s.width, s.height) / 24;
  final mn = sizes['minEl'] ?? 8.0, mx = sizes['maxEl'] ?? 28.0;
  final scaled = base * (uiScale.value);
  return scaled.clamp(mn, mx);
}

EdgeInsets adaptiveScreenPadding(BuildContext ctx, double el) {
  final width = MediaQuery.sizeOf(ctx).width;
  final factor = width < (responsiveLayout['compactWidth'] as double)
      ? responsiveLayout['compactPadding'] as double
      : width < (responsiveLayout['mediumWidth'] as double)
      ? responsiveLayout['regularPadding'] as double
      : responsiveLayout['widePadding'] as double;
  return EdgeInsets.all(el * factor);
}

extension StringIfEmpty on String {
  String ifEmpty(String fallback) => trim().isEmpty ? fallback : this;
}

String formatMs(int ms) {
  final s = ms ~/ 1000;
  final m = s ~/ 60;
  final r = s % 60;
  return '$m:${r.toString().padLeft(2, '0')}';
}

double pageTitleFontSize(BuildContext ctx, double el) {
  final desktop =
      MediaQuery.sizeOf(ctx).width >=
      (responsiveLayout['desktopWidth'] as double);
  return desktop
      ? playerTypography['desktopSettingsTitle']!
      : el * playerTypography['compactTitleFactor']!;
}

BoxDecoration appBackground() => BoxDecoration(
  gradient: LinearGradient(
    colors: [colors['bg1']!, colors['bg2']!],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  ),
);

Widget glass(Widget child, double el) {
  final r = el * (sizes['radiusK'] ?? 2.4);
  return ClipRRect(
    borderRadius: BorderRadius.circular(r),
    child: BackdropFilter.grouped(
      filter: ImageFilter.blur(
        sigmaX: sizes['blur'] ?? 20,
        sigmaY: sizes['blur'] ?? 20,
      ),
      child: Material(
        type: MaterialType.transparency,
        child: Container(
          padding: EdgeInsets.all(el * 1.2),
          decoration: BoxDecoration(
            color: colors['glass'],
            borderRadius: BorderRadius.circular(r),
            border: Border.all(color: colors['glassBorder']!, width: 1),
            boxShadow: [
              BoxShadow(
                color: colors['shadow']!,
                blurRadius: el * 1.4,
                offset: Offset(0, el * .4),
              ),
            ],
          ),
          child: Material(type: MaterialType.transparency, child: child),
        ),
      ),
    ),
  );
}

/* ========= reusable UI ========= */

Drawer appDrawer(double el) {
  return Drawer(
    backgroundColor: Colors.transparent,
    child: SafeArea(
      child: Padding(
        padding: EdgeInsets.all(el * 1.2),
        child: glass(
          ListView.separated(
            itemCount: navigationMenu.length,
            separatorBuilder: (_, __) => SizedBox(height: el * .35),
            itemBuilder: (ctx, i) => ListTile(
              leading: Icon(
                iconsMap[navigationMenu[i]['icon']]!,
                color: colors['text'],
              ),
              title: Text(
                texts[navigationMenu[i]['title']]!,
                style: TextStyle(color: colors['text']),
              ),
              onTap: () {
                setPage(navigationMenu[i]['id']!);
                Navigator.pop(ctx);
              },
            ),
          ),
          el,
        ),
      ),
    ),
  );
}

Widget topBar(BuildContext ctx, double el) {
  // Storage and audio are initialized once in main(); do not restart them on rebuild.

  return ValueListenableBuilder<bool>(
    valueListenable: isSelectionMode,
    builder: (context, isSelecting, _) {
      // --- СОСТОЯНИЕ 1: РЕЖИМ ВЫДЕЛЕНИЯ ---
      if (isSelecting) {
        return _buildSelectionTopBar(context, el);
      }
      return ValueListenableBuilder<bool>(
        valueListenable: isSearchMode,
        builder: (context, isSearching, _) {
          if (isSearching) {
            return _buildSearchTopBar(context, el);
          }
          return ValueListenableBuilder<String>(
            valueListenable: currentPage,
            builder: (context, page, _) {
              if (page == 'settings') {
                return _buildSettingsTopBar(ctx, el);
              }
              return _buildNormalTopBar(context, el);
            },
          );
        },
      );
    },
  );
}

Widget _buildSearchTopBar(BuildContext ctx, double el) {
  final iconBtn =
      buttons['icon'] as Widget Function(IconData, VoidCallback, double);

  return Row(
    children: [
      iconBtn(iconsMap['back']!, () {
        isSearchMode.value = false;
        clearSearch();
      }, el),
      SizedBox(width: el * .65),
      Expanded(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final compact =
                MediaQuery.sizeOf(ctx).width <
                (responsiveLayout['compactWidth'] as double);
            final maximumWidth = compact
                ? responsiveLayout['searchCompactMaxWidth'] as double
                : responsiveLayout['searchMaxWidth'] as double;
            final targetWidth = min(constraints.maxWidth, maximumWidth);
            final radius = el * (sizes['radiusK'] ?? 2.4);

            return Align(
              alignment: Alignment.centerLeft,
              child: SizedBox(
                width: targetWidth,
                height: el * (responsiveLayout['searchHeightFactor'] as double),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(radius),
                  child: BackdropFilter(
                    filter: ImageFilter.blur(
                      sigmaX: sizes['blur'] ?? 20,
                      sigmaY: sizes['blur'] ?? 20,
                    ),
                    child: Material(
                      type: MaterialType.transparency,
                      child: Container(
                        padding: EdgeInsets.symmetric(
                          horizontal:
                              el *
                              (responsiveLayout['searchHorizontalPaddingFactor']
                                  as double),
                        ),
                        decoration: BoxDecoration(
                          color: colors['glass'],
                          borderRadius: BorderRadius.circular(radius),
                          border: Border.all(color: colors['glassBorder']!),
                          boxShadow: [
                            BoxShadow(
                              color: colors['shadow']!,
                              blurRadius: el,
                              offset: Offset(0, el * .25),
                            ),
                          ],
                        ),
                        child: ValueListenableBuilder<String>(
                          valueListenable: searchQuery,
                          builder: (_, query, __) => Row(
                            children: [
                              Icon(
                                iconsMap['search']!,
                                color: colors['textDim'],
                                size: el * 1.3,
                              ),
                              SizedBox(width: el * .55),
                              Expanded(
                                child: TextField(
                                  controller: searchController,
                                  autofocus: true,
                                  onChanged: (value) => searchQuery.value =
                                      value.trim().toLowerCase(),
                                  style: TextStyle(
                                    color: colors['text'],
                                    fontSize: el,
                                  ),
                                  decoration: InputDecoration(
                                    isDense: true,
                                    hintText: texts['search']!,
                                    hintStyle: TextStyle(
                                      color: colors['textDim'],
                                      fontSize: el,
                                    ),
                                    border: InputBorder.none,
                                    contentPadding: EdgeInsets.zero,
                                  ),
                                ),
                              ),
                              if (query.isNotEmpty)
                                InkWell(
                                  onTap: clearSearch,
                                  borderRadius: BorderRadius.circular(el),
                                  child: Padding(
                                    padding: EdgeInsets.all(el * .22),
                                    child: Icon(
                                      iconsMap['close']!,
                                      size: el * 1.15,
                                      color: colors['textDim'],
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    ],
  );
}

Widget _buildNormalTopBar(BuildContext ctx, double el) {
  final iconBtn =
      buttons['icon'] as Widget Function(IconData, VoidCallback, double);
  final page = currentPage.value;
  final libraryPage = page == 'home';
  String titleForPage() {
    if (page != 'playlist') {
      return texts[pageTitleTextKeys[page]] ?? texts['home']!;
    }
    final playlistId = currentPlaylistId.value;
    final raw = playlistId == null ? null : playlistsBox?.get(playlistId);
    return raw is Map
        ? (raw['name'] ?? texts['playlists']!).toString()
        : texts['playlists']!;
  }

  Widget titleWidget() => Text(
    titleForPage(),
    style: TextStyle(
      fontSize: pageTitleFontSize(ctx, el),
      color: colors['text'],
      fontWeight: FontWeight.w700,
    ),
    maxLines: 1,
    overflow: TextOverflow.ellipsis,
  );

  return Builder(
    builder: (inner) => Row(
      children: [
        iconBtn(
          libraryPage ? iconsMap['menu']! : iconsMap['back']!,
          libraryPage ? () => Scaffold.of(inner).openDrawer() : goBackPage,
          el,
        ),
        SizedBox(width: el),
        Expanded(
          child: page == 'playlist'
              ? ValueListenableBuilder<List<Map<String, dynamic>>>(
                  valueListenable: playlistsList,
                  builder: (_, __, ___) => titleWidget(),
                )
              : titleWidget(),
        ),
        if (libraryPage) ...[
          SizedBox(width: el),
          iconBtn(iconsMap['sort']!, () => openSortSheet(inner, el), el),
          SizedBox(width: el),
          iconBtn(iconsMap['search']!, () => isSearchMode.value = true, el),
          SizedBox(width: el),
          iconBtn(iconsMap['more']!, () => openTopMoreMenu(inner, el), el),
        ] else if (page == 'playlist' && currentPlaylistId.value != null) ...[
          SizedBox(width: el),
          iconBtn(
            iconsMap['more']!,
            () => openPlaylistActions(inner, el, currentPlaylistId.value!),
            el,
          ),
        ] else if (page == 'queue') ...[
          TextButton(
            onPressed: clearQueue,
            child: Text(
              texts['clearQueue']!,
              style: TextStyle(color: colors['text']),
            ),
          ),
        ],
      ],
    ),
  );
}

Widget _buildSelectionTopBar(BuildContext ctx, double el) {
  final iconBtn =
      buttons['icon'] as Widget Function(IconData, VoidCallback, double);

  return ValueListenableBuilder<Set<String>>(
    valueListenable: selectedTrackIds,
    builder: (context, selected, _) {
      final count = selected.length;
      return Row(
        children: [
          iconBtn(iconsMap['close']!, _cancelSelectionMode, el),
          SizedBox(width: el),
          Expanded(
            child: Text(
              textTemplate('selectedTemplate', {'count': count}),
              style: TextStyle(
                fontSize: pageTitleFontSize(ctx, el),
                color: colors['text'],
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          TextButton(
            onPressed: _selectAllTracks,
            child: Text(
              texts['selectAll']!,
              style: TextStyle(color: colors['text'], fontSize: el * 1.05),
            ),
          ),
          SizedBox(width: el),
          iconBtn(iconsMap['delete']!, () => _deleteSelectedTracks(ctx), el),
        ],
      );
    },
  );
}

Widget libraryView(double el) {
  return ValueListenableBuilder2<String, String?>(
    first: libraryStatus,
    second: libraryErrorMessage,
    builder: (context, status, error, _) {
      if (status == 'initializing') {
        return Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircularProgressIndicator(color: colors['accent']),
              SizedBox(height: el),
              Text(
                texts['initializingLibrary']!,
                style: TextStyle(color: colors['textDim']),
              ),
            ],
          ),
        );
      }
      if (status == 'error') {
        return Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                texts['libraryOpenFailed']!,
                textAlign: TextAlign.center,
                style: TextStyle(color: colors['text']),
              ),
              if (error != null && error.isNotEmpty) ...[
                SizedBox(height: el * .4),
                Text(
                  error,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: TextStyle(color: colors['textDim'], fontSize: el * .8),
                ),
              ],
              SizedBox(height: el),
              FilledButton(
                onPressed: libraryRetryAction,
                child: Text(texts['retry']!),
              ),
            ],
          ),
        );
      }
      return _libraryReadyView(el);
    },
  );
}

Widget _libraryReadyView(double el) {
  final iconBtn =
      buttons['icon'] as Widget Function(IconData, VoidCallback, double);

  return ValueListenableBuilder<List<Map<String, dynamic>>>(
    valueListenable: tracksList,
    builder: (_, list, __) {
      if (list.isEmpty) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              texts['library']!,
              style: TextStyle(
                color: colors['text'],
                fontSize: el * 1.2,
                fontWeight: FontWeight.w600,
              ),
            ),
            SizedBox(height: el * .8),
            Center(
              child: Padding(
                padding: EdgeInsets.symmetric(vertical: el * 6),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      iconsMap['playlist']!,
                      size: el * 4,
                      color: colors['textDim'],
                    ),
                    SizedBox(height: el),
                    Text(
                      texts['noTracks']!,
                      style: TextStyle(
                        color: colors['textDim'],
                        fontSize: el * 1.05,
                      ),
                    ),
                    SizedBox(height: el * .6),
                    Text(
                      texts[kIsWeb ||
                              defaultTargetPlatform == TargetPlatform.iOS
                          ? 'emptyLibraryManualCta'
                          : 'emptyLibraryAutoCta']!,
                      textAlign: TextAlign.center,
                      style: TextStyle(color: colors['textDim'], fontSize: el),
                    ),
                  ],
                ),
              ),
            ),
          ],
        );
      }
      return ValueListenableBuilder<String>(
        valueListenable: searchQuery,
        builder: (_, q, __) {
          // 1) фильтр поиска
          final view = (q.isEmpty)
              ? list
              : list.where((t) {
                  final title = (t['title'] ?? '').toString().toLowerCase();
                  final artist = (t['artist'] ?? '').toString().toLowerCase();
                  return title.contains(q) || artist.contains(q);
                }).toList();
          if (view.isEmpty) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      texts['library']!,
                      style: TextStyle(
                        color: colors['text'],
                        fontSize: el * 1.2,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const Spacer(),
                    Text(
                      texts[currentSort] ?? '',
                      style: TextStyle(color: colors['textDim'], fontSize: el),
                    ),
                  ],
                ),
                SizedBox(height: el * .8),
                Center(
                  child: Padding(
                    padding: EdgeInsets.symmetric(vertical: el * 4),
                    child: Text(
                      texts['noResults']!,
                      style: TextStyle(
                        color: colors['textDim'],
                        fontSize: el * 1.05,
                      ),
                    ),
                  ),
                ),
              ],
            );
          }
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Text(
                    texts['library']!,
                    style: TextStyle(
                      color: colors['text'],
                      fontSize: el * 1.2,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const Spacer(),
                  Text(
                    texts[currentSort] ?? '',
                    style: TextStyle(color: colors['textDim'], fontSize: el),
                  ),
                ],
              ),
              SizedBox(height: el * .8),
              Expanded(
                child: ValueListenableBuilder2<String?, bool>(
                  first: currentId,
                  second: isPlaying,
                  builder: (_, activeId, playing, __) {
                    return ValueListenableBuilder2<bool, Set<String>>(
                      first: isSelectionMode,
                      second: selectedTrackIds,
                      builder: (_, isSelecting, selectedIds, __) {
                        return ListView.separated(
                          itemCount: view.length,
                          separatorBuilder: (_, __) =>
                              SizedBox(height: el * .6),
                          itemBuilder: (ctx, i) {
                            final t = view[i];
                            final artist = (t['artist'] ?? '')
                                .toString()
                                .trim();
                            final int dur = _numberFromData(t['duration']);
                            final String meta =
                                '${artist.isEmpty ? texts['unknown']! : artist}'
                                '${dur > 0 ? ' • ${formatMs(dur)}' : ''}';
                            final trackId = t['id'] as String;
                            final isCurrent = activeId == trackId;
                            final isSelected = selectedIds.contains(trackId);
                            return Container(
                              decoration: BoxDecoration(
                                color: isSelected
                                    ? colors['accentDim']!.withValues(
                                        alpha: 0.50,
                                      )
                                    : isCurrent
                                    ? colors['accentDim']!.withValues(
                                        alpha: 0.34,
                                      )
                                    : Colors.transparent,
                                borderRadius: BorderRadius.circular(el),
                                border: isCurrent
                                    ? Border.all(
                                        color: colors['accent']!.withValues(
                                          alpha: 0.72,
                                        ),
                                        width: 1.4,
                                      )
                                    : null,
                              ),
                              child: InkWell(
                                onTap: () {
                                  if (isSelecting) {
                                    _toggleTrackSelection(trackId);
                                  } else {
                                    playSelectedTrack(ctx, trackId);
                                  }
                                },
                                onLongPress: isSelecting
                                    ? null
                                    : () => openTrackActions(ctx, el, trackId),
                                borderRadius: BorderRadius.circular(el),
                                child: Padding(
                                  padding: EdgeInsets.all(el * .6),
                                  child: Row(
                                    children: [
                                      if (isSelecting)
                                        Icon(
                                          isSelected
                                              ? iconsMap['selected']!
                                              : iconsMap['select']!,
                                          color: colors['text'],
                                          size: el * 2.6,
                                        )
                                      else
                                        Stack(
                                          clipBehavior: Clip.none,
                                          children: [
                                            artThumb(t, el),
                                            if (isCurrent)
                                              Positioned(
                                                right: -el * .16,
                                                bottom: -el * .16,
                                                child: Container(
                                                  width: el * 1.22,
                                                  height: el * 1.22,
                                                  decoration: BoxDecoration(
                                                    color: colors['accent'],
                                                    shape: BoxShape.circle,
                                                    border: Border.all(
                                                      color: colors['text']!,
                                                      width: 1.2,
                                                    ),
                                                  ),
                                                  alignment: Alignment.center,
                                                  child: Icon(
                                                    playing
                                                        ? Icons
                                                              .graphic_eq_rounded
                                                        : iconsMap['pause']!,
                                                    color: colors['text'],
                                                    size: el * .82,
                                                  ),
                                                ),
                                              ),
                                          ],
                                        ),
                                      SizedBox(width: el),
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              t['title'] ?? '',
                                              style: TextStyle(
                                                color: isCurrent
                                                    ? colors['accent']
                                                    : colors['text'],
                                                fontSize: el * 1.05,
                                                fontWeight: FontWeight.w600,
                                              ),
                                              overflow: TextOverflow.ellipsis,
                                            ),
                                            SizedBox(height: el * .2),
                                            Text(
                                              isCurrent
                                                  ? '${playing ? texts['playing']! : texts['paused']!} • $meta'
                                                  : meta,
                                              style: TextStyle(
                                                color: colors['textDim'],
                                                fontSize: el,
                                              ),
                                              overflow: TextOverflow.ellipsis,
                                            ),
                                          ],
                                        ),
                                      ),
                                      SizedBox(width: el * .45),
                                      if (!isSelecting)
                                        iconBtn(
                                          iconsMap['more']!,
                                          () => openTrackActions(
                                            ctx,
                                            el,
                                            trackId,
                                          ),
                                          el,
                                        ),
                                    ],
                                  ),
                                ),
                              ),
                            );
                          },
                        );
                      },
                    );
                  },
                ),
              ),
            ],
          );
        },
      );
    },
  );
}

Widget miniPlayer(double el) {
  final iconBtn =
      buttons['icon'] as Widget Function(IconData, VoidCallback, double);

  return ValueListenableBuilder<String?>(
    valueListenable: currentId,
    builder: (_, id, __) {
      Map<String, dynamic>? t;
      if (id != null) {
        t = tracksList.value.cast<Map<String, dynamic>?>().firstWhere(
          (e) => e?['id'] == id,
          orElse: () => null,
        );
      }

      final title = ((t?['title'] ?? texts['trackSample']!) as String);
      final artistRaw = ((t?['artist'] ?? '') as String).trim();
      final artist = artistRaw.isEmpty ? texts['unknown']! : artistRaw;
      final durMs = _numberFromData(t?['duration'] ?? durationMs.value);

      Widget controls({bool includeClose = true}) {
        return FittedBox(
          fit: BoxFit.scaleDown,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              ValueListenableBuilder<String>(
                valueListenable: playbackMode,
                builder: (_, mode, __) {
                  final icon = playbackModeIcons[mode] ?? iconsMap['order']!;
                  return iconBtn(icon, cyclePlaybackMode, el);
                },
              ),
              SizedBox(width: el * .45),
              iconBtn(iconsMap['prev']!, () => playPrev(), el),
              SizedBox(width: el * .45),
              ValueListenableBuilder<bool>(
                valueListenable: isPlaying,
                builder: (_, playing, __) => iconBtn(
                  playing ? iconsMap['pause']! : iconsMap['play']!,
                  () => togglePlay(),
                  el,
                ),
              ),
              SizedBox(width: el * .45),
              iconBtn(iconsMap['next']!, () => playNext(), el),
              if (includeClose) ...[
                SizedBox(width: el * .45),
                iconBtn(iconsMap['close']!, () => stopAndHidePlayer(), el),
              ],
            ],
          ),
        );
      }

      Widget trackText() {
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: colors['text'], fontSize: el),
            ),
            Text(
              artist,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: colors['textDim'], fontSize: el * .95),
            ),
          ],
        );
      }

      Widget trackSummary() {
        return Row(
          children: [
            artThumb(t ?? <String, dynamic>{}, el),
            SizedBox(width: el),
            Expanded(child: trackText()),
          ],
        );
      }

      Widget compactPlayerHeader() {
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                artThumb(t ?? <String, dynamic>{}, el, size: 2.9),
                SizedBox(width: el * .8),
                Expanded(child: trackText()),
              ],
            ),
            SizedBox(height: el * .6),
            Center(child: controls()),
          ],
        );
      }

      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          LayoutBuilder(
            builder: (_, constraints) {
              final compact =
                  constraints.maxWidth <
                  (responsiveLayout['miniPlayerCompactWidth'] as double);
              if (compact) {
                return compactPlayerHeader();
              }
              return Row(
                children: [
                  Expanded(child: trackSummary()),
                  SizedBox(width: el * .6),
                  controls(),
                ],
              );
            },
          ),
          SizedBox(height: el * .6),
          ValueListenableBuilder<int>(
            valueListenable: durationMs,
            builder: (_, dMs, __) => ValueListenableBuilder<int>(
              valueListenable: positionMs,
              builder: (_, pMs, __) {
                final total = (durMs > 0 ? durMs : dMs);
                final denom = total > 0 ? total : 1;
                final frac = (pMs / denom).clamp(0.0, 1.0);
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    LayoutBuilder(
                      builder: (_, c) {
                        final w = c.maxWidth;
                        void seekAt(double dx) {
                          final f = (dx / w).clamp(0.0, 1.0);
                          seekToFraction(f);
                        }

                        return GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTapDown: (e) => seekAt(e.localPosition.dx),
                          onHorizontalDragUpdate: (e) =>
                              seekAt(e.localPosition.dx),
                          child: Container(
                            height: el * .6,
                            decoration: BoxDecoration(
                              color: colors['text']!.withValues(alpha: .25),
                              borderRadius: BorderRadius.circular(el),
                            ),
                            alignment: Alignment.centerLeft,
                            child: FractionallySizedBox(
                              widthFactor: frac.toDouble(),
                              child: Container(
                                height: double.infinity,
                                decoration: BoxDecoration(
                                  color: colors['accent'],
                                  borderRadius: BorderRadius.circular(el),
                                ),
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                    SizedBox(height: el * .2),
                    Row(
                      children: [
                        Text(
                          formatMs(pMs),
                          style: TextStyle(
                            color: colors['textDim'],
                            fontSize: el * .9,
                          ),
                        ),
                        const Spacer(),
                        Text(
                          formatMs(total),
                          style: TextStyle(
                            color: colors['textDim'],
                            fontSize: el * .9,
                          ),
                        ),
                      ],
                    ),
                  ],
                );
              },
            ),
          ),
        ],
      );
    },
  );
}
/* ========= actions ========= */

void openSortSheet(BuildContext ctx, double el) {
  showModalBottomSheet(
    context: ctx,
    backgroundColor: Colors.transparent,
    builder: (_) => Padding(
      padding: EdgeInsets.all(el * 1.2),
      child: glass(
        ListView.builder(
          shrinkWrap: true,
          itemCount: sortOptionIds.length,
          itemBuilder: (_, i) => ListTile(
            title: Text(
              texts[sortOptionIds[i]]!,
              style: TextStyle(color: colors['text']),
            ),
            onTap: () {
              Navigator.pop(ctx);
              setSort(sortOptionIds[i]);
            },
          ),
        ),
        el,
      ),
    ),
  );
}

void _applyHivePreferences() {
  final preferences = prefsBox;
  if (preferences == null) return;

  final savedScale = preferences.get('uiScale', defaultValue: 1.0);
  uiScale.value = savedScale is num ? savedScale.toDouble() : 1.0;
  final savedTextScale = preferences.get('textScale', defaultValue: 1.0);
  textScale.value = savedTextScale is num ? savedTextScale.toDouble() : 1.0;
  final savedLyricsAnimationMode = preferences
      .get('lyricsAnimationMode', defaultValue: '')
      .toString();
  final legacySingAlong =
      preferences.get('singAlongMode', defaultValue: false) == true;
  lyricsAnimationMode.value =
      lyricsAnimationModes.contains(savedLyricsAnimationMode)
      ? savedLyricsAnimationMode
      : legacySingAlong
      ? 'synced'
      : 'smooth';
  final savedLyricsOffset = preferences.get('lyricsOffsetMs', defaultValue: 0);
  final offsetMinimum = lyricPresentation['offsetMinMs'] as int;
  final offsetMaximum = lyricPresentation['offsetMaxMs'] as int;
  lyricsOffsetMs.value = savedLyricsOffset is num
      ? savedLyricsOffset.toInt().clamp(offsetMinimum, offsetMaximum).toInt()
      : 0;

  final savedTheme = preferences.get('theme', defaultValue: 'glass').toString();
  themeId.value = themes.containsKey(savedTheme) ? savedTheme : 'glass';
  _applyTheme(themeId.value);

  final savedBackground = preferences
      .get('background', defaultValue: 'sky')
      .toString();
  backgroundId.value = backgrounds.containsKey(savedBackground)
      ? savedBackground
      : 'sky';

  currentSort = preferences.get('sort', defaultValue: 'byDate').toString();
  playbackMode.value = preferences
      .get('playbackMode', defaultValue: 'order')
      .toString();
  final scanPreferenceKey =
      libraryPerformance['lastSuccessfulScanPreference'] as String;
  final savedScanAt = preferences.get(scanPreferenceKey);
  if (savedScanAt is num && savedScanAt > 0) {
    _lastAutomaticScanAt = DateTime.fromMillisecondsSinceEpoch(
      savedScanAt.toInt(),
    );
  }
}

bool _preferencesApplied = false;

Future<void> initializePreferences() async {
  if (prefsBox == null) {
    await Hive.initFlutter();
    prefsBox = await Hive.openBox('prefsBox');
  }
  if (!_preferencesApplied) {
    _applyHivePreferences();
    _preferencesApplied = true;
  }
}

Future<void>? _libraryInitialization;

Future<void> ensureBoxes() {
  return _libraryInitialization ??= _initializeBoxesOnce();
}

Future<void> _initializeBoxesOnce() async {
  try {
    await _initializeBoxes();
  } catch (_) {
    _libraryInitialization = null;
    rethrow;
  }
}

Future<void> _initializeBoxes() async {
  if (prefsBox == null) {
    await Hive.initFlutter();
    prefsBox = await Hive.openBox('prefsBox');
  }

  if (tracksBox == null || playlistsBox == null) {
    final preferences = prefsBox!;
    final alreadyMigrated =
        preferences.get('libraryDriftMigratedV1', defaultValue: false) == true;
    Box? legacyTracksBox;
    Box? legacyPlaylistsBox;
    final legacyTracks = <Map<String, dynamic>>[];
    final legacyPlaylists = <Map<String, dynamic>>[];
    var legacyQueue = <String>[];

    if (!alreadyMigrated) {
      legacyTracksBox = await Hive.openBox('tracksBox');
      legacyPlaylistsBox = await Hive.openBox('playlistsBox');

      for (final raw in legacyTracksBox.values) {
        if (raw is Map) legacyTracks.add(Map<String, dynamic>.from(raw));
      }
      for (final raw in legacyPlaylistsBox.values) {
        if (raw is Map) legacyPlaylists.add(Map<String, dynamic>.from(raw));
      }
      final rawQueue = preferences.get('queueIds', defaultValue: <dynamic>[]);
      if (rawQueue is List) {
        legacyQueue = rawQueue.map((id) => id.toString()).toList();
      }
    }

    final initializer = libraryStorageInitializer;
    if (initializer == null) {
      throw StateError('Drift library storage is not configured.');
    }
    await initializer(legacyTracks, legacyPlaylists, legacyQueue);

    if (!alreadyMigrated) {
      if (tracksBox.length < legacyTracks.length ||
          playlistsBox.length < legacyPlaylists.length) {
        throw StateError('The music library was not fully migrated to Drift.');
      }

      await preferences.put('libraryDriftMigratedV1', true);
      await preferences.delete('queueIds');
      await legacyTracksBox?.close();
      await legacyPlaylistsBox?.close();
      if (await Hive.boxExists('tracksBox')) {
        await Hive.deleteBoxFromDisk('tracksBox');
      }
      if (await Hive.boxExists('playlistsBox')) {
        await Hive.deleteBoxFromDisk('playlistsBox');
      }
    }
  }

  _reloadTracks();
  _reloadPlaylists();
  final lastId = prefsBox?.get('lastPlayedId')?.toString();
  if (lastId != null &&
      tracksList.value.any((track) => track['id'] == lastId)) {
    currentId.value = lastId;
  }
}

void setSort(String id) {
  currentSort = id;
  prefsBox?.put('sort', id);
  _reloadTracks();
}

void _reloadTracks() {
  final List<Map<String, dynamic>> all = <Map<String, dynamic>>[
    for (final value in tracksBox?.values ?? const <dynamic>[])
      if (value is Map) Map<String, dynamic>.from(value),
  ];

  all.sort((Map<String, dynamic> a, Map<String, dynamic> b) {
    switch (currentSort) {
      case 'byName':
        return (a['title'] ?? '').toString().toLowerCase().compareTo(
          (b['title'] ?? '').toString().toLowerCase(),
        );
      case 'byArtist':
        return (a['artist'] ?? '').toString().toLowerCase().compareTo(
          (b['artist'] ?? '').toString().toLowerCase(),
        );
      case 'byDuration':
        return _numberFromData(
          a['duration'],
        ).compareTo(_numberFromData(b['duration']));
      case 'byDate':
      default:
        return _numberFromData(
          b['addedAt'],
        ).compareTo(_numberFromData(a['addedAt']));
    }
  });

  tracksList.value = all;
}

// Manual file import is available from the top overflow menu.
Future<Uint8List?> _webUint8Bytes(PlatformFile file) async {
  final directBytes = file.bytes;
  if (directBytes != null && directBytes.isNotEmpty) return directBytes;

  final stream = file.readStream;
  if (stream == null) return null;

  final builder = BytesBuilder(copy: false);
  try {
    await for (final chunk in stream) {
      if (chunk.isNotEmpty) builder.add(chunk);
    }
  } catch (error) {
    debugPrint('Web media byte stream failed for ${file.name}: $error');
    return null;
  }

  final bytes = builder.takeBytes();
  return bytes.isEmpty ? null : bytes;
}

String _webFileSignature(Uint8List bytes) {
  final sample = webMediaTransferConfig['signatureSampleBytes'] as int;
  var hash = 0x811c9dc5;
  void addRange(int start, int end) {
    for (var index = start; index < end; index++) {
      hash = ((hash ^ bytes[index]) * 0x01000193) & 0xffffffff;
    }
  }

  final headEnd = min(sample, bytes.length);
  addRange(0, headEnd);
  if (bytes.length > sample) {
    addRange(max(headEnd, bytes.length - sample), bytes.length);
  }
  return '${bytes.length}_${hash.toRadixString(16)}';
}

Future<void> pickAndImportFiles(BuildContext ctx) async {
  final preferReadStream =
      kIsWeb && webMediaTransferConfig['preferReadStream'] == true;
  final res = await FilePicker.platform.pickFiles(
    type: FileType.custom,
    allowedExtensions: audioExt,
    allowMultiple: true,
    withData: kIsWeb && !preferReadStream,
    withReadStream: preferReadStream,
    readSequential: kIsWeb && webMediaTransferConfig['readSequential'] == true,
  );
  if (res == null || res.files.isEmpty) return;

  await ensureBoxes();
  var failedFiles = 0;

  for (final f in res.files) {
    if (!_isAudio(f.name) || (!kIsWeb && _existsFile(f))) continue;
    String? path;
    Uint8List? bytes;
    final name = f.name;
    String idSource;
    String signature = '';

    try {
      if (kIsWeb) {
        bytes = await _webUint8Bytes(f);
        idSource = f.name;
        if (bytes == null || bytes.isEmpty) {
          failedFiles++;
          continue;
        }
        signature = _webFileSignature(bytes);
        if (await _isExistingWebFile(signature, name, f.size)) continue;
      } else {
        path = f.path;
        idSource = path ?? f.name;
        if (path == null) continue;
      }

      final now = DateTime.now().millisecondsSinceEpoch;
      final id = _fastId(idSource, now);
      final base = p.basenameWithoutExtension(idSource);
      String title = base;
      String artist = '';
      String album = '';
      int duration = 0;
      Uint8List? art;
      String lyrics = '';

      try {
        await Future<void>.delayed(Duration.zero);
        Metadata? md;

        if (kIsWeb && bytes != null && bytes.isNotEmpty) {
          final tp = TagProcessor();
          final tags = await tp.getTagsFromByteArray(Future.value(bytes));
          title = _pickTagText(tags, const <String>['title', 'TIT2'], title);
          artist = _pickTagText(tags, const <String>['artist', 'TPE1'], artist);
          album = _pickTagText(tags, const <String>['album', 'TALB'], album);
          lyrics = _pickLyrics(tags);
          final embeddedArtwork = _pickArtwork(tags);
          if (embeddedArtwork != null) art = embeddedArtwork;

          final timeoutMs =
              webMediaTransferConfig['metadataTimeoutMs'] as int? ?? 6000;
          md = await MetadataRetriever.fromBytes(
            bytes,
          ).timeout(Duration(milliseconds: timeoutMs));
        } else if (!kIsWeb && path != null) {
          md = await MetadataRetriever.fromFile(io.File(path));
        }

        if (md != null) {
          final t = (md.trackName ?? '').trim();
          if (t.isNotEmpty) title = t;
          final names = (md.trackArtistNames ?? const <String>[])
              .where((e) => e.trim().isNotEmpty)
              .toList();
          if (names.isEmpty && (md.authorName ?? '').trim().isNotEmpty) {
            names.add(md.authorName!.trim());
          }
          artist = names.join(', ').trim();
          final metadataAlbum = (md.albumName ?? '').trim();
          if (metadataAlbum.isNotEmpty) album = metadataAlbum;
          duration = md.trackDuration ?? 0;
          if (md.albumArt != null && md.albumArt!.isNotEmpty) {
            art = md.albumArt;
          }
        }

        if (title == base && artist.isEmpty) {
          final guessed = _guessMetaFromName(base);
          title = guessed['title']!;
          artist = guessed['artist']!;
        }
      } catch (error) {
        debugPrint('Metadata read failed for $name: $error');
        final g = _guessMetaFromName(base);
        title = g['title']!;
        artist = g['artist']!;
      }
      final track = <String, dynamic>{
        'id': id,
        'source': kIsWeb ? 'web' : 'fs',
        'path': path ?? '',
        'name': name,
        'size': f.size,
        'signature': signature,
        'title': title,
        'artist': artist,
        'album': album,
        'duration': duration,
        'art': art,
        'lyrics': lyrics,
        'addedAt': now,
      };
      if (kIsWeb && bytes != null) track['bytes'] = bytes;
      await tracksBox!.put(id, track);
      if (kIsWeb && bytes != null) _cacheWebTrackBytes(id, bytes);
    } catch (error) {
      failedFiles++;
      debugPrint('Import failed for $name: $error');
      bytes = null;
    }
    await Future<void>.delayed(
      Duration(milliseconds: libraryPerformance['eventLoopYieldMs'] as int),
    );
  }

  _reloadTracks();
  if (failedFiles > 0 && ctx.mounted) {
    ScaffoldMessenger.of(ctx).showSnackBar(
      SnackBar(
        content: Text(
          kIsWeb ? texts['webStorageFailed']! : texts['webImportPartial']!,
        ),
      ),
    );
  }
}

Future<bool> _isExistingWebFile(String signature, String name, int size) async {
  final normalizedName = name.trim().toLowerCase();
  for (final raw in tracksBox?.values ?? const <dynamic>[]) {
    if (raw is! Map || (raw['source'] ?? '').toString() != 'web') continue;
    if (_numberFromData(raw['size']) != size ||
        (raw['name'] ?? '').toString().trim().toLowerCase() != normalizedName) {
      continue;
    }
    var existingSignature = (raw['signature'] ?? '').toString();
    if (existingSignature.isEmpty) {
      final id = (raw['id'] ?? '').toString();
      final storedBytes = await tracksBox?.loadTrackBytes(id);
      if (storedBytes is Uint8List && storedBytes.isNotEmpty) {
        existingSignature = _webFileSignature(storedBytes);
        final latestRaw = tracksBox?.get(id);
        if (latestRaw is! Map ||
            (latestRaw['source'] ?? '').toString() != 'web') {
          continue;
        }
        final latest = Map<String, dynamic>.from(latestRaw);
        if (_numberFromData(latest['size']) != size ||
            (latest['name'] ?? '').toString().trim().toLowerCase() !=
                normalizedName) {
          continue;
        }
        final latestSignature = (latest['signature'] ?? '').toString();
        if (latestSignature.isEmpty) {
          await tracksBox!.put(id, <String, dynamic>{
            ...latest,
            'signature': existingSignature,
          });
        } else {
          existingSignature = latestSignature;
        }
      }
    }
    if (existingSignature == signature) return true;
  }
  return false;
}

Widget artThumb(Map<String, dynamic> t, double el, {double size = 2.6}) {
  final id = (t['id'] ?? '').toString();
  final Uint8List? art = t['art'] is Uint8List
      ? t['art'] as Uint8List
      : artworkBytesCache[id];
  if ((art == null || art.isEmpty) &&
      id.isNotEmpty &&
      t['hasArtwork'] == true) {
    unawaited(_ensureTrackArtworkLoaded(id));
  }
  final w = el * size;
  final decodeSize =
      (w * (libraryPerformance['thumbnailDecodeScale'] as double)).round();
  final r = BorderRadius.circular(el);

  return ClipRRect(
    borderRadius: r,
    child: (art != null && art.isNotEmpty)
        ? Image.memory(
            art,
            width: w,
            height: w,
            cacheWidth: decodeSize,
            cacheHeight: decodeSize,
            fit: BoxFit.cover,
            gaplessPlayback: true,
            filterQuality: FilterQuality.medium,
          )
        : Image.asset(
            defaultArtPath,
            width: w,
            height: w,
            fit: BoxFit.cover,
            gaplessPlayback: true,
            filterQuality: FilterQuality.medium,
          ),
  );
}

bool _isAudio(String path) {
  final ext = p.extension(path).replaceFirst('.', '').toLowerCase();
  return audioExt.contains(ext);
}

bool _existsFile(PlatformFile f) {
  final vals = tracksBox?.values ?? const Iterable.empty();
  final path = f.path;
  if (path != null) {
    return vals.any((e) {
      final m = Map<String, dynamic>.from(e as Map);
      return (m['path'] ?? '') == path;
    });
  }

  return vals.any((e) {
    final m = Map<String, dynamic>.from(e as Map);
    return (m['name'] ?? '') == f.name && (m['size'] ?? -1) == f.size;
  });
}

String _fastId(String path, int seed) {
  final s = '${path.length}_${path.hashCode}_$seed';
  return s;
}

Future<void> ensureAudio() async {
  if (audioInited) return;
  final active = _audioInitialization;
  if (active != null) return active;
  _audioInitialization = _initializeAudioOnce();
  return _audioInitialization!;
}

Future<void> ensureAudioService() async {
  if (audioHandler != null) return;
  final active = _audioServiceInitialization;
  if (active != null) return active;
  final initializer = audioServiceInitializer;
  if (initializer == null) return;
  final future = initializer();
  _audioServiceInitialization = future;
  try {
    await future;
  } finally {
    if (audioHandler == null) _audioServiceInitialization = null;
  }
}

Future<void> _initializeAudioOnce() async {
  try {
    await audio.setAudioContext(
      AudioContext(
        iOS: AudioContextIOS(
          category: AVAudioSessionCategory.playback,
          options: <AVAudioSessionOptions>{},
        ),
        android: const AudioContextAndroid(
          isSpeakerphoneOn: false,
          stayAwake: true,
          contentType: AndroidContentType.music,
          usageType: AndroidUsageType.media,
          audioFocus: AndroidAudioFocus.gain,
        ),
      ),
    );
    await audio.setReleaseMode(ReleaseMode.stop);

    audio.onPlayerStateChanged.listen((state) {
      final playing = currentId.value != null && state == PlayerState.playing;
      isPlaying.value = playing;
      final handler = audioHandler;
      if (handler is AppAudioHandler) handler.syncPlayerState(state);
    });
    audio.onPositionChanged.listen((position) {
      if (currentId.value == null) return;
      positionMs.value = position.inMilliseconds;
      final handler = audioHandler;
      if (handler is AppAudioHandler) handler.syncPosition(position);
    });
    audio.onDurationChanged.listen((duration) {
      if (currentId.value == null) return;
      durationMs.value = duration.inMilliseconds;
      final handler = audioHandler;
      if (handler is AppAudioHandler) handler.syncDuration(duration);
    });
    audio.onPlayerComplete.listen((_) async {
      if (playbackMode.value == 'repeatOne' && currentId.value != null) {
        await playById(
          currentId.value!,
          queuePosition: _activeQueuePosition >= 0
              ? _activeQueuePosition
              : null,
        );
        return;
      }
      await playNext(completed: true);
    });
    audioInited = true;
  } catch (error) {
    audioInited = false;
    _audioInitialization = null;
    rethrow;
  }
}

Future<void> stopPlaybackSession({bool clearCurrent = true}) async {
  final request = ++_playbackRequestGeneration;
  _publishFinalStoppedState(clearCurrent: clearCurrent);
  final task = _playbackCommandChain
      .catchError((Object _) {})
      .then((_) => _performFinalStop(request, clearCurrent));
  _playbackCommandChain = task;
  await task;
}

void _publishFinalStoppedState({required bool clearCurrent}) {
  isPlaying.value = false;
  positionMs.value = 0;
  durationMs.value = 0;
  _activeQueuePosition = -1;
  if (clearCurrent) currentId.value = null;
  final handler = audioHandler;
  if (handler is AppAudioHandler) handler.publishStopped();
}

Future<void> _performFinalStop(int request, bool clearCurrent) async {
  try {
    await ensureAudio();
    await audio.stop();
  } catch (error) {
    debugPrint('Audio stop failed: $error');
  }
  if (request == _playbackRequestGeneration) {
    _publishFinalStoppedState(clearCurrent: clearCurrent);
    if (clearCurrent) await prefsBox?.delete('lastPlayedId');
  }
}

int _numberFromData(dynamic value) {
  if (value is num) return value.toInt();
  return int.tryParse(value?.toString() ?? '') ?? 0;
}

List<io.Directory> _automaticScanDirectories() {
  final directories = <io.Directory>[];
  final knownPaths = <String>[];

  void addDirectory(String path) {
    if (path.trim().isEmpty || knownPaths.contains(path)) return;
    knownPaths.add(path);
    directories.add(io.Directory(path));
  }

  final home =
      io.Platform.environment[defaultTargetPlatform == TargetPlatform.windows
          ? 'USERPROFILE'
          : 'HOME'];
  if (home != null && home.isNotEmpty) {
    for (final folder
        in automaticMusicFolders[defaultTargetPlatform] ?? const <String>[]) {
      addDirectory(p.join(home, folder));
    }
  }

  if (defaultTargetPlatform == TargetPlatform.windows) {
    for (final letter in windowsMediaDriveLetters) {
      addDirectory('$letter:\\Music');
    }
  } else if (defaultTargetPlatform == TargetPlatform.linux) {
    final user = io.Platform.environment['USER'] ?? '';
    if (user.isNotEmpty) {
      for (final folder in unixExternalMediaFolders) {
        addDirectory(p.join('/', folder, user));
      }
    }
  } else if (defaultTargetPlatform == TargetPlatform.macOS) {
    for (final folder in macExternalMediaFolders) {
      addDirectory(folder);
    }
  }

  return directories;
}

bool _artworkBackfillRunning = false;

Future<void> backfillMissingArtwork() async {
  if (_artworkBackfillRunning) return;
  _artworkBackfillRunning = true;
  try {
    await ensureBoxes();
    final batchSize = libraryPerformance['artworkBatchSize'] as int;
    final pendingIds = (tracksBox?.values ?? const <dynamic>[])
        .whereType<Map>()
        .where((track) => track['artChecked'] != true)
        .map((track) => (track['id'] ?? '').toString())
        .where((id) => id.isNotEmpty)
        .toList();
    for (
      var offset = 0;
      offset < pendingIds.length && backgroundMetadataWorkEnabled;
      offset += batchSize
    ) {
      final artworkResults = <String, Uint8List?>{};
      final end = min(offset + batchSize, pendingIds.length);
      for (final id in pendingIds.sublist(offset, end)) {
        if (!backgroundMetadataWorkEnabled) break;
        final initialRaw = tracksBox?.get(id);
        if (initialRaw is! Map || initialRaw['artChecked'] == true) continue;
        final initial = Map<String, dynamic>.from(initialRaw);
        Uint8List? artwork;
        var metadataReadSucceeded = false;
        try {
          if (kIsWeb) {
            Uint8List? storedBytes = await tracksBox!.loadTrackBytes(id);
            if (storedBytes != null && storedBytes.isNotEmpty) {
              final timeoutMs =
                  webMediaTransferConfig['metadataTimeoutMs'] as int;
              final metadata = await MetadataRetriever.fromBytes(
                storedBytes,
              ).timeout(Duration(milliseconds: timeoutMs));
              artwork = metadata.albumArt;
              metadataReadSucceeded = true;
            }
            storedBytes = null;
          } else {
            final path = (initial['path'] ?? '').toString();
            if (path.isNotEmpty) {
              final file = io.File(path);
              if (await file.exists()) {
                final metadata = await MetadataRetriever.fromFile(file);
                artwork = metadata.albumArt;
                metadataReadSucceeded = true;
              }
            }
          }
        } catch (error) {
          debugPrint(
            'Artwork backfill failed for ${(initial['name'] ?? id)}: '
            '$error',
          );
        }
        if (!metadataReadSucceeded) continue;
        artworkResults[id] = artwork;
      }
      final updates = <String, Map<String, dynamic>>{};
      var currentChanged = false;
      for (final result in artworkResults.entries) {
        final latestRaw = tracksBox?.get(result.key);
        if (latestRaw is! Map) continue;
        final latest = Map<String, dynamic>.from(latestRaw);
        final updated = <String, dynamic>{...latest, 'artChecked': true};
        final artwork = result.value;
        if (latest['hasArtwork'] != true &&
            artwork != null &&
            artwork.isNotEmpty) {
          updated['art'] = artwork;
        }
        updates[result.key] = updated;
        if (currentId.value == result.key) currentChanged = true;
      }
      if (updates.isNotEmpty) {
        await tracksBox!.putAll(updates);
        _reloadTracks();
      }
      if (currentChanged) currentId.refresh();
      await Future<void>.delayed(
        Duration(milliseconds: libraryPerformance['eventLoopYieldMs'] as int),
      );
    }
  } finally {
    _artworkBackfillRunning = false;
  }
}

Map<String, Map<String, dynamic>> _buildTrackSourceIndex() {
  final index = <String, Map<String, dynamic>>{};
  for (final raw in tracksBox?.values ?? const <dynamic>[]) {
    if (raw is! Map) continue;
    final track = Map<String, dynamic>.from(raw);
    final path = (track['path'] ?? '').toString();
    final url = (track['url'] ?? '').toString();
    if (path.isNotEmpty) index[path] = track;
    if (url.isNotEmpty) index[url] = track;
  }
  return index;
}

Future<Map<String, dynamic>?> _prepareAutomaticTrack(
  Map<String, dynamic> fileData,
  Map<String, Map<String, dynamic>> sourceIndex,
) async {
  final path = (fileData['path'] ?? '').toString();
  final url = (fileData['url'] ?? '').toString();
  final sourceKey = path.isNotEmpty ? path : url;
  if (sourceKey.isEmpty) return null;

  final existing = sourceIndex[sourceKey];

  final size = _numberFromData(fileData['size']);
  final modifiedAt = _numberFromData(fileData['modifiedAt']);
  if (existing != null &&
      _numberFromData(existing['size']) == size &&
      (modifiedAt == 0 ||
          _numberFromData(existing['modifiedAt']) == modifiedAt)) {
    return null;
  }

  final name = (fileData['name'] ?? p.basename(sourceKey)).toString();
  final base = p.basenameWithoutExtension(name);
  String title = (fileData['title'] ?? base).toString().trim();
  String artist = (fileData['artist'] ?? '').toString().trim();
  String album = (fileData['album'] ?? '').toString().trim();
  int duration = _numberFromData(fileData['duration']);
  String lyrics = (existing?['lyrics'] ?? fileData['lyrics'] ?? '').toString();
  var metadataReadSucceeded = false;
  Uint8List? art = fileData['art'] is Uint8List
      ? fileData['art'] as Uint8List
      : existing?['art'] is Uint8List
      ? existing!['art'] as Uint8List
      : null;

  if (!kIsWeb &&
      path.isNotEmpty &&
      defaultTargetPlatform != TargetPlatform.android) {
    try {
      final file = io.File(path);
      if (await file.exists()) {
        final metadata = await MetadataRetriever.fromFile(file);
        final metadataTitle = (metadata.trackName ?? '').trim();
        if (metadataTitle.isNotEmpty) title = metadataTitle;
        final artists = (metadata.trackArtistNames ?? const <String>[])
            .where((value) => value.trim().isNotEmpty)
            .toList();
        if (artists.isEmpty && (metadata.authorName ?? '').trim().isNotEmpty) {
          artists.add(metadata.authorName!.trim());
        }
        if (artists.isNotEmpty) artist = artists.join(', ');
        final metadataAlbum = (metadata.albumName ?? '').trim();
        if (metadataAlbum.isNotEmpty) album = metadataAlbum;
        if ((metadata.trackDuration ?? 0) > 0) {
          duration = metadata.trackDuration!;
        }
        if (metadata.albumArt != null && metadata.albumArt!.isNotEmpty) {
          art = metadata.albumArt;
        }
        // Do not read the complete audio file during a bulk scan. Embedded
        // artwork and lyrics can be backfilled later in small batches.
        metadataReadSucceeded = true;
      }
    } catch (error) {
      debugPrint('Automatic metadata read failed for $sourceKey: $error');
    }
  }

  if (title.isEmpty || title == base && artist.isEmpty) {
    final guessed = _guessMetaFromName(base);
    if (title.isEmpty || title == base) title = guessed['title']!;
    if (artist.isEmpty) artist = guessed['artist']!;
  }

  final now = DateTime.now().millisecondsSinceEpoch;
  final id = (existing?['id'] ?? 'auto_${_fastId(sourceKey, 0)}').toString();
  final track = <String, dynamic>{
    'id': id,
    'source': 'auto',
    'path': path,
    'url': url,
    'name': name,
    'size': size,
    'title': title,
    'artist': artist,
    'album': album,
    'albumId': _numberFromData(fileData['albumId']),
    'duration': duration,
    'hasArtwork':
        existing?['hasArtwork'] == true || (art != null && art.isNotEmpty),
    'artChecked': metadataReadSucceeded,
    'lyrics': lyrics,
    'addedAt':
        existing?['addedAt'] ??
        (_numberFromData(fileData['addedAt']) > 0
            ? _numberFromData(fileData['addedAt'])
            : now),
    'modifiedAt': modifiedAt,
  };
  if (art != null && art.isNotEmpty) track['art'] = art;
  return track;
}

Future<void> _flushAutomaticTrackBatch(
  Map<String, Map<String, dynamic>> pending,
  Map<String, Map<String, dynamic>> sourceIndex,
) async {
  if (pending.isEmpty) return;
  await tracksBox!.putAll(pending);
  for (final track in pending.values) {
    final path = (track['path'] ?? '').toString();
    final url = (track['url'] ?? '').toString();
    if (path.isNotEmpty) sourceIndex[path] = track;
    if (url.isNotEmpty) sourceIndex[url] = track;
  }
  pending.clear();
}

bool _androidArtworkJobRunning = false;
List<Map<String, dynamic>> _androidArtworkPendingFiles = [];
Map<String, Map<String, dynamic>> _androidArtworkSourceIndex = {};
int _androidArtworkRequestGeneration = 0;

Uint8List? _safeArtworkBytes(dynamic value) {
  if (value is Uint8List) return value;
  if (value is! List) return null;
  final result = <int>[];
  for (final item in value) {
    if (item is! num || item < 0 || item > 255) return null;
    result.add(item.toInt());
  }
  return Uint8List.fromList(result);
}

Future<void> _loadMissingAndroidArtwork(
  List<Map<String, dynamic>> files,
  Map<String, Map<String, dynamic>> sourceIndex,
) async {
  if (files.isNotEmpty) {
    _androidArtworkPendingFiles = List<Map<String, dynamic>>.from(files);
    _androidArtworkSourceIndex = sourceIndex;
    _androidArtworkRequestGeneration++;
  }
  if (_androidArtworkJobRunning) return;
  _androidArtworkJobRunning = true;
  final jobGeneration = _androidArtworkRequestGeneration;
  var completedAllBatches = true;
  var restartWithPendingWork = false;
  try {
    final batchSize = libraryPerformance['artworkBatchSize'] as int;
    final pending = _androidArtworkPendingFiles.where((fileData) {
      final url = (fileData['url'] ?? '').toString();
      final track = _androidArtworkSourceIndex[url];
      return url.isNotEmpty &&
          track != null &&
          track['artChecked'] != true &&
          !artworkBytesCache.containsKey(track['id'].toString());
    }).toList();

    for (
      var offset = 0;
      offset < pending.length && backgroundMetadataWorkEnabled;
      offset += batchSize
    ) {
      final end = min(offset + batchSize, pending.length);
      final artworkResults = <String, Uint8List?>{};
      final resultSources = <String, String>{};
      for (final fileData in pending.sublist(offset, end)) {
        final url = (fileData['url'] ?? '').toString();
        final initial = _androidArtworkSourceIndex[url];
        if (initial == null) continue;
        final id = (initial['id'] ?? '').toString();
        if (id.isEmpty) continue;
        if (!_androidArtworkRequests.add(url)) continue;
        try {
          final response = await deviceMediaChannel.invokeMethod<dynamic>(
            'loadArtwork',
            <String, dynamic>{
              'url': url,
              'albumId': _numberFromData(fileData['albumId']),
            },
          );
          final bytes = _safeArtworkBytes(response);
          artworkResults[id] = bytes;
          resultSources[id] = url;
        } catch (error) {
          debugPrint('Android artwork load failed for $url: $error');
        } finally {
          _androidArtworkRequests.remove(url);
        }
      }
      final updates = <String, Map<String, dynamic>>{};
      final updatedSources = <String, Map<String, dynamic>>{};
      var currentChanged = false;
      for (final result in artworkResults.entries) {
        final latestRaw = tracksBox?.get(result.key);
        if (latestRaw is! Map) continue;
        final latest = Map<String, dynamic>.from(latestRaw);
        final updated = <String, dynamic>{...latest, 'artChecked': true};
        final artwork = result.value;
        if (latest['hasArtwork'] != true &&
            artwork != null &&
            artwork.isNotEmpty) {
          updated['art'] = artwork;
        }
        updates[result.key] = updated;
        final url = resultSources[result.key];
        if (url != null) updatedSources[url] = updated;
        if (currentId.value == result.key) currentChanged = true;
      }
      if (updates.isNotEmpty) {
        await tracksBox!.putAll(updates);
        _androidArtworkSourceIndex.addAll(updatedSources);
        _reloadTracks();
      }
      if (currentChanged) currentId.refresh();
      await Future<void>.delayed(
        Duration(milliseconds: libraryPerformance['eventLoopYieldMs'] as int),
      );
    }
    if (!backgroundMetadataWorkEnabled) completedAllBatches = false;
  } finally {
    _androidArtworkJobRunning = false;
    if (completedAllBatches &&
        jobGeneration == _androidArtworkRequestGeneration) {
      _androidArtworkPendingFiles = [];
      _androidArtworkSourceIndex = {};
    } else if (backgroundMetadataWorkEnabled &&
        _androidArtworkPendingFiles.isNotEmpty) {
      restartWithPendingWork = true;
    }
  }
  if (restartWithPendingWork) {
    await _loadMissingAndroidArtwork(
      _androidArtworkPendingFiles,
      _androidArtworkSourceIndex,
    );
  }
}

void scheduleAutomaticLibraryScan() {
  _automaticScanDebounce?.cancel();
  _automaticScanDebounce = Timer(
    Duration(milliseconds: libraryPerformance['resumeScanDebounceMs'] as int),
    () async {
      await runAutomaticLibraryMaintenance();
    },
  );
}

Future<void> _removeMissingAutomaticTracks(
  Set<String> scannedSources, {
  required bool androidScan,
  required List<String> successfullyScannedRoots,
}) async {
  final missingIds = <String>{};
  for (final raw in tracksBox?.values ?? const <dynamic>[]) {
    if (raw is! Map || (raw['source'] ?? '').toString() != 'auto') continue;
    final path = (raw['path'] ?? '').toString();
    final url = (raw['url'] ?? '').toString();
    final source = path.isNotEmpty ? path : url;
    if (source.isEmpty || scannedSources.contains(source)) continue;
    if (androidScan) {
      missingIds.add(raw['id'].toString());
      continue;
    }
    final controlled = successfullyScannedRoots.any(
      (root) => p.equals(root, source) || p.isWithin(root, source),
    );
    if (controlled) missingIds.add(raw['id'].toString());
  }
  if (missingIds.isNotEmpty) await deleteTracks(missingIds);
}

Future<void> scanMusicLibraryAutomatically({bool force = false}) async {
  if (kIsWeb || automaticScanInProgress) return;
  if (defaultTargetPlatform == TargetPlatform.iOS ||
      defaultTargetPlatform == TargetPlatform.fuchsia) {
    return;
  }
  final lastScan = _lastAutomaticScanAt;
  if (!force && lastScan != null) {
    final elapsed = DateTime.now().difference(lastScan).inMilliseconds;
    if (elapsed < (libraryPerformance['minimumScanIntervalMs'] as int)) return;
  }

  automaticScanInProgress = true;
  isScanningLibrary.value = true;
  scanErrorMessage.value = null;
  try {
    await ensureBoxes();
    final scannedSources = <String>{};
    final sourceIndex = _buildTrackSourceIndex();
    final successfullyScannedRoots = <String>[];
    final batchSize = libraryPerformance['scanBatchSize'] as int;
    var fullScanSucceeded = true;

    if (defaultTargetPlatform == TargetPlatform.android) {
      final rawFiles = await deviceMediaChannel.invokeListMethod<dynamic>(
        'scanAudio',
        <String, dynamic>{'extensions': List<String>.from(audioExt)},
      );
      final files = (rawFiles ?? const <dynamic>[])
          .whereType<Map>()
          .map((value) => Map<String, dynamic>.from(value))
          .toList();
      final pendingWrites = <String, Map<String, dynamic>>{};
      for (var index = 0; index < files.length; index++) {
        final file = files[index];
        final path = (file['path'] ?? '').toString();
        final url = (file['url'] ?? '').toString();
        final key = path.isNotEmpty ? path : url;
        if (key.isEmpty || !scannedSources.add(key)) continue;
        if (url.isNotEmpty) scannedSources.add(url);
        final track = await _prepareAutomaticTrack(file, sourceIndex);
        if (track != null) pendingWrites[track['id'].toString()] = track;
        if (pendingWrites.length >= batchSize) {
          await _flushAutomaticTrackBatch(pendingWrites, sourceIndex);
        }
        if ((index + 1) % batchSize == 0) {
          await Future<void>.delayed(
            Duration(
              milliseconds: libraryPerformance['eventLoopYieldMs'] as int,
            ),
          );
        }
      }
      await _flushAutomaticTrackBatch(pendingWrites, sourceIndex);
      await _removeMissingAutomaticTracks(
        scannedSources,
        androidScan: true,
        successfullyScannedRoots: const <String>[],
      );
      _reloadTracks();
      _androidArtworkPendingFiles = List<Map<String, dynamic>>.from(files);
      _androidArtworkSourceIndex = sourceIndex;
      _androidArtworkRequestGeneration++;
    } else {
      for (final directory in _automaticScanDirectories()) {
        if (!await directory.exists()) continue;
        var rootCompleted = true;
        var processed = 0;
        final pendingWrites = <String, Map<String, dynamic>>{};
        try {
          await for (final entity in directory.list(
            recursive: true,
            followLinks: false,
          )) {
            if (entity is! io.File || !_isAudio(entity.path)) continue;
            if (!scannedSources.add(entity.path)) continue;
            final stat = await entity.stat();
            final track = await _prepareAutomaticTrack(<String, dynamic>{
              'path': entity.path,
              'name': p.basename(entity.path),
              'size': stat.size,
              'modifiedAt': stat.modified.millisecondsSinceEpoch,
            }, sourceIndex);
            if (track != null) {
              pendingWrites[track['id'].toString()] = track;
            }
            processed++;
            if (pendingWrites.length >= batchSize) {
              await _flushAutomaticTrackBatch(pendingWrites, sourceIndex);
            }
            if (processed % batchSize == 0) {
              await Future<void>.delayed(
                Duration(
                  milliseconds: libraryPerformance['eventLoopYieldMs'] as int,
                ),
              );
            }
          }
          await _flushAutomaticTrackBatch(pendingWrites, sourceIndex);
        } catch (error) {
          pendingWrites.clear();
          rootCompleted = false;
          fullScanSucceeded = false;
          debugPrint('Automatic scan skipped ${directory.path}: $error');
        }
        if (rootCompleted) successfullyScannedRoots.add(directory.path);
      }
      if (fullScanSucceeded) {
        await _removeMissingAutomaticTracks(
          scannedSources,
          androidScan: false,
          successfullyScannedRoots: successfullyScannedRoots,
        );
      }
      _reloadTracks();
    }
    if (fullScanSucceeded) {
      _lastAutomaticScanAt = DateTime.now();
      final preferenceKey =
          libraryPerformance['lastSuccessfulScanPreference'] as String;
      await prefsBox?.put(
        preferenceKey,
        _lastAutomaticScanAt!.millisecondsSinceEpoch,
      );
    } else {
      scanErrorMessage.value = texts['scanFailed'];
    }
  } on PlatformException catch (error) {
    debugPrint('Automatic media scan failed: ${error.message}');
    scanErrorMessage.value = texts['scanFailed'];
  } catch (error) {
    debugPrint('Automatic media scan failed: $error');
    scanErrorMessage.value = texts['scanFailed'];
  } finally {
    isScanningLibrary.value = false;
    automaticScanInProgress = false;
  }
}

Future<void>? _automaticLibraryMaintenance;

Future<void> runAutomaticLibraryMaintenance({bool force = false}) {
  final active = _automaticLibraryMaintenance;
  if (active != null) return active;
  final task = _runAutomaticLibraryMaintenance(force: force);
  _automaticLibraryMaintenance = task;
  return task.whenComplete(() {
    if (identical(_automaticLibraryMaintenance, task)) {
      _automaticLibraryMaintenance = null;
    }
  });
}

Future<void> _runAutomaticLibraryMaintenance({required bool force}) async {
  await scanMusicLibraryAutomatically(force: force);
  if (!backgroundMetadataWorkEnabled || scanErrorMessage.value != null) return;
  if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
    if (_androidArtworkPendingFiles.isNotEmpty) {
      await _loadMissingAndroidArtwork(
        _androidArtworkPendingFiles,
        _androidArtworkSourceIndex,
      );
    }
    return;
  }
  await backfillMissingArtwork();
}

Future<Source?> _sourceFor(Map<String, dynamic> t) async {
  if (kIsWeb) {
    final id = (t['id'] ?? '').toString();
    final sessionBytes = webBytes[id];
    if (sessionBytes != null) return BytesSource(sessionBytes);
    var storedBytes = t['bytes'];
    if (storedBytes is! Uint8List || storedBytes.isEmpty) {
      storedBytes = await tracksBox!.loadTrackBytes(id);
    }
    if (storedBytes is Uint8List && storedBytes.isNotEmpty) {
      _cacheWebTrackBytes(id, storedBytes);
      return BytesSource(storedBytes);
    }
    final url = (t['url'] ?? '').toString();
    if (url.isNotEmpty) return UrlSource(url);
    return null;
  }

  final url = (t['url'] ?? '').toString();
  if (defaultTargetPlatform == TargetPlatform.android &&
      url.startsWith('content://')) {
    try {
      final cachedPath = await deviceMediaChannel
          .invokeMethod<String>('prepareAudioSource', <String, dynamic>{
            'url': url,
            'name': (t['name'] ?? '').toString(),
            'size': _numberFromData(t['size']),
            'modifiedAt': _numberFromData(t['modifiedAt']),
          });
      if (cachedPath != null && cachedPath.isNotEmpty) {
        return DeviceFileSource(cachedPath);
      }
    } catch (error) {
      debugPrint('Android audio source preparation failed: $error');
    }
    return null;
  }

  final path = (t['path'] ?? '').toString();
  if (path.isNotEmpty) return DeviceFileSource(path);

  if (url.startsWith('file://')) {
    try {
      final filePath = Uri.parse(
        url,
      ).toFilePath(windows: defaultTargetPlatform == TargetPlatform.windows);
      if (filePath.isNotEmpty) return DeviceFileSource(filePath);
    } catch (_) {}
  }
  if (url.isNotEmpty) return UrlSource(url);

  return null;
}

Future<void> playById(String id, {int? queuePosition}) async {
  final request = ++_playbackRequestGeneration;
  final task = _playbackCommandChain
      .catchError((Object _) {})
      .then((_) => _performPlayById(id, request, queuePosition));
  _playbackCommandChain = task;
  await task;
}

Future<void> _performPlayById(
  String id,
  int request,
  int? queuePosition,
) async {
  if (request != _playbackRequestGeneration) return;
  await ensureBoxes();
  await ensureAudio();
  if (!kIsWeb &&
      defaultTargetPlatform == TargetPlatform.android &&
      !_notificationPermissionRequestedThisSession) {
    _notificationPermissionRequestedThisSession = true;
    try {
      await deviceMediaChannel.invokeMethod<bool>(
        'requestNotificationPermission',
      );
    } catch (error) {
      debugPrint('Notification permission request failed: $error');
    }
  }
  try {
    await ensureAudioService();
  } catch (error) {
    debugPrint('Audio service retry failed: $error');
  }
  if (request != _playbackRequestGeneration) return;

  final raw = tracksBox!.get(id);
  final Map<String, dynamic>? t = raw is Map
      ? Map<String, dynamic>.from(raw)
      : null;
  if (t == null) return;

  final src = await _sourceFor(t);
  if (src == null) return;
  if (request != _playbackRequestGeneration) return;

  try {
    await audio.stop();
    if (request != _playbackRequestGeneration) return;
    currentId.value = id;
    positionMs.value = 0;
    durationMs.value = _numberFromData(t['duration']);
    _activeQueuePosition =
        queuePosition != null &&
            queuePosition >= 0 &&
            queuePosition < queueIds.value.length &&
            queueIds.value[queuePosition] == id
        ? queuePosition
        : -1;
    final handler = audioHandler;
    if (handler is AppAudioHandler) {
      handler.publishLoading(
        MediaItem(
          id: id,
          title: (t['title'] ?? '').toString(),
          artist: (t['artist'] ?? '').toString().trim().isEmpty
              ? texts['unknown']!
              : t['artist'].toString(),
          duration: _numberFromData(t['duration']) > 0
              ? Duration(milliseconds: _numberFromData(t['duration']))
              : null,
        ),
      );
    }
    await audio.play(src);
    if (request != _playbackRequestGeneration) return;
    await prefsBox?.put('lastPlayedId', id);
    unawaited(_backfillLyricsForTrack(id));
    unawaited(_ensureTrackArtworkLoaded(id));
  } catch (e) {
    debugPrint('playById error: $e');
    if (request == _playbackRequestGeneration) {
      _publishFinalStoppedState(clearCurrent: true);
      await _performFinalStop(request, true);
    }
  }
}

Future<void> resumePlayback() async {
  await ensureAudio();
  if (audio.state == PlayerState.playing) return;

  if (audio.state == PlayerState.paused) {
    try {
      await audio.resume();
    } catch (error) {
      debugPrint('Audio resume failed: $error');
      await stopPlaybackSession();
    }
    return;
  }

  final id = currentId.value;
  if (id != null) {
    await playById(id);
    return;
  }

  if (tracksList.value.isNotEmpty) {
    await playById(tracksList.value.first['id'] as String);
  }
}

Future<void> togglePlay() async {
  await ensureAudio();
  if (audio.state == PlayerState.playing) {
    await audio.pause();
  } else {
    await resumePlayback();
  }
}

Future<void> seekToFraction(double f) async {
  final d = durationMs.value;
  if (d <= 0) return;
  final pos = (d * f).round();
  await audio.seek(Duration(milliseconds: pos));
}

Future<void> playNext({bool completed = false}) async {
  final q = queueIds.value;
  final pool = q.isNotEmpty
      ? q
      : tracksList.value.map((e) => e['id'] as String).toList();
  if (pool.isEmpty) return;

  final cur = currentId.value;
  final mode = playbackMode.value;

  if (mode == 'shuffle') {
    if (pool.length == 1 && cur != null && pool.first == cur) {
      if (completed) {
        await stopPlaybackSession();
        return;
      }
      await playById(pool.first, queuePosition: q.isNotEmpty ? 0 : null);
      return;
    }
    var nextIndex = -1;
    final rng = Random();
    for (var k = 0; k < 7; k++) {
      final candidate = rng.nextInt(pool.length);
      if (pool[candidate] != cur || pool.length == 1) {
        nextIndex = candidate;
        break;
      }
    }
    nextIndex = nextIndex < 0 ? 0 : nextIndex;
    await playById(
      pool[nextIndex],
      queuePosition: q.isNotEmpty ? nextIndex : null,
    );
    return;
  }

  final queueActive =
      q.isNotEmpty &&
      _activeQueuePosition >= 0 &&
      _activeQueuePosition < q.length &&
      q[_activeQueuePosition] == cur;
  int i = queueActive
      ? _activeQueuePosition
      : cur == null
      ? -1
      : pool.indexOf(cur);
  final isLast = i >= 0 && i == pool.length - 1;

  if (isLast && completed && mode == 'order') {
    await stopPlaybackSession();
    return;
  }

  final nextIndex = (i + 1) % pool.length;
  final nextId = pool[nextIndex];
  await playById(nextId, queuePosition: q.isNotEmpty ? nextIndex : null);
}

Future<void> playPrev() async {
  final q = queueIds.value;
  final pool = q.isNotEmpty
      ? q
      : tracksList.value.map((e) => e['id'] as String).toList();
  if (pool.isEmpty) return;

  final cur = currentId.value;
  final mode = playbackMode.value;

  if (mode == 'shuffle') {
    if (pool.length == 1) {
      await playById(pool.first, queuePosition: q.isNotEmpty ? 0 : null);
      return;
    }
    var previousIndex = -1;
    final rng = Random();
    for (var k = 0; k < 7; k++) {
      final candidate = rng.nextInt(pool.length);
      if (pool[candidate] != cur) {
        previousIndex = candidate;
        break;
      }
    }
    previousIndex = previousIndex < 0 ? 0 : previousIndex;
    await playById(
      pool[previousIndex],
      queuePosition: q.isNotEmpty ? previousIndex : null,
    );
    return;
  }

  final queueActive =
      q.isNotEmpty &&
      _activeQueuePosition >= 0 &&
      _activeQueuePosition < q.length &&
      q[_activeQueuePosition] == cur;
  final currentIndex = queueActive
      ? _activeQueuePosition
      : cur == null
      ? -1
      : pool.indexOf(cur);
  final prevId = currentIndex < 0
      ? pool.last
      : pool[(currentIndex - 1 + pool.length) % pool.length];
  final previousIndex = currentIndex < 0
      ? pool.length - 1
      : (currentIndex - 1 + pool.length) % pool.length;
  await playById(prevId, queuePosition: q.isNotEmpty ? previousIndex : null);
}

Map<String, String> _guessMetaFromName(String base) {
  var s = base.replaceAll('_', ' ').trim();
  for (final d in [' - ', ' – ', ' — ']) {
    if (s.contains(d)) {
      final parts = s.split(d);
      final artist = parts.first.trim();
      final title = parts.sublist(1).join(d).trim();
      if (artist.isNotEmpty && title.isNotEmpty) {
        return {'artist': artist, 'title': title};
      }
    }
  }
  return {'artist': '', 'title': s};
}

void _reloadPlaylists() {
  final List<Map<String, dynamic>> all = <Map<String, dynamic>>[
    for (final value in playlistsBox?.values ?? const <dynamic>[])
      if (value is Map) Map<String, dynamic>.from(value),
  ];
  all.sort(
    (Map<String, dynamic> a, Map<String, dynamic> b) => _numberFromData(
      b['createdAt'],
    ).compareTo(_numberFromData(a['createdAt'])),
  );
  playlistsList.value = all;
  final selectedPlaylist = currentPlaylistId.value;
  if (selectedPlaylist != null &&
      !all.any((playlist) => playlist['id'] == selectedPlaylist)) {
    currentPlaylistId.value = null;
    pageHistory.removeWhere((page) => page == 'playlist');
  }
}

Future<String?> createPlaylist(String name) async {
  final trimmed = name.trim();
  if (trimmed.isEmpty) return null;
  await ensureBoxes();
  final id = 'pl_${_fastId(trimmed, DateTime.now().millisecondsSinceEpoch)}';
  final pl = <String, dynamic>{
    'id': id,
    'name': trimmed,
    'trackIds': <String>[],
    'createdAt': DateTime.now().millisecondsSinceEpoch,
  };
  await playlistsBox!.put(id, pl);
  _reloadPlaylists();
  return id;
}

Future<void> addTrackToPlaylist(String playlistId, String trackId) async {
  await ensureBoxes();
  final raw = playlistsBox!.get(playlistId);
  final Map<String, dynamic>? pl = raw is Map
      ? Map<String, dynamic>.from(raw)
      : null;
  if (pl == null) return;

  final List<dynamic> idsDyn = (pl['trackIds'] ?? <dynamic>[]) as List<dynamic>;
  final ids = idsDyn.map((e) => e.toString()).toList();
  if (!ids.contains(trackId)) ids.add(trackId);

  pl['trackIds'] = ids;
  await playlistsBox!.put(playlistId, pl);
  _reloadPlaylists();
}

Future<void> removeTrackFromPlaylist(String playlistId, String trackId) async {
  await ensureBoxes();
  final raw = playlistsBox!.get(playlistId);
  final Map<String, dynamic>? pl = raw is Map
      ? Map<String, dynamic>.from(raw)
      : null;
  if (pl == null) return;

  final List<dynamic> idsDyn = (pl['trackIds'] ?? <dynamic>[]) as List<dynamic>;
  final ids = idsDyn.map((e) => e.toString()).toList()..remove(trackId);

  pl['trackIds'] = ids;
  await playlistsBox!.put(playlistId, pl);
  _reloadPlaylists();
}

void openAddToPlaylistSheet(BuildContext ctx, double el, String trackId) {
  showModalBottomSheet(
    context: ctx,
    backgroundColor: Colors.transparent,
    builder: (_) => Padding(
      padding: EdgeInsets.all(el * 1.2),
      child: glass(
        SizedBox(
          height:
              MediaQuery.sizeOf(ctx).height *
              (responsiveLayout['sheetMaxHeightFactor'] as double),
          child: ValueListenableBuilder<List<Map<String, dynamic>>>(
            valueListenable: playlistsList,
            builder: (_, pls, __) {
              return Column(
                children: [
                  ListTile(
                    leading: Icon(
                      iconsMap['playlistAdd']!,
                      color: colors['text'],
                    ),
                    title: Text(
                      texts['newPlaylist']!,
                      style: TextStyle(color: colors['text']),
                    ),
                    onTap: () async {
                      Navigator.pop(ctx);
                      await openCreatePlaylistDialog(ctx, el, trackId);
                    },
                  ),
                  Expanded(
                    child: pls.isEmpty
                        ? Center(
                            child: Text(
                              texts['emptyPlaylists']!,
                              style: TextStyle(
                                color: colors['textDim'],
                                fontSize: el * 1.05,
                              ),
                            ),
                          )
                        : ListView.builder(
                            itemCount: pls.length,
                            itemBuilder: (_, index) {
                              final pl = pls[index];
                              return ListTile(
                                leading: Icon(
                                  iconsMap['playlist']!,
                                  color: colors['text'],
                                ),
                                title: Text(
                                  pl['name'] ?? '',
                                  style: TextStyle(color: colors['text']),
                                ),
                                trailing: Text(
                                  ((pl['trackIds'] ?? const <dynamic>[]).length)
                                      .toString(),
                                  style: TextStyle(color: colors['textDim']),
                                ),
                                onTap: () async {
                                  await addTrackToPlaylist(
                                    pl['id'] as String,
                                    trackId,
                                  );
                                  if (ctx.mounted) Navigator.pop(ctx);
                                },
                              );
                            },
                          ),
                  ),
                ],
              );
            },
          ),
        ),
        el,
      ),
    ),
  );
}

Future<void> openCreatePlaylistDialog(
  BuildContext ctx,
  double el,
  String? addTrackIdAfter,
) async {
  final c = TextEditingController();
  final ok = await showDialog<bool>(
    context: ctx,
    builder: (_) => AlertDialog(
      contentPadding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            texts['playlistName']!,
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 12),
          TextField(controller: c, autofocus: true),
          const SizedBox(height: 8),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: Text(texts['cancel']!),
        ),
        TextButton(
          onPressed: () => Navigator.pop(ctx, true),
          child: Text(texts['create']!),
        ),
      ],
    ),
  );

  final name = c.text;
  c.dispose();
  if (ok != true) return;
  final id = await createPlaylist(name);
  if (id == null) {
    if (ctx.mounted) {
      ScaffoldMessenger.of(
        ctx,
      ).showSnackBar(SnackBar(content: Text(texts['emptyPlaylistName']!)));
    }
    return;
  }
  if (addTrackIdAfter != null) {
    await addTrackToPlaylist(id, addTrackIdAfter);
  }
}

Widget playlistsView(double el) {
  return ValueListenableBuilder<List<Map<String, dynamic>>>(
    valueListenable: playlistsList,
    builder: (context, pls, _) {
      return Column(
        children: [
          Align(
            alignment: Alignment.centerRight,
            child: FilledButton.icon(
              onPressed: () => openCreatePlaylistDialog(context, el, null),
              icon: Icon(iconsMap['playlistAdd']),
              label: Text(texts['createPlaylist']!),
            ),
          ),
          SizedBox(height: el * .6),
          Expanded(
            child: pls.isEmpty
                ? Center(
                    child: Text(
                      texts['emptyPlaylists']!,
                      style: TextStyle(
                        color: colors['textDim'],
                        fontSize: el * 1.05,
                      ),
                    ),
                  )
                : ListView.separated(
                    itemCount: pls.length,
                    separatorBuilder: (_, __) => SizedBox(height: el * .6),
                    itemBuilder: (ctx, i) {
                      final p = pls[i];
                      final count = (p['trackIds'] ?? const <dynamic>[]).length;
                      return InkWell(
                        onTap: () => openPlaylist(p['id'] as String),
                        borderRadius: BorderRadius.circular(el),
                        child: Padding(
                          padding: EdgeInsets.all(el * .6),
                          child: Row(
                            children: [
                              Icon(iconsMap['playlist'], color: colors['text']),
                              SizedBox(width: el),
                              Expanded(
                                child: Text(
                                  p['name'] ?? '',
                                  style: TextStyle(
                                    color: colors['text'],
                                    fontSize: el * 1.05,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                              Text(
                                '$count',
                                style: TextStyle(
                                  color: colors['textDim'],
                                  fontSize: el,
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      );
    },
  );
}

Widget playlistView(double el) {
  return ValueListenableBuilder<String?>(
    valueListenable: currentPlaylistId,
    builder: (ctx, id, __) {
      return ValueListenableBuilder<List<Map<String, dynamic>>>(
        valueListenable: playlistsList,
        builder: (_, playlists, ___) {
          if (id == null) {
            return Center(
              child: Text(
                texts['emptyPlaylists']!,
                style: TextStyle(color: colors['textDim']),
              ),
            );
          }

          final raw = playlistsBox?.get(id);
          final Map<String, dynamic>? pl = raw is Map
              ? Map<String, dynamic>.from(raw)
              : null;
          if (pl == null) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (currentPlaylistId.value == id) {
                currentPlaylistId.value = null;
                pageHistory.removeWhere((page) => page == 'playlist');
                if (currentPage.value == 'playlist') replacePage('playlists');
              }
            });
            return Center(
              child: Text(
                texts['emptyPlaylists']!,
                style: TextStyle(color: colors['textDim']),
              ),
            );
          }

          final ids = ((pl['trackIds'] ?? const <dynamic>[]) as List)
              .map((e) => e.toString())
              .toList();
          final tracksById = <String, Map<String, dynamic>>{
            for (final track in tracksList.value) track['id'].toString(): track,
          };
          final list = ids
              .map((tid) => tracksById[tid])
              .whereType<Map<String, dynamic>>()
              .toList();

          if (list.isEmpty) {
            return Center(
              child: Text(
                texts['noTracks']!,
                style: TextStyle(color: colors['textDim']),
              ),
            );
          }

          return ReorderableListView.builder(
            buildDefaultDragHandles: false,
            itemCount: list.length,
            onReorderItem: (oldIndex, newIndex) async {
              await reorderPlaylist(id, oldIndex, newIndex);
            },

            itemBuilder: (ctx2, i) {
              final t = list[i];
              final artist = (t['artist'] ?? '').toString().trim();
              final int dur = _numberFromData(t['duration']);
              final String meta =
                  '${artist.isEmpty ? texts['unknown']! : artist}'
                  '${dur > 0 ? ' • ${formatMs(dur)}' : ''}';

              return Container(
                key: ValueKey('playlist_${id}_${t['id']}'),
                padding: EdgeInsets.all(el * .6),
                child: Row(
                  children: [
                    ReorderableDragStartListener(
                      index: i,
                      child: Icon(iconsMap['drag']!, color: colors['textDim']),
                    ),
                    SizedBox(width: el),
                    artThumb(t, el),
                    SizedBox(width: el),
                    Expanded(
                      child: InkWell(
                        onTap: () => playSelectedTrack(ctx2, t['id'] as String),
                        onLongPress: () =>
                            removeTrackFromPlaylist(id, t['id'] as String),
                        borderRadius: BorderRadius.circular(el),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              t['title'] ?? '',
                              style: TextStyle(
                                color: colors['text'],
                                fontSize: el * 1.05,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            SizedBox(height: el * .2),
                            Text(
                              meta,
                              style: TextStyle(
                                color: colors['textDim'],
                                fontSize: el,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ),
                      ),
                    ),
                    IconButton(
                      onPressed: () =>
                          removeTrackFromPlaylist(id, t['id'] as String),
                      icon: Icon(iconsMap['remove']!, color: colors['text']),
                    ),
                  ],
                ),
              );
            },
          );
        },
      );
    },
  );
}

Future<void> reorderPlaylist(
  String playlistId,
  int oldIndex,
  int newIndex,
) async {
  await ensureBoxes();
  final raw = playlistsBox!.get(playlistId);
  final Map<String, dynamic>? pl = raw is Map
      ? Map<String, dynamic>.from(raw)
      : null;
  if (pl == null) return;

  final ids = ((pl['trackIds'] ?? const <dynamic>[]) as List)
      .map((e) => e.toString())
      .toList();

  if (oldIndex < 0 || oldIndex >= ids.length) return;
  if (newIndex < 0 || newIndex >= ids.length) return;

  final moved = ids.removeAt(oldIndex);
  ids.insert(newIndex, moved);

  pl['trackIds'] = ids;
  await playlistsBox!.put(playlistId, pl);
  _reloadPlaylists();
}

final queueIds = ValueNotifier<List<String>>([]);
void _saveQueue() {
  final saver = libraryQueueSaver;
  if (saver == null) return;
  final snapshot = List<String>.from(queueIds.value);
  libraryQueueWriteChain = libraryQueueWriteChain
      .catchError((Object _) {})
      .then((_) async {
        await saver(snapshot);
        libraryOperationErrorMessage.value = null;
      })
      .catchError((Object error) {
        debugPrint('Queue save failed: $error');
        libraryOperationErrorMessage.value =
            '${texts['queueSaveFailed']}: $error';
      });
}

void clearQueue() {
  queueIds.value = [];
  _activeQueuePosition = -1;
  _saveQueue();
}

void enqueueEnd(String id) {
  final q = [...queueIds.value];
  q.add(id);
  queueIds.value = q;
  _saveQueue();
}

void enqueueNext(String id) {
  final q = [...queueIds.value];
  final cur = currentId.value;
  final insertAt = _activeQueuePosition >= 0 && _activeQueuePosition < q.length
      ? _activeQueuePosition + 1
      : cur == null
      ? 0
      : (q.indexOf(cur) + 1).clamp(0, q.length);
  q.insert(insertAt, id);
  if (_activeQueuePosition >= insertAt) _activeQueuePosition++;
  queueIds.value = q;
  _saveQueue();
}

void removeQueueItemAt(int index) {
  final queue = List<String>.from(queueIds.value);
  if (index < 0 || index >= queue.length) return;
  queue.removeAt(index);
  if (_activeQueuePosition == index) {
    _activeQueuePosition = -1;
  } else if (_activeQueuePosition > index) {
    _activeQueuePosition--;
  }
  queueIds.value = queue;
  _saveQueue();
}

Widget queueView(double el) {
  return ValueListenableBuilder<List<String>>(
    valueListenable: queueIds,
    builder: (ctx, q, __) {
      if (q.isEmpty) {
        return Center(
          child: Text(
            texts['emptyQueue']!,
            style: TextStyle(color: colors['textDim'], fontSize: el * 1.05),
          ),
        );
      }

      final tracksById = <String, Map<String, dynamic>>{
        for (final track in tracksList.value) track['id'].toString(): track,
      };
      final items = <Map<String, dynamic>>[
        for (final id in q)
          tracksById[id] ??
              <String, dynamic>{
                'id': id,
                'title': texts['unknown'],
                'artist': texts['unknown'],
              },
      ];
      final occurrenceCounts = <String, int>{};
      final itemKeys = <String>[
        for (final id in q)
          'queue_${id}_${occurrenceCounts.update(id, (value) => value + 1, ifAbsent: () => 0)}',
      ];

      return ReorderableListView.builder(
        buildDefaultDragHandles: false,
        itemCount: items.length,
        onReorderItem: (oldIndex, newIndex) {
          reorderQueue(oldIndex, newIndex);
        },
        itemBuilder: (ctx2, i) {
          final t = items[i];
          final artist = (t['artist'] ?? '').toString().trim();
          final int dur = _numberFromData(t['duration']);
          final String meta =
              '${artist.isEmpty ? texts['unknown']! : artist}'
              '${dur > 0 ? ' • ${formatMs(dur)}' : ''}';

          return Padding(
            key: ValueKey(itemKeys[i]),
            padding: EdgeInsets.all(el * .6),
            child: Row(
              children: [
                ReorderableDragStartListener(
                  index: i,
                  child: Icon(iconsMap['drag']!, color: colors['textDim']),
                ),
                SizedBox(width: el),
                artThumb(t, el),
                SizedBox(width: el),
                Expanded(
                  child: InkWell(
                    onTap: () => playSelectedTrack(
                      ctx2,
                      t['id'] as String,
                      queuePosition: i,
                    ),
                    onLongPress: () => removeQueueItemAt(i),
                    borderRadius: BorderRadius.circular(el),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          t['title'] ?? '',
                          style: TextStyle(
                            color: colors['text'],
                            fontSize: el * 1.05,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        SizedBox(height: el * .2),
                        Text(
                          meta,
                          style: TextStyle(
                            color: colors['textDim'],
                            fontSize: el,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                ),
                IconButton(
                  onPressed: () => removeQueueItemAt(i),
                  icon: Icon(iconsMap['remove']!, color: colors['text']),
                ),
              ],
            ),
          );
        },
      );
    },
  );
}

Future<void> deleteTracks(Set<String> ids) async {
  if (ids.isEmpty) return;
  await ensureBoxes();
  if (currentId.value != null && ids.contains(currentId.value)) {
    await stopPlaybackSession();
  }
  await libraryQueueWriteChain.catchError((Object _) {});
  final remainingQueue = queueIds.value
      .where((trackId) => !ids.contains(trackId))
      .toList();
  if (_activeQueuePosition >= 0 &&
      _activeQueuePosition < queueIds.value.length) {
    final activeId = queueIds.value[_activeQueuePosition];
    _activeQueuePosition = ids.contains(activeId)
        ? -1
        : queueIds.value
              .take(_activeQueuePosition)
              .where((trackId) => !ids.contains(trackId))
              .length;
  }
  late final Set<String> affectedPlaylists;
  try {
    affectedPlaylists = await tracksBox.deleteTracksAndReferences(
      ids,
      remainingQueue,
    );
  } catch (error) {
    debugPrint('Track deletion failed: $error');
    libraryOperationErrorMessage.value =
        '${texts['deleteTracksFailed']}: $error';
    rethrow;
  }
  libraryOperationErrorMessage.value = null;
  playlistsBox?.removeTrackReferencesFromCache(ids, affectedPlaylists);
  queueIds.value = remainingQueue;
  for (final id in ids) {
    webBytes.remove(id);
    removeCachedTrackArtwork(id);
  }
  _reloadTracks();
  _reloadPlaylists();
}

Future<void> deleteTrack(String id) => deleteTracks(<String>{id});

void reorderQueue(int oldIndex, int newIndex) {
  final q = [...queueIds.value];
  final item = q.removeAt(oldIndex);
  q.insert(newIndex, item);
  if (_activeQueuePosition == oldIndex) {
    _activeQueuePosition = newIndex;
  } else if (oldIndex < _activeQueuePosition &&
      newIndex >= _activeQueuePosition) {
    _activeQueuePosition--;
  } else if (oldIndex > _activeQueuePosition &&
      newIndex <= _activeQueuePosition) {
    _activeQueuePosition++;
  }
  queueIds.value = q;
  _saveQueue();
}

void openTrackActions(BuildContext ctx, double el, String trackId) {
  showModalBottomSheet(
    context: ctx,
    backgroundColor: Colors.transparent,
    builder: (_) => Padding(
      padding: EdgeInsets.all(el * 1.2),
      child: glass(
        Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: Icon(iconsMap['playlistPlay'], color: colors['text']),
              title: Text(
                texts['playNext']!,
                style: TextStyle(color: colors['text']),
              ),
              onTap: () {
                Navigator.pop(ctx);
                enqueueNext(trackId);
              },
            ),
            ListTile(
              leading: Icon(iconsMap['playlist'], color: colors['text']),
              title: Text(
                texts['addToQueue']!,
                style: TextStyle(color: colors['text']),
              ),
              onTap: () {
                Navigator.pop(ctx);
                enqueueEnd(trackId);
              },
            ),
            ListTile(
              leading: Icon(iconsMap['playlistAdd'], color: colors['text']),
              title: Text(
                texts['addToPlaylist']!,
                style: TextStyle(color: colors['text']),
              ),
              onTap: () {
                Navigator.pop(ctx);
                openAddToPlaylistSheet(ctx, el, trackId);
              },
            ),
            ListTile(
              leading: Icon(iconsMap['info'], color: colors['text']),
              title: Text(
                texts['trackInformation']!,
                style: TextStyle(color: colors['text']),
              ),
              onTap: () {
                Navigator.pop(ctx);
                openTrackInfoDialog(ctx, el, trackId);
              },
            ),
            ListTile(
              leading: Icon(iconsMap['delete']!, color: colors['text']),
              title: Text(
                texts['deleteFromLibrary']!,
                style: TextStyle(color: colors['text']),
              ),
              onTap: () async {
                Navigator.pop(ctx);
                final ok = await showDialog<bool>(
                  context: ctx,
                  builder: (_) => AlertDialog(
                    content: Text(texts['confirmDeleteTrack']!),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(ctx, false),
                        child: Text(texts['cancel']!),
                      ),
                      TextButton(
                        onPressed: () => Navigator.pop(ctx, true),
                        child: Text(texts['delete']!),
                      ),
                    ],
                  ),
                );
                if (ok == true) {
                  await deleteTrack(trackId);
                }
              },
            ),
          ],
        ),
        el,
      ),
    ),
  );
}

Future<void> enqueueListEnd(List<String> ids) async {
  final q = [...queueIds.value, ...ids];
  queueIds.value = q;
  _saveQueue();
}

Future<void> playListFromStart(List<String> ids) async {
  if (ids.isEmpty) return;
  queueIds.value = [...ids];
  _saveQueue();
  await playById(ids.first, queuePosition: 0);
}

Future<void> renamePlaylist(String id, String newName) async {
  final trimmed = newName.trim();
  if (trimmed.isEmpty) return;
  await ensureBoxes();
  final raw = playlistsBox!.get(id);
  final Map<String, dynamic>? pl = raw is Map
      ? Map<String, dynamic>.from(raw)
      : null;
  if (pl == null) return;
  pl['name'] = trimmed;
  await playlistsBox!.put(id, pl);
  _reloadPlaylists();
}

Future<void> deletePlaylist(String id) async {
  await ensureBoxes();
  await playlistsBox!.delete(id);
  if (currentPlaylistId.value == id) currentPlaylistId.value = null;
  pageHistory.removeWhere((page) => page == 'playlist');
  _reloadPlaylists();
  replacePage('playlists');
}

void openPlaylistActions(BuildContext ctx, double el, String playlistId) {
  final raw = playlistsBox?.get(playlistId);
  final Map<String, dynamic>? pl = raw is Map
      ? Map<String, dynamic>.from(raw)
      : null;
  final ids = ((pl?['trackIds'] ?? const <dynamic>[]) as List)
      .map((e) => e.toString())
      .toList();

  showModalBottomSheet(
    context: ctx,
    backgroundColor: Colors.transparent,
    builder: (_) => Padding(
      padding: EdgeInsets.all(el * 1.2),
      child: glass(
        Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: Icon(iconsMap['playFilled']!, color: colors['text']),
              title: Text(
                texts['playAll']!,
                style: TextStyle(color: colors['text']),
              ),
              onTap: () {
                Navigator.pop(ctx);
                playListFromStart(ids);
              },
            ),
            ListTile(
              leading: Icon(iconsMap['playlist'], color: colors['text']),
              title: Text(
                texts['addAllToQueue']!,
                style: TextStyle(color: colors['text']),
              ),
              onTap: () {
                Navigator.pop(ctx);
                enqueueListEnd(ids);
              },
            ),
            ListTile(
              leading: Icon(iconsMap['rename']!, color: colors['text']),
              title: Text(
                texts['rename']!,
                style: TextStyle(color: colors['text']),
              ),
              onTap: () async {
                Navigator.pop(ctx);
                final c = TextEditingController(
                  text: (pl?['name'] ?? '').toString(),
                );
                final ok = await showDialog<bool>(
                  context: ctx,
                  builder: (_) => AlertDialog(
                    contentPadding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                    content: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          texts['rename']!,
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                        const SizedBox(height: 12),
                        TextField(controller: c, autofocus: true),
                        const SizedBox(height: 8),
                      ],
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(ctx, false),
                        child: Text(texts['cancel']!),
                      ),
                      TextButton(
                        onPressed: () => Navigator.pop(ctx, true),
                        child: Text(texts['rename']!),
                      ),
                    ],
                  ),
                );
                final name = c.text.trim();
                c.dispose();
                if (ok == true && name.isNotEmpty) {
                  await renamePlaylist(playlistId, name);
                } else if (ok == true && ctx.mounted) {
                  ScaffoldMessenger.of(ctx).showSnackBar(
                    SnackBar(content: Text(texts['emptyPlaylistName']!)),
                  );
                }
              },
            ),
            ListTile(
              leading: Icon(iconsMap['delete']!, color: colors['text']),
              title: Text(
                texts['delete']!,
                style: TextStyle(color: colors['text']),
              ),
              onTap: () async {
                Navigator.pop(ctx);
                final ok = await showDialog<bool>(
                  context: ctx,
                  builder: (_) => AlertDialog(
                    content: Text(texts['confirmDelete']!),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(ctx, false),
                        child: Text(texts['cancel']!),
                      ),
                      TextButton(
                        onPressed: () => Navigator.pop(ctx, true),
                        child: Text(texts['delete']!),
                      ),
                    ],
                  ),
                );
                if (ok == true) await deletePlaylist(playlistId);
              },
            ),
          ],
        ),
        el,
      ),
    ),
  );
}

void cyclePlaybackMode() {
  final current = playbackMode.value;
  final i = playbackModes.indexOf(current);
  final nextIndex = (i + 1) % playbackModes.length;
  final next = playbackModes[nextIndex];
  setPlayMode(next);
}

class MusicTimelineVisualizer extends StatefulWidget {
  const MusicTimelineVisualizer({required this.el, super.key});

  final double el;

  @override
  State<MusicTimelineVisualizer> createState() =>
      _MusicTimelineVisualizerState();
}

class _MusicTimelineVisualizerState extends State<MusicTimelineVisualizer>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ticker;
  DateTime _positionTime = DateTime.now();
  int _positionAnchorMs = 0;

  @override
  void initState() {
    super.initState();
    _ticker = AnimationController(
      vsync: this,
      duration: Duration(
        milliseconds: musicVisualizerSettings['tickerDurationMs'] as int,
      ),
    );
    _positionAnchorMs = positionMs.value;
    positionMs.addListener(_syncPosition);
    isPlaying.addListener(_syncPlayback);
    _syncPlayback();
  }

  void _syncPosition() {
    _positionAnchorMs = positionMs.value;
    _positionTime = DateTime.now();
    if (mounted && !isPlaying.value) setState(() {});
  }

  void _syncPlayback() {
    _positionAnchorMs = positionMs.value;
    _positionTime = DateTime.now();
    if (isPlaying.value) {
      if (!_ticker.isAnimating) _ticker.repeat();
    } else {
      _ticker.stop();
      if (mounted) setState(() {});
    }
  }

  int get _visualPositionMs {
    if (!isPlaying.value) return _positionAnchorMs;
    return _positionAnchorMs +
        DateTime.now().difference(_positionTime).inMilliseconds;
  }

  @override
  void dispose() {
    positionMs.removeListener(_syncPosition);
    isPlaying.removeListener(_syncPlayback);
    _ticker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final height =
        widget.el * (musicVisualizerSettings['heightFactor'] as double);
    return RepaintBoundary(
      child: AnimatedBuilder(
        animation: _ticker,
        builder: (context, _) {
          final seconds = _visualPositionMs / 1000.0;
          final speed = musicVisualizerSettings['speed'] as double;
          final secondarySpeed =
              musicVisualizerSettings['secondarySpeed'] as double;
          final minimum =
              musicVisualizerSettings['minimumHeightFactor'] as double;
          return Container(
            height: height,
            padding: EdgeInsets.symmetric(
              horizontal:
                  widget.el *
                  (musicVisualizerSettings['horizontalPaddingFactor']
                      as double),
              vertical:
                  widget.el *
                  (musicVisualizerSettings['verticalPaddingFactor'] as double),
            ),
            decoration: BoxDecoration(
              color: colors['accentDim'],
              borderRadius: BorderRadius.circular(widget.el),
              border: Border.all(color: colors['glassBorder']!),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                for (
                  var index = 0;
                  index < musicVisualizerBarPattern.length;
                  index++
                )
                  Expanded(
                    child: Align(
                      alignment: Alignment.bottomCenter,
                      child: FractionallySizedBox(
                        heightFactor:
                            (minimum +
                                    (1 - minimum) *
                                        musicVisualizerBarPattern[index] *
                                        (0.55 +
                                            0.27 *
                                                sin(
                                                  seconds * speed +
                                                      index * 0.83,
                                                ) +
                                            0.18 *
                                                sin(
                                                  seconds * secondarySpeed +
                                                      index * 1.37,
                                                )))
                                .clamp(minimum, 1.0),
                        widthFactor: 0.56,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: Color.lerp(
                              colors['accent'],
                              colors['text'],
                              0.28,
                            ),
                            borderRadius: BorderRadius.circular(
                              widget.el *
                                  (musicVisualizerSettings['cornerRadiusFactor']
                                      as double),
                            ),
                          ),
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
  }
}

Widget nowPlayingView(
  double el, {
  bool embedded = false,
  VoidCallback? onClose,
  VoidCallback? onExpand,
}) => _PersistentNowPlayingView(
  el: el,
  embedded: embedded,
  onClose: onClose,
  onExpand: onExpand,
);

class _PersistentNowPlayingView extends StatefulWidget {
  final double el;
  final bool embedded;
  final VoidCallback? onClose;
  final VoidCallback? onExpand;

  const _PersistentNowPlayingView({
    required this.el,
    required this.embedded,
    this.onClose,
    this.onExpand,
  });

  @override
  State<_PersistentNowPlayingView> createState() =>
      _PersistentNowPlayingViewState();
}

class _PersistentNowPlayingViewState extends State<_PersistentNowPlayingView> {
  final GlobalKey<_LyricsViewerState> _lyricsViewerKey =
      GlobalKey<_LyricsViewerState>();

  @override
  Widget build(BuildContext context) {
    return _buildNowPlayingView(
      widget.el,
      embedded: widget.embedded,
      onClose: widget.onClose,
      onExpand: widget.onExpand,
      lyricsViewerKey: _lyricsViewerKey,
    );
  }
}

Widget _buildNowPlayingView(
  double el, {
  required bool embedded,
  required GlobalKey<_LyricsViewerState> lyricsViewerKey,
  VoidCallback? onClose,
  VoidCallback? onExpand,
}) {
  return ValueListenableBuilder<String?>(
    valueListenable: currentId,
    builder: (ctx, id, __) {
      Map<String, dynamic>? track;
      if (id != null) {
        track = tracksList.value.cast<Map<String, dynamic>?>().firstWhere(
          (item) => item?['id'] == id,
          orElse: () => null,
        );
      }

      final title = ((track?['title'] ?? texts['trackSample']!) as String);
      final artistRaw = ((track?['artist'] ?? '') as String).trim();
      final artist = artistRaw.isEmpty ? texts['unknown']! : artistRaw;
      final trackDuration = (track?['duration'] ?? durationMs.value) as int;
      final lyrics = (track?['lyrics'] ?? '') as String;
      final rawArt = track?['art'];
      final art = rawArt is Uint8List
          ? rawArt
          : id == null
          ? null
          : artworkBytesCache[id];
      final iconButton =
          buttons['icon'] as Widget Function(IconData, VoidCallback, double);

      Widget buildHeader({required bool desktop}) {
        return Row(
          children: [
            iconButton(
              embedded ? iconsMap['close']! : iconsMap['back']!,
              embedded ? onClose ?? closeWidePlayerPanel : goBackPage,
              el,
            ),
            SizedBox(width: el),
            Expanded(
              child: Text(
                texts['nowPlaying']!,
                style: TextStyle(
                  color: colors['text'],
                  fontSize: desktop
                      ? playerTypography['desktopHeader']
                      : el * playerTypography['compactHeaderFactor']!,
                  fontWeight: FontWeight.w600,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            SizedBox(width: el * .6),
            if (embedded) ...[
              TextButton.icon(
                onPressed: onExpand ?? expandWidePlayerPanel,
                icon: Icon(Icons.open_in_full_rounded, size: el * 1.15),
                label: Text(texts['expand']!),
                style: TextButton.styleFrom(foregroundColor: colors['text']),
              ),
              SizedBox(width: el * .4),
            ] else ...[
              iconButton(iconsMap['queue']!, () => setPage('queue'), el),
              SizedBox(width: el * .4),
            ],
            iconButton(
              iconsMap['info']!,
              () => openTrackInfoDialog(ctx, el, id),
              el,
            ),
          ],
        );
      }

      Widget buildCover(double dimension) {
        final devicePixelRatio = MediaQuery.devicePixelRatioOf(ctx);
        final decodeLimit = libraryPerformance['artworkDecodeMaxPx'] as int;
        final decodeSize = min(
          decodeLimit,
          max(1, (dimension * devicePixelRatio).round()),
        ).toInt();
        return SizedBox.square(
          dimension: dimension,
          child: FlipCard(
            fill: Fill.fillBack,
            direction: FlipDirection.HORIZONTAL,
            onFlip: () => lyricsViewerKey.currentState?._replayEntryAnimation(),
            front: ClipRRect(
              borderRadius: BorderRadius.circular(el),
              child: (art != null && art.isNotEmpty)
                  ? Image.memory(
                      art,
                      cacheWidth: decodeSize,
                      cacheHeight: decodeSize,
                      fit: BoxFit.cover,
                    )
                  : Image.asset(defaultArtPath, fit: BoxFit.cover),
            ),
            back: Container(
              padding: EdgeInsets.all(el),
              decoration: BoxDecoration(
                color: colors['accentDim']!.withValues(alpha: 0.3),
                borderRadius: BorderRadius.circular(el),
              ),
              child: LyricsViewer(
                key: lyricsViewerKey,
                trackId: id ?? '',
                lyrics: lyrics,
                el: el,
                position: positionMs,
                duration: durationMs,
              ),
            ),
          ),
        );
      }

      Widget buildDetails({required bool desktop}) {
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              title,
              style: TextStyle(
                color: colors['text'],
                fontSize: desktop
                    ? playerTypography['desktopTitle']
                    : el * playerTypography['compactTitleFactor']!,
                fontWeight: FontWeight.w700,
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            SizedBox(height: el * .4),
            Text(
              artist,
              style: TextStyle(
                color: colors['textDim'],
                fontSize: desktop
                    ? playerTypography['desktopArtist']
                    : el * playerTypography['compactArtistFactor']!,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            SizedBox(height: el * .8),
            MusicTimelineVisualizer(el: el),
            SizedBox(height: el * .8),
            ValueListenableBuilder<int>(
              valueListenable: durationMs,
              builder: (_, duration, __) => ValueListenableBuilder<int>(
                valueListenable: positionMs,
                builder: (_, position, __) {
                  final total = trackDuration > 0 ? trackDuration : duration;
                  final denominator = total > 0 ? total : 1;
                  final fraction = (position / denominator).clamp(0.0, 1.0);
                  return Column(
                    children: [
                      Row(
                        children: [
                          Text(
                            formatMs(position),
                            style: TextStyle(
                              color: colors['textDim'],
                              fontSize: desktop
                                  ? playerTypography['desktopTime']
                                  : el * playerTypography['compactTimeFactor']!,
                            ),
                          ),
                          const Spacer(),
                          Text(
                            formatMs(total),
                            style: TextStyle(
                              color: colors['textDim'],
                              fontSize: desktop
                                  ? playerTypography['desktopTime']
                                  : el * playerTypography['compactTimeFactor']!,
                            ),
                          ),
                        ],
                      ),
                      Slider(
                        value: fraction.toDouble(),
                        min: 0.0,
                        max: 1.0,
                        activeColor: colors['accent'],
                        inactiveColor: colors['text']!.withValues(alpha: .25),
                        onChanged: seekToFraction,
                      ),
                    ],
                  );
                },
              ),
            ),
            SizedBox(height: el * 1.2),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                iconButton(iconsMap['prev']!, playPrev, el * 1.1),
                SizedBox(width: el),
                ValueListenableBuilder<bool>(
                  valueListenable: isPlaying,
                  builder: (_, playing, __) => iconButton(
                    playing ? iconsMap['pause']! : iconsMap['play']!,
                    togglePlay,
                    el * 1.4,
                  ),
                ),
                SizedBox(width: el),
                iconButton(iconsMap['next']!, playNext, el * 1.1),
              ],
            ),
            SizedBox(height: el),
            ValueListenableBuilder<String>(
              valueListenable: playbackMode,
              builder: (_, mode, __) {
                Widget modeButton(String value, IconData icon) {
                  return Opacity(
                    opacity: mode == value ? 1.0 : 0.5,
                    child: iconButton(icon, () => setPlayMode(value), el),
                  );
                }

                return Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    for (
                      var index = 0;
                      index < playbackModes.length;
                      index++
                    ) ...[
                      if (index > 0) SizedBox(width: el),
                      modeButton(
                        playbackModes[index],
                        playbackModeIcons[playbackModes[index]]!,
                      ),
                    ],
                  ],
                );
              },
            ),
          ],
        );
      }

      return LayoutBuilder(
        builder: (context, constraints) {
          final width = constraints.maxWidth;
          final compactWidth = responsiveLayout['compactWidth'] as double;
          final desktopWidth = responsiveLayout['desktopWidth'] as double;
          final isCompact = width < compactWidth;
          final isDesktop = width >= desktopWidth;
          final screenPadding = isCompact
              ? responsiveLayout['compactScreenPadding'] as double
              : isDesktop
              ? responsiveLayout['desktopScreenPadding'] as double
              : responsiveLayout['mediumScreenPadding'] as double;
          final availableWidth = max(0.0, width - screenPadding * 2);
          final maxContentWidth =
              responsiveLayout['maxPlayerContentWidth'] as double;
          final contentWidth = min(availableWidth, maxContentWidth);
          final desktopGap = responsiveLayout['playerDesktopGap'] as double;
          final coverLimit = isDesktop
              ? responsiveLayout['desktopPlayerCover'] as double
              : isCompact
              ? responsiveLayout['compactPlayerCover'] as double
              : responsiveLayout['mediumPlayerCover'] as double;
          final desktopCoverWidth =
              (contentWidth - desktopGap) *
              (responsiveLayout['desktopCoverShare'] as double);
          final coverSize = max(
            0.0,
            min(coverLimit, isDesktop ? desktopCoverWidth : contentWidth),
          );

          final body = isDesktop
              ? Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    buildCover(coverSize),
                    SizedBox(width: desktopGap),
                    Expanded(
                      child: Center(
                        child: ConstrainedBox(
                          constraints: BoxConstraints(
                            maxWidth:
                                responsiveLayout['maxPlayerDetailsWidth']
                                    as double,
                          ),
                          child: buildDetails(desktop: true),
                        ),
                      ),
                    ),
                  ],
                )
              : Center(
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      maxWidth: isCompact
                          ? responsiveLayout['compactPlayerCover'] as double
                          : responsiveLayout['maxPlayerDetailsWidth'] as double,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Center(child: buildCover(coverSize)),
                        SizedBox(height: el * 1.2),
                        buildDetails(desktop: false),
                      ],
                    ),
                  ),
                );

          return scrollY(
            Padding(
              padding: EdgeInsets.all(screenPadding),
              child: Align(
                alignment: Alignment.topCenter,
                child: ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: maxContentWidth),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      buildHeader(desktop: isDesktop),
                      SizedBox(height: isDesktop ? desktopGap : el * 1.2),
                      body,
                    ],
                  ),
                ),
              ),
            ),
          );
        },
      );
    },
  );
}

Future<void> stopAndHidePlayer() async {
  await stopPlaybackSession();
}

Future<void> updateTrackLyrics(String trackId, String newLyrics) async {
  await ensureBoxes();
  if (trackId.isEmpty) return;
  final raw = tracksBox!.get(trackId);
  final Map<String, dynamic>? t = raw is Map
      ? Map<String, dynamic>.from(raw)
      : null;
  if (t == null) return;

  final newTrack = <String, dynamic>{
    ...t,
    'lyrics': newLyrics,
    'lyricsManuallyEdited': true,
    'lyricsChecked': true,
  };
  await tracksBox!.put(trackId, newTrack);

  final list = [...tracksList.value];
  final index = list.indexWhere((e) => e['id'] == trackId);
  if (index != -1) {
    list[index] = newTrack;
    tracksList.value = list;
  }
}

void openTrackInfoDialog(BuildContext ctx, double el, String? trackId) {
  if (trackId == null) return;
  final raw = tracksBox?.get(trackId);
  final Map<String, dynamic>? track = raw is Map
      ? Map<String, dynamic>.from(raw)
      : null;
  if (track == null) return;

  Widget infoTile(String title, String subtitle) {
    if (subtitle.trim().isEmpty || subtitle == texts['notAvailable']) {
      return const SizedBox.shrink();
    }
    return ListTile(
      dense: true,
      visualDensity: VisualDensity.compact,
      title: Text(title, style: TextStyle(color: colors['textDim'])),
      subtitle: Text(
        subtitle,
        style: TextStyle(color: colors['text']),
        maxLines: 3,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }

  final resolvedTrackId = (track['id'] ?? '').toString();
  final art = track['art'] is Uint8List
      ? track['art'] as Uint8List
      : artworkBytesCache[resolvedTrackId];
  final title = (track['title'] ?? texts['unknown']!).toString();
  final artist = (track['artist'] ?? '').toString().trim().ifEmpty(
    texts['unknown']!,
  );
  final album = (track['album'] ?? '').toString().trim();
  final duration = _numberFromData(track['duration']);
  final sizeBytes = _numberFromData(track['size']);
  final addedAt = _numberFromData(track['addedAt']);
  final path = (track['path'] ?? '').toString().trim();
  final url = (track['url'] ?? '').toString().trim();
  final source = path.isNotEmpty ? path : url;
  final fileName = (track['name'] ?? p.basename(source)).toString();
  final extension = p.extension(fileName).replaceFirst('.', '').toUpperCase();
  final added = addedAt > 0
      ? DateTime.fromMillisecondsSinceEpoch(
          addedAt,
        ).toLocal().toString().substring(0, 16)
      : texts['notAvailable']!;

  showModalBottomSheet(
    context: ctx,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    showDragHandle: true,
    enableDrag: true,
    builder: (_) => SafeArea(
      child: Padding(
        padding: EdgeInsets.all(el * 1.2),
        child: glass(
          ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight:
                  MediaQuery.sizeOf(ctx).height *
                  (responsiveLayout['sheetMaxHeightFactor'] as double),
            ),
            child: ListView(
              shrinkWrap: true,
              children: [
                Row(
                  children: [
                    artThumb(track, el, size: 3.8),
                    SizedBox(width: el),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            title,
                            style: TextStyle(
                              color: colors['text'],
                              fontSize: el * 1.2,
                              fontWeight: FontWeight.w700,
                            ),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          SizedBox(height: el * .2),
                          Text(
                            artist,
                            style: TextStyle(
                              color: colors['textDim'],
                              fontSize: el,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      tooltip: texts['close'],
                      onPressed: () => Navigator.pop(ctx),
                      icon: Icon(iconsMap['close'], color: colors['text']),
                    ),
                  ],
                ),
                Divider(color: colors['glassBorder'], height: el * 1.5),
                infoTile(texts['titleLabel']!, title),
                infoTile(texts['artistLabel']!, artist),
                infoTile(texts['albumLabel']!, album),
                infoTile(
                  texts['durationLabel']!,
                  duration > 0 ? formatMs(duration) : texts['notAvailable']!,
                ),
                infoTile(texts['formatLabel']!, extension),
                infoTile(texts['fileNameLabel']!, fileName),
                infoTile(texts['locationLabel']!, source),
                infoTile(
                  texts['sizeLabel']!,
                  sizeBytes > 0
                      ? '${(sizeBytes / (1024 * 1024)).toStringAsFixed(2)} MB'
                      : texts['notAvailable']!,
                ),
                infoTile(texts['addedLabel']!, added),
                infoTile(
                  texts['coverArtLabel']!,
                  art != null && art.isNotEmpty
                      ? '${texts['yes']} '
                            '(${(art.lengthInBytes / 1024).toStringAsFixed(1)} KB)'
                      : track['hasArtwork'] == true
                      ? texts['yes']!
                      : texts['no']!,
                ),
              ],
            ),
          ),
          el,
        ),
      ),
    ),
  );
}

class LyricsViewer extends StatefulWidget {
  final String trackId;
  final String lyrics;
  final double el;
  final ValueNotifier<int> position;
  final ValueNotifier<int> duration;

  const LyricsViewer({
    super.key,
    required this.trackId,
    required this.lyrics,
    required this.el,
    required this.position,
    required this.duration,
  });

  @override
  State<LyricsViewer> createState() => _LyricsViewerState();
}

class _LyricsViewerState extends State<LyricsViewer>
    with TickerProviderStateMixin {
  final ScrollController _scrollController = ScrollController();
  late final TextEditingController _textController;
  late final AnimationController _entryController;
  late final AnimationController _smoothScrollTicker;
  List<Map<String, dynamic>> _lyricLines = <Map<String, dynamic>>[];
  List<GlobalKey?> _lineKeys = <GlobalKey?>[];
  Timer? _manualScrollResumeTimer;
  bool _hasTimestamps = false;
  bool _userIsScrolling = false;
  bool _manualScrollInProgress = false;
  bool _isEditing = false;
  int _activeLine = -1;
  int _lastScrollTarget = -1;

  String get _selectedAnimationMode {
    final selected = lyricsAnimationMode.value;
    return lyricsAnimationModes.contains(selected) ? selected : 'smooth';
  }

  String get _effectiveAnimationMode {
    final selected = _selectedAnimationMode;
    if (selected == 'synced' && !_hasTimestamps) return 'smooth';
    return selected;
  }

  bool get _usesTimestampSync =>
      _effectiveAnimationMode == 'synced' && _hasTimestamps;

  bool get _usesSmoothAutoScroll => _effectiveAnimationMode == 'smooth';

  @override
  void initState() {
    super.initState();
    _textController = TextEditingController(text: widget.lyrics);
    _entryController = AnimationController(
      vsync: this,
      duration: Duration(
        milliseconds: lyricPresentation['entryLineDurationMs'] as int,
      ),
    );
    _smoothScrollTicker = AnimationController(
      vsync: this,
      duration: Duration(
        milliseconds: lyricPresentation['smoothScrollTickerMs'] as int,
      ),
    )..addListener(_updateSmoothScrollFrame);
    _rebuildLyricLines();
    widget.position.addListener(_handlePlaybackProgress);
    widget.duration.addListener(_handlePlaybackProgress);
    isPlaying.addListener(_handlePlayingChanged);
    lyricsAnimationMode.addListener(_handleAnimationModeChanged);
    lyricsOffsetMs.addListener(_handleLyricsOffsetChanged);
    _replayEntryAnimation();
    _updateSmoothScrollTicker();
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _handlePlaybackProgress(),
    );
  }

  @override
  void dispose() {
    _manualScrollResumeTimer?.cancel();
    widget.position.removeListener(_handlePlaybackProgress);
    widget.duration.removeListener(_handlePlaybackProgress);
    isPlaying.removeListener(_handlePlayingChanged);
    lyricsAnimationMode.removeListener(_handleAnimationModeChanged);
    lyricsOffsetMs.removeListener(_handleLyricsOffsetChanged);
    _smoothScrollTicker
      ..removeListener(_updateSmoothScrollFrame)
      ..dispose();
    _entryController.dispose();
    _scrollController.dispose();
    _textController.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(LyricsViewer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.position != oldWidget.position) {
      oldWidget.position.removeListener(_handlePlaybackProgress);
      widget.position.addListener(_handlePlaybackProgress);
    }
    if (widget.duration != oldWidget.duration) {
      oldWidget.duration.removeListener(_handlePlaybackProgress);
      widget.duration.addListener(_handlePlaybackProgress);
    }
    if (widget.trackId != oldWidget.trackId ||
        widget.lyrics != oldWidget.lyrics) {
      _manualScrollResumeTimer?.cancel();
      _userIsScrolling = false;
      _manualScrollInProgress = false;
      _isEditing = false;
      _textController.text = widget.lyrics;
      _rebuildLyricLines();
      _replayEntryAnimation();
      _updateSmoothScrollTicker();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (_scrollController.hasClients) {
          _scrollController.jumpTo(0);
        }
        _handlePlaybackProgress();
      });
    }
  }

  void _rebuildLyricLines() {
    final timingPattern = RegExp(
      r'^\[(\d{1,3}):(\d{2})(?:[.:](\d{1,3}))?\]\s*(.*)$',
    );
    final parsed = <Map<String, dynamic>>[];

    for (final sourceLine in _textController.text.split(RegExp(r'\r?\n'))) {
      final trimmed = sourceLine.trim();
      if (trimmed.isEmpty) continue;

      final match = timingPattern.firstMatch(trimmed);
      if (match == null) {
        parsed.add(<String, dynamic>{'text': trimmed, 'timeMs': null});
        continue;
      }

      final minutes = int.tryParse(match.group(1) ?? '') ?? 0;
      final seconds = int.tryParse(match.group(2) ?? '') ?? 0;
      final fractionText = match.group(3) ?? '';
      final fraction = fractionText.isEmpty
          ? 0
          : int.tryParse(fractionText.padRight(3, '0').substring(0, 3)) ?? 0;
      final lineText = (match.group(4) ?? '').trim();
      if (lineText.isEmpty) continue;

      parsed.add(<String, dynamic>{
        'text': lineText,
        'timeMs': ((minutes * 60 + seconds) * 1000) + fraction,
      });
    }

    _lyricLines = parsed;
    _hasTimestamps = parsed.any((line) => line['timeMs'] is int);
    final lineDuration = lyricPresentation['entryLineDurationMs'] as int;
    final lineStagger = lyricPresentation['entryLineStaggerMs'] as int;
    final totalDuration =
        lineDuration + max(0, parsed.length - 1) * lineStagger;
    _entryController.duration = Duration(milliseconds: max(1, totalDuration));
    _lineKeys = parsed
        .map<GlobalKey?>((line) => line['timeMs'] is int ? GlobalKey() : null)
        .toList(growable: false);
    _activeLine = -1;
    _lastScrollTarget = -1;
  }

  void _replayEntryAnimation() {
    if (_effectiveAnimationMode != 'smooth') return;
    _entryController.forward(from: 0);
  }

  void _updateSmoothScrollTicker() {
    if (_usesSmoothAutoScroll && isPlaying.value) {
      if (!_smoothScrollTicker.isAnimating) {
        _smoothScrollTicker.repeat();
      }
    } else {
      _smoothScrollTicker.stop();
    }
  }

  void _handlePlayingChanged() {
    _updateSmoothScrollTicker();
    if (isPlaying.value) _handlePlaybackProgress();
  }

  void _handlePlaybackProgress() {
    if (_usesTimestampSync) {
      _autoScroll();
    } else if (_usesSmoothAutoScroll) {
      _updateSmoothScrollFrame();
    }
  }

  void _updateSmoothScrollFrame() {
    if (!_usesSmoothAutoScroll ||
        !isPlaying.value ||
        _isEditing ||
        _userIsScrolling ||
        !_scrollController.hasClients) {
      return;
    }

    final duration = widget.duration.value;
    if (duration <= 0) return;

    final progress = (widget.position.value / duration)
        .clamp(0.0, 1.0)
        .toDouble();
    final maxExtent = _scrollController.position.maxScrollExtent;
    if (maxExtent <= 0) return;

    final currentOffset = _scrollController.offset;
    final targetOffset = maxExtent * progress;
    final distance = targetOffset - currentOffset;
    final snapDistance =
        lyricPresentation['smoothScrollSnapDistance'] as double;
    final followFactor =
        lyricPresentation['smoothScrollFollowFactor'] as double;
    final nextOffset = distance.abs() <= snapDistance
        ? targetOffset
        : currentOffset + distance * followFactor;

    if ((nextOffset - currentOffset).abs() < 0.01) return;
    _scrollController.jumpTo(nextOffset.clamp(0.0, maxExtent).toDouble());
  }

  int _activeLineAt(int position) {
    if (!_hasTimestamps || _lyricLines.isEmpty) return -1;

    final effectivePosition = position + lyricsOffsetMs.value;
    var result = -1;
    for (var index = 0; index < _lyricLines.length; index++) {
      final timestamp = _lyricLines[index]['timeMs'];
      if (timestamp is int && timestamp <= effectivePosition) {
        result = index;
      }
    }
    return result;
  }

  void _handleAnimationModeChanged() {
    if (!mounted) return;
    _manualScrollResumeTimer?.cancel();
    _userIsScrolling = false;
    _manualScrollInProgress = false;
    setState(() {
      _activeLine = -1;
      _lastScrollTarget = -1;
    });
    if (_effectiveAnimationMode == 'smooth') {
      _replayEntryAnimation();
    }
    _updateSmoothScrollTicker();
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _handlePlaybackProgress(),
    );
  }

  void _handleLyricsOffsetChanged() {
    if (!mounted || !_usesTimestampSync) return;
    _autoScroll();
  }

  void _beginManualScroll() {
    _manualScrollResumeTimer?.cancel();
    _userIsScrolling = true;
    _lastScrollTarget = -1;
  }

  void _scheduleManualScrollResume() {
    _manualScrollResumeTimer?.cancel();
    _manualScrollResumeTimer = Timer(
      Duration(
        milliseconds: lyricPresentation['manualScrollResumeDelayMs'] as int,
      ),
      () {
        if (!mounted) return;
        _userIsScrolling = false;
        _handlePlaybackProgress();
      },
    );
  }

  bool _handleScrollNotification(ScrollNotification notification) {
    if (notification is ScrollStartNotification &&
        notification.dragDetails != null) {
      _manualScrollInProgress = true;
      _beginManualScroll();
    } else if (notification is ScrollUpdateNotification &&
        notification.dragDetails != null) {
      _beginManualScroll();
    } else if (notification is ScrollEndNotification &&
        _manualScrollInProgress) {
      _manualScrollInProgress = false;
      _scheduleManualScrollResume();
    }
    return false;
  }

  void _autoScroll() {
    if (!_usesTimestampSync || _isEditing || _lyricLines.isEmpty) {
      return;
    }

    final nextLine = _activeLineAt(widget.position.value);
    if (nextLine != _activeLine && mounted) {
      setState(() => _activeLine = nextLine);
    }
    if (nextLine < 0) {
      _lastScrollTarget = -1;
      return;
    }
    if (_userIsScrolling || !_scrollController.hasClients) return;
    if (nextLine >= _lineKeys.length || nextLine == _lastScrollTarget) {
      return;
    }
    _lastScrollTarget = nextLine;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          !_usesTimestampSync ||
          _userIsScrolling ||
          !_scrollController.hasClients ||
          _lyricLines.isEmpty) {
        return;
      }

      final lineKey = _lineKeys[nextLine];
      final lineContext = lineKey?.currentContext;
      final scrollDuration = Duration(
        milliseconds: lyricPresentation['scrollAnimationMs'] as int,
      );
      if (lineContext != null) {
        Scrollable.ensureVisible(
          lineContext,
          alignment: lyricPresentation['scrollAlignment'] as double,
          duration: scrollDuration,
          curve: Curves.easeInOutCubic,
        );
      } else {
        final maxExtent = _scrollController.position.maxScrollExtent;
        final progress = _lyricLines.length <= 1
            ? 0.0
            : nextLine / (_lyricLines.length - 1);
        _scrollController.animateTo(
          (maxExtent * progress).clamp(0.0, maxExtent),
          duration: scrollDuration,
          curve: Curves.easeInOutCubic,
        );
      }
    });
  }

  Widget _buildEditor() {
    return Column(
      children: [
        Expanded(
          child: TextField(
            controller: _textController,
            maxLines: null,
            expands: true,
            autofocus: true,
            style: TextStyle(color: colors['text'], fontSize: widget.el * 1.1),
            decoration: const InputDecoration(border: InputBorder.none),
          ),
        ),
        SizedBox(height: widget.el * .6),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            TextButton(
              onPressed: () => setState(() => _isEditing = false),
              child: Text(
                texts['cancel']!,
                style: TextStyle(color: colors['textDim']),
              ),
            ),
            SizedBox(width: widget.el * .6),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: colors['accent'],
                foregroundColor: colors['text'],
              ),
              onPressed: () async {
                await updateTrackLyrics(widget.trackId, _textController.text);
                _rebuildLyricLines();
                _replayEntryAnimation();
                _updateSmoothScrollTicker();
                if (mounted) setState(() => _isEditing = false);
                WidgetsBinding.instance.addPostFrameCallback(
                  (_) => _handlePlaybackProgress(),
                );
              },
              child: Text(texts['save']!),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildPlainLyrics() {
    final linePadding = lyricPresentation['linePadding'] as double;
    final lineHeight = lyricPresentation['lineHeight'] as double;
    final fontFactor = lyricPresentation['baseFontFactor'] as double;
    return ListView.builder(
      controller: _scrollController,
      padding: EdgeInsets.symmetric(vertical: widget.el),
      itemCount: _lyricLines.length,
      itemBuilder: (_, index) => Padding(
        padding: EdgeInsets.symmetric(vertical: linePadding),
        child: Text(
          _lyricLines[index]['text'] as String,
          textAlign: TextAlign.center,
          style: TextStyle(
            color: colors['text'],
            fontSize: widget.el * fontFactor,
            height: lineHeight,
            fontWeight: FontWeight.w400,
          ),
        ),
      ),
    );
  }

  Widget _buildSmoothLyrics() {
    final linePadding = lyricPresentation['linePadding'] as double;
    final lineHeight = lyricPresentation['lineHeight'] as double;
    final fontFactor = lyricPresentation['baseFontFactor'] as double;
    final lineDuration = lyricPresentation['entryLineDurationMs'] as int;
    final lineStagger = lyricPresentation['entryLineStaggerMs'] as int;
    final slideOffset = lyricPresentation['entrySlideOffset'] as double;
    final totalDuration = max(
      1,
      lineDuration + max(0, _lyricLines.length - 1) * lineStagger,
    );

    return ListView.builder(
      controller: _scrollController,
      padding: EdgeInsets.symmetric(vertical: widget.el),
      itemCount: _lyricLines.length,
      itemBuilder: (_, index) {
        final start = (index * lineStagger / totalDuration)
            .clamp(0.0, 1.0)
            .toDouble();
        final end = ((index * lineStagger + lineDuration) / totalDuration)
            .clamp(start, 1.0)
            .toDouble();
        final curve = CurvedAnimation(
          parent: _entryController,
          curve: Interval(start, end, curve: Curves.easeOutCubic),
        );
        final slide = Tween<Offset>(
          begin: Offset(0, slideOffset),
          end: Offset.zero,
        ).animate(curve);

        return FadeTransition(
          opacity: curve,
          child: SlideTransition(
            position: slide,
            child: Padding(
              padding: EdgeInsets.symmetric(vertical: linePadding),
              child: Text(
                _lyricLines[index]['text'] as String,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: colors['text'],
                  fontSize: widget.el * fontFactor,
                  height: lineHeight,
                  fontWeight: FontWeight.w400,
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildSyncedLyrics() {
    final animationDuration = Duration(
      milliseconds: lyricPresentation['animationMs'] as int,
    );
    final linePadding = lyricPresentation['linePadding'] as double;
    final lineHeight = lyricPresentation['lineHeight'] as double;
    final fontFactor = lyricPresentation['baseFontFactor'] as double;

    return ListView.builder(
      controller: _scrollController,
      padding: EdgeInsets.symmetric(vertical: widget.el * 2),
      itemCount: _lyricLines.length,
      itemBuilder: (_, index) {
        final active = index == _activeLine;
        return AnimatedOpacity(
          key: _lineKeys[index],
          duration: animationDuration,
          curve: Curves.easeInOut,
          opacity: active
              ? 1.0
              : lyricPresentation['inactiveOpacity'] as double,
          child: AnimatedScale(
            duration: animationDuration,
            curve: Curves.easeOutCubic,
            scale: active ? lyricPresentation['activeScale'] as double : 1.0,
            child: Padding(
              padding: EdgeInsets.symmetric(vertical: linePadding),
              child: AnimatedDefaultTextStyle(
                duration: animationDuration,
                curve: Curves.easeInOut,
                style: TextStyle(
                  color: active ? colors['text'] : colors['textDim'],
                  fontSize: widget.el * fontFactor,
                  height: lineHeight,
                  fontWeight: active ? FontWeight.w600 : FontWeight.w400,
                ),
                child: Text(
                  _lyricLines[index]['text'] as String,
                  textAlign: TextAlign.center,
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildViewer() {
    final hasLyrics = _lyricLines.isNotEmpty;
    final canEdit = widget.trackId.isNotEmpty;
    final mode = _effectiveAnimationMode;
    final lyricsBody = switch (mode) {
      'off' => _buildPlainLyrics(),
      'synced' => _buildSyncedLyrics(),
      _ => _buildSmoothLyrics(),
    };

    return Column(
      children: [
        Expanded(
          child: hasLyrics
              ? Listener(
                  onPointerDown: (_) => _beginManualScroll(),
                  onPointerUp: (_) {
                    if (!_manualScrollInProgress) {
                      _scheduleManualScrollResume();
                    }
                  },
                  onPointerCancel: (_) {
                    _manualScrollInProgress = false;
                    _scheduleManualScrollResume();
                  },
                  child: NotificationListener<ScrollNotification>(
                    onNotification: _handleScrollNotification,
                    child: lyricsBody,
                  ),
                )
              : Center(
                  child: Text(
                    texts['noLyrics']!,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: colors['textDim'],
                      fontSize: widget.el,
                    ),
                  ),
                ),
        ),
        SizedBox(height: widget.el * .6),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton(
            onPressed: canEdit ? () => setState(() => _isEditing = true) : null,
            child: Text(
              hasLyrics ? texts['editLyrics']! : texts['addLyrics']!,
              style: TextStyle(
                color: canEdit ? colors['text']! : colors['textDim']!,
              ),
            ),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return _isEditing ? _buildEditor() : _buildViewer();
  }
}

Uint8List? _pickArtwork(List<Tag> tags) {
  AttachedPicture? fallback;
  for (final tag in tags) {
    final pictures = tag.tags['picture'];
    if (pictures is! Map) continue;
    for (final value in pictures.values) {
      if (value is! AttachedPicture || value.imageData.isEmpty) continue;
      if (value.imageTypeCode == 3) {
        return Uint8List.fromList(value.imageData);
      }
      fallback ??= value;
    }
  }
  return fallback == null ? null : Uint8List.fromList(fallback.imageData);
}

String _pickTagText(List<Tag> tags, List<String> keys, String fallback) {
  for (final tag in tags) {
    for (final key in keys) {
      final value = tag.tags[key];
      if (value == null) continue;
      final text = value.toString().trim();
      if (text.isNotEmpty) return text;
    }
  }
  return fallback;
}

String _pickLyrics(List<Tag> tags) {
  for (final t in tags) {
    final v = t.tags['lyrics'] ?? t.tags['USLT'];
    if (v != null) {
      final s = v.toString().trim();
      if (s.isNotEmpty) return s;
    }
  }
  return '';
}

final Set<String> _lyricsLoads = <String>{};

Future<void> _backfillLyricsForTrack(String id) async {
  if (!_lyricsLoads.add(id)) return;
  try {
    final raw = tracksBox?.get(id);
    if (raw is! Map) return;
    final track = Map<String, dynamic>.from(raw);
    final initialLyrics = (track['lyrics'] ?? '').toString();
    if (initialLyrics.trim().isNotEmpty ||
        track['lyricsManuallyEdited'] == true ||
        track['lyricsChecked'] == true) {
      return;
    }
    Uint8List? bytes;
    if (kIsWeb) {
      bytes = await tracksBox?.loadTrackBytes(id);
    } else {
      final path = (track['path'] ?? '').toString();
      if (path.isNotEmpty) {
        final file = io.File(path);
        if (await file.exists()) bytes = await file.readAsBytes();
      }
    }
    var lyrics = '';
    var metadataReadSucceeded = false;
    if (bytes != null && bytes.isNotEmpty) {
      final tags = await TagProcessor().getTagsFromByteArray(
        Future<Uint8List>.value(bytes),
      );
      lyrics = _pickLyrics(tags);
      metadataReadSucceeded = true;
    }
    bytes = null;
    if (!metadataReadSucceeded) return;
    final latestRaw = tracksBox?.get(id);
    if (latestRaw is! Map) return;
    final latest = Map<String, dynamic>.from(latestRaw);
    final latestLyrics = (latest['lyrics'] ?? '').toString();
    if (latest['lyricsManuallyEdited'] == true ||
        latestLyrics != initialLyrics ||
        latest['lyricsChecked'] == true) {
      return;
    }
    final updated = <String, dynamic>{...latest, 'lyricsChecked': true};
    if (lyrics.isNotEmpty) updated['lyrics'] = lyrics;
    await tracksBox!.put(id, updated);
    _reloadTracks();
    if (currentId.value == id) currentId.refresh();
  } catch (error) {
    debugPrint('Lyrics backfill failed for $id: $error');
  } finally {
    _lyricsLoads.remove(id);
  }
}

void _toggleTrackSelection(String id) {
  final newSet = {...selectedTrackIds.value};
  if (newSet.contains(id)) {
    newSet.remove(id);
  } else {
    newSet.add(id);
  }
  selectedTrackIds.value = newSet;
}

void _startSelectionMode([String? initialId]) {
  isSelectionMode.value = true;
  final newSet = <String>{};
  if (initialId != null) {
    newSet.add(initialId);
  }
  selectedTrackIds.value = newSet;
}

void _cancelSelectionMode() {
  isSelectionMode.value = false;
  selectedTrackIds.value = {};
}

void _selectAllTracks() {
  final allIds = tracksList.value.map((t) => t['id'] as String).toSet();
  selectedTrackIds.value = allIds;
}

Future<void> _deleteSelectedTracks(BuildContext ctx) async {
  final idsToDelete = {...selectedTrackIds.value};
  if (idsToDelete.isEmpty) {
    _cancelSelectionMode();
    return;
  }

  final ok = await showDialog<bool>(
    context: ctx,
    builder: (_) => AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      content: Text(
        textTemplate('bulkDeleteTemplate', {'count': idsToDelete.length}),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: Text(texts['cancel']!),
        ),
        TextButton(
          onPressed: () => Navigator.pop(ctx, true),
          child: Text(texts['delete']!),
        ),
      ],
    ),
  );

  if (ok != true) return;

  await deleteTracks(idsToDelete);
  _cancelSelectionMode();
}

void openTopMoreMenu(BuildContext ctx, double el) {
  showModalBottomSheet(
    context: ctx,
    backgroundColor: Colors.transparent,
    builder: (_) => Padding(
      padding: EdgeInsets.all(el * 1.2),
      child: glass(
        Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (kIsWeb || defaultTargetPlatform == TargetPlatform.iOS)
              ListTile(
                leading: Icon(iconsMap['upload'], color: colors['text']),
                title: Text(
                  texts['importFiles']!,
                  style: TextStyle(color: colors['text']),
                ),
                onTap: () async {
                  Navigator.pop(ctx);
                  await pickAndImportFiles(ctx);
                },
              ),
            ListTile(
              leading: Icon(iconsMap['selectTracks']!, color: colors['text']),
              title: Text(
                texts['selectTracks']!,
                style: TextStyle(color: colors['text']),
              ),
              onTap: () {
                Navigator.pop(ctx);
                _startSelectionMode();
              },
            ),
            ListTile(
              leading: Icon(iconsMap['settings']!, color: colors['text']),
              title: Text(
                texts['settings']!,
                style: TextStyle(color: colors['text']),
              ),
              onTap: () {
                Navigator.pop(ctx);
                setPage('settings');
              },
            ),
          ],
        ),
        el,
      ),
    ),
  );
}

// =========== SETTINGS STATE ===========
final uiScale = ValueNotifier<double>(1.0);
final textScale = ValueNotifier<double>(1.0);
final lyricsAnimationMode = ValueNotifier<String>('smooth');
final lyricsOffsetMs = ValueNotifier<int>(0);
final themeId = ValueNotifier<String>('glass');

final List<Map<String, dynamic>> sizePresets = [
  {'label': 'Small', 'value': 0.90},
  {'label': 'Normal', 'value': 1.00},
  {'label': 'Large', 'value': 1.15},
  {'label': 'XL', 'value': 1.30},
];

final Map<String, dynamic> textScaleSettings = {
  'min': 0.80,
  'max': 1.40,
  'divisions': 12,
};

final List<Map<String, dynamic>> textScalePresets = [
  {'label': 'Small', 'value': 0.90},
  {'label': 'Normal', 'value': 1.00},
  {'label': 'Large', 'value': 1.15},
  {'label': 'XL', 'value': 1.30},
];
final Map<String, Map<String, Color>> themes = {
  'glass': {
    'bg1': const Color(0xFFBFD9FF),
    'bg2': const Color(0xFF9FC3FF),
    'glass': const Color(0x33FFFFFF),
    'glassBorder': const Color(0x22FFFFFF),
    'text': Colors.white,
    'textDim': Colors.white70,
    'accent': const Color(0xFF7A4DFF),
    'accentDim': const Color(0x337A4DFF),
    'chipBackground': const Color(0xCC35364A),
    'chipSelected': const Color(0xE25E43D0),
    'chipText': Colors.white,
    'chipSelectedText': Colors.white,
    'chipBorder': const Color(0x55FFFFFF),
    'shadow': const Color(0x33000000),
  },
  'dark': {
    'bg1': const Color(0xFF111318),
    'bg2': const Color(0xFF0B0C10),
    'glass': const Color(0x18000000),
    'glassBorder': const Color(0x33000000),
    'text': Colors.white,
    'textDim': Colors.white70,
    'accent': const Color(0xFF7A4DFF),
    'accentDim': const Color(0x337A4DFF),
    'chipBackground': const Color(0xE6242731),
    'chipSelected': const Color(0xE25E43D0),
    'chipText': Colors.white,
    'chipSelectedText': Colors.white,
    'chipBorder': const Color(0x4DFFFFFF),
    'shadow': const Color(0x66000000),
  },
  'light': {
    'bg1': const Color(0xFFF0F3FF),
    'bg2': const Color(0xFFE7EDFF),
    'glass': const Color(0x44FFFFFF),
    'glassBorder': const Color(0x22FFFFFF),
    'text': const Color(0xFF111111),
    'textDim': const Color(0x99111111),
    'accent': const Color(0xFF7A4DFF),
    'accentDim': const Color(0x227A4DFF),
    'chipBackground': const Color(0xFFF7F8FD),
    'chipSelected': const Color(0xFF6846D9),
    'chipText': const Color(0xFF17131F),
    'chipSelectedText': Colors.white,
    'chipBorder': const Color(0x4D312A45),
    'shadow': const Color(0x1A000000),
  },
};

ThemeData appMaterialTheme(String id) {
  final palette = themes[id] ?? themes['glass']!;
  final brightness = id == 'light' ? Brightness.light : Brightness.dark;
  final chipLabelColor = WidgetStateColor.resolveWith(
    (states) => states.contains(WidgetState.selected)
        ? palette['chipSelectedText']!
        : palette['chipText']!,
  );
  final scheme =
      ColorScheme.fromSeed(
        seedColor: palette['accent']!,
        brightness: brightness,
      ).copyWith(
        primary: palette['accent'],
        onPrimary: palette['text'],
        surface: palette['bg1'],
        onSurface: palette['text'],
        outline: palette['glassBorder'],
      );
  return ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: scheme,
    scaffoldBackgroundColor: Colors.transparent,
    dialogTheme: DialogThemeData(
      backgroundColor: palette['bg1'],
      contentTextStyle: TextStyle(color: palette['text']),
      titleTextStyle: TextStyle(
        color: palette['text'],
        fontSize: 20,
        fontWeight: FontWeight.w600,
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      labelStyle: TextStyle(color: palette['textDim']),
      hintStyle: TextStyle(color: palette['textDim']),
    ),
    chipTheme: ChipThemeData(
      backgroundColor: palette['chipBackground'],
      selectedColor: palette['chipSelected'],
      secondarySelectedColor: palette['chipSelected'],
      surfaceTintColor: Colors.transparent,
      checkmarkColor: palette['chipSelectedText'],
      labelStyle: TextStyle(color: chipLabelColor),
      secondaryLabelStyle: TextStyle(
        color: palette['chipSelectedText'],
        fontWeight: FontWeight.w600,
      ),
      iconTheme: IconThemeData(color: chipLabelColor),
      side: BorderSide(color: palette['chipBorder']!),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
    ),
  );
}

void setUiScale(double v) {
  final clamped = v.clamp(
    uiScaleSettings['min'] as double,
    uiScaleSettings['max'] as double,
  );
  uiScale.value = clamped;
  prefsBox?.put('uiScale', clamped);
}

void previewUiScale(double value) {
  uiScale.value = value.clamp(
    uiScaleSettings['min'] as double,
    uiScaleSettings['max'] as double,
  );
}

void setTextScale(double value) {
  final minimum = textScaleSettings['min'] as double;
  final maximum = textScaleSettings['max'] as double;
  final clamped = value.clamp(minimum, maximum);
  textScale.value = clamped;
  prefsBox?.put('textScale', clamped);
}

void previewTextScale(double value) {
  textScale.value = value.clamp(
    textScaleSettings['min'] as double,
    textScaleSettings['max'] as double,
  );
}

void setLyricsAnimationMode(String mode) {
  if (!lyricsAnimationModes.contains(mode)) return;
  lyricsAnimationMode.value = mode;
  prefsBox?.put('lyricsAnimationMode', mode);
}

void previewLyricsOffsetMs(double value) {
  final minimum = lyricPresentation['offsetMinMs'] as int;
  final maximum = lyricPresentation['offsetMaxMs'] as int;
  lyricsOffsetMs.value = value.round().clamp(minimum, maximum).toInt();
}

void setLyricsOffsetMs(int value) {
  final minimum = lyricPresentation['offsetMinMs'] as int;
  final maximum = lyricPresentation['offsetMaxMs'] as int;
  final step = lyricPresentation['offsetStepMs'] as int;
  final clamped = value.clamp(minimum, maximum);
  final stepped = (clamped / step).round() * step;
  lyricsOffsetMs.value = stepped;
  prefsBox?.put('lyricsOffsetMs', stepped);
}

String formatLyricsOffset(int offsetMs) {
  final seconds = offsetMs / 1000;
  final prefix = seconds > 0 ? '+' : '';
  return textTemplate('lyricsTimingValue', <String, Object>{
    'value': '$prefix${seconds.toStringAsFixed(1)}',
  });
}

void setTheme(String id) {
  if (!themes.containsKey(id)) return;
  _applyTheme(id);
  themeId.value = id;
  backgroundId.refresh();
  prefsBox?.put('theme', id);
}

void _applyTheme(String id) {
  final t = themes[id];
  if (t == null) return;
  for (final entry in t.entries) {
    if (colors.containsKey(entry.key)) {
      colors[entry.key] = entry.value;
    }
  }
}

class _AuthorFlowerMark extends StatefulWidget {
  const _AuthorFlowerMark();

  @override
  State<_AuthorFlowerMark> createState() => _AuthorFlowerMarkState();
}

class _AuthorFlowerMarkState extends State<_AuthorFlowerMark> {
  Timer? _tapResetTimer;
  int _tapCount = 0;

  void _handleTap() {
    _tapResetTimer?.cancel();
    _tapCount++;
    if (_tapCount >= (authorMarkPresentation['tapsToReveal'] as int)) {
      _tapCount = 0;
      showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          icon: Icon(
            Icons.local_florist_rounded,
            color: authorMarkPresentation['color'] as Color,
            size: authorMarkPresentation['dialogIconSize'] as double,
          ),
          content: Text(
            texts['authorSignature']!,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 20, height: 1.6),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: Text(texts['close']!),
            ),
          ],
        ),
      );
      return;
    }
    _tapResetTimer = Timer(
      Duration(milliseconds: authorMarkPresentation['tapResetMs'] as int),
      () => _tapCount = 0,
    );
  }

  @override
  void dispose() {
    _tapResetTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return IconButton(
      key: const ValueKey('author-flower'),
      tooltip: texts['authorMark'],
      onPressed: _handleTap,
      iconSize: authorMarkPresentation['iconSize'] as double,
      style: IconButton.styleFrom(
        foregroundColor: authorMarkPresentation['color'] as Color,
      ),
      icon: const Icon(Icons.local_florist_rounded),
    );
  }
}

Widget settingsView(double el) {
  return ValueListenableBuilder<double>(
    valueListenable: textScale,
    builder: (context, currentTextScale, _) {
      return ValueListenableBuilder2<String, int>(
        first: lyricsAnimationMode,
        second: lyricsOffsetMs,
        builder: (context, animationMode, offsetMs, _) {
          return ValueListenableBuilder3<double, String, String>(
            first: uiScale,
            second: themeId,
            third: backgroundId,
            builder: (context, scale, theme, bgId, _) {
              final desktop =
                  MediaQuery.sizeOf(context).width >=
                  (responsiveLayout['desktopWidth'] as double);
              final sectionFontSize = desktop
                  ? playerTypography['desktopSectionTitle']!
                  : el * 1.2;
              final textMinimum = textScaleSettings['min'] as double;
              final textMaximum = textScaleSettings['max'] as double;
              final offsetMinimum = lyricPresentation['offsetMinMs'] as int;
              final offsetMaximum = lyricPresentation['offsetMaxMs'] as int;
              final offsetStep = lyricPresentation['offsetStepMs'] as int;

              Widget sectionTitle(String value) {
                return Text(
                  value,
                  style: TextStyle(
                    color: colors['text'],
                    fontSize: sectionFontSize,
                    fontWeight: FontWeight.w600,
                  ),
                );
              }

              return Align(
                alignment: Alignment.topLeft,
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    maxWidth: responsiveLayout['settingsMaxWidth'] as double,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      sectionTitle(texts['themes']!),
                      SizedBox(height: el * .6),
                      Wrap(
                        spacing: el * .6,
                        runSpacing: el * .6,
                        children: [
                          for (final option in themes.keys)
                            ChoiceChip(
                              label: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(iconsMap['theme'], size: el * 1.2),
                                  SizedBox(width: el * .4),
                                  Text(
                                    option[0].toUpperCase() +
                                        option.substring(1),
                                  ),
                                ],
                              ),
                              selected: theme == option,
                              onSelected: (_) => setTheme(option),
                            ),
                        ],
                      ),
                      SizedBox(height: el * 1.2),
                      sectionTitle(texts['backgrounds']!),
                      SizedBox(height: el * .6),
                      Wrap(
                        spacing: el * .6,
                        runSpacing: el * .6,
                        children: [
                          for (final id in backgrounds.keys)
                            ChoiceChip(
                              label: Text(
                                id[0].toUpperCase() + id.substring(1),
                              ),
                              selected: bgId == id,
                              onSelected: (_) => setBackground(id),
                            ),
                        ],
                      ),
                      SizedBox(height: el * 1.2),
                      sectionTitle(texts['sizes']!),
                      SizedBox(height: el * .6),
                      Row(
                        children: [
                          Icon(iconsMap['size'], color: colors['textDim']),
                          SizedBox(width: el * .6),
                          Expanded(
                            child: Slider(
                              value: scale,
                              min: uiScaleSettings['min'] as double,
                              max: uiScaleSettings['max'] as double,
                              divisions: uiScaleSettings['divisions'] as int,
                              label: scale.toStringAsFixed(2),
                              activeColor: colors['accent'],
                              inactiveColor: colors['text']!.withValues(
                                alpha: .25,
                              ),
                              onChanged: previewUiScale,
                              onChangeEnd: setUiScale,
                            ),
                          ),
                        ],
                      ),
                      SizedBox(height: el * .4),
                      Wrap(
                        spacing: el * .6,
                        runSpacing: el * .6,
                        children: [
                          for (final preset in sizePresets)
                            InputChip(
                              label: Text(preset['label'] as String),
                              selected: (preset['value'] as double) == scale,
                              onPressed: () =>
                                  setUiScale(preset['value'] as double),
                            ),
                        ],
                      ),
                      SizedBox(height: el * 1.2),
                      sectionTitle(texts['textSize']!),
                      SizedBox(height: el * .3),
                      Text(
                        texts['textSizeHint']!,
                        style: TextStyle(color: colors['textDim']),
                      ),
                      SizedBox(height: el * .4),
                      Row(
                        children: [
                          Icon(iconsMap['textSize'], color: colors['textDim']),
                          SizedBox(width: el * .6),
                          Expanded(
                            child: Slider(
                              value: currentTextScale.clamp(
                                textMinimum,
                                textMaximum,
                              ),
                              min: textMinimum,
                              max: textMaximum,
                              divisions: textScaleSettings['divisions'] as int,
                              label: currentTextScale.toStringAsFixed(2),
                              activeColor: colors['accent'],
                              inactiveColor: colors['text']!.withValues(
                                alpha: .25,
                              ),
                              onChanged: previewTextScale,
                              onChangeEnd: setTextScale,
                            ),
                          ),
                        ],
                      ),
                      Wrap(
                        spacing: el * .6,
                        runSpacing: el * .6,
                        children: [
                          for (final preset in textScalePresets)
                            InputChip(
                              label: Text(preset['label'] as String),
                              selected:
                                  (preset['value'] as double) ==
                                  currentTextScale,
                              onPressed: () =>
                                  setTextScale(preset['value'] as double),
                            ),
                        ],
                      ),
                      SizedBox(height: el * 1.2),
                      sectionTitle(texts['lyricsAnimation']!),
                      SizedBox(height: el * .6),
                      Wrap(
                        spacing: el * .6,
                        runSpacing: el * .6,
                        children: [
                          for (final mode in lyricsAnimationModes)
                            ChoiceChip(
                              label: Text(
                                texts[lyricsAnimationModeTextKeys[mode]]!,
                              ),
                              selected: animationMode == mode,
                              onSelected: (_) => setLyricsAnimationMode(mode),
                            ),
                        ],
                      ),
                      SizedBox(height: el * 1.2),
                      sectionTitle(texts['lyricsTiming']!),
                      SizedBox(height: el * .4),
                      Row(
                        children: [
                          Icon(iconsMap['karaoke'], color: colors['textDim']),
                          SizedBox(width: el * .6),
                          Expanded(
                            child: Slider(
                              value: offsetMs
                                  .clamp(offsetMinimum, offsetMaximum)
                                  .toDouble(),
                              min: offsetMinimum.toDouble(),
                              max: offsetMaximum.toDouble(),
                              divisions:
                                  (offsetMaximum - offsetMinimum) ~/ offsetStep,
                              label: formatLyricsOffset(offsetMs),
                              activeColor: colors['accent'],
                              inactiveColor: colors['text']!.withValues(
                                alpha: .25,
                              ),
                              onChanged: previewLyricsOffsetMs,
                              onChangeEnd: (value) =>
                                  setLyricsOffsetMs(value.round()),
                            ),
                          ),
                          SizedBox(width: el * .5),
                          SizedBox(
                            width: el * 3.5,
                            child: Text(
                              formatLyricsOffset(offsetMs),
                              textAlign: TextAlign.end,
                              style: TextStyle(color: colors['textDim']),
                            ),
                          ),
                        ],
                      ),
                      Align(
                        alignment: Alignment.centerRight,
                        child: TextButton(
                          onPressed: offsetMs == 0
                              ? null
                              : () => setLyricsOffsetMs(0),
                          child: Text(texts['reset']!),
                        ),
                      ),
                      SizedBox(height: el * .8),
                      const Align(
                        alignment: Alignment.center,
                        child: _AuthorFlowerMark(),
                      ),
                    ],
                  ),
                ),
              );
            },
          );
        },
      );
    },
  );
}

class ValueListenableBuilder2<A, B> extends StatelessWidget {
  const ValueListenableBuilder2({
    super.key,
    required this.first,
    required this.second,
    required this.builder,
  });

  final ValueListenable<A> first;
  final ValueListenable<B> second;
  final Widget Function(BuildContext, A, B, Widget?) builder;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<A>(
      valueListenable: first,
      builder: (context, a, _) {
        return ValueListenableBuilder<B>(
          valueListenable: second,
          builder: (context, b, __) => builder(context, a, b, null),
        );
      },
    );
  }
}

Widget _buildSettingsTopBar(BuildContext ctx, double el) {
  final iconBtn =
      buttons['icon'] as Widget Function(IconData, VoidCallback, double);

  return Row(
    children: [
      iconBtn(iconsMap['back']!, goBackPage, el),
      SizedBox(width: el),
      Expanded(
        child: Text(
          texts['settings']!,
          style: TextStyle(
            fontSize: pageTitleFontSize(ctx, el),
            color: colors['text'],
            fontWeight: FontWeight.w700,
          ),
          overflow: TextOverflow.ellipsis,
        ),
      ),
    ],
  );
}

final Map<String, List<Color>> backgrounds = {
  'sky': [const Color(0xFFBFD9FF), const Color(0xFF9FC3FF)],
  'ocean': [
    const Color(0xFF005C97),
    const Color(0xFF363795),
    const Color(0xFF0083B0),
  ],
  'sunset': [
    const Color(0xFFff7e5f), // оранжевый
    const Color(0xFFfeb47b), // персиковый
    const Color(0xFF8a2387), // фиолетовый
  ],
  'forest': [const Color(0xFF136a8a), const Color(0xFF267871)],
};

class AnimatedAppBackground extends StatefulWidget {
  const AnimatedAppBackground({required this.id, super.key});

  final String id;

  @override
  State<AnimatedAppBackground> createState() => _AnimatedAppBackgroundState();
}

class _AnimatedAppBackgroundState extends State<AnimatedAppBackground> {
  bool _flip = false;

  @override
  void initState() {
    super.initState();
    _startAnimation();
  }

  @override
  void didUpdateWidget(AnimatedAppBackground oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.id != widget.id) {
      _flip = false;
      _startAnimation();
    }
  }

  void _startAnimation() {
    if (widget.id == 'sky') return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() => _flip = !_flip);
    });
  }

  @override
  Widget build(BuildContext context) {
    if (widget.id == 'sky') {
      return AnimatedContainer(
        duration: Duration(
          milliseconds: responsiveLayout['themeTransitionMs'] as int,
        ),
        curve: Curves.easeInOutCubic,
        decoration: appBackground(),
      );
    }
    final values = backgrounds[widget.id] ?? backgrounds['sky']!;
    return AnimatedContainer(
      duration: Duration(
        milliseconds: responsiveLayout['backgroundAnimationMs'] as int,
      ),
      curve: Curves.easeInOut,
      onEnd: () {
        if (mounted) setState(() => _flip = !_flip);
      },
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: _flip ? values.reversed.toList() : values,
        ),
      ),
    );
  }
}

Widget scanStatusBar(double el) {
  return ValueListenableBuilder3<bool, String?, String?>(
    first: isScanningLibrary,
    second: scanErrorMessage,
    third: libraryOperationErrorMessage,
    builder: (context, scanning, scanError, operationError, _) {
      final error = scanError ?? operationError;
      if (!scanning && error == null) return const SizedBox.shrink();
      return Padding(
        padding: EdgeInsets.only(top: el * .45),
        child: Row(
          children: [
            if (scanning) ...[
              SizedBox.square(
                dimension: el,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: colors['accent'],
                ),
              ),
              SizedBox(width: el * .45),
              Expanded(
                child: Text(
                  texts['scanningLibrary']!,
                  style: TextStyle(color: colors['textDim'], fontSize: el * .8),
                ),
              ),
            ] else ...[
              Expanded(
                child: Text(
                  error!,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: colors['textDim'], fontSize: el * .8),
                ),
              ),
              if (scanError != null)
                TextButton(
                  onPressed: () =>
                      unawaited(runAutomaticLibraryMaintenance(force: true)),
                  child: Text(texts['retry']!),
                )
              else
                IconButton(
                  onPressed: () => libraryOperationErrorMessage.value = null,
                  icon: Icon(iconsMap['close'], color: colors['textDim']),
                ),
            ],
          ],
        ),
      );
    },
  );
}

void setBackground(String id) {
  if (!backgrounds.containsKey(id)) return;
  backgroundId.value = id;
  prefsBox?.put('background', id);
}

class ValueListenableBuilder3<A, B, C> extends StatelessWidget {
  const ValueListenableBuilder3({
    super.key,
    required this.first,
    required this.second,
    required this.third,
    required this.builder,
  });

  final ValueListenable<A> first;
  final ValueListenable<B> second;
  final ValueListenable<C> third;
  final Widget Function(BuildContext, A, B, C, Widget?) builder;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<A>(
      valueListenable: first,
      builder: (context, a, _) {
        return ValueListenableBuilder<B>(
          valueListenable: second,
          builder: (context, b, __) {
            return ValueListenableBuilder<C>(
              valueListenable: third,
              builder: (context, c, ___) => builder(context, a, b, c, null),
            );
          },
        );
      },
    );
  }
}

const _closeNotificationControl = MediaControl(
  androidIcon: 'drawable/ic_notification_close',
  label: 'Close',
  action: MediaAction.stop,
);

MediaControl _playbackModeNotificationControl() {
  return switch (playbackMode.value) {
    'repeatAll' => const MediaControl(
      androidIcon: 'drawable/ic_notification_repeat',
      label: 'Repeat all',
      action: MediaAction.fastForward,
    ),
    'repeatOne' => const MediaControl(
      androidIcon: 'drawable/ic_notification_repeat_one',
      label: 'Repeat one',
      action: MediaAction.fastForward,
    ),
    'shuffle' => const MediaControl(
      androidIcon: 'drawable/ic_notification_shuffle',
      label: 'Shuffle',
      action: MediaAction.fastForward,
    ),
    _ => const MediaControl(
      androidIcon: 'drawable/ic_notification_order',
      label: 'Play in order',
      action: MediaAction.fastForward,
    ),
  };
}

List<MediaControl> _notificationControls(bool playing) => [
  _playbackModeNotificationControl(),
  MediaControl.skipToPrevious,
  playing ? MediaControl.pause : MediaControl.play,
  MediaControl.skipToNext,
  _closeNotificationControl,
];

class AppAudioHandler extends BaseAudioHandler with SeekHandler {
  bool _sessionActive = false;

  AppAudioHandler() {
    playbackState.add(
      PlaybackState(
        controls: const [],
        systemActions: {
          MediaAction.seek,
          MediaAction.seekForward,
          MediaAction.seekBackward,
        },
        playing: false,
        processingState: AudioProcessingState.idle,
      ),
    );
  }

  void syncPlayerState(PlayerState state) {
    if (!_hasOpenSession) {
      _publishIdleState();
      return;
    }
    final playing = state == PlayerState.playing;
    _broadcast(
      playing: playing,
      processingState: state == PlayerState.stopped
          ? AudioProcessingState.ready
          : null,
    );
  }

  void syncPosition(Duration position) {
    if (!_hasOpenSession) return;
    _broadcast(position: position);
  }

  void syncDuration(Duration duration) {
    if (!_hasOpenSession) return;
    final item = mediaItem.value;
    if (item != null) mediaItem.add(item.copyWith(duration: duration));
  }

  void syncPlaybackMode() {
    if (!_hasOpenSession) return;
    _broadcast();
  }

  void publishLoading(MediaItem item) {
    _sessionActive = true;
    mediaItem.add(item);
    playbackState.add(
      playbackState.value.copyWith(
        controls: _notificationControls(false),
        androidCompactActionIndices: const [0, 2, 4],
        repeatMode: _notificationRepeatMode,
        shuffleMode: _notificationShuffleMode,
        playing: false,
        processingState: AudioProcessingState.loading,
        updatePosition: Duration.zero,
      ),
    );
  }

  bool get _hasOpenSession =>
      _sessionActive && currentId.value != null && mediaItem.value != null;

  void _broadcast({
    bool? playing,
    Duration? position,
    AudioProcessingState? processingState,
  }) {
    if (!_hasOpenSession) {
      _publishIdleState();
      return;
    }
    final curPlaying = playing ?? playbackState.value.playing;
    final pos = position ?? (playbackState.value.position);
    final currentProcessing = playbackState.value.processingState;
    final nextProcessing =
        processingState ??
        (currentProcessing == AudioProcessingState.loading
            ? AudioProcessingState.ready
            : currentProcessing);
    playbackState.add(
      playbackState.value.copyWith(
        controls: _notificationControls(curPlaying),
        androidCompactActionIndices: const [0, 2, 4],
        repeatMode: _notificationRepeatMode,
        shuffleMode: _notificationShuffleMode,
        playing: curPlaying,
        processingState: nextProcessing,
        updatePosition: pos,
      ),
    );
  }

  void publishStopped() {
    _sessionActive = false;
    mediaItem.add(null);
    _publishIdleState();
  }

  void _publishIdleState() {
    playbackState.add(
      playbackState.value.copyWith(
        controls: const [],
        playing: false,
        processingState: AudioProcessingState.idle,
        updatePosition: Duration.zero,
        bufferedPosition: Duration.zero,
      ),
    );
  }

  @override
  Future<void> play() => resumePlayback();
  @override
  Future<void> pause() => audio.pause();
  @override
  Future<void> stop() async {
    await stopPlaybackSession();
    await super.stop();
  }

  @override
  Future<void> seek(Duration position) => audio.seek(position);
  @override
  Future<void> skipToNext() => playNext();
  @override
  Future<void> skipToPrevious() => playPrev();
  @override
  Future<void> fastForward() async => cyclePlaybackMode();
}

AudioServiceRepeatMode get _notificationRepeatMode =>
    playbackMode.value == 'repeatOne'
    ? AudioServiceRepeatMode.one
    : playbackMode.value == 'repeatAll'
    ? AudioServiceRepeatMode.all
    : AudioServiceRepeatMode.none;

AudioServiceShuffleMode get _notificationShuffleMode =>
    playbackMode.value == 'shuffle'
    ? AudioServiceShuffleMode.all
    : AudioServiceShuffleMode.none;
