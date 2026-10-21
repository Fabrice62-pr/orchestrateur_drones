extends Camera3D
## Caméra libre (style éditeur) + modes de suivi d'un drone.
## Les touches de déplacement utilisent la position PHYSIQUE des touches :
## ZQSD sur AZERTY = WASD sur QWERTY.
##
## Souris (hors panneaux de l'interface) :
##   clic gauche maintenu : regarder / tourner autour du véhicule suivi
##   molette             : zoom (avance/recule, ou distance de suivi ; champ de vision en FPV)
##   clic molette maintenu : déplacer la vue (caméra libre)
##   Ctrl + molette      : vitesse de déplacement au clavier
##
## Modes de suivi (quand un drone est suivi) :
##   "orbit"  : orbite autour du drone (clic gauche pour tourner)
##   "fpv"    : 1re personne, caméra embarquée sous le nez du drone (clic gauche pour regarder autour)
##   "second" : 2e personne, caméra placée devant le drone et tournée vers lui
##   "smart"  : suivi intelligent, derrière le drone dans son sens de vol, recul adapté
##              à la vitesse, cadrage vers sa destination (feu, lac, base)

const MODES := ["orbit", "fpv", "second", "smart"]
const MODE_FR := {"orbit": "Orbite", "fpv": "1re personne (FPV)", "second": "2e personne", "smart": "Suivi intelligent"}

var yaw := 0.0
var pitch := -0.5
var speed := 60.0
var follow: Node3D = null
var last_follow: Node3D = null   # dernier véhicule suivi (repris si on choisit une vue en caméra libre)
var mode := "orbit"
var looking := false
var panning := false
var zoom := 1.0          # multiplicateur de distance en mode suivi
var orbit_elev := 0.42   # élévation de l'orbite (rad)
var look_yaw := 0.0      # regard libre en FPV (décalage par rapport au cap du drone)
var look_pitch := 0.0
var _smart_dir := Vector3.FORWARD
var _smart_look := Vector3.ZERO
var _last_us := 0


func _ready() -> void:
	far = 3000.0
	fov = 70.0
	_last_us = Time.get_ticks_usec()


func setup_view(pos: Vector3, target: Vector3) -> void:
	global_position = pos
	look_at(target, Vector3.UP)
	yaw = rotation.y
	pitch = rotation.x


func set_follow(d: Node3D) -> void:
	_set_hidden(follow, false)
	follow = d
	if d == null:
		yaw = rotation.y
		pitch = clampf(rotation.x, -1.5, 1.5)
		rotation = Vector3(pitch, yaw, 0.0)   # supprime le roulis hérité de la vue embarquée
		fov = 70.0
		return
	last_follow = d
	_enter_mode()


## Annule la vue de suivi : caméra libre, souris rendue à l'utilisateur.
func release_view() -> void:
	var was: Node3D = follow
	set_follow(null)
	looking = false
	panning = false
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	if was != null:
		EventBus.log_msg("Caméra libre : contrôle à la souris (vue %s annulée)" % was.drone_id)


func set_mode(m: String) -> void:
	if not (m in MODES):
		return
	mode = m
	if follow != null:
		_enter_mode()
	EventBus.log_msg("Caméra : %s%s" % [MODE_FR[mode], (" — " + follow.drone_id) if follow != null else ""])


func cycle_mode() -> void:
	set_mode(MODES[(MODES.find(mode) + 1) % MODES.size()])


func _enter_mode() -> void:
	look_yaw = 0.0
	look_pitch = 0.0
	fov = 85.0 if mode == "fpv" else 70.0
	_set_hidden(follow, mode == "fpv")   # en FPV on ne voit pas son propre drone
	_smart_dir = _heading(follow)
	_smart_look = follow.global_position


## Masque le modèle du drone suivi (FPV) sans toucher à sa simulation.
func _set_hidden(d: Node3D, hidden: bool) -> void:
	if d == null or not is_instance_valid(d):
		return
	d.fpv_hidden = hidden
	for n in [d.body, d.label]:
		if n:
			n.visible = not hidden


## Cap du drone : son axe avant (le drone s'oriente dans le sens de son vol).
func _heading(d: Node3D) -> Vector3:
	var f := -d.global_transform.basis.z
	f.y = 0.0
	return f.normalized() if f.length() > 0.01 else Vector3.FORWARD


