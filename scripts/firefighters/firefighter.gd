extends Node3D
const Look := preload("res://scripts/render/look.gd")
## Pompier : se déplace à pied (marche / course), monte et descend du camion,
## déroule son tuyau depuis la pompe du camion (le tuyau reste posé au sol le long
## de son trajet, plat quand il est vide, gonflé une fois en eau), et attaque le feu
## à la lance : jet d'eau, éclaboussures à l'impact, vapeur sur les foyers.
##
## Le pompier ne décide pas de sa mission : c'est son camion (chef d'agrès) qui
## lui donne ses ordres (go_to, board, spray_at...).

const WALK := 1.4
const RUN := 3.8
const HOSE_SEG := 1.2           # un point de tuyau posé tous les 1,2 m
const HOSE_MAX := 90            # segments au plus (tuyau de ~100 m)
const REWIND_SPEED := 5.0       # m/s : enroulement par le dévidoir

var person_name := "Pompier"
var role := "équipier"         # conducteur | chef d'agrès | équipier
var truck: Node3D = null
var state := "IDLE"            # IDLE, MOVING, ABOARD, AIMING, SPRAYING, PUMP
var goal := Vector3.ZERO
var move_speed := WALK
var pause_t := 0.0
var phase := 0.0
var aboard := false
var spray_target = null        # Vector3 visé par la lance
var wander_zones: Array = []   # zones de la caserne où il circule au repos (Rect2)
var pump_face := Vector3.ZERO  # tableau de pompe que regarde le conducteur
# tuyau
var hose_on := false
var hose_rewind := false
var hose_charged := false      # en eau (gonflé)
var hose_pts: Array = []       # points posés au sol ; le premier est le raccord sur le camion
var hose_left := 0.0           # longueur restant à enrouler
var hose_drawn := 0.0          # longueur affichée (pour faire tourner le dévidoir)
var hose_mm: MultiMesh
var splash: CPUParticles3D
var steam: CPUParticles3D
var steam_cd := 0.0
var rng := RandomNumberGenerator.new()

var body: Node3D
var legs: Array[Node3D] = []
var arms: Array[Node3D] = []
var nozzle: MeshInstance3D
var jet: CPUParticles3D
var label: Label3D


func _ready() -> void:
	_build_visual()
	goal = global_position


# ------------------------------------------------------------ ordres

func go_to(p: Vector3, running: bool = false) -> void:
	goal = p
	move_speed = RUN if running else WALK
	state = "MOVING"
	pause_t = 0.0
	stop_spray()


func board() -> void:
	aboard = true
	visible = false
	state = "ABOARD"
	stop_spray()
	hose_on = false
	hose_pts.clear()
	_hide_hose()


func alight(at: Vector3) -> void:
	aboard = false
	visible = true
	global_position = at
	goal = at
	state = "IDLE"


func arrived() -> bool:
	return Vector2(global_position.x - goal.x, global_position.z - goal.z).length() < 0.6


func spray_at(target: Vector3) -> void:
	spray_target = target
	state = "SPRAYING"
	nozzle.visible = true
	jet.emitting = true
	splash.emitting = true


## Lance en main, pointée sur la cible, en attendant la mise en eau.
func aim_at(target: Vector3) -> void:
	spray_target = target
	state = "AIMING"
	nozzle.visible = true
	jet.emitting = false
	splash.emitting = false
	steam.emitting = false


func stop_spray() -> void:
	spray_target = null
	if nozzle:
		nozzle.visible = false
		jet.emitting = false
		splash.emitting = false
		steam.emitting = false


## Conducteur : reste au tableau de pompe du camion.
func work_pump(face: Vector3) -> void:
	pump_face = face
	state = "PUMP"
	stop_spray()


# ------------------------------------------------------------ tuyau

