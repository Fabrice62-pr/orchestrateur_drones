extends Node3D
## Ville procédurale : grille de rues, îlots subdivisés en parcelles,
## hauteur des immeubles décroissante du centre-ville vers la périphérie, parcs.

const Look := preload("res://scripts/render/look.gd")
const Vegetation := preload("res://scripts/render/vegetation.gd")
const BUILDING_SHADER := preload("res://scripts/render/shaders/building.gdshader")
const ROAD_SHADER := preload("res://scripts/render/shaders/road.gdshader")

var max_height := 0.0

# grille des rues (utilisée par le réseau routier, la circulation et les piétons)
const ROAD_TOP := 0.155        # dessus de la chaussée
const SIDEWALK_TOP := 0.25     # dessus du trottoir
const SIDEWALK_W := 2.2        # largeur du trottoir (à l'intérieur de l'îlot)
var block := 36.0
var road := 9.0
var cols := 0
var rows := 0
var road_xs: Array = []        # x des rues nord-sud
var road_zs: Array = []        # z des rues est-ouest
var block_kind := {}           # Vector2i(ci, ri) -> "buildings" | "park" | "station"
var station_block := Vector2i(-1, -1)
var station_rect := Rect2()
var connector_row := 0         # rue est-ouest prolongée jusqu'à la forêt


func block_rect(c: Vector2i) -> Rect2:
	return Rect2(road_xs[c.x] + road * 0.5, road_zs[c.y] + road * 0.5, block, block)


