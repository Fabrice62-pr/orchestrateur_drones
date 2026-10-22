extends Node3D
const Look := preload("res://scripts/render/look.gd")
const FelledTree := preload("res://scripts/lumber/felled_tree.gd")
## Grumier : camion forestier à plateau et ranchers, avec 2 bûcherons
## (un abatteur à la tronçonneuse, un débardeur qui porte les grumes et replante).
##
## Cycle (les arbres et les itinéraires sont fournis par la scierie, lumber_camp.gd) :
##   SCIERIE -> DEPART (équipage à bord) -> ROUTE (piste de ceinture autour de la ville,
##   jamais dans la forêt protégée) -> CHANTIER (abattage, chute, ébranchage, tronçonnage,
##   chargement des grumes, replantation d'un jeune arbre) -> arbre suivant tant que le
##   plateau n'est pas plein -> RETOUR -> DECHARGEMENT (grumes portées au parc à grumes)
## Incendie à proximité : EVACUATION (l'équipe rembarque en courant et rentre à la scierie).

const ROAD_SPEED := 6.0
const RING_SPEED := 9.0
const FIELD_SPEED := 6.0
const YARD_SPEED := 3.0
const CUT_TIME := 5.0           # trait d'abattage
const FALL_TIME := 2.6
const LIMB_TIME := 4.0          # ébranchage
const BUCK_TIME := 2.2          # par trait de tronçonnage
const PLANT_TIME := 4.0
const REST_TIME := 12.0         # pause à la scierie entre deux coupes
const NEXT_TREE_RANGE := 180.0  # m : distance maxi pour enchaîner sur un 2e arbre pendant le trajet
# emplacements des grumes sur le plateau (repère local : avant = -Z), couche du bas d'abord
const BED_SLOTS := [Vector3(-0.68, 1.58, 0.35), Vector3(0.0, 1.58, 0.35), Vector3(0.68, 1.58, 0.35),
	Vector3(-0.68, 1.58, 3.05), Vector3(0.0, 1.58, 3.05), Vector3(0.68, 1.58, 3.05),
	Vector3(-0.34, 1.98, 0.35), Vector3(0.34, 1.98, 0.35), Vector3(-0.34, 1.98, 3.05), Vector3(0.34, 1.98, 3.05),
	Vector3(0.0, 2.36, 0.35), Vector3(0.0, 2.36, 3.05)]

var drone_id := "BUCH-1"        # identifiant (nom compatible caméra/interface)
var role := "log_truck"
var state := "SCIERIE"
var camp: Node3D
var crew: Array = []            # [abatteur, débardeur]
var bay := Vector2.ZERO         # place de stationnement à la scierie (face à l'est)
var route: Array = []           # [Vector2, type] : yard | street | ring | field
var heading := Vector2(1, 0)
var speed := 0.0
var velocity := Vector3.ZERO
var moving := false
var on_street := false          # en train de traverser la rue : les voitures s'arrêtent
var street_wait := 0.0
var rest_t := 0.0
var load := 0
var capacity := 8
var logs_per_tree := 4
var after_boarding := ""        # ROUTE | RETOUR
var target := -1                # arbre en cours
var trees_this_trip := 0
var cam_scale := 0.55
var fpv_hidden := false
var fpv_local := Vector3(0, 3.1, -2.6)

# chantier
var work := ""                  # APPROCHE, SCIAGE, CHUTE, EBRANCHAGE, TRONCONNAGE, REPLANTATION, RANGEMENT
var work_t := 0.0
var fall_dir := Vector2.RIGHT
var stump := Vector3.ZERO
var tree_s := 1.0
var felled: Node3D = null       # arbre qui tombe puis reste couché (felled_tree.gd)
var ground_logs: Array = []     # grumes coupées posées au sol (MeshInstance3D)
var next_cut := 0
var logs_loaded := 0
var carry_log: MeshInstance3D = null
var plant_spot := Vector3.ZERO
var unload_phase := {}          # bûcheron -> TO_TRUCK | TO_PILE

