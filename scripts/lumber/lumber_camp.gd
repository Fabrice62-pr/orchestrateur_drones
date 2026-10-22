extends Node3D
## Exploitation du bois : scierie et marché du bois au sud de la ville, grumiers et bûcherons.
##
## - Les bûcherons n'abattent QUE les arbres de prairie autour de la ville. Le massif
##   forestier est une zone protégée : ses arbres ne sont jamais proposés (forest.is_protected),
##   un arbre trop proche de la lisière (il tomberait dans la forêt) est exclu, et aucun
##   itinéraire ne traverse la forêt (piste de ceinture à l'ouest, au sud et au nord de la ville).
## - Chaque arbre abattu laisse une souche ; un jeune plant est replanté à côté et repousse
##   en regrow_time s avant de pouvoir être coupé de nouveau.
## - À la scierie, les grumes déchargées sont sciées en planches, vendues au marché du bois.
## - Un incendie à moins de fire_flee_radius m d'un chantier : l'équipe évacue.

const TruckScript := preload("res://scripts/lumber/log_truck.gd")
const PersonScript := preload("res://scripts/people/person.gd")
const Look := preload("res://scripts/render/look.gd")

const YARD_TOP := 0.12          # dessus de la dalle de la cour
const RING_MARGIN := 15.0       # piste de ceinture à 15 m des dernières rues
const APPROACH := 10.0          # le grumier s'arrête à 10 m du pied de l'arbre
const FOREST_KEEP := 16.0       # un arbre à moins de 16 m de la forêt tomberait dedans : interdit
const SAPLING := 0.08           # taille d'un jeune plant (1 m environ)
const PLANKS_PER_LOG := 12
const PLANKS_PER_BUNDLE := 12
const CREW_NAMES := ["Marc Dubois", "Karim Haddad", "Julien Roche", "Samir Ouali", "Hugo Lambert", "Yanis Ferhat"]

var city: Node3D
var terrain: Node3D
var forest: Node3D
var city_life: Node3D = null
var rng := RandomNumberGenerator.new()
var lot := Rect2()              # cour de la scierie
var block := Rect2()            # îlot complet (trottoirs compris)
var street_far := 0.0           # bord sud de la rue qui longe la scierie
var bays: Array = []            # places des grumiers (face à l'est)
var ring: Array = []            # piste de ceinture (Vector2) : sud-est -> sud-ouest -> nord-ouest -> nord-est
var ring_s: Array = []          # abscisse curviligne de chaque sommet
var trucks: Array = []
var lumberjacks: Array = []
var access := {}                # arbre -> [abscisse sur la ceinture, point d'arrêt du grumier]
var reserved := {}              # arbre -> grumier
var growing := {}               # arbre replanté -> croissance (0..1)
var stump_slot := {}            # arbre -> instance de souche
var fire_blocked := false       # aucun arbre accessible hors de portée d'un incendie
var tick_acc := 0.0

# réglages (data/config.json -> "lumber")
var regrow_time := 240.0
var flee_radius := 150.0
var max_distance := 400.0
var saw_time := 8.0
var sell_interval := 14.0
var plank_price := 9

# stocks et bilan
var log_stock := 6
var planks := 24
var trees_cut := 0
var trees_planted := 0
var logs_delivered := 0
var planks_made := 0
var planks_sold := 0
var revenue := 0
var bench_busy := false
var saw_t := 0.0
var sell_t := 6.0

# visuels
var bark_mat: Material
var log_mm: MultiMesh
var log_slots: Array = []
var plank_mm: MultiMesh
var plank_slots: Array = []
var stump_mm: MultiMesh
var blade: MeshInstance3D
var bench_log: MeshInstance3D
var saw_dust: CPUParticles3D


