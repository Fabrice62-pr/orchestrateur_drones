extends Node3D
const Look := preload("res://scripts/render/look.gd")
## Personnage à pied : bûcheron, braconnier, garde forestier ou policier (tenue `outfit`).
## Marche / court, monte et descend de son véhicule, travaille à la tronçonneuse
## (sciure), porte une grume sur l'épaule, replante à genoux, menotte ou est menotté.
##
## Il ne décide pas de sa mission : son véhicule lui donne ses ordres
## (go_to, board, saw, carry, plant, cuff, arrest...).

const WALK := 1.6
const RUN := 3.6

var person_name := "Bûcheron"
var outfit := "bucheron"        # bucheron | braconnier | garde | policier
var role := "abatteur"          # abatteur (tronçonneuse) | débardeur | agent
var truck: Node3D = null        # véhicule de rattachement
var state := "IDLE"             # IDLE, MOVING, ABOARD, SAW, PLANT, CUFF
var goal := Vector3.ZERO
var move_speed := WALK
var run_speed := RUN
var phase := 0.0
var aboard := false
var carrying := false
var cuffed := false             # menotté (mains dans le dos)
var escaped := false            # sorti de la carte (fuite réussie)
var face_target = null          # Vector3 regardé pendant le travail
var rng := RandomNumberGenerator.new()

var body: Node3D
var legs: Array[Node3D] = []
var arms: Array[Node3D] = []
var chainsaw: Node3D
var log_on_shoulder: MeshInstance3D
var sawdust: CPUParticles3D
var label: Label3D


func _ready() -> void:
	_build_visual()
	goal = global_position


# ------------------------------------------------------------ ordres

func go_to(p: Vector3, running: bool = false) -> void:
	goal = p
	move_speed = run_speed if running and not cuffed else WALK
	state = "MOVING"
	_tool(false)


func board() -> void:
	aboard = true
	visible = false
	state = "ABOARD"
	_tool(false)
	set_carrying(false)


func alight(at: Vector3) -> void:
	aboard = false
	visible = true
	global_position = at
	goal = at
	state = "IDLE"


func arrived() -> bool:
	return Vector2(global_position.x - goal.x, global_position.z - goal.z).length() < 0.6


## Tronçonneuse en marche, lame contre le bois (abattage ou tronçonnage).
func saw(target: Vector3) -> void:
	face_target = target
	state = "SAW"
	_tool(true)


## Plantation d'un jeune arbre : à genoux face au trou.
func plant(target: Vector3) -> void:
	face_target = target
	state = "PLANT"
	_tool(false)


## Agent qui passe les menottes à la personne devant lui.
func cuff(target: Vector3) -> void:
	face_target = target
	state = "CUFF"
	_tool(false)


## Interpellé : s'arrête, lâche tout, mains dans le dos.
func arrest() -> void:
	cuffed = true
	state = "IDLE"
	goal = global_position
	_tool(false)
	set_carrying(false)


func idle() -> void:
	state = "IDLE"
	_tool(false)


func set_carrying(on: bool) -> void:
	carrying = on
	if log_on_shoulder:
		log_on_shoulder.visible = on


func _tool(on: bool) -> void:
	if sawdust:
		sawdust.emitting = on
	if chainsaw:
		chainsaw.visible = role == "abatteur" and not aboard and not cuffed


# ------------------------------------------------------------ simulation

func _ground_y(x: float, z: float) -> float:
	if GameState.lumber:
		return GameState.lumber.ground_y(x, z)
	return GameState.terrain.height_at(x, z)


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
		"SAW", "PLANT", "CUFF":
			if face_target != null:
				var t: Vector3 = face_target
				var d2 := Vector2(t.x - pos.x, t.z - pos.z)
				if d2.length() > 0.1:
					rotation.y = lerp_angle(rotation.y, atan2(-d2.x, -d2.y), clampf(dt * 6.0, 0.0, 1.0))
			phase += dt * (14.0 if state == "SAW" else 3.0)
	pos.y = _ground_y(pos.x, pos.z)
	global_position = pos
	_animate(dt, moving)


