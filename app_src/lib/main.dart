import 'package:agora_rtc_engine/agora_rtc_engine.dart';
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

  @override
  void initState() {
    super.initState();
    db.collection('users').doc(uid).get().then((d) {
      if (!mounted) return;
      if (d.exists) {
        setState(() => name = d['name'] as String?);
      } else {
        WidgetsBinding.instance.addPostFrameCallback((_) => _askName());
      }
    });
  }

  Future<void> _askName() async {
    final n = await ask(context, 'Siapa nama awak?', dismiss: false);
    if (n == null || n.isEmpty) return _askName();
    await db.collection('users').doc(uid).set({'name': n});
    if (mounted) setState(() => name = n);
  }

  Future<void> _create() async {
    final n = await ask(context, 'Nama group');
    if (n == null || n.isEmpty) return;
    await db.collection('groups').add({'name': n, 'members': [uid]});
  }

  Future<void> _join() async {
    final code = await ask(context, 'Masukkan kod group');
    if (code == null || code.isEmpty) return;
    try {
      await db.collection('groups').doc(code).update({
        'members': FieldValue.arrayUnion([uid])
      });
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('Kod tak sah')));
      }
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
          const SizedBox(height: 18),
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
                        Text('Belum ada group', style: disp(28), textAlign: TextAlign.center),
                        const SizedBox(height: 6),
                        const Text('Buat group baru atau masukkan kod daripada kawan.',
                            textAlign: TextAlign.center, style: TextStyle(color: inkSoft)),
                      ]),
                    ),
                  ]);
                }
                return ListView.separated(
                  itemCount: docs.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 16),
                  itemBuilder: (_, i) {
                    final d = docs[i];
                    final col = tileColors[i % tileColors.length];
                    final gname = (d['name'] ?? '') as String;
                    return GestureDetector(
                      onTap: () => Navigator.push(context,
                          MaterialPageRoute(builder: (_) => Talk(id: d.id, title: gname))),
                      child: Sticker(
                        padding: const EdgeInsets.all(14),
                        child: Row(children: [
                          Container(
                            width: 52,
                            height: 52,
                            alignment: Alignment.center,
                            decoration: BoxDecoration(
                                color: col,
                                borderRadius: BorderRadius.circular(16),
                                border: Border.all(color: ink, width: 3)),
                            child: Text(gname.isEmpty ? '?' : gname[0].toUpperCase(),
                                style: disp(26, c: Colors.white)),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                              Text(gname, style: disp(21), overflow: TextOverflow.ellipsis),
                              Text('${(d['members'] as List).length} ahli',
                                  style: const TextStyle(color: inkSoft, fontSize: 14)),
                            ]),
                          ),
                          IconButton(
                            tooltip: 'Salin kod',
                            icon: const Icon(Icons.copy_rounded, color: ink),
                            onPressed: () {
                              Clipboard.setData(ClipboardData(text: d.id));
                              ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(content: Text('Kod group disalin')));
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
          Chunky(label: 'Buat group', icon: Icons.group_add, onTap: _create),
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

class _TalkState extends State<Talk> {
  RtcEngine? engine;
  final remote = <int>{};
  bool talking = false, ready = false;

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    await Permission.microphone.request();
    final e = createAgoraRtcEngine();
    engine = e;
    await e.initialize(const RtcEngineContext(
        appId: agoraAppId,
        channelProfile: ChannelProfileType.channelProfileCommunication));
    e.registerEventHandler(RtcEngineEventHandler(
      onUserJoined: (c, u, el) {
        if (mounted) setState(() => remote.add(u));
      },
      onUserOffline: (c, u, r) {
        if (mounted) setState(() => remote.remove(u));
      },
    ));
    await e.enableAudio();
    await e.setEnableSpeakerphone(true);
    await e.muteLocalAudioStream(true);
    await e.joinChannel(
        token: '',
        channelId: widget.id,
        uid: 0,
        options: const ChannelMediaOptions(
            clientRoleType: ClientRoleType.clientRoleBroadcaster,
            autoSubscribeAudio: true,
            publishMicrophoneTrack: true));
    if (mounted) setState(() => ready = true);
  }

  Future<void> _talk(bool on) async {
    if (!ready) return;
    await engine?.muteLocalAudioStream(!on);
    if (mounted) setState(() => talking = on);
  }

  @override
  void dispose() {
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
              Text(ready ? 'Tersambung' : 'Menyambung...',
                  style: const TextStyle(color: inkSoft)),
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
          Expanded(
            child: Center(
              child: GestureDetector(
                onTapDown: (_) => _talk(true),
                onTapUp: (_) => _talk(false),
                onTapCancel: () => _talk(false),
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
                      BoxShadow(color: ink, offset: Offset(0, talking ? 3 : 10), blurRadius: 0)
                    ],
                  ),
                  child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                    const Icon(Icons.mic, size: 84, color: Colors.white),
                    Text(talking ? 'CAKAP' : 'TAHAN', style: disp(22, c: Colors.white)),
                  ]),
                ),
              ),
            ),
          ),
          Text(talking ? 'Sedang cakap...' : 'Tekan & tahan untuk cakap',
              style: disp(18, c: inkSoft, w: FontWeight.w600)),
        ]),
      ),
    );
  }
}