@warning_ignore("integer_division")
func setup(c: Node3D, t: Node3D, f: Node3D, life: Node3D) -> void:
	city = c
	terrain = t
	forest = f
	city_life = life
	rng.seed = GameState.seed_value + 707
	regrow_time = float(GameState.cfgv("lumber", "regrow_time", regrow_time))
	flee_radius = float(GameState.cfgv("lumber", "fire_flee_radius", flee_radius))
	max_distance = float(GameState.cfgv("lumber", "max_distance_from_city", max_distance))
	saw_time = float(GameState.cfgv("lumber", "saw_time", saw_time))
	sell_interval = float(GameState.cfgv("lumber", "sell_interval", sell_interval))
	plank_price = int(GameState.cfgv("lumber", "plank_price", plank_price))
	bark_mat = Look.pbr("bark", 1.2, Color(0.75, 0.65, 0.55))
	var key: Vector2i = city.landmarks.get("sawmill", Vector2i(city.cols / 2 - 1, city.rows - 1))
	lot = city.lot_rect(key)
	block = city.block_rect(key)
	street_far = city.road_zs[city.rows] + city.road * 0.5
	bays = [_l(14.0, 14.0), _l(14.0, 19.5)]
	_plan_ring()
	_index_trees()
	_build_sawmill()
	_build_stumps()
	_spawn_trucks()
	EventBus.log_msg("Scierie : %d arbres de prairie exploitables (forêt protégée exclue)" % access.size())


## Point de la cour (repère local : x vers l'est, z vers le sud, origine au coin nord-ouest).
func _l(x: float, z: float) -> Vector2:
	return lot.position + Vector2(x, z)


func _w(x: float, y: float, z: float) -> Vector3:
	return Vector3(lot.position.x + x, y, lot.position.y + z)


## Altitude du sol pour les véhicules et les piétons (cour, trottoir, rue, campagne).
func ground_y(x: float, z: float) -> float:
	var p := Vector2(x, z)
	if lot.has_point(p):
		return YARD_TOP
	if block.has_point(p):
		return 0.25
	return terrain.height_at(x, z)


func distance_to_city(t: int) -> float:
	var b: Vector3 = forest.tree_base[t]
	var r: Rect2 = terrain.city_rect
	var dx := maxf(maxf(r.position.x - b.x, b.x - r.end.x), 0.0)
	var dz := maxf(maxf(r.position.y - b.z, b.z - r.end.y), 0.0)
	return sqrt(dx * dx + dz * dz)


# ------------------------------------------------------------ piste de ceinture

## La ceinture contourne la ville par l'ouest : pas de côté est, qui longerait la base et la forêt.
func _plan_ring() -> void:
	var r: Rect2 = terrain.city_rect.grow(RING_MARGIN)
	ring = [Vector2(r.end.x, r.end.y), Vector2(r.position.x, r.end.y), Vector2(r.position.x, r.position.y), Vector2(r.end.x, r.position.y)]
	ring_s = [0.0]
	for k in range(1, ring.size()):
		ring_s.append(ring_s[k - 1] + (ring[k - 1] as Vector2).distance_to(ring[k]))


func ring_point(s: float) -> Vector2:
	s = clampf(s, 0.0, ring_s[ring_s.size() - 1])
	for k in range(ring.size() - 1):
		if s <= ring_s[k + 1]:
			var seg: float = ring_s[k + 1] - ring_s[k]
			return (ring[k] as Vector2).lerp(ring[k + 1], (s - ring_s[k]) / maxf(seg, 0.001))
	return ring[ring.size() - 1]


func ring_project(p: Vector2) -> float:
	var best := INF
	var bs := 0.0
	for k in range(ring.size() - 1):
		var q := Geometry2D.get_closest_point_to_segment(p, ring[k], ring[k + 1])
		if p.distance_to(q) < best:
			best = p.distance_to(q)
			bs = ring_s[k] + (ring[k] as Vector2).distance_to(q)
	return bs


