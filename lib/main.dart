import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:geolocator/geolocator.dart';
import 'package:image_picker/image_picker.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart'; // Ajouté pour le guidage
import 'dart:convert';
import 'dart:math' as math;
import 'dart:async';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(
    const MaterialApp(home: SlowTravelApp(), debugShowCheckedModeBanner: false),
  );
}

// --- MODÈLES ---
class Avis {
  String texte;
  double note;
  String? imageBase64;
  Avis(this.texte, this.note, {this.imageBase64});
  Map<String, dynamic> toJson() => {
    'texte': texte,
    'note': note,
    'image': imageBase64,
  };
  factory Avis.fromJson(Map<String, dynamic> j) =>
      Avis(j['texte'], j['note'], imageBase64: j['image']);
}

class LieuInteret {
  final String id;
  String nom;
  String type;
  LatLng coordonnees;
  List<Avis> commentaires;
  LieuInteret({
    required this.id,
    required this.nom,
    required this.type,
    required this.coordonnees,
    required this.commentaires,
  });
  double get noteMoyenne => commentaires.isEmpty
      ? 0
      : commentaires.map((m) => m.note).reduce((a, b) => a + b) /
            commentaires.length;
  Map<String, dynamic> toJson() => {
    'id': id,
    'nom': nom,
    'type': type,
    'lat': coordonnees.latitude,
    'lng': coordonnees.longitude,
    'avis': commentaires.map((a) => a.toJson()).toList(),
  };
  factory LieuInteret.fromJson(Map<String, dynamic> j) => LieuInteret(
    id: j['id'],
    nom: j['nom'],
    type: j['type'],
    coordonnees: LatLng(j['lat'], j['lng']),
    commentaires: (j['avis'] as List).map((a) => Avis.fromJson(a)).toList(),
  );
}

class SlowTravelApp extends StatefulWidget {
  const SlowTravelApp({super.key});
  @override
  State<SlowTravelApp> createState() => _SlowTravelAppState();
}

class _SlowTravelAppState extends State<SlowTravelApp> {
  final MapController _mapController = MapController();

  List<LieuInteret> listeLieux = [];
  int _joursRestants = 3;
  int _heuresRestantes = 0;
  int _minutesRestantes = 0;
  List<LatLng> traceItineraire = [];
  LatLng maPosition = const LatLng(43.64, 2.34);
  double monCap = 0.0;
  bool gpsInitialise = false;
  double valeurDetour = 15.0;
  bool modeTrajetActif = false;
  bool suivrePosition = true;
  String filtreTypeActuel = 'Tous';
  StreamSubscription<Position>? _positionStream;
  Timer? _timerCompteur;

  // --- VARIABLES COMMERCIALISATION ---
  bool _periodeEssaiDepassee = false;
  bool _estVIP = false;

  final TextEditingController _nomController = TextEditingController();
  final TextEditingController _avisController = TextEditingController();
  final TextEditingController _nouveauCommentController =
      TextEditingController();

  String _typeSelectionne = 'Vue';
  double _noteCreation = 4.0;
  String? _imageBase64Temp;
  final ImagePicker _picker = ImagePicker();

  @override
  void initState() {
    super.initState();
    _ecouterPosition();
    _chargerLieuxSauvegardes();
    _verifierPeriodeEssai();

    // On lance le chrono une seule fois ici
    _timerCompteur = Timer.periodic(const Duration(minutes: 1), (timer) {
      _verifierPeriodeEssai();
    });
  }

  @override
  void dispose() {
    _timerCompteur?.cancel(); // On arrête le chrono proprement
    _positionStream?.cancel();
    _nomController.dispose();
    _avisController.dispose();
    _nouveauCommentController.dispose();
    super.dispose();
  }

