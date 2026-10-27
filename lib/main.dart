// MesseCaisse - Gestion des offrandes de messe
// Fichier complet : lib/main.dart
//
// ARCHITECTURE DES ÉCRANS
//   Accueil (menu à boutons)
//    |- Nouvelle entrée      -> formulaire (entrée)
//    |- Nouvelle sortie      -> formulaire (sortie)
//    |- Situation de caisse  -> solde du jour / du mois / de l'année
//    |- Historique           -> liste, recherche, filtre, modification, suppression
//    |- Rapports PDF         -> journalier, mensuel, annuel (télécharger / imprimer)
//    |- Paramètres           -> paroisse, devise, célébrants, heures, catégories, sauvegarde
//
// Fichiers à avoir : lib/main.dart + pubspec.yaml

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:intl/intl.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ---------------------------------------------------------------------------
// OUTILS
// ---------------------------------------------------------------------------

String money(double v, String cur) {
  final s = NumberFormat('#,##0.##', 'en_US').format(v).replaceAll(',', ' ');
  return '$s $cur';
}

DateTime dayOnly(DateTime d) => DateTime(d.year, d.month, d.day);

String fmtDate(DateTime d) => DateFormat('dd/MM/yyyy').format(d);

String cap(String s) => s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);

const Color kEntry = Color(0xFF2E7D32);
const Color kExit = Color(0xFFC62828);
const Color kSeed = Color(0xFF5B2A86);
const Color kBlue = Color(0xFF1565C0);
const Color kGold = Color(0xFFB8860B);

void goTo(BuildContext context, Widget page) {
  Navigator.of(context).push(MaterialPageRoute(builder: (_) => page));
}

/// Centre le contenu et limite sa largeur (jolie présentation sur Mac / tablette).
Widget centered(Widget child, {double maxWidth = 900}) {
  return Align(
    alignment: Alignment.topCenter,
    child: ConstrainedBox(
      constraints: BoxConstraints(maxWidth: maxWidth),
      child: child,
    ),
  );
}

// ---------------------------------------------------------------------------
// MODÈLE
// ---------------------------------------------------------------------------

class Tx {
  String id;
  bool isEntry;
  double amount;
  DateTime date;
  String category;
  String celebrant;
  String massTime;
  String person; // intention / donateur / bénéficiaire
  String note;

  Tx({
    required this.id,
    required this.isEntry,
    required this.amount,
    required this.date,
    required this.category,
    this.celebrant = '',
    this.massTime = '',
    this.person = '',
    this.note = '',
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'isEntry': isEntry,
    'amount': amount,
    'date': date.toIso8601String(),
    'category': category,
    'celebrant': celebrant,
    'massTime': massTime,
    'person': person,
    'note': note,
  };

  factory Tx.fromJson(Map<String, dynamic> j) => Tx(
    id: j['id'] as String,
    isEntry: j['isEntry'] as bool,
    amount: (j['amount'] as num).toDouble(),
    date: DateTime.parse(j['date'] as String),
    category: (j['category'] ?? '') as String,
    celebrant: (j['celebrant'] ?? '') as String,
    massTime: (j['massTime'] ?? '') as String,
    person: (j['person'] ?? '') as String,
    note: (j['note'] ?? '') as String,
  );
}

// ---------------------------------------------------------------------------
// ÉTAT DE L'APPLICATION
// ---------------------------------------------------------------------------

class AppState extends ChangeNotifier {
  SharedPreferences? _prefs;

  String parishName = 'Paroisse';
  String currency = 'FC';
  List<String> celebrants = ['Père Curé', 'Père Vicaire'];
  List<String> entryCats = [
    'Offrande de messe',
    'Quête',
    'Intention de messe',
    'Dîme',
    'Don spécial',
    'Autre entrée',
  ];
  List<String> exitCats = [
    'Honoraires du célébrant',
    'Entretien de l\'église',
    'Hosties et vin',
    'Cire et encens',
    'Aide aux pauvres',
    'Transport',
    'Autre sortie',
  ];
  List<String> massTimes = ['06h00', '08h00', '10h00', '18h00'];
  List<Tx> txs = [];

  Future<void> load() async {
    _prefs = await SharedPreferences.getInstance();
    final raw = _prefs!.getString('data');
    if (raw != null) {
      try {
        _apply(jsonDecode(raw) as Map<String, dynamic>);
      } catch (_) {}
    }
  }

  void _apply(Map<String, dynamic> j) {
    parishName = (j['parishName'] ?? parishName) as String;
    currency = (j['currency'] ?? currency) as String;
    celebrants = List<String>.from(j['celebrants'] ?? celebrants);
    entryCats = List<String>.from(j['entryCats'] ?? entryCats);
    exitCats = List<String>.from(j['exitCats'] ?? exitCats);
    massTimes = List<String>.from(j['massTimes'] ?? massTimes);
    txs = ((j['txs'] ?? []) as List)
        .map((e) => Tx.fromJson(Map<String, dynamic>.from(e as Map)))
        .toList();
  }

  Map<String, dynamic> toJson() => {
    'parishName': parishName,
    'currency': currency,
    'celebrants': celebrants,
    'entryCats': entryCats,
    'exitCats': exitCats,
    'massTimes': massTimes,
    'txs': txs.map((t) => t.toJson()).toList(),
  };

  Future<void> save() async {
    await _prefs?.setString('data', jsonEncode(toJson()));
    notifyListeners();
  }

  Future<void> importJson(String raw) async {
    _apply(jsonDecode(raw) as Map<String, dynamic>);
    await save();
  }

  Future<void> addOrUpdate(Tx t) async {
    final i = txs.indexWhere((e) => e.id == t.id);
    if (i >= 0) {
      txs[i] = t;
    } else {
      txs.add(t);
    }
    await save();
  }

  Future<void> remove(String id) async {
    txs.removeWhere((e) => e.id == id);
    await save();
  }

  Future<void> update(void Function() change) async {
    change();
    await save();
  }

  /// mode : 0 = jour, 1 = mois, 2 = année
  List<Tx> inPeriod(int mode, DateTime ref) {
    final r = txs.where((t) {
      if (t.date.year != ref.year) return false;
      if (mode == 2) return true;
      if (t.date.month != ref.month) return false;
      if (mode == 1) return true;
      return t.date.day == ref.day;
    }).toList();
    r.sort((a, b) {
      final c = a.date.compareTo(b.date);
      return c != 0 ? c : a.massTime.compareTo(b.massTime);
    });
    return r;
  }

