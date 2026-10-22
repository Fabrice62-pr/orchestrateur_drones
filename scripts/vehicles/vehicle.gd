extends Node3D
## Véhicule terrestre générique : suit une liste de points de passage (rues, pistes
## forestières, petits trajets hors réseau), avec son équipage à bord ou à pied.
## Sert de base aux 4x4 des gardes, aux voitures de police et à la camionnette des braconniers.
##
## Route : liste de [Vector2, type] ; le type fixe la vitesse maxi (speed_for).

const Look := preload("res://scripts/render/look.gd")
const Models := preload("res://scripts/render/models.gd")

var drone_id := "VEH"           # identifiant (nom compatible caméra/interface)
var role := "vehicle"
var state := ""
var net: Node3D
var route: Array = []           # [Vector2, type] : city | track | exit | offroad
var heading := Vector2(0, -1)
var speed := 0.0
var velocity := Vector3.ZERO
var moving := false
var crew: Array = []
var siren := false              # gyrophares (les voitures de la ville se rangent)
var speed_bonus := 1.0          # fuite / urgence
var body: Node3D
var label: Label3D
var beacons: Array[MeshInstance3D] = []
var blink_t := 0.0
var cam_scale := 0.45
var fpv_hidden := false
var fpv_local := Vector3(0, 1.9, -0.4)


func pos2() -> Vector2:
	return Vector2(global_position.x, global_position.z)


## Vitesse maxi selon le type du tronçon (surchargée par les véhicules).
func speed_for(kind: String) -> float:
	return {"city": 12.0, "track": 9.0, "exit": 9.0}.get(kind, 5.0)


func crew_labels_visible() -> bool:
	return true


# ------------------------------------------------------------ itinéraires

## Chemin sur le réseau jusqu'au nœud `to` (depuis le nœud le plus proche).
func path_to_node(to: int) -> Array:
	var here := pos2()
	var from: int = net.nearest_node(here)
	var out: Array = []
	for id in net.path(from, to):
		out.append([net.nodes[id], net.kinds[id]])
	# inutile de revenir au premier nœud s'il est derrière nous
	if out.size() > 1 and here.distance_to(out[1][0]) < (out[0][0] as Vector2).distance_to(out[1][0]):
		out.pop_front()
	return out


## Longueur d'un itinéraire depuis la position actuelle.
func route_length(r: Array) -> float:
	var total := 0.0
	var p := pos2()
	for w in r:
		total += p.distance_to(w[0])
		p = w[0]
	return total


# ------------------------------------------------------------ conduite

## Avance sur la route ; renvoie vrai une fois le dernier point atteint.
func drive(dt: float) -> bool:
	if route.is_empty():
		speed = 0.0
		velocity = Vector3.ZERO
		moving = false
		return true
	var here := pos2()
	var wp: Vector2 = route[0][0]
	var to := wp - here
	var limit := speed_for(str(route[0][1])) * speed_bonus
	# ralentir avant un virage serré
	if route.size() > 1 and to.length() < 12.0:
		var nxt: Vector2 = route[1][0]
		var turn := to.normalized().dot((nxt - wp).normalized())
		limit = minf(limit, lerpf(3.5, limit, clampf((turn + 1.0) * 0.5, 0.0, 1.0)))
	if route.size() == 1:
		limit = minf(limit, maxf(1.5, to.length() * 0.7))
	limit = minf(limit, _traffic_limit(here))
	speed = move_toward(speed, limit, dt * (8.0 if limit < speed else 3.5))
	var step := speed * dt
	if to.length() <= maxf(step, 0.4):
		here = wp
		route.pop_front()
	else:
		var d := to.normalized()
		heading = heading.lerp(d, clampf(dt * 5.0, 0.0, 1.0)).normalized()
		here += d * step
	moving = speed > 0.3
	place(here)
	velocity = Vector3(heading.x, 0, heading.y) * speed
	return route.is_empty()


## Voitures de la ville devant nous, sur la même voie : on ralentit derrière elles.
func _traffic_limit(here: Vector2) -> float:
	var limit := INF
	var life = GameState.fire_service.city_life if GameState.fire_service else null
	if life == null or not GameState.terrain.city_rect.has_point(here):
		return limit
	for c in life.cars:
		var off: Vector2 = c.pos - here
		var ahead := off.dot(heading)
		if ahead > 0.0 and ahead < 14.0 and absf(off.dot(Vector2(-heading.y, heading.x))) < 2.8:
			limit = minf(limit, maxf(0.0, (ahead - 6.5) * 1.2))
	return limit


