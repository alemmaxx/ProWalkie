import 'package:flutter/material.dart';

const ground = Color(0xFF00704A); // hijau Starbucks
const onGround = Colors.white;
const onGroundSoft = Color(0xFFCFE6DD);
const paper = Colors.white;
const ink = Color(0xFF1F2A44);
const inkSoft = Color(0xFF56607A);
const blue = Color(0xFF2C74E0);
const red = Color(0xFFE0463B);
const orange = Color(0xFFEE8420);
const green = Color(0xFF23A047);
const purple = Color(0xFF7B4FD0);
const tileColors = [blue, red, orange, green, purple];

TextStyle disp(double s, {Color c = ink, FontWeight w = FontWeight.w700}) =>
    TextStyle(fontFamily: 'Fredoka', fontSize: s, fontWeight: w, color: c, height: 1.1);

ThemeData proTheme() {
  const b = OutlineInputBorder(
      borderRadius: BorderRadius.all(Radius.circular(14)),
      borderSide: BorderSide(color: ink, width: 3));
  return ThemeData(
    useMaterial3: true,
    fontFamily: 'Andika',
    scaffoldBackgroundColor: ground,
    colorScheme: ColorScheme.fromSeed(seedColor: blue),
    inputDecorationTheme: const InputDecorationTheme(
        filled: true,
        fillColor: Color(0xFFFFFDF4),
        border: b,
        enabledBorder: b,
        focusedBorder: b),
  );
}

class _DotPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size s) {
    final p = Paint()..color = const Color(0x1AFFFFFF);
    for (double y = 1; y < s.height; y += 22) {
      for (double x = 1; x < s.width; x += 22) {
        canvas.drawCircle(Offset(x, y), 1.5, p);
      }
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter old) => false;
}

class Screen extends StatelessWidget {
  final Widget child;
  const Screen({super.key, required this.child});
  @override
  Widget build(BuildContext context) => Scaffold(
        body: Stack(children: [
          Positioned.fill(child: CustomPaint(painter: _DotPainter())),
          SafeArea(child: child),
        ]),
      );
}

class Sticker extends StatelessWidget {
  final Widget child;
  final EdgeInsets padding;
  final Color color;
  final double radius, depth;
  const Sticker(
      {super.key,
      required this.child,
      this.padding = const EdgeInsets.all(18),
      this.color = paper,
      this.radius = 24,
      this.depth = 6});
  @override
  Widget build(BuildContext context) => Container(
        padding: padding,
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(radius),
          border: Border.all(color: ink, width: 3),
          boxShadow: [BoxShadow(color: ink, offset: Offset(0, depth), blurRadius: 0)],
        ),
        child: child,
      );
}

class Chunky extends StatefulWidget {
  final String label;
  final IconData? icon;
  final VoidCallback? onTap;
  final Color bg, fg;
  final bool small;
  const Chunky(
      {super.key,
      required this.label,
      this.icon,
      this.onTap,
      this.bg = blue,
      this.fg = Colors.white,
      this.small = false});
  @override
  State<Chunky> createState() => _ChunkyState();
}

class _ChunkyState extends State<Chunky> {
  bool down = false;
  @override
  Widget build(BuildContext context) {
    final sm = widget.small;
    return GestureDetector(
      onTapDown: (_) => setState(() => down = true),
      onTapUp: (_) => setState(() => down = false),
      onTapCancel: () => setState(() => down = false),
      onTap: widget.onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 60),
        transform: Matrix4.translationValues(0, down ? 3 : 0, 0),
        padding: EdgeInsets.symmetric(horizontal: sm ? 14 : 22, vertical: sm ? 8 : 12),
        decoration: BoxDecoration(
          color: widget.bg,
          borderRadius: BorderRadius.circular(sm ? 14 : 18),
          border: Border.all(color: ink, width: 3),
          boxShadow: [
            BoxShadow(color: ink, offset: Offset(0, down ? 2 : (sm ? 4 : 5)), blurRadius: 0)
          ],
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          if (widget.icon != null) ...[
            Icon(widget.icon, color: widget.fg, size: sm ? 20 : 26),
            const SizedBox(width: 8),
          ],
          Text(widget.label, style: disp(sm ? 16 : 21, c: widget.fg)),
        ]),
      ),
    );
  }
}

class Logo extends StatelessWidget {
  final double size;
  const Logo({super.key, this.size = 46});
  @override
  Widget build(BuildContext context) => Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: blue,
          shape: BoxShape.circle,
          border: Border.all(color: ink, width: 3),
          boxShadow: const [BoxShadow(color: ink, offset: Offset(0, 3), blurRadius: 0)],
        ),
        child: Icon(Icons.mic, color: Colors.white, size: size * 0.55),
      );
}

Future<String?> ask(BuildContext context, String title, {bool dismiss = true}) {
  final c = TextEditingController();
  return showDialog<String>(
    context: context,
    barrierDismissible: dismiss,
    builder: (ctx) => Dialog(
      backgroundColor: Colors.transparent,
      elevation: 0,
      child: Sticker(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(title, style: disp(24)),
            const SizedBox(height: 14),
            TextField(controller: c, autofocus: true, style: const TextStyle(fontSize: 20)),
            const SizedBox(height: 18),
            Center(child: Chunky(label: 'OK', onTap: () => Navigator.pop(ctx, c.text.trim()))),
          ],
        ),
      ),
    ),
  );
}