  static double sumEntries(Iterable<Tx> l) =>
      l.where((t) => t.isEntry).fold(0.0, (a, t) => a + t.amount);
  static double sumExits(Iterable<Tx> l) =>
      l.where((t) => !t.isEntry).fold(0.0, (a, t) => a + t.amount);
}

// ---------------------------------------------------------------------------
// RAPPORT PDF
// ---------------------------------------------------------------------------

class ReportPdf {
  static String title(int mode, DateTime ref) {
    switch (mode) {
      case 0:
        return 'Rapport journalier';
      case 1:
        return 'Rapport mensuel';
      default:
        return 'Rapport annuel';
    }
  }

  static String periodLabel(int mode, DateTime ref) {
    switch (mode) {
      case 0:
        return cap(DateFormat('EEEE dd MMMM yyyy', 'fr_FR').format(ref));
      case 1:
        return cap(DateFormat('MMMM yyyy', 'fr_FR').format(ref));
      default:
        return 'Année ${ref.year}';
    }
  }

  static String fileName(int mode, DateTime ref) {
    switch (mode) {
      case 0:
        return 'rapport_journalier_${DateFormat('yyyy-MM-dd').format(ref)}.pdf';
      case 1:
        return 'rapport_mensuel_${DateFormat('yyyy-MM').format(ref)}.pdf';
      default:
        return 'rapport_annuel_${ref.year}.pdf';
    }
  }

  static Map<String, double> _group(
      Iterable<Tx> l, String Function(Tx) key, bool entries) {
    final m = <String, double>{};
    for (final t in l.where((t) => t.isEntry == entries)) {
      final k = key(t).isEmpty ? '(non précisé)' : key(t);
      m[k] = (m[k] ?? 0) + t.amount;
    }
    return m;
  }

  static Future<Uint8List> build(AppState s, int mode, DateTime ref) async {
    final list = s.inPeriod(mode, ref);
    final cur = s.currency;
    final totalIn = AppState.sumEntries(list);
    final totalOut = AppState.sumExits(list);
    final balance = totalIn - totalOut;

    final doc = pw.Document();
    final grey = PdfColors.grey300;
    final headStyle = pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 10);
    const cellStyle = pw.TextStyle(fontSize: 9);

    pw.Widget sectionTitle(String t) => pw.Padding(
      padding: const pw.EdgeInsets.only(top: 14, bottom: 6),
      child: pw.Text(t,
          style: pw.TextStyle(
              fontSize: 13,
              fontWeight: pw.FontWeight.bold,
              color: PdfColor.fromInt(0xFF5B2A86))),
    );

    pw.Widget table(List<String> headers, List<List<String>> rows,
        {Map<int, pw.Alignment>? align, Map<int, pw.TableColumnWidth>? widths}) {
      return pw.TableHelper.fromTextArray(
        headers: headers,
        data: rows,
        headerStyle: headStyle,
        cellStyle: cellStyle,
        headerDecoration: pw.BoxDecoration(color: grey),
        cellAlignments: align,
        columnWidths: widths,
        border: pw.TableBorder.all(color: PdfColors.grey500, width: 0.5),
        cellPadding: const pw.EdgeInsets.symmetric(horizontal: 4, vertical: 3),
      );
    }

    pw.Widget summaryBox(String label, String value, PdfColor color) =>
        pw.Expanded(
          child: pw.Container(
            margin: const pw.EdgeInsets.symmetric(horizontal: 3),
            padding: const pw.EdgeInsets.all(8),
            decoration: pw.BoxDecoration(
              border: pw.Border.all(color: color, width: 1),
              borderRadius: pw.BorderRadius.circular(4),
            ),
            child: pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: [
                pw.Text(label, style: const pw.TextStyle(fontSize: 9)),
                pw.SizedBox(height: 3),
                pw.Text(value,
                    style: pw.TextStyle(
                        fontSize: 13,
                        fontWeight: pw.FontWeight.bold,
                        color: color)),
              ],
            ),
          ),
        );

    // Ventilation par période
    final List<List<String>> perPeriodRows = [];
    String perPeriodTitle = '';
    if (mode == 1) {
      perPeriodTitle = 'Récapitulatif par jour';
      final days = <int, List<Tx>>{};
      for (final t in list) {
        days.putIfAbsent(t.date.day, () => []).add(t);
      }
      final keys = days.keys.toList()..sort();
      for (final d in keys) {
        final l = days[d]!;
        final i = AppState.sumEntries(l);
        final o = AppState.sumExits(l);
        perPeriodRows.add([
          fmtDate(DateTime(ref.year, ref.month, d)),
          money(i, cur),
          money(o, cur),
          money(i - o, cur),
        ]);
      }
    } else if (mode == 2) {
      perPeriodTitle = 'Récapitulatif par mois';
      for (var m = 1; m <= 12; m++) {
        final l = list.where((t) => t.date.month == m).toList();
        if (l.isEmpty) continue;
        final i = AppState.sumEntries(l);
        final o = AppState.sumExits(l);
        perPeriodRows.add([
          cap(DateFormat('MMMM', 'fr_FR').format(DateTime(ref.year, m, 1))),
          money(i, cur),
          money(o, cur),
          money(i - o, cur),
        ]);
      }
    }

    final byCelebrant = _group(list, (t) => t.celebrant, true);
    final inCats = _group(list, (t) => t.category, true);
    final outCats = _group(list, (t) => t.category, false);

    List<List<String>> mapRows(Map<String, double> m) {
      final e = m.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
      return e.map((x) => [x.key, money(x.value, cur)]).toList();
    }

