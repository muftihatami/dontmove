import 'package:flutter/material.dart';

import 'api.dart';
import 'settings.dart';
import 'theme.dart';
import 'thread.dart';
import 'widgets.dart';

// ---------------------------------------------------------------- kerangka utama

class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int tab = 0;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(index: tab, children: const [TimelineScreen(), ChatPlaceholder()]),
      bottomNavigationBar: NavigationBar(
        selectedIndex: tab,
        backgroundColor: C.paper,
        indicatorColor: C.fill,
        height: 64,
        onDestinationSelected: (i) => setState(() => tab = i),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.notes_outlined), selectedIcon: Icon(Icons.notes), label: 'Timeline'),
          NavigationDestination(
              icon: Icon(Icons.chat_bubble_outline), selectedIcon: Icon(Icons.chat_bubble), label: 'Chat'),
        ],
      ),
    );
  }
}

class ChatPlaceholder extends StatelessWidget {
  const ChatPlaceholder({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Chat')),
      body: const Padding(
        padding: EdgeInsets.all(24),
        child: SysNote(
          'Chat pribadi hadir di tahap berikutnya. Nanti percakapan hanya bisa dimulai dari "Ajak bicara" '
          'di sebuah thread.',
          title: 'Belum tersedia di versi uji ini',
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------- TL-01 Timeline

const _tabs = [('terbaru', 'Terbaru'), ('belum-dibalas', 'Belum dibalas'), ('ramai', 'Ramai')];

class TimelineScreen extends StatefulWidget {
  const TimelineScreen({super.key});

  @override
  State<TimelineScreen> createState() => _TimelineScreenState();
}

class _TimelineScreenState extends State<TimelineScreen> {
  final _keys = List.generate(_tabs.length, (_) => GlobalKey<_FeedListState>());

  Future<void> compose() async {
    final created = await Navigator.push<bool>(context, MaterialPageRoute(builder: (_) => const ComposeScreen()));
    if (created == true) {
      _keys[0].currentState?.reload();
    }
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: _tabs.length,
      child: Scaffold(
        appBar: AppBar(
          title: const Text("Don't Move"),
          actions: [
            IconButton(
              tooltip: 'Pengaturan',
              icon: const Icon(Icons.settings_outlined),
              onPressed: () => Navigator.push(context, MaterialPageRoute<void>(builder: (_) => const SettingsScreen())),
            ),
          ],
          bottom: TabBar(
            isScrollable: true,
            tabAlignment: TabAlignment.start,
            labelColor: C.ink,
            unselectedLabelColor: C.ink3,
            indicatorColor: C.ink,
            dividerColor: C.rule,
            labelStyle: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
            tabs: [for (final t in _tabs) Tab(text: t.$2)],
          ),
        ),
        body: TabBarView(
          children: [for (var i = 0; i < _tabs.length; i++) FeedList(key: _keys[i], tab: _tabs[i].$1)],
        ),
        floatingActionButton: FloatingActionButton.extended(
          onPressed: compose,
          backgroundColor: C.ink,
          foregroundColor: C.paper,
          icon: const Icon(Icons.edit_outlined, size: 18),
          label: const Text('Tulis'),
        ),
      ),
    );
  }
}

class FeedList extends StatefulWidget {
  const FeedList({super.key, required this.tab});

  final String tab;

  @override
  State<FeedList> createState() => _FeedListState();
}

class _FeedListState extends State<FeedList> with AutomaticKeepAliveClientMixin {
  final items = <Json>[];
  String next = '';
  bool loading = true;
  bool loadingMore = false;
  Object? error;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    reload();
  }

  Future<void> reload() async {
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final d = await Api.feed(widget.tab);
      items
        ..clear()
        ..addAll((d['items'] as List).cast<Json>());
      next = d['next'] as String;
    } catch (e) {
      error = e;
    }
    if (mounted) setState(() => loading = false);
  }

  Future<void> more() async {
    setState(() => loadingMore = true);
    try {
      final d = await Api.feed(widget.tab, cursor: next);
      items.addAll((d['items'] as List).cast<Json>());
      next = d['next'] as String;
    } catch (e) {
      if (mounted) showError(context, e);
    }
    if (mounted) setState(() => loadingMore = false);
  }

  Future<void> open(Json t) async {
    await Navigator.push(context, MaterialPageRoute<void>(builder: (_) => ThreadScreen(id: t['id'] as String)));
    reload();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    if (loading && items.isEmpty) {
      return const Center(child: CircularProgressIndicator(color: C.ink));
    }
    if (error != null && items.isEmpty) {
      return _Empty(
        text: error is ApiError ? (error as ApiError).message : 'Gagal memuat.',
        action: TextButton(onPressed: reload, child: const Text('Coba lagi')),
      );
    }
    final empty = switch (widget.tab) {
      'belum-dibalas' => 'Semua thread dalam 24 jam terakhir sudah dibalas. Terima kasih sudah menemani.',
      'ramai' => 'Belum ada thread yang ramai. Thread masuk ke sini setelah dibalas orang lain.',
      _ => 'Belum ada thread. Jadilah yang pertama menulis.',
    };
    return RefreshIndicator(
      color: C.ink,
      onRefresh: reload,
      child: items.isEmpty
          ? ListView(children: [_Empty(text: empty)])
          : ListView.separated(
              padding: const EdgeInsets.only(bottom: 96),
              itemCount: items.length + (next.isNotEmpty ? 1 : 0),
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (context, i) {
                if (i == items.length) {
                  return Padding(
                    padding: const EdgeInsets.all(16),
                    child: loadingMore
                        ? const Center(child: CircularProgressIndicator(color: C.ink))
                        : OutlinedButton(onPressed: more, child: const Text('Muat lagi')),
                  );
                }
                return PostCard(thread: items[i], onTap: () => open(items[i]));
              },
            ),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty({required this.text, this.action});

  final String text;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 48, 24, 24),
      child: Column(children: [
        Text(text, textAlign: TextAlign.center, style: const TextStyle(color: C.ink2, fontSize: 15, height: 1.5)),
        if (action != null) action!,
      ]),
    );
  }
}

class PostCard extends StatelessWidget {
  const PostCard({super.key, required this.thread, required this.onTap});