## Vrai si la souris est au-dessus d'un panneau de l'interface (boutons, curseurs...).
func _over_ui() -> bool:
	return get_viewport().gui_get_hovered_control() != null


## _input (et non _unhandled_input) : la caméra voit tous les événements souris,
## y compris un relâchement de bouton au-dessus d'un panneau -> jamais bloquée.
func _input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		match mb.button_index:
			MOUSE_BUTTON_LEFT:
				# Maj + clic gauche reste réservé à l'allumage d'un feu (géré par main.gd)
				if mb.pressed and not mb.shift_pressed and not _over_ui():
					looking = true
					Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
					get_viewport().set_input_as_handled()
				elif not mb.pressed and looking:
					looking = false
					Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
					if mode == "fpv":
						look_yaw = 0.0
						look_pitch = 0.0
			MOUSE_BUTTON_MIDDLE:
				panning = mb.pressed and not _over_ui()
			MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN:
				if not mb.pressed or _over_ui():
					return   # au-dessus d'un panneau, la molette reste à l'interface (curseurs)
				var dir := 1.0 if mb.button_index == MOUSE_BUTTON_WHEEL_UP else -1.0
				if mb.ctrl_pressed:
					speed = clampf(speed * (1.15 if dir > 0.0 else 1.0 / 1.15), 5.0, 400.0)
				else:
					_zoom(dir)
				get_viewport().set_input_as_handled()
	elif event is InputEventMouseMotion:
		var mm := event as InputEventMouseMotion
		if looking:
			if follow != null and mode == "fpv":
				look_yaw = clampf(look_yaw - mm.relative.x * 0.003, -2.5, 2.5)
				look_pitch = clampf(look_pitch - mm.relative.y * 0.003, -1.2, 1.0)
				return
			yaw -= mm.relative.x * 0.003
			if follow == null:
				pitch = clampf(pitch - mm.relative.y * 0.003, -1.5, 1.5)
				rotation = Vector3(pitch, yaw, 0.0)
			else:
				orbit_elev = clampf(orbit_elev + mm.relative.y * 0.003, 0.05, 1.45)
		elif panning and follow == null:
			_pan(mm.relative)


func _height_above_ground() -> float:
	if GameState.terrain == null:
		return 50.0
	return maxf(global_position.y - GameState.terrain.height_at(global_position.x, global_position.z), 2.0)


## Molette : en caméra libre on avance dans la direction regardée (pas proportionnel
## à l'altitude) ; en suivi on rapproche / éloigne ; en FPV on change le champ de vision.
func _zoom(dir: float) -> void:
	if follow != null:
		if mode == "fpv":
			fov = clampf(fov - dir * 5.0, 30.0, 100.0)
		else:
			zoom = clampf(zoom * (0.85 if dir > 0.0 else 1.0 / 0.85), 0.25, 5.0)
		return
	var step := clampf(_height_above_ground() * 0.18, 3.0, 120.0)
	global_position += -global_transform.basis.z * step * dir
	_keep_above_ground()


## Clic molette maintenu : on fait glisser la vue (déplacement à plat, proportionnel à l'altitude).
func _pan(rel: Vector2) -> void:
	var k := _height_above_ground() * 0.0025
	var right := global_transform.basis.x
	var fwd := -global_transform.basis.z
	fwd.y = 0.0
	if fwd.length() < 0.01:
		fwd = -global_transform.basis.y
		fwd.y = 0.0
	fwd = fwd.normalized()
	global_position += (-right * rel.x + fwd * rel.y) * k


func _process(_delta: float) -> void:
	# temps réel : la caméra reste utilisable en pause / en accéléré
	var now := Time.get_ticks_usec()
	var dt := minf((now - _last_us) / 1000000.0, 0.1)
	_last_us = now
	if follow != null and not is_instance_valid(follow):
		follow = null
	if follow != null:
		match mode:
			"fpv":
				_update_fpv()
			"second":
				_update_second(dt)
			"smart":
				_update_smart(dt)
			_:
				_update_orbit(dt)
		_keep_above_ground()
		return
	if GameState.ui_capture:
		return
	var b := global_transform.basis
	var dir := Vector3.ZERO
	if Input.is_physical_key_pressed(KEY_W):
		dir -= b.z
	if Input.is_physical_key_pressed(KEY_S):
		dir += b.z
	if Input.is_physical_key_pressed(KEY_A):
		dir -= b.x
	if Input.is_physical_key_pressed(KEY_D):
		dir += b.x
	if Input.is_physical_key_pressed(KEY_E):
		dir += Vector3.UP
	if Input.is_physical_key_pressed(KEY_Q):
		dir -= Vector3.UP
	if dir != Vector3.ZERO:
		var s := speed * (3.0 if Input.is_key_pressed(KEY_SHIFT) else 1.0)
		global_position += dir.normalized() * s * dt
	_keep_above_ground()


