import 'package:flutter/widgets.dart';

import '../../services.dart';

// Byte 2.0 © 2026 Apurba Laskar.
//
// Rebuilds its [builder] only when the song with [id] starts or stops
// playing, not on every song change (song lists have dozens of rows).

class CurrentIs extends StatefulWidget {
  final String id;
  final Widget Function(BuildContext context, bool isCurrent) builder;
  const CurrentIs({super.key, required this.id, required this.builder});
  @override
  State<CurrentIs> createState() => _CurrentIsState();
}

class _CurrentIsState extends State<CurrentIs> {
  late bool _is = _read();

  bool _read() => Services.i.player.current.value?.id == widget.id;

  @override
  void initState() {
    super.initState();
    Services.i.player.current.addListener(_changed);
  }

  @override
  void didUpdateWidget(covariant CurrentIs old) {
    super.didUpdateWidget(old);
    if (old.id != widget.id) _is = _read();
  }

  @override
  void dispose() {
    Services.i.player.current.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    final v = _read();
    if (v != _is && mounted) setState(() => _is = v);
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, _is);
}
