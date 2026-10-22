extends Node3D
## Grande ville procédurale inspirée de Casablanca / Rabat : grille de rues de
## 12 x 20 îlots, découpée en quartiers selon la distance au centre :
##   - quartier des affaires : tours de bureaux (murs-rideaux de verre), « tours jumelles »
##   - ville nouvelle : îlots fermés d'immeubles blancs (5 à 9 étages) autour d'une cour
##   - quartiers résidentiels : petits immeubles de 3-5 étages
##   - périphérie : villas blanches avec jardin, palmier et parfois piscine
##   - médina : maisons basses serrées, ruelles, remparts ocre (city_landmarks.gd)
## Boulevards plantés de palmiers, parcs, et services publics : hôpital,
## commissariat de police, grande mosquée, place centrale, caserne de pompiers.

const Look := preload("res://scripts/render/look.gd")
const Vegetation := preload("res://scripts/render/vegetation.gd")
const LandmarksScript := preload("res://scripts/world/city_landmarks.gd")
const BUILDING_SHADER := preload("res://scripts/render/shaders/building.gdshader")
const ROAD_SHADER := preload("res://scripts/render/shaders/road.gdshader")

var max_height := 0.0

# grille des rues (utilisée par le réseau routier, la circulation et les piétons)
const ROAD_TOP := 0.155        # dessus de la chaussée
const SIDEWALK_TOP := 0.25     # dessus du trottoir
const SIDEWALK_W := 2.2        # largeur du trottoir (à l'intérieur de l'îlot)
const LOT_INSET := SIDEWALK_W + 0.6   # retrait des constructions par rapport au bord de l'îlot
var block := 36.0
var road := 9.0
var cols := 0
var rows := 0
var road_xs: Array = []        # x des rues nord-sud
var road_zs: Array = []        # z des rues est-ouest
var block_kind := {}           # Vector2i(ci, ri) -> "buildings" | "park" | "station" | "villas" | "medina" | service
var station_block := Vector2i(-1, -1)
var station_rect := Rect2()
var connector_row := 0         # rue est-ouest prolongée jusqu'à la forêt
var landmarks := {}            # "hospital" | "police" | "mosque" | "plaza" | "twin" -> Vector2i
var medina := {}               # Vector2i -> true (îlots de la médina)
var blvd_x: Array = []         # indices des rues nord-sud plantées de palmiers
var blvd_z: Array = []         # indices des rues est-ouest plantées de palmiers

# enduits : blancs cassés et sables (Casablanca « la ville blanche »), ocres (Rabat)
const WHITES := [Color(0.95, 0.94, 0.9), Color(0.92, 0.9, 0.85), Color(0.9, 0.86, 0.78), Color(0.97, 0.96, 0.93),
	Color(0.88, 0.84, 0.76), Color(0.93, 0.91, 0.88)]
const OCHRES := [Color(0.86, 0.68, 0.52), Color(0.82, 0.62, 0.47), Color(0.9, 0.76, 0.6), Color(0.84, 0.72, 0.6)]
const GLASS := [Color(0.35, 0.5, 0.65), Color(0.3, 0.45, 0.5), Color(0.52, 0.56, 0.62), Color(0.62, 0.52, 0.34),
	Color(0.28, 0.38, 0.55)]

var terrain: Node3D
var rng := RandomNumberGenerator.new()
var buildings: Array = []
var roof_props: Array = []
var parks: Array = []
var park_trees: Array = []
var park_trunks: Array = []
var palm_crowns: Array = []
var palm_trunks: Array = []
var pools: Array = []


func block_rect(c: Vector2i) -> Rect2:
	return Rect2(road_xs[c.x] + road * 0.5, road_zs[c.y] + road * 0.5, block, block)


## Emprise constructible d'un îlot (sans les trottoirs).
func lot_rect(c: Vector2i) -> Rect2:
	return block_rect(c).grow(-LOT_INSET)