func generate(terrain: Node3D, seed_val: int) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_val + 101
	var r: Rect2 = terrain.city_rect
	var center := r.get_center() + Vector2(rng.randf_range(-30.0, 30.0), rng.randf_range(-50.0, 50.0))
	# teintes d'enduit réalistes (multipliées à la texture de façade)
	var palette := [Color(0.62, 0.6, 0.56), Color(0.58, 0.56, 0.55), Color(0.66, 0.62, 0.55),
		Color(0.55, 0.57, 0.6), Color(0.64, 0.57, 0.5), Color(0.68, 0.67, 0.64), Color(0.6, 0.5, 0.45)]
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

	var tm: ShaderMaterial = terrain.get("material")
	if tm:
		tm.set_shader_parameter("city_rect", Vector4(r.position.x, r.position.y, span_x, span_z))
	var buildings: Array = []
	var roads_x: Array = []        # rues orientées selon X (est-ouest)
	var roads_z: Array = []        # rues orientées selon Z (nord-sud)
	var parks: Array = []
	var park_trees: Array = []
	var park_trunks: Array = []
	var roof_props: Array = []
	var road_col := Color(1, 1, 1)

	for ci in range(cols + 1):
		var x0 := r.position.x + ci * (block + road) + road * 0.5
		roads_z.append([Transform3D(Basis.from_scale(Vector3(road, 0.15, span_z)),
			Vector3(x0, 0.08, r.position.y + span_z * 0.5)), road_col])
	for ri in range(rows + 1):
		var z0 := r.position.y + ri * (block + road) + road * 0.5
		roads_x.append([Transform3D(Basis.from_scale(Vector3(span_x, 0.149, road)),
			Vector3(r.position.x + span_x * 0.5, 0.0805, z0)), road_col])

	var sidewalks: Array = []
	var walk_col := Color(0.58, 0.57, 0.55)
	for ci in range(cols):
		for ri in range(rows):
			var bx := r.position.x + road + ci * (block + road)
			var bz := r.position.y + road + ri * (block + road)
			var c2 := Vector2(bx + block * 0.5, bz + block * 0.5)
			# trottoirs : 4 bandes surélevées le long des bords de l'îlot
			for e in [[Vector2(c2.x, bz + SIDEWALK_W * 0.5), Vector2(block, SIDEWALK_W)],
					[Vector2(c2.x, bz + block - SIDEWALK_W * 0.5), Vector2(block, SIDEWALK_W)],
					[Vector2(bx + SIDEWALK_W * 0.5, c2.y), Vector2(SIDEWALK_W, block)],
					[Vector2(bx + block - SIDEWALK_W * 0.5, c2.y), Vector2(SIDEWALK_W, block)]]:
				var ec: Vector2 = e[0]
				var es: Vector2 = e[1]
				sidewalks.append([Transform3D(Basis.from_scale(Vector3(es.x, SIDEWALK_TOP, es.y)),
					Vector3(ec.x, SIDEWALK_TOP * 0.5, ec.y)), walk_col])
			if Vector2i(ci, ri) == station_block:
				block_kind[Vector2i(ci, ri)] = "station"
				continue
			var t := clampf(1.0 - c2.distance_to(center) / 200.0, 0.0, 1.0)
			if rng.randf() < 0.06 + (1.0 - t) * 0.06:
				block_kind[Vector2i(ci, ri)] = "park"
				parks.append([Transform3D(Basis.from_scale(Vector3(block, 0.25, block)),
					Vector3(c2.x, 0.12, c2.y)), Color(0.28, 0.48, 0.22)])
				for k in 7:
					# feuillus : fût de 2-3 m, houppier de 5-8 m de diamètre
					var s := rng.randf_range(2.6, 4.0)
					var gx := c2.x + rng.randf_range(-11.0, 11.0)
					var gz := c2.y + rng.randf_range(-11.0, 11.0)
					var crown := Vector3(gx, 0.25 + s * 0.75 + s * 0.55, gz)
					var yaw := Basis(Vector3.UP, rng.randf() * TAU)
					park_trees.append([Transform3D(yaw * Basis.from_scale(Vector3(s, s * 1.05, s)), crown),
						Vegetation.leaf_color(rng)])
					park_trunks.append([Transform3D(Basis.from_scale(Vector3(0.9, s * 1.1, 0.9)),
						Vector3(gx, 0.25 + s * 0.55, gz)), Color(0.75, 0.68, 0.6)])
					terrain.add_obstacle_disc(Vector2(gx, gz), s * 0.6, crown.y + s * 0.55)
				continue
			block_kind[Vector2i(ci, ri)] = "buildings"
			var n := rng.randi_range(1, 3) if t > 0.5 else rng.randi_range(2, 3)
			var sub := block / n
			for i in n:
				for j in n:
					if rng.randf() < 0.12 * (1.0 - t):
						continue
					var w := sub - rng.randf_range(5.0, 7.5)
					var d := sub - rng.randf_range(5.0, 7.5)
					var h := lerpf(6.0, 55.0, t * t) * rng.randf_range(0.5, 1.15)
					if rng.randf() < 0.06 * t:
						h *= 1.5
					h = clampf(h, 5.0, 70.0)
					max_height = maxf(max_height, h)
					var col: Color = palette[rng.randi() % palette.size()] * rng.randf_range(0.88, 1.05)
					col.a = 1.0
					var px := bx + sub * (i + 0.5)
					var pz := bz + sub * (j + 0.5)
					buildings.append([Transform3D(Basis.from_scale(Vector3(w, h, d)), Vector3(px, h * 0.5, pz)), col])
					terrain.add_obstacle_box(Vector2(px, pz), Vector2(w, d), h)
					_roof_props(roof_props, rng, Vector3(px, h, pz), w, d)

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


## Équipements de toit : centrales de climatisation, cage d'ascenseur, réservoirs.
func _roof_props(out: Array, rng: RandomNumberGenerator, top: Vector3, w: float, d: float) -> void:
	if w < 8.0 or d < 8.0:
		return
	var grey := Color(0.75, 0.75, 0.74)
	if rng.randf() < 0.75:   # cage d'ascenseur / escalier
		var s := Vector3(rng.randf_range(2.5, 4.0), rng.randf_range(2.4, 3.2), rng.randf_range(2.5, 4.0))
		var off := Vector3(rng.randf_range(-w, w) * 0.2, s.y * 0.5, rng.randf_range(-d, d) * 0.2)
		out.append([Transform3D(Basis.from_scale(s), top + off), grey])
	for k in rng.randi_range(1, 4):   # climatiseurs
		var s := Vector3(rng.randf_range(1.0, 2.0), rng.randf_range(0.8, 1.3), rng.randf_range(1.0, 2.2))
		var off := Vector3(rng.randf_range(-w, w) * 0.35, s.y * 0.5, rng.randf_range(-d, d) * 0.35)
		out.append([Transform3D(Basis.from_scale(s), top + off), Color(0.85, 0.85, 0.86)])


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
