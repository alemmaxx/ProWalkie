import 'dart:io' show Directory, File;
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:agora_rtc_engine/agora_rtc_engine.dart';
import 'package:agora_token_service/agora_token_service.dart';
import 'package:audioplayers/audioplayers.dart' as ap;
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'config.dart';
import 'theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(
      options: const FirebaseOptions(
          apiKey: firebaseApiKey,
          appId: firebaseAppId,
          messagingSenderId: firebaseSenderId,
          projectId: firebaseProjectId));
  if (FirebaseAuth.instance.currentUser == null) {
    await FirebaseAuth.instance.signInAnonymously();
  }
  runApp(MaterialApp(
      title: 'ProWalkie',
      debugShowCheckedModeBanner: false,
      theme: proTheme(),
      home: const Home()));
}

final db = FirebaseFirestore.instance;
String get uid => FirebaseAuth.instance.currentUser!.uid;

class Home extends StatefulWidget {
  const Home({super.key});
  @override
  State<Home> createState() => _HomeState();
}

class _HomeState extends State<Home> {
  String? name;
  String? code;

  @override
  void initState() {
    super.initState();
    db.collection('users').doc(uid).get().then((d) async {
      if (!mounted) return;
      if (d.exists) {
        final m = d.data() as Map<String, dynamic>;
        var c = m['code'] as String?;
        if (c == null || c.isEmpty) {
          c = await _newCode();
          await db.collection('users').doc(uid).update({'code': c});
        }
        if (mounted) {
          setState(() {
            name = m['name'] as String?;
            code = c;
          });
        }
      } else {
        WidgetsBinding.instance.addPostFrameCallback((_) => _askName());
      }
    });
  }

