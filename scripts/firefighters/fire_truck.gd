extends Node3D
const Look := preload("res://scripts/render/look.gd")
## Fourgon pompe-tonne (FPT) : citerne d'eau, 4 pompiers, lances d'incendie.
##
## Comme les drones, le camion EXÉCUTE des commandes (cmd_dispatch, cmd_return)
## et PUBLIE des événements (fire_trucks_departed, fire_truck_arrived,
## fire_truck_empty, fire_out_of_reach, fire_truck_returned, fire_truck_ready).
## Les règles d'automatisation décident quoi en faire.
##
## États : CASERNE, DEPART (équipage qui monte), ROUTE, DEPLOIEMENT/EXTINCTION
##         (équipage à pied, lances en action), REPLI (équipage qui remonte),
##         RETOUR, REMPLISSAGE (citerne remplie à la caserne)

const HOSE_LEN := 45.0          # longueur de tuyau déroulable depuis le camion
const SPRAY_RANGE := 13.0       # portée utile d'une lance
const SPRAY_RADIUS := 5.5       # zone éteinte par un jet
const SPRAY_PERIOD := 1.3       # s entre deux applications d'eau par lance
const ROAD_SPEED := 14.0
const TRACK_SPEED := 8.0

var drone_id := "FPT"           # identifiant (nom compatible caméra/interface)
var role := "fire_truck"
var state := "CASERNE"
var water := 100
var max_water := 100
var crew: Array = []            # pompiers rattachés (le premier est le conducteur)
var home_node := -1             # place de stationnement à la caserne
var fire_target := Vector3.ZERO
var stage_node := -1            # nœud de piste où le camion se met en batterie
var route: Array = []           # points (Vector2) à parcourir
var route_kinds: Array = []
var velocity := Vector3.ZERO
var speed := 0.0
var heading := Vector2(0, -1)
var moving := false
var after_boarding := ""        # ROUTE ou RETOUR, une fois l'équipage à bord
var spray_cd := {}
var targets := {}               # pompier -> cellule visée
var no_target_t := 0.0
var out_of_reach_sent := false
var empty_sent := false
var refill_t := 0.0
var retarget_t := 0.0
var blink_t := 0.0
var fpv_hidden := false
var fpv_local := Vector3(0, 3.1, -2.6)   # caméra embarquée : dans la cabine
var cam_scale := 0.55                     # distance de suivi caméra adaptée à un camion de 8 m

var net: Node3D
var service: Node3D
var body: Node3D
var label: Label3D
var beacons: Array[MeshInstance3D] = []
var hoses := {}                 # pompier -> MeshInstance3D (tuyau au sol)


func _ready() -> void:
	max_water = int(GameState.cfgv("fire_service", "water_capacity", max_water))
	water = max_water
	_build_visual()


func info() -> Dictionary:
	var on_board := 0
	for f in crew:
		if f.aboard:
			on_board += 1
	return {"unit_id": drone_id, "drone_id": drone_id, "role": role, "state": state, "water": water,
		"crew": crew.size(), "crew_aboard": on_board}


func at_station() -> bool:
	return state == "CASERNE" or state == "REMPLISSAGE"


func is_available() -> bool:
	return state == "CASERNE" and water > 0


# ------------------------------------------------------------ commandes

func cmd_dispatch(target: Vector3, stage: int) -> void:
	fire_target = target
	stage_node = stage
	out_of_reach_sent = false
	no_target_t = 0.0
	match state:
		"CASERNE", "REMPLISSAGE":
			_start_boarding("ROUTE")
		"DEPLOIEMENT", "EXTINCTION":
			_start_boarding("ROUTE")   # on replie les lances et on se déplace
		"ROUTE", "RETOUR":
			_set_route(stage_node)
			state = "ROUTE"
		"DEPART", "REPLI":
			after_boarding = "ROUTE"


func cmd_return() -> void:
	match state:
		"DEPLOIEMENT", "EXTINCTION", "DEPART":
			_start_boarding("RETOUR")
		"REPLI":
			after_boarding = "RETOUR"
		"ROUTE":
			_set_route(home_node)
			state = "RETOUR"


func _start_boarding(next: String) -> void:
	after_boarding = next
	state = "DEPART" if at_station() or state == "DEPART" else "REPLI"
	_clear_targets()
	var running := after_boarding == "ROUTE"
	for k in crew.size():
		crew[k].go_to(_door(k), running)


## Place de chaque pompier à côté du camion (portes de cabine / caisse).
func _door(k: int) -> Vector3:
	var side := Vector2(-heading.y, heading.x)
	var along: float = [2.2, 2.2, -0.8, -0.8][k % 4]
	var lat: float = [-1.9, 1.9, -1.9, 1.9][k % 4]
	var p: Vector2 = Vector2(global_position.x, global_position.z) + heading * along + side * lat
	return Vector3(p.x, 0.0, p.y)


