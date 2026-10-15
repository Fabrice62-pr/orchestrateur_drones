extends Node3D
## Pompier : se déplace à pied (marche / course), monte et descend du camion,
## et attaque le feu à la lance (jet d'eau réel : il éteint les cellules visées).
##
## Le pompier ne décide pas de sa mission : c'est son camion (chef d'agrès) qui
## lui donne ses ordres (go_to, board, spray_at...).

const WALK := 1.4
const RUN := 3.8

var person_name := "Pompier"
var role := "équipier"         # conducteur | chef d'agrès | équipier
var truck: Node3D = null
var state := "IDLE"            # IDLE, MOVING, ABOARD, SPRAYING
var goal := Vector3.ZERO
var move_speed := WALK
var pause_t := 0.0
var phase := 0.0
var aboard := false
var spray_target = null        # Vector3 visé par la lance
var wander_zones: Array = []   # zones de la caserne où il circule au repos (Rect2)
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


func stop_spray() -> void:
	spray_target = null
	if nozzle:
		nozzle.visible = false
		jet.emitting = false


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
		"SPRAYING":
			if spray_target != null:
				var t: Vector3 = spray_target
				var d := Vector2(t.x - pos.x, t.z - pos.z)
				rotation.y = lerp_angle(rotation.y, atan2(-d.x, -d.y), clampf(dt * 6.0, 0.0, 1.0))
				_aim_jet(t)
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
	jet.initial_velocity_min = clampf(dist * 0.95, 6.0, 18.0)
	jet.initial_velocity_max = jet.initial_velocity_min * 1.1


func _animate(dt: float, moving: bool) -> void:
	var swing := 0.0
	if moving:
		phase += dt * move_speed * 4.0
		swing = sin(phase) * (0.7 if move_speed > 2.0 else 0.45)
	for k in legs.size():
		legs[k].rotation.x = swing if k == 0 else -swing
	if state == "SPRAYING":
		for a in arms:
			a.rotation.x = -1.2   # bras tendus vers l'avant, tenant la lance
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
	jet.amount = 140
	jet.lifetime = 1.6
	jet.emitting = false
	jet.local_coords = false
	jet.direction = Vector3(0, 0, -1)
	jet.spread = 4.0
	jet.initial_velocity_min = 12.0
	jet.initial_velocity_max = 13.0
	jet.gravity = Vector3(0, -9.8, 0)
	jet.scale_amount_min = 0.5
	jet.scale_amount_max = 1.1
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
