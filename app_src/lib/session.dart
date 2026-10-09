import 'dart:async';
import 'dart:io' show Directory, File;
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:agora_rtc_engine/agora_rtc_engine.dart';
import 'package:agora_token_service/agora_token_service.dart';
import 'package:audioplayers/audioplayers.dart' as ap;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'config.dart';
import 'i18n.dart';

final session = VoiceSession();

/// Satu sesi suara pada satu masa. Hidup walaupun skrin Talk ditutup (Kekal online).
class VoiceSession extends ChangeNotifier {
  RtcEngine? engine;
  String? channelId;
  String title = '';
  bool ready = false;
  bool talking = false;
  bool recording = false;
  String? err;
  String? notice;
  String? recPath;
  String? lastClip;
  Timer? idle;
  final remote = <int>{};
  final speaking = <int>{};
  final ap.AudioPlayer player = ap.AudioPlayer();
  late final Uint8List dingBytes = _makeDing();

  bool get active => channelId != null;

  // Agora kira masa dalam channel (bukan masa cakap), jadi keluar bila senyap.
  void _bump() {
    idle?.cancel();
    idle = Timer(const Duration(minutes: 15), () async {
      await leave();
      notice = tr('Keluar automatik: senyap 15 minit',
          'Left automatically: 15 min of silence');
      notifyListeners();
    });
  }

  Future<void> join(String id, String name) async {
    if (channelId == id) return;
    await leave();
    channelId = id;
    title = name;
    err = null;
    notifyListeners();
    var stage = 'permission';
    try {
      await Permission.microphone.request();
      stage = 'initialize';
      final e = createAgoraRtcEngine();
      engine = e;
      await e.initialize(const RtcEngineContext(
          appId: agoraAppId,
          channelProfile: ChannelProfileType.channelProfileCommunication));
      e.registerEventHandler(RtcEngineEventHandler(
        onJoinChannelSuccess: (c, el) async {
          if (engine != e) return;
          ready = true;
          _bump();
          notifyListeners();
          try {
            await e.setEnableSpeakerphone(true);
          } catch (_) {}
        },
        onError: (code, msg) {
          err = '${tr('Ralat', 'Error')} $code $msg';
          notifyListeners();
        },
        onConnectionStateChanged: (c, state, reason) {
          if (state == ConnectionStateType.connectionStateFailed) {
            err = '${tr('Gagal sambung', 'Connection failed')}: $reason';
            notifyListeners();
          }
        },
        onUserJoined: (c, u, el) {
          remote.add(u);
          notifyListeners();
        },
        onUserOffline: (c, u, r) {
          remote.remove(u);
          speaking.remove(u);
          if (speaking.isEmpty) _stopRec();
          notifyListeners();
        },
        onRemoteAudioStateChanged: (c, u, state, reason, el) {
          if (state == RemoteAudioState.remoteAudioStateDecoding) {
            final first = speaking.isEmpty;
            speaking.add(u);
            if (first) {
              _bump();
              _alert();
              _startRec();
            }
          } else if (state == RemoteAudioState.remoteAudioStateStopped ||
              state == RemoteAudioState.remoteAudioStateFailed) {
            speaking.remove(u);
            if (speaking.isEmpty) _stopRec();
          }
        },
      ));
      stage = 'enableAudio';
      try {
        await e.enableAudio();
      } catch (_) {}
      var token = '';
      if (agoraCertificate.isNotEmpty) {
        stage = 'token';
        token = RtcTokenBuilder.build(
          appId: agoraAppId,
          appCertificate: agoraCertificate,
          channelName: id,
          uid: '0',
          role: RtcRole.publisher,
          expireTimestamp: DateTime.now().millisecondsSinceEpoch ~/ 1000 + 86400,
        );
      }
      stage = 'joinChannel';
      await e.joinChannel(
          token: token,
          channelId: id,
          uid: 0,
          options: const ChannelMediaOptions(
              clientRoleType: ClientRoleType.clientRoleBroadcaster,
              autoSubscribeAudio: true,
              publishMicrophoneTrack: false));
    } catch (ex) {
      err = '${tr('Ralat', 'Error')} ($stage): $ex';
      notifyListeners();
    }
  }

