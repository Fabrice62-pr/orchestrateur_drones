extends Node
## État global de la simulation : configuration, météo, références vers les systèmes.

var config: Dictionary = {}
var seed_value: int = 1337
var _seed_initialized := false

var sim_time := 0.0
var wind_speed := 4.0      # m/s
var wind_dir_deg := 180.0  # direction VERS laquelle souffle le vent (0 = Est/+X, 90 = Sud/+Z)
var raining := false
var rain_left := 0.0
var snowing := false
var snow_left := 0.0
var paused := false
var ui_capture := false    # vrai quand l'éditeur de règles a le focus
var bridge_status := "désactivé"
var show_labels := true    # étiquettes 3D au-dessus des véhicules (touche L)

var terrain: Node3D = null
var fire: Node3D = null
var orchestrator: Node = null
var drones: Array = []
var fire_trucks: Array = []
var fire_service: Node3D = null


func _ready() -> void:
	load_config()
	if not _seed_initialized:
		seed_value = int(cfg("seed", 1337))
		_seed_initialized = true


func load_config() -> void:
	var path := "res://data/config.json"
	if FileAccess.file_exists("user://config.json"):
		path = "user://config.json"
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(path))
	if typeof(parsed) == TYPE_DICTIONARY:
		config = parsed
	else:
		push_warning("Configuration invalide : " + path)
		config = {}


func cfg(key: String, default_value = null):
	return config.get(key, default_value)


func cfgv(section: String, key: String, default_value = null):
	var s = config.get(section, {})
	if typeof(s) == TYPE_DICTIONARY:
		return s.get(key, default_value)
	return default_value


func set_cfgv(section: String, key: String, value) -> void:
	if typeof(config.get(section)) != TYPE_DICTIONARY:
		config[section] = {}
	config[section][key] = value


## Appelé par la scène principale à chaque (re)génération du monde.
func reset_runtime() -> void:
	sim_time = 0.0
	raining = false
	rain_left = 0.0
	snowing = false
	snow_left = 0.0
	paused = false
	ui_capture = false
	drones = []
	fire_trucks = []
	fire_service = null
	terrain = null
	fire = null
	orchestrator = null
	wind_speed = float(cfgv("wind", "speed", 4.0))
	wind_dir_deg = float(cfgv("wind", "direction_deg", 180.0))


func _process(delta: float) -> void:
	sim_time += delta
	if raining and rain_left > 0.0:
		rain_left -= delta
		if rain_left <= 0.0:
			set_rain(false, 0.0)
	if snowing and snow_left > 0.0:
		snow_left -= delta
		if snow_left <= 0.0:
			set_snow(false, 0.0)


func wind_vector() -> Vector2:
	var a := deg_to_rad(wind_dir_deg)
	return Vector2(cos(a), sin(a))


func wind_compass() -> String:
	var names := ["E", "SE", "S", "SO", "O", "NO", "N", "NE"]
	return names[int(round(wind_dir_deg / 45.0)) % 8]


func set_wind(speed: float, dir_deg: float) -> void:
	wind_speed = clampf(speed, 0.0, 25.0)
	wind_dir_deg = fposmod(dir_deg, 360.0)
	EventBus.emit_event("wind_changed", {"speed": snappedf(wind_speed, 0.1), "direction_deg": int(round(wind_dir_deg))})


func set_rain(active: bool, duration: float) -> void:
	if active == raining and not active:
		return
	raining = active
	rain_left = duration if active else 0.0
	EventBus.emit_event("rain_started" if active else "rain_stopped", {"duration": duration})


## duration <= 0 : précipitation sans fin (jusqu'à arrêt manuel).
func set_snow(active: bool, duration: float) -> void:
	if active == snowing and not active:
		return
	snowing = active
	snow_left = duration if active else 0.0
	EventBus.emit_event("snow_started" if active else "snow_stopped", {"duration": duration})


func get_drone(id: String):
	for d in drones:
		if d.drone_id == id:
			return d
	return null


## Drone ou camion de pompiers (suivi caméra, interface).
func get_unit(id: String):
	var d = get_drone(id)
	if d == null:
		for t in fire_trucks:
			if t.drone_id == id:
				return t
	return d