## Raccorde un tuyau sur la sortie de pompe `outlet` : il se déroule ensuite derrière lui.
func attach_hose(outlet: Vector3) -> void:
	hose_on = true
	hose_rewind = false
	hose_charged = false
	hose_pts = [outlet, _hose_ground(global_position)]


## Lâche le tuyau : le dévidoir l'enroule depuis l'extrémité, qui revient vers le camion.
func release_hose() -> void:
	if not hose_on or hose_rewind:
		return
	hose_rewind = true
	hose_charged = false
	hose_pts.append(_hose_ground(global_position))
	hose_left = _polyline_len(hose_pts)


func _hose_ground(p: Vector3) -> Vector3:
	return Vector3(p.x, _ground_y(p.x, p.z) + 0.07, p.z)


func _polyline_len(pts: Array) -> float:
	var l := 0.0
	for i in range(1, pts.size()):
		l += (pts[i] as Vector3).distance_to(pts[i - 1])
	return l


## Appelé par le camion à chaque pas : pose / enroule le tuyau et le redessine.
func update_hose(outlet: Vector3, dt: float) -> void:
	if not hose_on:
		hose_drawn = 0.0
		return
	hose_pts[0] = outlet
	if hose_rewind:
		hose_left -= REWIND_SPEED * dt
		if hose_left <= 0.0:
			hose_on = false
			hose_rewind = false
			hose_pts.clear()
			hose_drawn = 0.0
			_hide_hose()
			return
		_draw_hose(hose_pts, hose_left)
		return
	# le tuyau se pose derrière lui ; s'il revient sur ses pas, il est ramené (pas de boucle)
	var feet := _hose_ground(global_position)
	if hose_pts.size() > 2 and feet.distance_to(hose_pts[hose_pts.size() - 2]) < HOSE_SEG * 0.75:
		hose_pts.pop_back()
	elif feet.distance_to(hose_pts[hose_pts.size() - 1]) > HOSE_SEG and hose_pts.size() < HOSE_MAX:
		hose_pts.append(feet)
	# extrémité : du sol jusqu'à la lance tenue à deux mains
	var hand := global_position + global_transform.basis * Vector3(0, 1.05, -0.35)
	var pts := hose_pts.duplicate()
	pts.append(feet)
	pts.append(hand)
	_draw_hose(pts, INF)


func _draw_hose(pts: Array, limit: float) -> void:
	var n := 0
	var acc := 0.0
	var w := 0.13 if hose_charged else 0.12
	var h := 0.13 if hose_charged else 0.035   # tuyau plat à vide, rond en eau
	for i in range(1, pts.size()):
		if n >= hose_mm.instance_count or acc >= limit:
			break
		var a: Vector3 = pts[i - 1]
		var b: Vector3 = pts[i]
		var d := b - a
		var l := d.length()
		if l < 0.05:
			continue
		if acc + l > limit:
			l = limit - acc
			b = a + d.normalized() * l
			d = b - a
		acc += l
		var dir := d / l
		var up := Vector3.UP if absf(dir.y) < 0.98 else Vector3.FORWARD
		hose_mm.set_instance_transform(n, Transform3D(Basis.looking_at(dir, up) * Basis.from_scale(Vector3(w, h, l + 0.06)), a + d * 0.5))
		n += 1
	hose_mm.visible_instance_count = n
	hose_drawn = acc


func _hide_hose() -> void:
	if hose_mm:
		hose_mm.visible_instance_count = 0
	hose_drawn = 0.0


func idle() -> void:
	state = "IDLE"
	stop_spray()


# ------------------------------------------------------------ simulation

func _ground_y(x: float, z: float) -> float:
	var y: float = GameState.terrain.height_at(x, z)
	if GameState.fire_service and GameState.fire_service.on_station(Vector2(x, z)):
		y = maxf(y, GameState.fire_service.APRON_TOP)
	return y