## Points de passage le long de la ceinture, de l'abscisse s0 à s1 (sommets compris).
func _ring_walk(s0: float, s1: float) -> Array:
	var out: Array = []
	if s1 >= s0:
		for k in ring.size():
			if ring_s[k] > s0 and ring_s[k] < s1:
				out.append([ring[k], "ring"])
	else:
		for k in range(ring.size() - 1, -1, -1):
			if ring_s[k] < s0 and ring_s[k] > s1:
				out.append([ring[k], "ring"])
	out.append([ring_point(s1), "ring"])
	return out


## Trajet en ligne droite praticable : ni forêt, ni ville, ni base des drones, ni bord de carte.
func _clear(a: Vector2, b: Vector2) -> bool:
	var n := maxi(1, int(a.distance_to(b) / 3.0))
	var fr: Rect2 = terrain.forest_rect.grow(5.0)
	var cr: Rect2 = terrain.city_rect.grow(4.0)
	var half: float = terrain.SIZE * 0.5 - 4.0
	for k in n + 1:
		var q := a.lerp(b, float(k) / n)
		if fr.has_point(q) or cr.has_point(q) or absf(q.x) > half or absf(q.y) > half:
			return false
		if q.distance_to(terrain.base_pos2) < terrain.base_radius + 30.0:
			return false
	return true


## Arbres que les bûcherons ont le droit d'abattre, avec leur point d'accès.
func _index_trees() -> void:
	for t in forest.meadow_trees():
		_compute_access(t)


func _compute_access(t: int) -> void:
	access.erase(t)
	if forest.is_protected(t):
		return
	var b: Vector3 = forest.tree_base[t]
	var p := Vector2(b.x, b.z)
	if terrain.forest_rect.grow(FOREST_KEEP).has_point(p) or distance_to_city(t) > max_distance:
		return
	var s := ring_project(p)
	var rp := ring_point(s)
	var a := rp if p.distance_to(rp) < APPROACH + 2.0 else p + (rp - p).normalized() * APPROACH
	if not _clear(rp, a):
		return
	access[t] = [s, a]


## Sortie de la cour (portail est), jusqu'à la ceinture.
func _exit_route(from: Vector2) -> Array:
	var ex := lot.position.x + 25.0
	var r: Array = []
	if from.y > lot.position.y + 12.0 and from.x < lot.position.x + 22.0:
		r.append([Vector2(lot.position.x + 23.5, from.y), "yard"])
	r.append([Vector2(ex, lot.end.y - 1.0), "yard"])
	r.append([Vector2(ex, block.end.y), "yard"])
	r.append([Vector2(ex, street_far + 1.5), "street"])
	r.append([Vector2(ex, ring[0].y), "field"])
	return r


func in_yard(p: Vector2) -> bool:
	return block.grow(1.0).has_point(p)


## Itinéraire vers l'arbre t : depuis la scierie, ou depuis le chantier précédent.
func route_to_tree(from: Vector2, t: int) -> Array:
	var s_t: float = access[t][0]
	var a: Vector2 = access[t][1]
	var r: Array = []
	if in_yard(from):
		r = _exit_route(from)
		r.append_array(_ring_walk(ring_project(r[r.size() - 1][0]), s_t))
	elif _clear(from, a):
		return [[a, "field"]]
	else:
		var s0 := ring_project(from)
		r.append([ring_point(s0), "field"])
		r.append_array(_ring_walk(s0, s_t))
	r.append([a, "field"])
	return r


## Retour à la scierie par la ceinture et le portail ouest, jusqu'à une place libre.
func route_home(from: Vector2) -> Array:
	var nx := lot.position.x + 4.0
	var s0 := ring_project(from)
	var r: Array = [[ring_point(s0), "field"]]
	r.append_array(_ring_walk(s0, ring_project(Vector2(nx, ring[0].y))))
	r.append([Vector2(nx, street_far + 1.5), "field"])
	r.append([Vector2(nx, block.end.y), "street"])
	r.append([Vector2(nx, lot.end.y - 1.0), "yard"])
	var bay := _free_bay()
	r.append([Vector2(nx, bay.y), "yard"])
	r.append([bay, "yard"])
	return r