@warning_ignore("integer_division")
func generate(t: Node3D, seed_val: int) -> void:
	terrain = t
	rng.seed = seed_val + 101
	var r: Rect2 = terrain.city_rect
	cols = int((r.size.x - road) / (block + road))
	rows = int((r.size.y - road) / (block + road))
	road_xs.clear()
	road_zs.clear()
	for ci in range(cols + 1):
		road_xs.append(r.position.x + ci * (block + road) + road * 0.5)
	for ri in range(rows + 1):
		road_zs.append(r.position.y + ri * (block + road) + road * 0.5)
	# la caserne occupe l'îlot de l'est de la ville bordé par la rue qui mène à la forêt
	var best := INF
	for ri in range(rows + 1):
		if absf(road_zs[ri] - 55.0) < best:
			best = absf(road_zs[ri] - 55.0)
			connector_row = ri
	station_block = Vector2i(cols - 1, mini(connector_row, rows - 1))
	station_rect = block_rect(station_block)
	var span_x := cols * (block + road) + road
	var span_z := rows * (block + road) + road
	_plan_districts()

	var tm: ShaderMaterial = terrain.get("material")
	if tm:
		tm.set_shader_parameter("city_rect", Vector4(r.position.x, r.position.y, span_x, span_z))
	var roads_x: Array = []        # rues orientées selon X (est-ouest)
	var roads_z: Array = []        # rues orientées selon Z (nord-sud)
	var road_col := Color(1, 1, 1)
	for ci in range(cols + 1):
		roads_z.append([Transform3D(Basis.from_scale(Vector3(road, 0.15, span_z)),
			Vector3(road_xs[ci], 0.08, r.position.y + span_z * 0.5)), road_col])
	for ri in range(rows + 1):
		roads_x.append([Transform3D(Basis.from_scale(Vector3(span_x, 0.149, road)),
			Vector3(r.position.x + span_x * 0.5, 0.0805, road_zs[ri])), road_col])

	var sidewalks: Array = []
	var walk_col := Color(0.58, 0.57, 0.55)
	var center := Vector2(road_xs[cols / 2], road_zs[rows / 2])
	for ci in range(cols):
		for ri in range(rows):
			var key := Vector2i(ci, ri)
			var br := block_rect(key)
			var bx := br.position.x
			var bz := br.position.y
			var c2 := br.get_center()
			# trottoirs : 4 bandes surélevées le long des bords de l'îlot
			for e in [[Vector2(c2.x, bz + SIDEWALK_W * 0.5), Vector2(block, SIDEWALK_W)],
					[Vector2(c2.x, bz + block - SIDEWALK_W * 0.5), Vector2(block, SIDEWALK_W)],
					[Vector2(bx + SIDEWALK_W * 0.5, c2.y), Vector2(SIDEWALK_W, block)],
					[Vector2(bx + block - SIDEWALK_W * 0.5, c2.y), Vector2(SIDEWALK_W, block)]]:
				var ec: Vector2 = e[0]
				var es: Vector2 = e[1]
				sidewalks.append([Transform3D(Basis.from_scale(Vector3(es.x, SIDEWALK_TOP, es.y)),
					Vector3(ec.x, SIDEWALK_TOP * 0.5, ec.y)), walk_col])
			if block_kind.has(key):   # îlots réservés (caserne, services, médina)
				_special_block(key)
				continue
			var d := c2.distance_to(center)
			var lot := lot_rect(key)
			if rng.randf() < (0.04 if d < 200.0 else 0.08):
				block_kind[key] = "park"
				_park(br, false)
			elif d < 125.0:
				block_kind[key] = "buildings"
				_downtown(lot, 1.0 - d / 125.0)
			elif d < 300.0:
				block_kind[key] = "buildings"
				_closed_block(lot, 1.0 - (d - 125.0) / 175.0)
			elif d < 390.0 or rng.randf() < 0.3:
				block_kind[key] = "buildings"
				_residential(lot)
			else:
				block_kind[key] = "villas"
				_villas(lot)
	_boulevard_palms()

	var box := BoxMesh.new()
	var smat := ShaderMaterial.new()
	smat.shader = BUILDING_SHADER
	for pair in [["fa", "facade_a"], ["fb", "facade_b"], ["fc", "facade_c"], ["fd", "facade_d"], ["roof", "roof"]]:
		smat.set_shader_parameter(pair[0] + "_d", Look.tex(pair[1], "diff"))
		smat.set_shader_parameter(pair[0] + "_n", Look.tex(pair[1], "nor"))
	_multimesh("Buildings", buildings, box, smat)
	_multimesh("RoofEquipment", roof_props, BoxMesh.new(), Look.pbr("concrete", 2.0, Color(0.72, 0.75, 0.8), true))

	for k in 2:
		var rm := ShaderMaterial.new()
		rm.shader = ROAD_SHADER
		rm.set_shader_parameter("asp_d", Look.tex("asphalt", "diff"))
		rm.set_shader_parameter("asp_n", Look.tex("asphalt", "nor"))
		rm.set_shader_parameter("asp_a", Look.tex("asphalt", "arm"))
		rm.set_shader_parameter("grid_origin", Vector2(road_xs[0], road_zs[0]))
		rm.set_shader_parameter("grid_step", block + road)
		rm.set_shader_parameter("road_width", road)
		rm.set_shader_parameter("axis", k)
		_multimesh("RoadsX" if k == 0 else "RoadsZ", roads_x if k == 0 else roads_z, BoxMesh.new(), rm)
	_multimesh("Parks", parks, BoxMesh.new(), Look.pbr("park_grass", 3.0, Color(0.85, 0.95, 0.75)))
	_multimesh("Sidewalks", sidewalks, BoxMesh.new(), Look.pbr("sidewalk", 2.5, Color(0.95, 0.97, 1.0)))
	_multimesh("ParkTrees", park_trees, Vegetation.broadleaf_mesh(), Vegetation.foliage_material())
	_multimesh("ParkTrunks", park_trunks, Vegetation.trunk_mesh(), Vegetation.trunk_material())
	_multimesh("PalmCrowns", palm_crowns, Vegetation.palm_crown_mesh(), Vegetation.foliage_material())
	_multimesh("PalmTrunks", palm_trunks, Vegetation.trunk_mesh(), Vegetation.trunk_material())
	var pool_mat := StandardMaterial3D.new()
	pool_mat.vertex_color_use_as_albedo = true
	pool_mat.roughness = 0.05
	pool_mat.metallic = 0.2
	_multimesh("Pools", pools, BoxMesh.new(), pool_mat)

	var lm := LandmarksScript.new()   # services publics, médina, mosquée, place centrale
	lm.name = "Landmarks"
	add_child(lm)
	lm.build(self, terrain, seed_val)


