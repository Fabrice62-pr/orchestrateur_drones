extends Node3D
## Drone simulé : machine à états + vol cinématique.
##
## Le drone ne prend PAS de décisions de mission : il exécute les commandes
## (cmd_*) envoyées par l'orchestrateur et publie des événements sur l'EventBus
## (fire_detected, fire_report, tank_empty, refill_done, battery_low,
## arrived_base, drone_ready, arrived). Ce sont les règles d'automatisation qui
## décident quoi faire de ces événements.
##
## États : IDLE, CHARGING, STARTING, PATROL, ORBIT, OBSERVE, TRANSIT, FIGHTING, GO_REFILL,
##         REFILLING, RETURN_BASE, HOLD, GOTO
## STARTING : mise en route au sol (moteurs) avant tout décollage depuis la base.

var drone_id := "DRONE"
var role := "action"          # "surveillance" ou "action"
var state := "IDLE"
var home := Vector3.ZERO
var patrol_points: Array = []

var battery := 100.0
var water := 0
var max_water := 12
var velocity := Vector3.ZERO

# paramètres (surchargés par data/config.json, section "drone")
var max_speed := 24.0
var accel := 14.0
var cruise_alt := 85.0
var work_alt := 14.0
var drain := 0.3
var drain_fighting := 0.45
var battery_low_level := 25.0
var charge_rate := 10.0
var drop_radius := 9.0
var drop_cooldown := 1.0
var refill_time := 3.0
var detect_radius := 90.0
var startup_time := 3.0       # secondes de mise en route avant décollage

var fire_target := Vector3.ZERO
var cell_target = null
var orbit_center := Vector3.ZERO
var orbit_angle := 0.0
var patrol_index := 0
var hold_pos := Vector3.ZERO
var goto_target := Vector3.ZERO
var goal := Vector3.ZERO
var wait_t := 0.0
var drop_cd := 0.0
var retarget_cd := 0.0
var detect_cd := 0.0
var report_cd := 0.0
var label_cd := 0.0
var low_battery_sent := false
var pending_state := ""       # état visé à la fin de la mise en route

var body: Node3D
var rotors: Array[Node3D] = []
var label: Label3D
var spray: CPUParticles3D
var prop_discs: Array[MeshInstance3D] = []
var beam: MeshInstance3D
var ring: MeshInstance3D
var strobe: MeshInstance3D
var blink_t := 0.0
var orbit_radius := 45.0
var fire_lost_t := 0.0        # temps passé en orbite sans voir de feu
var fire_lost_sent := false
# encombrement physique (calculé depuis la taille du modèle) : sert aux collisions
var radius := 7.0             # rayon horizontal (bras + protections d'hélices)
var bottom := 2.6             # distance centre -> point le plus bas (train, buse)
const SAFETY := 1.0           # marge minimale avec le décor (m)
var distance_boost_max := 1.5   # grossissement max quand la caméra est loin (lisibilité)
var fpv_hidden := false    # vrai quand la caméra est embarquée sur ce drone (modèle masqué)
var visual_scale := 2.6   # taille d'affichage (data/config.json -> drone.visual_scale)


func _ready() -> void:
	_load_params()
	water = max_water if role == "action" else 0
	goal = home
	_build_visual()
	radius = 2.65 * visual_scale
	bottom = (1.0 if role == "action" else 0.8) * visual_scale
	home.y += bottom - 0.6   # posé sur le plot, train d'atterrissage au contact


func _load_params() -> void:
	max_speed = float(GameState.cfgv("drone", "max_speed", max_speed))
	accel = float(GameState.cfgv("drone", "accel", accel))
	cruise_alt = float(GameState.cfgv("drone", "cruise_altitude", cruise_alt))
	work_alt = float(GameState.cfgv("drone", "work_altitude", work_alt))
	drain = float(GameState.cfgv("drone", "battery_drain", drain))
	drain_fighting = float(GameState.cfgv("drone", "battery_drain_fighting", drain_fighting))
	battery_low_level = float(GameState.cfgv("drone", "battery_low", battery_low_level))
	charge_rate = float(GameState.cfgv("drone", "charge_rate", charge_rate))
	max_water = int(GameState.cfgv("drone", "water_capacity", max_water))
	drop_radius = float(GameState.cfgv("drone", "drop_radius", drop_radius))
	drop_cooldown = float(GameState.cfgv("drone", "drop_cooldown", drop_cooldown))
	refill_time = float(GameState.cfgv("drone", "refill_time", refill_time))
	detect_radius = float(GameState.cfgv("drone", "detect_radius", detect_radius))
	startup_time = float(GameState.cfgv("drone", "startup_time", startup_time))