func _free_bay() -> Vector2:
	for b in bays:
		var taken := false
		for t in trucks:
			if t.state != "ROUTE" and t.state != "RETOUR" and t.state != "DEPART" and t.state != "CHANTIER" \
					and t.state != "EVACUATION" and Vector2(t.global_position.x, t.global_position.z).distance_to(b) < 3.0:
				taken = true
		for t in trucks:   # place déjà promise à un grumier en chemin
			if t.state == "RETOUR" and not t.route.is_empty() and (t.route[t.route.size() - 1][0] as Vector2).distance_to(b) < 0.5:
				taken = true
		if not taken:
			return b
	return bays[0]


## Traversée de la rue : aucune voiture à moins de 10 m (4,5 m après 8 s d'attente).
func street_clear(from: Vector2, to: Vector2, waited: float) -> bool:
	if city_life == null:
		return true
	var margin := 10.0 if waited < 8.0 else 4.5
	for c in city_life.cars:
		if c.pos.distance_to(Geometry2D.get_closest_point_to_segment(c.pos, from, to)) < margin:
			return false
	return true


# ------------------------------------------------------------ choix des arbres

func _fire_points() -> Array:
	if forest.burning_count() == 0:
		return []
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


func fire_near(p: Vector2, r: float) -> bool:
	return _near_any(p, _fire_points(), r)


## Arbre adulte, libre et loin de tout incendie, parmi les plus proches (un peu de hasard
## pour ne pas raser un seul secteur). -1 si aucun.
func pick_tree(from: Vector2, max_cost := INF) -> int:
	var fire := _fire_points()
	var scored: Array = []
	var blocked := 0
	var yard := in_yard(from)
	var s_exit := ring_project(Vector2(lot.position.x + 25.0, ring[0].y))
	for t in access:
		if reserved.has(t) or growing.has(t) or forest.tree_growth[t] < 1.0:
			continue
		var a: Vector2 = access[t][1]
		if not fire.is_empty() and _near_any(a, fire, flee_radius * 1.3):
			blocked += 1
			continue
		var cost := 0.0
		if yard:
			cost = absf(access[t][0] - s_exit) + ring_point(access[t][0]).distance_to(a)
		elif _clear(from, a):
			cost = from.distance_to(a)
		else:
			var s0 := ring_project(from)
			cost = from.distance_to(ring_point(s0)) + absf(access[t][0] - s0) + ring_point(access[t][0]).distance_to(a)
		if cost <= max_cost:
			scored.append([cost, t])
	fire_blocked = scored.is_empty() and blocked > 0
	if scored.is_empty():
		return -1
	scored.sort_custom(func(x, y): return x[0] < y[0])
	return scored[rng.randi() % mini(5, scored.size())][1]


func reserve(t: int, truck: Node3D) -> void:
	reserved[t] = truck


func release(t: int) -> void:
	reserved.erase(t)


# ------------------------------------------------------------ abattage et repousse

func on_felled(t: int) -> void:
	if forest.is_protected(t):
		return
	var b: Vector3 = forest.tree_base[t]
	var s: float = forest.tree_scale(t)
	forest.set_tree_growth(t, 0.0)
	if stump_slot.has(t):
		stump_mm.set_instance_transform(stump_slot[t], Transform3D(Basis.from_scale(Vector3(s, 1.0, s)), b + Vector3(0, 0.2, 0)))
	trees_cut += 1


## Emplacement du jeune plant : à 2 m de la souche, toujours hors de la forêt et de la ville.
func plant_spot(t: int) -> Vector3:
	var b: Vector3 = forest.tree_base[t]
	var p := Vector2(b.x, b.z)
	for k in 8:
		var q := p + Vector2.from_angle(rng.randf() * TAU) * 2.2
		if not terrain.forest_rect.grow(FOREST_KEEP).has_point(q) and terrain.city_mask(q.x, q.y) <= 0.0:
			return Vector3(q.x, terrain.height_at(q.x, q.y), q.y)
	return b