## Réserve les îlots des services publics et de la médina (positions fixes dans la grille).
@warning_ignore("integer_division")
func _plan_districts() -> void:
	block_kind.clear()
	landmarks.clear()
	medina.clear()
	block_kind[station_block] = "station"
	var mid := Vector2i(cols / 2, rows / 2)
	var wanted := {
		"plaza": mid + Vector2i(0, -1),       # place centrale (fontaine, palmiers)
		"twin": mid + Vector2i(-1, 0),        # tours jumelles du quartier des affaires
		"hospital": mid + Vector2i(2, -4),
		"police": mid + Vector2i(1, 2),
		"mosque": Vector2i(2, rows - 5),
		"sawmill": Vector2i(cols / 2 - 1, rows - 1),   # scierie + marché du bois, en lisière sud
	}
	for k in wanted:
		var key: Vector2i = wanted[k]
		key = Vector2i(clampi(key.x, 0, cols - 2), clampi(key.y, 0, rows - 1))
		if block_kind.has(key):
			continue
		landmarks[k] = key
		block_kind[key] = "park" if k == "plaza" else ("buildings" if k == "twin" else k)
	# médina : 3 x 4 îlots au nord-ouest
	for ci in range(1, mini(4, cols)):
		for ri in range(3, mini(7, rows)):
			var key := Vector2i(ci, ri)
			if not block_kind.has(key):
				medina[key] = true
				block_kind[key] = "medina"
	# boulevards : rue de la forêt + quelques grands axes
	blvd_x = [3, 6, 9]
	blvd_z = [4, connector_row, 16]