func _set_route(to_node: int) -> void:
	var here := Vector2(global_position.x, global_position.z)
	var from: int = net.nearest_node(here)
	var ids: Array = net.path(from, to_node)
	route.clear()
	route_kinds.clear()
	for id in ids:
		route.append(net.nodes[id])
		route_kinds.append(net.kinds[id])
	# inutile de revenir au premier nœud s'il est derrière nous
	var first: Vector2 = route[0] if not route.is_empty() else here
	if route.size() > 1 and here.distance_to(route[1]) < first.distance_to(route[1]):
		route.pop_front()
		route_kinds.pop_front()


# ------------------------------------------------------------ simulation

func _physics_process(dt: float) -> void:
	if dt <= 0.0:
		return
	moving = false
	match state:
		"DEPART", "REPLI":
			_update_boarding()
		"ROUTE", "RETOUR":
			_drive(dt)
		"DEPLOIEMENT", "EXTINCTION":
			_fight(dt)
		"REMPLISSAGE":
			refill_t -= dt
			water = mini(max_water, water + int(ceil(dt * max_water / 10.0)))
			if refill_t <= 0.0:
				water = max_water
				state = "CASERNE"
				empty_sent = false
				EventBus.emit_event("fire_truck_ready", info())
	_update_hoses()
	_animate(dt)


func _update_boarding() -> void:
	for k in crew.size():
		var f = crew[k]
		if f.aboard:
			continue
		if f.state == "IDLE" or f.arrived():
			if Vector2(f.global_position.x - global_position.x, f.global_position.z - global_position.z).length() < 4.0:
				f.board()
			else:
				f.go_to(_door(k), after_boarding == "ROUTE")
	for f in crew:
		if not f.aboard:
			return
	# tout le monde est à bord : départ
	if after_boarding == "ROUTE":
		_set_route(stage_node)
		state = "ROUTE"
		EventBus.emit_event("fire_trucks_departed", info())
	else:
		_set_route(home_node)
		state = "RETOUR"


func _drive(dt: float) -> void:
	if route.is_empty():
		_on_arrival()
		return
	var here := Vector2(global_position.x, global_position.z)
	var wp: Vector2 = route[0]
	var to := wp - here
	var limit := TRACK_SPEED if (route_kinds[0] == "track") else ROAD_SPEED
	# ralentir avant un virage serré
	if route.size() > 1 and to.length() < 14.0:
		var nxt: Vector2 = route[1]
		var turn := to.normalized().dot((nxt - wp).normalized())
		limit = minf(limit, lerpf(4.0, limit, clampf((turn + 1.0) * 0.5, 0.0, 1.0)))
	if route.size() == 1:
		limit = minf(limit, maxf(2.0, to.length() * 0.8))
	# véhicule devant : voiture ou autre camion
	for o in service.trucks:
		if o != self and o.moving:
			var off := Vector2(o.global_position.x, o.global_position.z) - here
			if off.length() < 13.0 and off.normalized().dot(heading) > 0.7:
				limit = minf(limit, maxf(0.0, (off.length() - 10.0) * 1.5))
	if service.city_life:
		for c in service.city_life.cars:
			var off: Vector2 = c.pos - here
			var ahead := off.dot(heading)
			var lat := absf(off.dot(Vector2(-heading.y, heading.x)))
			# demi-longueur camion 4,2 m + demi-longueur voiture 2,15 m + marge
			if ahead > 0.0 and ahead < 14.0 and lat < 2.8:
				limit = minf(limit, maxf(0.0, (ahead - 7.5) * 1.2))
	speed = move_toward(speed, limit, dt * (7.0 if limit < speed else 3.0))
	var step := speed * dt
	if to.length() <= maxf(step, 0.5):
		here = wp
		route.pop_front()
		route_kinds.pop_front()
	else:
		var d := to.normalized()
		heading = heading.lerp(d, clampf(dt * 5.0, 0.0, 1.0)).normalized()
		here += d * step
	moving = speed > 0.3
	_place(here)
	velocity = Vector3(heading.x, 0, heading.y) * speed


func _place(p: Vector2) -> void:
	var y: float = GameState.terrain.height_at(p.x, p.y)
	if service.on_station(p):
		y = maxf(y, service.APRON_TOP)
	global_position = Vector3(p.x, y, p.y)
	rotation.y = atan2(-heading.x, -heading.y)
	# inclinaison selon la pente (avant / arrière)
	var f := Vector2(p.x, p.y) + heading * 3.0
	var b := Vector2(p.x, p.y) - heading * 3.0
	var dh: float = GameState.terrain.height_at(f.x, f.y) - GameState.terrain.height_at(b.x, b.y)
	body.rotation.x = lerpf(body.rotation.x, atan2(dh, 6.0), 0.2)