func replant(t: int, spot: Vector3) -> void:
	if forest.is_protected(t):
		return
	forest.move_tree(t, spot)
	forest.set_tree_growth(t, SAPLING)
	growing[t] = SAPLING
	trees_planted += 1
	_compute_access(t)


func _tick_growth(dt: float) -> void:
	for t in growing.keys():
		var g: float = minf(1.0, growing[t] + dt / maxf(regrow_time, 1.0))
		forest.set_tree_growth(t, g)
		if g >= 1.0:
			growing.erase(t)
		else:
			growing[t] = g


## Incendie à portée d'un chantier (ou de l'arbre visé) : l'équipe évacue.
func _check_fire() -> void:
	var fire := _fire_points()
	if fire.is_empty():
		return
	var town: Rect2 = terrain.city_rect.grow(14.0)
	for t in trucks:
		if t.state != "CHANTIER" and t.state != "ROUTE":
			continue
		var p := Vector2(t.global_position.x, t.global_position.z)
		if town.has_point(p):
			continue
		var danger := _near_any(p, fire, flee_radius)
		if not danger and t.target >= 0 and access.has(t.target):
			danger = _near_any(access[t.target][1], fire, flee_radius)
		if danger:
			t.cmd_evacuate()


# ------------------------------------------------------------ scierie et marché

func deliver_log() -> void:
	log_stock += 1
	logs_delivered += 1
	_refresh_stacks()


## Point de dépôt au pied du parc à grumes.
func pile_point(id: int) -> Vector3:
	var p := _l(22.5 + float(id % 7), 11.3)
	return Vector3(p.x, 0.0, p.y)


## Place des bûcherons au repos, devant le hangar.
func idle_point(truck: Node3D, k: int) -> Vector3:
	var p := _l(2.0 + trucks.find(truck) * 3.0 + k * 1.2, 11.2)
	return Vector3(p.x, 0.0, p.y)


func _physics_process(dt: float) -> void:
	if dt <= 0.0:
		return
	tick_acc += dt
	if tick_acc >= 1.0:
		_tick_growth(tick_acc)
		_check_fire()
		tick_acc = 0.0
	_run_sawmill(dt)


## Sciage des grumes en planches, puis vente au marché du bois.
func _run_sawmill(dt: float) -> void:
	if bench_busy:
		saw_t -= dt
		blade.rotate_object_local(Vector3.UP, dt * 40.0)
		var u := 1.0 - clampf(saw_t / saw_time, 0.0, 1.0)
		bench_log.position = _w(lerpf(11.0, 18.0, u), 1.27, 5.0)
		if saw_t <= 0.0:
			bench_busy = false
			bench_log.visible = false
			saw_dust.emitting = false
			planks += PLANKS_PER_LOG
			planks_made += PLANKS_PER_LOG
			_refresh_stacks()
	elif log_stock > 0:
		log_stock -= 1
		bench_busy = true
		saw_t = saw_time
		bench_log.visible = true
		saw_dust.emitting = true
		_refresh_stacks()
	sell_t -= dt
	if sell_t <= 0.0:
		sell_t = sell_interval * rng.randf_range(0.6, 1.4)
		if planks > 0:
			var n := mini(planks, rng.randi_range(4, 12))
			planks -= n
			planks_sold += n
			revenue += n * plank_price
			_refresh_stacks()


@warning_ignore("integer_division")
func _refresh_stacks() -> void:
	log_mm.visible_instance_count = mini(log_stock, log_slots.size())
	plank_mm.visible_instance_count = mini((planks + PLANKS_PER_BUNDLE - 1) / PLANKS_PER_BUNDLE, plank_slots.size())


# ------------------------------------------------------------ grumiers et équipes

