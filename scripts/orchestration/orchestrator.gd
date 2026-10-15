extends Node
## Moteur de règles d'automatisation : DÉCLENCHEUR -> CONDITIONS -> ACTIONS.
##
## Les règles sont décrites en JSON (data/rules.json, ou user://rules.json si
## vous les avez sauvegardées depuis l'éditeur en jeu). Elles peuvent être
## modifiées pendant la simulation, sans redémarrer.
##
## Une règle :
## {
##   "name": "Incendie détecté : déployer",
##   "on": "fire_detected",                       # événement déclencheur
##   "enabled": true,                             # optionnel
##   "conditions": [ {"field": "event.intensity", "op": ">=", "value": 1} ],
##   "actions": [ {"type": "dispatch", "role": "action", "count": 2, "target": "event.position"} ]
## }
## Les valeurs "event.xxx" lisent les données de l'événement, "world.xxx" l'état du monde.

const DEFAULT_RULES := "res://data/rules.json"
const USER_RULES := "user://rules.json"
const AVAILABLE_STATES := ["IDLE", "HOLD", "PATROL", "RETURN_BASE", "CHARGING"]

var rules: Array = []
var rules_text := ""
var rules_source := ""
var local_rules_enabled := true
var fire_known := false
var fire_position := Vector3.ZERO
var rules_fired := 0
var _depth := 0


func _ready() -> void:
	local_rules_enabled = bool(GameState.cfg("local_rules", true))
	EventBus.game_event.connect(_on_event)
	var err := load_rules_from_disk()
	if err != "":
		EventBus.log_msg(err, "warn")


# ------------------------------------------------------------ chargement

func load_rules_from_disk(use_default: bool = false) -> String:
	var path := DEFAULT_RULES
	if not use_default and FileAccess.file_exists(USER_RULES):
		path = USER_RULES
	if not FileAccess.file_exists(path):
		return "Fichier de règles introuvable : " + path
	var err := set_rules_text(FileAccess.get_file_as_string(path))
	if err == "":
		rules_source = path
		EventBus.log_msg("%d règles chargées (%s)" % [rules.size(), path])
	return err


func set_rules_text(text: String) -> String:
	var json := JSON.new()
	if json.parse(text) != OK:
		return "Erreur JSON ligne %d : %s" % [json.get_error_line(), json.get_error_message()]
	var data = json.data
	if typeof(data) != TYPE_DICTIONARY or typeof(data.get("rules")) != TYPE_ARRAY:
		return "Le texte doit être un objet { \"rules\": [ ... ] }"
	for r in data["rules"]:
		if typeof(r) != TYPE_DICTIONARY or not r.has("on"):
			return "Chaque règle doit être un objet contenant au moins le champ \"on\""
	rules = data["rules"]
	rules_text = text
	return ""


func save_user_rules(text: String) -> String:
	var err := set_rules_text(text)
	if err != "":
		return err
	var f := FileAccess.open(USER_RULES, FileAccess.WRITE)
	if f == null:
		return "Impossible d'écrire " + USER_RULES
	f.store_string(text)
	f.close()
	rules_source = USER_RULES
	return ""


func reset_to_default() -> String:
	if FileAccess.file_exists(USER_RULES):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(USER_RULES))
	return load_rules_from_disk(true)


# ------------------------------------------------------------ évaluation

func _on_event(event_name: String, data: Dictionary) -> void:
	match event_name:
		"fire_detected", "fire_report":
			fire_known = true
			fire_position = to_vec3(data.get("position", null), fire_position)
		"fire_extinguished":
			fire_known = false
	if not local_rules_enabled:
		return
	if _depth > 8:
		EventBus.log_msg("Chaîne d'événements trop profonde, arrêt (boucle de règles ?)", "warn")
		return
	_depth += 1
	for rule in rules:
		if not bool(rule.get("enabled", true)):
			continue
		if str(rule.get("on", "")) != event_name:
			continue
		if check_conditions(rule.get("conditions", []), data):
			rules_fired += 1
			EventBus.log_msg("Règle « %s »" % str(rule.get("name", "sans nom")), "rule")
			var actions = rule.get("actions", [])
			if typeof(actions) == TYPE_ARRAY:
				for a in actions:
					if typeof(a) == TYPE_DICTIONARY:
						execute_action(a, data)
	_depth -= 1