func _keep_above_ground() -> void:
	if GameState.terrain:
		var gy: float = GameState.terrain.height_at(global_position.x, global_position.z)
		global_position.y = maxf(global_position.y, gy + 2.0)


# ------------------------------------------------------------ modes de suivi

## Facteur de distance selon la taille du véhicule suivi (drone de 1 m ou camion de 8 m).
func _unit_scale() -> float:
	var cs = follow.get("cam_scale")
	if cs != null:
		return float(cs)
	var r = follow.get("radius")
	return clampf(float(r) / 7.0, 0.2, 1.0) if r != null else 1.0


func _update_orbit(dt: float) -> void:
	var target := follow.global_position
	var d := 44.0 * zoom * _unit_scale()
	var offset := Vector3(sin(yaw) * cos(orbit_elev), sin(orbit_elev), cos(yaw) * cos(orbit_elev)) * d
	global_position = global_position.lerp(target + offset, clampf(dt * 3.0, 0.0, 1.0))
	look_at(target, Vector3.UP)


## Caméra embarquée : suit exactement le cap et l'inclinaison du drone.
func _update_fpv() -> void:
	var cap: float = follow.rotation.y
	var roll: float = follow.body.rotation.z * 0.6 if follow.body else 0.0
	var tilt: float = follow.body.rotation.x * 0.6 if follow.body else 0.0
	var local_off = follow.get("fpv_local")   # point de vue embarqué propre au véhicule
	if local_off == null:
		local_off = Vector3.DOWN * 0.8
	global_position = follow.global_position + Basis(Vector3.UP, cap) * local_off
	global_transform.basis = Basis.from_euler(Vector3(-0.30 + tilt + look_pitch, cap + look_yaw, roll))


## Caméra placée devant le drone, tournée vers lui : on le voit arriver de face.
func _update_second(dt: float) -> void:
	var target := follow.global_position
	var fwd := _heading(follow)
	var desired := target + (fwd * 26.0 + Vector3.UP * 6.0) * zoom * _unit_scale()
	global_position = global_position.lerp(desired, clampf(dt * 4.0, 0.0, 1.0))
	look_at(target, Vector3.UP)


## Suivi intelligent : derrière le drone selon sa trajectoire, recul et hauteur
## proportionnels à la vitesse, regard orienté vers là où il va.
func _update_smart(dt: float) -> void:
	var target := follow.global_position
	var vel: Vector3 = follow.velocity
	var hv := Vector3(vel.x, 0.0, vel.z)
	var spd := hv.length()
	if spd > 2.0:
		_smart_dir = _smart_dir.slerp(hv / spd, clampf(dt * 1.5, 0.0, 1.0)).normalized()
	var dist := 28.0 + spd * 0.9
	var height := 10.0 + spd * 0.35
	# en intervention on cadre la zone de travail : caméra plus haute et plus proche
	if follow.state in ["FIGHTING", "REFILLING"]:
		dist = 24.0
		height = 22.0
	var desired := target + (-_smart_dir * dist + Vector3.UP * height) * zoom * maxf(_unit_scale(), 0.35)
	global_position = global_position.lerp(desired, clampf(dt * 2.5, 0.0, 1.0))
	var look := target + _smart_dir * minf(spd * 1.2, 30.0)
	var dest = _destination(follow)
	if dest != null:
		# regarde entre le drone et sa destination tant qu'elle est lointaine
		look = target.lerp(dest, clampf(target.distance_to(dest) / 400.0, 0.0, 0.35))
	_smart_look = _smart_look.lerp(look, clampf(dt * 3.0, 0.0, 1.0))
	look_at(_smart_look, Vector3.UP)


func _destination(d: Node3D):
	match d.state:
		"TRANSIT", "FIGHTING":
			return d.fire_target
		"GO_REFILL", "REFILLING":
			return d._lake_point()
		"RETURN_BASE":
			return d.home
		"GOTO":
			return d.goto_target
	return null