func _spawn_trucks() -> void:
	var n := clampi(int(GameState.cfgv("lumber", "trucks", 2)), 0, bays.size())
	var per_tree := maxi(2, int(GameState.cfgv("lumber", "logs_per_tree", 4)))
	var per_trip := maxi(1, int(GameState.cfgv("lumber", "trees_per_trip", 2)))
	for k in n:
		var t := TruckScript.new()
		t.drone_id = "BUCH-%d" % (k + 1)
		t.name = t.drone_id
		t.camp = self
		t.bay = bays[k]
		t.logs_per_tree = per_tree
		t.capacity = mini(per_tree * per_trip, TruckScript.BED_SLOTS.size())
		t.rest_t = 5.0 + k * 35.0   # départs décalés
		add_child(t)
		t.heading = Vector2(1, 0)
		t._place(bays[k])
		trucks.append(t)
		for m in 2:
			var j := PersonScript.new()
			var idx := lumberjacks.size()
			j.person_name = CREW_NAMES[idx % CREW_NAMES.size()]
			j.role = "abatteur" if m == 0 else "débardeur"
			j.truck = t
			j.name = "Bucheron%d" % (idx + 1)
			add_child(j)
			j.global_position = idle_point(t, m) + Vector3(0, YARD_TOP, 0)
			j.goal = j.global_position
			t.crew.append(j)
			lumberjacks.append(j)
	GameState.lumber_trucks = trucks


# ------------------------------------------------------------ visuel

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
	stump_mm.instance_count = maxi(1, access.size())
	var hidden := Transform3D(Basis.from_scale(Vector3.ONE * 0.001), Vector3(0, -50.0, 0))
	for k in stump_mm.instance_count:
		stump_mm.set_instance_transform(k, hidden)
	var k := 0
	for t in access:
		stump_slot[t] = k
		k += 1
	var mi := MultiMeshInstance3D.new()
	mi.name = "Stumps"
	mi.multimesh = stump_mm
	mi.material_override = bark_mat
	mi.extra_cull_margin = 2000.0   # souches dispersées autour de toute la ville
	add_child(mi)