func _special_block(key: Vector2i) -> void:
	var lot := lot_rect(key)
	var c := lot.get_center()
	if medina.has(key):
		_medina(lot)
	elif landmarks.get("twin", Vector2i(-1, -1)) == key:
		_twin_towers(lot)
	elif landmarks.get("plaza", Vector2i(-1, -1)) == key:
		_park(block_rect(key), true)
	elif landmarks.get("hospital", Vector2i(-1, -1)) == key:
		# aile principale (8 étages) + aile ouest ; la cour sud-est reste aux ambulances
		_bld(Vector2(c.x, lot.position.y + 7.0), Vector3(lot.size.x, 26.0, 14.0), Color(0.97, 0.97, 0.95, 0.75))
		_bld(Vector2(lot.position.x + 6.0, c.y + 6.5), Vector3(12.0, 14.0, 17.0), Color(0.95, 0.95, 0.93, 0.75))
	elif landmarks.get("police", Vector2i(-1, -1)) == key:
		_bld(Vector2(c.x, lot.position.y + 7.5), Vector3(lot.size.x - 2.0, 13.0, 15.0), Color(0.86, 0.9, 0.98, 0.75))
	# mosquée, caserne et scierie : construites par leurs propres scripts


# ------------------------------------------------------------ quartiers

## Quartier des affaires : socle commercial + tour(s) de bureaux.
func _downtown(lot: Rect2, t: float) -> void:
	var c := lot.get_center()
	var podium := rng.randf_range(6.5, 9.5)
	_bld(c, Vector3(lot.size.x, podium, lot.size.y), _white())
	if rng.randf() < 0.55:
		var w := rng.randf_range(16.0, 22.0)
		var h := lerpf(45.0, 100.0, t) * rng.randf_range(0.85, 1.1)
		var off := Vector2(rng.randf_range(-3.0, 3.0), rng.randf_range(-3.0, 3.0))
		_bld(c + off, Vector3(w, h, w * rng.randf_range(0.75, 1.1)), _tower_color())
	else:
		var sx := 1.0 if rng.randf() < 0.5 else -1.0
		for k in 2:
			var sgn := 1.0 if k == 0 else -1.0
			var w := rng.randf_range(11.0, 14.0)
			var h := lerpf(32.0, 78.0, t) * rng.randf_range(0.75, 1.1)
			_bld(c + Vector2(sx * sgn, sgn) * lot.size.x * 0.24, Vector3(w, h, w), _tower_color())


## Tours jumelles sur un socle commun (silhouette du centre d'affaires).
func _twin_towers(lot: Rect2) -> void:
	var c := lot.get_center()
	_bld(c, Vector3(lot.size.x, 11.0, lot.size.y), Color(0.9, 0.88, 0.84, 0.75))
	for sgn: float in [-1.0, 1.0]:
		var p: Vector2 = c + Vector2(sgn, sgn) * 7.6
		_bld(p, Vector3(13.0, 112.0, 13.0), Color(0.36, 0.48, 0.6, 0.3))
		roof_props.append([Transform3D(Basis.from_scale(Vector3(7.0, 6.0, 7.0)), Vector3(p.x, 115.0, p.y)), Color(0.5, 0.52, 0.55)])
		roof_props.append([Transform3D(Basis.from_scale(Vector3(0.4, 14.0, 0.4)), Vector3(p.x, 125.0, p.y)), Color(0.8, 0.8, 0.82)])
		terrain.add_obstacle_box(p, Vector2(7.0, 7.0), 132.0)