# ------------------------------------------------------------- commandes

## Passe à l'état demandé ; au sol, passe d'abord par la mise en route des moteurs.
func _start(next_state: String) -> void:
	if state == "STARTING":
		pending_state = next_state
		return
	if (state == "IDLE" or state == "CHARGING") and startup_time > 0.0:
		pending_state = next_state
		state = "STARTING"
		wait_t = startup_time
		EventBus.log_msg("%s : mise en route des moteurs (%.1f s)" % [drone_id, startup_time])
		return
	state = next_state


func cmd_patrol() -> void:
	_start("PATROL")


func cmd_orbit(center: Vector3) -> void:
	orbit_center = center
	fire_lost_t = 0.0
	fire_lost_sent = false
	_start("ORBIT")


## Vol stationnaire au-dessus du feu pour l'observer (le drone qui l'a détecté
## attend l'arrivée des drones d'action).
func cmd_observe(center: Vector3) -> void:
	orbit_center = center
	fire_lost_t = 0.0
	fire_lost_sent = false
	_start("OBSERVE")


func cmd_fight(zone: Vector3) -> void:
	if role != "action":
		EventBus.log_msg("%s n'est pas un drone d'action" % drone_id, "warn")
		return
	fire_target = zone
	if water <= 0:
		state = "HOLD"
		hold_pos = global_position
		EventBus.emit_event("tank_empty", info())
		return
	_start("TRANSIT")


func cmd_refill() -> void:
	if role == "action":
		_start("GO_REFILL")


func cmd_return_base() -> void:
	if state != "IDLE" and state != "CHARGING":
		state = "RETURN_BASE"


func cmd_hold() -> void:
	hold_pos = global_position
	state = "HOLD"


func cmd_goto(target: Vector3) -> void:
	goto_target = target
	_start("GOTO")


func info() -> Dictionary:
	return {"drone_id": drone_id, "role": role, "state": state, "battery": int(battery), "water": water}


# ------------------------------------------------------------- simulation

func _physics_process(delta: float) -> void:
	if delta <= 0.0:
		return
	drop_cd -= delta
	_update_battery(delta)
	match state:
		"IDLE", "CHARGING":
			goal = home
			if state == "CHARGING":
				_charge(delta)
		"STARTING":
			goal = home
			wait_t -= delta
			if wait_t <= 0.0:
				state = pending_state
				pending_state = ""
				EventBus.emit_event("takeoff", info())
		"PATROL":
			_do_patrol()
		"ORBIT":
			orbit_angle += delta * 0.22 * 45.0 / orbit_radius
			goal = Vector3(orbit_center.x + cos(orbit_angle) * orbit_radius, 0.0, orbit_center.z + sin(orbit_angle) * orbit_radius)
			goal.y = _ground(goal) + 55.0
		"OBSERVE":
			# point fixe à la verticale du foyer, hauteur d'observation
			goal = Vector3(orbit_center.x, 0.0, orbit_center.z)
			goal.y = _ground(goal) + 55.0
		"TRANSIT":
			goal = fire_target
			goal.y = _ground(fire_target) + 30.0
			if _hdist(global_position, fire_target) < 40.0:
				state = "FIGHTING"
				retarget_cd = 0.0
				var data := info()
				data["position"] = [snappedf(fire_target.x, 0.1), snappedf(fire_target.y, 0.1), snappedf(fire_target.z, 0.1)]
				EventBus.emit_event("fire_engaged", data)   # drone d'action sur zone
		"FIGHTING":
			_do_fight(delta)
		"GO_REFILL":
			goal = _lake_point()
			if global_position.distance_to(goal) < 5.0:
				state = "REFILLING"
				wait_t = refill_time
		"REFILLING":
			goal = _lake_point()
			wait_t -= delta
			water = int(lerpf(float(max_water), float(water), clampf(wait_t / refill_time, 0.0, 1.0)))
			if wait_t <= 0.0:
				water = max_water
				hold_pos = global_position
				state = "HOLD"
				EventBus.emit_event("refill_done", info())
		"RETURN_BASE":
			goal = home
			if global_position.distance_to(home) < 1.5:
				state = "CHARGING"
				velocity = Vector3.ZERO
				EventBus.emit_event("arrived_base", info())
		"HOLD":
			goal = hold_pos
		"GOTO":
			goal = goto_target
			if global_position.distance_to(goto_target) < 4.0:
				hold_pos = goto_target
				state = "HOLD"
				EventBus.emit_event("arrived", info())
	_fly(delta)
	if role == "surveillance":
		_detect(delta)
	_animate(delta)


