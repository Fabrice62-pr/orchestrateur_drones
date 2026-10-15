extends Node3D
## Vie urbaine : voitures qui circulent dans les rues et piétons sur les trottoirs.
##
## Voitures : conduite à droite, distance de sécurité, un seul véhicule à la fois
## dans un carrefour, et elles se rangent sur le côté au passage des pompiers.
## Piétons : font le tour des îlots sur les trottoirs, dans les deux sens,
## ralentissent derrière un piéton plus lent et marquent parfois une pause.
## Rendu en MultiMesh (quelques appels de dessin pour des centaines d'éléments).

const LANE := 2.3              # décalage de la voie de droite / axe de la rue
const PULL_OVER := 3.5         # décalage quand on se range pour laisser passer les pompiers
const GAP := 7.5               # distance visée entre deux voitures arrêtées (centre à centre)
const HARD_GAP := 6.0          # jamais moins : les carrosseries (4,3 m) ne se touchent pas
const BRAKE := 8.0             # décélération de freinage (m/s²)
const PEOPLE_SCALE := 1.0      # taille réelle
const Models := preload("res://scripts/render/models.gd")
# couleurs réalistes (albédo) : carrosseries courantes, vêtements sobres
const CAR_COLORS := [Color(0.78, 0.78, 0.78), Color(0.03, 0.03, 0.035), Color(0.5, 0.51, 0.53), Color(0.22, 0.23, 0.24),
	Color(0.04, 0.07, 0.18), Color(0.42, 0.03, 0.03), Color(0.48, 0.44, 0.36), Color(0.05, 0.12, 0.08), Color(0.78, 0.78, 0.76)]
const CLOTHES := [Color(0.08, 0.1, 0.18), Color(0.04, 0.04, 0.045), Color(0.15, 0.15, 0.16), Color(0.55, 0.48, 0.36),
	Color(0.7, 0.7, 0.68), Color(0.2, 0.24, 0.14), Color(0.3, 0.06, 0.08), Color(0.18, 0.25, 0.38), Color(0.45, 0.3, 0.16),
	Color(0.5, 0.08, 0.06), Color(0.45, 0.55, 0.65)]
const TROUSERS := [Color(0.12, 0.16, 0.26), Color(0.04, 0.04, 0.045), Color(0.22, 0.22, 0.23), Color(0.4, 0.36, 0.26)]
const HAIR := [Color(0.03, 0.025, 0.02), Color(0.08, 0.05, 0.03), Color(0.18, 0.1, 0.05), Color(0.55, 0.42, 0.22), Color(0.45, 0.45, 0.44)]
const SKINS := [Color(0.78, 0.6, 0.5), Color(0.68, 0.5, 0.38), Color(0.45, 0.3, 0.2), Color(0.27, 0.17, 0.11)]

var net: Node3D
var city: Node3D
var rng := RandomNumberGenerator.new()
var cars: Array = []
var peds: Array = []
var reserved := {}             # nœud de carrefour -> voiture qui le traverse
var car_mm: MultiMesh
var ped_body_mm: MultiMesh
var ped_head_mm: MultiMesh
var ped_hair_mm: MultiMesh
var ped_leg_mm: MultiMesh
var ped_arm_mm: MultiMesh


class Car:
	var a := 0                 # nœud de départ de la rue
	var b := 0                 # nœud d'arrivée
	var s := 0.0               # avancement sur la voie
	var crossing := false      # en train de traverser le carrefour b
	var next := -1             # rue suivante (b -> next)
	var cross_from := Vector2.ZERO
	var cross_to := Vector2.ZERO
	var cross_t := 0.0
	var speed := 0.0
	var max_speed := 10.0
	var lateral := LANE
	var pos := Vector2.ZERO
	var heading := Vector2.RIGHT
	var color := Color.WHITE


