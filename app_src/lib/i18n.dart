import 'package:flutter/foundation.dart';

final lang = ValueNotifier<String>('ms');

String tr(String ms, String en) => lang.value == 'ms' ? ms : en;