func _ground(p: Vector3) -> float:
	return GameState.terrain.height_at(p.x, p.z)


func _hdist(a: Vector3, b: Vector3) -> float:
	return Vector2(a.x - b.x, a.z - b.z).length()


## Point de remplissage : le point d'eau (lac ou bassin DFCI) le plus proche ;
## chaque drone d'action a sa place autour, pour ne pas se gêner.
func _lake_point() -> Vector3:
	var best: Array = []
	var bd := INF
	for wp in GameState.terrain.water_points():
		var c: Vector3 = wp[0]
		var d := _hdist(global_position, c)
		if d < bd:
			bd = d
			best = wp
	var center: Vector3 = best[0]
	var r: float = best[1]
	var k := 0
	for o in GameState.drones:
		if o == self:
			break
		if o.role == "action":
			k += 1
	var a := k * TAU / 6.0
	return Vector3(center.x + cos(a) * r, center.y + bottom + 2.5, center.z + sin(a) * r)


func _update_battery(delta: float) -> void:
	if state == "IDLE" or state == "CHARGING":
		return
	battery -= (drain_fighting if state == "FIGHTING" else drain) * delta
	if battery <= battery_low_level and not low_battery_sent:
		low_battery_sent = true
		EventBus.emit_event("battery_low", info())
	if battery <= 0.0:
		battery = 0.0
		if state != "RETURN_BASE":
			state = "RETURN_BASE"
			EventBus.log_msg("%s : batterie épuisée, retour forcé" % drone_id, "warn")


func _charge(delta: float) -> void:
	battery = minf(100.0, battery + charge_rate * delta)
	if role == "action":
		water = max_water
	if battery >= 100.0:
		state = "IDLE"
		low_battery_sent = false
		EventBus.emit_event("drone_ready", info())


func _do_patrol() -> void:
	if patrol_points.is_empty():
		goal = home
		return
	var p: Vector3 = patrol_points[patrol_index % patrol_points.size()]
	goal = Vector3(p.x, maxf(cruise_alt, _ground(p) + 55.0), p.z)
	if _hdist(global_position, p) < 10.0:
		patrol_index = (patrol_index + 1) % patrol_points.size()


func _do_fight(delta: float) -> void:
	retarget_cd -= delta
	if retarget_cd <= 0.0:
		retarget_cd = 0.6
		var avoid: Array = []
		for o in GameState.drones:
			if o != self and o.role == "action" and o.state == "FIGHTING" and o.cell_target != null:
				avoid.append(o.cell_target)
		# confinement : les drones ne peuvent pas éteindre, ils ralentissent le front
		cell_target = GameState.fire.find_contain_target(global_position, avoid)
	if cell_target == null:
		goal = fire_target
		goal.y = _ground(fire_target) + 30.0
		return
	var ct: Vector3 = cell_target
	goal = ct + Vector3.UP * work_alt
	goal.y = maxf(goal.y, min_alt(ct.x, ct.z))
	if _hdist(global_position, ct) < 5.0 and absf(global_position.y - goal.y) < 6.0 and drop_cd <= 0.0:
		_drop(ct)


