extends CanvasLayer
## Interface de supervision : état de la flotte, météo/incendie, journal,
## aide et éditeur de règles en jeu.

const STATE_FR := {
	"IDLE": "À la base", "CHARGING": "En charge", "PATROL": "Patrouille",
	"ORBIT": "Surveillance du feu", "OBSERVE": "Observation stationnaire du feu", "TRANSIT": "En route vers le feu",
	"FIGHTING": "Confinement du feu", "GO_REFILL": "Vers le lac",
	"REFILLING": "Remplissage", "RETURN_BASE": "Retour base",
	"HOLD": "Stationnaire", "GOTO": "Déplacement", "STARTING": "Mise en route",
}
const LEVEL_COLORS := {"info": "#e6e6e6", "rule": "#ffd166", "warn": "#ff7b7b", "event": "#8ecae6", "cmd": "#b5e48c"}
const MAX_LOG := 13

var drones_label: RichTextLabel
var info_label: RichTextLabel
var log_label: RichTextLabel
var help_panel: PanelContainer
var editor_panel: PanelContainer
var editor: CodeEdit
var editor_status: Label
var local_check: CheckBox
var log_lines: Array[String] = []
var _last_refresh := 0

# panneau météo
const DURATIONS := [20.0, 40.0, 60.0, 120.0, 0.0]   # 0 = illimitée
const WIND_PRESETS := [["Calme", 0.0], ["Brise", 4.0], ["Vent fort", 10.0], ["Tempête", 20.0]]
var right_column: VBoxContainer
var rain_btn: Button
var snow_btn: Button
var duration_opt: OptionButton
var wind_speed_slider: HSlider
var wind_dir_slider: HSlider
var wind_speed_value: Label
var wind_dir_value: Label
var _wind_apply_at := -1   # ms : application différée du vent pendant qu'on fait glisser

# panneau caméra
const CAM_DRONES := ["SURV-1", "SURV-2", "SURV-3", "ACT-1", "ACT-2", "ACT-3", "ACT-4", "ACT-5", "ACT-6",
	"FPT-1", "FPT-2"]
const TRUCK_STATE_FR := {"CASERNE": "À la caserne", "DEPART": "Équipage vers le camion",
	"ROUTE": "En route (gyrophares)", "DEPLOIEMENT": "Établissement des lances", "EXTINCTION": "Attaque du feu",
	"REPLI": "Repli des lances", "RETOUR": "Retour caserne", "REMPLISSAGE": "Remplissage citerne"}
const CAM_MODES := [["fpv", "FPV"], ["second", "2e personne"], ["smart", "Suivi intelligent"], ["orbit", "Orbite"]]
var cam_drone_btns := {}   # id ("" = caméra libre) -> Button
var cam_mode_btns := {}    # mode -> Button


func _ready() -> void:
	layer = 10
	_build_drone_panel()
	_build_info_panel()
	_build_weather_panel()
	_build_camera_panel()
	_build_log_panel()
	_build_help_panel()
	_build_editor()
	EventBus.log_message.connect(_on_log)
	EventBus.game_event.connect(_on_event)


# ----------------------------------------------------------- construction

func _style(alpha: float = 0.78) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.05, 0.07, 0.10, alpha)
	sb.set_corner_radius_all(8)
	sb.set_content_margin_all(10)
	sb.border_color = Color(1, 1, 1, 0.08)
	sb.set_border_width_all(1)
	return sb


func _panel(ignore_mouse: bool = true) -> PanelContainer:
	var p := PanelContainer.new()
	p.add_theme_stylebox_override("panel", _style())
	if ignore_mouse:
		p.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(p)
	return p


func _rich(parent: Control, width: float, font_size: int = 14) -> RichTextLabel:
	var r := RichTextLabel.new()
	r.bbcode_enabled = true
	r.fit_content = true
	r.scroll_active = false
	r.mouse_filter = Control.MOUSE_FILTER_IGNORE
	r.custom_minimum_size = Vector2(width, 0)
	r.add_theme_font_size_override("normal_font_size", font_size)
	r.add_theme_font_size_override("bold_font_size", font_size)
	parent.add_child(r)
	return r


func _build_drone_panel() -> void:
	var p := _panel()
	p.position = Vector2(12, 12)
	drones_label = _rich(p, 340)


func _build_info_panel() -> void:
	# colonne de droite : informations puis commandes météo
	right_column = VBoxContainer.new()
	right_column.mouse_filter = Control.MOUSE_FILTER_IGNORE
	right_column.add_theme_constant_override("separation", 8)
	right_column.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	right_column.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	right_column.offset_left = -12
	right_column.offset_right = -12
	right_column.offset_top = 12
	add_child(right_column)
	var p := _panel()
	p.reparent(right_column)
	info_label = _rich(p, 330)


