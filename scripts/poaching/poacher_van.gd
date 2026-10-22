extends "res://scripts/vehicles/vehicle.gd"
## Camionnette de braconniers : un abatteur et ses porteurs, spécialisés dans la
## coupe illégale de pins dans la forêt protégée.
##
## ARRIVEE (par une piste depuis le bord de la carte) -> COUPE (abattage, tronçonnage,
## grumes portées dans la camionnette) -> DEPART -> SORTIE (repartent par où ils sont venus).
## Alertés (drone qui tourne au-dessus d'eux pendant qu'ils sont à l'arrêt — en roulant, le moteur
## couvre le bruit des hélices —, sirènes, incendie qu'ils ont provoqué) :
##   - FUITE en camionnette vers la sortie la moins surveillée ;
##   - route coupée ou poursuivants trop proches : ils ABANDONNENT la camionnette et
##     s'enfuient à pied à travers la forêt vers le bord de carte le plus sûr.
## Un braconnier qui atteint le bord de la carte s'est échappé ; un braconnier rattrapé
## par un garde ou un policier est menotté (patrol_vehicle.gd).

const FelledTree := preload("res://scripts/lumber/felled_tree.gd")
const CUT_TIME := 4.0           # trait d'abattage (travail bâclé, rapide)
const FALL_TIME := 2.4
const BUCK_TIME := 2.5
const CAPACITY := 6
const BED_SLOTS := [Vector3(-0.45, 1.2, 1.25), Vector3(0.45, 1.2, 1.25), Vector3(0.0, 1.55, 1.25),
	Vector3(-0.45, 1.9, 1.25), Vector3(0.45, 1.9, 1.25), Vector3(0.0, 2.25, 1.25)]

var group := 1
var manager: Node3D
var entry_exit := -1            # sortie (bord de carte) par laquelle ils sont arrivés
var trees: Array = []           # arbres visés à cet endroit
var target := -1
var work := ""                  # APPROCHE, SCIAGE, CHUTE, TRONCONNAGE
var work_t := 0.0
var fall_dir := Vector2.RIGHT
var felled: Node3D = null
var ground_logs: Array = []
var carry := {}                 # porteur -> grume visée ou portée
var load := 0
var detected := false
var detected_by := ""
var last_report := -100.0
var fleeing := ""               # "" | "vehicule" | "pied"
var check_t := 0.0
var flee_goal := {}             # braconnier -> point de fuite au bord de la carte
var bed_logs: Array[MeshInstance3D] = []


func _ready() -> void:
	role = "poachers"
	build_pickup(Color(0.16, 0.17, 0.16))
	label.modulate = Color(1.0, 0.45, 0.4)
	# bâche sale sur l'avant du plateau, grumes chargées
	box(body, Vector3(1.8, 0.5, 0.9), Vector3(0, 1.25, 0.0), Look.plastic(Color(0.25, 0.28, 0.2), 0.9))
	for sl in BED_SLOTS:
		var lg := FelledTree.log_mesh(2.2, 0.17)
		lg.position = sl
		lg.rotation_degrees.x = 90.0
		lg.visible = false
		body.add_child(lg)
		bed_logs.append(lg)


func speed_for(kind: String) -> float:
	return {"track": 8.5, "exit": 8.5, "city": 8.5}.get(kind, 4.0)


func info() -> Dictionary:
	return {"unit_id": drone_id, "group": group, "state": state, "logs": load, "free": free_members().size()}


## Braconniers encore libres (ni menottés, ni sortis de la carte).
func free_members() -> Array:
	return crew.filter(func(m): return not m.cuffed and not m.escaped)


func is_over() -> bool:
	return free_members().is_empty()


# ------------------------------------------------------------ simulation

func _physics_process(dt: float) -> void:
	if dt <= 0.0:
		return
	moving = false
	match state:
		"ARRIVEE":
			if drive(dt):
				_begin_work()
		"COUPE":
			_work(dt)
			_haul()
		"DEPART":
			if _gather(false):
				route = path_to_node(entry_exit)
				state = "SORTIE"
		"FUITE_EMBARQUEMENT":
			if _gather(true):
				var r := _escape_route()
				if r.is_empty():
					abandon("route coupée")
				else:
					route = r
					speed_bonus = 1.0   # camionnette chargée sur une piste : pas plus vite qu'à l'aller
					state = "FUITE"
			elif _pursuer_within(35.0):
				abandon("poursuivants trop proches")
		"SORTIE", "FUITE":
			if drive(dt):
				_left_map()
			elif state == "FUITE":
				check_t -= dt
				if check_t <= 0.0:
					check_t = 0.5
					_check_blockade()
		"ABANDONNEE":
			_flee_on_foot(dt)
	if fleeing == "" and state != "PARTIE":
		_check_alert(dt)
	label.visible = GameState.show_labels and state != "PARTIE"
	label.text = "%s · braconniers" % drone_id


# ------------------------------------------------------------ coupe illégale