func world_state() -> Dictionary:
	var avail := 0
	for d in GameState.drones:
		if d.role == "action" and is_available(d, 35.0):
			avail += 1
	var fire = GameState.fire
	return {
		"time": snappedf(GameState.sim_time, 0.1),
		"fire_active": fire_known,
		"fire_position": [snappedf(fire_position.x, 0.1), snappedf(fire_position.y, 0.1), snappedf(fire_position.z, 0.1)],
		"burning_cells": fire.burning_count() if fire else 0,
		"burnt_cells": fire.total_burnt if fire else 0,
		"wind_speed": snappedf(GameState.wind_speed, 0.1),
		"wind_dir_deg": int(round(GameState.wind_dir_deg)),
		"raining": GameState.raining,
		"snowing": GameState.snowing,
		"available_action_drones": avail,
		"observing_drones": _count_state("OBSERVE"),
		"available_fire_trucks": GameState.fire_service.available_count() if GameState.fire_service else 0,
		"engaged_fire_trucks": GameState.fire_service.engaged_count() if GameState.fire_service else 0,
	}


func _count_state(st: String) -> int:
	var n := 0
	for d in GameState.drones:
		if d.state == st:
			n += 1
	return n


func resolve(value, event: Dictionary):
	if typeof(value) == TYPE_STRING:
		var s: String = value
		if s.begins_with("event."):
			return _dig(event, s.substr(6))
		if s.begins_with("world."):
			return _dig(world_state(), s.substr(6))
	return value


func _dig(d, path: String):
	var cur = d
	for part in path.split("."):
		if typeof(cur) == TYPE_DICTIONARY and cur.has(part):
			cur = cur[part]
		else:
			return null
	return cur


func check_conditions(conds, event: Dictionary) -> bool:
	if typeof(conds) != TYPE_ARRAY:
		return true
	for c in conds:
		if typeof(c) != TYPE_DICTIONARY:
			continue
		var left = resolve(c.get("field"), event)
		var right = resolve(c.get("value"), event)
		if not compare(left, str(c.get("op", "==")), right):
			return false
	return true


func compare(a, op: String, b) -> bool:
	if a == null or b == null:
		return (op == "==" and a == null and b == null) or (op == "!=" and not (a == null and b == null))
	var num_a := typeof(a) == TYPE_INT or typeof(a) == TYPE_FLOAT
	var num_b := typeof(b) == TYPE_INT or typeof(b) == TYPE_FLOAT
	if num_a and num_b:
		var x := float(a)
		var y := float(b)
		match op:
			"==": return is_equal_approx(x, y)
			"!=": return not is_equal_approx(x, y)
			">": return x > y
			">=": return x >= y
			"<": return x < y
			"<=": return x <= y
		return false
	var sa := str(a)
	var sb := str(b)
	match op:
		"==": return sa == sb
		"!=": return sa != sb
		"contains": return sa.contains(sb)
	return false


func to_vec3(v, fallback: Vector3 = Vector3.ZERO) -> Vector3:
	if v is Vector3:
		return v
	if typeof(v) == TYPE_ARRAY:
		var arr: Array = v
		if arr.size() >= 3:
			return Vector3(float(arr[0]), float(arr[1]), float(arr[2]))
		if arr.size() == 2:
			var x := float(arr[0])
			var z := float(arr[1])
			var y: float = GameState.terrain.height_at(x, z)
			return Vector3(x, y, z)
	return fallback


func is_available(d, min_battery: float) -> bool:
	return (d.state in AVAILABLE_STATES) and d.battery >= min_battery


## Sélecteurs : "all", "surveillance", "action", "role:action", "available:action", "state:OBSERVE", ou un identifiant ("ACT-1").
func select_drones(sel, event: Dictionary) -> Array:
	var s := str(resolve(sel, event))
	var out: Array = []
	for d in GameState.drones:
		if s == "all" or s == d.role or s == "role:" + d.role or s == d.drone_id:
			out.append(d)
		elif s == "available:" + d.role and is_available(d, 35.0):
			out.append(d)
		elif s == "state:" + d.state:
			out.append(d)
	if out.is_empty():
		EventBus.log_msg("Aucun drone ne correspond à « %s »" % s, "warn")
	return out


func format_message(msg: String, event: Dictionary) -> String:
	for k in event.keys():
		msg = msg.replace("{%s}" % k, str(event[k]))
	var w := world_state()
	for k in w.keys():
		msg = msg.replace("{world.%s}" % k, str(w[k]))
	return msg


func _cmd(d, what: String) -> void:
	EventBus.log_msg("%s -> %s" % [d.drone_id, what], "cmd")


# ------------------------------------------------------------ actions