func _drop(ct: Vector3) -> void:
	drop_cd = drop_cooldown
	water -= 1
	if spray:
		spray.restart()
		spray.emitting = true
	GameState.fire.apply_water(ct, drop_radius, false)   # ralentit le feu, ne l'éteint pas
	cell_target = null
	retarget_cd = 0.0
	if water <= 0:
		water = 0
		hold_pos = global_position
		state = "HOLD"
		EventBus.emit_event("tank_empty", info())


func _detect(delta: float) -> void:
	if not (state in ["PATROL", "ORBIT", "OBSERVE", "HOLD", "GOTO"]):
		return
	detect_cd -= delta
	if detect_cd > 0.0:
		return
	detect_cd = 0.5
	# en orbite on observe depuis le centre du cercle : c'est la zone surveillée
	var focused := state == "ORBIT" or state == "OBSERVE"
	var eye := orbit_center if focused else global_position
	var seen: Array = GameState.fire.burning_near(eye, detect_radius)
	if seen.is_empty():
		# feu perdu de vue (foyer éteint ici mais incendie ailleurs) : on le signale
		if focused and GameState.orchestrator.fire_known:
			fire_lost_t += 0.5
			if fire_lost_t >= 6.0 and not fire_lost_sent:
				fire_lost_sent = true
				EventBus.emit_event("fire_lost", info())
		return
	var c: Vector3 = GameState.fire.centroid_of(seen)
	if state == "OBSERVE":
		# reste au-dessus du foyer : ne se décale que si le feu dérive (vent)
		fire_lost_t = 0.0
		fire_lost_sent = false
		if _hdist(orbit_center, c) > 15.0:
			orbit_center = orbit_center.lerp(c, 0.2)
	if state == "ORBIT":
		# le drone reste focalisé sur la zone en feu : le cercle suit le foyer et s'adapte à sa taille
		fire_lost_t = 0.0
		fire_lost_sent = false
		orbit_center = orbit_center.lerp(c, 0.25)
		var extent := 0.0
		for q in seen:
			extent = maxf(extent, Vector2(q.x - c.x, q.z - c.z).length())
		orbit_radius = lerpf(orbit_radius, clampf(extent + 25.0, 30.0, 65.0), 0.2)
	var data := info()
	data["position"] = [snappedf(c.x, 0.1), snappedf(c.y, 0.1), snappedf(c.z, 0.1)]
	data["intensity"] = seen.size()
	var orch = GameState.orchestrator
	if not orch.fire_known:
		report_cd = 10.0
		EventBus.emit_event("fire_detected", data)
	elif state == "PATROL" and _hdist(c, orch.fire_position) > 100.0 and not _observed_by_other(c):
		# nouveau foyer, loin de l'incendie déjà connu et que personne ne surveille
		report_cd = 10.0
		EventBus.emit_event("fire_detected", data)
	else:
		report_cd -= 0.5
		if report_cd <= 0.0:
			report_cd = 10.0
			EventBus.emit_event("fire_report", data)


func _observed_by_other(p: Vector3) -> bool:
	for o in GameState.drones:
		if o != self and (o.state == "OBSERVE" or o.state == "ORBIT") and _hdist(o.orbit_center, p) < 90.0:
			return true
	return false


## Altitude minimale du centre du drone au-dessus d'un point : rien du décor
## (relief, eau, immeubles, arbres) ne doit se trouver sous son encombrement.
func min_alt(x: float, z: float) -> float:
	return GameState.terrain.obstacle_top(x, z, radius) + bottom + SAFETY


func is_grounded() -> bool:
	return state == "IDLE" or state == "CHARGING" or state == "STARTING"