func _physics_process(dt: float) -> void:
	if aboard or dt <= 0.0:
		return
	var pos := global_position
	var moving := false
	match state:
		"MOVING":
			var to := Vector2(goal.x - pos.x, goal.z - pos.z)
			if to.length() > 0.3:
				var step := minf(move_speed * dt, to.length())
				var d := to.normalized()
				pos.x += d.x * step
				pos.z += d.y * step
				rotation.y = lerp_angle(rotation.y, atan2(-d.x, -d.y), clampf(dt * 8.0, 0.0, 1.0))
				moving = true
			else:
				state = "IDLE"
		"IDLE":
			# au repos à la caserne : petits déplacements dans la cour
			if not wander_zones.is_empty() and truck and truck.at_station():
				pause_t -= dt
				if pause_t <= 0.0:
					var z: Rect2 = wander_zones[rng.randi() % wander_zones.size()]
					var p := Vector2(rng.randf_range(z.position.x, z.end.x), rng.randf_range(z.position.y, z.end.y))
					goal = Vector3(p.x, 0.0, p.y)
					move_speed = WALK
					state = "MOVING"
					pause_t = rng.randf_range(4.0, 10.0)
		"SPRAYING", "AIMING":
			if spray_target != null:
				var t: Vector3 = spray_target
				var d := Vector2(t.x - pos.x, t.z - pos.z)
				rotation.y = lerp_angle(rotation.y, atan2(-d.x, -d.y), clampf(dt * 6.0, 0.0, 1.0))
				if state == "SPRAYING":
					_aim_jet(t)
					_update_impact(t, dt)
		"PUMP":
			var d2 := Vector2(pump_face.x - pos.x, pump_face.z - pos.z)
			if d2.length() > 0.1:
				rotation.y = lerp_angle(rotation.y, atan2(-d2.x, -d2.y), clampf(dt * 6.0, 0.0, 1.0))
			phase += dt * 2.0
	pos.y = _ground_y(pos.x, pos.z)
	global_position = pos
	_animate(dt, moving)


func _aim_jet(t: Vector3) -> void:
	var from := jet.global_position
	var dist := Vector2(t.x - from.x, t.z - from.z).length()
	# visée en cloche : on vise au-dessus de la cible pour que le jet retombe dessus
	var aim := Vector3(t.x, t.y + dist * 0.45, t.z)
	if from.distance_to(aim) > 0.5:
		jet.look_at(aim, Vector3.UP)
	jet.initial_velocity_min = clampf(sqrt(dist * 13.2), 6.0, 22.0)   # tir à ~24° : v = sqrt(g.d / sin 48°)
	jet.initial_velocity_max = jet.initial_velocity_min * 1.1


## Point d'impact : éclaboussures, et vapeur tant que la cible brûle encore.
func _update_impact(t: Vector3, dt: float) -> void:
	var gy := _ground_y(t.x, t.z)
	splash.global_position = Vector3(t.x, gy + 0.3, t.z)
	steam.global_position = Vector3(t.x, gy + 1.0, t.z)
	steam_cd -= dt
	if steam_cd <= 0.0:
		steam_cd = 0.5
		var burning: bool = GameState.fire != null and not GameState.fire.burning_near(t, 6.0).is_empty()
		steam.emitting = burning


func _animate(dt: float, moving: bool) -> void:
	var swing := 0.0
	if moving:
		phase += dt * move_speed * 4.0
		swing = sin(phase) * (0.7 if move_speed > 2.0 else 0.45)
	for k in legs.size():
		legs[k].rotation.x = swing if k == 0 else -swing
	if state == "SPRAYING" or state == "AIMING":
		for a in arms:
			a.rotation.x = -1.2   # bras tendus vers l'avant, tenant la lance
	elif state == "PUMP":
		for k in arms.size():   # mains sur les vannes du tableau de pompe
			arms[k].rotation.x = -0.95 + sin(phase + k * 1.7) * 0.12
	else:
		for k in arms.size():
			arms[k].rotation.x = -swing * 0.8 if k == 0 else swing * 0.8