class Ped:
	var rect := Rect2()
	var inset := 0.8
	var dirn := 1.0
	var u := 0.0
	var speed := 1.3
	var cur_speed := 1.3
	var pause_t := 0.0
	var phase := 0.0
	var pos := Vector2.ZERO
	var heading := Vector2.RIGHT
	var clothes := Color.WHITE
	var skin := Color.WHITE
	var trousers := Color.WHITE
	var hair := Color.WHITE
	var height := 1.0
	var block_key := Vector2i.ZERO


func setup(network: Node3D, c: Node3D, seed_val: int) -> void:
	net = network
	city = c
	rng.seed = seed_val + 555
	_spawn_cars(int(GameState.cfgv("city", "cars", 45)))
	_spawn_peds(int(GameState.cfgv("city", "pedestrians_per_block", 5)))
	_build_visuals()


# ------------------------------------------------------------ voitures

func _lane_len(a: int, b: int) -> float:
	return _np(a).distance_to(_np(b)) - _cut() * 2.0


func _np(i: int) -> Vector2:
	return net.nodes[i]


func _cut() -> float:
	return city.road * 0.5 + 1.0


## Point de la voie a -> b à l'avancement s, décalé latéralement.
func _lane_point(a: int, b: int, s: float, lat: float) -> Vector2:
	var pa := _np(a)
	var dir := (_np(b) - pa).normalized()
	var right := Vector2(-dir.y, dir.x)
	return pa + dir * (_cut() + s) + right * lat


func _car_neighbors(n: int) -> Array:
	var out: Array = []
	for m in net.adj[n]:
		if net.is_car_edge(n, m):
			out.append(m)
	return out


func _spawn_cars(count: int) -> void:
	var city_nodes: Array = []
	for i in net.nodes.size():
		if net.kinds[i] == "city" and not _car_neighbors(i).is_empty():
			city_nodes.append(i)
	var tries := 0
	while cars.size() < count and tries < count * 30:
		tries += 1
		var a: int = city_nodes[rng.randi() % city_nodes.size()]
		var nb := _car_neighbors(a)
		var b: int = nb[rng.randi() % nb.size()]
		var ln := _lane_len(a, b)
		if ln < 4.0:
			continue
		var s := rng.randf_range(0.0, ln)
		var ok := true
		for o in cars:
			if o.a == a and o.b == b and absf(o.s - s) < GAP + 1.0:
				ok = false
				break
		if not ok:
			continue
		var c := Car.new()
		c.a = a
		c.b = b
		c.s = s
		c.max_speed = rng.randf_range(8.0, 13.0)
		c.speed = c.max_speed * 0.5
		c.color = CAR_COLORS[rng.randi() % CAR_COLORS.size()]
		c.pos = _lane_point(a, b, s, LANE)
		c.heading = (_np(b) - _np(a)).normalized()
		cars.append(c)


func _truck_near(p: Vector2, radius: float) -> bool:
	for t in GameState.fire_trucks:
		if t.moving and Vector2(t.global_position.x - p.x, t.global_position.z - p.y).length() < radius:
			return true
	return false