func _on_arrival() -> void:
	speed = 0.0
	velocity = Vector3.ZERO
	if state == "RETOUR":
		# garé face à la rue, prêt à repartir
		heading = Vector2(0, -1)
		_place(Vector2(global_position.x, global_position.z))
		for k in crew.size():
			crew[k].alight(_door(k))
			crew[k].idle()
		state = "REMPLISSAGE"
		refill_t = 8.0 if water < max_water else 0.5
		EventBus.emit_event("fire_truck_returned", info())
		return
	# arrivé sur la piste : mise en batterie, l'équipage descend
	state = "DEPLOIEMENT"
	for k in crew.size():
		crew[k].alight(_door(k))
	retarget_t = 0.0
	EventBus.emit_event("fire_truck_arrived", info())


## Attaque du feu : les équipiers se placent à distance de sécurité des cellules
## en feu à portée de tuyau et les arrosent ; le conducteur reste à la pompe.
func _fight(dt: float) -> void:
	retarget_t -= dt
	var fire = GameState.fire
	if retarget_t <= 0.0:
		retarget_t = 2.0
		_assign_targets(fire)
	var any_target := false
	for k in range(1, crew.size()):
		var f = crew[k]
		var tgt = targets.get(f)
		if tgt == null:
			continue
		any_target = true
		var t: Vector3 = tgt
		# danger : un foyer trop proche, on recule vers le camion
		if not fire.burning_near(f.global_position, 3.5).is_empty():
			var back: Vector3 = global_position - f.global_position
			back.y = 0.0
			f.go_to(f.global_position + back.normalized() * 6.0, true)
			continue
		if f.state == "MOVING" and not f.arrived():
			continue
		if water <= 0:
			f.idle()
			continue
		if f.state != "SPRAYING":
			f.spray_at(t)
			state = "EXTINCTION"
		spray_cd[f] = spray_cd.get(f, 0.0) - dt
		if spray_cd[f] <= 0.0:
			spray_cd[f] = SPRAY_PERIOD
			fire.apply_water(t, SPRAY_RADIUS)
			water = maxi(0, water - 1)
	if water <= 0 and not empty_sent:
		empty_sent = true
		_clear_targets()
		EventBus.emit_event("fire_truck_empty", info())
	if any_target:
		no_target_t = 0.0
	else:
		no_target_t += dt
		# à l'arrivée on juge vite ; en cours d'attaque on laisse le temps au feu de revenir
		var patience := 2.5 if state == "DEPLOIEMENT" else 8.0
		if no_target_t > patience and not out_of_reach_sent and GameState.orchestrator.fire_known and fire.burning_count() > 0:
			out_of_reach_sent = true
			EventBus.emit_event("fire_out_of_reach", info())


func _assign_targets(fire) -> void:
	var base := global_position
	var taken: Array = []
	for k in range(1, crew.size()):
		var f = crew[k]
		var old = targets.get(f)
		# on garde sa cible tant qu'elle brûle encore
		if old != null and not fire.burning_near(old, 2.0).is_empty():
			taken.append(old)
			continue
		var cell = fire.find_target(base, taken, 10.0)
		if cell == null or Vector2(cell.x - base.x, cell.z - base.z).length() > HOSE_LEN + SPRAY_RANGE:
			targets.erase(f)
			f.idle()
			continue
		var c: Vector3 = cell
		taken.append(c)
		targets[f] = c
		# position de tir : à portée de lance, côté camion
		var away := Vector2(base.x - c.x, base.z - c.z)
		var stand := Vector2(c.x, c.z) + away.normalized() * minf(SPRAY_RANGE - 2.0, away.length())
		var from_truck := stand - Vector2(base.x, base.z)
		if from_truck.length() > HOSE_LEN:
			stand = Vector2(base.x, base.z) + from_truck.normalized() * HOSE_LEN
		f.go_to(Vector3(stand.x, 0.0, stand.y), true)
	# le conducteur reste au tableau de pompe
	if not crew.is_empty() and crew[0].state == "IDLE":
		crew[0].go_to(_door(2), false)


func _clear_targets() -> void:
	targets.clear()
	for f in crew:
		f.stop_spray()


# ------------------------------------------------------------ visuel

func _update_hoses() -> void:
	var deployed := state == "DEPLOIEMENT" or state == "EXTINCTION" or state == "REPLI"
	for k in range(1, crew.size()):
		var f = crew[k]
		var h: MeshInstance3D = hoses.get(f)
		if h == null:
			continue
		h.visible = deployed and not f.aboard
		if not h.visible:
			continue
		var a := global_position + global_transform.basis * Vector3(0, 0.6, 1.5)
		var b: Vector3 = f.global_position + Vector3(0, 0.15, 0)
		var d := b - a
		if d.length() < 0.2:
			h.visible = false
			continue
		h.global_transform = Transform3D(Basis.looking_at(d.normalized(), Vector3.UP) * Basis.from_scale(Vector3(1, 1, d.length())), a + d * 0.5)