## Ville nouvelle : îlot fermé d'immeubles mitoyens autour d'une cour intérieure.
func _closed_block(lot: Rect2, t: float) -> void:
	var depth := rng.randf_range(10.0, 12.5)
	var base_h := lerpf(15.0, 30.0, t)
	var L := lot.size.x
	_row(Vector2(lot.position.x, lot.position.y + depth * 0.5), L, depth, true, base_h)
	_row(Vector2(lot.position.x, lot.end.y - depth * 0.5), L, depth, true, base_h)
	_row(Vector2(lot.position.x + depth * 0.5, lot.position.y + depth), L - depth * 2.0, depth, false, base_h)
	_row(Vector2(lot.end.x - depth * 0.5, lot.position.y + depth), L - depth * 2.0, depth, false, base_h)


## Rangée d'immeubles mitoyens de hauteurs différentes, le long de x (along_x) ou de z.
func _row(start: Vector2, length: float, depth: float, along_x: bool, base_h: float) -> void:
	var n := rng.randi_range(2, 3)
	var cuts: Array = [0.0]
	for k in n - 1:
		cuts.append(length * (k + 1) / n + rng.randf_range(-2.0, 2.0))
	cuts.append(length)
	for k in n:
		var a: float = cuts[k]
		var b: float = cuts[k + 1]
		var mid := (a + b) * 0.5
		var floors := maxi(3, int(round((base_h * rng.randf_range(0.8, 1.2) - 4.2) / 3.15)))
		var h := 4.2 + floors * 3.15
		var col := _white() if rng.randf() < 0.8 else _ochre()
		if along_x:
			_bld(Vector2(start.x + mid, start.y), Vector3(b - a, h, depth), col)
		else:
			_bld(Vector2(start.x, start.y + mid), Vector3(depth, h, b - a), col)


## Quartier résidentiel : quatre petits immeubles de 3 à 5 étages.
func _residential(lot: Rect2) -> void:
	var half := lot.size.x * 0.5
	for i in 2:
		for j in 2:
			if rng.randf() < 0.1:
				continue
			var w := half - rng.randf_range(2.0, 4.0)
			var d := half - rng.randf_range(2.0, 4.0)
			var h := 4.2 + rng.randi_range(2, 4) * 3.15
			_bld(lot.position + Vector2(half * (i + 0.5), half * (j + 0.5)), Vector3(w, h, d),
				_white() if rng.randf() < 0.75 else _ochre())


## Périphérie : 9 villas avec jardin, palmier ou arbre, parfois une piscine.
func _villas(lot: Rect2) -> void:
	parks.append([Transform3D(Basis.from_scale(Vector3(lot.size.x, 0.27, lot.size.y)),
		Vector3(lot.get_center().x, 0.135, lot.get_center().y)), Color(0.3, 0.46, 0.22)])
	var cell := lot.size.x / 3.0
	for i in 3:
		for j in 3:
			var o := lot.position + Vector2(cell * (i + 0.5), cell * (j + 0.5))
			var corner := Vector2(1.0 if i == 2 else (-1.0 if i == 0 else (1.0 if rng.randf() < 0.5 else -1.0)),
				1.0 if j == 2 else (-1.0 if j == 0 else (1.0 if rng.randf() < 0.5 else -1.0)))
			var w := rng.randf_range(5.5, 7.0)
			var d := rng.randf_range(5.5, 7.0)
			var hp := o + corner * Vector2(cell * 0.5 - w * 0.5 - 0.6, cell * 0.5 - d * 0.5 - 0.6)
			_bld(hp, Vector3(w, rng.randf_range(6.6, 7.6), d), _white() if rng.randf() < 0.7 else _ochre())
			var g := o - corner * 2.2   # jardin : côté opposé à la maison
			if rng.randf() < 0.3:
				pools.append([Transform3D(Basis.from_scale(Vector3(3.6, 0.06, 2.2)), Vector3(g.x, 0.3, g.y)),
					Color(0.15, 0.6, 0.72)])
			elif rng.randf() < 0.6:
				_palm(g, 0.27, rng.randf_range(5.0, 8.0))
			else:
				_tree(g, 0.27, rng.randf_range(2.0, 3.0))


