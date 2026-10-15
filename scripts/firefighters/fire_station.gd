extends Node3D
## Caserne de pompiers : bâtiment, cour, 2 fourgons pompe-tonne et 8 pompiers.
## Point d'entrée des ordres de l'orchestrateur pour les moyens terrestres :
##   dispatch(count, target, unit)  -> engage des camions sur un feu
##   recall(unit)                    -> rappel à la caserne
## Les camions choisissent un point de mise en batterie sur les pistes forestières
## au plus près du feu (deux camions ne se placent pas au même endroit).

const TruckScript := preload("res://scripts/firefighters/fire_truck.gd")
const FirefighterScript := preload("res://scripts/firefighters/firefighter.gd")
const APRON_TOP := 0.3
const Look := preload("res://scripts/render/look.gd")
const CREW_NAMES := ["Sgt Martin", "Cpl Diallo", "Sap. Leroy", "Sap. Nguyen",
	"Adj. Moreau", "Cpl Benali", "Sap. Petit", "Sap. Garcia"]
const ROLES := ["conducteur", "chef d'agrès", "équipier", "équipier"]

var net: Node3D
var city: Node3D
var city_life: Node3D = null
var rect := Rect2()
var trucks: Array = []
var firefighters: Array = []


func setup(network: Node3D, c: Node3D, terrain: Node3D) -> void:
	net = network
	city = c
	rect = city.station_rect
	_build_station(terrain)
	var n_trucks := int(GameState.cfgv("fire_service", "trucks", 2))
	var per_truck := int(GameState.cfgv("fire_service", "crew_per_truck", 4))
	var zones := _wander_zones()
	for k in mini(n_trucks, net.station_spots.size()):
		var t := TruckScript.new()
		t.drone_id = "FPT-%d" % (k + 1)
		t.name = t.drone_id
		t.net = net
		t.service = self
		t.home_node = net.station_spots[k]
		add_child(t)
		var spot: Vector2 = net.nodes[t.home_node]
		t.heading = Vector2(0, -1)
		t._place(spot)
		trucks.append(t)
		for m in per_truck:
			var f := FirefighterScript.new()
			var idx := firefighters.size()
			f.person_name = CREW_NAMES[idx % CREW_NAMES.size()]
			f.role = ROLES[m % ROLES.size()]
			f.truck = t
			f.wander_zones = zones
			f.name = "Pompier%d" % (idx + 1)
			add_child(f)
			var z: Rect2 = zones[idx % zones.size()]
			f.global_position = Vector3(z.get_center().x + (m - 1.5) * 0.9, APRON_TOP, z.get_center().y)
			f.goal = f.global_position
			t.crew.append(f)
			t.add_hose_for(f)
			firefighters.append(f)
	GameState.fire_trucks = trucks
	EventBus.log_msg.call_deferred("Caserne : %d fourgons pompe-tonne, %d pompiers" % [trucks.size(), firefighters.size()])


func on_station(p: Vector2) -> bool:
	return rect.grow(-0.5).has_point(p)


## Zones libres de la cour (entre et autour des camions) où l'équipage circule au repos.
func _wander_zones() -> Array:
	var y0 := rect.position.y + 3.0
	var y1 := rect.position.y + 16.0
	var cx := rect.get_center().x
	return [Rect2(rect.position.x + 3.0, y0, 5.0, y1 - y0),
		Rect2(cx - 4.0, y0, 8.0, y1 - y0),
		Rect2(rect.end.x - 8.0, y0, 5.0, y1 - y0)]


# ------------------------------------------------------------ ordres

func available_count() -> int:
	var n := 0
	for t in trucks:
		if t.is_available():
			n += 1
	return n


func engaged_count() -> int:
	var n := 0
	for t in trucks:
		if not t.at_station():
			n += 1
	return n


func get_truck(id: String):
	for t in trucks:
		if t.drone_id == id:
			return t
	return null


func dispatch(count: int, target: Vector3, unit: String = "") -> int:
	var chosen: Array = []
	if unit != "":
		var t = get_truck(unit)
		if t:
			chosen.append(t)
	else:
		var cands: Array = []
		for t in trucks:
			if t.is_available():
				cands.append(t)
		for k in mini(count, cands.size()):
			chosen.append(cands[k])
	if chosen.is_empty():
		EventBus.log_msg("Aucun fourgon disponible à la caserne", "warn")
		return 0
	for t in chosen:
		var stage := _stage_for(target, t)
		t.cmd_dispatch(target, stage)
		EventBus.log_msg("%s -> départ en intervention (équipage de %d)" % [t.drone_id, t.crew.size()], "cmd")
	return chosen.size()


func recall(unit: String = "all") -> void:
	for t in trucks:
		if unit == "all" or unit == t.drone_id:
			if not t.at_station():
				t.cmd_return()
				EventBus.log_msg("%s -> retour caserne" % t.drone_id, "cmd")


## Point de piste le plus proche du feu, à l'écart des points déjà pris par les autres camions.
func _stage_for(target: Vector3, truck: Node3D) -> int:
	# on vise le foyer réel le plus proche de la position signalée (le feu a pu bouger)
	var cell = GameState.fire.find_target(target, []) if GameState.fire else null
	if cell != null:
		target = cell
	var p := Vector2(target.x, target.z)
	var best := -1
	var bd := INF
	for i in net.nodes.size():
		if net.kinds[i] != "track":
			continue
		var q: Vector2 = net.nodes[i]
		var d := q.distance_to(p)
		for o in trucks:
			if o != truck and o.stage_node >= 0 and not o.at_station():
				if q.distance_to(net.nodes[o.stage_node]) < 25.0:
					d += 60.0
		if d < bd:
			bd = d
			best = i
	return best