var body: Node3D
var label: Label3D
var bed_logs: Array[MeshInstance3D] = []
var dust: CPUParticles3D


func _ready() -> void:
	_build_visual()


func info() -> Dictionary:
	return {"unit_id": drone_id, "drone_id": drone_id, "role": role, "state": state, "logs": load, "capacity": capacity}


func at_sawmill() -> bool:
	return state == "SCIERIE" or state == "ATTENTE" or state == "DECHARGEMENT"


## Étiquettes des bûcherons : affichées hors de la scierie.
func crew_labels_visible() -> bool:
	return not at_sawmill()


func _say(msg: String, level := "info") -> void:
	EventBus.log_msg(msg, level)


func _pos2() -> Vector2:
	return Vector2(global_position.x, global_position.z)


## Place de chaque bûcheron à côté de la cabine (0 à gauche, 1 à droite).
func _door(k: int) -> Vector3:
	var side := Vector2(-heading.y, heading.x)
	var p := _pos2() + heading * 2.9 + side * (1.9 if k == 0 else -1.9)
	return Vector3(p.x, 0.0, p.y)


## Point de chargement, à l'arrière du plateau.
func _rear() -> Vector3:
	var side := Vector2(-heading.y, heading.x)
	var p := _pos2() - heading * 5.8 + side * 0.6
	return Vector3(p.x, 0.0, p.y)


# ------------------------------------------------------------ commandes

## Ordre de la scierie : incendie à proximité, on rentre tout de suite.
func cmd_evacuate() -> void:
	if not (state == "ROUTE" or state == "CHANTIER"):
		return
	if state == "CHANTIER":
		_abandon_worksite()
	_say("%s : incendie à proximité, évacuation de l'équipe vers la scierie" % drone_id, "warn")
	EventBus.emit_event("lumberjacks_evacuating", info())
	if state == "ROUTE":
		camp.release(target)
		target = -1
		route = camp.route_home(_pos2())
		state = "RETOUR"
		return
	_start_boarding("RETOUR", true)
	state = "EVACUATION"


func _start_boarding(next: String, running := false) -> void:
	after_boarding = next
	state = "DEPART"
	work = ""
	for k in crew.size():
		crew[k].set_carrying(false)
		crew[k].go_to(_door(k), running)


# ------------------------------------------------------------ simulation

func _physics_process(dt: float) -> void:
	if dt <= 0.0:
		return
	moving = false
	on_street = false
	match state:
		"SCIERIE", "ATTENTE":
			rest_t -= dt
			if rest_t <= 0.0:
				rest_t = 4.0
				_try_depart()
		"DEPART", "EVACUATION":
			_update_boarding()
		"ROUTE", "RETOUR":
			_drive(dt)
		"CHANTIER":
			_work(dt)
		"DECHARGEMENT":
			_unload()
	_animate()


func _try_depart() -> void:
	var t: int = camp.pick_tree(_pos2())
	if t < 0:
		state = "ATTENTE" if camp.fire_blocked else "SCIERIE"
		return
	target = t
	trees_this_trip = 0
	camp.reserve(t, self)
	_say("%s : départ en coupe (arbre de prairie à %d m de la ville)" % [drone_id, int(camp.distance_to_city(t))])
	_start_boarding("ROUTE")


func _update_boarding() -> void:
	for k in crew.size():
		var f = crew[k]
		if f.aboard:
			continue
		if f.arrived() or f.state == "IDLE":
			if Vector2(f.global_position.x, f.global_position.z).distance_to(_pos2()) < 4.5:
				f.board()
			else:
				f.go_to(_door(k), f.move_speed > 2.0)
	for f in crew:
		if not f.aboard:
			return
	if after_boarding == "ROUTE":
		route = camp.route_to_tree(_pos2(), target)
		state = "ROUTE"
	else:
		route = camp.route_home(_pos2())
		state = "RETOUR"