  void _snack(String t) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t)));
    }
  }

  Future<String> _newCode() async {
    const chars = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
    final r = math.Random.secure();
    while (true) {
      final c = List.generate(6, (_) => chars[r.nextInt(chars.length)]).join();
      final q = await db.collection('users').where('code', isEqualTo: c).limit(1).get();
      if (q.docs.isEmpty) return c;
    }
  }

  Future<void> _askName() async {
    final n = await ask(context, 'Siapa nama awak?', dismiss: false);
    if (n == null || n.isEmpty) return _askName();
    final c = await _newCode();
    await db.collection('users').doc(uid).set({'name': n, 'code': c});
    if (mounted) {
      setState(() {
        name = n;
        code = c;
      });
    }
  }

  Future<void> _create() async {
    final n = await ask(context, 'Nama group');
    if (n == null || n.isEmpty) return;
    await db.collection('groups').add({'name': n, 'members': [uid]});
  }

  Future<void> _join() async {
    final c = await ask(context, 'Masukkan kod group');
    if (c == null || c.isEmpty) return;
    try {
      await db.collection('groups').doc(c).update({
        'members': FieldValue.arrayUnion([uid])
      });
    } catch (_) {
      _snack('Kod tak sah');
    }
  }

  Future<void> _addFriend() async {
    final raw = await ask(context, 'Kunci kawan');
    if (raw == null || raw.isEmpty) return;
    try {
      final q = await db
          .collection('users')
          .where('code', isEqualTo: raw.trim().toUpperCase())
          .limit(1)
          .get();
      if (q.docs.isEmpty) return _snack('Kunci tak jumpa');
      final other = q.docs.first;
      if (other.id == uid) return _snack('Itu kunci awak sendiri');
      final otherName = ((other.data())['name'] ?? 'Kawan') as String;
      final ids = [uid, other.id]..sort();
      final ref = db.collection('groups').doc('d_${ids[0]}_${ids[1]}');
      final snap = await ref.get();
      if (!snap.exists) {
        await ref.set({
          'type': 'direct',
          'members': ids,
          'names': {uid: name ?? 'Kawan', other.id: otherName},
        });
      }
      if (!mounted) return;
      Navigator.push(context,
          MaterialPageRoute(builder: (_) => Talk(id: ref.id, title: otherName)));
    } catch (e) {
      _snack('Gagal: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Screen(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 20),
        child: Column(children: [
          Row(children: [
            const Logo(),
            const SizedBox(width: 10),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('ProWalkie', style: disp(24)),
                Text(name == null ? 'Cakap terus guna data' : 'Hai, $name!',
                    style: disp(14, c: inkSoft, w: FontWeight.w500)),
              ]),
            ),
            Chunky(label: 'Masuk', icon: Icons.login, small: true, bg: paper, fg: ink, onTap: _join),
          ]),
          const SizedBox(height: 14),
          Sticker(
            depth: 4,
            radius: 18,
            padding: const EdgeInsets.fromLTRB(14, 6, 6, 6),
            child: Row(children: [
              const Icon(Icons.vpn_key_rounded, color: ink),
              const SizedBox(width: 10),
              Text('Kunci saya', style: disp(15, c: inkSoft, w: FontWeight.w500)),
              const SizedBox(width: 10),
              Expanded(child: Text(code ?? '...', style: disp(24, c: blue))),
              IconButton(
                tooltip: 'Salin kunci',
                icon: const Icon(Icons.copy_rounded, color: ink),
                onPressed: code == null
                    ? null
                    : () {
                        Clipboard.setData(ClipboardData(text: code!));
                        _snack('Kunci disalin');
                      },
              ),
            ]),
          ),
          const SizedBox(height: 16),
          Expanded(
            child: StreamBuilder<QuerySnapshot>(
              stream: db.collection('groups').where('members', arrayContains: uid).snapshots(),
              builder: (c, s) {
                if (!s.hasData) return const Center(child: CircularProgressIndicator());
                final docs = s.data!.docs;
                if (docs.isEmpty) {
                  return ListView(children: [
                    Sticker(
                      child: Column(children: [
                        const Logo(size: 84),
                        const SizedBox(height: 14),
                        Text('Belum ada sesiapa', style: disp(28), textAlign: TextAlign.center),
                        const SizedBox(height: 6),
                        const Text(
                            'Tambah kawan guna kunci mereka, atau buat group dan kongsi kodnya.',
                            textAlign: TextAlign.center,
                            style: TextStyle(color: inkSoft)),
                      ]),
                    ),
                  ]);
                }
                return ListView.separated(
                  itemCount: docs.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 16),
                  itemBuilder: (_, i) {
                    final d = docs[i];
                    final m = d.data() as Map<String, dynamic>;
                    final isDirect = m['type'] == 'direct';
                    final members = (m['members'] as List?) ?? [];
                    var title = (m['name'] ?? '') as String;
                    if (isDirect) {
                      final oid = members.firstWhere((x) => x != uid, orElse: () => '');
                      title = (((m['names'] as Map?)?[oid]) ?? 'Kawan') as String;
                    }
                    final col = tileColors[i % tileColors.length];
                    return GestureDetector(
                      onTap: () => Navigator.push(context,
                          MaterialPageRoute(builder: (_) => Talk(id: d.id, title: title))),
                      child: Sticker(
                        padding: const EdgeInsets.all(14),
                        child: Row(children: [
                          Container(
                            width: 52,
                            height: 52,
                            alignment: Alignment.center,
                            decoration: BoxDecoration(
                                color: col,
                                borderRadius: BorderRadius.circular(isDirect ? 26 : 16),
                                border: Border.all(color: ink, width: 3)),
                            child: isDirect
                                ? const Icon(Icons.person, color: Colors.white, size: 30)
                                : Text(title.isEmpty ? '?' : title[0].toUpperCase(),
                                    style: disp(26, c: Colors.white)),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                              Text(title, style: disp(21), overflow: TextOverflow.ellipsis),
                              Text(isDirect ? 'Individu' : 'Group, ${members.length} ahli',
                                  style: const TextStyle(color: inkSoft, fontSize: 14)),
                            ]),
                          ),
                          if (!isDirect)
                            IconButton(
                              tooltip: 'Salin kod group',
                              icon: const Icon(Icons.copy_rounded, color: ink),
                              onPressed: () {
                                Clipboard.setData(ClipboardData(text: d.id));
                                _snack('Kod group disalin');
                              },
                            ),
                        ]),
                      ),
                    );
                  },
                );
              },
            ),
          ),
          const SizedBox(height: 12),
          Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
            Chunky(label: 'Group', icon: Icons.group_add, onTap: _create),
            Chunky(label: 'Kawan', icon: Icons.person_add, bg: green, onTap: _addFriend),
          ]),
        ]),
      ),
    );
  }
}

class Talk extends StatefulWidget {
  final String id, title;
  const Talk({super.key, required this.id, required this.title});
  @override
  State<Talk> createState() => _TalkState();
}

