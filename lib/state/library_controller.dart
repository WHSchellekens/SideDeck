import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sidedeck/engine/analysis_cache.dart';
import 'package:sidedeck/engine/music_utils.dart';
import 'package:sidedeck/engine/track_analyzer.dart';

class LibraryTrack {
  LibraryTrack({
    required this.path,
    required this.title,
    this.artist = '',
    this.durationMs = 0,
    this.bpm,
    this.key,
  });

  final String path;
  final String title;
  final String artist;
  final int durationMs;
  final double? bpm;
  final int? key;

  bool get hasAnalysis => bpm != null && bpm! > 0;

  LibraryTrack copyWith({double? bpm, int? key}) {
    return LibraryTrack(
      path: path,
      title: title,
      artist: artist,
      durationMs: durationMs,
      bpm: bpm ?? this.bpm,
      key: key ?? this.key,
    );
  }
}

/// One entry in the Local tab's playlist list: a subfolder of the music
/// folder, or one of the [LibraryController.allTracksId] /
/// [LibraryController.pickedFilesId] views.
class LibraryPlaylist {
  const LibraryPlaylist({
    required this.id,
    required this.name,
    required this.trackCount,
  });

  /// Folder path for a subfolder; a fixed id for the built-in views.
  final String id;
  final String name;
  final int trackCount;
}

/// Local library. You pick one music folder (say DJ/); each subfolder of it
/// is a playlist, and opening one loads only that folder's tracks. A folder
/// without subfolders just shows all its tracks. Picking a new folder
/// replaces the library. BPM, key and grid edits live in [AnalysisCache],
/// keyed per file, and are never cleared here.
class LibraryController extends ChangeNotifier {
  LibraryController() {
    restore();
  }

  /// Ids for the built-in views. Folder ids are absolute paths, so these
  /// never collide with one.
  static const allTracksId = 'all';
  static const pickedFilesId = 'picked';

  static const _folderPref = 'library_folder';
  static const _pathsPref = 'library_paths';
  static const _playlistPref = 'library_playlist';

  final AnalysisCache _cache = AnalysisCache.instance;
  /// Tracks of the open view.
  final List<LibraryTrack> tracks = [];
  String query = '';
  TrackSort sort = TrackSort.name;
  bool loading = false;
  String? error;
  /// The music folder you picked.
  String? folderPath;
  /// Subfolders of [folderPath] that hold audio, sorted by name.
  List<LibraryPlaylist> playlists = const [];
  /// Open view: a folder path, [allTracksId], [pickedFilesId], or null for
  /// the playlist list.
  String? openPlaylistId;
  /// Single files added with Pick files.
  final List<String> _extraPaths = [];
  int _allCount = 0;
  int _scanGen = 0;
  bool _disposed = false;

  bool analyzing = false;
  bool _cancelAnalyze = false;
  int analyzeDone = 0;
  int analyzeTotal = 0;
  String? analyzingPath;

  List<LibraryTrack> get filtered {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return List.unmodifiable(tracks);
    return tracks
        .where(
          (t) =>
              t.title.toLowerCase().contains(q) ||
              t.artist.toLowerCase().contains(q),
        )
        .toList();
  }

  int get unanalyzedCount => tracks.where((t) => !t.hasAnalysis).length;

  /// True while the Local tab should show the list of playlists.
  bool get showingPlaylistList => openPlaylistId == null && playlists.isNotEmpty;

  /// Rows for the playlist list: everything, each subfolder, picked files.
  List<LibraryPlaylist> get playlistEntries => [
        LibraryPlaylist(id: allTracksId, name: 'All tracks', trackCount: _allCount),
        ...playlists,
        if (_extraPaths.isNotEmpty)
          LibraryPlaylist(
            id: pickedFilesId,
            name: 'Picked files',
            trackCount: _extraPaths.length,
          ),
      ];

  String get openPlaylistName {
    final id = openPlaylistId;
    if (id == null || id == allTracksId) return 'All tracks';
    if (id == pickedFilesId) return 'Picked files';
    return p.basename(id);
  }

  Future<bool> ensurePermission() async {
    if (!Platform.isAndroid) return true;
    final audio = await Permission.audio.request();
    if (audio.isGranted) return true;
    final storage = await Permission.storage.request();
    return storage.isGranted;
  }

