import 'dart:async';
import 'dart:math' as math;
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'config.dart';
import 'i18n.dart';
import 'session.dart';
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

// Online = ada degupan (lastSeen) dalam 130 saat terakhir.
bool fresh(dynamic ts) =>
    ts is Timestamp && DateTime.now().difference(ts.toDate()).inSeconds < 130;

class StatusBadge extends StatelessWidget {
  final bool on;
  final String label;
  const StatusBadge({super.key, required this.on, required this.label});
  @override
  Widget build(BuildContext context) => Row(mainAxisSize: MainAxisSize.min, children: [
        Container(
          width: 12,
          height: 12,
          decoration: BoxDecoration(
              color: on ? green : const Color(0xFFB8B8B8),
              shape: BoxShape.circle,
              border: Border.all(color: ink, width: 2)),
        ),
        const SizedBox(width: 5),
        Text(label, style: disp(14, c: on ? green : inkSoft, w: FontWeight.w600)),
      ]);
}

class Home extends StatefulWidget {
  const Home({super.key});
  @override
  State<Home> createState() => _HomeState();
}

class _HomeState extends State<Home> {
  String? name;
  String? code;
  Timer? _beat;
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    session.addListener(_onSession);
    db.collection('users').doc(uid).get().then((d) async {
      if (!mounted) return;
      if (d.exists) {
        final m = d.data() as Map<String, dynamic>;
        var c = m['code'] as String?;
        if (c == null || c.isEmpty) {
          c = await _newCode();
          await db.collection('users').doc(uid).update({'code': c});
        }
        if (m['lang'] is String) lang.value = m['lang'] as String;
        if (mounted) {
          setState(() {
            name = m['name'] as String?;
            code = c;
          });
          _startPresence();
        }
      } else {
        WidgetsBinding.instance.addPostFrameCallback((_) => _askName());
      }
    });
  }

  @override
  void dispose() {
    session.removeListener(_onSession);
    _beat?.cancel();
    _tick?.cancel();
    super.dispose();
  }

  void _onSession() {
    final n = session.notice;
    if (n != null) {
      session.notice = null;
      _snack(n);
    }
  }

  void _startPresence() {
    if (_beat != null) return;
    _heartbeat();
    _beat = Timer.periodic(const Duration(seconds: 60), (_) => _heartbeat());
    _tick = Timer.periodic(const Duration(seconds: 20), (_) {
      if (mounted) setState(() {});
    });
  }

  void _heartbeat() {
    db
        .collection('users')
        .doc(uid)
        .set({'lastSeen': FieldValue.serverTimestamp()}, SetOptions(merge: true))
        .catchError((_) {});
  }

  void _toggleLang() {
    lang.value = lang.value == 'ms' ? 'en' : 'ms';
    db
        .collection('users')
        .doc(uid)
        .set({'lang': lang.value}, SetOptions(merge: true))
        .catchError((_) {});
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
    final n = await ask(context, tr('Siapa nama awak?', 'What is your name?'), dismiss: false);
    if (n == null || n.isEmpty) return _askName();
    final c = await _newCode();
    await db.collection('users').doc(uid).set({'name': n, 'code': c, 'lang': lang.value});
    if (mounted) {
      setState(() {
        name = n;
        code = c;
      });
      _startPresence();
    }
  }

  Future<void> _create() async {
    final n = await ask(context, tr('Nama group', 'Group name'));
    if (n == null || n.isEmpty) return;
    await db.collection('groups').add({'name': n, 'members': [uid]});
  }

  Future<void> _join() async {
    final c = await ask(context, tr('Masukkan kod group', 'Enter group code'));
    if (c == null || c.isEmpty) return;
    try {
      await db.collection('groups').doc(c).update({
        'members': FieldValue.arrayUnion([uid])
      });
    } catch (_) {
      _snack(tr('Kod tak sah', 'Invalid code'));
    }
  }

  Future<void> _addFriend() async {
    final raw = await ask(context, tr('Kunci kawan', 'Friend key'));
    if (raw == null || raw.isEmpty) return;
    try {
      final q = await db
          .collection('users')
          .where('code', isEqualTo: raw.trim().toUpperCase())
          .limit(1)
          .get();
      if (q.docs.isEmpty) return _snack(tr('Kunci tak jumpa', 'Key not found'));
      final other = q.docs.first;
      if (other.id == uid) return _snack(tr('Itu kunci awak sendiri', 'That is your own key'));
      final otherName = ((other.data())['name'] ?? 'Friend') as String;
      final ids = [uid, other.id]..sort();
      final ref = db.collection('groups').doc('d_${ids[0]}_${ids[1]}');
      final snap = await ref.get();
      if (!snap.exists) {
        await ref.set({
          'type': 'direct',
          'members': ids,
          'names': {uid: name ?? 'Friend', other.id: otherName},
        });
      }
      if (!mounted) return;
      Navigator.push(context,
          MaterialPageRoute(builder: (_) => Talk(id: ref.id, title: otherName)));
    } catch (e) {
      _snack('${tr('Gagal', 'Failed')}: $e');
    }
  }

  Widget _status(Map<String, dynamic> m, bool isDirect, List members) {
    if (isDirect) {
      final oid = members.firstWhere((x) => x != uid, orElse: () => '');
      if (oid == '') return const SizedBox.shrink();
      return StreamBuilder<DocumentSnapshot>(
        stream: db.collection('users').doc(oid as String).snapshots(),
        builder: (c, s) {
          final d = s.data?.data() as Map<String, dynamic>?;
          final on = fresh(d?['lastSeen']);
          return StatusBadge(on: on, label: on ? 'Online' : 'Offline');
        },
      );
    }
    final ids = members.take(30).map((e) => e as String).toList();
    if (ids.isEmpty) return const SizedBox.shrink();
    return StreamBuilder<QuerySnapshot>(
      stream: db.collection('users').where(FieldPath.documentId, whereIn: ids).snapshots(),
      builder: (c, s) {
        var on = 0;
        for (final d in s.data?.docs ?? <QueryDocumentSnapshot>[]) {
          final data = d.data() as Map<String, dynamic>;
          if (fresh(data['lastSeen'])) on++;
        }
        return StatusBadge(on: on > 0, label: '$on/${members.length} online');
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([lang, session]),
      builder: (context, _) => Screen(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 20),
          child: Column(children: [
            Row(children: [
              const Logo(),
              const SizedBox(width: 10),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('ProWalkie', style: disp(24, c: onGround)),
                  Text(
                      name == null
                          ? tr('Cakap terus guna data', 'Talk over mobile data')
                          : tr('Hai, $name!', 'Hi, $name!'),
                      style: disp(14, c: onGroundSoft, w: FontWeight.w500)),
                ]),
              ),
              Chunky(
                  label: lang.value == 'ms' ? 'BM|en' : 'bm|EN',
                  small: true,
                  bg: paper,
                  fg: ink,
                  onTap: _toggleLang),
            ]),
            const SizedBox(height: 14),
            Sticker(
              depth: 4,
              radius: 18,
              padding: const EdgeInsets.fromLTRB(14, 6, 6, 6),
              child: Row(children: [
                const Icon(Icons.vpn_key_rounded, color: ink),
                const SizedBox(width: 10),
                Text(tr('Kunci saya', 'My key'), style: disp(15, c: inkSoft, w: FontWeight.w500)),
                const SizedBox(width: 10),
                Expanded(child: Text(code ?? '...', style: disp(24, c: blue))),
                IconButton(
                  tooltip: tr('Salin kunci', 'Copy key'),
                  icon: const Icon(Icons.copy_rounded, color: ink),
                  onPressed: code == null
                      ? null
                      : () {
                          Clipboard.setData(ClipboardData(text: code!));
                          _snack(tr('Kunci disalin', 'Key copied'));
                        },
                ),
              ]),
            ),
            if (session.active) ...[
              const SizedBox(height: 14),
              GestureDetector(
                onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                        builder: (_) => Talk(id: session.channelId!, title: session.title))),
                child: Sticker(
                  depth: 4,
                  radius: 18,
                  color: const Color(0xFFE3F4EA),
                  padding: const EdgeInsets.fromLTRB(14, 8, 8, 8),
                  child: Row(children: [
                    const Icon(Icons.hearing, color: green),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text('${tr('Mendengar', 'Listening')}: ${session.title}',
                          style: disp(17), overflow: TextOverflow.ellipsis),
                    ),
                    Chunky(
                        label: tr('Keluar', 'Leave'),
                        small: true,
                        bg: red,
                        onTap: () => session.leave()),
                  ]),
                ),
              ),
            ],
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
                          Text(tr('Belum ada sesiapa', 'Nobody here yet'),
                              style: disp(28), textAlign: TextAlign.center),
                          const SizedBox(height: 6),
                          Text(
                              tr('Tambah kawan guna kunci mereka, atau buat group dan kongsi kodnya.',
                                  'Add a friend with their key, or create a group and share its code.'),
                              textAlign: TextAlign.center,
                              style: const TextStyle(color: inkSoft)),
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
                        title = (((m['names'] as Map?)?[oid]) ?? 'Friend') as String;
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
                                Text(
                                    isDirect
                                        ? tr('Individu', 'Individual')
                                        : tr('Group, ${members.length} ahli',
                                            'Group, ${members.length} members'),
                                    style: const TextStyle(color: inkSoft, fontSize: 14)),
                              ]),
                            ),
                            _status(m, isDirect, members),
                            if (!isDirect)
                              IconButton(
                                tooltip: tr('Salin kod group', 'Copy group code'),
                                icon: const Icon(Icons.copy_rounded, color: ink),
                                onPressed: () {
                                  Clipboard.setData(ClipboardData(text: d.id));
                                  _snack(tr('Kod group disalin', 'Group code copied'));
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
            Wrap(spacing: 12, runSpacing: 12, alignment: WrapAlignment.center, children: [
              Chunky(label: 'Group', icon: Icons.group_add, onTap: _create),
              Chunky(
                  label: tr('Kawan', 'Friend'),
                  icon: Icons.person_add,
                  bg: orange,
                  onTap: _addFriend),
              Chunky(
                  label: tr('Masuk', 'Join'),
                  icon: Icons.login,
                  bg: paper,
                  fg: ink,
                  onTap: _join),
            ]),
          ]),
        ),
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
  late final AnimationController pulse = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 900));

  @override
  void initState() {
    super.initState();
    session.addListener(_sync);
    HardwareKeyboard.instance.addHandler(_onKey);
    session.join(widget.id, widget.title);
    _sync();
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onKey);
    session.removeListener(_sync);
    pulse.dispose();
    super.dispose();
  }

  void _sync() {
    if (session.talking && !pulse.isAnimating) pulse.repeat();
    if (!session.talking && pulse.isAnimating) {
      pulse.stop();
      pulse.reset();
    }
  }

  // Butang Volume Naik = sama seperti tekan butang cakap.
  bool _onKey(KeyEvent e) {
    if (e.logicalKey == LogicalKeyboardKey.audioVolumeUp) {
      if (e is KeyDownEvent) {
        session.setTalk(true);
      } else if (e is KeyUpEvent) {
        session.setTalk(false);
      }
      return true;
    }
    return false;
  }

  Future<void> _back() async {
    if (!session.active) {
      Navigator.pop(context);
      return;
    }
    final c = await showDialog<String>(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: Colors.transparent,
        elevation: 0,
        child: Sticker(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(tr('Keluar skrin ini?', 'Leave this screen?'), style: disp(24)),
              const SizedBox(height: 10),
              Text(
                  tr('Kekal online: terus mendengar di latar. Guna kuota Agora dan keluar automatik selepas 15 minit senyap.',
                      'Stay online: keep listening in the background. Uses Agora quota and leaves automatically after 15 min of silence.'),
                  style: const TextStyle(color: inkSoft)),
              const SizedBox(height: 16),
              Center(
                  child: Chunky(
                      label: tr('Kekal online', 'Stay online'),
                      icon: Icons.hearing,
                      bg: green,
                      onTap: () => Navigator.pop(ctx, 'stay'))),
              const SizedBox(height: 14),
              Center(
                  child: Chunky(
                      label: tr('Keluar', 'Leave'),
                      icon: Icons.logout,
                      bg: red,
                      onTap: () => Navigator.pop(ctx, 'leave'))),
            ],
          ),
        ),
      ),
    );
    if (c == null) return;
    if (c == 'leave') await session.leave();
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) _back();
      },
      child: ListenableBuilder(
        listenable: Listenable.merge([session, lang]),
        builder: (context, _) {
          final s = session;
          final talking = s.talking;
          final online = s.ready ? s.remote.length + 1 : 0;
          final status = s.err ??
              (s.ready ? tr('Tersambung', 'Connected') : tr('Menyambung...', 'Connecting...'));
          return Screen(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
              child: Column(children: [
                Align(
                  alignment: Alignment.centerLeft,
                  child: Chunky(
                      label: tr('Kembali', 'Back'),
                      icon: Icons.arrow_back,
                      small: true,
                      bg: paper,
                      fg: ink,
                      onTap: _back),
                ),
                const SizedBox(height: 18),
                Sticker(
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    Text(widget.title, style: disp(30), textAlign: TextAlign.center),
                    const SizedBox(height: 6),
                    Text(status,
                        textAlign: TextAlign.center,
                        style: TextStyle(color: s.err != null ? red : inkSoft)),
                  ]),
                ),
                const SizedBox(height: 16),
                Sticker(
                  radius: 16,
                  depth: 0,
                  padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 10),
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    Text('$online', style: disp(34, c: blue)),
                    Text('Online', style: disp(15, w: FontWeight.w600)),
                  ]),
                ),
                const SizedBox(height: 14),
                Chunky(
                  label: s.lastClip == null ? tr('Tiada klip', 'No clip') : tr('Ulang', 'Replay'),
                  icon: Icons.replay,
                  small: true,
                  bg: s.lastClip == null ? paper : orange,
                  fg: s.lastClip == null ? inkSoft : Colors.white,
                  onTap: s.lastClip == null ? null : s.replay,
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
                          onTapDown: (_) => s.setTalk(true),
                          onTapUp: (_) => s.setTalk(false),
                          onTapCancel: () => s.setTalk(false),
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
                                Text(talking ? tr('CAKAP', 'TALK') : tr('TAHAN', 'HOLD'),
                                    style: disp(22, c: Colors.white)),
                              ]),
                            ),
                          ),
                        ),
                      ]),
                    ),
                  ),
                ),
                Text(
                    talking
                        ? (s.ready
                            ? tr('Sedang cakap...', 'Talking...')
                            : tr('Belum tersambung', 'Not connected yet'))
                        : tr('Tekan & tahan untuk cakap', 'Press & hold to talk'),
                    style: disp(18, c: onGround, w: FontWeight.w600)),
                const SizedBox(height: 4),
                Text(tr('Atau tahan butang Volume Naik', 'Or hold the Volume Up key'),
                    style: const TextStyle(color: onGroundSoft, fontSize: 13)),
              ]),
            ),
          );
        },
      ),
    );
  }
}