func _build_weather_panel() -> void:
	var p := _panel(false)   # reçoit la souris : les clics ne traversent pas vers la carte
	p.reparent(right_column)
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 6)
	p.add_child(vb)
	var title := Label.new()
	title.text = "MÉTÉO"
	title.add_theme_font_size_override("font_size", 14)
	vb.add_child(title)

	# précipitations
	var hb := HBoxContainer.new()
	hb.add_theme_constant_override("separation", 6)
	vb.add_child(hb)
	rain_btn = _toggle(hb, "Pluie", func(on: bool): GameState.set_rain(on, _duration()))
	snow_btn = _toggle(hb, "Neige", func(on: bool): GameState.set_snow(on, _duration()))
	duration_opt = OptionButton.new()
	duration_opt.focus_mode = Control.FOCUS_NONE
	duration_opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for d in DURATIONS:
		duration_opt.add_item("Durée %d s" % int(d) if d > 0.0 else "Durée illimitée")
	duration_opt.select(1)
	hb.add_child(duration_opt)

	# vent
	wind_speed_slider = _slider(vb, "Vitesse du vent", 0.0, 25.0, 0.5)
	wind_speed_value = wind_speed_slider.get_meta("value_label")
	wind_dir_slider = _slider(vb, "Direction (vers)", 0.0, 355.0, 5.0)
	wind_dir_value = wind_dir_slider.get_meta("value_label")
	var presets := HBoxContainer.new()
	presets.add_theme_constant_override("separation", 6)
	vb.add_child(presets)
	for pr in WIND_PRESETS:
		var b := Button.new()
		b.text = pr[0]
		b.focus_mode = Control.FOCUS_NONE
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var spd: float = pr[1]
		b.pressed.connect(func(): GameState.set_wind(spd, GameState.wind_dir_deg))
		presets.add_child(b)
	_sync_weather_controls()


func _camera():
	return get_parent().get("camera")


func _build_camera_panel() -> void:
	var p := _panel(false)
	p.reparent(right_column)
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 6)
	p.add_child(vb)
	var title := Label.new()
	title.text = "CAMÉRA — DRONES / POMPIERS"
	title.add_theme_font_size_override("font_size", 14)
	vb.add_child(title)
	# drone suivi
	var row := GridContainer.new()
	row.columns = 4
	row.add_theme_constant_override("h_separation", 4)
	row.add_theme_constant_override("v_separation", 4)
	vb.add_child(row)
	var group_d := ButtonGroup.new()
	group_d.allow_unpress = false
	for id in CAM_DRONES + [""]:
		var b := _toggle(row, id if id != "" else "Libre", _on_cam_drone.bind(id))
		b.button_group = group_d
		b.custom_minimum_size = Vector2(0, 0)
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		cam_drone_btns[id] = b
	# mode de vue
	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 6)
	grid.add_theme_constant_override("v_separation", 6)
	vb.add_child(grid)
	var group_m := ButtonGroup.new()
	group_m.allow_unpress = false
	for m in CAM_MODES:
		var b := _toggle(grid, m[1], _on_cam_mode.bind(m[0]))
		b.button_group = group_m
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		cam_mode_btns[m[0]] = b
	# annuler la vue : retour à la caméra libre, pilotée à la souris
	var cancel := Button.new()
	cancel.text = "✕  Annuler la vue (reprendre la souris)"
	cancel.focus_mode = Control.FOCUS_NONE
	cancel.tooltip_text = "Quitte le suivi du drone et rend la caméra libre (touche 0 ou Échap)"
	cancel.pressed.connect(_on_cam_cancel)
	vb.add_child(cancel)
	_sync_camera_controls()


func _on_cam_cancel() -> void:
	var cam = _camera()
	if cam:
		cam.release_view()
	_sync_camera_controls()


func _on_cam_drone(on: bool, id: String) -> void:
	if not on:
		return
	var cam = _camera()
	cam.set_follow(GameState.get_unit(id) if id != "" else null)


func _on_cam_mode(on: bool, m: String) -> void:
	if not on:
		return
	var cam = _camera()
	if cam.follow == null:   # vue choisie en caméra libre : on reprend le dernier véhicule suivi
		var last = cam.last_follow
		cam.set_follow(last if last != null and is_instance_valid(last) else GameState.get_unit("ACT-1"))
	cam.set_mode(m)


