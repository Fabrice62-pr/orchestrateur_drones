extends Node
## Pont vers un orchestrateur EXTERNE (script Python, n8n via tools/bridge_server.py...).
## - envoie chaque événement : {"type":"event","name":..,"data":{..},"world":{..}}
## - reçoit des actions     : {"type":"action","action":{..},"event":{..}}
##                            {"type":"actions","actions":[..]}
##                            {"type":"rules","text":"{...json des règles...}"}
## Activation : data/config.json -> "external_bridge": {"enabled": true, "url": "ws://127.0.0.1:8765"}

var ws: WebSocketPeer = null
var enabled := false
var url := "ws://127.0.0.1:8765"
var connected := false
var retry_t := 0.0
var queue: Array[String] = []   # événements émis avant la connexion


func _ready() -> void:
	var c = GameState.cfg("external_bridge", {})
	if typeof(c) == TYPE_DICTIONARY:
		enabled = bool(c.get("enabled", false))
		url = str(c.get("url", url))
	GameState.bridge_status = "désactivé"
	if enabled:
		EventBus.game_event.connect(_on_event)
		_connect()


func _connect() -> void:
	ws = WebSocketPeer.new()
	var err := ws.connect_to_url(url)
	GameState.bridge_status = "connexion..." if err == OK else "erreur"
	retry_t = 5.0


func _process(delta: float) -> void:
	if not enabled or ws == null:
		return
	ws.poll()
	var st := ws.get_ready_state()
	if st == WebSocketPeer.STATE_OPEN:
		if not connected:
			connected = true
			GameState.bridge_status = "connecté"
			EventBus.log_msg("Pont externe connecté à " + url)
			for q in queue:
				ws.send_text(q)
			queue.clear()
		while ws.get_available_packet_count() > 0:
			_handle(ws.get_packet().get_string_from_utf8())
	elif st == WebSocketPeer.STATE_CLOSED:
		if connected:
			connected = false
			EventBus.log_msg("Pont externe déconnecté", "warn")
		GameState.bridge_status = "hors ligne"
		retry_t -= delta
		if retry_t <= 0.0:
			_connect()


func _on_event(event_name: String, data: Dictionary) -> void:
	var msg := {"type": "event", "name": event_name, "data": data, "world": GameState.orchestrator.world_state()}
	var text := JSON.stringify(msg)
	if connected:
		ws.send_text(text)
	elif queue.size() < 50:
		queue.append(text)


func _handle(text: String) -> void:
	var d = JSON.parse_string(text)
	if typeof(d) != TYPE_DICTIONARY:
		return
	var orch = GameState.orchestrator
	var ev = d.get("event", {})
	if typeof(ev) != TYPE_DICTIONARY:
		ev = {}
	match str(d.get("type", "")):
		"action":
			if typeof(d.get("action")) == TYPE_DICTIONARY:
				orch.execute_action(d["action"], ev)
		"actions":
			if typeof(d.get("actions")) == TYPE_ARRAY:
				for a in d["actions"]:
					if typeof(a) == TYPE_DICTIONARY:
						orch.execute_action(a, ev)
		"rules":
			var err: String = orch.set_rules_text(str(d.get("text", "")))
			EventBus.log_msg("Règles reçues du pont externe" if err == "" else err, "info" if err == "" else "warn")