  void _emit() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _cancelAnalyze = true;
    _scanGen++;
    super.dispose();
  }

  Future<void> restore() async {
    loading = true;
    _emit();
    String? view;
    try {
      final prefs = await SharedPreferences.getInstance();
      folderPath = prefs.getString(_folderPref);
      // Drop saved files that are gone (deleted, moved, card removed).
      final saved = prefs.getStringList(_pathsPref) ?? const <String>[];
      _extraPaths.clear();
      for (final path in saved) {
        if (await File(path).exists()) _extraPaths.add(path);
      }
      if (_extraPaths.length != saved.length) {
        await prefs.setStringList(_pathsPref, List.of(_extraPaths));
      }
      if (folderPath != null && folderPath!.isNotEmpty) {
        await _iosAccess(folderPath!);
      }
      await _listPlaylists();
      final savedView = prefs.getString(_playlistPref);
      if (playlists.isEmpty) {
        view = allTracksId;
      } else if (savedView == allTracksId ||
          (savedView == pickedFilesId && _extraPaths.isNotEmpty) ||
          playlists.any((pl) => pl.id == savedView)) {
        view = savedView;
      }
    } catch (e) {
      error = e.toString();
    }
    loading = false;
    if (view != null) {
      await openPlaylist(view);
    } else {
      _emit();
    }
  }

  static const _iosIo = MethodChannel('sidedeck/audio');

  Future<void> _iosAccess(String path) async {
    if (!Platform.isIOS) return;
    try {
      await _iosIo.invokeMethod<bool>('accessPath', path);
    } catch (_) {}
  }

  /// iOS document-picker paths live in tmp; copy into Documents so they survive.
  Future<String> _durablePath(String path) async {
    if (!Platform.isIOS) return path;
    final docs = await getApplicationDocumentsDirectory();
    if (p.isWithin(docs.path, path) || p.equals(p.normalize(docs.path), p.normalize(path))) {
      return path;
    }
    final libDir = Directory(p.join(docs.path, 'library'));
    await libDir.create(recursive: true);
    var dest = p.join(libDir.path, p.basename(path));
    if (p.equals(p.normalize(path), p.normalize(dest))) return path;
    try {
      if (await File(dest).exists() &&
          await File(path).length() == await File(dest).length()) {
        return dest;
      }
      if (await File(dest).exists()) {
        dest = p.join(
          libDir.path,
          '${p.basenameWithoutExtension(path)}_${DateTime.now().millisecondsSinceEpoch}${p.extension(path)}',
        );
      }
      await File(path).copy(dest);
      return dest;
    } catch (_) {
      return path;
    }
  }

  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    if (folderPath != null) {
      await prefs.setString(_folderPref, folderPath!);
    } else {
      await prefs.remove(_folderPref);
    }
    await prefs.setStringList(_pathsPref, List.of(_extraPaths));
  }

  Future<void> _saveOpenPlaylist() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final id = openPlaylistId;
      if (id == null) {
        await prefs.remove(_playlistPref);
      } else {
        await prefs.setString(_playlistPref, id);
      }
    } catch (_) {}
  }

  Future<void> pickFiles() async {
    loading = true;
    error = null;
    _emit();
    var added = false;
    try {
      await ensurePermission();
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: nativeAudioPickerExtensions(),
        allowMultiple: true,
        withData: false,
      );
      if (result != null) {
        for (final f in result.files) {
          final path = f.path;
          if (path == null) continue;
          final durable = await _durablePath(path);
          if (!_extraPaths.contains(durable)) _extraPaths.add(durable);
          added = true;
        }
        await _persist();
        if (added) await _listPlaylists();
      }
    } catch (e) {
      error = e.toString();
    }
    loading = false;
    if (!added) {
      _emit();
      return;
    }
    // Show what you just added: its own list when there are playlists,
    // otherwise everything.
    await openPlaylist(playlists.isEmpty ? allTracksId : pickedFilesId);
  }

  /// Pick the music folder. Replaces the library: tracks and picked files
  /// from before are dropped (their analysis stays cached).
  Future<void> pickFolder() async {
    loading = true;
    error = null;
    _emit();
    try {
      await ensurePermission();
      final dir = await FilePicker.platform.getDirectoryPath();
      if (dir == null) {
        loading = false;
        _emit();
        return;
      }
      await _iosAccess(dir);
      _scanGen++;
      folderPath = dir;
      _extraPaths.clear();
      tracks.clear();
      openPlaylistId = null;
      await _persist();
      await _saveOpenPlaylist();
      await _listPlaylists();
    } catch (e) {
      error = e.toString();
      loading = false;
      _emit();
      return;
    }
    loading = false;
    if (playlists.isEmpty) {
      await openPlaylist(allTracksId);
    } else {
      _emit();
    }
  }

  /// Load one view: a subfolder path, [allTracksId] or [pickedFilesId].
  Future<void> openPlaylist(String id) async {
    final gen = ++_scanGen;
    openPlaylistId = id;
    tracks.clear();
    loading = true;
    error = null;
    _emit();
    try {
      if (id == pickedFilesId) {
        for (final path in _extraPaths) {
          if (gen != _scanGen) return;
          await _addPath(path);
        }
      } else if (id == allTracksId) {
        if (Platform.isIOS) {
          final docs = await getApplicationDocumentsDirectory();
          await _scanInto(docs.path, gen);
        }
        final root = folderPath;
        if (root != null && root.isNotEmpty) await _scanInto(root, gen);
        for (final path in _extraPaths) {
          if (gen != _scanGen) return;
          await _addPath(path);
        }
      } else {
        await _scanInto(id, gen);
      }
    } catch (e) {
      error = e.toString();
    }
    if (gen != _scanGen) return;
    loading = false;
    _emit();
    await _saveOpenPlaylist();
  }

  /// Back to the playlist list.
  void closePlaylist() {
    _scanGen++;
    openPlaylistId = null;
    tracks.clear();
    loading = false;
    _emit();
    _saveOpenPlaylist();
  }

  Future<void> _listPlaylists() async {
    final list = <LibraryPlaylist>[];
    var all = _extraPaths.length;
    final root = folderPath;
    if (root != null && root.isNotEmpty) {
      final dir = Directory(root);
      if (await dir.exists()) {
        final subdirs = <Directory>[];
        await for (final e in dir.list(followLinks: false)) {
          if (e is Directory && !p.basename(e.path).startsWith('.')) {
            subdirs.add(e);
          }
        }
        subdirs.sort(
          (a, b) => p
              .basename(a.path)
              .toLowerCase()
              .compareTo(p.basename(b.path).toLowerCase()),
        );
        for (final d in subdirs) {
          final n = await _countAudio(d.path);
          if (n > 0) {
            list.add(LibraryPlaylist(id: d.path, name: p.basename(d.path), trackCount: n));
          }
        }
        all += await _countAudio(root);
      }
    }
    playlists = list;
    _allCount = all;
  }

  static Future<int> _countAudio(String dirPath) async {
    var n = 0;
    try {
      await for (final e in Directory(dirPath).list(recursive: true, followLinks: false)) {
        if (e is File && isNativeAudioExtension(p.extension(e.path))) n++;
      }
    } catch (_) {}
    return n;
  }

  Future<void> _scanInto(String dirPath, int gen) async {
    final dir = Directory(dirPath);
    if (!await dir.exists()) return;
    var sinceEmit = 0;
    await for (final entity in dir.list(recursive: true, followLinks: false)) {
      if (gen != _scanGen) return;
      if (entity is! File) continue;
      if (!isNativeAudioExtension(p.extension(entity.path))) continue;
      await _addPath(entity.path);
      if (++sinceEmit >= 25) {
        sinceEmit = 0;
        _emit();
      }
    }
  }

  Future<void> _addPath(String path) async {
    if (tracks.any((t) => t.path == path)) return;
    final name = p.basenameWithoutExtension(path);
    final parsed = splitTitleArtist(name);
    double? bpm;
    int? key;
    try {
      final stat = await File(path).stat();
      final cached = await _cache.get(
        path,
        stat.size,
        stat.modified.millisecondsSinceEpoch,
      );
      if (cached != null && cached.bpm > 0) {
        bpm = cached.bpm;
        key = cached.key;
      }
    } catch (_) {}
    tracks.add(LibraryTrack(
      path: path,
      title: parsed.title,
      artist: parsed.artist,
      durationMs: (fileDurationSec(path) * 1000).round(),
      bpm: bpm,
      key: key,
    ));
  }

  void setQuery(String q) {
    query = q;
    _emit();
  }

  void setSort(TrackSort value) {
    if (sort == value) return;
    sort = value;
    _emit();
  }

  void upsertAnalysis(String path, {double? bpm, int? key}) {
    final i = tracks.indexWhere((t) => t.path == path);
    if (i < 0) return;
    tracks[i] = tracks[i].copyWith(bpm: bpm, key: key);
    _emit();
  }

  void cancelAnalyze() {
    _cancelAnalyze = true;
  }

  /// Returns the paths that were successfully analyzed, so callers can refresh
  /// anything holding the old values (e.g. a deck with the track loaded).
  Future<List<String>> analyzePath(String path) async {
    if (analyzing) return const [];
    return _analyzeList([path]);
  }

  Future<List<String>> analyzeMissing() async {
    final pending = tracks.where((t) => !t.hasAnalysis).map((t) => t.path).toList();
    return _analyzeList(pending);
  }

  Future<List<String>> analyzeAll() async {
    return _analyzeList(tracks.map((t) => t.path).toList());
  }

  Future<List<String>> _analyzeList(List<String> paths) async {
    final analyzed = <String>[];
    if (paths.isEmpty || analyzing) return analyzed;
    analyzing = true;
    _cancelAnalyze = false;
    analyzeDone = 0;
    analyzeTotal = paths.length;
    error = null;
    _emit();
    try {
      for (final path in paths) {
        if (_cancelAnalyze) break;
        analyzingPath = path;
        _emit();
        final result = await analyzeTrackFileOffUi(path);
        analyzeDone++;
        if (result == null) continue;
        try {
          final stat = await File(path).stat();
          await _cache.put(
            path: path,
            size: stat.size,
            mtime: stat.modified.millisecondsSinceEpoch,
            bpm: result.bpm,
            key: result.key,
            beatOffset: result.beatOffset,
          );
        } catch (_) {}
        upsertAnalysis(path, bpm: result.bpm, key: result.key);
        analyzed.add(path);
      }
    } catch (e) {
      error = e.toString();
    }
    analyzing = false;
    analyzingPath = null;
    analyzeTotal = 0;
    analyzeDone = 0;
    _emit();
    return analyzed;
  }
}