  Future<void> _verifierPeriodeEssai() async {
    final prefs = await SharedPreferences.getInstance();

    // 1. Vérification VIP
    _estVIP = prefs.getBool('is_vip') ?? false;
    if (_estVIP) {
      setState(() => _periodeEssaiDepassee = false);
      return;
    }

    // 2. Gestion de la date d'installation
    String? dateInstallStr = prefs.getString('slow_travel_install_timestamp');
    DateTime now = DateTime.now();

    if (dateInstallStr == null) {
      dateInstallStr = now.toIso8601String();
      await prefs.setString('slow_travel_install_timestamp', dateInstallStr);
    }

    DateTime dateInstallation = DateTime.parse(dateInstallStr);

    // 3. Calcul de l'écart (Limite de 3 jours)
    Duration limite = const Duration(days: 3);
    Duration ecoule = now.difference(dateInstallation);
    Duration restant = limite - ecoule;

    // 4. Mise à jour des chiffres de l'interface
    setState(() {
      if (restant.isNegative) {
        _periodeEssaiDepassee = true;
      } else {
        _periodeEssaiDepassee = false;
        _joursRestants = restant.inDays;
        _heuresRestantes = restant.inHours.remainder(24);
        _minutesRestantes = restant.inMinutes.remainder(60);
      }
    });
  }

  // --- NOUVELLE FONCTION : GUIDAGE GPS ---
  Future<void> _lancerGuidage(LatLng destination) async {
    final url =
        "https://www.google.com/maps/dir/?api=1&destination=${destination.latitude},${destination.longitude}&travelmode=driving";
    if (await canLaunchUrl(Uri.parse(url))) {
      await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
    }
  }

  // --- LOGIQUE COMMERCIALE ---