## Recale les boutons sur la caméra (touches 0-3 et V peuvent aussi la changer).
func _sync_camera_controls() -> void:
	var cam = _camera()
	if cam == null:
		return
	var id := ""
	if cam.follow != null and is_instance_valid(cam.follow):
		id = cam.follow.drone_id
	for k in cam_drone_btns:
		cam_drone_btns[k].set_pressed_no_signal(k == id)
	for k in cam_mode_btns:   # caméra libre : aucune vue sélectionnée
		cam_mode_btns[k].set_pressed_no_signal(id != "" and k == cam.mode)


func _toggle(parent: Control, text: String, cb: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.toggle_mode = true
	b.focus_mode = Control.FOCUS_NONE
	b.custom_minimum_size = Vector2(90, 0)
	b.toggled.connect(cb)
	parent.add_child(b)
	return b


func _slider(parent: Control, text: String, lo: float, hi: float, step: float) -> HSlider:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	parent.add_child(row)
	var l := Label.new()
	l.text = text
	l.custom_minimum_size = Vector2(120, 0)
	l.add_theme_font_size_override("font_size", 13)
	row.add_child(l)
	var s := HSlider.new()
	s.min_value = lo
	s.max_value = hi
	s.step = step
	s.focus_mode = Control.FOCUS_NONE
	s.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	s.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(s)
	var v := Label.new()
	v.custom_minimum_size = Vector2(80, 0)
	v.add_theme_font_size_override("font_size", 13)
	row.add_child(v)
	s.set_meta("value_label", v)
	s.value_changed.connect(_on_wind_slider)
	return s


func _on_wind_slider(_value: float) -> void:
	_update_wind_labels()
	_wind_apply_at = Time.get_ticks_msec() + 250


func _duration() -> float:
	return DURATIONS[duration_opt.selected]


func _update_wind_labels() -> void:
	wind_speed_value.text = "%.1f m/s" % wind_speed_slider.value
	var names := ["E", "SE", "S", "SO", "O", "NO", "N", "NE"]
	wind_dir_value.text = "%d° (%s)" % [int(wind_dir_slider.value), names[int(round(wind_dir_slider.value / 45.0)) % 8]]


## Recale les boutons/curseurs sur l'état réel (clavier, scénario, règles peuvent aussi changer la météo).
func _sync_weather_controls() -> void:
	rain_btn.set_pressed_no_signal(GameState.raining)
	snow_btn.set_pressed_no_signal(GameState.snowing)
	rain_btn.text = ("Pluie (%ds)" % int(GameState.rain_left)) if GameState.raining and GameState.rain_left > 0.0 else "Pluie"
	snow_btn.text = ("Neige (%ds)" % int(GameState.snow_left)) if GameState.snowing and GameState.snow_left > 0.0 else "Neige"
	if _wind_apply_at < 0:
		wind_speed_slider.set_value_no_signal(GameState.wind_speed)
		wind_dir_slider.set_value_no_signal(GameState.wind_dir_deg)
		_update_wind_labels()


func _build_log_panel() -> void:
	var p := _panel()
	p.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	p.grow_vertical = Control.GROW_DIRECTION_BEGIN
	p.offset_left = 12
	p.offset_top = -12
	p.offset_bottom = -12
	log_label = _rich(p, 600, 13)


func _build_help_panel() -> void:
	help_panel = _panel()
	help_panel.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	help_panel.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	help_panel.grow_vertical = Control.GROW_DIRECTION_BEGIN
	help_panel.offset_left = -12
	help_panel.offset_right = -12
	help_panel.offset_top = -12
	help_panel.offset_bottom = -12
	var r := _rich(help_panel, 440, 13)
	r.text = "[b]COMMANDES[/b]  (F1 : masquer)\n" \
		+ "Clic gauche maintenu + souris : regarder\n" \
		+ "ZQSD (AZERTY) / WASD : se déplacer · A/E : descendre/monter\n" \
		+ "Maj : accélérer · Molette : zoom · Ctrl + molette : vitesse caméra\n" \
		+ "Clic molette maintenu : faire glisser la vue\n" \
		+ "1 à 9 : suivre un drone · 0 / Échap : annuler la vue · V : changer de vue\n" \
		+ "F : départ de feu aléatoire · Maj + clic gauche : allumer un feu\n" \
		+ "← / → : direction du vent · ↑ / ↓ : force du vent\n" \
		+ "L : étiquettes · H : pluie on/off · J : neige on/off · Espace : pause · + / - : vitesse simulation\n" \
		+ "Tab : éditeur de règles · N : nouvelle carte (graine aléatoire)"


func _build_editor() -> void:
	editor_panel = _panel(false)
	editor_panel.add_theme_stylebox_override("panel", _style(0.94))
	editor_panel.set_anchors_preset(Control.PRESET_CENTER)
	editor_panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	editor_panel.grow_vertical = Control.GROW_DIRECTION_BOTH
	editor_panel.offset_left = -400
	editor_panel.offset_right = 400
	editor_panel.offset_top = -330
	editor_panel.offset_bottom = 330
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 8)
	editor_panel.add_child(vb)
	var title := Label.new()
	title.text = "Éditeur des règles d'automatisation"
	title.add_theme_font_size_override("font_size", 18)
	vb.add_child(title)
	var hint := Label.new()
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.custom_minimum_size = Vector2(770, 0)
	hint.add_theme_font_size_override("font_size", 12)
	hint.text = "Format : { \"rules\": [ { \"name\", \"on\": <événement>, \"conditions\": [ {\"field\", \"op\", \"value\"} ], \"actions\": [ {\"type\", ...} ] } ] }. " \
		+ "Valeurs dynamiques : \"event.xxx\" et \"world.xxx\". Événements, actions et exemples : voir README.md. « Appliquer » agit immédiatement sur la simulation."
	vb.add_child(hint)
	editor = CodeEdit.new()
	editor.custom_minimum_size = Vector2(770, 450)
	editor.size_flags_vertical = Control.SIZE_EXPAND_FILL
	editor.gutters_draw_line_numbers = true
	editor.add_theme_font_size_override("font_size", 13)
	vb.add_child(editor)
	local_check = CheckBox.new()
	local_check.text = "Règles locales actives (décocher pour laisser décider uniquement l'orchestrateur externe)"
	local_check.toggled.connect(func(on: bool): GameState.orchestrator.local_rules_enabled = on)
	vb.add_child(local_check)
	var hb := HBoxContainer.new()
	hb.add_theme_constant_override("separation", 8)
	vb.add_child(hb)
	_button(hb, "Appliquer", _on_apply)
	_button(hb, "Appliquer + sauvegarder", _on_save)
	_button(hb, "Recharger", _on_reload)
	_button(hb, "Règles par défaut", _on_default)
	_button(hb, "Fermer (Échap)", toggle_editor)
	editor_status = Label.new()
	editor_status.add_theme_font_size_override("font_size", 13)
	vb.add_child(editor_status)
	editor_panel.visible = false