func _drive(dt: float) -> void:
	if route.is_empty():
		_on_arrival()
		return
	var here := _pos2()
	var wp: Vector2 = route[0][0]
	var kind: String = route[0][1]
	var to := wp - here
	var limit: float = {"yard": YARD_SPEED, "street": ROAD_SPEED, "ring": RING_SPEED}.get(kind, FIELD_SPEED)
	# ralentir avant un virage serré
	if route.size() > 1 and to.length() < 10.0:
		var nxt: Vector2 = route[1][0]
		var turn := to.normalized().dot((nxt - wp).normalized())
		limit = minf(limit, lerpf(2.0, limit, clampf((turn + 1.0) * 0.5, 0.0, 1.0)))
	if route.size() == 1:
		limit = minf(limit, maxf(1.5, to.length() * 0.6))
	# traversée de la rue : on attend au bord du trottoir qu'aucune voiture n'arrive
	if kind == "street":
		if street_wait >= 0.0 and not camp.street_clear(here, wp, street_wait):
			street_wait += dt
			limit = 0.0
		else:
			street_wait = -1.0   # engagé : on traverse
			on_street = true
	# grumier devant, dans le même sens
	for o in camp.trucks:
		if o != self and o.moving:
			var off := Vector2(o.global_position.x, o.global_position.z) - here
			if off.length() < 12.0 and off.normalized().dot(heading) > 0.75 and o.heading.dot(heading) > 0.3:
				limit = minf(limit, maxf(0.0, (off.length() - 10.0) * 1.5))
	speed = move_toward(speed, limit, dt * (6.0 if limit < speed else 2.5))
	var step := speed * dt
	if to.length() <= maxf(step, 0.4):
		here = wp
		route.pop_front()
		if kind == "street":
			street_wait = 0.0
	else:
		var d := to.normalized()
		heading = heading.lerp(d, clampf(dt * 3.5, 0.0, 1.0)).normalized()
		here += d * step
	moving = speed > 0.3
	_place(here)
	velocity = Vector3(heading.x, 0, heading.y) * speed


func _place(p: Vector2) -> void:
	global_position = Vector3(p.x, camp.ground_y(p.x, p.y), p.y)
	rotation.y = atan2(-heading.x, -heading.y)
	# inclinaison selon la pente (avant / arrière)
	var f := p + heading * 3.5
	var b := p - heading * 3.5
	var dh: float = GameState.terrain.height_at(f.x, f.y) - GameState.terrain.height_at(b.x, b.y)
	body.rotation.x = lerpf(body.rotation.x, atan2(dh, 7.0), 0.2)


func _on_arrival() -> void:
	speed = 0.0
	velocity = Vector3.ZERO
	if state == "RETOUR":
		heading = Vector2(1, 0)   # garé face à l'est, devant le hangar
		_place(_pos2())
		for k in crew.size():
			crew[k].alight(_door(k))
		state = "DECHARGEMENT"
		unload_phase.clear()
		if load > 0:
			_say("%s : retour à la scierie avec %d grumes" % [drone_id, load])
			EventBus.emit_event("wood_delivered", info())
	else:
		_begin_work()


# ------------------------------------------------------------ chantier

func _begin_work() -> void:
	state = "CHANTIER"
	var forest: Node3D = GameState.fire
	stump = forest.tree_base[target]
	tree_s = forest.tree_scale(target)
	var to_tree := (Vector2(stump.x, stump.z) - _pos2()).normalized()
	# le pin tombe perpendiculairement à l'axe camion -> arbre : jamais sur le camion
	fall_dir = Vector2(-to_tree.y, to_tree.x) * (1.0 if randf() < 0.5 else -1.0)
	for k in crew.size():
		crew[k].alight(_door(k))
	var cutter = crew[0]
	cutter.go_to(_on_ground(Vector2(stump.x, stump.z) - fall_dir * 0.9))
	var side := Vector2(-heading.y, heading.x)
	crew[1].go_to(_on_ground(_pos2() - heading * 6.5 + side * 2.0))   # débardeur à distance de sécurité, derrière le camion
	ground_logs.clear()
	logs_loaded = 0
	carry_log = null
	work = "APPROCHE"
	work_t = 0.0


func _on_ground(p: Vector2) -> Vector3:
	return Vector3(p.x, 0.0, p.y)