func place(p: Vector2) -> void:
	global_position = Vector3(p.x, GameState.terrain.height_at(p.x, p.y), p.y)
	rotation.y = atan2(-heading.x, -heading.y)
	# inclinaison selon la pente (avant / arrière)
	var f := p + heading * 2.2
	var b := p - heading * 2.2
	var dh: float = GameState.terrain.height_at(f.x, f.y) - GameState.terrain.height_at(b.x, b.y)
	body.rotation.x = lerpf(body.rotation.x, atan2(dh, 4.4), 0.2)


func stop() -> void:
	route.clear()
	speed = 0.0
	velocity = Vector3.ZERO
	moving = false


# ------------------------------------------------------------ équipage

## Place de l'équipier k autour du véhicule (portières avant puis arrière).
func door(k: int) -> Vector3:
	var side := Vector2(-heading.y, heading.x)
	var p := pos2() + heading * (0.6 if k < 2 else -0.8) + side * (1.6 if k % 2 == 0 else -1.6)
	return Vector3(p.x, 0.0, p.y)


func all_aboard() -> bool:
	for f in crew:
		if not f.aboard:
			return false
	return true


## Fait remonter l'équipage (ceux qui sont à côté montent, les autres s'approchent).
func gather_crew(running: bool) -> bool:
	for k in crew.size():
		var f = crew[k]
		if f.aboard:
			continue
		if Vector2(f.global_position.x, f.global_position.z).distance_to(pos2()) < 3.2:
			f.board()
		elif f.state == "IDLE" or f.arrived():
			f.go_to(door(k), running)
	return all_aboard()


# ------------------------------------------------------------ visuel

func animate_beacons(dt: float) -> void:
	blink_t += dt
	for k in beacons.size():
		beacons[k].visible = siren and fmod(blink_t * 2.6 + k * 0.5, 1.0) < 0.5


func box(parent: Node3D, sz: Vector3, pos: Vector3, mat: Material) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var b := BoxMesh.new()
	b.size = sz
	mi.mesh = b
	mi.material_override = mat
	mi.position = pos
	parent.add_child(mi)
	return mi


func emissive(c: Color, energy: float) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.emission_enabled = true
	m.emission = c
	m.emission_energy_multiplier = energy
	return m


## Berline de la ville (même modèle que les voitures garées), carrosserie blanche.
func build_car() -> void:
	body = Node3D.new()
	add_child(body)
	var mi := MeshInstance3D.new()
	mi.mesh = Models.car_mesh()
	body.add_child(mi)
	_build_label()


## Carrosserie de 4x4 / pick-up (avant = -Z) : châssis, cabine, plateau, roues.
func build_pickup(paint: Color, cab_len := 2.4, bed := true) -> void:
	body = Node3D.new()
	add_child(body)
	var shell := Look.paint(paint, 0.3, 0.25)
	var dark := Look.plastic(Color(0.03, 0.03, 0.035), 0.6)
	var glass := Look.glass()
	box(body, Vector3(1.9, 0.35, 4.8), Vector3(0, 0.55, 0), dark)
	box(body, Vector3(1.9, 0.75, 1.2), Vector3(0, 1.05, -1.85), shell)                     # capot
	box(body, Vector3(1.9, 1.2, cab_len), Vector3(0, 1.3, -1.25 + cab_len * 0.5), shell)   # cabine
	box(body, Vector3(1.8, 0.62, 0.05), Vector3(0, 1.55, -1.27), glass)                     # pare-brise
	for sx in [-0.96, 0.96]:
		box(body, Vector3(0.02, 0.5, cab_len - 0.3), Vector3(sx, 1.6, -1.25 + cab_len * 0.5), glass)
	if bed:
		var z0 := -1.25 + cab_len
		var L := 2.4 - cab_len + 1.25
		box(body, Vector3(1.9, 0.12, L), Vector3(0, 0.95, z0 + L * 0.5), shell)
		for sx in [-0.92, 0.92]:
			box(body, Vector3(0.08, 0.5, L), Vector3(sx, 1.2, z0 + L * 0.5), shell)
		box(body, Vector3(1.9, 0.5, 0.08), Vector3(0, 1.2, 2.38), shell)
	for z in [-1.6, 1.5]:
		for x in [-0.88, 0.88]:
			var w := MeshInstance3D.new()
			var wm := CylinderMesh.new()
			wm.top_radius = 0.42
			wm.bottom_radius = 0.42
			wm.height = 0.32
			w.mesh = wm
			w.material_override = dark
			w.position = Vector3(x, 0.42, z)
			w.rotation_degrees.z = 90.0
			body.add_child(w)
	_build_label()


func _build_label() -> void:
	label = Label3D.new()
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.no_depth_test = false
	label.fixed_size = true
	label.pixel_size = 0.0007
	label.font_size = 28
	label.outline_size = 8
	label.position = Vector3(0, 4.5, 0)
	add_child(label)