    doc.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.all(30),
        footer: (ctx) => pw.Align(
          alignment: pw.Alignment.centerRight,
          child: pw.Text('Page ${ctx.pageNumber} / ${ctx.pagesCount}',
              style: const pw.TextStyle(fontSize: 8, color: PdfColors.grey700)),
        ),
        build: (ctx) => [
          pw.Center(
            child: pw.Text(s.parishName.toUpperCase(),
                style: pw.TextStyle(
                    fontSize: 16, fontWeight: pw.FontWeight.bold)),
          ),
          pw.SizedBox(height: 4),
          pw.Center(
            child: pw.Text(title(mode, ref).toUpperCase(),
                style: pw.TextStyle(
                    fontSize: 14,
                    fontWeight: pw.FontWeight.bold,
                    color: PdfColor.fromInt(0xFF5B2A86))),
          ),
          pw.Center(
            child: pw.Text(periodLabel(mode, ref),
                style: const pw.TextStyle(fontSize: 11)),
          ),
          pw.SizedBox(height: 4),
          pw.Center(
            child: pw.Text(
                'Établi le ${DateFormat('dd/MM/yyyy HH:mm').format(DateTime.now())}',
                style: const pw.TextStyle(
                    fontSize: 8, color: PdfColors.grey700)),
          ),
          pw.SizedBox(height: 12),
          pw.Row(children: [
            summaryBox('Total des entrées', money(totalIn, cur),
                PdfColor.fromInt(0xFF2E7D32)),
            summaryBox('Total des sorties', money(totalOut, cur),
                PdfColor.fromInt(0xFFC62828)),
            summaryBox('Solde', money(balance, cur),
                balance >= 0
                    ? PdfColor.fromInt(0xFF1565C0)
                    : PdfColor.fromInt(0xFFC62828)),
          ]),
          if (perPeriodRows.isNotEmpty) ...[
            sectionTitle(perPeriodTitle),
            table(
              [mode == 1 ? 'Jour' : 'Mois', 'Entrées', 'Sorties', 'Solde'],
              perPeriodRows,
              align: {
                1: pw.Alignment.centerRight,
                2: pw.Alignment.centerRight,
                3: pw.Alignment.centerRight,
              },
            ),
          ],
          if (inCats.isNotEmpty) ...[
            sectionTitle('Entrées par catégorie'),
            table(['Catégorie', 'Montant'], mapRows(inCats),
                align: {1: pw.Alignment.centerRight}),
          ],
          if (outCats.isNotEmpty) ...[
            sectionTitle('Sorties par catégorie'),
            table(['Catégorie', 'Montant'], mapRows(outCats),
                align: {1: pw.Alignment.centerRight}),
          ],
          if (byCelebrant.isNotEmpty) ...[
            sectionTitle('Entrées par célébrant'),
            table(['Célébrant', 'Montant'], mapRows(byCelebrant),
                align: {1: pw.Alignment.centerRight}),
          ],
          sectionTitle('Détail des opérations (${list.length})'),
          if (list.isEmpty)
            pw.Text('Aucune opération pour cette période.',
                style: const pw.TextStyle(fontSize: 10))
          else
            table(
              [
                'Date',
                'Heure',
                'Type',
                'Catégorie',
                'Célébrant',
                'Intention / Personne',
                'Montant',
              ],
              list
                  .map((t) => [
                fmtDate(t.date),
                t.massTime,
                t.isEntry ? 'Entrée' : 'Sortie',
                t.category,
                t.celebrant,
                t.person,
                '${t.isEntry ? '+' : '-'} ${money(t.amount, cur)}',
              ])
                  .toList(),
              align: {6: pw.Alignment.centerRight},
              widths: {
                0: const pw.FlexColumnWidth(1.6),
                1: const pw.FlexColumnWidth(1.1),
                2: const pw.FlexColumnWidth(1.1),
                3: const pw.FlexColumnWidth(2.2),
                4: const pw.FlexColumnWidth(1.8),
                5: const pw.FlexColumnWidth(2.2),
                6: const pw.FlexColumnWidth(2.0),
              },
            ),
          pw.SizedBox(height: 40),
          pw.Row(
            mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
            children: [
              pw.Column(children: [
                pw.Text('Le Trésorier', style: headStyle),
                pw.SizedBox(height: 36),
                pw.Container(width: 120, height: 0.5, color: PdfColors.grey700),
              ]),
              pw.Column(children: [
                pw.Text('Le Curé / Le Célébrant', style: headStyle),
                pw.SizedBox(height: 36),
                pw.Container(width: 120, height: 0.5, color: PdfColors.grey700),
              ]),
            ],
          ),
        ],
      ),
    );

    return doc.save();
  }
}

// ---------------------------------------------------------------------------
// APPLICATION
// ---------------------------------------------------------------------------

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initializeDateFormatting('fr_FR');
  final state = AppState();
  await state.load();
  runApp(MesseCaisseApp(state: state));
}

class MesseCaisseApp extends StatelessWidget {
  final AppState state;
  const MesseCaisseApp({super.key, required this.state});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'MesseCaisse',
      debugShowCheckedModeBanner: false,
      locale: const Locale('fr', 'FR'),
      supportedLocales: const [Locale('fr', 'FR')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: kSeed),
        scaffoldBackgroundColor: const Color(0xFFF6F2FA),
        appBarTheme: const AppBarTheme(
          centerTitle: false,
          backgroundColor: kSeed,
          foregroundColor: Colors.white,
          elevation: 0,
        ),
        cardTheme: CardThemeData(
          elevation: 1,
          color: Colors.white,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: Colors.white,
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
        ),
      ),
      home: HomePage(state: state),
    );
  }
}

// ---------------------------------------------------------------------------
// ÉCRAN D'ACCUEIL (MENU À BOUTONS)
// ---------------------------------------------------------------------------