## Point du tronc couché, à la distance d du pied, décalé sur le côté.
func _along(d: float, lat: float) -> Vector3:
	var p := Vector2(stump.x, stump.z) + fall_dir * d + Vector2(-fall_dir.y, fall_dir.x) * lat
	return _on_ground(p)


func _seg_len() -> float:
	return 8.0 * tree_s / logs_per_tree


func _work(dt: float) -> void:
	var cutter = crew[0]
	var hauler = crew[1]
	match work:
		"APPROCHE":
			if cutter.arrived():
				cutter.saw(stump + Vector3(0, 0.5, 0))
				work = "SCIAGE"
				work_t = CUT_TIME
		"SCIAGE":
			work_t -= dt
			if work_t <= 0.0:
				_spawn_felled()
				camp.on_felled(target)
				cutter.go_to(_along(-3.0, 2.0))   # recul de sécurité pendant la chute
				work = "CHUTE"
				work_t = 0.0
		"CHUTE":
			work_t += dt
			felled.set_fall(work_t / FALL_TIME)
			if work_t >= FALL_TIME:
				dust.global_position = _along(5.0 * tree_s, 0.0) + Vector3(0, stump.y + 0.5, 0)
				dust.restart()
				cutter.go_to(_along(7.0 * tree_s, 1.0))
				work = "EBRANCHAGE"
				work_t = 0.0
		"EBRANCHAGE":
			if cutter.state == "MOVING":
				return
			if cutter.state != "SAW":
				cutter.saw(_along(7.0 * tree_s, 0.0))
			work_t += dt
			felled.foliage.scale = Vector3.ONE * maxf(0.001, 1.0 - work_t / LIMB_TIME)
			if work_t >= LIMB_TIME:
				felled.foliage.visible = false
				next_cut = logs_per_tree - 1
				cutter.go_to(_along(0.45 + next_cut * _seg_len(), 0.9))
				work = "TRONCONNAGE"
				work_t = 0.0
		"TRONCONNAGE":
			if next_cut > 0 and cutter.state != "MOVING":
				if cutter.state != "SAW":
					cutter.saw(_along(0.45 + next_cut * _seg_len(), 0.0))
				work_t += dt
				if work_t >= BUCK_TIME:
					work_t = 0.0
					_spawn_log(next_cut)
					next_cut -= 1
					if next_cut == 0:
						_spawn_log(0)
						felled.trunk.visible = false
						cutter.go_to(_door(0))
					else:
						cutter.go_to(_along(0.45 + next_cut * _seg_len(), 0.9))
			_haul()
			if next_cut == 0 and logs_loaded >= logs_per_tree:
				plant_spot = camp.plant_spot(target)
				hauler.go_to(plant_spot + (_on_ground(Vector2(stump.x, stump.z)) - plant_spot).normalized() * 0.7)
				work = "REPLANTATION"
				work_t = 0.0
		"REPLANTATION":
			if hauler.state == "MOVING":
				return
			if hauler.state != "PLANT":
				hauler.plant(plant_spot)
			work_t += dt
			if work_t >= PLANT_TIME:
				camp.replant(target, plant_spot)
				_clear_felled()
				trees_this_trip += 1
				camp.release(target)
				target = -1
				# plateau pas encore plein : arbre suivant, à proximité
				var nxt := -1
				if load + logs_per_tree <= capacity:
					nxt = camp.pick_tree(_pos2(), NEXT_TREE_RANGE)
				if nxt >= 0:
					target = nxt
					camp.reserve(nxt, self)
					_start_boarding("ROUTE")
				else:
					_start_boarding("RETOUR")


