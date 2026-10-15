extends Node
## Bus d'événements global.
## Les drones, la carte et le scénario PUBLIENT des événements ;
## l'orchestrateur (règles), l'interface et le pont externe les ÉCOUTENT.

signal game_event(event_name: String, data: Dictionary)
signal log_message(text: String, level: String)


func emit_event(event_name: String, data: Dictionary = {}) -> void:
	game_event.emit(event_name, data)


func log_msg(text: String, level: String = "info") -> void:
	print("[%7.1fs][%s] %s" % [GameState.sim_time, level, text])
	log_message.emit(text, level)