func _update_car(c: Car, dt: float) -> void:
	var target := c.max_speed
	# on se range pour les pompiers, sauf au milieu d'un carrefour : on le libère d'abord
	var yielding := not c.crossing and _truck_near(c.pos, 24.0)
	var want_lat := PULL_OVER if yielding else LANE
	c.lateral = move_toward(c.lateral, want_lat, dt * 1.5)
	if yielding:
		target = 0.0   # on se range et on s'arrête : les pompiers passent
	if not c.crossing:
		var ln := _lane_len(c.a, c.b)
		# véhicule devant sur la même voie : vitesse qui permet de s'arrêter à temps
		var gap := _gap_ahead(c, ln)
		if gap < INF:
			target = minf(target, sqrt(2.0 * BRAKE * maxf(gap - GAP, 0.0)))
		# fin de voie : demander le carrefour
		if c.s >= ln - 0.05:
			c.s = ln
			if c.next < 0:
				var nb := _car_neighbors(c.b)
				if nb.size() > 1:
					nb.erase(c.a)
				c.next = nb[rng.randi() % nb.size()]
			if _can_cross(c):
				reserved[c.b] = c
				c.crossing = true
				c.cross_from = _lane_point(c.a, c.b, ln, c.lateral)
				c.cross_to = _lane_point(c.b, c.next, 0.0, LANE)
				c.cross_t = 0.0
			else:
				target = 0.0
		elif c.s > ln - 6.0:
			target = minf(target, 6.0)   # on ralentit à l'approche du carrefour
	c.speed = move_toward(c.speed, target, dt * (BRAKE if target < c.speed else 3.5))
	if c.crossing:
		var seg_len := maxf(c.cross_from.distance_to(c.cross_to), 0.1)
		c.cross_t += c.speed * dt / seg_len
		var np := c.cross_from.lerp(c.cross_to, minf(c.cross_t, 1.0))
		_face(c, np)
		if c.cross_t >= 1.0:
			reserved.erase(c.b)
			c.crossing = false
			c.a = c.b
			c.b = c.next
			c.next = -1
			c.s = 0.0
	elif c.s < _lane_len(c.a, c.b):
		var ln2 := _lane_len(c.a, c.b)
		var ns := minf(c.s + c.speed * dt, ln2)
		var gap2 := _gap_ahead(c, ln2)
		if gap2 < INF and ns > c.s + gap2 - HARD_GAP:
			ns = maxf(c.s, c.s + gap2 - HARD_GAP)   # contrainte stricte : pas de chevauchement
			c.speed = 0.0
		c.s = ns
		_face(c, _lane_point(c.a, c.b, c.s, c.lateral))


## Distance au véhicule qui précède sur la même voie (INF si personne).
func _gap_ahead(c: Car, ln: float) -> float:
	var gap := INF
	for o in cars:
		if o == c or o.a != c.a or o.b != c.b:
			continue
		if o.crossing:
			# il tourne dans le carrefour : distance réellement parcourue depuis la fin de voie
			gap = minf(gap, ln - c.s + o.cross_t * o.cross_from.distance_to(o.cross_to))
		elif o.s > c.s or (o.s == c.s and o.get_instance_id() > c.get_instance_id()):
			gap = minf(gap, o.s - c.s)
	return gap


func _can_cross(c: Car) -> bool:
	if reserved.has(c.b) and reserved[c.b] != c:
		return false
	if _truck_near(_np(c.b), 30.0):
		return false
	# la voie suivante doit avoir de la place à son entrée
	for o in cars:
		if o != c and not o.crossing and o.a == c.b and o.b == c.next and o.s < GAP:
			return false
	return true


func _face(c: Car, np: Vector2) -> void:
	var mv := np - c.pos
	if mv.length() > 0.001:
		c.heading = c.heading.lerp(mv.normalized(), 0.25).normalized()
	c.pos = np


# ------------------------------------------------------------ piétons

func _spawn_peds(per_block: int) -> void:
	for key in city.block_kind:
		var kind: String = city.block_kind[key]
		if kind == "station":
			continue
		var r: Rect2 = city.block_rect(key)
		var count := per_block + rng.randi_range(-2, 2)
		# dans les parcs, des promeneurs suivent en plus l'allée intérieure
		var strollers := per_block / 2 if kind == "park" else 0
		for k in count + strollers:
			var p := Ped.new()
			p.block_key = key
			p.dirn = 1.0 if rng.randf() < 0.5 else -1.0
			# chaque sens a sa file : les piétons se croisent sans se traverser
			if k < count:
				p.inset = 0.7 if p.dirn > 0.0 else 1.5
			else:
				p.inset = 7.0 if p.dirn > 0.0 else 7.8
			p.rect = r.grow(-p.inset)
			p.u = rng.randf_range(0.0, _perimeter(p.rect))
			p.speed = rng.randf_range(1.0, 1.7)
			p.cur_speed = p.speed
			p.phase = rng.randf() * TAU
			p.clothes = CLOTHES[rng.randi() % CLOTHES.size()] * rng.randf_range(0.85, 1.1)
			p.clothes.a = 1.0
			p.skin = SKINS[rng.randi() % SKINS.size()]
			p.trousers = TROUSERS[rng.randi() % TROUSERS.size()]
			p.hair = HAIR[rng.randi() % HAIR.size()]
			p.height = rng.randf_range(0.92, 1.08)   # 1,60 m à 1,90 m
			p.pos = _rect_point(p.rect, p.u)
			peds.append(p)


