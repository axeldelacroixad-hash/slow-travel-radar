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

LatLng? destinationActuelle;
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
  LatLng? destinationActuelle;
  int _heuresRestantes = 0;
  int _minutesRestantes = 0;
  List<LatLng> traceItineraire = [];
  LatLng maPosition = const LatLng(43.64, 2.34);
  double monCap = 0.0;
  bool gpsInitialise = false;
  double valeurDetour = 15.0;
  bool modeTrajetActif = false;
  bool suivrePosition = true;
  bool _eviterPeages = false;
  String filtreTypeActuel = 'Tous';
  StreamSubscription<Position>? _positionStream;
  Timer? _timerCompteur;
  double distanceTrajet = 0.0; // Stocke la distance en km
  double dureeTrajet = 0.0; // Stocke la durée en minutes
  double vitesseActuelle = 0.0;
  Color couleurRouteActuelle = Colors.blue;
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

            // --- AJOUT DE LA VITESSE ---
            // On vérifie si la vitesse est disponible (parfois négative si signal faible)
            // On multiplie par 3.6 pour passer de m/s à km/h
            vitesseActuelle = p.speed > 0 ? p.speed * 3.6 : 0.0;

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

  Future<void> _tracerRoute(double lat, double lon) async {
    destinationActuelle = LatLng(lat, lon);
    // 1. TA CLÉ API OPENROUTE SERVICE (gratuite sur openrouteservice.org)
    const String apiKey =
        "eyJvcmciOiI1YjNjZTM1OTc4NTExMTAwMDFjZjYyNDgiLCJpZCI6ImFjYWFjN2RhNWY5YzQ4OGRhOTg3YWIzM2EwYzU1YjBlIiwiaCI6Im11cm11cjY0In0=";

    final url = Uri.parse(
      "https://api.openrouteservice.org/v2/directions/driving-car/geojson",
    );

    try {
      final response = await http.post(
        url,
        headers: {
          'Authorization': apiKey,
          'Content-Type': 'application/json; charset=utf-8',
        },
        body: jsonEncode({
          "coordinates": [
            [maPosition.longitude, maPosition.latitude],
            [lon, lat],
          ],
          // Voici la nouvelle structure correcte :
          "options": {
            "avoid_features": _eviterPeages ? ["tollways", "highways"] : [],
          },
          "language": "fr",
        }),
      );

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        // Avec OpenRouteService, le chemin est dans features[0] -> geometry -> coordinates
        var coords = data['features'][0]['geometry']['coordinates'] as List;

        setState(() {
          traceItineraire = coords
              .map((c) => LatLng(c[1].toDouble(), c[0].toDouble()))
              .toList();

          // --- AJOUT DES INFOS DE TRAJET ---
          // OpenRouteService donne la distance en mètres et la durée en secondes
          var summary = data['features'][0]['properties']['summary'];
          distanceTrajet = summary['distance'] / 1000.0; // Conversion en km
          dureeTrajet = summary['duration'] / 60.0; // Conversion en minutes
          // ---------------------------------

          modeTrajetActif = true;
          suivrePosition = false;
          couleurRouteActuelle = _eviterPeages ? Colors.green : Colors.blue;

          _mapController.fitCamera(
            CameraFit.bounds(
              bounds: LatLngBounds.fromPoints(traceItineraire),
              padding: const EdgeInsets.all(50),
            ),
          );
        });
      } else {}
    } catch (e) {
      ("Erreur lors du calcul du trajet : $e");
    }
  }

  Future<void> _sauvegarderLieux() async {
    final prefs = await SharedPreferences.getInstance();
    final data = json.encode(listeLieux.map((l) => l.toJson()).toList());
    await prefs.setString('slow_travel_data', data);
  }

  Future<Iterable<Map<String, dynamic>>> _chercherSuggestions(
    String query,
  ) async {
    if (query.length < 3) return const Iterable.empty();

    // Photon est mondial et gère très bien l'autocomplétion (prédiction)
    final url = Uri.parse(
      "https://photon.komoot.io/api/?q=${Uri.encodeComponent(query)}&limit=10&lang=fr",
    );

    try {
      final response = await http.get(url);

      if (response.statusCode == 200) {
        // utf8.decode est vital ici pour les accents (ex: Bruxelles, Málaga)
        final data = json.decode(utf8.decode(response.bodyBytes));
        final List features = data['features'];

        return features.map((f) {
          final p = f['properties'];
          final coords = f['geometry']['coordinates'];

          // On construit un nom lisible : Nom, Ville, Pays
          List<String> components = [];
          if (p['name'] != null) components.add(p['name']);
          if (p['city'] != null) components.add(p['city']);
          if (p['country'] != null) components.add(p['country']);

          return {
            'display_name': components.join(', '),
            'lat': coords[1].toString(),
            'lon': coords[0].toString(),
          };
        });
      }
    } catch (e) {
      debugPrint("Erreur Monde : $e");
    }
    return const Iterable.empty();
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
                Builder(
                  builder: (context) {
                    // 1. On crée une liste triée : les avis avec photos en premier (index -1), sans photos au fond (index 1)
                    final commentairesTries = List.from(lieu.commentaires)
                      ..sort((a, b) {
                        if (a.imageBase64 != null && b.imageBase64 == null) {
                          return -1;
                        }
                        if (a.imageBase64 == null && b.imageBase64 != null) {
                          return 1;
                        }
                        return 0;
                      });

                    return GridView.builder(
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      gridDelegate:
                          const SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: 2, // Garde les 2 colonnes
                            crossAxisSpacing: 10,
                            mainAxisSpacing: 10,
                            childAspectRatio: 0.75,
                          ),
                      itemCount:
                          commentairesTries.length, // Utilise la liste triée
                      itemBuilder: (context, index) {
                        final a =
                            commentairesTries[index]; // On récupère l'avis trié
                        final bool aUnePhoto = a.imageBase64 != null;

                        return Card(
                          clipBehavior: Clip.antiAlias,
                          // Si pas de photo, on met un fond gris très léger pour le différencier
                          color: aUnePhoto ? Colors.white : Colors.grey[50],
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              if (aUnePhoto)
                                Expanded(
                                  child: GestureDetector(
                                    onTap: () {
                                      showDialog(
                                        context: context,
                                        builder: (ctx) => Dialog(
                                          backgroundColor: Colors.black,
                                          child: InteractiveViewer(
                                            child: Image.memory(
                                              base64Decode(a.imageBase64!),
                                            ),
                                          ),
                                        ),
                                      );
                                    },
                                    child: Image.memory(
                                      base64Decode(a.imageBase64!),
                                      width: double.infinity,
                                      fit: BoxFit.cover,
                                    ),
                                  ),
                                )
                              else
                                // Si pas de photo, on met une petite icône vide pour garder la structure
                                const Expanded(
                                  child: Center(
                                    child: Icon(
                                      Icons.chat_bubble_outline,
                                      color: Colors.grey,
                                      size: 30,
                                    ),
                                  ),
                                ),

                              Padding(
                                padding: const EdgeInsets.all(8.0),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      "⭐" * a.note.toInt(),
                                      style: const TextStyle(fontSize: 10),
                                    ),
                                    const SizedBox(height: 4),
                                    Text(
                                      a.texte,
                                      style: const TextStyle(fontSize: 11),
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        );
                      },
                    );
                  },
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

    showModalBottomSheet(
      context: context,
      isScrollControlled: true, // Pour que le clavier ne cache rien
      backgroundColor: Colors.transparent, // Pour gérer nos propres arrondis
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => Container(
          decoration: const BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.vertical(top: Radius.circular(25)),
          ),
          padding: EdgeInsets.only(
            top: 20,
            left: 20,
            right: 20,
            bottom:
                MediaQuery.of(ctx).viewInsets.bottom +
                20, // Ajuste selon le clavier
          ),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Barre de drag en haut pour le look
                Center(
                  child: Container(
                    width: 40,
                    height: 5,
                    decoration: BoxDecoration(
                      color: Colors.grey[300],
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                const Text(
                  "Nouveau Spot",
                  style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 20),

                // Champ Nom
                TextField(
                  controller: _nomController,
                  decoration: InputDecoration(
                    labelText: "Nom du spot",
                    prefixIcon: const Icon(
                      Icons.edit_location_alt,
                      color: Colors.green,
                    ),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                ),
                const SizedBox(height: 15),

                // Type de lieu stylisé
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  decoration: BoxDecoration(
                    border: Border.all(color: Colors.grey),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: DropdownButtonHideUnderline(
                    child: DropdownButton<String>(
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
                                (t) =>
                                    DropdownMenuItem(value: t, child: Text(t)),
                              )
                              .toList(),
                      onChanged: (v) => setS(() => _typeSelectionne = v!),
                    ),
                  ),
                ),
                const SizedBox(height: 15),

                // Avis
                TextField(
                  controller: _avisController,
                  maxLines: 2,
                  decoration: InputDecoration(
                    labelText: "Votre avis",
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                ),
                const SizedBox(height: 15),

                // Note avec Slider
                Row(
                  children: [
                    const Text(
                      "Note : ",
                      style: TextStyle(fontWeight: FontWeight.bold),
                    ),
                    Expanded(
                      child: Slider(
                        value: _noteCreation,
                        min: 1,
                        max: 5,
                        divisions: 4,
                        activeColor: Colors.green,
                        label: _noteCreation.toInt().toString(),
                        onChanged: (v) => setS(() => _noteCreation = v),
                      ),
                    ),
                    Text(
                      "${_noteCreation.toInt()}/5",
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                  ],
                ),

                // Photo section
                Row(
                  children: [
                    ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.grey[200],
                        foregroundColor: Colors.black,
                      ),
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
                    const SizedBox(width: 15),
                    if (_imageBase64Temp != null)
                      ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: Image.memory(
                          base64Decode(_imageBase64Temp!),
                          height: 50,
                          width: 50,
                          fit: BoxFit.cover,
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 25),

                // Bouton Enregistrer
                SizedBox(
                  width: double.infinity,
                  height: 50,
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.green,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
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
                    child: const Text(
                      "ENREGISTRER",
                      style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                      ),
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
          onSelected: (o) {
            double latSelection = double.parse(o['lat'].toString());
            double lonSelection = double.parse(o['lon'].toString());
            _tracerRoute(latSelection, lonSelection);
          },
          optionsViewBuilder: (context, onSelected, options) {
            return Align(
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
                          style: const TextStyle(
                            color: Colors.black,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        subtitle: Text(
                          o['display_name'],
                          style: const TextStyle(
                            color: Colors.black54,
                            fontSize: 10,
                          ),
                        ),
                        onTap: () => onSelected(o),
                      );
                    },
                  ),
                ),
              ),
            );
          },
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
          // --- BLOC SLOW TRAVEL AVEC SWITCH ---
          Row(
            children: [
              const Text(
                "Slow Travel",
                style: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                  fontSize: 16,
                ),
              ),
              Transform.scale(
                scale:
                    0.8, // On réduit un peu la taille pour que ça rentre bien
                child: Switch(
                  value: _eviterPeages,
                  activeThumbColor: Colors.white,
                  activeTrackColor: Colors.green[900],
                  inactiveThumbColor: Colors.grey[300],
                  inactiveTrackColor: Colors.white24,
                  onChanged: (bool value) {
                    setState(() {
                      _eviterPeages = value;
                    });
                    if (destinationActuelle != null) {
                      _tracerRoute(
                        destinationActuelle!.latitude,
                        destinationActuelle!.longitude,
                      );
                    }
                  },
                ),
              ),
            ],
          ),

          // --- TON BOUTON GPS ---
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
            child: Stack(
              // <--- ON AJOUTE LE STACK ICI
              children: [
                FlutterMap(
                  mapController: _mapController,
                  options: MapOptions(
                    initialCenter: maPosition,
                    initialZoom: 12,
                    onTap: (p, l) => _ouvrirCreation(l),
                    interactionOptions: const InteractionOptions(
                      flags: InteractiveFlag.all,
                    ),
                  ),
                  children: [
                    TileLayer(
                      urlTemplate:
                          'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                    ),
                    if (modeTrajetActif)
                      PolylineLayer(
                        polylines: [
                          Polyline(
                            points: traceItineraire,
                            // ON UTILISE LA VARIABLE SYNCHRONISÉE :
                            color: couleurRouteActuelle,
                            strokeWidth: 6,
                          ),
                        ],
                      ),
                    MarkerLayer(
                      markers: [
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
                                    color: Colors.blue.withValues(alpha: 0.3),
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
                ), // <--- FIN DU FLUTTERMAP
                // --- TON BANDEAU D'INFOS (POSITIONED) ---
                if (modeTrajetActif)
                  // --- UN SEUL BANDEAU D'INFOS PROPRE ---
                  Positioned(
                    bottom: 20,
                    left: 10,
                    right: 10,
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        // BLOC GAUCHE : VITESSE (Toujours visible)
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 15,
                            vertical: 8,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: 0.6),
                            borderRadius: BorderRadius.circular(15),
                            border: Border.all(color: Colors.white24, width: 1),
                          ),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                vitesseActuelle.toInt().toString(),
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 28,
                                ),
                              ),
                              const Text(
                                "km/h",
                                style: TextStyle(
                                  color: Colors.white70,
                                  fontSize: 10,
                                ),
                              ),
                            ],
                          ),
                        ),

                        // BLOC DROIT : DISTANCE / TEMPS (Seulement si trajet actif)
                        if (modeTrajetActif)
                          Container(
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: Colors.white.withValues(alpha: 0.85),
                              borderRadius: BorderRadius.circular(15),
                              boxShadow: [
                                BoxShadow(
                                  color: Colors.black.withValues(alpha: 0.2),
                                  blurRadius: 10,
                                ),
                              ],
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.end,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  _formaterTemps(dureeTrajet),
                                  style: const TextStyle(
                                    fontSize: 18,
                                    fontWeight: FontWeight.bold,
                                    color: Colors.black,
                                  ),
                                ),
                                Text(
                                  _formaterDistance(distanceTrajet),
                                  style: const TextStyle(
                                    fontSize: 14,
                                    color: Colors.green,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ],
                            ),
                          ),
                      ],
                    ),
                  ),
              ], // <--- FERMETURE DU CHILDREN DU STACK
            ), // <--- FERMETURE DU STACK
          ),
        ], // <--- FERMETURE DE L'EXPANDED        ],
      ),
    );
  }

  String _formaterTemps(double minutes) {
    int h = minutes ~/ 60;
    int m = (minutes % 60).toInt();
    if (h > 0) return "${h}h ${m.toString().padLeft(2, '0')}min";
    return "${m}min";
  }

  String _formaterDistance(double km) {
    if (km >= 1) return "${km.toStringAsFixed(1)} km";
    return "${(km * 1000).toInt()} m";
  }
}