  final Json thread;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final replies = (thread['reply_count'] as num).toInt();
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          WhoRow(alias: thread['alias'] as Json, time: thread['time'] as String, isMine: thread['is_mine'] == true),
          const SizedBox(height: 8),
          Text(thread['body'] as String? ?? '',
              maxLines: 3, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 15, height: 1.45)),
          const SizedBox(height: 8),
          Text(replies == 0 ? 'Belum ada balasan' : '$replies balasan',
              style: TextStyle(fontSize: 13, color: replies == 0 ? C.ink2 : C.ink3)),
        ]),
      ),
    );
  }
}

// ---------------------------------------------------------------- TL-02 / TL-03 Tulis

class ComposeScreen extends StatefulWidget {
  const ComposeScreen({super.key});

  @override
  State<ComposeScreen> createState() => _ComposeScreenState();
}

class _ComposeScreenState extends State<ComposeScreen> {
  final text = TextEditingController();
  bool busy = false;
  int? remaining;
  DateTime? blockedUntil;

  @override
  void initState() {
    super.initState();
    text.addListener(() => setState(() {}));
    Api.quota().then((q) {
      if (mounted) setState(() => remaining = (q['threads_remaining'] as num).toInt());
    }).catchError((Object _) {});
  }

  @override
  void dispose() {
    text.dispose();
    super.dispose();
  }

  Future<void> send() async {
    setState(() => busy = true);
    try {
      await Api.createThread(text.text);
      if (mounted) Navigator.pop(context, true);
    } on ApiError catch (e) {
      if (!mounted) return;
      if (e.code == 'quota_exceeded') {
        setState(() => blockedUntil = e.retryAt ?? DateTime.now().add(const Duration(hours: 1)));
      } else {
        showError(context, e);
      }
    }
    if (mounted) setState(() => busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final n = text.text.trim().runes.length;
    final canSend = n > 0 && n <= 1000 && !busy && blockedUntil == null && remaining != 0;
    final blocked = blockedUntil != null || remaining == 0;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Thread baru'),
        leading: IconButton(icon: const Icon(Icons.close), onPressed: () => Navigator.pop(context)),
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            if (blocked)
              SysNote(
                blockedUntil != null
                    ? 'Kamu sudah menulis 10 thread dalam 24 jam terakhir. Kamu bisa menulis lagi sekitar pukul '
                        '${clock(blockedUntil!)}.\n\nSambil menunggu, kamu tetap bisa membalas thread orang lain.'
                    : 'Kamu sudah menulis 10 thread dalam 24 jam terakhir. Sambil menunggu, kamu tetap bisa '
                        'membalas thread orang lain.',
                warn: true,
              )
            else
              const SysNote('Namamu di thread ini dibuat otomatis saat kamu mengirim. '
                  'Di thread lain kamu akan punya nama lain.'),
            const SizedBox(height: 12),
            Expanded(
              child: TextField(
                controller: text,
                autofocus: !blocked,
                enabled: !blocked,
                maxLines: null,
                expands: true,
                textAlignVertical: TextAlignVertical.top,
                style: const TextStyle(fontSize: 16, height: 1.55),
                decoration: const InputDecoration(
                  hintText: 'Ceritakan apa saja.',
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                  disabledBorder: InputBorder.none,
                  contentPadding: EdgeInsets.zero,
                ),
              ),
            ),
            const Text('Hanya teks. Jangan tulis nomor HP, alamat, atau akun media sosial.',
                style: TextStyle(fontSize: 12, color: C.ink3)),
            const SizedBox(height: 10),
            Row(children: [
              Text('$n / 1.000', style: TextStyle(fontSize: 13, color: n > 1000 ? C.stop : C.ink3)),
              const Spacer(),
              // K5: sisa kuota hanya tampil saat tinggal 3 atau kurang.
              if (remaining != null && remaining! > 0 && remaining! <= 3)
                Padding(
                  padding: const EdgeInsets.only(right: 12),
                  child: Text('Sisa $remaining thread hari ini', style: const TextStyle(fontSize: 13, color: C.ink3)),
                ),
              SizedBox(
                width: 110,
                child: BusyButton(label: 'Kirim', busy: busy, onPressed: canSend ? send : null),
              ),
            ]),
          ]),
        ),
      ),
    );
  }
}