func execute_action(a: Dictionary, event: Dictionary = {}) -> void:
	# "delay" (secondes de simulation) : latence avant exécution, ex. temps de transmission radio
	var dv = resolve(a.get("delay", 0), event)
	if (typeof(dv) == TYPE_INT or typeof(dv) == TYPE_FLOAT) and float(dv) > 0.0:
		var later := a.duplicate(true)
		later.erase("delay")
		get_tree().create_timer(float(dv), false).timeout.connect(execute_action.bind(later, event.duplicate(true)))
		return
	var t := str(a.get("type", ""))
	match t:
		"dispatch":
			var role := str(a.get("role", "action"))
			var count := int(a.get("count", 1))
			var min_bat := float(a.get("min_battery", 35))
			var target := to_vec3(resolve(a.get("target", "world.fire_position"), event), fire_position)
			var cands: Array = []
			for d in GameState.drones:
				if d.role == role and is_available(d, min_bat):
					cands.append(d)
			cands.sort_custom(func(p, q): return p.global_position.distance_to(target) < q.global_position.distance_to(target))
			if cands.is_empty():
				EventBus.log_msg("Aucun drone « %s » disponible pour l'intervention" % role, "warn")
			for k in mini(count, cands.size()):
				cands[k].cmd_fight(target)
				_cmd(cands[k], "intervention")
		"fight":
			var target := to_vec3(resolve(a.get("target", "world.fire_position"), event), fire_position)
			for d in select_drones(a.get("drone", ""), event):
				d.cmd_fight(target)
				_cmd(d, "intervention")
		"refill":
			for d in select_drones(a.get("drone", ""), event):
				d.cmd_refill()
				_cmd(d, "remplissage au lac")
		"return_base":
			for d in select_drones(a.get("drone", ""), event):
				d.cmd_return_base()
				_cmd(d, "retour base")
		"patrol":
			for d in select_drones(a.get("drone", ""), event):
				d.cmd_patrol()
				_cmd(d, "patrouille")
		"observe":
			var target := to_vec3(resolve(a.get("target", "world.fire_position"), event), fire_position)
			for d in select_drones(a.get("drone", ""), event):
				d.cmd_observe(target)
				_cmd(d, "vol stationnaire d'observation")
		"orbit":
			var target := to_vec3(resolve(a.get("target", "world.fire_position"), event), fire_position)
			for d in select_drones(a.get("drone", ""), event):
				d.cmd_orbit(target)
				_cmd(d, "orbite de surveillance")
		"hold":
			for d in select_drones(a.get("drone", ""), event):
				d.cmd_hold()
				_cmd(d, "stationnaire")
		"goto":
			var target := to_vec3(resolve(a.get("target", null), event), Vector3.ZERO)
			target.y += float(a.get("altitude", 40.0))
			for d in select_drones(a.get("drone", ""), event):
				d.cmd_goto(target)
				_cmd(d, "déplacement")
		"set_drone_param":
			var param := str(a.get("param", ""))
			for d in select_drones(a.get("drone", ""), event):
				if param in d:
					d.set(param, resolve(a.get("value"), event))
				else:
					EventBus.log_msg("Paramètre de drone inconnu : " + param, "warn")
		"set_fire_param":
			GameState.set_cfgv("fire", str(a.get("param", "")), resolve(a.get("value"), event))
		"log":
			EventBus.log_msg(format_message(str(a.get("message", "")), event), str(a.get("level", "info")))
		"ignite":
			var p = resolve(a.get("position", "random"), event)
			if typeof(p) == TYPE_STRING and p == "random":
				GameState.fire.ignite_random()
			else:
				GameState.fire.ignite_at(to_vec3(p, Vector3.ZERO))
		"set_wind":
			var sp := float(resolve(a.get("speed", GameState.wind_speed), event))
			var dr := float(resolve(a.get("direction_deg", GameState.wind_dir_deg), event))
			GameState.set_wind(sp, dr)
		"rain":
			GameState.set_rain(true, float(a.get("duration", 30.0)))
		"stop_rain":
			GameState.set_rain(false, 0.0)
		"snow":
			GameState.set_snow(true, float(a.get("duration", 30.0)))
		"stop_snow":
			GameState.set_snow(false, 0.0)
		"dispatch_firefighters":
			if GameState.fire_service:
				var target := to_vec3(resolve(a.get("target", "world.fire_position"), event), fire_position)
				var unit := str(resolve(a.get("unit", ""), event)) if a.has("unit") else ""
				GameState.fire_service.dispatch(int(a.get("count", 2)), target, unit)
		"recall_firefighters", "refill_fire_truck":
			if GameState.fire_service:
				GameState.fire_service.recall(str(resolve(a.get("unit", "all"), event)))
		"emit":
			var payload = a.get("data", {})
			EventBus.emit_event(str(a.get("event", "custom")), payload if typeof(payload) == TYPE_DICTIONARY else {})
		_:
			EventBus.log_msg("Action inconnue : « %s »" % t, "warn")