func _animate(dt: float, moving: bool) -> void:
	var swing := 0.0
	if moving:
		phase += dt * move_speed * 4.0
		swing = sin(phase) * (0.7 if move_speed > 2.0 else 0.45)
	var kneel := state == "PLANT"
	body.position.y = lerpf(body.position.y, -0.42 if kneel else 0.0, clampf(dt * 6.0, 0.0, 1.0))
	for k in legs.size():
		if kneel:
			legs[k].rotation.x = -1.4 if k == 0 else 0.1   # un genou à terre
		else:
			legs[k].rotation.x = swing if k == 0 else -swing
	if cuffed:
		for k in arms.size():   # mains menottées dans le dos
			arms[k].rotation.x = 0.55
			arms[k].rotation.z = 0.25 if k == 0 else -0.25
	elif state == "SAW":
		for k in arms.size():   # bras tendus sur les poignées, vibrations de la machine
			arms[k].rotation.x = -0.9 + sin(phase) * 0.03
	elif state == "PLANT":
		for k in arms.size():   # mains au sol : tasse la terre autour du plant
			arms[k].rotation.x = -0.6 + sin(phase + k * PI) * 0.25
	elif state == "CUFF":
		for k in arms.size():   # mains en avant, à hauteur de taille
			arms[k].rotation.x = -0.7 + sin(phase + k * 1.3) * 0.12
	elif carrying:
		arms[0].rotation.x = -2.6   # main sur la grume posée sur l'épaule
		arms[1].rotation.x = -swing * 0.8
	else:
		for k in arms.size():
			arms[k].rotation.x = -swing * 0.8 if k == 0 else swing * 0.8
	label.visible = GameState.show_labels and truck != null and truck.crew_labels_visible()


# ------------------------------------------------------------ visuel

func _mat(c: Color, rough := 0.75) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.roughness = rough
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


## Couleurs de la tenue : [haut, bas, couvre-chef, détail].
func _palette() -> Array:
	match outfit:
		"braconnier":   # veste kaki sombre ou camouflage, bonnet noir
			return [[Color(0.2, 0.23, 0.13), Color(0.16, 0.14, 0.1), Color(0.12, 0.13, 0.1)][rng.randi() % 3],
				Color(0.08, 0.08, 0.08), Color(0.04, 0.04, 0.04), Color(0.3, 0.27, 0.18)]
		"garde":        # chemise kaki, pantalon vert, chapeau vert, insigne doré
			return [Color(0.56, 0.5, 0.32), Color(0.13, 0.22, 0.12), Color(0.15, 0.28, 0.15), Color(0.85, 0.7, 0.2)]
		"policier":     # chemise bleu clair, gilet et pantalon bleu nuit, casquette
			return [Color(0.55, 0.66, 0.82), Color(0.05, 0.08, 0.18), Color(0.04, 0.06, 0.15), Color(0.95, 0.95, 0.95)]
	return [[Color(0.55, 0.07, 0.05), Color(0.12, 0.3, 0.12), Color(0.1, 0.16, 0.38)][rng.randi() % 3],
		Color(0.12, 0.17, 0.3), Color(0.95, 0.42, 0.04), Color(0.95, 0.42, 0.04)]