func _begin_work() -> void:
	state = "COUPE"
	trees = GameState.fire.forest_trees_near(pos2(), 10.0, 45.0)
	trees.shuffle()
	trees = trees.slice(0, manager.trees_per_visit)
	for k in crew.size():
		crew[k].alight(door(k))
	_next_tree()


func _next_tree() -> void:
	var forest: Node3D = GameState.fire
	target = -1
	while not trees.is_empty() and target < 0:
		var t: int = trees.pop_front()
		var idx: int = forest.cell_of(t)
		if forest.tree_growth[t] >= 1.0 and idx >= 0 and forest.state[idx] == forest.FUEL:
			target = t
	if target < 0 or load + 2 > CAPACITY:
		work = "RANGEMENT"
		crew[0].go_to(door(0))
		return
	var b: Vector3 = forest.tree_base[target]
	var to_tree := (Vector2(b.x, b.z) - pos2()).normalized()
	fall_dir = Vector2(-to_tree.y, to_tree.x) * (1.0 if randf() < 0.5 else -1.0)
	crew[0].go_to(Vector3(b.x - fall_dir.x * 0.9, 0.0, b.z - fall_dir.y * 0.9))
	work = "APPROCHE"


func _work(dt: float) -> void:
	var cutter = crew[0]
	var b: Vector3 = GameState.fire.tree_base[target] if target >= 0 else Vector3.ZERO
	match work:
		"APPROCHE":
			if cutter.arrived():
				cutter.saw(b + Vector3(0, 0.5, 0))
				work = "SCIAGE"
				work_t = CUT_TIME
		"SCIAGE":
			work_t -= dt
			if work_t <= 0.0:
				felled = FelledTree.new()
				manager.add_remains(felled)   # le houppier reste sur place : preuve de l'abattage
				felled.setup(GameState.fire, target, fall_dir)
				GameState.fire.fell_illegally(target)
				manager.on_tree_poached(self, target)
				cutter.go_to(felled.along(-3.0, 2.0))
				work = "CHUTE"
				work_t = 0.0
				if manager.roll_accident():
					manager.accident_fire(self, Vector3(b.x, b.y, b.z))
		"CHUTE":
			work_t += dt
			felled.set_fall(work_t / FALL_TIME)
			if work_t >= FALL_TIME:
				cutter.go_to(felled.along(3.6 * felled.tree_s, 0.9))
				work = "TRONCONNAGE"
				work_t = 0.0
		"TRONCONNAGE":
			if cutter.state == "MOVING":
				return
			if cutter.state != "SAW":
				cutter.saw(felled.along(3.6 * felled.tree_s, 0.0))
			work_t += dt
			if work_t >= BUCK_TIME:
				# deux grumes emportées, le houppier abandonné sur place
				var L: float = 3.4 * felled.tree_s
				ground_logs.append(felled.make_log(0.4, 0.4 + L, self))
				ground_logs.append(felled.make_log(0.4 + L, 0.4 + 2.0 * L, self))
				felled.trunk.visible = false
				felled = null
				_next_tree()
		"RANGEMENT":
			if ground_logs.is_empty() and carry.values().all(func(v): return v == null):
				state = "DEPART"


## Porteurs : vont chercher les grumes au sol et les chargent dans la camionnette.
func _haul() -> void:
	for k in range(1, crew.size()):
		var m = crew[k]
		var lg = carry.get(m)
		if lg == null:
			if ground_logs.is_empty() or m.state == "MOVING":
				continue
			lg = ground_logs.pop_back()
			carry[m] = lg
			var lp: Vector3 = lg.global_position
			m.go_to(Vector3(lp.x + 0.8, 0.0, lp.z))
		elif not m.carrying:
			if m.arrived():
				lg.visible = false   # libérée au chargement seulement (un objet libéré vaut null)
				m.set_carrying(true)
				m.go_to(_rear())
		elif m.arrived():
			m.set_carrying(false)
			lg.queue_free()
			carry[m] = null
			_set_load(load + 1)


func _rear() -> Vector3:
	var p := pos2() - heading * 3.0 + Vector2(-heading.y, heading.x) * 0.5
	return Vector3(p.x, 0.0, p.y)


func _set_load(n: int) -> void:
	load = clampi(n, 0, CAPACITY)
	for k in bed_logs.size():
		bed_logs[k].visible = k < load


## Laisse tout en plan : grumes au sol, tronçonneuse coupée.
func _drop_work() -> void:
	for m in crew:
		var lg = carry.get(m)
		if lg != null:
			lg.queue_free()
		m.set_carrying(false)
		if not m.cuffed and not m.aboard:
			m.idle()
	carry.clear()
	if felled:
		felled.set_fall(1.0)   # l'arbre finit de tomber
		felled = null
	work = ""


## Fait remonter les braconniers libres ; vrai quand tous sont à bord.
func _gather(running: bool) -> bool:
	var ok := true
	for k in crew.size():
		var m = crew[k]
		if m.aboard or m.cuffed or m.escaped:
			continue
		ok = false
		if Vector2(m.global_position.x, m.global_position.z).distance_to(pos2()) < 3.2:
			m.board()
		elif m.state == "IDLE" or m.arrived():
			m.go_to(door(k), running)
	return ok


