extends "res://scripts/vehicles/vehicle.gd"
## Véhicule d'intervention contre le braconnage : 4x4 des gardes forestiers (maison
## forestière) ou voiture de police (commissariat), avec 2 agents.
##
## Comme les drones, il EXÉCUTE des commandes (cmd_dispatch, cmd_recall) ; c'est
## l'orchestrateur qui l'engage sur alerte d'un drone de surveillance.
##   POSTE -> ROUTE (gyrophares, guidé par la position que transmet le drone ; sirènes coupées
##   à l'approche pour surprendre les braconniers, rallumées s'ils s'enfuient)
##   -> PIED (les agents poursuivent les braconniers à pied, menottent, ramènent)
##   -> ROUTE (si les braconniers repartent) ... -> RETOUR -> POSTE (garde à vue)
## Face à une camionnette en fuite : la police cherche à lui couper la route (elle vise
## la sortie de la carte vers laquelle elle roule), les gardes la suivent. Un véhicule
## d'intervention à moins de 22 m d'une camionnette en fuite fait barrage.
## Face à des fuyards à pied : la police se place sur la piste devant eux, dans la direction
## de leur fuite ; les agents ne courent qu'après un braconnier à moins de 80 m, sinon ils
## remontent en voiture pour se replacer (poursuite par bonds).

const CUFF_TIME := 2.5
const FOOT_RANGE := 80.0        # m : au-delà, les agents remontent en voiture pour se replacer devant
const QUIET_RANGE := 350.0      # m : approche discrète, sirènes coupées près des braconniers

var service := "garde"          # garde | police
var home := Vector2.ZERO        # place de stationnement
var home_heading := Vector2(0, 1)
var home_leg: Array = []        # points entre la place et le réseau (Vector2)
var entry_node := -1            # nœud du réseau au bout de home_leg
var manager: Node3D
var van: Node3D = null          # braconniers poursuivis
var goal_node := -1
var retarget_t := 0.0
var recalled := false
var prisoners: Array = []       # braconniers menottés à bord
var escort := {}                # agent -> braconnier menotté qu'il ramène
var cuff_t := {}                # agent -> temps de menottage restant
var foot_t := 0.0


func _ready() -> void:
	role = service
	var bar_y := 1.98
	var bar_z := -0.6
	if service == "police":   # berline blanche comme celles du commissariat, bande bleue
		build_car()
		for sx in [-0.93, 0.93]:
			box(body, Vector3(0.03, 0.16, 3.0), Vector3(sx, 0.62, 0.0), Look.plastic(Color(0.06, 0.14, 0.45), 0.4))
		label.modulate = Color(0.6, 0.75, 1.0)
		bar_y = 1.52
		bar_z = 0.3
	else:
		build_pickup(Color(0.12, 0.3, 0.14))
		box(body, Vector3(1.92, 0.12, 2.4), Vector3(0, 1.15, -0.05), Look.plastic(Color(0.9, 0.75, 0.2), 0.4))   # bande jaune
		label.modulate = Color(0.6, 0.95, 0.55)
	box(body, Vector3(1.2, 0.12, 0.3), Vector3(0, bar_y, bar_z), Look.plastic(Color(0.1, 0.1, 0.1), 0.5))      # rampe lumineuse
	for x in [-0.4, 0.4]:
		beacons.append(box(body, Vector3(0.38, 0.16, 0.26), Vector3(x, bar_y + 0.12, bar_z), emissive(Color(0.15, 0.35, 1.0), 9.0)))


func speed_for(kind: String) -> float:
	if service == "police":
		return {"city": 14.0, "track": 12.0, "exit": 12.0}.get(kind, 5.0)
	return {"city": 12.0, "track": 11.5, "exit": 11.5}.get(kind, 5.0)


func crew_labels_visible() -> bool:
	return state != "POSTE"


func info() -> Dictionary:
	return {"unit_id": drone_id, "service": service, "state": state, "prisoners": prisoners.size()}


func is_available() -> bool:
	return state == "POSTE" or state == "RETOUR"


# ------------------------------------------------------------ commandes

func cmd_dispatch(target_van: Node3D) -> void:
	van = target_van
	recalled = false
	goal_node = -1
	retarget_t = 0.0
	siren = true
	match state:
		"POSTE":
			route = _route_from_home(_pursuit_node())
			state = "ROUTE"
		"RETOUR":
			state = "ROUTE"


func cmd_recall() -> void:
	recalled = true


func _route_from_home(to: int) -> Array:
	var r: Array = []
	for p in home_leg:
		r.append([p, "offroad"])
	for id in net.path(entry_node, to):
		r.append([net.nodes[id], net.kinds[id]])
	return r


func _route_home() -> Array:
	var r := path_to_node(entry_node)
	for k in range(home_leg.size() - 1, -1, -1):
		r.append([home_leg[k], "offroad"])
	r.append([home, "offroad"])
	return r


# ------------------------------------------------------------ simulation

func _physics_process(dt: float) -> void:
	if dt <= 0.0:
		return
	moving = false
	match state:
		"ROUTE":
			_pursue(dt)
		"PIED":
			_on_foot(dt)
		"RETOUR":
			if drive(dt):
				_arrive_home()
	animate_beacons(dt)
	label.visible = GameState.show_labels and state != "POSTE"
	label.text = "%s%s" % [drone_id, (" · %d interpellé(s)" % prisoners.size()) if not prisoners.is_empty() else ""]


func _go_home() -> void:
	route = _route_home()
	state = "RETOUR"
	siren = false


