import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:openvpn_flutter/openvpn_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() => runApp(const TunnelApp());

class Server {
  final String host, ip, country, cc, config;
  final int ping, speed; // speed in bits/s
  Server(this.host, this.ip, this.country, this.cc, this.ping, this.speed, this.config);
  String get flag => cc.length == 2
      ? String.fromCharCodes(cc.toUpperCase().codeUnits.map((c) => c + 127397))
      : '🌐';
}

/// Free server list from VPN Gate (volunteer-run OpenVPN servers).
Future<List<Server>> fetchServers() async {
  final r = await http.get(Uri.parse('https://www.vpngate.net/api/iphone/'))
      .timeout(const Duration(seconds: 20));
  if (r.statusCode != 200) throw 'HTTP ${r.statusCode}';
  final out = <Server>[];
  for (final line in const LineSplitter().convert(r.body)) {
    if (line.startsWith('*') || line.startsWith('#') || line.trim().isEmpty) continue;
    final f = line.split(',');
    if (f.length < 15) continue;
    try {
      final cfg = utf8.decode(base64.decode(f[14].trim()));
      out.add(Server(f[0], f[1], f[5], f[6], int.tryParse(f[3]) ?? 999,
          int.tryParse(f[4]) ?? 0, cfg));
    } catch (_) {}
  }
  out.sort((a, b) => b.speed.compareTo(a.speed));
  return out.take(150).toList();
}

class TunnelApp extends StatelessWidget {
  const TunnelApp({super.key});
  @override
  Widget build(BuildContext context) {
    const teal = Color(0xFF0B8F7C);
    return MaterialApp(
      title: 'Tunnel',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorSchemeSeed: teal, useMaterial3: true),
      darkTheme: ThemeData(
          colorSchemeSeed: const Color(0xFF3FD8C0),
          brightness: Brightness.dark,
          useMaterial3: true),
      home: const Home(),
    );
  }
}

class Home extends StatefulWidget {
  const Home({super.key});
  @override
  State<Home> createState() => _HomeState();
}

class _HomeState extends State<Home> {
  late final OpenVPN vpn;
  List<Server> servers = [];
  Set<String> favs = {};
  Server? sel;
  String stage = 'disconnected';
  String? error;
  bool loading = true;
  int tab = 0;
  DateTime? since;
  Timer? ticker;
  String q = '';

  bool get on => stage == 'connected';
  bool get busy => !on && stage != 'disconnected' && stage != 'error' && stage != 'denied';

  @override
  void initState() {
    super.initState();
    vpn = OpenVPN(
      onVpnStageChanged: (s, _) {
        if (!mounted) return;
        setState(() {
          stage = s.name;
          if (s == VPNStage.connected) {
            since = DateTime.now();
            ticker = Timer.periodic(const Duration(seconds: 1), (_) => setState(() {}));
          } else {
            ticker?.cancel();
            since = null;
          }
        });
      },
    );
    vpn.initialize(
        groupIdentifier: 'group.tunnel', providerBundleIdentifier: 'tunnel.ext',
        localizedDescription: 'Tunnel');
    _loadPrefs();
    refresh();
  }

  Future<void> _loadPrefs() async {
    final p = await SharedPreferences.getInstance();
    setState(() => favs = (p.getStringList('favs') ?? []).toSet());
  }

  Future<void> _toggleFav(Server s) async {
    favs.contains(s.ip) ? favs.remove(s.ip) : favs.add(s.ip);
    (await SharedPreferences.getInstance()).setStringList('favs', favs.toList());
    setState(() {});
  }

  Future<void> refresh() async {
    setState(() { loading = true; error = null; });
    try {
      servers = await fetchServers();
      sel ??= servers.isNotEmpty ? servers.first : null;
    } catch (e) {
      error = 'Couldn’t load servers. Check your connection and pull to retry.';
    }
    if (mounted) setState(() => loading = false);
  }

  void toggle() {
    if (on || busy) { vpn.disconnect(); return; }
    final s = sel;
    if (s == null) return;
    vpn.connect(s.config, '${s.country} ${s.host}',
        username: 'vpn', password: 'vpn', certIsRequired: true);
  }

  String get elapsed {
    if (since == null) return '00:00:00';
    final d = DateTime.now().difference(since!);
    String p(int n) => n.toString().padLeft(2, '0');
    return '${p(d.inHours)}:${p(d.inMinutes % 60)}:${p(d.inSeconds % 60)}';
  }