  Future<void> _devenirVIP() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('is_vip', true);
    setState(() {
      _estVIP = true;
      _periodeEssaiDepassee = false;
    });
  }

  void _verifierCodePromo(String code) {
    List<String> codesVIP = ['SLOW26', 'CLUB-CC', 'MAGIQUE', 'EVASION'];
    if (codesVIP.contains(code.toUpperCase().trim())) {
      _devenirVIP();
      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text("Code valide ! Bienvenue VIP."),
          backgroundColor: Colors.green,
        ),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text("Code invalide."),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  void _ouvrirFenetreCode() {
    final TextEditingController codeController = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("Code Partenaire"),
        content: TextField(
          controller: codeController,
          decoration: const InputDecoration(hintText: "Entrez votre code"),
          textCapitalization: TextCapitalization.characters,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text("Annuler"),
          ),
          ElevatedButton(
            onPressed: () => _verifierCodePromo(codeController.text),
            child: const Text("VALIDER"),
          ),
        ],
      ),
    );
  }

  // --- WIDGETS COMMERCIAUX ---
  Widget _buildPaywall() {
    return Container(
      color: Colors.white,
      padding: const EdgeInsets.all(30),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.auto_stories, size: 80, color: Colors.green),
          const SizedBox(height: 20),
          const Text(
            "L'aventure continue !",
            style: TextStyle(fontSize: 26, fontWeight: FontWeight.bold),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 15),
          const Text(
            "Votre période d'essai est terminée. Choisissez un pass pour continuer.",
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 16, color: Colors.grey),
          ),
          const SizedBox(height: 40),
          _buildOptionPrix("Pass Vacances (15 jours)", "6 €"),
          _buildOptionPrix("Abonnement Mensuel", "5 € / mois"),
          _buildOptionPrix("Passionné (1 an)", "48 € / an", highlight: true),
          const SizedBox(height: 20),
          TextButton.icon(
            icon: const Icon(Icons.card_giftcard, color: Colors.orange),
            label: const Text(
              "J'ai un code partenaire",
              style: TextStyle(color: Colors.orange),
            ),
            onPressed: () => _ouvrirFenetreCode(),
          ),
          const SizedBox(height: 10),
          TextButton(
            onPressed: () => _devenirVIP(),
            child: const Text("Restaurer mes achats"),
          ),
        ],
      ),
    );
  }

  Widget _buildOptionPrix(String titre, String prix, {bool highlight = false}) {
    return Container(
      margin: const EdgeInsets.only(bottom: 15),
      width: double.infinity,
      child: ElevatedButton(
        style: ElevatedButton.styleFrom(
          backgroundColor: highlight ? Colors.orange : Colors.green,
          padding: const EdgeInsets.symmetric(vertical: 15),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(15),
          ),
        ),
        onPressed: () {},
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceAround,
          children: [
            Text(
              titre,
              style: const TextStyle(fontSize: 16, color: Colors.white),
            ),
            Text(
              prix,
              style: const TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
                color: Colors.white,
              ),
            ),
          ],
        ),
      ),
    );
  }

  double _calculerZoom(double minutes) {
    if (minutes <= 5) return 14.5;
    if (minutes <= 15) return 12.5;
    if (minutes <= 30) return 11.0;
    if (minutes <= 45) return 10.0;
    return 9.0;
  }

  void _ecouterPosition() {
    _positionStream =
        Geolocator.getPositionStream(
          locationSettings: const LocationSettings(
            accuracy: LocationAccuracy.high,
            distanceFilter: 5,
          ),
        ).listen((Position p) {
          if (!mounted) return;
          setState(() {
            maPosition = LatLng(p.latitude, p.longitude);
            if (p.heading >= 0) {
              monCap = p.heading;
            }
            gpsInitialise = true;
            if (suivrePosition && !modeTrajetActif) {
              _mapController.move(maPosition, _calculerZoom(valeurDetour));
            }
          });
        });
  }

  Future<List<Map<String, dynamic>>> _chercherSuggestions(String query) async {
    if (query.length < 3) return [];
    double delta = 2.0;
    final url =
        "https://nominatim.openstreetmap.org/search?q=$query&format=json&limit=10&viewbox=${maPosition.longitude - delta},${maPosition.latitude + delta},${maPosition.longitude + delta},${maPosition.latitude - delta}&addressdetails=1&accept-language=fr";
    try {
      final res = await http.get(Uri.parse(url));
      return List<Map<String, dynamic>>.from(json.decode(res.body));
    } catch (e) {
      return [];
    }
  }

  Future<void> _tracerRoute(double lat, double lon) async {
    final url =
        "https://router.project-osrm.org/route/v1/driving/${maPosition.longitude},${maPosition.latitude};$lon,$lat?overview=full&geometries=geojson";
    final res = await http.get(Uri.parse(url));
    final data = json.decode(res.body);
    if (data['routes'] != null && data['routes'].isNotEmpty) {
      var coords = data['routes'][0]['geometry']['coordinates'] as List;
      setState(() {
        traceItineraire = coords
            .map((c) => LatLng(c[1].toDouble(), c[0].toDouble()))
            .toList();
        modeTrajetActif = true;
        suivrePosition = false;
        _mapController.fitCamera(
          CameraFit.bounds(
            bounds: LatLngBounds.fromPoints(traceItineraire),
            padding: const EdgeInsets.all(50),
          ),
        );
      });
    }
  }

  Future<void> _sauvegarderLieux() async {
    final prefs = await SharedPreferences.getInstance();
    final data = json.encode(listeLieux.map((l) => l.toJson()).toList());
    await prefs.setString('slow_travel_data', data);
  }

  Future<void> _chargerLieuxSauvegardes() async {
    final prefs = await SharedPreferences.getInstance();
    final data = prefs.getString('slow_travel_data');
    if (data != null) {
      final List decoded = json.decode(data);
      setState(() {
        listeLieux = decoded.map((item) => LieuInteret.fromJson(item)).toList();
      });
    }
  }

  double _distGps(LatLng p1, LatLng p2) {
    var p = 0.017453292519943295;
    var a =
        0.5 -
        math.cos((p2.latitude - p1.latitude) * p) / 2 +
        math.cos(p1.latitude * p) *
            math.cos(p2.latitude * p) *
            (1 - math.cos((p2.longitude - p1.longitude) * p)) /
            2;
    return 12742 * math.asin(math.sqrt(a));
  }

  double _distanceTrajet(LatLng point, List<LatLng> trajet) {
    if (trajet.isEmpty) return 0;
    double minD = double.infinity;
    for (int i = 0; i < trajet.length - 1; i += 5) {
      double d = _distGps(point, trajet[i]);
      if (d < minD) minD = d;
      if (minD < 0.1) break;
    }
    return minD;
  }

  Widget _getIcon(String type) {
    switch (type) {
      case 'Bivouac':
        return const Icon(Icons.directions_bus, color: Colors.brown, size: 30);
      case 'Musée':
        return const Icon(Icons.museum, color: Colors.purple, size: 30);
      case 'Nature':
        return const Icon(Icons.park, color: Colors.green, size: 30);
      case 'Monument':
        return const Icon(Icons.castle, color: Colors.orange, size: 30);
      case 'Archéo':
        return const Icon(
          Icons.account_balance,
          color: Colors.blueGrey,
          size: 30,
        );
      case 'Histoire':
        return const Icon(
          Icons.auto_stories,
          color: Colors.redAccent,
          size: 30,
        );
      default:
        return const Icon(Icons.wallpaper, color: Colors.blue, size: 30);
    }
  }

  void _afficherFiche(LieuInteret lieu) {
    _nouveauCommentController.clear();
    _imageBase64Temp = null;
    _noteCreation = 3;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(25)),
      ),
      builder: (context) => StatefulBuilder(
        builder: (context, setS) => DraggableScrollableSheet(
          initialChildSize: 0.9,
          expand: false,
          builder: (context, scroll) => Padding(
            padding: const EdgeInsets.all(20),
            child: ListView(
              controller: scroll,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Expanded(
                      child: Text(
                        lieu.nom,
                        style: const TextStyle(
                          fontSize: 24,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.delete_forever, color: Colors.red),
                      onPressed: () {
                        setState(
                          () => listeLieux.removeWhere((l) => l.id == lieu.id),
                        );
                        _sauvegarderLieux();
                        Navigator.pop(context);
                      },
                    ),
                  ],
                ),
                Text(
                  "${lieu.type} • ${lieu.noteMoyenne.toStringAsFixed(1)} ⭐",
                  style: const TextStyle(fontSize: 16, color: Colors.grey),
                ),
                const SizedBox(height: 15),
                // --- BOUTON GUIDAGE INTÉGRÉ ---
                ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.blue,
                    foregroundColor: Colors.white,
                    minimumSize: const Size(double.infinity, 50),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(15),
                    ),
                  ),
                  icon: const Icon(Icons.directions),
                  label: const Text(
                    "Y ALLER (GPS EXTERNE)",
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  onPressed: () => _lancerGuidage(lieu.coordonnees),
                ),
                const Divider(height: 30),
                Container(
                  padding: const EdgeInsets.all(15),
                  decoration: BoxDecoration(
                    color: Colors.grey[100],
                    borderRadius: BorderRadius.circular(15),
                  ),
                  child: Column(
                    children: [
                      TextField(
                        controller: _nouveauCommentController,
                        decoration: const InputDecoration(
                          hintText: "Ajouter un avis...",
                        ),
                      ),
                      Row(
                        children: [
                          IconButton(
                            icon: const Icon(Icons.add_a_photo),
                            onPressed: () async {
                              final img = await _picker.pickImage(
                                source: ImageSource.gallery,
                                maxWidth: 800,
                              );
                              if (img != null) {
                                final b = await img.readAsBytes();
                                setS(() => _imageBase64Temp = base64Encode(b));
                              }
                            },
                          ),
                          if (_imageBase64Temp != null)
                            Image.memory(
                              base64Decode(_imageBase64Temp!),
                              height: 50,
                              width: 50,
                              fit: BoxFit.cover,
                            ),
                          const Spacer(),
                          Slider(
                            value: _noteCreation,
                            min: 1,
                            max: 5,
                            divisions: 4,
                            onChanged: (v) => setS(() => _noteCreation = v),
                          ),
                        ],
                      ),
                      ElevatedButton(
                        onPressed: () {
                          if (_nouveauCommentController.text.isNotEmpty) {
                            setState(
                              () => lieu.commentaires.insert(
                                0,
                                Avis(
                                  _nouveauCommentController.text,
                                  _noteCreation,
                                  imageBase64: _imageBase64Temp,
                                ),
                              ),
                            );
                            _sauvegarderLieux();
                            setS(() {
                              _nouveauCommentController.clear();
                              _imageBase64Temp = null;
                            });
                          }
                        },
                        child: const Text("PUBLIER L'AVIS"),
                      ),
                    ],
                  ),
                ),
                ...lieu.commentaires.map(
                  (a) => Card(
                    margin: const EdgeInsets.only(top: 20),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (a.imageBase64 != null)
                          Image.memory(
                            base64Decode(a.imageBase64!),
                            width: double.infinity,
                            height: 200,
                            fit: BoxFit.cover,
                          ),
                        ListTile(
                          title: Text("⭐" * a.note.toInt()),
                          subtitle: Text(a.texte),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _ouvrirCreation(LatLng pos) {
    _imageBase64Temp = null;
    _noteCreation = 4.0;
    _nomController.clear();
    _avisController.clear();
    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => AlertDialog(
          title: const Text("Ajouter ce lieu"),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: _nomController,
                  decoration: const InputDecoration(labelText: "Nom du spot"),
                ),
                DropdownButton<String>(
                  value: _typeSelectionne,
                  isExpanded: true,
                  items:
                      [
                            'Vue',
                            'Monument',
                            'Nature',
                            'Bivouac',
                            'Musée',
                            'Archéo',
                            'Histoire',
                          ]
                          .map(
                            (t) => DropdownMenuItem(value: t, child: Text(t)),
                          )
                          .toList(),
                  onChanged: (v) => setS(() => _typeSelectionne = v!),
                ),
                TextField(
                  controller: _avisController,
                  decoration: const InputDecoration(labelText: "Votre avis"),
                ),
                Slider(
                  value: _noteCreation,
                  min: 1,
                  max: 5,
                  divisions: 4,
                  onChanged: (v) => setS(() => _noteCreation = v),
                ),
                ElevatedButton.icon(
                  icon: const Icon(Icons.camera_alt),
                  label: const Text("Photo"),
                  onPressed: () async {
                    final img = await _picker.pickImage(
                      source: ImageSource.gallery,
                      maxWidth: 800,
                    );
                    if (img != null) {
                      final b = await img.readAsBytes();
                      setS(() => _imageBase64Temp = base64Encode(b));
                    }
                  },
                ),
                if (_imageBase64Temp != null)
                  Image.memory(base64Decode(_imageBase64Temp!), height: 80),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text("Annuler"),
            ),
            ElevatedButton(
              onPressed: () {
                setState(() {
                  listeLieux.add(
                    LieuInteret(
                      id: DateTime.now().toString(),
                      nom: _nomController.text.isEmpty
                          ? "Spot"
                          : _nomController.text,
                      type: _typeSelectionne,
                      coordonnees: pos,
                      commentaires: [
                        Avis(
                          _avisController.text.isEmpty
                              ? "Découvert"
                              : _avisController.text,
                          _noteCreation,
                          imageBase64: _imageBase64Temp,
                        ),
                      ],
                    ),
                  );
                });
                _sauvegarderLieux();
                Navigator.pop(ctx);
              },
              child: const Text("ENREGISTRER"),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_periodeEssaiDepassee) {
      return Scaffold(body: _buildPaywall());
    }

    List<LieuInteret> visibles = listeLieux.where((l) {
      bool okType = filtreTypeActuel == 'Tous' || l.type == filtreTypeActuel;
      double distMax = valeurDetour * 0.8;
      if (modeTrajetActif) {
        return okType &&
            _distanceTrajet(l.coordonnees, traceItineraire) <= distMax;
      }
      return okType && _distGps(maPosition, l.coordonnees) <= distMax;
    }).toList();

    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.green,
        title: Autocomplete<Map<String, dynamic>>(
          displayStringForOption: (o) =>
              o['display_name'].toString().split(',')[0],
          optionsBuilder: (t) => _chercherSuggestions(t.text),
          onSelected: (o) =>
              _tracerRoute(double.parse(o['lat']), double.parse(o['lon'])),
          optionsViewBuilder: (context, onSelected, options) => Align(
            alignment: Alignment.topLeft,
            child: Material(
              elevation: 4.0,
              child: Container(
                width: MediaQuery.of(context).size.width * 0.8,
                color: Colors.white,
                child: ListView.builder(
                  padding: EdgeInsets.zero,
                  shrinkWrap: true,
                  itemCount: options.length,
                  itemBuilder: (ctx, i) {
                    final o = options.elementAt(i);
                    return ListTile(
                      title: Text(
                        o['display_name'].split(',')[0],
                        style: const TextStyle(color: Colors.black),
                      ),
                      onTap: () => onSelected(o),
                    );
                  },
                ),
              ),
            ),
          ),
          fieldViewBuilder:
              (context, controller, focusNode, onFieldSubmitted) => TextField(
                controller: controller,
                focusNode: focusNode,
                style: const TextStyle(color: Colors.white),
                decoration: const InputDecoration(
                  hintText: "Où allez-vous ?",
                  border: InputBorder.none,
                  hintStyle: TextStyle(color: Colors.white70),
                ),
              ),
        ),
        actions: [
          IconButton(
            icon: Icon(
              suivrePosition ? Icons.gps_fixed : Icons.gps_not_fixed,
              color: Colors.white,
            ),
            onPressed: () {
              setState(() => suivrePosition = !suivrePosition);
              if (suivrePosition) {
                _mapController.move(maPosition, _mapController.camera.zoom);
              }
            },
          ),
        ],
      ),
      body: Column(
        children: [
          if (!_estVIP)
            Container(
              width: double.infinity,
              color: Colors.orange[100],
              padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 15),
              child: Row(
                children: [
                  const Icon(Icons.timer, color: Colors.orange, size: 20),
                  const SizedBox(width: 10),
                  Text(
                    "Essai : ${_joursRestants}j ${_heuresRestantes}h ${_minutesRestantes}m restantes",
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                  const Spacer(),
                  GestureDetector(
                    onTap: () => _ouvrirFenetreCode(),
                    child: const Text(
                      "VOIR OFFRES",
                      style: TextStyle(
                        color: Colors.green,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          Container(
            height: 50,
            color: Colors.green,
            child: ListView(
              scrollDirection: Axis.horizontal,
              children:
                  [
                        'Tous',
                        'Vue',
                        'Monument',
                        'Nature',
                        'Bivouac',
                        'Musée',
                        'Archéo',
                        'Histoire',
                      ]
                      .map(
                        (t) => Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 5),
                          child: ChoiceChip(
                            label: Text(t),
                            selected: filtreTypeActuel == t,
                            onSelected: (s) =>
                                setState(() => filtreTypeActuel = t),
                          ),
                        ),
                      )
                      .toList(),
            ),
          ),
          Container(
            padding: const EdgeInsets.all(10),
            child: Column(
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      modeTrajetActif ? "Écart route" : "Radar (min)",
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                    Text("${valeurDetour.toInt()} min"),
                  ],
                ),
                Slider(
                  value: valeurDetour,
                  min: 2,
                  max: 60,
                  divisions: 29,
                  onChanged: (v) {
                    setState(() {
                      valeurDetour = v;
                      if (suivrePosition && !modeTrajetActif) {
                        _mapController.move(maPosition, _calculerZoom(v));
                      }
                    });
                  },
                ),
                if (modeTrajetActif)
                  TextButton(
                    onPressed: () => setState(() {
                      modeTrajetActif = false;
                      traceItineraire = [];
                      suivrePosition = true;
                    }),
                    child: const Text(
                      "RETOUR MODE RADAR",
                      style: TextStyle(
                        color: Colors.red,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          Expanded(
            child: FlutterMap(
              mapController: _mapController,
              options: MapOptions(
                initialCenter: maPosition,
                initialZoom: 12,
                onTap: (p, l) => _ouvrirCreation(l),
                // --- ACTIVATION DE LA ROTATION MANUELLE ---
                interactionOptions: const InteractionOptions(
                  flags: InteractiveFlag.all,
                ),
              ),
              children: [
                TileLayer(
                  urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                ),
                if (modeTrajetActif)
                  PolylineLayer(
                    polylines: [
                      Polyline(
                        points: traceItineraire,
                        color: Colors.blue.withValues(alpha: 0.6),
                        strokeWidth: 6,
                      ),
                    ],
                  ),
                MarkerLayer(
                  markers: [
                    // --- MARQUEUR POSITION AVEC BOUSSOLE ROTATIVE ---
                    Marker(
                      point: maPosition,
                      width: 60,
                      height: 60,
                      child: Transform.rotate(
                        angle: (monCap * (math.pi / 180)),
                        child: Stack(
                          alignment: Alignment.center,
                          children: [
                            Container(
                              width: 40,
                              height: 40,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: Colors.blue.withValues(alpha: 0.7),
                              ),
                            ),
                            const Icon(
                              Icons.navigation,
                              color: Colors.blue,
                              size: 35,
                            ),
                          ],
                        ),
                      ),
                    ),
                    ...visibles.map(
                      (l) => Marker(
                        point: l.coordonnees,
                        width: 45,
                        height: 45,
                        child: GestureDetector(
                          onTap: () => _afficherFiche(l),
                          child: Column(
                            children: [
                              Container(
                                padding: const EdgeInsets.all(2),
                                decoration: BoxDecoration(
                                  color: Colors.white,
                                  borderRadius: BorderRadius.circular(5),
                                ),
                                child: Text(
                                  "${l.noteMoyenne.toStringAsFixed(1)}⭐",
                                  style: const TextStyle(
                                    fontSize: 8,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ),
                              _getIcon(l.type),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