func _build_visual() -> void:
	rng.seed = hash(person_name)
	body = Node3D.new()
	body.scale = Vector3.ONE * rng.randf_range(0.97, 1.06)
	add_child(body)
	var pal := _palette()
	var top := _mat(pal[0])
	var bottom := _mat(pal[1], 0.85)
	var hat := _mat(pal[2], 0.5)
	var detail := _mat(pal[3], 0.45)
	var dark := _mat(Color(0.03, 0.03, 0.03), 0.8)
	_part(body, _box(Vector3(0.48, 0.62, 0.3)), Vector3(0, 1.2, 0), top)
	match outfit:
		"bucheron":   # chemise à carreaux + bretelles de salopette anti-coupure
			for y in [1.02, 1.2, 1.38]:
				_part(body, _box(Vector3(0.5, 0.04, 0.32)), Vector3(0, y, 0), dark)
			for x in [-0.12, 0.12]:
				_part(body, _box(Vector3(0.06, 0.62, 0.32)), Vector3(x, 1.2, 0), detail)
		"policier":   # gilet tactique, bande blanche dans le dos
			_part(body, _box(Vector3(0.5, 0.42, 0.33)), Vector3(0, 1.26, 0), bottom)
			_part(body, _box(Vector3(0.4, 0.07, 0.02)), Vector3(0, 1.3, 0.17), detail)
		"garde":      # insigne et ceinturon
			_part(body, _box(Vector3(0.08, 0.08, 0.02)), Vector3(-0.12, 1.36, -0.16), detail)
			_part(body, _box(Vector3(0.5, 0.06, 0.32)), Vector3(0, 0.93, 0), dark)
	var head := SphereMesh.new()
	head.radius = 0.12
	head.height = 0.24
	_part(body, head, Vector3(0, 1.65, 0), _mat([Color(0.85, 0.66, 0.52), Color(0.6, 0.42, 0.3), Color(0.35, 0.22, 0.14)][rng.randi() % 3]))
	var dome := SphereMesh.new()
	dome.radius = 0.15 if outfit == "bucheron" else 0.135
	dome.height = 0.2 if outfit == "bucheron" else 0.17
	dome.is_hemisphere = true
	_part(body, dome, Vector3(0, 1.71, 0), hat)
	match outfit:
		"bucheron":   # coquilles anti-bruit et visière grillagée
			for x in [-0.15, 0.15]:
				_part(body, _box(Vector3(0.05, 0.1, 0.1)), Vector3(x, 1.64, 0), dark)
			_part(body, _box(Vector3(0.26, 0.12, 0.02)), Vector3(0, 1.64, -0.15), _mat(Color(0.2, 0.2, 0.2), 0.4))
		"garde":      # chapeau à large bord
			var brim := CylinderMesh.new()
			brim.top_radius = 0.24
			brim.bottom_radius = 0.24
			brim.height = 0.02
			_part(body, brim, Vector3(0, 1.72, 0), hat)
		"policier":   # visière de casquette
			_part(body, _box(Vector3(0.2, 0.02, 0.1)), Vector3(0, 1.72, -0.15), dark)
	# jambes et bras articulés aux hanches / épaules
	for k in 2:
		var hip := Node3D.new()
		hip.position = Vector3(-0.12 if k == 0 else 0.12, 0.88, 0)
		body.add_child(hip)
		var leg_mat := detail if outfit == "bucheron" and role == "abatteur" else bottom
		_part(hip, _box(Vector3(0.17, 0.88, 0.2)), Vector3(0, -0.44, 0), leg_mat)
		_part(hip, _box(Vector3(0.19, 0.12, 0.28)), Vector3(0, -0.84, -0.04), dark)
		legs.append(hip)
		var sh := Node3D.new()
		sh.position = Vector3(-0.31 if k == 0 else 0.31, 1.45, 0)
		body.add_child(sh)
		_part(sh, _box(Vector3(0.13, 0.58, 0.14)), Vector3(0, -0.28, 0), top)
		arms.append(sh)
	# tronçonneuse (abatteur) : carter orange, guide-chaîne vers l'avant
	chainsaw = Node3D.new()
	chainsaw.position = Vector3(0.0, 0.95, -0.42)
	body.add_child(chainsaw)
	var saw_col := Color(0.95, 0.42, 0.04) if outfit == "bucheron" else Color(0.75, 0.12, 0.06)
	_part(chainsaw, _box(Vector3(0.22, 0.24, 0.42)), Vector3.ZERO, _mat(saw_col, 0.45))
	_part(chainsaw, _box(Vector3(0.04, 0.09, 0.75)), Vector3(0, -0.02, -0.55), _mat(Color(0.6, 0.62, 0.64), 0.3))
	_part(chainsaw, _box(Vector3(0.26, 0.03, 0.03)), Vector3(0, 0.15, -0.08), dark)
	chainsaw.visible = role == "abatteur"
	# grume portée sur l'épaule
	var lm := CylinderMesh.new()
	lm.top_radius = 0.17
	lm.bottom_radius = 0.19
	lm.height = 2.4
	lm.radial_segments = 10
	log_on_shoulder = _part(body, lm, Vector3(-0.22, 1.62, 0), Look.pbr("bark", 1.2, Color(0.75, 0.65, 0.55)))
	log_on_shoulder.rotation_degrees.x = 90.0
	log_on_shoulder.visible = false
	# sciure projetée par la chaîne
	sawdust = CPUParticles3D.new()
	sawdust.amount = 60
	sawdust.lifetime = 0.8
	sawdust.emitting = false
	sawdust.local_coords = false
	sawdust.direction = Vector3(0, 0.4, 1)
	sawdust.spread = 35.0
	sawdust.initial_velocity_min = 2.0
	sawdust.initial_velocity_max = 4.0
	sawdust.gravity = Vector3(0, -6.0, 0)
	sawdust.scale_amount_min = 0.5
	sawdust.scale_amount_max = 1.0
	var grain := BoxMesh.new()
	grain.size = Vector3(0.04, 0.04, 0.04)
	var gm := StandardMaterial3D.new()
	gm.albedo_color = Color(0.86, 0.74, 0.52)
	gm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	grain.material = gm
	sawdust.mesh = grain
	sawdust.position = Vector3(0, 0.9, -1.1)
	add_child(sawdust)
	label = Label3D.new()
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.fixed_size = true
	label.pixel_size = 0.0005
	label.font_size = 24
	label.outline_size = 6
	label.modulate = {"braconnier": Color(1.0, 0.45, 0.4), "garde": Color(0.6, 0.95, 0.55),
		"policier": Color(0.6, 0.75, 1.0)}.get(outfit, Color(0.95, 0.85, 0.55))
	label.text = person_name
	label.position = Vector3(0, 2.8, 0)
	label.visible = false
	add_child(label)