# ------------------------------------------------------------ bâtiment

func _mat(c: Color, emission: float = 0.0) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.roughness = 0.8
	if emission > 0.0:
		m.emission_enabled = true
		m.emission = c
		m.emission_energy_multiplier = emission
	return m


func _box(sz: Vector3, pos: Vector3, mat: Material) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var b := BoxMesh.new()
	b.size = sz
	mi.mesh = b
	mi.material_override = mat
	mi.position = pos
	add_child(mi)
	return mi


func _build_station(terrain: Node3D) -> void:
	var cx := rect.get_center().x
	var x0 := rect.position.x
	var z0 := rect.position.y
	var w := rect.size.x
	# cour bétonnée (aire de manœuvre) avec marquage
	_box(Vector3(w - 4.4, APRON_TOP, 16.5), Vector3(cx, APRON_TOP * 0.5, z0 + 2.2 + 8.25), Look.pbr("concrete", 4.0, Color(0.85, 0.87, 0.9)))
	for k in 2:
		var px: float = net.nodes[net.station_spots[k]].x if net.station_spots.size() > k else cx
		_box(Vector3(3.6, 0.02, 9.5), Vector3(px, APRON_TOP + 0.01, z0 + 10.0), _mat(Color(0.95, 0.85, 0.2)))
		_box(Vector3(3.4, 0.03, 9.3), Vector3(px, APRON_TOP + 0.02, z0 + 10.0), Look.pbr("concrete", 4.0, Color(0.85, 0.87, 0.9)))
	# remise (garage) + bureaux, façade rouge et blanche
	var bz := z0 + 18.5
	var depth := rect.end.y - 2.5 - bz
	_box(Vector3(w - 5.0, 9.0, depth), Vector3(cx, 4.5, bz + depth * 0.5), Look.pbr("facade_a", 3.0, Color(1.0, 0.98, 0.95)))
	_box(Vector3(w - 4.8, 1.2, depth + 0.2), Vector3(cx, 8.4, bz + depth * 0.5), Look.paint(Color(0.48, 0.02, 0.015), 0.4, 0.1))
	terrain.add_obstacle_box(Vector2(cx, bz + depth * 0.5), Vector2(w - 5.0, depth), 9.0)
	# deux portes de remise ouvertes (vue sur l'intérieur sombre), encadrement rouge
	for k in 2:
		var px: float = net.nodes[net.station_spots[k]].x if net.station_spots.size() > k else cx
		_box(Vector3(5.2, 5.0, 0.3), Vector3(px, 2.5 + APRON_TOP, bz - 0.05), Look.plastic(Color(0.02, 0.02, 0.022), 0.9))
		_box(Vector3(6.0, 0.5, 0.4), Vector3(px, 5.25 + APRON_TOP, bz - 0.1), Look.paint(Color(0.48, 0.02, 0.015), 0.4, 0.1))
		# porte sectionnelle relevée (visible en haut de l'ouverture)
		_box(Vector3(5.1, 0.9, 0.12), Vector3(px, 4.6 + APRON_TOP, bz - 0.2), Look.paint(Color(0.45, 0.02, 0.015), 0.35, 0.3))
	# tour de séchage des tuyaux
	var tx := rect.end.x - 6.0
	var tz := rect.end.y - 7.0
	_box(Vector3(4.0, 20.0, 4.0), Vector3(tx, 10.0, tz), Look.pbr("facade_d", 2.4))
	_box(Vector3(4.4, 0.8, 4.4), Vector3(tx, 20.2, tz), Look.pbr("concrete", 2.0))
	terrain.add_obstacle_box(Vector2(tx, tz), Vector2(4.4, 4.4), 20.6)
	# mât et drapeau
	_box(Vector3(0.15, 10.0, 0.15), Vector3(x0 + 3.0, 5.0, z0 + 17.0), Look.metal(Color(0.8, 0.8, 0.82), 0.3))
	for k in 3:
		var fc: Color = [Color(0.1, 0.2, 0.6), Color(0.95, 0.95, 0.95), Color(0.8, 0.1, 0.1)][k]
		_box(Vector3(0.05, 1.0, 0.5), Vector3(x0 + 3.0, 9.4, z0 + 17.0 + 0.25 + k * 0.5), _mat(fc))
	# enseigne
	var sign := Label3D.new()
	sign.text = "SAPEURS-POMPIERS"
	sign.font_size = 96
	sign.outline_size = 10
	sign.pixel_size = 0.02
	sign.modulate = Color(1, 1, 1)
	sign.position = Vector3(cx, 7.0, bz - 0.25)
	sign.rotation_degrees.y = 180.0   # lisible depuis la rue (côté nord)
	add_child(sign)
	var tag := Label3D.new()
	tag.text = "CASERNE DE POMPIERS"
	tag.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	tag.font_size = 64
	tag.outline_size = 12
	tag.pixel_size = 0.03
	tag.modulate = Color(1.0, 0.6, 0.5)
	tag.position = Vector3(cx, 24.0, rect.get_center().y)
	add_child(tag)
