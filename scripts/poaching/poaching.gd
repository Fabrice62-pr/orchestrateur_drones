extends Node3D
## Braconnage : des groupes de braconniers viennent couper illégalement des pins dans
## la forêt protégée ; gardes forestiers et police interviennent sur alerte des drones.
##
## Déclenchement : au hasard (toutes les interval_min à interval_max s), touche B, ou
## action « spawn_poachers » (scénario ou règles).
## Détection : par les drones de surveillance (drone_scan). Sous le couvert des pins, un
## groupe n'est pas repéré à coup sûr ; un drone en filature (état TRACK) le suit et
## transmet sa position, qui guide les véhicules d'intervention.
## Événements publiés : poachers_detected, poachers_report, poachers_fleeing,
## poacher_arrested, poacher_escaped, poaching_over.
## Commandes (actions des règles) : dispatch(service, count, target), recall(service).

const VanScript := preload("res://scripts/poaching/poacher_van.gd")
const PatrolScript := preload("res://scripts/poaching/patrol_vehicle.gd")
const PersonScript := preload("res://scripts/people/person.gd")
const FelledTree := preload("res://scripts/lumber/felled_tree.gd")
const RANGER_NAMES := ["Garde Benali", "Garde Morel", "Garde Koné", "Garde Simon"]
const POLICE_NAMES := ["Agent Diaz", "Agent Laurent", "Agent Mercier", "Agent Traoré"]
const MAX_REMAINS := 40         # houppiers abandonnés gardés à l'écran
const MAX_STUMPS := 400

var net: Node3D
var city: Node3D
var terrain: Node3D
var forest: Node3D
var rng := RandomNumberGenerator.new()
var vans: Array = []            # groupes (en cours ou terminés)
var closed := {}                # camionnette -> vrai quand le groupe est terminé
var units: Array = []           # véhicules d'intervention (gardes, police)
var last_known := {}            # camionnette -> dernière position transmise par un drone
var remains: Array = []
var stump_mm: MultiMesh
var stump_n := 0
var spawn_t := 0.0
var next_group := 1

# réglages (data/config.json -> "poaching")
var enabled := true
var interval_min := 300.0
var interval_max := 600.0
var max_groups := 1
var group_size := 3
var trees_per_visit := 3
var notice_chance := 0.015      # par seconde, quand un drone tourne au-dessus d'eux
var hear_radius := 220.0        # m : ils entendent les sirènes
var accident_chance := 0.12     # par arbre abattu : départ de feu accidentel

# bilan
var groups_total := 0
var arrested := 0
var escaped := 0
var fires_caused := 0
var jailed := 0


func setup(network: Node3D, c: Node3D, t: Node3D, f: Node3D) -> void:
	net = network
	city = c
	terrain = t
	forest = f
	rng.seed = GameState.seed_value + 909
	enabled = bool(GameState.cfgv("poaching", "enabled", enabled))
	interval_min = float(GameState.cfgv("poaching", "interval_min", interval_min))
	interval_max = float(GameState.cfgv("poaching", "interval_max", interval_max))
	max_groups = int(GameState.cfgv("poaching", "max_groups", max_groups))
	group_size = clampi(int(GameState.cfgv("poaching", "poachers_per_group", group_size)), 2, 4)
	trees_per_visit = int(GameState.cfgv("poaching", "trees_per_visit", trees_per_visit))
	notice_chance = float(GameState.cfgv("poaching", "notice_chance", notice_chance))
	hear_radius = float(GameState.cfgv("poaching", "siren_hear_radius", hear_radius))
	accident_chance = float(GameState.cfgv("poaching", "fire_accident_chance", accident_chance))
	spawn_t = rng.randf_range(interval_min, interval_max)
	_build_stumps()
	_spawn_units()
	GameState.patrol_units = units


# ------------------------------------------------------------ moyens d'intervention