## Médina : maisons basses à toits-terrasses serrées le long de ruelles étroites.
func _medina(lot: Rect2) -> void:
	var area := lot.grow(-0.8)   # place pour les remparts sur les bords extérieurs
	var n := 5
	var cell := area.size.x / n
	for i in n:
		for j in n:
			if rng.randf() < 0.08:
				continue   # petite cour / placette
			var w := cell - rng.randf_range(0.3, 1.1)
			var d := cell - rng.randf_range(0.3, 1.1)
			var h := rng.randf_range(4.6, 10.5)
			var p := area.position + Vector2(cell * (i + 0.5), cell * (j + 0.5))
			_bld(p, Vector3(w, h, d), _white() if rng.randf() < 0.65 else _ochre(), false)


## Parc de quartier (feuillus) ou place centrale (palmiers ; fontaine posée par Landmarks).
func _park(br: Rect2, plaza: bool) -> void:
	var c2 := br.get_center()
	parks.append([Transform3D(Basis.from_scale(Vector3(block, 0.25, block)),
		Vector3(c2.x, 0.12, c2.y)), Color(0.28, 0.48, 0.22)])
	if plaza:
		for k in 10:
			var a := k * TAU / 10.0
			_palm(c2 + Vector2(cos(a), sin(a)) * 12.5, 0.25, rng.randf_range(8.0, 11.0))
		return
	for k in 7:
		var g := c2 + Vector2(rng.randf_range(-11.0, 11.0), rng.randf_range(-11.0, 11.0))
		_tree(g, 0.25, rng.randf_range(2.6, 4.0))


## Palmiers alignés sur les trottoirs des boulevards (côté chaussée), hors carrefours.
func _boulevard_palms() -> void:
	var off := road * 0.5 + 0.55
	for k in blvd_x:
		if k <= 0 or k >= road_xs.size() - 1:
			continue
		var x: float = road_xs[k]
		var z: float = road_zs[0]
		while z <= road_zs[road_zs.size() - 1]:
			if _clear_of_crossings(z, road_zs):
				for sd: float in [-1.0, 1.0]:
					_palm(Vector2(x + sd * off, z), SIDEWALK_TOP, rng.randf_range(7.5, 10.5))
			z += 9.0
	for k in blvd_z:
		if k <= 0 or k >= road_zs.size() - 1:
			continue
		var z2: float = road_zs[k]
		var x2: float = road_xs[0]
		while x2 <= road_xs[road_xs.size() - 1]:
			if _clear_of_crossings(x2, road_xs):
				for sd: float in [-1.0, 1.0]:
					var p := Vector2(x2, z2 + sd * off)
					if not station_rect.grow(1.0).has_point(p):
						_palm(p, SIDEWALK_TOP, rng.randf_range(7.5, 10.5))
			x2 += 9.0


func _clear_of_crossings(v: float, lines: Array) -> bool:
	for l in lines:
		if absf(v - float(l)) < road * 0.5 + 2.5:
			return false
	return true


# ------------------------------------------------------------ éléments

## Immeuble (boîte unité mise à l'échelle, rendu par le shader des façades).
func _bld(p: Vector2, size: Vector3, col: Color, props := true) -> void:
	max_height = maxf(max_height, size.y)
	buildings.append([Transform3D(Basis.from_scale(size), Vector3(p.x, size.y * 0.5, p.y)), col])
	terrain.add_obstacle_box(p, Vector2(size.x, size.z), size.y)
	if props:
		_roof_props(Vector3(p.x, size.y, p.y), size.x, size.z)