## Débardeur : va chercher les grumes au sol et les charge sur le plateau.
func _haul() -> void:
	var hauler = crew[1]
	if carry_log == null:
		if ground_logs.is_empty() or hauler.state == "MOVING":
			return
		carry_log = ground_logs.pop_back()
		var lp := carry_log.global_position
		var side := Vector2(-fall_dir.y, fall_dir.x)
		hauler.go_to(Vector3(lp.x + side.x * 0.8, 0.0, lp.z + side.y * 0.8))
	elif not hauler.carrying:
		if hauler.arrived():
			carry_log.visible = false   # libérée au chargement seulement (un objet libéré vaut null)
			hauler.set_carrying(true)
			hauler.go_to(_rear())
	elif hauler.arrived():
		hauler.set_carrying(false)
		carry_log.queue_free()
		carry_log = null
		_set_load(load + 1)
		logs_loaded += 1


## Copie visuelle de l'arbre, qui va pivoter autour de son pied.
func _spawn_felled() -> void:
	felled = FelledTree.new()
	add_child(felled)
	felled.setup(GameState.fire, target, fall_dir)


## Grume k (0 = pied) posée au sol le long du tronc couché.
func _spawn_log(k: int) -> void:
	var seg := _seg_len()
	ground_logs.push_front(felled.make_log(0.45 + k * seg, 0.45 + (k + 1) * seg, self))   # emportées dans l'ordre de coupe (pop_back)


func _clear_felled() -> void:
	if felled:
		felled.queue_free()
		felled = null
	for lg in ground_logs:
		lg.queue_free()
	ground_logs.clear()
	if carry_log:
		carry_log.queue_free()
		carry_log = null


## Évacuation en plein chantier : on laisse tout sur place.
func _abandon_worksite() -> void:
	var was_felled := felled != null
	_clear_felled()
	for f in crew:
		f.idle()
		f.set_carrying(false)
	if was_felled:
		camp.replant(target, camp.plant_spot(target))   # replanté plus tard par les gardes forestiers
	camp.release(target)
	target = -1


# ------------------------------------------------------------ scierie

func _unload() -> void:
	var busy := false
	for f in crew:
		var ph: String = unload_phase.get(f, "")
		if ph == "" and load > 0:
			unload_phase[f] = "TO_TRUCK"
			f.go_to(_rear())
			busy = true
		elif ph == "TO_TRUCK":
			busy = true
			if f.arrived():
				if load > 0:
					_set_load(load - 1)
					f.set_carrying(true)
					unload_phase[f] = "TO_PILE"
					f.go_to(camp.pile_point(f.get_instance_id()))
				else:
					unload_phase[f] = ""
		elif ph == "TO_PILE":
			busy = true
			if f.arrived():
				f.set_carrying(false)
				camp.deliver_log()
				unload_phase[f] = ""
	if not busy and load == 0:
		state = "SCIERIE"
		rest_t = REST_TIME
		for k in crew.size():
			crew[k].go_to(camp.idle_point(self, k))


func _set_load(n: int) -> void:
	load = clampi(n, 0, capacity)
	for k in bed_logs.size():
		bed_logs[k].visible = k < load


# ------------------------------------------------------------ visuel

func _animate() -> void:
	label.visible = GameState.show_labels and not at_sawmill()
	label.text = "%s · grumes %d/%d" % [drone_id, load, capacity]


func _mat(c: Color, rough := 0.6) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.roughness = rough
	return m


func _box(parent: Node3D, sz: Vector3, pos: Vector3, mat: Material) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var b := BoxMesh.new()
	b.size = sz
	mi.mesh = b
	mi.material_override = mat
	mi.position = pos
	parent.add_child(mi)
	return mi