# ------------------------------------------------------------ alerte et fuite

func _check_alert(dt: float) -> void:
	check_t -= dt
	if check_t > 0.0:
		return
	check_t = 1.0
	if manager.siren_heard(pos2()):
		flee("sirènes")
	elif _pursuer_seen(25.0) or (_pursuer_seen(70.0) and randf() < 0.35):   # moins attentifs en tronçonnant
		flee("gardes ou policiers en vue")
	elif detected and not moving and manager.drone_overhead(self) and randf() < manager.notice_chance:
		flee("drone au-dessus d'eux")


## Les braconniers comprennent qu'ils sont repérés : ils s'enfuient.
func flee(reason: String) -> void:
	if fleeing != "" or state == "PARTIE" or is_over():
		return
	_drop_work()
	var near_van := true
	for m in free_members():
		if not m.aboard and Vector2(m.global_position.x, m.global_position.z).distance_to(pos2()) > 45.0:
			near_van = false
	if near_van and not _escape_route().is_empty() and not _pursuer_within(60.0):
		fleeing = "vehicule"
		stop()
		state = "FUITE_EMBARQUEMENT"
		for k in crew.size():
			if not crew[k].aboard and not crew[k].cuffed:
				crew[k].go_to(door(k), true)
		manager.on_flee(self, reason)
	else:
		abandon(reason)


## Itinéraire vers la sortie la plus courte dont aucun poursuivant ne garde le passage.
func _escape_route() -> Array:
	var best: Array = []
	var bl := INF
	for e in net.exit_nodes:
		var r := path_to_node(e)
		var blocked := false
		for u in manager.pursuers():
			for w in r:
				if u.pos2().distance_to(w[0]) < 50.0:
					blocked = true
					break
			if blocked:
				break
		var L := route_length(r)
		if not blocked and L < bl:
			bl = L
			best = r
	return best


## Un poursuivant (véhicule ou agent à pied) à moins de r d'un des braconniers.
func _pursuer_seen(r: float) -> bool:
	for q in manager.pursuer_points():
		if q.distance_to(pos2()) < r:
			return true
		for m in free_members():
			if not m.aboard and q.distance_to(Vector2(m.global_position.x, m.global_position.z)) < r:
				return true
	return false


## Un poursuivant (véhicule ou agent à pied) à moins de r de la camionnette.
func _pursuer_within(r: float) -> bool:
	for q in manager.pursuer_points():
		if q.distance_to(pos2()) < r:
			return true
	return false


## En pleine fuite : barrage ou poursuivant qui arrive en face -> on abandonne la camionnette.
func _check_blockade() -> void:
	if _pursuer_within(25.0):
		abandon("barrage des poursuivants")
		return
	for u in manager.pursuers():
		for k in mini(4, route.size()):
			var w: Vector2 = route[k][0]
			if u.pos2().distance_to(w) < 30.0 and u.pos2().distance_to(w) < pos2().distance_to(w):
				abandon("route coupée")
				return


func abandon(reason: String) -> void:
	var first := fleeing == ""
	stop()
	_drop_work()
	speed_bonus = 1.0
	fleeing = "pied"
	state = "ABANDONNEE"
	for k in crew.size():
		var m = crew[k]
		if m.aboard and not m.cuffed:
			m.alight(door(k))
	if first:
		manager.on_flee(self, reason)
	else:
		manager.on_abandon(self, reason)


func _flee_on_foot(dt: float) -> void:
	check_t -= dt
	var replan := check_t <= 0.0
	if replan:
		check_t = 1.0
	var edge: float = GameState.terrain.SIZE * 0.5 - 4.0
	for m in free_members():
		var p := Vector2(m.global_position.x, m.global_position.z)
		if absf(p.x) >= edge - 1.5 or absf(p.y) >= edge - 1.5:
			m.escaped = true
			m.visible = false
			manager.on_escaped(self, m)
			continue
		if replan or m.state == "IDLE":
			var g := _escape_point(p, edge)
			flee_goal[m] = g
			m.go_to(Vector3(g.x, 0.0, g.y), true)


## Bord de carte le plus sûr : le plus proche, en évitant de passer près d'un poursuivant.
func _escape_point(p: Vector2, edge: float) -> Vector2:
	var best := Vector2(edge, p.y)
	var bs := INF
	for c in [Vector2(edge, p.y), Vector2(p.x, -edge), Vector2(p.x, edge)]:
		var score := p.distance_to(c)
		for q in manager.pursuer_points():
			var d: float = q.distance_to(Geometry2D.get_closest_point_to_segment(q, p, c))
			if d < 45.0:
				score += (45.0 - d) * 10.0
		if score < bs:
			bs = score
			best = c
	return best


## Sortie atteinte en camionnette : tous ceux qui sont à bord se sont échappés.
func _left_map() -> void:
	for m in crew:
		if m.aboard and not m.cuffed:
			m.escaped = true
			manager.on_escaped(self, m)
	state = "PARTIE"
	visible = false
	stop()