func _build_sawmill() -> void:
	var W := lot.size.x
	var H := lot.size.y
	var wood := Look.plastic(Color(0.42, 0.28, 0.16), 0.85)
	var light_wood := Look.plastic(Color(0.66, 0.48, 0.3), 0.8)
	var roof := Look.metal(Color(0.42, 0.44, 0.46), 0.45)
	var steel := Look.metal(Color(0.55, 0.56, 0.58), 0.35)
	var yellow := Look.paint(Color(0.85, 0.65, 0.08), 0.35, 0.1)
	var tile := Look.plastic(Color(0.45, 0.13, 0.08), 0.6)
	var cream := Color(0.97, 0.92, 0.8)
	# dalle de la cour
	_box(Vector3(W, 0.24, H), _w(W * 0.5, 0.0, H * 0.5), Look.pbr("concrete", 4.0, Color(0.74, 0.7, 0.62)))
	# hangar de sciage (ouvert au sud), bardage bois et toit en tôle
	_box(Vector3(20.0, 6.2, 0.3), _w(10.0, 3.1, 0.15), wood)
	for x in [0.15, 19.85]:
		_box(Vector3(0.3, 6.2, 10.0), _w(x, 3.1, 5.0), wood)
	for x in [0.2, 6.8, 13.3, 19.8]:
		_box(Vector3(0.35, 6.2, 0.35), _w(x, 3.1, 9.8), wood)
	_box(Vector3(20.0, 0.4, 0.3), _w(10.0, 6.0, 9.8), wood)
	_box(Vector3(21.0, 0.25, 11.2), _w(10.0, 6.45, 5.0), roof, Vector3(-0.05, 0, 0))
	_text("SCIERIE", _w(10.0, 5.1, 10.02), 0.0, 96, cream)
	terrain.add_obstacle_box(_l(10.0, 5.0), Vector2(21.0, 11.2), 7.0)
	# banc de sciage : scie circulaire, carter, grume qui avance pendant la coupe
	_box(Vector3(9.0, 0.9, 1.3), _w(14.5, 0.57, 5.0), steel)
	_box(Vector3(1.8, 0.5, 0.3), _w(14.5, 1.95, 5.0), yellow)
	var bm := CylinderMesh.new()
	bm.top_radius = 0.75
	bm.bottom_radius = 0.75
	bm.height = 0.05
	bm.radial_segments = 24
	blade = _part(bm, _w(14.5, 1.15, 5.0), Look.metal(Color(0.8, 0.81, 0.83), 0.2), Vector3(PI * 0.5, 0, 0))
	for k in 6:   # dents (pour voir la lame tourner)
		var tooth := MeshInstance3D.new()
		var tm := BoxMesh.new()
		tm.size = Vector3(0.1, 0.07, 0.1)
		tooth.mesh = tm
		tooth.material_override = Look.metal(Color(0.3, 0.3, 0.32), 0.3)
		tooth.position = Vector3(cos(k * TAU / 6.0) * 0.72, 0, sin(k * TAU / 6.0) * 0.72)
		blade.add_child(tooth)
	var lm := CylinderMesh.new()
	lm.top_radius = 0.2
	lm.bottom_radius = 0.22
	lm.height = 2.6
	lm.radial_segments = 10
	bench_log = _part(lm, _w(11.0, 1.27, 5.0), bark_mat, Vector3(0, 0, PI * 0.5))
	bench_log.visible = false
	saw_dust = CPUParticles3D.new()
	saw_dust.amount = 80
	saw_dust.lifetime = 1.0
	saw_dust.emitting = false
	saw_dust.direction = Vector3(-1, 0.6, 0)
	saw_dust.spread = 30.0
	saw_dust.initial_velocity_min = 2.0
	saw_dust.initial_velocity_max = 4.0
	saw_dust.gravity = Vector3(0, -6.0, 0)
	var grain := BoxMesh.new()
	grain.size = Vector3(0.05, 0.05, 0.05)
	var gm := StandardMaterial3D.new()
	gm.albedo_color = Color(0.86, 0.74, 0.52)
	gm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	grain.material = gm
	saw_dust.mesh = grain
	saw_dust.position = _w(14.5, 1.3, 5.0)
	add_child(saw_dust)
	var mound := SphereMesh.new()   # tas de sciure au bout du banc
	mound.radius = 1.0
	mound.height = 2.0
	var mi := _part(mound, _w(18.4, YARD_TOP, 7.6), Look.plastic(Color(0.8, 0.66, 0.44), 0.95))
	mi.scale = Vector3(1.3, 0.35, 1.0)
	# planches en paquets, sous le hangar (5 colonnes x 2 rangées x 3 niveaux)
	for layer in 3:
		for row in 2:
			for col in 5:
				plank_slots.append(Transform3D(Basis.IDENTITY, _w(1.4 + col * 1.4, YARD_TOP + 0.21 + layer * 0.44, 2.8 + row * 4.0)))
	plank_mm = _stack("PlankBundles", plank_slots, Vector3(1.2, 0.42, 3.3), Look.plastic(Color(0.86, 0.72, 0.5), 0.8))
	# parc à grumes au nord-est (3 colonnes de grumes couchées, 2 niveaux)
	var lying := Basis(Vector3(0, 0, 1), PI * 0.5)
	for layer in 2:
		for col in 3:
			for row in 19:
				log_slots.append(Transform3D(lying, _w(22.9 + col * 2.8, YARD_TOP + 0.22 + layer * 0.4, 1.0 + row * 0.48 + layer * 0.24)))
	log_mm = _stack("LogPile", log_slots, Vector3.ZERO, bark_mat, lm)
	for x in [21.4, 29.9]:   # montants qui retiennent la pile
		for z in [0.6, 10.4]:
			_box(Vector3(0.15, 1.4, 0.15), _w(x, 0.7, z), wood)
	# marché du bois : boutique sur la rue, enseigne côté rue
	_box(Vector3(11.0, 4.2, 6.9), _w(14.5, YARD_TOP + 2.1, 26.95), light_wood)
	_box(Vector3(11.6, 0.3, 7.5), _w(14.5, YARD_TOP + 4.35, 26.95), tile)
	_box(Vector3(6.0, 1.4, 0.05), _w(13.0, 2.2, 30.42), Look.glass(Color(0.25, 0.3, 0.32)))
	_box(Vector3(1.4, 2.3, 0.05), _w(18.3, 1.27, 30.42), Look.plastic(Color(0.15, 0.08, 0.04), 0.6))
	_text("MARCHÉ DU BOIS", _w(14.5, 3.6, 30.48), 0.0, 64, cream)
	_text("BOIS · PLANCHES", _w(14.5, 3.0, 23.48), PI, 48, cream)
	terrain.add_obstacle_box(_l(14.5, 26.95), Vector2(11.6, 7.5), YARD_TOP + 4.6)
	# clôture (poteaux + lisses), portails ouest (entrée) et est (sortie) côté rue
	var fence := Look.metal(Color(0.32, 0.34, 0.33), 0.5)
	_fence(_l(20.0, 0.05), _l(W, 0.05), fence)
	_fence(_l(0.05, 10.0), _l(0.05, H), fence)
	_fence(_l(W - 0.05, 0.0), _l(W - 0.05, H), fence)
	for span in [[0.0, 1.5], [6.5, 9.0], [20.0, 22.5], [27.5, W]]:
		_fence(_l(span[0], H - 0.05), _l(span[1], H - 0.05), fence)
	_tag("SCIERIE · MARCHÉ DU BOIS", _w(W * 0.5, 15.0, H * 0.5), Color(0.95, 0.8, 0.45), 56)
	_refresh_stacks()