func _build_visual() -> void:
	body = Node3D.new()
	add_child(body)
	var green := Look.paint(Color(0.1, 0.26, 0.12), 0.3, 0.2)       # vert forestier
	var dark := Look.plastic(Color(0.03, 0.03, 0.035), 0.6)
	var steel := Look.metal(Color(0.4, 0.41, 0.42), 0.5)
	var yellow := Look.paint(Color(0.85, 0.65, 0.08), 0.35, 0.1)
	var glass := Look.glass()
	# châssis, cabine (avant = -Z), plateau, ridelle avant (grille de protection)
	_box(body, Vector3(2.4, 0.5, 8.8), Vector3(0, 0.8, 0.3), dark)
	_box(body, Vector3(2.45, 2.1, 2.3), Vector3(0, 2.05, -3.05), green)
	_box(body, Vector3(2.3, 0.85, 0.05), Vector3(0, 2.45, -4.21), glass)
	for sx in [-1.235, 1.235]:
		_box(body, Vector3(0.02, 0.7, 1.4), Vector3(sx, 2.45, -3.1), glass)
	_box(body, Vector3(2.45, 0.16, 5.9), Vector3(0, 1.3, 1.75), steel)
	_box(body, Vector3(2.45, 1.9, 0.1), Vector3(0, 2.3, -1.25), steel)
	for k in 4:
		_box(body, Vector3(2.45, 0.06, 0.12), Vector3(0, 1.6 + k * 0.42, -1.25), dark)
	# ranchers (montants qui retiennent les grumes)
	for z in [-0.6, 1.75, 4.1]:
		for sx in [-1.15, 1.15]:
			_box(body, Vector3(0.12, 1.7, 0.12), Vector3(sx, 2.2, z), yellow)
	# grue de chargement repliée derrière la cabine
	_box(body, Vector3(0.35, 1.6, 0.35), Vector3(0.75, 2.3, -1.65), yellow)
	_box(body, Vector3(0.24, 0.24, 3.4), Vector3(0.75, 3.15, 0.0), yellow)
	_box(body, Vector3(0.18, 0.7, 0.18), Vector3(0.75, 2.8, 1.6), steel)
	# roues (3 essieux)
	for z in [-3.0, 1.4, 3.2]:
		for x in [-1.12, 1.12]:
			var w := MeshInstance3D.new()
			var wm := CylinderMesh.new()
			wm.top_radius = 0.55
			wm.bottom_radius = 0.55
			wm.height = 0.42
			w.mesh = wm
			w.material_override = dark
			w.position = Vector3(x, 0.55, z)
			w.rotation_degrees.z = 90.0
			body.add_child(w)
	# feux de travail orange sur le toit
	for x in [-0.7, 0.7]:
		var m := _mat(Color(1.0, 0.55, 0.1))
		m.emission_enabled = true
		m.emission = Color(1.0, 0.55, 0.1)
		m.emission_energy_multiplier = 3.0
		_box(body, Vector3(0.3, 0.16, 0.22), Vector3(x, 3.18, -3.3), m)
	# grumes chargées (masquées tant que le plateau est vide)
	for sl in BED_SLOTS:
		var lg := FelledTree.log_mesh(2.5, 0.2)
		lg.position = sl
		lg.rotation_degrees.x = 90.0
		lg.visible = false
		body.add_child(lg)
		bed_logs.append(lg)
	# poussière soulevée par la chute de l'arbre
	dust = CPUParticles3D.new()
	dust.top_level = true
	dust.one_shot = true
	dust.emitting = false
	dust.amount = 40
	dust.lifetime = 2.0
	dust.explosiveness = 0.9
	dust.emission_shape = CPUParticles3D.EMISSION_SHAPE_BOX
	dust.emission_box_extents = Vector3(3.0, 0.3, 3.0)
	dust.direction = Vector3.UP
	dust.spread = 70.0
	dust.initial_velocity_min = 1.0
	dust.initial_velocity_max = 2.5
	dust.gravity = Vector3(0, -0.5, 0)
	dust.scale_amount_min = 0.6
	dust.scale_amount_max = 1.4
	var puff := SphereMesh.new()
	puff.radius = 0.5
	puff.height = 1.0
	puff.radial_segments = 6
	puff.rings = 3
	var pm := StandardMaterial3D.new()
	pm.albedo_color = Color(0.55, 0.48, 0.38, 0.45)
	pm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	pm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	puff.material = pm
	dust.mesh = puff
	add_child(dust)
	label = Label3D.new()
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.no_depth_test = false
	label.fixed_size = true
	label.pixel_size = 0.0007
	label.font_size = 28
	label.outline_size = 8
	label.modulate = Color(0.95, 0.8, 0.45)
	label.position = Vector3(0, 6.0, 0)
	add_child(label)
