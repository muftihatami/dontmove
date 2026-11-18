import 'package:flutter/material.dart';

import 'api.dart';
import 'theme.dart';
import 'widgets.dart';

// ---------------------------------------------------------------- TH-01 … TH-04 Thread

class ThreadScreen extends StatefulWidget {
  const ThreadScreen({super.key, required this.id});

  final String id;

  @override
  State<ThreadScreen> createState() => _ThreadScreenState();
}

class _ThreadScreenState extends State<ThreadScreen> {
  Json? data;
  bool notFound = false;
  Object? error;
  Json? replyTo;
  bool sending = false;
  final text = TextEditingController();
  final focus = FocusNode();

  @override
  void initState() {
    super.initState();
    load();
  }

  @override
  void dispose() {
    text.dispose();
    focus.dispose();
    super.dispose();
  }

  Future<void> load() async {
    try {
      final d = await Api.getThread(widget.id);
      if (mounted) {
        setState(() {
          data = d;
          error = null;
        });
      }
    } on ApiError catch (e) {
      if (!mounted) return;
      setState(() {
        if (e.status == 404) {
          notFound = true;
        } else {
          error = e;
        }
      });
    }
  }

  Json get thread => data!['thread'] as Json;
  List<Json> get comments => (data!['comments'] as List).cast<Json>();
  bool get closed => data!['closed'] == true;
  Json? get myAlias => data!['my_alias'] as Json?;

  // ------------------------------------------------------------ aksi

  Future<void> send() async {
    var body = text.text.trim();
    if (body.isEmpty) return;
    final target = replyTo;
    // K3: membalas sebuah balasan → server menaruhnya di bawah komentar tingkat atas,
    // jadi rujukan nama ditulis di teks.
    if (target != null && target['parent_id'] != null) {
      final name = (target['alias'] as Json)['label'] as String;
      if (!body.startsWith('@$name')) body = '@$name $body';
    }
    setState(() => sending = true);
    try {
      final out = await Api.createComment(widget.id, body, parentId: target?['id'] as String?);
      text.clear();
      setState(() => replyTo = null);
      if (out['alias_new'] == true && mounted) {
        final name = ((out['comment'] as Json)['alias'] as Json)['label'];
        showNote(context, 'Di thread ini kamu $name. Di thread lain namamu berbeda.');
      }
      await load();
    } on ApiError catch (e) {
      if (!mounted) return;
      if (e.code == 'quota_exceeded' && e.retryAt != null) {
        showNote(context, 'Kamu sudah mencapai 60 komentar dalam 24 jam. Bisa lagi sekitar pukul ${clock(e.retryAt!)}.');
      } else {
        showError(context, e);
        if (e.code == 'thread_closed') await load();
      }
    }
    if (mounted) setState(() => sending = false);
  }