func _spawn_units() -> void:
	var n_rangers := int(GameState.cfgv("poaching", "ranger_vehicles", 2))
	var n_police := int(GameState.cfgv("poaching", "police_vehicles", 2))
	var station := get_parent().get_node_or_null("RangerStation")
	if station:
		for k in mini(n_rangers, station.parking.size()):
			var p: Vector3 = station.parking[k]
			var entry: int = net.nearest_node(Vector2(p.x, p.z), ["track"])
			_add_unit("garde", "GF-%d" % (k + 1), Vector2(p.x, p.z), [Vector2(p.x, net.nodes[entry].y)], entry, k)
	var lm := city.get_node_or_null("Landmarks")
	if lm and city.landmarks.has("police"):
		var key: Vector2i = city.landmarks["police"]
		var street_z: float = city.road_zs[key.y + 1]
		for k in mini(n_police, lm.police_spots.size()):
			var p: Vector3 = lm.police_spots[k]
			var leg := Vector2(p.x, street_z)
			_add_unit("police", "POL-%d" % (k + 1), Vector2(p.x, p.z), [leg], net.nearest_node(leg, ["city"]), k)


func _add_unit(service: String, id: String, home: Vector2, leg: Array, entry: int, k: int) -> void:
	var u := PatrolScript.new()
	u.service = service
	u.drone_id = id
	u.name = id
	u.net = net
	u.manager = self
	u.home = home
	u.home_leg = leg
	u.entry_node = entry
	add_child(u)
	u.heading = u.home_heading
	u.place(home)
	u.state = "POSTE"
	var names: Array = RANGER_NAMES if service == "garde" else POLICE_NAMES
	for m in 2:
		var f := PersonScript.new()
		f.outfit = "garde" if service == "garde" else "policier"
		f.role = "agent"
		f.person_name = names[(k * 2 + m) % names.size()]
		f.run_speed = 3.9
		f.truck = u
		add_child(f)
		f.global_position = u.global_position
		f.board()
		u.crew.append(f)
	units.append(u)


func pursuers() -> Array:
	return units.filter(func(u): return u.state == "ROUTE" or u.state == "PIED")


## Positions des poursuivants (véhicules et agents à pied).
func pursuer_points() -> Array:
	var pts: Array = []
	for u in pursuers():
		pts.append(u.pos2())
		for f in u.crew:
			if not f.aboard:
				pts.append(Vector2(f.global_position.x, f.global_position.z))
	return pts


func siren_heard(p: Vector2) -> bool:
	for u in units:
		if u.siren and u.pos2().distance_to(p) < hear_radius:
			return true
	return false


## Un drone de surveillance tourne au-dessus du groupe (bruit des hélices).
func drone_overhead(van: Node3D) -> bool:
	for d in GameState.drones:
		if d.role != "surveillance" or d.is_grounded():
			continue
		for q in _visible_points(van) + [van.global_position]:
			if Vector2(d.global_position.x - q.x, d.global_position.z - q.z).length() < 60.0:
				return true
	return false


## Engage `count` véhicules du service sur le groupe signalé le plus proche de target.
func dispatch(service: String, count: int, target: Vector3) -> int:
	var van = _van_near(target)
	if van == null:
		EventBus.log_msg("Aucun groupe de braconniers à intercepter", "warn")
		return 0
	var cands := units.filter(func(u): return u.service == service and u.is_available())
	cands.sort_custom(func(a, b): return a.pos2().distance_to(Vector2(target.x, target.z)) < b.pos2().distance_to(Vector2(target.x, target.z)))
	var n := mini(count, cands.size())
	if n == 0:
		EventBus.log_msg("Aucun véhicule « %s » disponible" % service, "warn")
	for k in n:
		cands[k].cmd_dispatch(van)
		EventBus.log_msg("%s -> intervention braconnage (%s)" % [cands[k].drone_id, van.drone_id], "cmd")
	return n


func recall(service: String) -> void:
	for u in units:
		if service == "all" or u.service == service:
			u.cmd_recall()