func _button(parent: Control, text: String, cb: Callable) -> void:
	var b := Button.new()
	b.text = text
	b.pressed.connect(cb)
	parent.add_child(b)


# ----------------------------------------------------------- éditeur

func toggle_editor() -> void:
	editor_panel.visible = not editor_panel.visible
	GameState.ui_capture = editor_panel.visible
	if editor_panel.visible:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		editor.text = GameState.orchestrator.rules_text
		local_check.set_pressed_no_signal(GameState.orchestrator.local_rules_enabled)
		editor_status.text = "Source : " + str(GameState.orchestrator.rules_source)
		editor.grab_focus()
	else:
		editor.release_focus()


func toggle_help() -> void:
	help_panel.visible = not help_panel.visible


func _status(err: String, ok_text: String) -> void:
	if err == "":
		editor_status.text = ok_text
		editor_status.add_theme_color_override("font_color", Color(0.7, 1.0, 0.7))
	else:
		editor_status.text = err
		editor_status.add_theme_color_override("font_color", Color(1.0, 0.5, 0.5))


func _on_apply() -> void:
	var err: String = GameState.orchestrator.set_rules_text(editor.text)
	_status(err, "Règles appliquées (%d)." % GameState.orchestrator.rules.size())
	if err == "":
		EventBus.log_msg("Règles modifiées depuis l'éditeur", "rule")


func _on_save() -> void:
	var err: String = GameState.orchestrator.save_user_rules(editor.text)
	_status(err, "Règles appliquées et sauvegardées dans user://rules.json")


func _on_reload() -> void:
	var err: String = GameState.orchestrator.load_rules_from_disk()
	editor.text = GameState.orchestrator.rules_text
	_status(err, "Rechargé depuis " + str(GameState.orchestrator.rules_source))


func _on_default() -> void:
	var err: String = GameState.orchestrator.reset_to_default()
	editor.text = GameState.orchestrator.rules_text
	_status(err, "Règles par défaut restaurées (sauvegarde utilisateur supprimée).")


func _input(event: InputEvent) -> void:
	if editor_panel.visible and event is InputEventKey and event.pressed and (event as InputEventKey).keycode == KEY_ESCAPE:
		toggle_editor()
		get_viewport().set_input_as_handled()


# ----------------------------------------------------------- journal