class _TalkState extends State<Talk> with SingleTickerProviderStateMixin {
  RtcEngine? engine;
  final remote = <int>{};
  bool talking = false, ready = false;
  String? err;
  final speaking = <int>{};
  bool recording = false;
  String? recPath;
  String? lastClip;
  final ap.AudioPlayer player = ap.AudioPlayer();
  late final Uint8List dingBytes = _makeDing();
  late final AnimationController pulse = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 900));

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
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
          if (mounted) setState(() => ready = true);
          try {
            await e.setEnableSpeakerphone(true);
          } catch (_) {}
        },
        onError: (code, msg) {
          if (mounted) setState(() => err = 'Ralat $code $msg');
        },
        onConnectionStateChanged: (c, state, reason) {
          if (mounted && state == ConnectionStateType.connectionStateFailed) {
            setState(() => err = 'Gagal sambung: $reason');
          }
        },
        onUserJoined: (c, u, el) {
          if (mounted) setState(() => remote.add(u));
        },
        onUserOffline: (c, u, r) {
          speaking.remove(u);
          if (speaking.isEmpty) _stopRec();
          if (mounted) setState(() => remote.remove(u));
        },
        onRemoteAudioStateChanged: (c, u, state, reason, el) {
          if (state == RemoteAudioState.remoteAudioStateDecoding) {
            final first = speaking.isEmpty;
            speaking.add(u);
            if (first) {
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
          channelName: widget.id,
          uid: '0',
          role: RtcRole.publisher,
          expireTimestamp: DateTime.now().millisecondsSinceEpoch ~/ 1000 + 86400,
        );
      }
      stage = 'joinChannel';
      await e.joinChannel(
          token: token,
          channelId: widget.id,
          uid: 0,
          options: const ChannelMediaOptions(
              clientRoleType: ClientRoleType.clientRoleBroadcaster,
              autoSubscribeAudio: true,
              publishMicrophoneTrack: false));
    } catch (ex) {
      if (mounted) setState(() => err = 'Ralat ($stage): $ex');
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
      if (mounted) setState(() => lastClip = p);
    } catch (_) {}
  }

  Future<void> _replay() async {
    final p = lastClip;
    if (p == null) return;
    try {
      await player.play(ap.DeviceFileSource(p));
    } catch (ex) {
      if (mounted) setState(() => err = 'Ralat ulang: $ex');
    }
  }

  Future<void> _talk(bool on) async {
    if (talking == on) return;
    if (on) {
      HapticFeedback.heavyImpact();
      pulse.repeat();
    } else {
      HapticFeedback.lightImpact();
      pulse.stop();
      pulse.reset();
    }
    setState(() => talking = on);
    if (ready) {
      try {
        await engine?.updateChannelMediaOptions(
            ChannelMediaOptions(publishMicrophoneTrack: on));
      } catch (ex) {
        if (mounted) setState(() => err = 'Ralat mic: $ex');
      }
    }
  }

  @override
  void dispose() {
    pulse.dispose();
    player.dispose();
    engine?.leaveChannel();
    engine?.release();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Screen(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
        child: Column(children: [
          Align(
            alignment: Alignment.centerLeft,
            child: Chunky(
                label: 'Group',
                icon: Icons.arrow_back,
                small: true,
                bg: paper,
                fg: ink,
                onTap: () => Navigator.pop(context)),
          ),
          const SizedBox(height: 18),
          Sticker(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Text(widget.title, style: disp(30), textAlign: TextAlign.center),
              const SizedBox(height: 6),
              Text(err ?? (ready ? 'Tersambung' : 'Menyambung...'),
                  textAlign: TextAlign.center,
                  style: TextStyle(color: err != null ? red : inkSoft)),
            ]),
          ),
          const SizedBox(height: 16),
          Sticker(
            radius: 16,
            depth: 0,
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 10),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Text('${ready ? remote.length + 1 : 0}', style: disp(34, c: blue)),
              Text('Online', style: disp(15, w: FontWeight.w600)),
            ]),
          ),
          const SizedBox(height: 14),
          Chunky(
            label: lastClip == null ? 'Tiada klip' : 'Ulang',
            icon: Icons.replay,
            small: true,
            bg: lastClip == null ? paper : orange,
            fg: lastClip == null ? inkSoft : Colors.white,
            onTap: lastClip == null ? null : _replay,
          ),
          Expanded(
            child: Center(
              child: SizedBox(
                width: 300,
                height: 300,
                child: Stack(alignment: Alignment.center, children: [
                  if (talking)
                    AnimatedBuilder(
                      animation: pulse,
                      builder: (_, __) => Stack(alignment: Alignment.center, children: [
                        for (final o in [0.0, 0.5])
                          Container(
                            width: 200 + 90 * ((pulse.value + o) % 1.0),
                            height: 200 + 90 * ((pulse.value + o) % 1.0),
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              border: Border.all(
                                  color: red.withOpacity(1 - ((pulse.value + o) % 1.0)),
                                  width: 5),
                            ),
                          ),
                      ]),
                    ),
                  GestureDetector(
                    onTapDown: (_) => _talk(true),
                    onTapUp: (_) => _talk(false),
                    onTapCancel: () => _talk(false),
                    child: AnimatedScale(
                      scale: talking ? 0.88 : 1.0,
                      duration: Duration(milliseconds: talking ? 120 : 600),
                      curve: talking ? Curves.easeOut : Curves.elasticOut,
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 80),
                        width: 200,
                        height: 200,
                        transform: Matrix4.translationValues(0, talking ? 6 : 0, 0),
                        decoration: BoxDecoration(
                          color: talking ? red : blue,
                          shape: BoxShape.circle,
                          border: Border.all(color: ink, width: 4),
                          boxShadow: [
                            BoxShadow(
                                color: ink,
                                offset: Offset(0, talking ? 3 : 10),
                                blurRadius: 0)
                          ],
                        ),
                        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                          const Icon(Icons.mic, size: 84, color: Colors.white),
                          Text(talking ? 'CAKAP' : 'TAHAN', style: disp(22, c: Colors.white)),
                        ]),
                      ),
                    ),
                  ),
                ]),
              ),
            ),
          ),
          Text(talking ? (ready ? 'Sedang cakap...' : 'Belum tersambung') : 'Tekan & tahan untuk cakap',
              style: disp(18, c: inkSoft, w: FontWeight.w600)),
        ]),
      ),
    );
  }
}