  @override
  void dispose() { ticker?.cancel(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Tunnel', style: TextStyle(fontWeight: FontWeight.w800)),
        actions: [Padding(padding: const EdgeInsets.only(right: 16),
          child: Chip(label: Text(on ? 'Protected' : busy ? 'Connecting' : 'Not protected')))],
      ),
      body: tab == 0 ? _home(cs) : _list(cs),
      bottomNavigationBar: NavigationBar(
        selectedIndex: tab,
        onDestinationSelected: (i) => setState(() => tab = i),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.power_settings_new), label: 'Connect'),
          NavigationDestination(icon: Icon(Icons.public), label: 'Servers'),
        ],
      ),
    );
  }

  Widget _home(ColorScheme cs) {
    final s = sel;
    return ListView(padding: const EdgeInsets.all(20), children: [
      const SizedBox(height: 16),
      Center(child: GestureDetector(
        onTap: toggle,
        child: Stack(alignment: Alignment.center, children: [
          SizedBox(width: 230, height: 230,
            child: CircularProgressIndicator(
              value: on ? 1 : busy ? null : 0, strokeWidth: 8,
              backgroundColor: cs.outlineVariant)),
          Container(width: 190, height: 190,
            decoration: BoxDecoration(shape: BoxShape.circle,
              color: on ? cs.primary : cs.surfaceContainer),
            child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
              Text(on ? 'On' : busy ? '…' : 'Off',
                style: TextStyle(fontSize: 30, fontWeight: FontWeight.w800,
                  color: on ? cs.onPrimary : cs.onSurface)),
              Text(on ? (s?.country ?? '') : 'Tap to connect',
                style: TextStyle(color: on ? cs.onPrimary : cs.onSurfaceVariant)),
            ])),
        ]))),
      const SizedBox(height: 16),
      Center(child: Text(on ? 'Time connected $elapsed'
        : stage == 'error' || stage == 'denied'
          ? 'Couldn’t connect. Try another server.'
          : 'Your traffic is not encrypted.')),
      const SizedBox(height: 20),
      Card(child: ListTile(
        leading: Text(s?.flag ?? '🌐', style: const TextStyle(fontSize: 28)),
        title: Text(s == null ? 'No server selected' : s.country),
        subtitle: Text(s == null ? 'Open Servers to pick one' : '${s.ip} · ${s.ping} ms'),
        trailing: const Text('Change'),
        onTap: () => setState(() => tab = 1))),
      if (error != null) Padding(padding: const EdgeInsets.only(top: 12),
        child: Text(error!, style: TextStyle(color: cs.error))),
      const SizedBox(height: 16),
      FilledButton(onPressed: s == null ? null : toggle,
        style: FilledButton.styleFrom(padding: const EdgeInsets.all(16)),
        child: Text(on ? 'Disconnect' : busy ? 'Cancel' : 'Connect')),
    ]);
  }

  Widget _list(ColorScheme cs) {
    final rows = servers.where((s) =>
      ('${s.country} ${s.host}').toLowerCase().contains(q.toLowerCase())).toList()
      ..sort((a, b) {
        final f = (favs.contains(b.ip) ? 1 : 0) - (favs.contains(a.ip) ? 1 : 0);
        return f != 0 ? f : b.speed.compareTo(a.speed);
      });
    return Column(children: [
      Padding(padding: const EdgeInsets.all(12),
        child: TextField(onChanged: (v) => setState(() => q = v),
          decoration: const InputDecoration(prefixIcon: Icon(Icons.search),
            hintText: 'Search country', border: OutlineInputBorder()))),
      Expanded(child: RefreshIndicator(onRefresh: refresh,
        child: loading && servers.isEmpty
          ? const Center(child: CircularProgressIndicator())
          : rows.isEmpty
            ? ListView(children: [Padding(padding: const EdgeInsets.all(32),
                child: Text(error ?? 'No servers match. Clear the search to see all.'))])
            : ListView.builder(itemCount: rows.length, itemBuilder: (_, i) {
                final s = rows[i];
                return ListTile(
                  leading: Text(s.flag, style: const TextStyle(fontSize: 26)),
                  title: Text(s.country),
                  subtitle: Text('${s.ping} ms · ${(s.speed / 1e6).toStringAsFixed(0)} Mbps'),
                  selected: sel?.ip == s.ip,
                  trailing: IconButton(
                    icon: Icon(favs.contains(s.ip) ? Icons.star : Icons.star_border),
                    onPressed: () => _toggleFav(s)),
                  onTap: () {
                    if (on || busy) vpn.disconnect();
                    setState(() { sel = s; tab = 0; });
                  });
              }))),
    ]);
  }
}