func _perimeter(r: Rect2) -> float:
	return 2.0 * (r.size.x + r.size.y)


## Point du contour du rectangle à l'abscisse curviligne u.
func _rect_point(r: Rect2, u: float) -> Vector2:
	u = fposmod(u, _perimeter(r))
	var w := r.size.x
	var h := r.size.y
	if u < w:
		return r.position + Vector2(u, 0.0)
	u -= w
	if u < h:
		return r.position + Vector2(w, u)
	u -= h
	if u < w:
		return r.position + Vector2(w - u, h)
	u -= w
	return r.position + Vector2(0.0, h - u)


func _update_ped(p: Ped, dt: float, same_block: Array) -> void:
	if p.pause_t > 0.0:
		p.pause_t -= dt
		p.cur_speed = 0.0
		return
	if rng.randf() < dt * 0.02:
		p.pause_t = rng.randf_range(2.0, 6.0)   # regarde une vitrine, attend quelqu'un...
	var target := p.speed
	var per := _perimeter(p.rect)
	for o in same_block:
		if o == p or o.dirn != p.dirn or o.inset != p.inset:
			continue
		var ahead := fposmod((o.u - p.u) * p.dirn, per)
		if ahead < 1.6:
			target = minf(target, o.cur_speed if ahead > 0.9 else 0.0)
	p.cur_speed = move_toward(p.cur_speed, target, dt * 2.0)
	p.u += p.cur_speed * p.dirn * dt
	var np := _rect_point(p.rect, p.u)
	var mv := np - p.pos
	if mv.length() > 0.0005:
		p.heading = p.heading.lerp(mv.normalized(), 0.3).normalized()
	p.pos = np
	p.phase += p.cur_speed * dt * 5.0


# ------------------------------------------------------------ boucle

func _physics_process(dt: float) -> void:
	if dt <= 0.0:
		return
	for c in cars:
		_update_car(c, dt)
	var by_block := {}
	for p in peds:
		if not by_block.has(p.block_key):
			by_block[p.block_key] = []
		by_block[p.block_key].append(p)
	for p in peds:
		_update_ped(p, dt, by_block[p.block_key])


func _process(_delta: float) -> void:
	_draw_cars()
	_draw_peds()


func _basis_from(h: Vector2) -> Basis:
	return Basis(Vector3.UP, atan2(-h.x, -h.y))   # -Z du modèle = sens de marche


func _xf(bas: Basis, size: Vector3, origin: Vector3) -> Transform3D:
	return Transform3D(bas * Basis.from_scale(size), origin)


func _draw_cars() -> void:
	for k in cars.size():
		var c: Car = cars[k]
		car_mm.set_instance_transform(k, Transform3D(_basis_from(c.heading), Vector3(c.pos.x, city.ROAD_TOP, c.pos.y)))


