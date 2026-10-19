extends Node3D
## Réseau routier : graphe des rues de la ville + route d'accès + pistes forestières
## (pistes DFCI de défense contre l'incendie) qui quadrillent la forêt.
##
## - Les voitures de la ville n'utilisent que les rues (arêtes « car »).
## - Les camions de pompiers utilisent tout le réseau : caserne -> rues -> route
##   d'accès -> piste forestière la plus proche du feu.

const TRACK_STEP := 10.0       # espacement des nœuds sur les pistes (points d'arrêt possibles)
const FIREBREAK_SPACING := 75.0

var nodes: Array = []          # Vector2 (x, z)
var kinds: Array = []          # "city" | "station" | "link" | "track"
var adj: Array = []            # Array[Array[int]]
var city_index := {}           # Vector2i(ci, ri) -> id du carrefour
var station_entry := -1        # nœud devant la caserne, sur la rue
var station_spots: Array = []  # nœuds de stationnement des camions
var segments: Array = []       # [Vector2 a, Vector2 b, String type] hors ville (route d'accès, pistes)
var track_x := 0.0
var firebreak_zs: Array = []


func build(terrain: Node3D, city: Node3D) -> void:
	var fr: Rect2 = terrain.forest_rect
	# --- carrefours de la ville
	for ri in range(city.rows + 1):
		for ci in range(city.cols + 1):
			city_index[Vector2i(ci, ri)] = _add(Vector2(city.road_xs[ci], city.road_zs[ri]), "city")
	var R: int = city.connector_row
	var sb: Vector2i = city.station_block
	var srect: Rect2 = city.station_rect
	for ri in range(city.rows + 1):
		for ci in range(city.cols + 1):
			var a: int = city_index[Vector2i(ci, ri)]
			if ci < city.cols:
				var b: int = city_index[Vector2i(ci + 1, ri)]
				if ri == R and ci == sb.x:
					# la rue devant la caserne est coupée par l'entrée de la caserne
					station_entry = _add(Vector2(srect.get_center().x, city.road_zs[R]), "city")
					_link(a, station_entry)
					_link(station_entry, b)
				else:
					_link(a, b)
			if ri < city.rows:
				_link(a, city_index[Vector2i(ci, ri + 1)])
	# --- places de stationnement des camions (devant les remises, face à la rue)
	for k in 2:
		var spot := _add(Vector2(srect.get_center().x + (k - 0.5) * 14.0, srect.position.y + 10.0), "station")
		_link(spot, station_entry)
		station_spots.append(spot)
	# --- route d'accès : de la ville jusqu'à la piste qui longe l'ouest de la forêt
	track_x = fr.position.x + 6.0
	var zc: float = city.road_zs[R]
	var city_end: int = city_index[Vector2i(city.cols, R)]
	firebreak_zs = [zc]
	var z := zc - FIREBREAK_SPACING
	var lake_c: Vector2 = terrain.lake_center2
	var lake_keep: float = terrain.lake_radius * 1.8   # pas de piste qui traverse le lac
	while z > fr.position.y + 12.0:
		if absf(z - lake_c.y) > lake_keep:
			firebreak_zs.append(z)
		z -= FIREBREAK_SPACING
	z = zc + FIREBREAK_SPACING
	while z < fr.end.y - 10.0:
		if absf(z - lake_c.y) > lake_keep:
			firebreak_zs.append(z)
		z += FIREBREAK_SPACING
	firebreak_zs.sort()
	# --- piste de lisière (nord-sud)
	var zs: Array = []
	z = fr.position.y + 6.0
	while z <= fr.end.y - 6.0:
		zs.append(z)
		z += TRACK_STEP
	for f in firebreak_zs:
		var dup := false
		for v in zs:
			if absf(v - f) < 3.0:
				dup = true
		if not dup:
			zs.append(f)
	zs.sort()
	var col_ids := {}
	var prev := -1
	for v in zs:
		var id := _add(Vector2(track_x, v), "track")
		col_ids[v] = id
		if prev >= 0:
			_link(prev, id)
		prev = id
	segments.append([Vector2(track_x, zs[0]), Vector2(track_x, zs[zs.size() - 1]), "track"])
	# raccord de la route d'accès sur le nœud de lisière le plus proche de zc
	var junction := _closest_in(col_ids, zc)
	_link(city_end, junction)
	segments.append([nodes[city_end], nodes[junction], "road"])
	# --- pistes est-ouest (pare-feu)
	for f in firebreak_zs:
		var start := _closest_in(col_ids, f)
		var x := track_x + TRACK_STEP
		prev = start
		while x <= fr.end.x - 6.0:
			var id := _add(Vector2(x, nodes[start].y), "track")
			_link(prev, id)
			prev = id
			x += TRACK_STEP
		segments.append([nodes[start], nodes[prev], "track"])
	_build_visuals(terrain)