func _van_near(target: Vector3):
	var best = null
	var bd := INF
	for v in active_vans():
		var d: float = v.pos2().distance_to(Vector2(target.x, target.z))
		if v.detected:
			d -= 10000.0   # priorité aux groupes signalés
		if d < bd:
			bd = d
			best = v
	return best


# ------------------------------------------------------------ groupes de braconniers

func active_vans() -> Array:
	return vans.filter(func(v): return not closed.has(v))


func van_by_group(g: int):
	for v in vans:
		if v.group == g:
			return v
	return null


## Nouveau groupe : entre par une piste depuis le bord de la carte, vers un coin de forêt
## dense, loin de la maison forestière. at : point visé (null = au hasard).
func spawn_group(at = null) -> bool:
	if active_vans().size() >= max_groups:
		EventBus.log_msg("Un groupe de braconniers est déjà dans la forêt", "warn")
		return false
	var work := _pick_work_node(at)
	if work < 0:
		EventBus.log_msg("Braconnage : aucun coin de forêt exploitable", "warn")
		return false
	var exits: Array = []
	for e in net.exit_nodes:
		exits.append([_path_len(net.path(e, work)), e])
	exits.sort_custom(func(a, b): return a[0] < b[0])
	var entry: int = exits[rng.randi() % mini(2, exits.size())][1]
	var v := VanScript.new()
	v.group = next_group
	v.drone_id = "BRAC-%d" % next_group
	v.name = v.drone_id
	v.manager = self
	v.net = net
	v.entry_exit = entry
	add_child(v)
	next_group += 1
	var ids: Array = net.path(entry, work)
	for id in ids:
		v.route.append([net.nodes[id], net.kinds[id]])
	var start: Vector2 = net.nodes[entry]
	var nxt: Vector2 = net.nodes[ids[1]] if ids.size() > 1 else start
	v.heading = (nxt - start).normalized()
	v.place(start)
	v.state = "ARRIVEE"
	for m in group_size:
		var p := PersonScript.new()
		p.outfit = "braconnier"
		p.role = "abatteur" if m == 0 else "débardeur"
		p.person_name = "Braconnier %d-%d" % [v.group, m + 1]
		p.run_speed = 3.5
		p.truck = v
		add_child(p)
		p.global_position = v.global_position
		p.board()
		v.crew.append(p)
	vans.append(v)
	groups_total += 1
	EventBus.log_msg("Braconnage : %d braconniers entrent dans la forêt protégée (non repérés)" % group_size)
	return true


func _path_len(ids: Array) -> float:
	var L := 0.0
	for k in range(1, ids.size()):
		L += (net.nodes[ids[k - 1]] as Vector2).distance_to(net.nodes[ids[k]])
	return L if not ids.is_empty() else INF


func _pick_work_node(at) -> int:
	var fr: Rect2 = terrain.forest_rect.grow(-12.0)
	var deep: float = terrain.SIZE * 0.5 - 120.0   # loin du bord de la carte : la fuite n'est pas immédiate
	var cands: Array = []
	for i in net.nodes.size():
		var p: Vector2 = net.nodes[i]
		if net.kinds[i] == "track" and fr.has_point(p) and p.distance_to(terrain.ranger_center) > 160.0 				and absf(p.x) < deep and absf(p.y) < deep:
			cands.append(i)
	if at != null:
		var a := Vector2(at.x, at.z)
		cands.sort_custom(func(x, y): return (net.nodes[x] as Vector2).distance_to(a) < (net.nodes[y] as Vector2).distance_to(a))
	else:
		cands.shuffle()
	var fire := _fire_points()
	for i in cands:
		var p: Vector2 = net.nodes[i]
		if _near_any(p, fire, 150.0):
			continue
		if forest.forest_trees_near(p, 10.0, 45.0).size() >= trees_per_visit:
			return i
	return -1


func _fire_points() -> Array:
	var pts: Array = []
	for idx in forest.burning.keys():
		var c: Vector3 = forest.cell_pos[idx]
		pts.append(Vector2(c.x, c.z))
	return pts