func _on_log(text: String, level: String) -> void:
	var t := int(GameState.sim_time)
	var col: String = LEVEL_COLORS.get(level, "#e6e6e6")
	log_lines.append("[color=#7a8796]%02d:%02d[/color] [color=%s]%s[/color]" % [t / 60, t % 60, col, text.replace("[", "(")])
	while log_lines.size() > MAX_LOG:
		log_lines.pop_front()
	log_label.text = "[b]JOURNAL[/b]\n" + "\n".join(log_lines)


func _on_event(event_name: String, data: Dictionary) -> void:
	if event_name == "scenario_step":
		return
	var parts: Array[String] = []
	for k in ["drone_id", "intensity", "speed", "direction_deg", "burnt_cells", "duration"]:
		if data.has(k):
			parts.append("%s=%s" % [k, str(data[k])])
	_on_log("événement %s %s" % [event_name, " ".join(parts)], "event")


# ----------------------------------------------------------- rafraîchissement

func _process(_delta: float) -> void:
	var now := Time.get_ticks_msec()
	if _wind_apply_at >= 0 and now >= _wind_apply_at:
		_wind_apply_at = -1
		GameState.set_wind(wind_speed_slider.value, wind_dir_slider.value)
	if now - _last_refresh < 200:
		return
	_last_refresh = now
	drones_label.text = _drones_text()
	info_label.text = _info_text()
	_sync_weather_controls()
	_sync_camera_controls()


func _bar(v: float, n: int = 12) -> String:
	var full := clampi(int(round(v * n)), 0, n)
	var col := "#7CFC00" if v > 0.5 else ("#ffd166" if v > 0.25 else "#ff6b6b")
	return "[color=%s]%s[/color][color=#3a4450]%s[/color]" % [col, "|".repeat(full), "|".repeat(n - full)]


func _drones_text() -> String:
	var s := "[b]FLOTTE DE DRONES[/b]\n"
	for d in GameState.drones:
		var col := "#5aa9ff" if d.role == "surveillance" else "#ff7a5c"
		s += "[color=%s][b]%s[/b][/color] %s  %s %d%%" % [col, d.drone_id, STATE_FR.get(d.state, d.state),
			_bar(d.battery / 100.0, 8), int(d.battery)]
		if d.role == "action":
			s += "  eau %d/%d" % [d.water, d.max_water]
		s += "\n"
	if not GameState.fire_trucks.is_empty():
		s += "[b]POMPIERS[/b]\n"
		for t in GameState.fire_trucks:
			var aboard := 0
			for f in t.crew:
				if f.aboard:
					aboard += 1
			s += "[color=#ff5a4a][b]%s[/b][/color] — %s\n" % [t.drone_id, TRUCK_STATE_FR.get(t.state, t.state)]
			s += "  Citerne %s %d/%d   Équipage %d (%d à bord)\n" % [_bar(float(t.water) / maxf(1.0, float(t.max_water)), 8),
				t.water, t.max_water, t.crew.size(), aboard]
	return s


func _info_text() -> String:
	var t := int(GameState.sim_time)
	var orch = GameState.orchestrator
	var fire = GameState.fire
	var s := "[b]SIMULATION[/b]\n"
	s += "Temps %02d:%02d   Vitesse x%s%s\n" % [t / 60, t % 60, str(Engine.time_scale) if not GameState.paused else "0",
		"  [color=#ffd166]PAUSE[/color]" if GameState.paused else ""]
	s += "Vent %.1f m/s vers %s (%d°)\n" % [GameState.wind_speed, GameState.wind_compass(), int(GameState.wind_dir_deg)]
	s += "Pluie : %s\n" % ("[color=#8ecae6]oui (%ds)[/color]" % int(GameState.rain_left) if GameState.raining else "non")
	s += "Neige : %s\n" % ("[color=#e0f0ff]oui (%ds)[/color]" % int(GameState.snow_left) if GameState.snowing else "non")
	if fire:
		s += "Foyers actifs : [color=#ff8c42]%d[/color] (%d ralentis)   Brûlées : %d\n" % [fire.burning_count(), fire.damped.size(), fire.total_burnt]
		s += "Éteintes (pompiers) : %d   Largages drones : %d\n" % [fire.total_extinguished, fire.total_contained]
	if orch:
		s += "Incendie signalé : %s\n" % ("[color=#ff6b6b]OUI[/color]" if orch.fire_known else "non")
		s += "Règles : %d (%s) · déclenchées : %d\n" % [orch.rules.size(), "actives" if orch.local_rules_enabled else "désactivées", orch.rules_fired]
	s += "Pont externe : %s\n" % GameState.bridge_status
	s += "Graine de la carte : %d" % GameState.seed_value
	return s