func _fly(delta: float) -> void:
	var pos := global_position
	var to := goal - pos
	var hd := Vector2(to.x, to.z).length()
	var target := goal
	if hd > 30.0:
		target.y = maxf(cruise_alt, goal.y)
	var d := target - pos
	var dist := d.length()
	var desired := Vector3.ZERO
	if dist > 0.05:
		desired = d / dist * minf(max_speed, dist * 1.2)
	# priorité à la montée : on franchit l'altitude de croisière avant d'avancer (évite les immeubles)
	if hd > 30.0 and pos.y < cruise_alt - 8.0:
		desired.x *= 0.3
		desired.z *= 0.3
		desired.y = maxf(desired.y, 8.0)
	var grounded := is_grounded()
	var near_home := pos.distance_to(home) < 8.0

	if not grounded:
		# anticipation du décor : on regarde devant soi et on monte avant l'obstacle
		var hv := Vector2(desired.x, desired.z)
		if hv.length() > 0.5 and not near_home:
			var dir := hv.normalized()
			var look := clampf(hv.length() * 1.5 + radius, 8.0, 50.0)
			var need := -INF
			var sdist := 0.5   # dès le pas suivant : un obstacle sur le côté compte aussi
			while sdist <= look:
				need = maxf(need, min_alt(pos.x + dir.x * sdist, pos.z + dir.y * sdist))
				sdist = 3.0 if sdist < 3.0 else sdist + 3.0
			if need > pos.y - 0.5:
				desired.y = maxf(desired.y, minf((need - pos.y) * 2.0 + 4.0, max_speed))
				if need > pos.y + 2.0:
					desired.x *= 0.15   # on freine : on passe par-dessus, pas au travers
					desired.z *= 0.15
		# évitement anticipé des autres drones
		for o in GameState.drones:
			if o == self:
				continue
			var off: Vector3 = pos - o.global_position
			var l := off.length()
			var keep: float = (radius + o.radius) * 1.4
			if l < keep and l > 0.01:
				desired += off / l * (keep - l) * 1.5
				# départage des face-à-face : l'un monte, l'autre reste
				if drone_id < o.drone_id:
					desired.y += (keep - l) * 0.6

	velocity = velocity.move_toward(desired, accel * delta)
	var new_pos := pos + velocity * delta

	if not grounded:
		# contrainte stricte drone/drone : les volumes ne se chevauchent jamais
		for o in GameState.drones:
			if o == self:
				continue
			var off: Vector3 = new_pos - o.global_position
			var l := off.length()
			var min_d: float = radius + o.radius + SAFETY
			if l < min_d:
				var n: Vector3 = off / l if l > 0.01 else Vector3.UP
				# un drone posé ne bouge pas : celui qui vole fait tout l'écart
				new_pos += n * (min_d - l) * (1.0 if o.is_grounded() else 0.5)
				var vn := velocity.dot(n)
				if vn < 0.0:
					velocity -= n * vn   # on annule la vitesse dirigée vers l'autre drone

	# contrainte stricte drone/décor : jamais sous l'altitude minimale
	var floor_new := min_alt(new_pos.x, new_pos.z)
	if near_home or new_pos.distance_to(home) < 8.0:
		floor_new = minf(floor_new, home.y)   # atterrissage sur le plot de la base
	if new_pos.y < floor_new:
		var floor_here := min_alt(pos.x, pos.z)
		if pos.distance_to(home) < 8.0:
			floor_here = minf(floor_here, home.y)
		if new_pos.y < floor_new - 0.01 and floor_new > floor_here + 0.5 and pos.y >= floor_here - 0.01:
			# le pas horizontal entrerait dans un obstacle (façade, cime) : on reste sur place et on monte
			new_pos.x = pos.x
			new_pos.z = pos.z
			velocity.x = 0.0
			velocity.z = 0.0
			velocity.y = maxf(velocity.y, 6.0)   # bloqué : on monte obligatoirement, jamais coincé
			new_pos.y = maxf(new_pos.y, pos.y + velocity.y * delta)
			floor_new = floor_here
		if new_pos.y < floor_new:
			new_pos.y = floor_new
			velocity.y = maxf(velocity.y, 0.0)
	global_position = new_pos