# ------------------------------------------------------------ visuel

func _mat(c: Color, emission: float = 0.0) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.roughness = 0.7
	if emission > 0.0:
		m.emission_enabled = true
		m.emission = c
		m.emission_energy_multiplier = emission
	return m


func _part(parent: Node3D, mesh: Mesh, pos: Vector3, mat: Material) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = mat
	mi.position = pos
	parent.add_child(mi)
	return mi


func _box(sz: Vector3) -> BoxMesh:
	var b := BoxMesh.new()
	b.size = sz
	return b


func _build_visual() -> void:
	rng.seed = hash(person_name)
	body = Node3D.new()
	body.scale = Vector3.ONE * rng.randf_range(0.97, 1.05)   # taille réelle (~1,75 m)
	add_child(body)
	var navy := _mat(Color(0.035, 0.045, 0.09))        # tenue de feu bleu marine
	navy.roughness = 0.85
	var reflect := _mat(Color(0.75, 0.7, 0.3), 0.25)    # bandes rétroréfléchissantes
	var dark := _mat(Color(0.02, 0.02, 0.02))
	# veste de feu + bandes réfléchissantes
	_part(body, _box(Vector3(0.48, 0.62, 0.3)), Vector3(0, 1.2, 0), navy)
	_part(body, _box(Vector3(0.5, 0.06, 0.32)), Vector3(0, 1.05, 0), reflect)
	_part(body, _box(Vector3(0.5, 0.06, 0.32)), Vector3(0, 1.32, 0), reflect)
	# tête + casque F1 (rouge pour le chef d'agrès, chromé/jaune sinon)
	var head := SphereMesh.new()
	head.radius = 0.12
	head.height = 0.24
	_part(body, head, Vector3(0, 1.65, 0), _mat(Color(0.9, 0.72, 0.58)))
	var helmet := SphereMesh.new()
	helmet.radius = 0.16
	helmet.height = 0.22
	helmet.is_hemisphere = true
	var hcol := Color(0.85, 0.12, 0.1) if role == "chef d'agrès" else Color(0.95, 0.8, 0.15)
	_part(body, helmet, Vector3(0, 1.7, 0), _mat(hcol, 0.15))
	# jambes et bras articulés aux hanches / épaules
	for k in 2:
		var hip := Node3D.new()
		hip.position = Vector3(-0.12 if k == 0 else 0.12, 0.88, 0)
		body.add_child(hip)
		_part(hip, _box(Vector3(0.17, 0.88, 0.2)), Vector3(0, -0.44, 0), navy)
		_part(hip, _box(Vector3(0.19, 0.06, 0.22)), Vector3(0, -0.6, 0), reflect)
		_part(hip, _box(Vector3(0.19, 0.12, 0.28)), Vector3(0, -0.84, -0.04), dark)
		legs.append(hip)
		var sh := Node3D.new()
		sh.position = Vector3(-0.31 if k == 0 else 0.31, 1.45, 0)
		body.add_child(sh)
		_part(sh, _box(Vector3(0.13, 0.58, 0.14)), Vector3(0, -0.28, 0), navy)
		arms.append(sh)
	# lance à incendie (visible pendant l'attaque)
	var lance := CylinderMesh.new()
	lance.top_radius = 0.035
	lance.bottom_radius = 0.06
	lance.height = 0.7
	nozzle = _part(body, lance, Vector3(0, 1.15, -0.5), _mat(Color(0.75, 0.75, 0.78)))
	nozzle.rotation_degrees.x = -80.0
	nozzle.visible = false
	# jet d'eau
	jet = CPUParticles3D.new()
	jet.amount = 320
	jet.lifetime = 1.5
	jet.emitting = false
	jet.local_coords = false
	jet.direction = Vector3(0, 0, -1)
	jet.spread = 2.5
	jet.initial_velocity_min = 12.0
	jet.initial_velocity_max = 13.0
	jet.gravity = Vector3(0, -9.8, 0)
	jet.scale_amount_min = 0.5
	jet.scale_amount_max = 1.0
	var jc := Curve.new()   # jet compact à la lance, qui s'ouvre en pluie en retombant
	jc.add_point(Vector2(0, 0.55))
	jc.add_point(Vector2(1, 1.9))
	jet.scale_amount_curve = jc
	var drop := SphereMesh.new()
	drop.radius = 0.12
	drop.height = 0.24
	drop.radial_segments = 6
	drop.rings = 3
	var wm := StandardMaterial3D.new()
	wm.albedo_color = Color(0.7, 0.85, 1.0, 0.7)
	wm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	wm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	drop.material = wm
	jet.mesh = drop
	jet.position = Vector3(0, 1.55, -0.95)
	add_child(jet)
	# éclaboussures au point d'impact
	splash = CPUParticles3D.new()
	splash.top_level = true
	splash.amount = 90
	splash.lifetime = 0.9
	splash.emitting = false
	splash.emission_shape = CPUParticles3D.EMISSION_SHAPE_SPHERE
	splash.emission_sphere_radius = 1.6
	splash.direction = Vector3.UP
	splash.spread = 55.0
	splash.initial_velocity_min = 2.0
	splash.initial_velocity_max = 4.5
	splash.gravity = Vector3(0, -9.8, 0)
	splash.scale_amount_min = 0.35
	splash.scale_amount_max = 0.8
	splash.mesh = drop
	add_child(splash)
	# vapeur : l'eau qui touche les braises
	steam = CPUParticles3D.new()
	steam.top_level = true
	steam.amount = 40
	steam.lifetime = 3.2
	steam.emitting = false
	steam.emission_shape = CPUParticles3D.EMISSION_SHAPE_SPHERE
	steam.emission_sphere_radius = 2.0
	steam.direction = Vector3.UP
	steam.spread = 20.0
	steam.initial_velocity_min = 1.2
	steam.initial_velocity_max = 2.4
	steam.gravity = Vector3(0, 0.4, 0)
	steam.damping_min = 0.3
	steam.damping_max = 0.6
	var sc := Curve.new()
	sc.add_point(Vector2(0, 0.6))
	sc.add_point(Vector2(1, 3.0))
	steam.scale_amount_curve = sc
	var sg := Gradient.new()
	sg.set_color(0, Color(1, 1, 1, 0.55))
	sg.set_color(1, Color(0.9, 0.9, 0.92, 0.0))
	steam.color_ramp = sg
	var puff := SphereMesh.new()
	puff.radius = 0.7
	puff.height = 1.4
	puff.radial_segments = 8
	puff.rings = 4
	var pm := StandardMaterial3D.new()
	pm.vertex_color_use_as_albedo = true
	pm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	pm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	puff.material = pm
	steam.mesh = puff
	add_child(steam)
	# tuyau : segments posés au sol (MultiMesh en coordonnées monde)
	hose_mm = MultiMesh.new()
	hose_mm.transform_format = MultiMesh.TRANSFORM_3D
	hose_mm.mesh = BoxMesh.new()
	hose_mm.instance_count = HOSE_MAX + 4
	hose_mm.visible_instance_count = 0
	var hmi := MultiMeshInstance3D.new()
	hmi.name = "Hose"
	hmi.top_level = true
	hmi.multimesh = hose_mm
	hmi.material_override = Look.plastic(Color(0.86, 0.83, 0.72), 0.75)
	hmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	hmi.extra_cull_margin = 200.0
	add_child(hmi)
	label = Label3D.new()
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.fixed_size = true
	label.pixel_size = 0.0005
	label.font_size = 24
	label.outline_size = 6
	label.modulate = Color(1.0, 0.85, 0.6)
	label.text = person_name
	label.position = Vector3(0, 2.8, 0)
	label.visible = false
	add_child(label)