func _near_any(p: Vector2, pts: Array, r: float) -> bool:
	for q in pts:
		if p.distance_to(q) < r:
			return true
	return false


func _physics_process(dt: float) -> void:
	if dt <= 0.0:
		return
	if enabled:
		spawn_t -= dt
		if spawn_t <= 0.0:
			spawn_t = rng.randf_range(interval_min, interval_max)
			if active_vans().size() < max_groups:
				spawn_group()
	for v in active_vans():
		if v.is_over():
			_finish(v)


func _finish(v: Node3D) -> void:
	closed[v] = true
	var n_arr := 0
	var n_esc := 0
	for m in v.crew:
		if m.cuffed:
			n_arr += 1
		elif m.escaped:
			n_esc += 1
	if not v.detected:
		EventBus.log_msg("Braconnage : groupe reparti sans être repéré (%d grumes volées)" % v.load, "warn")
		return
	var tracker := ""
	for d in GameState.drones:
		if d.state == "TRACK" and d.track_group == v.group:
			tracker = d.drone_id
	EventBus.emit_event("poaching_over", {"group": v.group, "unit_id": v.drone_id, "drone_id": tracker,
		"tracking": tracker != "", "arrested": n_arr, "escaped": n_esc})


# ------------------------------------------------------------ détection par les drones

## Points visibles depuis le ciel : braconniers à pied, et la camionnette si elle roule ou
## transporte encore quelqu'un.
func _visible_points(v: Node3D) -> Array:
	var pts: Array = []
	if v.state == "PARTIE":
		return pts
	var inside := false
	for m in v.free_members():
		if m.aboard:
			inside = true
		elif m.visible:
			pts.append(m.global_position)
	if inside or v.moving:
		pts.append(v.global_position)
	return pts


## Appelée par chaque drone de surveillance (toutes les 0,5 s) avec la zone qu'il observe.
func drone_scan(drone: Node3D, eye: Vector3, r: float) -> void:
	for v in active_vans():
		var near: Array = _visible_points(v).filter(func(q): return Vector2(q.x - eye.x, q.z - eye.z).length() <= r)
		if near.is_empty():
			continue
		var c := Vector3.ZERO
		for q in near:
			c += q
		c /= near.size()
		var data := {"drone_id": drone.drone_id, "group": v.group, "unit_id": v.drone_id, "count": v.free_members().size(),
			"position": [snappedf(c.x, 0.1), snappedf(c.y, 0.1), snappedf(c.z, 0.1)]}
		if drone.state == "TRACK" and drone.track_group == v.group:
			last_known[v] = c
			if GameState.sim_time - v.last_report >= 10.0:
				v.last_report = GameState.sim_time
				data["mode"] = {"vehicule": "en fuite en camionnette", "pied": "en fuite à pied"}.get(v.fleeing, "sur place")
				EventBus.emit_event("poachers_report", data)
			continue
		if v.detected:
			continue
		# sous le couvert des pins, on ne les voit pas à coup sûr (mieux s'ils bougent ou tronçonnent)
		var busy: bool = v.moving or v.fleeing != "" or (not v.crew.is_empty() and v.crew[0].state == "SAW")
		if rng.randf() > (0.55 if busy else 0.3):
			continue
		v.detected = true
		v.detected_by = drone.drone_id
		v.last_report = GameState.sim_time
		last_known[v] = c
		EventBus.emit_event("poachers_detected", data)


## Point que suit le drone en filature : le braconnier libre (ou la camionnette) le plus proche.
func track_point(group: int, from: Vector3):
	var v = van_by_group(group)
	if v == null or closed.has(v):
		return null
	var pts := _visible_points(v)
	if pts.is_empty():
		return last_known.get(v, null)
	var best: Vector3 = pts[0]
	for q in pts:
		if Vector2(q.x - from.x, q.z - from.z).length() < Vector2(best.x - from.x, best.z - from.z).length():
			best = q
	return best


func known_position(v: Node3D):
	return last_known.get(v, null)