func _animate(delta: float) -> void:
	var spin := 6.0 if (state == "IDLE" or state == "CHARGING") else 45.0
	if state == "STARTING" and startup_time > 0.0:
		spin = lerpf(6.0, 45.0, clampf(1.0 - wait_t / startup_time, 0.0, 1.0))
	for r in rotors:
		r.rotate_y(spin * delta)
	for disc in prop_discs:
		disc.visible = spin > 10.0
	var local := global_transform.basis.inverse() * velocity
	body.rotation.x = lerpf(body.rotation.x, clampf(local.z * 0.02, -0.35, 0.35), clampf(delta * 4.0, 0.0, 1.0))
	body.rotation.z = lerpf(body.rotation.z, clampf(-local.x * 0.02, -0.35, 0.35), clampf(delta * 4.0, 0.0, 1.0))
	if Vector2(velocity.x, velocity.z).length() > 2.0:
		rotation.y = lerp_angle(rotation.y, atan2(-velocity.x, -velocity.z), clampf(delta * 3.0, 0.0, 1.0))
	label_cd -= delta
	if label_cd <= 0.0:
		label_cd = 0.25
		var txt := "%s · %d%%" % [drone_id, int(battery)]
		if role == "action":
			txt += " · eau %d/%d" % [water, max_water]
		label.text = txt


## Mise à l'échelle selon la distance caméra : le drone garde une taille lisible
## même vu de loin, et reste à taille « réelle » quand on s'approche.
func _process(delta: float) -> void:
	var cam := get_viewport().get_camera_3d()
	var k := 1.0
	if cam:
		k = clampf(global_position.distance_to(cam.global_position) / 90.0, 1.0, distance_boost_max)
	body.scale = Vector3.ONE * visual_scale * k
	# le grossissement de lisibilité ne doit pas faire « rentrer » le drone dans le sol
	body.position.y = (k - 1.0) * bottom
	label.position.y = (1.6 * visual_scale * k) + 2.0
	# repère au sol : faisceau vertical + anneau sous le drone
	var gy := _ground(global_position)
	var h := maxf(global_position.y - gy, 0.1)
	beam.global_position = Vector3(global_position.x, gy + h * 0.5, global_position.z)
	beam.scale = Vector3(k, h, k)
	# taille réelle : de loin le drone ne fait que quelques pixels -> repères pour le situer
	var far_cam := cam != null and global_position.distance_to(cam.global_position) > 90.0
	beam.visible = h > 6.0 and not fpv_hidden and far_cam
	ring.global_position = Vector3(global_position.x, gy + 0.3, global_position.z)
	ring.scale = Vector3.ONE * k
	ring.visible = h > 3.0 and not fpv_hidden and far_cam
	label.visible = not fpv_hidden and not is_grounded() and GameState.show_labels
	# feux de navigation clignotants
	blink_t += delta if delta > 0.0 else 0.016
	strobe.visible = fmod(blink_t, 1.0) < 0.12


# ------------------------------------------------------------- visuel

func _mat(c: Color, emission: float = 0.0, rough := 0.45) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.roughness = rough
	m.metallic = 0.15
	if emission > 0.0:
		m.emission_enabled = true
		m.emission = c
		m.emission_energy_multiplier = emission
	return m


func _mesh(parent: Node3D, mesh: Mesh, pos: Vector3, mat: Material, rot_deg: Vector3 = Vector3.ZERO) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = mat
	mi.position = pos
	mi.rotation_degrees = rot_deg
	parent.add_child(mi)
	return mi


func _box(parent: Node3D, size: Vector3, pos: Vector3, c: Color) -> MeshInstance3D:
	var bm := BoxMesh.new()
	bm.size = size
	return _mesh(parent, bm, pos, _mat(c))


func _cyl(r_top: float, r_bot: float, h: float, seg: int = 12) -> CylinderMesh:
	var cm := CylinderMesh.new()
	cm.top_radius = r_top
	cm.bottom_radius = r_bot
	cm.height = h
	cm.radial_segments = seg
	cm.rings = 1
	return cm


func _sphere(r: float, hgt: float) -> SphereMesh:
	var s := SphereMesh.new()
	s.radius = r
	s.height = hgt
	s.radial_segments = 16
	s.rings = 8
	return s