  Future<void> leave() async {
    idle?.cancel();
    idle = null;
    if (recording) await _stopRec();
    final e = engine;
    engine = null;
    channelId = null;
    ready = false;
    talking = false;
    remote.clear();
    speaking.clear();
    notifyListeners();
    if (e != null) {
      try {
        await e.leaveChannel();
      } catch (_) {}
      try {
        await e.release();
      } catch (_) {}
    }
  }

  Future<void> setTalk(bool on) async {
    if (talking == on) return;
    if (on) {
      HapticFeedback.heavyImpact();
      _bump();
    } else {
      HapticFeedback.lightImpact();
    }
    talking = on;
    notifyListeners();
    if (ready) {
      try {
        await engine?.updateChannelMediaOptions(
            ChannelMediaOptions(publishMicrophoneTrack: on));
      } catch (ex) {
        err = '${tr('Ralat mic', 'Mic error')}: $ex';
        notifyListeners();
      }
    }
  }

  Uint8List _makeDing() {
    const rate = 16000;
    const n = 4800;
    final bytes = ByteData(44 + n + n);
    void tag(int off, String t) {
      for (var i = 0; i < t.length; i++) {
        bytes.setUint8(off + i, t.codeUnitAt(i));
      }
    }

    tag(0, 'RIFF');
    bytes.setUint32(4, 36 + n + n, Endian.little);
    tag(8, 'WAVE');
    tag(12, 'fmt ');
    bytes.setUint32(16, 16, Endian.little);
    bytes.setUint16(20, 1, Endian.little);
    bytes.setUint16(22, 1, Endian.little);
    bytes.setUint32(24, rate, Endian.little);
    bytes.setUint32(28, rate + rate, Endian.little);
    bytes.setUint16(32, 2, Endian.little);
    bytes.setUint16(34, 16, Endian.little);
    tag(36, 'data');
    bytes.setUint32(40, n + n, Endian.little);
    var phase = 0.0;
    for (var i = 0; i < n; i++) {
      phase += 0.3456;
      final env = 1.0 - i / n;
      final wave = math.sin(phase);
      final amp = wave * 11000;
      final v = (amp * env).round();
      bytes.setInt16(44 + i + i, v, Endian.little);
    }
    return bytes.buffer.asUint8List();
  }

  void _alert() {
    HapticFeedback.mediumImpact();
    player.play(ap.BytesSource(dingBytes)).catchError((_) {});
  }

  Future<void> _startRec() async {
    if (recording) return;
    final path =
        '${Directory.systemTemp.path}/pw_${DateTime.now().millisecondsSinceEpoch}.wav';
    try {
      await engine?.startAudioRecording(
          AudioRecordingConfiguration(filePath: path, sampleRate: 16000));
      recording = true;
      recPath = path;
    } catch (_) {}
  }

  Future<void> _stopRec() async {
    if (!recording) return;
    recording = false;
    try {
      await engine?.stopAudioRecording();
    } catch (_) {}
    final p = recPath;
    if (p == null) return;
    try {
      final f = File(p);
      if (!f.existsSync()) return;
      if (f.lengthSync() < 8000) {
        f.deleteSync();
        return;
      }
      final old = lastClip;
      if (old != null && old != p) {
        try {
          File(old).deleteSync();
        } catch (_) {}
      }
      lastClip = p;
      notifyListeners();
    } catch (_) {}
  }

  Future<void> replay() async {
    final p = lastClip;
    if (p == null) return;
    try {
      await player.play(ap.DeviceFileSource(p));
    } catch (ex) {
      err = '${tr('Ralat ulang', 'Replay error')}: $ex';
      notifyListeners();
    }
  }
}