# ------------------------------------------------------------ comptes rendus

func on_tree_poached(v: Node3D, t: int) -> void:
	if stump_n < MAX_STUMPS:
		var b: Vector3 = forest.tree_base[t]
		var s: float = forest.tree_scale(t)
		stump_mm.set_instance_transform(stump_n, Transform3D(Basis.from_scale(Vector3(s, 1.0, s)), b + Vector3(0, 0.2, 0)))
		stump_n += 1
		stump_mm.visible_instance_count = stump_n


func on_flee(v: Node3D, reason: String) -> void:
	var mode := "en camionnette" if v.fleeing == "vehicule" else "à pied"
	EventBus.log_msg("%s : les braconniers prennent la fuite %s (%s)" % [v.drone_id, mode, reason], "warn")
	EventBus.emit_event("poachers_fleeing", {"group": v.group, "unit_id": v.drone_id, "mode": mode, "reason": reason})


func on_abandon(v: Node3D, reason: String) -> void:
	EventBus.log_msg("%s : camionnette abandonnée (%s), fuite à pied à travers la forêt" % [v.drone_id, reason], "warn")
	EventBus.emit_event("poachers_fleeing", {"group": v.group, "unit_id": v.drone_id, "mode": "à pied", "reason": reason})


func on_units_on_site(u: Node3D) -> void:
	EventBus.log_msg("%s sur place : les agents poursuivent les braconniers à pied" % u.drone_id)


func on_arrest(u: Node3D, officer: Node3D, m: Node3D) -> void:
	arrested += 1
	EventBus.log_msg("%s : %s interpellé par %s" % [u.drone_id, m.person_name, officer.person_name], "warn")
	EventBus.emit_event("poacher_arrested", {"unit_id": u.drone_id, "group": m.truck.group,
		"position": [snappedf(m.global_position.x, 0.1), snappedf(m.global_position.y, 0.1), snappedf(m.global_position.z, 0.1)]})


func on_escaped(v: Node3D, m: Node3D) -> void:
	escaped += 1
	if v.detected:
		EventBus.log_msg("%s : %s a quitté la zone, il s'est échappé" % [v.drone_id, m.person_name], "warn")
		EventBus.emit_event("poacher_escaped", {"group": v.group, "unit_id": v.drone_id})


func on_prisoners_delivered(u: Node3D, n: int) -> void:
	jailed += n
	EventBus.log_msg("%s : %d braconnier(s) placé(s) en garde à vue" % [u.drone_id, n])


func roll_accident() -> bool:
	return rng.randf() < accident_chance


## Mégot ou pot d'échappement de tronçonneuse : départ de feu à côté du chantier illégal.
func accident_fire(v: Node3D, pos: Vector3) -> void:
	fires_caused += 1
	EventBus.log_msg("%s : départ de feu accidentel provoqué par les braconniers (mégot, tronçonneuse)" % v.drone_id, "warn")
	forest.ignite_at(pos)
	v.flee("incendie qu'ils ont provoqué")


## Houppiers abandonnés sur place (preuves de la coupe), les plus anciens disparaissent.
func add_remains(n: Node3D) -> void:
	add_child(n)
	remains.append(n)
	while remains.size() > MAX_REMAINS:
		remains.pop_front().queue_free()


func _build_stumps() -> void:
	var cm := CylinderMesh.new()
	cm.top_radius = 0.24
	cm.bottom_radius = 0.3
	cm.height = 0.42
	cm.radial_segments = 10
	cm.rings = 1
	stump_mm = MultiMesh.new()
	stump_mm.transform_format = MultiMesh.TRANSFORM_3D
	stump_mm.mesh = cm
	stump_mm.instance_count = MAX_STUMPS
	stump_mm.visible_instance_count = 0
	var mi := MultiMeshInstance3D.new()
	mi.name = "PoachedStumps"
	mi.multimesh = stump_mm
	mi.material_override = FelledTree.bark_material()
	mi.extra_cull_margin = 2000.0
	add_child(mi)