func _build_visual() -> void:
	visual_scale = float(GameState.cfgv("drone", "visual_scale", visual_scale))
	distance_boost_max = maxf(1.0, float(GameState.cfgv("drone", "distance_boost_max", distance_boost_max)))
	if role == "surveillance":
		# drone d'observation plus léger que les drones d'action (pas de réservoir)
		visual_scale *= float(GameState.cfgv("drone", "surveillance_scale", 0.6))
	body = Node3D.new()
	body.scale = Vector3.ONE * visual_scale
	add_child(body)
	var main_col := Color(0.12, 0.42, 0.95) if role == "surveillance" else Color(0.92, 0.26, 0.12)
	var accent := Color(0.08, 0.2, 0.5) if role == "surveillance" else Color(0.55, 0.12, 0.04)
	var dark_mat := _mat(Color(0.035, 0.035, 0.04), 0.0, 0.45)          # fibre de carbone
	var white_mat := _mat(Color(0.62, 0.63, 0.64), 0.0, 0.35)           # coque plastique
	var main_mat := _mat(accent, 0.0, 0.3)                              # liseré de couleur

	# fuselage : coque arrondie + capot + bande de couleur lumineuse
	_mesh(body, _sphere(0.75, 0.55), Vector3.ZERO, white_mat).scale = Vector3(1.0, 1.0, 1.35)
	_mesh(body, _sphere(0.55, 0.4), Vector3(0, 0.2, -0.1), main_mat).scale = Vector3(1.0, 1.0, 1.3)
	_mesh(body, _cyl(0.78, 0.78, 0.08, 24), Vector3(0, -0.02, 0), main_mat).scale = Vector3(1.0, 1.0, 1.35)

	# 4 bras, moteurs, hélices (pales + disque de flou en rotation)
	var disc_mat := StandardMaterial3D.new()
	disc_mat.albedo_color = Color(0.2, 0.2, 0.22, 0.12)   # flou d'hélice discret
	disc_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	disc_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	disc_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	for k in 4:
		var ang := deg_to_rad(45.0 + 90.0 * k)
		var dir := Vector3(sin(ang), 0, cos(ang))
		var arm := _mesh(body, _cyl(0.07, 0.09, 1.6, 8), dir * 0.95 + Vector3(0, 0.05, 0), dark_mat)
		arm.look_at_from_position(arm.position, arm.position + dir, Vector3.UP)
		arm.rotate_object_local(Vector3.RIGHT, PI * 0.5)
		var hub_pos := dir * 1.75
		_mesh(body, _cyl(0.17, 0.2, 0.32), hub_pos + Vector3(0, 0.12, 0), dark_mat)
		_mesh(body, _cyl(0.05, 0.05, 0.12, 6), hub_pos + Vector3(0, 0.33, 0), white_mat)
		var rotor := Node3D.new()
		rotor.position = hub_pos + Vector3(0, 0.36, 0)
		body.add_child(rotor)
		var blade := BoxMesh.new()
		blade.size = Vector3(1.5, 0.025, 0.12)
		_mesh(rotor, blade, Vector3.ZERO, dark_mat, Vector3(0, 0, 4))
		rotors.append(rotor)
		var disc := _mesh(body, _cyl(0.78, 0.78, 0.01, 24), hub_pos + Vector3(0, 0.37, 0), disc_mat)
		prop_discs.append(disc)
		# protection d'hélice (anneau)
		var guard := TorusMesh.new()
		guard.inner_radius = 0.8
		guard.outer_radius = 0.86
		guard.rings = 24
		guard.ring_segments = 6
		_mesh(body, guard, hub_pos + Vector3(0, 0.36, 0), dark_mat)

	# train d'atterrissage
	for sx in [-0.5, 0.5]:
		_mesh(body, _cyl(0.04, 0.04, 1.5, 6), Vector3(sx, -0.6, 0), dark_mat, Vector3(90, 0, 0))
		_mesh(body, _cyl(0.03, 0.03, 0.4, 6), Vector3(sx, -0.42, 0.35), dark_mat, Vector3(0, 0, sx * -30.0))
		_mesh(body, _cyl(0.03, 0.03, 0.4, 6), Vector3(sx, -0.42, -0.35), dark_mat, Vector3(0, 0, sx * -30.0))

	# feux de navigation : rouge à gauche, vert à droite, flash blanc à l'arrière
	_mesh(body, _sphere(0.09, 0.18), Vector3(-0.72, 0.0, -0.6), _mat(Color(1, 0.1, 0.1), 6.0))
	_mesh(body, _sphere(0.09, 0.18), Vector3(0.72, 0.0, -0.6), _mat(Color(0.1, 1, 0.2), 6.0))
	strobe = _mesh(body, _sphere(0.11, 0.22), Vector3(0, 0.3, 0.95), _mat(Color(1, 1, 1), 12.0))

	if role == "action":
		# réservoir d'eau + buse
		_mesh(body, _cyl(0.4, 0.4, 0.55, 16), Vector3(0, -0.5, 0), _mat(Color(0.2, 0.45, 0.85), 0.2))
		_mesh(body, _cyl(0.06, 0.1, 0.25, 8), Vector3(0, -0.88, 0), dark_mat)
		spray = CPUParticles3D.new()
		spray.one_shot = true
		spray.emitting = false
		spray.amount = 90
		spray.lifetime = 1.4
		spray.explosiveness = 0.6
		spray.local_coords = false
		spray.direction = Vector3(0, -1, 0)
		spray.spread = 18.0
		spray.initial_velocity_min = 8.0
		spray.initial_velocity_max = 14.0
		spray.gravity = Vector3(0, -9.8, 0)
		spray.scale_amount_min = 0.8
		spray.scale_amount_max = 1.6
		var wm := StandardMaterial3D.new()
		wm.albedo_color = Color(0.55, 0.75, 1.0, 0.75)
		wm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		wm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		var sm := _sphere(0.25, 0.5)
		sm.radial_segments = 6
		sm.rings = 3
		sm.material = wm
		spray.mesh = sm
		spray.position = Vector3(0, -2.0, 0)
		add_child(spray)
	else:
		# nacelle caméra + projecteur
		_mesh(body, _cyl(0.06, 0.06, 0.2, 6), Vector3(0, -0.38, -0.55), dark_mat)
		_mesh(body, _sphere(0.22, 0.44), Vector3(0, -0.55, -0.55), dark_mat)
		_mesh(body, _cyl(0.1, 0.1, 0.06, 12), Vector3(0, -0.55, -0.76), _mat(Color(0.2, 0.5, 1.0), 3.0), Vector3(90, 0, 0))
		var spot := SpotLight3D.new()
		spot.rotation_degrees.x = -90.0
		spot.spot_range = 140.0
		spot.spot_angle = 30.0
		spot.light_energy = 3.0
		spot.light_color = Color(0.8, 0.9, 1.0)
		add_child(spot)

	# repères au sol (top_level : ne suivent pas la rotation du drone)
	var beam_mat := StandardMaterial3D.new()
	beam_mat.albedo_color = Color(main_col.r, main_col.g, main_col.b, 0.35)
	beam_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	beam_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	beam = _mesh(self, _cyl(0.12, 0.12, 1.0, 6), Vector3.ZERO, beam_mat)
	beam.top_level = true
	beam.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var torus := TorusMesh.new()
	torus.inner_radius = 3.2
	torus.outer_radius = 3.8
	torus.rings = 32
	torus.ring_segments = 4
	var ring_mat := StandardMaterial3D.new()
	ring_mat.albedo_color = Color(main_col.r, main_col.g, main_col.b, 0.75)
	ring_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	ring_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	ring = _mesh(self, torus, Vector3.ZERO, ring_mat)
	ring.top_level = true
	ring.scale = Vector3.ONE
	ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF

	label = Label3D.new()
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.no_depth_test = false   # masquée par les immeubles et le relief (réalisme)
	label.fixed_size = true
	label.pixel_size = 0.0007
	label.font_size = 28
	label.outline_size = 8
	label.modulate = main_col.lightened(0.5)
	label.position = Vector3(0, 6.0, 0)
	add_child(label)
