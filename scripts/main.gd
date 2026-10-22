extends Node3D
## Point d'entrée : génère le monde, crée les drones et branche tous les systèmes.
##
##   Terrain / Ville / Forêt  -> monde procédural (graine)
##   Drones                   -> exécutent des commandes, publient des événements
##   EventBus                 -> canal d'événements commun
##   Orchestrator             -> règles d'automatisation (JSON, modifiables en jeu)
##   ScenarioDirector         -> automatisations de la carte (chronologie JSON)
##   ExternalBridge           -> WebSocket vers un orchestrateur externe (n8n, Python)
##   HUD                      -> supervision + éditeur de règles
##   LumberCamp               -> scierie, grumiers et bûcherons (arbres de prairie uniquement)
##   Poaching                 -> braconniers en forêt protégée, gardes forestiers et police

const TerrainScript := preload("res://scripts/world/terrain.gd")
const CityScript := preload("res://scripts/world/city.gd")
const ForestScript := preload("res://scripts/world/forest.gd")
const DroneScript := preload("res://scripts/drones/drone.gd")
const OrchestratorScript := preload("res://scripts/orchestration/orchestrator.gd")
const DirectorScript := preload("res://scripts/orchestration/scenario_director.gd")
const BridgeScript := preload("res://scripts/orchestration/external_bridge.gd")
const HudScript := preload("res://scripts/ui/hud.gd")
const CameraScript := preload("res://scripts/camera/free_camera.gd")
const NetworkScript := preload("res://scripts/world/road_network.gd")
const CityLifeScript := preload("res://scripts/world/city_life.gd")
const ForestParkScript := preload("res://scripts/world/forest_park.gd")
const RangerStationScript := preload("res://scripts/world/ranger_station.gd")
const StationScript := preload("res://scripts/firefighters/fire_station.gd")
const LumberCampScript := preload("res://scripts/lumber/lumber_camp.gd")
const PoachingScript := preload("res://scripts/poaching/poaching.gd")
const AtmosphereScript := preload("res://scripts/render/atmosphere.gd")
const Look := preload("res://scripts/render/look.gd")

const SPEEDS := [0.5, 1.0, 2.0, 4.0, 8.0]

var terrain: Node3D
var forest: Node3D
var orchestrator: Node
var hud: CanvasLayer
var camera: Camera3D
var sun: DirectionalLight3D
var atmosphere: Node3D
var rain_fx: CPUParticles3D
var snow_fx: CPUParticles3D
var home_positions: Array = []
var pending_click = null
var speed_index := 1


func _ready() -> void:
	GameState.reset_runtime()
	Engine.time_scale = 1.0
	var s: int = GameState.seed_value
	_setup_environment()

	terrain = TerrainScript.new()
	terrain.name = "Terrain"
	add_child(terrain)
	terrain.generate(s)
	GameState.terrain = terrain

	var city := CityScript.new()
	city.name = "City"
	add_child(city)
	city.generate(terrain, s)

	var network := NetworkScript.new()
	network.name = "RoadNetwork"
	add_child(network)
	network.build(terrain, city)

	forest = ForestScript.new()
	forest.name = "Forest"
	forest.network = network
	add_child(forest)
	forest.generate(terrain, s)
	GameState.fire = forest

	var park := ForestParkScript.new()   # parc de loisirs dans les clairières de la forêt
	park.name = "ForestPark"
	add_child(park)
	park.build(terrain, s)

	var rangers := RangerStationScript.new()   # maison des gardes forestiers (entrée de la forêt)
	rangers.name = "RangerStation"
	add_child(rangers)
	rangers.build(terrain)

	_build_base()

	orchestrator = OrchestratorScript.new()
	orchestrator.name = "Orchestrator"
	add_child(orchestrator)
	GameState.orchestrator = orchestrator

	_spawn_drones()

	var station := StationScript.new()
	station.name = "FireStation"
	add_child(station)
	GameState.fire_service = station
	station.setup(network, city, terrain)

	var life := CityLifeScript.new()
	life.name = "CityLife"
	add_child(life)
	life.setup(network, city, s)
	station.city_life = life

	var lumber := LumberCampScript.new()   # scierie et bûcherons (arbres de prairie, jamais la forêt)
	lumber.name = "LumberCamp"
	add_child(lumber)
	GameState.lumber = lumber
	lumber.setup(city, terrain, forest, life)

	var poaching := PoachingScript.new()
	poaching.name = "Poaching"
	add_child(poaching)
	GameState.poaching = poaching
	poaching.setup(network, city, terrain, forest)

	var director := DirectorScript.new()
	director.name = "ScenarioDirector"
	add_child(director)

	var bridge := BridgeScript.new()
	bridge.name = "ExternalBridge"
	add_child(bridge)

	camera = CameraScript.new()
	camera.name = "Camera"
	add_child(camera)
	camera.current = true
	camera.setup_view(Vector3(-60, 150, 250), Vector3(70, 0, -10))

	_setup_rain()
	_setup_snow()

	hud = HudScript.new()
	hud.name = "HUD"
	add_child(hud)

	EventBus.log_msg("Monde généré (graine %d) — %d arbres" % [s, forest.tree_colors.size()])
	EventBus.emit_event.call_deferred("simulation_started", {"seed": s})