  Future<bool> confirm(String title, String body, String action) async {
    final ok = await showModalBottomSheet<bool>(
      context: context,
      backgroundColor: C.paper,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text(title, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            Text(body, style: const TextStyle(fontSize: 15, height: 1.5, color: C.ink2)),
            const SizedBox(height: 20),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: C.stop),
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(action),
            ),
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Batal')),
          ]),
        ),
      ),
    );
    return ok == true;
  }

  Future<void> deleteComment(Json c, int liveReplies) async {
    final body = liveReplies > 0
        ? 'Komentar ini sudah dibalas $liveReplies orang. Teksnya akan diganti "Dihapus penulisnya" '
            'supaya balasan mereka tetap bisa dibaca.'
        : 'Komentar ini akan hilang sepenuhnya.';
    if (!await confirm('Hapus komentarmu?', body, 'Hapus')) return;
    try {
      await Api.deleteComment(c['id'] as String);
      await load();
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> deleteThread() async {
    final hasReplies = comments.isNotEmpty;
    final body = hasReplies
        ? 'Thread ini sudah dibalas. Teksnya akan diganti "Dihapus penulisnya". Balasan yang ada tetap bisa '
            'dibaca, tapi thread ini keluar dari timeline dan tidak menerima balasan baru.'
        : 'Thread ini akan hilang sepenuhnya.';
    if (!await confirm('Hapus thread ini?', body, 'Hapus')) return;
    try {
      await Api.deleteThread(widget.id);
      if (!mounted) return;
      if (hasReplies) {
        await load();
      } else {
        Navigator.pop(context);
      }
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> moreFor(Json c, int liveReplies) async {
    if (c['is_mine'] == true) {
      await deleteComment(c, liveReplies);
      return;
    }
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: C.paper,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
            title: const Text('Laporkan'),
            onTap: () {
              Navigator.pop(ctx);
              showNote(context, 'Laporkan hadir bersama fitur keamanan (F3).');
            },
          ),
          ListTile(
            title: const Text('Blokir'),
            onTap: () {
              Navigator.pop(ctx);
              showNote(context, 'Blokir hadir bersama fitur keamanan (F3).');
            },
          ),
          ListTile(title: const Text('Batal', style: TextStyle(color: C.ink3)), onTap: () => Navigator.pop(ctx)),
        ]),
      ),
    );
  }

  // ------------------------------------------------------------ tampilan

  @override
  Widget build(BuildContext context) {
    if (notFound) {
      return Scaffold(
        appBar: AppBar(title: const Text('Thread')),
        body: const Center(child: Text('Thread tidak ditemukan.', style: TextStyle(color: C.ink2))),
      );
    }
    if (data == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Thread')),
        body: Center(
          child: error == null
              ? const CircularProgressIndicator(color: C.ink)
              : TextButton(onPressed: load, child: const Text('Gagal memuat. Coba lagi')),
        ),
      );
    }
    final t = thread;
    final tops = comments.where((c) => c['parent_id'] == null).toList();
    final replies = <String, List<Json>>{};
    for (final c in comments) {
      final p = c['parent_id'] as String?;
      if (p != null) replies.putIfAbsent(p, () => []).add(c);
    }
    final canDeleteThread = t['is_mine'] == true && t['deleted'] != true;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Thread'),
        actions: [
          if (canDeleteThread)
            PopupMenuButton<String>(
              onSelected: (_) => deleteThread(),
              itemBuilder: (_) => const [PopupMenuItem(value: 'hapus', child: Text('Hapus thread'))],
            ),
        ],
      ),
      body: Column(children: [
        Expanded(
          child: RefreshIndicator(
            color: C.ink,
            onRefresh: load,
            child: ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 24), children: [
              WhoRow(alias: t['alias'] as Json, time: t['time'] as String, isAuthor: true, isMine: t['is_mine'] == true),
              const SizedBox(height: 10),
              if (t['deleted'] == true)
                const Tombstone()
              else
                SelectableText(t['body'] as String, style: const TextStyle(fontSize: 16, height: 1.55)),
              const SizedBox(height: 12),
              Text(
                (t['reply_count'] as num) == 0 ? 'Belum ada balasan' : '${t['reply_count']} balasan',
                style: const TextStyle(color: C.ink3, fontSize: 13),
              ),
              const SizedBox(height: 4),
              for (final c in tops) ...[
                const Divider(height: 24),
                _comment(c, live(replies[c['id']])),
                for (final r in replies[c['id']] ?? const <Json>[])
                  Container(
                    margin: const EdgeInsets.only(left: 18, top: 10),
                    padding: const EdgeInsets.only(left: 12),
                    decoration: const BoxDecoration(border: Border(left: BorderSide(color: C.rule, width: 2))),
                    child: _comment(r, 0),
                  ),
              ],
            ]),
          ),
        ),
        if (closed)
          Container(
            width: double.infinity,
            decoration: const BoxDecoration(border: Border(top: BorderSide(color: C.rule))),
            padding: const EdgeInsets.fromLTRB(20, 14, 20, 18),
            child: const SafeArea(
              top: false,
              child: Text(
                'Penulis menghapus thread ini. Balasan yang ada tetap bisa dibaca, '
                'tapi thread ini tidak menerima balasan baru.',
                textAlign: TextAlign.center,
                style: TextStyle(color: C.ink3, fontSize: 13, height: 1.45),
              ),
            ),
          )
        else
          _composer(),
      ]),
    );
  }

  int live(List<Json>? rs) => (rs ?? const <Json>[]).where((r) => r['deleted'] != true).length;

  Widget _comment(Json c, int liveReplies) {
    final deleted = c['deleted'] == true;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      WhoRow(
        alias: c['alias'] as Json,
        time: c['time'] as String,
        isAuthor: c['is_author'] == true,
        isMine: c['is_mine'] == true,
      ),
      const SizedBox(height: 6),
      if (deleted)
        const Tombstone()
      else
        SelectableText(c['body'] as String, style: const TextStyle(fontSize: 15, height: 1.5)),
      if (!deleted && !closed)
        Row(children: [
          _action('Balas', () {
            setState(() => replyTo = c);
            focus.requestFocus();
          }),
          if (c['is_mine'] != true)
            _action('Ajak bicara', () => showNote(context, 'Ajak bicara hadir bersama fitur chat (F2).'), strong: true),
          const Spacer(),
          IconButton(
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.more_horiz, color: C.ink3, size: 20),
            onPressed: () => moreFor(c, liveReplies),
          ),
        ]),
    ]);
  }

  Widget _action(String label, VoidCallback onTap, {bool strong = false}) => TextButton(
        style: TextButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          minimumSize: const Size(0, 36),
          foregroundColor: strong ? C.ink : C.ink3,
          textStyle: TextStyle(fontSize: 13, fontWeight: strong ? FontWeight.w600 : FontWeight.w500),
        ),
        onPressed: onTap,
        child: Text(label),
      );

  Widget _composer() {
    final mine = myAlias;
    return Container(
      decoration: const BoxDecoration(color: C.paper, border: Border(top: BorderSide(color: C.rule))),
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      child: SafeArea(
        top: false,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (replyTo != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Row(children: [
                Expanded(
                  child: Text('Membalas ${(replyTo!['alias'] as Json)['label']}',
                      style: const TextStyle(fontSize: 13, color: C.ink2)),
                ),
                InkWell(
                  onTap: () => setState(() => replyTo = null),
                  child: const Padding(padding: EdgeInsets.all(4), child: Icon(Icons.close, size: 16, color: C.ink3)),
                ),
              ]),
            ),
          Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
            Expanded(
              child: TextField(
                controller: text,
                focusNode: focus,
                minLines: 1,
                maxLines: 5,
                maxLength: 1000,
                textCapitalization: TextCapitalization.sentences,
                decoration: InputDecoration(
                  hintText: 'Tulis balasan…',
                  counterText: '',
                  isDense: true,
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(20)),
                  enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(20), borderSide: const BorderSide(color: C.rule)),
                ),
              ),
            ),
            const SizedBox(width: 8),
            IconButton.filled(
              style: IconButton.styleFrom(backgroundColor: C.ink, foregroundColor: C.paper),
              onPressed: sending ? null : send,
              icon: sending
                  ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: C.paper))
                  : const Icon(Icons.arrow_upward, size: 20),
            ),
          ]),
          Padding(
            padding: const EdgeInsets.only(left: 6, top: 6),
            child: Text(
              mine == null ? 'Kamu belum punya nama di thread ini.' : 'Di thread ini kamu ${mine['label']}.',
              style: const TextStyle(fontSize: 12, color: C.ink3),
            ),
          ),
        ]),
      ),
    );
  }
}