## Nœud visé : la police coupe la route d'une camionnette en fuite (sortie qu'elle vise),
## sinon on rejoint la piste la plus proche de la dernière position transmise par le drone.
func _pursuit_node() -> int:
	var known = manager.known_position(van)
	if van.fleeing == "vehicule" and not van.route.is_empty():
		if service == "police":
			return net.nearest_node(van.route[van.route.size() - 1][0], ["exit"])
		return net.nearest_node(van.pos2(), ["track", "exit"])
	if known == null:
		return net.nearest_node(van.pos2(), ["track", "exit"])
	var p := Vector2(known.x, known.z)
	if van.fleeing == "pied" and service == "police":
		# couper la route : un point de la piste devant les fuyards, vers le bord qu'ils visent
		var m = _nearest_free(INF, p)
		if m != null and van.flee_goal.has(m):
			var mp := Vector2(m.global_position.x, m.global_position.z)
			var g: Vector2 = van.flee_goal[m]
			p = mp + (g - mp).normalized() * minf(110.0, mp.distance_to(g) * 0.6)
	return net.nearest_node(p, ["track", "exit"])


func _pursue(dt: float) -> void:
	if van == null or van.is_over():
		_go_home()
		return
	if van.fleeing == "vehicule" and van.state == "FUITE" and pos2().distance_to(van.pos2()) < 22.0:
		van.abandon("barrage de %s" % drone_id)
	# gyrophares et deux-tons pour traverser la ville, coupés à l'approche pour les surprendre
	var known = manager.known_position(van)
	var close: bool = known != null and pos2().distance_to(Vector2(known.x, known.z)) < QUIET_RANGE
	siren = not close or van.fleeing != ""
	retarget_t -= dt
	if retarget_t <= 0.0:
		retarget_t = 1.5
		var n := _pursuit_node()
		if n != goal_node and n >= 0:
			goal_node = n
			var r := path_to_node(n)
			if not r.is_empty():
				route = r
	var arrived := drive(dt)
	# braconniers à pied à portée : on roule jusqu'au plus près, puis les agents descendent et courent
	if _nearest_free(FOOT_RANGE if arrived else 30.0) != null:
		_deploy()


func _deploy() -> void:
	stop()
	state = "PIED"
	foot_t = 0.0
	for k in crew.size():
		crew[k].alight(door(k))
	manager.on_units_on_site(self)


## Braconnier libre, à pied (visible), le plus proche de p (ou du véhicule).
func _nearest_free(r: float, from = null):
	var p: Vector2 = from if from != null else pos2()
	var best = null
	var bd := r
	for m in van.free_members():
		if m.aboard or not m.visible:
			continue
		var d := p.distance_to(Vector2(m.global_position.x, m.global_position.z))
		if d < bd:
			bd = d
			best = m
	return best


func _on_foot(dt: float) -> void:
	foot_t -= dt
	var think := foot_t <= 0.0
	if think:
		foot_t = 0.3
	var busy := false
	for k in crew.size():
		var f = crew[k]
		if f.aboard:
			continue
		busy = true
		if escort.has(f):
			_escort_step(f, k, dt)
			continue
		if not think:
			continue
		var fp := Vector2(f.global_position.x, f.global_position.z)
		var m = _nearest_free(FOOT_RANGE, fp) if van else null
		if m == null:
			# personne à portée : retour au véhicule en courant (pour se replacer ou rentrer)
			if fp.distance_to(pos2()) < 3.2:
				f.board()
			elif Vector2(f.goal.x, f.goal.z).distance_to(Vector2(door(k).x, door(k).z)) > 1.0 or f.state == "IDLE":
				f.go_to(door(k), true)
			continue
		var mp := Vector2(m.global_position.x, m.global_position.z)
		if fp.distance_to(mp) < 1.6:
			m.arrest()
			f.cuff(m.global_position)
			escort[f] = m
			cuff_t[f] = CUFF_TIME
			manager.on_arrest(self, f, m)
		else:
			f.go_to(Vector3(mp.x, 0.0, mp.y), true)
	if not busy:
		# tout le monde à bord : on repart (camionnette en fuite) ou on rentre
		if recalled or van == null or van.is_over():
			_go_home()
		else:
			goal_node = -1
			retarget_t = 0.0
			siren = true
			state = "ROUTE"


## Menottage puis escorte du braconnier jusqu'au véhicule.
func _escort_step(f, k: int, dt: float) -> void:
	var m = escort[f]
	if cuff_t.get(f, 0.0) > 0.0:
		cuff_t[f] -= dt
		if cuff_t[f] <= 0.0:
			f.go_to(door(k), false)
		return
	var fp := Vector2(f.global_position.x, f.global_position.z)
	var mp := Vector2(m.global_position.x, m.global_position.z)
	if mp.distance_to(fp) > 1.3:
		var behind := fp - (fp - mp).normalized() * 1.0
		m.go_to(Vector3(behind.x, 0.0, behind.y), false)
	if fp.distance_to(pos2()) < 3.2:
		m.board()
		prisoners.append(m)
		escort.erase(f)
		cuff_t.erase(f)
		f.idle()
	elif f.state == "IDLE":
		f.go_to(door(k), false)


func _arrive_home() -> void:
	heading = home_heading
	place(home)
	stop()
	state = "POSTE"
	siren = false
	if not prisoners.is_empty():
		manager.on_prisoners_delivered(self, prisoners.size())
		prisoners.clear()   # placés en garde à vue (ils restent masqués)
	van = null