func _palm(p: Vector2, ground: float, h: float) -> void:
	var lean := Basis(Vector3(rng.randf_range(-1, 1), 0, rng.randf_range(-1, 1)).normalized(), rng.randf_range(0.0, 0.06))
	palm_trunks.append([Transform3D(lean * Basis.from_scale(Vector3(1.15, h, 1.15)), Vector3(p.x, ground + h * 0.5, p.y)),
		Color(0.82, 0.74, 0.62)])
	var top := Vector3(p.x, ground, p.y) + lean * Vector3(0, h, 0)
	var s := rng.randf_range(3.0, 3.8)
	palm_crowns.append([Transform3D(Basis(Vector3.UP, rng.randf() * TAU) * Basis.from_scale(Vector3(s, s * 0.75, s)),
		top - Vector3(0, 0.3 * s * 0.75, 0)), Color(0.1, 0.2, 0.06).lerp(Color(0.2, 0.27, 0.08), rng.randf())])


func _tree(p: Vector2, ground: float, s: float) -> void:
	var crown := Vector3(p.x, ground + s * 0.75 + s * 0.55, p.y)
	park_trees.append([Transform3D(Basis(Vector3.UP, rng.randf() * TAU) * Basis.from_scale(Vector3(s, s * 1.05, s)), crown),
		Vegetation.leaf_color(rng)])
	park_trunks.append([Transform3D(Basis.from_scale(Vector3(0.9, s * 1.1, 0.9)), Vector3(p.x, ground + s * 0.55, p.y)),
		Color(0.75, 0.68, 0.6)])
	terrain.add_obstacle_disc(p, s * 0.6, crown.y + s * 0.55)


func _white() -> Color:
	var c: Color = WHITES[rng.randi() % WHITES.size()] * rng.randf_range(0.94, 1.02)
	c.a = 0.75   # enduit uniquement (voir building.gdshader)
	return c


func _ochre() -> Color:
	var c: Color = OCHRES[rng.randi() % OCHRES.size()] * rng.randf_range(0.94, 1.03)
	c.a = 0.75
	return c


func _tower_color() -> Color:
	if rng.randf() < 0.7:
		var g: Color = GLASS[rng.randi() % GLASS.size()]
		g.a = 0.3   # mur-rideau en verre
		return g
	return _white()


## Équipements de toit : centrales de climatisation, cage d'ascenseur, réservoirs.
func _roof_props(top: Vector3, w: float, d: float) -> void:
	if w < 8.0 or d < 8.0:
		return
	var grey := Color(0.75, 0.75, 0.74)
	if rng.randf() < 0.75:   # cage d'ascenseur / escalier
		var s := Vector3(rng.randf_range(2.5, 4.0), rng.randf_range(2.4, 3.2), rng.randf_range(2.5, 4.0))
		var off := Vector3(rng.randf_range(-w, w) * 0.2, s.y * 0.5, rng.randf_range(-d, d) * 0.2)
		roof_props.append([Transform3D(Basis.from_scale(s), top + off), grey])
	for k in rng.randi_range(1, 4):   # climatiseurs, chauffe-eau solaires
		var s := Vector3(rng.randf_range(1.0, 2.0), rng.randf_range(0.8, 1.3), rng.randf_range(1.0, 2.2))
		var off := Vector3(rng.randf_range(-w, w) * 0.35, s.y * 0.5, rng.randf_range(-d, d) * 0.35)
		roof_props.append([Transform3D(Basis.from_scale(s), top + off), Color(0.85, 0.85, 0.86)])


func _multimesh(node_name: String, items: Array, mesh: Mesh, mat: Material) -> void:
	if items.is_empty():
		return
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.mesh = mesh
	mm.instance_count = items.size()
	for k in items.size():
		mm.set_instance_transform(k, items[k][0])
		mm.set_instance_color(k, items[k][1])
	var mmi := MultiMeshInstance3D.new()
	mmi.name = node_name
	mmi.multimesh = mm
	mmi.material_override = mat
	add_child(mmi)