# ----------------------------------------------------------- monde

func _setup_environment() -> void:
	atmosphere = AtmosphereScript.new()
	atmosphere.name = "Atmosphere"
	add_child(atmosphere)
	atmosphere.setup()
	sun = atmosphere.sun


func _mat(c: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.roughness = 0.8
	return m


func _build_base() -> void:
	var bp: Vector2 = terrain.base_pos2
	var y: float = terrain.height_at(bp.x, bp.y)
	# aire rectangulaire nord-sud : ne déborde ni sur la forêt (x >= 48) ni sur la ville
	var pad := MeshInstance3D.new()
	var cm := BoxMesh.new()
	cm.size = Vector3(34.0, 0.4, 74.0)
	cm.material = Look.pbr("concrete", 4.0, Color(0.78, 0.8, 0.84))
	pad.mesh = cm
	pad.position = Vector3(bp.x, y + 0.2, bp.y)
	add_child(pad)
	# plots : 3 drones d'action (colonne ouest, 18 m d'écart) puis 2 de surveillance (colonne est)
	# 6 plots « action » (colonnes ouest et centre) puis 3 plots « surveillance » (centre et est)
	var slots := [Vector2(-9, -27), Vector2(-9, -9), Vector2(-9, 9), Vector2(-9, 27), Vector2(4, -18), Vector2(4, 18),
		Vector2(4, 0), Vector2(12, -27), Vector2(12, 27)]
	for sl in slots:
		var hp := Vector3(bp.x + sl.x, y + 0.4, bp.y + sl.y)
		home_positions.append(hp)
		# marquage peint : cercle jaune (anneau) autour du plot
		for ring in [[5.0, Color(0.7, 0.56, 0.1), 0.03], [4.7, Color(0.36, 0.37, 0.38), 0.035]]:
			var mark := MeshInstance3D.new()
			var mm := CylinderMesh.new()
			mm.top_radius = ring[0]
			mm.bottom_radius = ring[0]
			mm.height = 0.02
			mm.radial_segments = 48
			mm.material = Look.plastic(ring[1], 0.7) if ring[0] > 4.9 else Look.pbr("concrete", 4.0, Color(0.78, 0.8, 0.84))
			mark.mesh = mm
			mark.position = hp + Vector3(0, ring[2], 0)
			add_child(mark)
	# poste de commandement : même rendu que les immeubles (fenêtres, toit)
	var hq := MeshInstance3D.new()
	hq.mesh = BoxMesh.new()
	var hqm := ShaderMaterial.new()
	hqm.shader = preload("res://scripts/render/shaders/building.gdshader")
	for pair in [["fa", "facade_a"], ["fb", "facade_b"], ["fc", "facade_c"], ["fd", "facade_d"], ["roof", "roof"]]:
		hqm.set_shader_parameter(pair[0] + "_d", Look.tex(pair[1], "diff"))
		hqm.set_shader_parameter(pair[0] + "_n", Look.tex(pair[1], "nor"))
	hq.material_override = hqm
	hq.scale = Vector3(12, 6, 8)
	hq.position = Vector3(bp.x, y + 3.0, bp.y - 46.0)
	add_child(hq)
	terrain.add_obstacle_box(Vector2(bp.x, bp.y - 46.0), Vector2(12, 8), y + 6.0)
	var label := Label3D.new()
	label.text = "BASE DRONES"
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.font_size = 64
	label.outline_size = 12
	label.pixel_size = 0.03
	label.position = Vector3(bp.x, y + 11.0, bp.y - 46.0)
	add_child(label)


func _spawn_drones() -> void:
	# [identifiant, rôle, plot] — ordre conservé : touches 1..5 et caméra
	var defs := [["SURV-1", "surveillance", 6], ["SURV-2", "surveillance", 7], ["SURV-3", "surveillance", 8],
		["ACT-1", "action", 0], ["ACT-2", "action", 1], ["ACT-3", "action", 2],
		["ACT-4", "action", 3], ["ACT-5", "action", 4], ["ACT-6", "action", 5]]
	var n_surv := 0
	for df in defs:
		if df[1] == "surveillance":
			n_surv += 1
	var surv_k := 0
	for k in defs.size():
		var d := DroneScript.new()
		d.drone_id = defs[k][0]
		d.role = defs[k][1]
		d.name = d.drone_id
		var hp: Vector3 = home_positions[defs[k][2]]
		d.home = hp + Vector3(0, 0.6, 0)
		if d.role == "surveillance":
			d.patrol_points = _patrol_points(surv_k, n_surv)
			surv_k += 1
		add_child(d)
		d.global_position = d.home
		GameState.drones.append(d)


## Parcours « en serpentin » au-dessus de la forêt : la forêt est découpée en
## bandes nord-sud, une par drone de surveillance (SURV-1 au nord, SURV-2 au sud).
func _patrol_points(index: int, count: int) -> Array:
	var full: Rect2 = terrain.forest_rect
	var h := full.size.y / maxi(count, 1)
	var fr := Rect2(full.position.x, full.position.y + h * index, full.size.x, h)
	var pts: Array = []
	# passes espacées d'environ 1,5 x le rayon de détection : aucune zone non survolée
	var lanes := maxi(3, ceili(fr.size.x / (float(GameState.cfgv("drone", "detect_radius", 70.0)) * 1.5)))
	for l in lanes:
		var x := fr.position.x + fr.size.x * (l + 0.5) / lanes
		var a := Vector3(x, 0, fr.position.y + 15.0)
		var b := Vector3(x, 0, fr.end.y - 15.0)
		if l % 2 == 0:
			pts.append(a)
			pts.append(b)
		else:
			pts.append(b)
			pts.append(a)
	return pts


func _setup_rain() -> void:
	rain_fx = CPUParticles3D.new()
	rain_fx.name = "Rain"
	rain_fx.amount = 2500
	rain_fx.lifetime = 1.2
	rain_fx.emitting = false
	rain_fx.local_coords = false
	rain_fx.emission_shape = CPUParticles3D.EMISSION_SHAPE_BOX
	rain_fx.emission_box_extents = Vector3(70, 1, 70)
	rain_fx.direction = Vector3(0, -1, 0)
	rain_fx.spread = 3.0
	rain_fx.initial_velocity_min = 35.0
	rain_fx.initial_velocity_max = 45.0
	var m := BoxMesh.new()
	m.size = Vector3(0.04, 0.9, 0.04)
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color(0.7, 0.8, 1.0, 0.45)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.material = mat
	rain_fx.mesh = m
	add_child(rain_fx)


func _setup_snow() -> void:
	snow_fx = CPUParticles3D.new()
	snow_fx.name = "Snow"
	snow_fx.amount = 3500
	snow_fx.lifetime = 7.0
	snow_fx.emitting = false
	snow_fx.local_coords = false
	snow_fx.emission_shape = CPUParticles3D.EMISSION_SHAPE_BOX
	snow_fx.emission_box_extents = Vector3(80, 1, 80)
	snow_fx.direction = Vector3(0, -1, 0)
	snow_fx.spread = 25.0
	snow_fx.initial_velocity_min = 2.0
	snow_fx.initial_velocity_max = 4.0
	snow_fx.gravity = Vector3(0, -1.5, 0)
	snow_fx.scale_amount_min = 0.6
	snow_fx.scale_amount_max = 1.4
	var m := SphereMesh.new()
	m.radius = 0.09
	m.height = 0.18
	m.radial_segments = 4
	m.rings = 2
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color(1, 1, 1, 0.9)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.material = mat
	snow_fx.mesh = m
	add_child(snow_fx)


func _process(_delta: float) -> void:
	rain_fx.global_position = camera.global_position + Vector3(0, 30, 0)
	rain_fx.emitting = GameState.raining
	snow_fx.global_position = camera.global_position + Vector3(0, 25, 0)
	snow_fx.emitting = GameState.snowing
	# les flocons dérivent avec le vent
	var w := GameState.wind_vector() * GameState.wind_speed * 0.25
	snow_fx.gravity = Vector3(w.x, -1.5, w.y)
	# éclairage, ciel et surfaces mouillées/enneigées : voir render/atmosphere.gd


# ----------------------------------------------------------- contrôles

func _unhandled_input(event: InputEvent) -> void:
	if GameState.ui_capture:
		return
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT and mb.shift_pressed:
			pending_click = mb.position
		return
	if not (event is InputEventKey):
		return
	var k := event as InputEventKey
	if not k.pressed or k.echo:
		return
	match k.physical_keycode:
		KEY_1, KEY_2, KEY_3, KEY_4, KEY_5, KEY_6, KEY_7, KEY_8, KEY_9:
			var idx: int = k.physical_keycode - KEY_1
			if idx < GameState.drones.size():
				camera.set_follow(GameState.drones[idx])
		KEY_0, KEY_ESCAPE:
			camera.release_view()
		KEY_V:
			if camera.follow == null:
				var last = camera.last_follow
				camera.set_follow(last if last != null and is_instance_valid(last) else GameState.get_drone("ACT-1"))
			camera.cycle_mode()
		KEY_TAB:
			hud.toggle_editor()
		KEY_F1:
			hud.toggle_help()
		KEY_SPACE:
			_toggle_pause()
		KEY_LEFT:
			GameState.set_wind(GameState.wind_speed, GameState.wind_dir_deg - 15.0)
		KEY_RIGHT:
			GameState.set_wind(GameState.wind_speed, GameState.wind_dir_deg + 15.0)
		KEY_UP:
			GameState.set_wind(GameState.wind_speed + 1.0, GameState.wind_dir_deg)
		KEY_DOWN:
			GameState.set_wind(GameState.wind_speed - 1.0, GameState.wind_dir_deg)
		KEY_EQUAL, KEY_KP_ADD:
			_change_speed(1)
		KEY_MINUS, KEY_KP_SUBTRACT, KEY_6:
			_change_speed(-1)
	match k.keycode:
		KEY_F:
			orchestrator.execute_action({"type": "ignite", "position": "random"})
		KEY_B:
			orchestrator.execute_action({"type": "spawn_poachers", "position": "random"})
		KEY_H:
			GameState.set_rain(not GameState.raining, 40.0)
		KEY_J:
			GameState.set_snow(not GameState.snowing, 40.0)
		KEY_L:
			GameState.show_labels = not GameState.show_labels
		KEY_N:
			GameState.seed_value = randi() % 100000
			get_tree().reload_current_scene()


func _toggle_pause() -> void:
	GameState.paused = not GameState.paused
	Engine.time_scale = 0.0 if GameState.paused else float(SPEEDS[speed_index])


func _change_speed(dir: int) -> void:
	speed_index = clampi(speed_index + dir, 0, SPEEDS.size() - 1)
	if not GameState.paused:
		Engine.time_scale = float(SPEEDS[speed_index])
	EventBus.log_msg("Vitesse de simulation x%s" % str(SPEEDS[speed_index]))


func _physics_process(_delta: float) -> void:
	if pending_click == null:
		return
	var pos: Vector2 = pending_click
	pending_click = null
	var from := camera.project_ray_origin(pos)
	var to := from + camera.project_ray_normal(pos) * 3000.0
	var hit := get_world_3d().direct_space_state.intersect_ray(PhysicsRayQueryParameters3D.create(from, to))
	if hit.is_empty():
		return
	var p: Vector3 = hit["position"]
	orchestrator.execute_action({"type": "ignite", "position": [p.x, p.y, p.z]})