class HomePage extends StatelessWidget {
  final AppState state;
  const HomePage({super.key, required this.state});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) {
        final tiles = <_MenuTile>[
          _MenuTile(
            icon: Icons.add_circle_outline,
            title: 'Nouvelle entrée',
            subtitle: 'Offrande, quête, intention',
            color: kEntry,
            onTap: () => goTo(context,
                TxFormPage(state: state, initialEntry: true)),
          ),
          _MenuTile(
            icon: Icons.remove_circle_outline,
            title: 'Nouvelle sortie',
            subtitle: 'Dépense, honoraires, aide',
            color: kExit,
            onTap: () => goTo(context,
                TxFormPage(state: state, initialEntry: false)),
          ),
          _MenuTile(
            icon: Icons.account_balance_wallet_outlined,
            title: 'Situation de caisse',
            subtitle: 'Solde du jour, du mois, de l\'année',
            color: kBlue,
            onTap: () => goTo(context, CashPage(state: state)),
          ),
          _MenuTile(
            icon: Icons.receipt_long_outlined,
            title: 'Historique',
            subtitle: 'Toutes les opérations',
            color: kSeed,
            onTap: () => goTo(context, TransactionsPage(state: state)),
          ),
          _MenuTile(
            icon: Icons.picture_as_pdf_outlined,
            title: 'Rapports PDF',
            subtitle: 'Journalier, mensuel, annuel',
            color: kGold,
            onTap: () => goTo(context, ReportsPage(state: state)),
          ),
          _MenuTile(
            icon: Icons.settings_outlined,
            title: 'Paramètres',
            subtitle: 'Célébrants, catégories, devise',
            color: Colors.blueGrey,
            onTap: () => goTo(context, SettingsPage(state: state)),
          ),
        ];

        return Scaffold(
          body: SingleChildScrollView(
            child: Column(
              children: [
                _HomeBanner(state: state),
                centered(
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 24, 20, 12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Que souhaitez-vous faire ?',
                            style: Theme.of(context)
                                .textTheme
                                .titleLarge
                                ?.copyWith(fontWeight: FontWeight.bold)),
                        const SizedBox(height: 16),
                        LayoutBuilder(builder: (context, c) {
                          final cols = c.maxWidth >= 560 ? 3 : 2;
                          return GridView.count(
                            crossAxisCount: cols,
                            shrinkWrap: true,
                            physics: const NeverScrollableScrollPhysics(),
                            mainAxisSpacing: 14,
                            crossAxisSpacing: 14,
                            childAspectRatio: cols == 3 ? 1.25 : 1.0,
                            children: tiles,
                          );
                        }),
                        const SizedBox(height: 24),
                        Center(
                          child: Text('MesseCaisse 1.0',
                              style: Theme.of(context).textTheme.bodySmall),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _HomeBanner extends StatelessWidget {
  final AppState state;
  const _HomeBanner({required this.state});

  @override
  Widget build(BuildContext context) {
    final top = MediaQuery.of(context).padding.top;
    return Container(
      width: double.infinity,
      padding: EdgeInsets.fromLTRB(24, top + 32, 24, 36),
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          colors: [Color(0xFF3E1A5E), kSeed, Color(0xFF8E5BB8)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.vertical(bottom: Radius.circular(36)),
      ),
      child: Column(
        children: [
          CircleAvatar(
            radius: 40,
            backgroundColor: Colors.white.withValues(alpha: 0.18),
            child: const Icon(Icons.church, size: 44, color: Colors.white),
          ),
          const SizedBox(height: 16),
          Text(
            state.parishName,
            textAlign: TextAlign.center,
            style: const TextStyle(
                color: Colors.white, fontSize: 26, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 4),
          const Text(
            'Gestion des offrandes de messe',
            style: TextStyle(color: Colors.white70, fontSize: 15),
          ),
          const SizedBox(height: 14),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.18),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Text(
              cap(DateFormat('EEEE dd MMMM yyyy', 'fr_FR').format(DateTime.now())),
              style: const TextStyle(color: Colors.white, fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }
}

class _MenuTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final Color color;
  final VoidCallback onTap;
  const _MenuTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              CircleAvatar(
                radius: 26,
                backgroundColor: color.withValues(alpha: 0.12),
                child: Icon(icon, color: color, size: 28),
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style: const TextStyle(
                          fontSize: 16, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 2),
                  Text(subtitle,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 12, color: Colors.grey[700])),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// SITUATION DE CAISSE
// ---------------------------------------------------------------------------

class CashPage extends StatelessWidget {
  final AppState state;
  const CashPage({super.key, required this.state});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) {
        final now = DateTime.now();
        final today = state.inPeriod(0, now);
        final month = state.inPeriod(1, now);
        final year = state.inPeriod(2, now);
        final cur = state.currency;
        final recent = [...state.txs]..sort((a, b) => b.date.compareTo(a.date));
        final todayBal = AppState.sumEntries(today) - AppState.sumExits(today);

        return Scaffold(
          appBar: AppBar(title: const Text('Situation de caisse')),
          body: centered(
            ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Card(
                  color: kSeed,
                  child: Padding(
                    padding: const EdgeInsets.all(22),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Aujourd\'hui - ${fmtDate(now)}',
                          style: const TextStyle(color: Colors.white70),
                        ),
                        const SizedBox(height: 6),
                        Text(money(todayBal, cur),
                            style: const TextStyle(
                                color: Colors.white,
                                fontSize: 32,
                                fontWeight: FontWeight.bold)),
                        const SizedBox(height: 12),
                        Row(children: [
                          const Icon(Icons.arrow_downward,
                              color: Colors.lightGreenAccent, size: 18),
                          const SizedBox(width: 4),
                          Text(money(AppState.sumEntries(today), cur),
                              style: const TextStyle(color: Colors.white)),
                          const SizedBox(width: 22),
                          const Icon(Icons.arrow_upward,
                              color: Colors.redAccent, size: 18),
                          const SizedBox(width: 4),
                          Text(money(AppState.sumExits(today), cur),
                              style: const TextStyle(color: Colors.white)),
                        ]),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 4),
                Row(children: [
                  Expanded(
                      child: _MiniCard(
                          title: cap(DateFormat('MMMM yyyy', 'fr_FR').format(now)),
                          list: month,
                          cur: cur)),
                  const SizedBox(width: 8),
                  Expanded(
                      child: _MiniCard(
                          title: 'Année ${now.year}', list: year, cur: cur)),
                ]),
                const SizedBox(height: 20),
                Text('Dernières opérations',
                    style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 8),
                if (recent.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(24),
                    child: Center(child: Text('Aucune opération enregistrée.')),
                  )
                else
                  ...recent.take(6).map((t) => TxTile(
                    tx: t,
                    cur: cur,
                    onTap: () =>
                        goTo(context, TxFormPage(state: state, existing: t)),
                  )),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _MiniCard extends StatelessWidget {
  final String title;
  final List<Tx> list;
  final String cur;
  const _MiniCard({required this.title, required this.list, required this.cur});

  @override
  Widget build(BuildContext context) {
    final i = AppState.sumEntries(list);
    final o = AppState.sumExits(list);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: Theme.of(context).textTheme.labelLarge),
            const SizedBox(height: 6),
            FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(money(i - o, cur),
                  style: Theme.of(context)
                      .textTheme
                      .titleMedium
                      ?.copyWith(fontWeight: FontWeight.bold)),
            ),
            const SizedBox(height: 6),
            Text('Entrées : ${money(i, cur)}',
                style: const TextStyle(color: kEntry, fontSize: 12)),
            Text('Sorties : ${money(o, cur)}',
                style: const TextStyle(color: kExit, fontSize: 12)),
          ],
        ),
      ),
    );
  }
}

class TxTile extends StatelessWidget {
  final Tx tx;
  final String cur;
  final VoidCallback onTap;
  const TxTile({super.key, required this.tx, required this.cur, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final color = tx.isEntry ? kEntry : kExit;
    final parts = <String>[
      fmtDate(tx.date),
      if (tx.massTime.isNotEmpty) tx.massTime,
      if (tx.celebrant.isNotEmpty) tx.celebrant,
    ];
    return Card(
      margin: const EdgeInsets.only(bottom: 6),
      child: ListTile(
        onTap: onTap,
        leading: CircleAvatar(
          backgroundColor: color.withValues(alpha: 0.12),
          child: Icon(tx.isEntry ? Icons.arrow_downward : Icons.arrow_upward,
              color: color),
        ),
        title: Text(tx.category.isEmpty
            ? (tx.isEntry ? 'Entrée' : 'Sortie')
            : tx.category),
        subtitle: Text([
          parts.join(' - '),
          if (tx.person.isNotEmpty) tx.person,
        ].join('\n')),
        isThreeLine: tx.person.isNotEmpty,
        trailing: Text(
          '${tx.isEntry ? '+' : '-'} ${money(tx.amount, cur)}',
          style: TextStyle(color: color, fontWeight: FontWeight.bold),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// HISTORIQUE DES OPÉRATIONS
// ---------------------------------------------------------------------------

class TransactionsPage extends StatefulWidget {
  final AppState state;
  const TransactionsPage({super.key, required this.state});

  @override
  State<TransactionsPage> createState() => _TransactionsPageState();
}

class _TransactionsPageState extends State<TransactionsPage> {
  String _q = '';
  int _filter = 0; // 0 tous, 1 entrées, 2 sorties

  AppState get s => widget.state;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: s,
      builder: (context, _) {
        var list = [...s.txs]..sort((a, b) => b.date.compareTo(a.date));
        if (_filter == 1) list = list.where((t) => t.isEntry).toList();
        if (_filter == 2) list = list.where((t) => !t.isEntry).toList();
        if (_q.trim().isNotEmpty) {
          final q = _q.toLowerCase();
          list = list
              .where((t) => [
            t.category,
            t.celebrant,
            t.person,
            t.note,
            t.massTime,
            fmtDate(t.date)
          ].join(' ').toLowerCase().contains(q))
              .toList();
        }

        return Scaffold(
          appBar: AppBar(title: const Text('Historique des opérations')),
          floatingActionButton: FloatingActionButton.extended(
            backgroundColor: kSeed,
            foregroundColor: Colors.white,
            onPressed: () => goTo(context, TxFormPage(state: s)),
            icon: const Icon(Icons.add),
            label: const Text('Nouvelle opération'),
          ),
          body: centered(
            Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                  child: TextField(
                    decoration: const InputDecoration(
                      prefixIcon: Icon(Icons.search),
                      hintText: 'Rechercher (célébrant, catégorie, date...)',
                    ),
                    onChanged: (v) => setState(() => _q = v),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Row(children: [
                    for (final e
                    in {0: 'Tous', 1: 'Entrées', 2: 'Sorties'}.entries)
                      Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: ChoiceChip(
                          label: Text(e.value),
                          selected: _filter == e.key,
                          onSelected: (_) => setState(() => _filter = e.key),
                        ),
                      ),
                  ]),
                ),
                Expanded(
                  child: list.isEmpty
                      ? const Center(child: Text('Aucune opération.'))
                      : ListView.builder(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 100),
                    itemCount: list.length,
                    itemBuilder: (context, i) {
                      final t = list[i];
                      return Dismissible(
                        key: ValueKey(t.id),
                        direction: DismissDirection.endToStart,
                        background: Container(
                          alignment: Alignment.centerRight,
                          padding: const EdgeInsets.only(right: 20),
                          margin: const EdgeInsets.only(bottom: 6),
                          decoration: BoxDecoration(
                            color: kExit,
                            borderRadius: BorderRadius.circular(16),
                          ),
                          child: const Icon(Icons.delete,
                              color: Colors.white),
                        ),
                        confirmDismiss: (_) async {
                          return await showDialog<bool>(
                            context: context,
                            builder: (ctx) => AlertDialog(
                              title: const Text(
                                  'Supprimer cette opération ?'),
                              content: Text(
                                  '${t.category} - ${money(t.amount, s.currency)}'),
                              actions: [
                                TextButton(
                                    onPressed: () =>
                                        Navigator.pop(ctx, false),
                                    child: const Text('Annuler')),
                                FilledButton(
                                    onPressed: () =>
                                        Navigator.pop(ctx, true),
                                    child: const Text('Supprimer')),
                              ],
                            ),
                          ) ??
                              false;
                        },
                        onDismissed: (_) => s.remove(t.id),
                        child: TxTile(
                          tx: t,
                          cur: s.currency,
                          onTap: () => goTo(context,
                              TxFormPage(state: s, existing: t)),
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// FORMULAIRE D'OPÉRATION
// ---------------------------------------------------------------------------

class TxFormPage extends StatefulWidget {
  final AppState state;
  final Tx? existing;
  final bool? initialEntry;
  const TxFormPage(
      {super.key, required this.state, this.existing, this.initialEntry});

  @override
  State<TxFormPage> createState() => _TxFormPageState();
}

class _TxFormPageState extends State<TxFormPage> {
  final _formKey = GlobalKey<FormState>();
  late bool _isEntry;
  late DateTime _date;
  late TextEditingController _amount;
  late TextEditingController _person;
  late TextEditingController _note;
  String _category = '';
  String _celebrant = '';
  String _massTime = '';

  AppState get s => widget.state;

  @override
  void initState() {
    super.initState();
    final t = widget.existing;
    _isEntry = t?.isEntry ?? widget.initialEntry ?? true;
    _date = t?.date ?? DateTime.now();
    _amount = TextEditingController(
        text: t == null
            ? ''
            : t.amount.toString().replaceAll(RegExp(r'\.0$'), ''));
    _person = TextEditingController(text: t?.person ?? '');
    _note = TextEditingController(text: t?.note ?? '');
    _category = t?.category ?? '';
    _celebrant = t?.celebrant ?? '';
    _massTime = t?.massTime ?? '';
  }

  @override
  void dispose() {
    _amount.dispose();
    _person.dispose();
    _note.dispose();
    super.dispose();
  }

  List<String> get _cats => _isEntry ? s.entryCats : s.exitCats;

  List<String> _withCurrent(List<String> base, String current) {
    if (current.isNotEmpty && !base.contains(current)) return [...base, current];
    return base;
  }

  Future<void> _pickDate() async {
    final d = await showDatePicker(
      context: context,
      initialDate: _date,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
      locale: const Locale('fr', 'FR'),
    );
    if (d != null) setState(() => _date = d);
  }

  Future<void> _addToList(
      String title, List<String> list, void Function(String) onAdded) async {
    final c = TextEditingController();
    final v = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: TextField(controller: c, autofocus: true),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Annuler')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, c.text.trim()),
              child: const Text('Ajouter')),
        ],
      ),
    );
    if (v != null && v.isNotEmpty) {
      if (!list.contains(v)) await s.update(() => list.add(v));
      setState(() => onAdded(v));
    }
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    final amount =
    double.parse(_amount.text.replaceAll(' ', '').replaceAll(',', '.'));
    final t = Tx(
      id: widget.existing?.id ??
          DateTime.now().microsecondsSinceEpoch.toString(),
      isEntry: _isEntry,
      amount: amount,
      date: dayOnly(_date),
      category: _category,
      celebrant: _celebrant,
      massTime: _massTime,
      person: _person.text.trim(),
      note: _note.text.trim(),
    );
    await s.addOrUpdate(t);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Opération enregistrée.')),
    );
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final editing = widget.existing != null;
    final accent = _isEntry ? kEntry : kExit;
    final title = editing
        ? 'Modifier l\'opération'
        : (_isEntry ? 'Nouvelle entrée' : 'Nouvelle sortie');

    return Scaffold(
      appBar: AppBar(
        title: Text(title),
        backgroundColor: accent,
      ),
      body: centered(
        Form(
          key: _formKey,
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              SegmentedButton<bool>(
                segments: const [
                  ButtonSegment(
                      value: true,
                      icon: Icon(Icons.arrow_downward),
                      label: Text('Entrée')),
                  ButtonSegment(
                      value: false,
                      icon: Icon(Icons.arrow_upward),
                      label: Text('Sortie')),
                ],
                selected: {_isEntry},
                onSelectionChanged: (v) => setState(() {
                  _isEntry = v.first;
                  _category = '';
                }),
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _amount,
                keyboardType:
                const TextInputType.numberWithOptions(decimal: true),
                decoration: InputDecoration(
                  labelText: 'Montant (${s.currency})',
                  prefixIcon: const Icon(Icons.payments_outlined),
                ),
                validator: (v) {
                  final x = double.tryParse(
                      (v ?? '').replaceAll(' ', '').replaceAll(',', '.'));
                  if (x == null || x <= 0) return 'Entrez un montant valide';
                  return null;
                },
              ),
              const SizedBox(height: 14),
              InkWell(
                onTap: _pickDate,
                child: InputDecorator(
                  decoration: const InputDecoration(
                    labelText: 'Date',
                    prefixIcon: Icon(Icons.event),
                  ),
                  child: Text(cap(
                      DateFormat('EEEE dd MMMM yyyy', 'fr_FR').format(_date))),
                ),
              ),
              const SizedBox(height: 14),
              Row(children: [
                Expanded(
                  child: DropdownButtonFormField<String>(
                    value: _cats.contains(_category) ? _category : null,
                    decoration: const InputDecoration(
                      labelText: 'Catégorie',
                      prefixIcon: Icon(Icons.category_outlined),
                    ),
                    items: _cats
                        .map((e) => DropdownMenuItem(value: e, child: Text(e)))
                        .toList(),
                    onChanged: (v) => setState(() => _category = v ?? ''),
                    validator: (v) => (v == null || v.isEmpty)
                        ? 'Choisissez une catégorie'
                        : null,
                  ),
                ),
                IconButton(
                  tooltip: 'Nouvelle catégorie',
                  icon: const Icon(Icons.add_circle_outline),
                  onPressed: () => _addToList(
                      'Nouvelle catégorie', _cats, (v) => _category = v),
                ),
              ]),
              const SizedBox(height: 14),
              Row(children: [
                Expanded(
                  child: DropdownButtonFormField<String>(
                    value: _celebrant.isNotEmpty ? _celebrant : null,
                    decoration: const InputDecoration(
                      labelText: 'Célébrant (qui dit la messe)',
                      prefixIcon: Icon(Icons.person_outline),
                    ),
                    items: _withCurrent(s.celebrants, _celebrant)
                        .map((e) => DropdownMenuItem(value: e, child: Text(e)))
                        .toList(),
                    onChanged: (v) => setState(() => _celebrant = v ?? ''),
                  ),
                ),
                IconButton(
                  tooltip: 'Nouveau célébrant',
                  icon: const Icon(Icons.add_circle_outline),
                  onPressed: () => _addToList('Nouveau célébrant',
                      s.celebrants, (v) => _celebrant = v),
                ),
              ]),
              const SizedBox(height: 14),
              Row(children: [
                Expanded(
                  child: DropdownButtonFormField<String>(
                    value: _massTime.isNotEmpty ? _massTime : null,
                    decoration: const InputDecoration(
                      labelText: 'Heure de la messe',
                      prefixIcon: Icon(Icons.schedule),
                    ),
                    items: _withCurrent(s.massTimes, _massTime)
                        .map((e) => DropdownMenuItem(value: e, child: Text(e)))
                        .toList(),
                    onChanged: (v) => setState(() => _massTime = v ?? ''),
                  ),
                ),
                IconButton(
                  tooltip: 'Nouvelle heure',
                  icon: const Icon(Icons.add_circle_outline),
                  onPressed: () => _addToList('Nouvelle heure de messe',
                      s.massTimes, (v) => _massTime = v),
                ),
              ]),
              const SizedBox(height: 14),
              TextFormField(
                controller: _person,
                decoration: InputDecoration(
                  labelText: _isEntry
                      ? 'Intention de messe / Donateur'
                      : 'Bénéficiaire / Motif',
                  prefixIcon: const Icon(Icons.favorite_border),
                ),
              ),
              const SizedBox(height: 14),
              TextFormField(
                controller: _note,
                maxLines: 3,
                decoration: const InputDecoration(
                  labelText: 'Autres informations',
                  prefixIcon: Icon(Icons.notes),
                ),
              ),
              const SizedBox(height: 24),
              FilledButton.icon(
                style: FilledButton.styleFrom(backgroundColor: accent),
                onPressed: _save,
                icon: const Icon(Icons.save),
                label: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  child: Text(editing
                      ? 'Enregistrer les modifications'
                      : 'Enregistrer'),
                ),
              ),
              if (editing) ...[
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(foregroundColor: kExit),
                  onPressed: () async {
                    final ok = await showDialog<bool>(
                      context: context,
                      builder: (ctx) => AlertDialog(
                        title: const Text('Supprimer cette opération ?'),
                        actions: [
                          TextButton(
                              onPressed: () => Navigator.pop(ctx, false),
                              child: const Text('Annuler')),
                          FilledButton(
                              onPressed: () => Navigator.pop(ctx, true),
                              child: const Text('Supprimer')),
                        ],
                      ),
                    );
                    if (ok == true) {
                      await s.remove(widget.existing!.id);
                      if (mounted) Navigator.pop(context);
                    }
                  },
                  icon: const Icon(Icons.delete_outline),
                  label: const Text('Supprimer'),
                ),
              ],
              const SizedBox(height: 24),
            ],
          ),
        ),
        maxWidth: 700,
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// RAPPORTS
// ---------------------------------------------------------------------------

class ReportsPage extends StatefulWidget {
  final AppState state;
  const ReportsPage({super.key, required this.state});

  @override
  State<ReportsPage> createState() => _ReportsPageState();
}

class _ReportsPageState extends State<ReportsPage> {
  int _mode = 0;
  DateTime _ref = dayOnly(DateTime.now());
  bool _busy = false;

  AppState get s => widget.state;

  void _shift(int delta) {
    setState(() {
      if (_mode == 0) {
        _ref = _ref.add(Duration(days: delta));
      } else if (_mode == 1) {
        _ref = DateTime(_ref.year, _ref.month + delta, 1);
      } else {
        _ref = DateTime(_ref.year + delta, _ref.month, 1);
      }
    });
  }

  Future<void> _pick() async {
    final d = await showDatePicker(
      context: context,
      initialDate: _ref,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
      locale: const Locale('fr', 'FR'),
    );
    if (d != null) setState(() => _ref = d);
  }

  Future<void> _download() async {
    setState(() => _busy = true);
    try {
      final bytes = await ReportPdf.build(s, _mode, _ref);
      await Printing.sharePdf(
          bytes: bytes, filename: ReportPdf.fileName(_mode, _ref));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Erreur PDF : $e')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _print() async {
    setState(() => _busy = true);
    try {
      await Printing.layoutPdf(
        name: ReportPdf.fileName(_mode, _ref),
        onLayout: (_) => ReportPdf.build(s, _mode, _ref),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Erreur impression : $e')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: s,
      builder: (context, _) {
        final list = s.inPeriod(_mode, _ref);
        final cur = s.currency;
        final i = AppState.sumEntries(list);
        final o = AppState.sumExits(list);

        final byCat = <String, double>{};
        for (final t in list) {
          final k = '${t.isEntry ? 'Entrée' : 'Sortie'} - ${t.category}';
          byCat[k] = (byCat[k] ?? 0) + t.amount;
        }
        final byCel = <String, double>{};
        for (final t in list.where((t) => t.isEntry)) {
          final k = t.celebrant.isEmpty ? '(non précisé)' : t.celebrant;
          byCel[k] = (byCel[k] ?? 0) + t.amount;
        }

        return Scaffold(
          appBar: AppBar(title: const Text('Rapports PDF')),
          body: centered(
            ListView(
              padding: const EdgeInsets.all(16),
              children: [
                SegmentedButton<int>(
                  segments: const [
                    ButtonSegment(value: 0, label: Text('Journalier')),
                    ButtonSegment(value: 1, label: Text('Mensuel')),
                    ButtonSegment(value: 2, label: Text('Annuel')),
                  ],
                  selected: {_mode},
                  onSelectionChanged: (v) => setState(() => _mode = v.first),
                ),
                const SizedBox(height: 12),
                Card(
                  child: Padding(
                    padding:
                    const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
                    child: Row(
                      children: [
                        IconButton(
                            onPressed: () => _shift(-1),
                            icon: const Icon(Icons.chevron_left)),
                        Expanded(
                          child: InkWell(
                            onTap: _pick,
                            child: Padding(
                              padding: const EdgeInsets.symmetric(vertical: 8),
                              child: Text(
                                ReportPdf.periodLabel(_mode, _ref),
                                textAlign: TextAlign.center,
                                style: Theme.of(context).textTheme.titleMedium,
                              ),
                            ),
                          ),
                        ),
                        IconButton(
                            onPressed: () => _shift(1),
                            icon: const Icon(Icons.chevron_right)),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 4),
                Row(children: [
                  Expanded(
                      child: _Stat(
                          label: 'Entrées',
                          value: money(i, cur),
                          color: kEntry)),
                  const SizedBox(width: 8),
                  Expanded(
                      child: _Stat(
                          label: 'Sorties',
                          value: money(o, cur),
                          color: kExit)),
                  const SizedBox(width: 8),
                  Expanded(
                      child: _Stat(
                          label: 'Solde',
                          value: money(i - o, cur),
                          color: i - o >= 0 ? kBlue : kExit)),
                ]),
                const SizedBox(height: 12),
                Row(children: [
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: _busy ? null : _download,
                      icon: _busy
                          ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2))
                          : const Icon(Icons.download),
                      label: const Padding(
                        padding: EdgeInsets.symmetric(vertical: 12),
                        child: Text('Télécharger le PDF'),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton.icon(
                    onPressed: _busy ? null : _print,
                    icon: const Icon(Icons.print),
                    label: const Padding(
                      padding: EdgeInsets.symmetric(vertical: 12),
                      child: Text('Imprimer'),
                    ),
                  ),
                ]),
                const SizedBox(height: 16),
                if (byCat.isNotEmpty) ...[
                  Text('Par catégorie',
                      style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 4),
                  Card(
                    child: Column(
                      children: byCat.entries
                          .map((e) => ListTile(
                        dense: true,
                        title: Text(e.key),
                        trailing: Text(money(e.value, cur),
                            style: const TextStyle(
                                fontWeight: FontWeight.bold)),
                      ))
                          .toList(),
                    ),
                  ),
                ],
                if (byCel.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Text('Entrées par célébrant',
                      style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 4),
                  Card(
                    child: Column(
                      children: byCel.entries
                          .map((e) => ListTile(
                        dense: true,
                        leading: const Icon(Icons.person_outline),
                        title: Text(e.key),
                        trailing: Text(money(e.value, cur),
                            style: const TextStyle(
                                fontWeight: FontWeight.bold)),
                      ))
                          .toList(),
                    ),
                  ),
                ],
                const SizedBox(height: 8),
                Text('${list.length} opération(s) dans cette période',
                    style: Theme.of(context).textTheme.bodySmall),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _Stat extends StatelessWidget {
  final String label;
  final String value;
  final Color color;
  const _Stat({required this.label, required this.value, required this.color});

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: const TextStyle(fontSize: 12)),
            const SizedBox(height: 4),
            FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(value,
                  style: TextStyle(
                      color: color, fontWeight: FontWeight.bold, fontSize: 15)),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// PARAMÈTRES
// ---------------------------------------------------------------------------

class SettingsPage extends StatelessWidget {
  final AppState state;
  const SettingsPage({super.key, required this.state});

  Future<void> _editName(BuildContext context) async {
    final c = TextEditingController(text: state.parishName);
    final v = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Nom de la paroisse / école'),
        content: TextField(controller: c, autofocus: true),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Annuler')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, c.text.trim()),
              child: const Text('OK')),
        ],
      ),
    );
    if (v != null && v.isNotEmpty) {
      await state.update(() => state.parishName = v);
    }
  }

  Future<void> _editCurrency(BuildContext context) async {
    final v = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('Devise'),
        children: ['FC', 'USD', 'EUR']
            .map((e) => SimpleDialogOption(
          onPressed: () => Navigator.pop(ctx, e),
          child: Text(e),
        ))
            .toList(),
      ),
    );
    if (v != null) await state.update(() => state.currency = v);
  }

  Future<void> _editList(BuildContext context, String title,
      List<String> items, void Function(List<String>) apply) async {
    final res = await Navigator.of(context).push<List<String>>(
      MaterialPageRoute(
          builder: (_) => ListEditorPage(title: title, items: items)),
    );
    if (res != null) await state.update(() => apply(res));
  }

  Future<void> _export(BuildContext context) async {
    await Clipboard.setData(ClipboardData(text: jsonEncode(state.toJson())));
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text(
              'Sauvegarde copiée. Collez-la dans une note ou un message pour la garder.')));
    }
  }

  Future<void> _import(BuildContext context) async {
    final c = TextEditingController();
    final v = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Restaurer une sauvegarde'),
        content: TextField(
          controller: c,
          maxLines: 6,
          decoration:
          const InputDecoration(hintText: 'Collez la sauvegarde ici'),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Annuler')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, c.text.trim()),
              child: const Text('Restaurer')),
        ],
      ),
    );
    if (v != null && v.isNotEmpty) {
      try {
        await state.importJson(v);
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Sauvegarde restaurée.')));
        }
      } catch (_) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Sauvegarde invalide.')));
        }
      }
    }
  }

  Future<void> _deleteAll(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Effacer toutes les opérations ?'),
        content: const Text('Cette action est définitive.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Annuler')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Effacer')),
        ],
      ),
    );
    if (ok == true) await state.update(() => state.txs.clear());
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) => Scaffold(
        appBar: AppBar(title: const Text('Paramètres')),
        body: centered(
          ListView(
            padding: const EdgeInsets.all(16),
            children: [
              _sectionLabel(context, 'Paroisse'),
              Card(
                child: Column(children: [
                  ListTile(
                    leading: const Icon(Icons.church_outlined),
                    title: const Text('Nom de la paroisse / école'),
                    subtitle: Text(state.parishName),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => _editName(context),
                  ),
                  const Divider(height: 1),
                  ListTile(
                    leading: const Icon(Icons.attach_money),
                    title: const Text('Devise'),
                    subtitle: Text(state.currency),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => _editCurrency(context),
                  ),
                ]),
              ),
              _sectionLabel(context, 'Listes'),
              Card(
                child: Column(children: [
                  ListTile(
                    leading: const Icon(Icons.person_outline),
                    title: const Text('Célébrants'),
                    subtitle: Text('${state.celebrants.length} enregistré(s)'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => _editList(context, 'Célébrants',
                        state.celebrants, (l) => state.celebrants = l),
                  ),
                  const Divider(height: 1),
                  ListTile(
                    leading: const Icon(Icons.schedule),
                    title: const Text('Heures de messe'),
                    subtitle: Text(state.massTimes.join(', ')),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => _editList(context, 'Heures de messe',
                        state.massTimes, (l) => state.massTimes = l),
                  ),
                  const Divider(height: 1),
                  ListTile(
                    leading: const Icon(Icons.arrow_downward, color: kEntry),
                    title: const Text('Catégories d\'entrées'),
                    subtitle: Text('${state.entryCats.length} catégories'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => _editList(context, 'Catégories d\'entrées',
                        state.entryCats, (l) => state.entryCats = l),
                  ),
                  const Divider(height: 1),
                  ListTile(
                    leading: const Icon(Icons.arrow_upward, color: kExit),
                    title: const Text('Catégories de sorties'),
                    subtitle: Text('${state.exitCats.length} catégories'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => _editList(context, 'Catégories de sorties',
                        state.exitCats, (l) => state.exitCats = l),
                  ),
                ]),
              ),
              _sectionLabel(context, 'Données'),
              Card(
                child: Column(children: [
                  ListTile(
                    leading: const Icon(Icons.backup_outlined),
                    title: const Text('Sauvegarder (copier les données)'),
                    onTap: () => _export(context),
                  ),
                  const Divider(height: 1),
                  ListTile(
                    leading: const Icon(Icons.restore),
                    title: const Text('Restaurer une sauvegarde'),
                    onTap: () => _import(context),
                  ),
                  const Divider(height: 1),
                  ListTile(
                    leading: const Icon(Icons.delete_forever, color: kExit),
                    title: const Text('Effacer toutes les opérations',
                        style: TextStyle(color: kExit)),
                    onTap: () => _deleteAll(context),
                  ),
                ]),
              ),
              const SizedBox(height: 16),
              Center(
                  child: Text('MesseCaisse 1.0',
                      style: Theme.of(context).textTheme.bodySmall)),
            ],
          ),
          maxWidth: 700,
        ),
      ),
    );
  }

  Widget _sectionLabel(BuildContext context, String t) => Padding(
    padding: const EdgeInsets.fromLTRB(4, 16, 4, 8),
    child: Text(t.toUpperCase(),
        style: Theme.of(context).textTheme.labelLarge?.copyWith(
            color: kSeed, fontWeight: FontWeight.bold, letterSpacing: 1)),
  );
}

class ListEditorPage extends StatefulWidget {
  final String title;
  final List<String> items;
  const ListEditorPage({super.key, required this.title, required this.items});

  @override
  State<ListEditorPage> createState() => _ListEditorPageState();
}

class _ListEditorPageState extends State<ListEditorPage> {
  late List<String> _items;
  final _c = TextEditingController();

  @override
  void initState() {
    super.initState();
    _items = [...widget.items];
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  void _add() {
    final v = _c.text.trim();
    if (v.isEmpty || _items.contains(v)) return;
    setState(() => _items.add(v));
    _c.clear();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) Navigator.pop(context, _items);
      },
      child: Scaffold(
        appBar: AppBar(title: Text(widget.title)),
        body: centered(
          Column(
            children: [
              Padding(
                padding: const EdgeInsets.all(16),
                child: Row(children: [
                  Expanded(
                    child: TextField(
                      controller: _c,
                      decoration: const InputDecoration(hintText: 'Ajouter...'),
                      onSubmitted: (_) => _add(),
                    ),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(onPressed: _add, child: const Text('Ajouter')),
                ]),
              ),
              Expanded(
                child: ListView.builder(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  itemCount: _items.length,
                  itemBuilder: (context, i) => Card(
                    margin: const EdgeInsets.only(bottom: 6),
                    child: ListTile(
                      title: Text(_items[i]),
                      trailing: IconButton(
                        icon: const Icon(Icons.delete_outline),
                        onPressed: () => setState(() => _items.removeAt(i)),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
          maxWidth: 700,
        ),
      ),
    );
  }
}