func _add(p: Vector2, kind: String) -> int:
	nodes.append(p)
	kinds.append(kind)
	adj.append([])
	return nodes.size() - 1


func _link(a: int, b: int) -> void:
	if not (b in adj[a]):
		adj[a].append(b)
		adj[b].append(a)


func _closest_in(ids: Dictionary, z: float) -> int:
	var best := -1
	var bd := INF
	for v in ids:
		if absf(v - z) < bd:
			bd = absf(v - z)
			best = ids[v]
	return best


## Arête praticable par les voitures de la ville (rues uniquement).
func is_car_edge(a: int, b: int) -> bool:
	return kinds[a] == "city" and kinds[b] == "city"


func nearest_node(p: Vector2, allowed: Array = []) -> int:
	var best := -1
	var bd := INF
	for i in nodes.size():
		if not allowed.is_empty() and not (kinds[i] in allowed):
			continue
		var d: float = p.distance_squared_to(nodes[i])
		if d < bd:
			bd = d
			best = i
	return best


## Plus court chemin (Dijkstra) : liste d'identifiants de nœuds, départ et arrivée compris.
func path(from_id: int, to_id: int) -> Array:
	var n := nodes.size()
	var dist := []
	var prev := []
	dist.resize(n)
	prev.resize(n)
	for i in n:
		dist[i] = INF
		prev[i] = -1
	dist[from_id] = 0.0
	var open := {from_id: true}
	while not open.is_empty():
		var u := -1
		var du := INF
		for k in open:
			if dist[k] < du:
				du = dist[k]
				u = k
		open.erase(u)
		if u == to_id:
			break
		var pu: Vector2 = nodes[u]
		for v in adj[u]:
			var nd: float = du + pu.distance_to(nodes[v])
			if nd < dist[v]:
				dist[v] = nd
				prev[v] = u
				open[v] = true
	if from_id != to_id and prev[to_id] == -1:
		return []
	var out: Array = [to_id]
	var c := to_id
	while c != from_id:
		c = prev[c]
		out.push_front(c)
	return out


## Distance d'un point aux pistes et à la route d'accès (hors ville).
func distance_to_tracks(p: Vector2) -> float:
	var best := INF
	for sgt in segments:
		best = minf(best, p.distance_to(Geometry2D.get_closest_point_to_segment(p, sgt[0], sgt[1])))
	return best


# ------------------------------------------------------------ visuel

## Tracé visible de la route d'accès et des pistes : désactivé par défaut (les camions
## les empruntent quand même) — data/config.json -> "roads": {"show_forest_tracks": true}.
func _build_visuals(terrain: Node3D) -> void:
	if not bool(GameState.cfgv("roads", "show_forest_tracks", false)):
		return
	for sgt in segments:
		var road: bool = sgt[2] == "road"
		_ribbon(terrain, sgt[0], sgt[1], 8.0 if road else 6.0,
			Color(0.16, 0.16, 0.17) if road else Color(0.45, 0.36, 0.24))


## Bande qui épouse le relief entre a et b.
func _ribbon(terrain: Node3D, a: Vector2, b: Vector2, width: float, col: Color) -> void:
	var dir := (b - a).normalized()
	var side := Vector2(-dir.y, dir.x) * width * 0.5
	var steps := maxi(1, int(a.distance_to(b) / 2.0))
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	st.set_color(col)
	st.set_normal(Vector3.UP)
	for k in steps + 1:
		var p := a.lerp(b, float(k) / steps)
		for q in [p + side, p - side]:
			st.add_vertex(Vector3(q.x, terrain.height_at(q.x, q.y) + 0.25, q.y))
	for k in steps:
		var i := k * 2
		st.add_index(i)
		st.add_index(i + 2)
		st.add_index(i + 1)
		st.add_index(i + 1)
		st.add_index(i + 2)
		st.add_index(i + 3)
	var mi := MeshInstance3D.new()
	mi.mesh = st.commit()
	var m := StandardMaterial3D.new()
	m.vertex_color_use_as_albedo = true
	m.roughness = 0.95
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	mi.material_override = m
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)