func _animate(dt: float) -> void:
	blink_t += dt
	var on_mission := state == "ROUTE" or state == "DEPLOIEMENT" or state == "EXTINCTION"
	for k in beacons.size():
		beacons[k].visible = on_mission and fmod(blink_t * 2.5 + k * 0.5, 1.0) < 0.5
	label.text = "%s · eau %d/%d" % [drone_id, water, max_water]


func _mat(c: Color, emission: float = 0.0) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.roughness = 0.5
	m.metallic = 0.2
	if emission > 0.0:
		m.emission_enabled = true
		m.emission = c
		m.emission_energy_multiplier = emission
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
	var red := Look.paint(Color(0.48, 0.02, 0.015), 0.25, 0.2)       # rouge pompier verni
	var white := Look.emissive(Color(0.85, 0.85, 0.83), 0.15)        # bande rétroréfléchissante
	var dark := Look.plastic(Color(0.03, 0.03, 0.035), 0.6)
	var glass := Look.glass()
	var alu := Look.metal(Color(0.78, 0.79, 0.8), 0.35)
	# châssis, cabine (avant = -Z), caisse avec coffres, bande blanche
	_box(body, Vector3(2.5, 0.5, 8.4), Vector3(0, 0.75, 0), dark)
	_box(body, Vector3(2.5, 2.0, 2.4), Vector3(0, 2.0, -2.9), red)
	_box(body, Vector3(2.3, 0.8, 0.05), Vector3(0, 2.45, -4.11), glass)
	_box(body, Vector3(2.52, 2.5, 5.6), Vector3(0, 2.25, 1.2), red)
	_box(body, Vector3(2.56, 0.18, 8.0), Vector3(0, 1.5, -0.2), white)
	for k in 3:
		# rideaux de coffres en aluminium (lamelles)
		_box(body, Vector3(2.57, 1.3, 1.5), Vector3(0, 2.4, -0.6 + k * 1.75), alu)
		for j in 6:
			_box(body, Vector3(2.59, 0.025, 1.5), Vector3(0, 1.85 + j * 0.2, -0.6 + k * 1.75), Look.metal(Color(0.5, 0.5, 0.52), 0.5))
	# vitres latérales de cabine
	for sx in [-1.26, 1.26]:
		_box(body, Vector3(0.02, 0.7, 1.6), Vector3(sx, 2.45, -2.95), glass)
	# échelle sur le toit et dévidoir à l'arrière
	_box(body, Vector3(0.7, 0.15, 6.0), Vector3(0, 3.6, 0.8), alu)
	for k in 7:
		_box(body, Vector3(0.7, 0.08, 0.08), Vector3(0, 3.7, -2.0 + k * 0.9), alu)
	var reel := MeshInstance3D.new()
	var cm := CylinderMesh.new()
	cm.top_radius = 0.55
	cm.bottom_radius = 0.55
	cm.height = 1.6
	reel.mesh = cm
	reel.material_override = Look.paint(Color(0.6, 0.5, 0.08), 0.4, 0.1)
	reel.position = Vector3(0, 1.8, 4.15)
	reel.rotation_degrees.z = 90.0
	body.add_child(reel)
	# roues
	for z in [-2.9, 1.0, 2.8]:
		for x in [-1.15, 1.15]:
			var w := MeshInstance3D.new()
			var wm := CylinderMesh.new()
			wm.top_radius = 0.55
			wm.bottom_radius = 0.55
			wm.height = 0.4
			w.mesh = wm
			w.material_override = dark
			w.position = Vector3(x, 0.55, z)
			w.rotation_degrees.z = 90.0
			body.add_child(w)
	# gyrophares bleus
	for x in [-0.8, 0.8]:
		beacons.append(_box(body, Vector3(0.45, 0.22, 0.3), Vector3(x, 3.1, -3.4), _mat(Color(0.2, 0.4, 1.0), 8.0)))
	label = Label3D.new()
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.no_depth_test = false   # masquée par les immeubles et le relief (réalisme)
	label.fixed_size = true
	label.pixel_size = 0.0007
	label.font_size = 28
	label.outline_size = 8
	label.modulate = Color(1.0, 0.55, 0.45)
	label.position = Vector3(0, 6.0, 0)
	add_child(label)


func add_hose_for(f: Node3D) -> void:
	var h := MeshInstance3D.new()
	var b := BoxMesh.new()
	b.size = Vector3(0.14, 0.14, 1.0)
	h.mesh = b
	h.material_override = Look.plastic(Color(0.75, 0.74, 0.7), 0.7)
	h.top_level = true
	h.visible = false
	h.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(h)
	hoses[f] = h
