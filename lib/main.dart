import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:geolocator/geolocator.dart';
import 'package:image_picker/image_picker.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'dart:math' as math;
import 'dart:html' as html;
import 'dart:async';

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
  double get noteMoyenne {
    if (commentaires.isEmpty) return 0;
    return commentaires.map((m) => m.note).reduce((a, b) => a + b) /
        commentaires.length;
  }

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
  List<LatLng> traceItineraire = [];
  LatLng maPosition = const LatLng(46.6, 2.2);
  bool gpsInitialise = false;
  double valeurDetour = 15.0;
  bool modeTrajetActif = false;
  bool suivrePosition = true;
  String filtreTypeActuel = 'Tous';
  StreamSubscription<Position>? _positionStream;

  // Controllers pour la création
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
  }

  @override
  void dispose() {
    _positionStream?.cancel();
    super.dispose();
  }

  double _calculerZoom(double minutes) {
    if (minutes <= 5) return 14.5;
    if (minutes <= 15) return 12.5;
    if (minutes <= 30) return 11.0;
    if (minutes <= 45) return 10.0;
    return 9.0;
  }

  void _ecouterPosition() {
    Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 10,
      ),
    ).listen((Position p) {
      if (!mounted) return;
      setState(() {
        maPosition = LatLng(p.latitude, p.longitude);
        gpsInitialise = true;
        if (suivrePosition && !modeTrajetActif) {
          _mapController.move(maPosition, _calculerZoom(valeurDetour));
        }
      });
    });
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

  void _sauvegarderLieux() {
    final data = json.encode(listeLieux.map((l) => l.toJson()).toList());
    html.window.localStorage['slow_travel_master'] = data;
  }

  void _chargerLieuxSauvegardes() {
    final data = html.window.localStorage['slow_travel_master'];
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
      default:
        return const Icon(Icons.wallpaper, color: Colors.blue, size: 30);
    }
  }

  // --- INTERFACE : FICHE DÉTAILLÉE ---
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
                          hintText: "Ajouter un avis ou un conseil...",
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
                            Container(
                              margin: const EdgeInsets.only(left: 10),
                              height: 50,
                              width: 50,
                              child: Image.memory(
                                base64Decode(_imageBase64Temp!),
                                fit: BoxFit.cover,
                              ),
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
                      SizedBox(
                        width: double.infinity,
                        child: ElevatedButton(
                          onPressed: () {
                            if (_nouveauCommentController.text.isNotEmpty) {
                              setState(() {
                                lieu.commentaires.insert(
                                  0,
                                  Avis(
                                    _nouveauCommentController.text,
                                    _noteCreation,
                                    imageBase64: _imageBase64Temp,
                                  ),
                                );
                              });
                              _sauvegarderLieux();
                              setS(() {
                                _nouveauCommentController.clear();
                                _imageBase64Temp = null;
                              });
                            }
                          },
                          child: const Text("PUBLIER L'AVIS"),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 20),
                ...lieu.commentaires.map(
                  (a) => Card(
                    margin: const EdgeInsets.only(bottom: 20),
                    clipBehavior: Clip.antiAlias,
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

  // --- CRÉATION AVEC NOTE ET COMMENTAIRE ---
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
                  items: ['Vue', 'Monument', 'Nature', 'Bivouac', 'Musée']
                      .map((t) => DropdownMenuItem(value: t, child: Text(t)))
                      .toList(),
                  onChanged: (v) => setS(() => _typeSelectionne = v!),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: _avisController,
                  decoration: const InputDecoration(
                    labelText: "Votre avis / commentaire",
                    hintText: "C'est comment ?",
                  ),
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    const Text("Note : "),
                    Expanded(
                      child: Slider(
                        value: _noteCreation,
                        min: 1,
                        max: 5,
                        divisions: 4,
                        onChanged: (v) => setS(() => _noteCreation = v),
                      ),
                    ),
                    Text("${_noteCreation.toInt()}⭐"),
                  ],
                ),
                ElevatedButton.icon(
                  icon: const Icon(Icons.camera_alt),
                  label: const Text("Ajouter une photo"),
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
                  Padding(
                    padding: const EdgeInsets.only(top: 10),
                    child: Image.memory(
                      base64Decode(_imageBase64Temp!),
                      height: 80,
                    ),
                  ),
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
                          ? "Spot sans nom"
                          : _nomController.text,
                      type: _typeSelectionne,
                      coordonnees: pos,
                      commentaires: [
                        Avis(
                          _avisController.text.isEmpty
                              ? "Lieu découvert"
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

  Future<List<Map<String, dynamic>>> _chercherSuggestions(String query) async {
    if (query.length < 3) return [];
    final url =
        "https://nominatim.openstreetmap.org/search?q=$query&format=json&limit=5";
    final res = await http.get(Uri.parse(url));
    return List<Map<String, dynamic>>.from(json.decode(res.body));
  }

  @override
  Widget build(BuildContext context) {
    List<LieuInteret> visibles = listeLieux.where((l) {
      bool okType = filtreTypeActuel == 'Tous' || l.type == filtreTypeActuel;
      double distMax = valeurDetour * 0.8;
      if (modeTrajetActif)
        return okType &&
            _distanceTrajet(l.coordonnees, traceItineraire) <= distMax;
      return okType && _distGps(maPosition, l.coordonnees) <= distMax;
    }).toList();

    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.green,
        elevation: 0,
        title: Autocomplete<Map<String, dynamic>>(
          displayStringForOption: (o) => o['display_name'],
          optionsBuilder: (t) => _chercherSuggestions(t.text),
          onSelected: (o) =>
              _tracerRoute(double.parse(o['lat']), double.parse(o['lon'])),
          fieldViewBuilder: (ctx, ctrl, focus, onF) => TextField(
            controller: ctrl,
            focusNode: focus,
            style: const TextStyle(color: Colors.white),
            decoration: const InputDecoration(
              hintText: "Destination ?",
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
                _mapController.move(
                  maPosition,
                  _mapController.camera.zoom,
                ); // RECENTRAGE FIXÉ
              }
            },
          ),
        ],
      ),
      body: Column(
        children: [
          Container(
            height: 50,
            color: Colors.green,
            child: ListView(
              scrollDirection: Axis.horizontal,
              children:
                  ['Tous', 'Vue', 'Monument', 'Nature', 'Bivouac', 'Musée']
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
            color: Colors.white,
            child: Column(
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      modeTrajetActif ? "Écart max route" : "Radar (minutes)",
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
                      if (suivrePosition && !modeTrajetActif)
                        _mapController.move(maPosition, _calculerZoom(v));
                    });
                  },
                ),
                if (modeTrajetActif)
                  TextButton(
                    onPressed: () => setState(() {
                      modeTrajetActif = false;
                      traceItineraire = [];
                    }),
                    child: const Text(
                      "RETOUR MODE RADAR",
                      style: TextStyle(color: Colors.red),
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
                        color: Colors.blue.withOpacity(0.6),
                        strokeWidth: 6,
                      ),
                    ],
                  ),
                MarkerLayer(
                  markers: [
                    Marker(
                      point: maPosition,
                      child: const Icon(
                        Icons.navigation,
                        color: Colors.blue,
                        size: 30,
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
