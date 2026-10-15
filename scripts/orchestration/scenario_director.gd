extends Node
## Directeur de scénario : automatisations côté CARTE.
## Lit une chronologie JSON et exécute des actions à des instants donnés
## (départs de feu, changements de vent, pluie...). Il utilise exactement le
## même vocabulaire d'actions que les règles de l'orchestrateur.

var events: Array = []
var next_index := 0
var scenario_name := ""


func _ready() -> void:
	var path := str(GameState.cfg("scenario", ""))
	if path == "" or not FileAccess.file_exists(path):
		return
	var data = JSON.parse_string(FileAccess.get_file_as_string(path))
	if typeof(data) != TYPE_DICTIONARY or typeof(data.get("events")) != TYPE_ARRAY:
		EventBus.log_msg("Scénario invalide : " + path, "warn")
		return
	scenario_name = str(data.get("name", path))
	for e in data["events"]:
		if typeof(e) == TYPE_DICTIONARY:
			events.append(e)
	events.sort_custom(func(a, b): return float(a.get("t", 0)) < float(b.get("t", 0)))
	EventBus.log_msg.call_deferred("Scénario : " + scenario_name)


func _process(_delta: float) -> void:
	while next_index < events.size() and GameState.sim_time >= float(events[next_index].get("t", 0)):
		var ev: Dictionary = events[next_index]
		next_index += 1
		EventBus.emit_event("scenario_step", {"t": ev.get("t", 0), "type": ev.get("type", "")})
		GameState.orchestrator.execute_action(ev, {})