## Silhouette humaine (1,75 m) : jambes et bras articulés, balancement opposé.
func _draw_peds() -> void:
	for k in peds.size():
		var p: Ped = peds[k]
		var sc := PEOPLE_SCALE * p.height
		var bas := _basis_from(p.heading)
		var o := Vector3(p.pos.x, city.SIDEWALK_TOP, p.pos.y)
		var walking := p.cur_speed > 0.1
		var bob := absf(sin(p.phase)) * 0.035 * sc if walking else 0.0
		var up := Vector3(0, bob, 0)
		ped_body_mm.set_instance_transform(k, _xf(bas, Vector3(0.36, 0.38, 0.22) * sc, o + Vector3(0, 1.2 * sc, 0) + up))
		var head_c := o + Vector3(0, 1.63 * sc, 0) + up
		ped_head_mm.set_instance_transform(k, _xf(bas, Vector3(0.2, 0.2, 0.21) * sc, head_c))
		ped_hair_mm.set_instance_transform(k, _xf(bas, Vector3(0.2, 0.22, 0.21) * sc, head_c + Vector3(0, 0.02 * sc, 0) + bas * Vector3(0, 0, 0.012)))
		var swing := sin(p.phase) * 0.45 if walking else 0.0
		for side in 2:
			var sgn := 1.0 if side == 0 else -1.0
			var lb := bas * Basis(Vector3.RIGHT, swing * sgn)
			var hip := o + Vector3(0, 0.9 * sc, 0) + bas * Vector3(0.09 * sgn * sc, 0, 0) + up
			ped_leg_mm.set_instance_transform(k * 2 + side, _xf(lb, Vector3(0.15, 0.43, 0.15) * sc, hip))
			var ab := bas * Basis(Vector3.RIGHT, -swing * sgn * 0.8) * Basis(Vector3.FORWARD, 0.06 * sgn)
			var shoulder := o + Vector3(0, 1.45 * sc, 0) + bas * Vector3(0.22 * sgn * sc, 0, 0) + up
			ped_arm_mm.set_instance_transform(k * 2 + side, _xf(ab, Vector3(0.1, 0.33, 0.1) * sc, shoulder))


# ------------------------------------------------------------ visuel

func _mm(node_name: String, mesh: Mesh, count: int, colors: Array, rough := 0.85) -> MultiMesh:
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.mesh = mesh
	mm.instance_count = count
	for k in count:
		mm.set_instance_color(k, colors[k] if k < colors.size() else Color(0.1, 0.1, 0.1))
	var mi := MultiMeshInstance3D.new()
	mi.name = node_name
	mi.multimesh = mm
	var m := StandardMaterial3D.new()
	m.vertex_color_use_as_albedo = true
	m.roughness = rough
	mi.material_override = m
	add_child(mi)
	return mm


func _build_visuals() -> void:
	# voitures : un seul MultiMesh, les matériaux sont portés par les surfaces du modèle
	car_mm = MultiMesh.new()
	car_mm.transform_format = MultiMesh.TRANSFORM_3D
	car_mm.use_colors = true
	car_mm.mesh = Models.car_mesh()
	car_mm.instance_count = cars.size()
	for k in cars.size():
		car_mm.set_instance_color(k, cars[k].color)
	var cmi := MultiMeshInstance3D.new()
	cmi.name = "Cars"
	cmi.multimesh = car_mm
	add_child(cmi)

	var clothes: Array = []
	var skins: Array = []
	var hair: Array = []
	var legs: Array = []
	var arms: Array = []
	for p in peds:
		clothes.append(p.clothes)
		skins.append(p.skin)
		hair.append(p.hair)
		legs.append(p.trousers)
		legs.append(p.trousers)
		arms.append(p.clothes)
		arms.append(p.clothes)
	ped_body_mm = _mm("PedBodies", Models.torso_mesh(), peds.size(), clothes)
	ped_head_mm = _mm("PedHeads", Models.head_mesh(), peds.size(), skins, 0.6)
	ped_hair_mm = _mm("PedHair", Models.hair_mesh(), peds.size(), hair, 0.7)
	ped_leg_mm = _mm("PedLegs", Models.limb_mesh(), peds.size() * 2, legs)
	ped_arm_mm = _mm("PedArms", Models.limb_mesh(), peds.size() * 2, arms)
	_draw_cars()
	_draw_peds()