func _stack(node_name: String, slots: Array, size: Vector3, mat: Material, mesh: Mesh = null) -> MultiMesh:
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	if mesh == null:
		var b := BoxMesh.new()
		b.size = size
		mesh = b
	mm.mesh = mesh
	mm.instance_count = slots.size()
	for k in slots.size():
		mm.set_instance_transform(k, slots[k])
	var mi := MultiMeshInstance3D.new()
	mi.name = node_name
	mi.multimesh = mm
	mi.material_override = mat
	add_child(mi)
	return mm


func _fence(a: Vector2, b: Vector2, mat: Material) -> void:
	var length := a.distance_to(b)
	if length < 0.2:
		return
	var c := (a + b) * 0.5
	var yaw := atan2(-(b - a).y, (b - a).x)
	for y in [0.7, 1.6]:
		_box(Vector3(length, 0.07, 0.06), Vector3(c.x, YARD_TOP + y, c.y), mat, Vector3(0, yaw, 0))
	var n := maxi(1, int(length / 2.5))
	for k in n + 1:
		var p := a.lerp(b, float(k) / n)
		_box(Vector3(0.1, 1.9, 0.1), Vector3(p.x, YARD_TOP + 0.95, p.y), mat)


func _box(size: Vector3, pos: Vector3, mat: Material, rot := Vector3.ZERO) -> MeshInstance3D:
	var bm := BoxMesh.new()
	bm.size = size
	return _part(bm, pos, mat, rot)


func _part(mesh: Mesh, pos: Vector3, mat: Material, rot := Vector3.ZERO) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = mat
	mi.position = pos
	mi.rotation = rot
	add_child(mi)
	return mi


## Texte peint sur une façade (lisible depuis +z local, tourné de yaw).
func _text(txt: String, pos: Vector3, yaw: float, size: int, col: Color) -> void:
	var l := Label3D.new()
	l.text = txt
	l.font_size = size
	l.pixel_size = 0.02
	l.outline_size = 8
	l.outline_modulate = Color(0, 0, 0, 0.5)
	l.modulate = col
	l.position = pos
	l.rotation.y = yaw
	add_child(l)


func _tag(text: String, pos: Vector3, col: Color, size: int) -> void:
	var tag := Label3D.new()
	tag.text = text
	tag.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	tag.font_size = size
	tag.outline_size = 12
	tag.pixel_size = 0.03
	tag.modulate = col
	tag.position = pos
	add_child(tag)
