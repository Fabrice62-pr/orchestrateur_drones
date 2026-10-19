extends Node3D
## Terrain procédural (bruit fractal) découpé en zones :
## ville aplanie à l'ouest, base des drones, collines boisées à l'est, lac au sud-est.
## height_at() est la fonction de référence utilisée par tous les systèmes.

const SIZE := 1200.0   # côté de la carte jouable (m)
const STEP := 4.0      # résolution du maillage de terrain
const Look := preload("res://scripts/render/look.gd")
const TERRAIN_SHADER := preload("res://scripts/render/shaders/terrain.gdshader")
const WATER_SHADER := preload("res://scripts/render/shaders/water.gdshader")
const FAR_SIZE := 5200.0       # paysage lointain autour de la carte

var material: ShaderMaterial   # partagé avec la forêt (carte de brûlure)
var lake_material: ShaderMaterial   # eau (lac et bassin)

var noise := FastNoiseLite.new()
var detail := FastNoiseLite.new()

var city_rect := Rect2(-205.0, -175.0, 215.0, 350.0)
var forest_rect := Rect2(48.0, -330.0, 512.0, 660.0)   # grand massif à l'est de la ville et de la base
var lake_center2 := Vector2(122.0, -168.0)
var lake_radius := 36.0
var water_level := -2.0
var base_pos2 := Vector2(26.0, 0.0)
var base_radius := 36.0
# bassin DFCI (réserve d'eau en forêt) : second point de remplissage des drones
var basin_center := Vector2(390.0, 15.0)
var basin_size := 30.0
var basin_ground := INF    # altitude de la plateforme (calculée à la génération)
var basin_water := 0.0
# maison forestière (poste des gardes forestiers) à l'entrée de la forêt,
# près du carrefour route d'accès / piste de lisière
var ranger_center := Vector2(82.0, 37.0)
var ranger_size := Vector2(40.0, 32.0)
var ranger_ground := INF
var ranger_parking := Rect2(64.0, 37.0, 36.0, 13.0)   # aire gravillonnée devant le bâtiment
# parcs de loisirs en forêt : clairières aplanies. Même plan pour chaque parc :
# zone -> [décalage depuis l'origine du parc, rayon du plat].
const PARK_LAYOUT := {
	"playground": [Vector2(0.0, 0.0), 22.0],    # aire de jeux pour enfants
	"pond": [Vector2(66.0, 0.0), 26.0],         # étang (point d'eau)
	"picnic": [Vector2(3.0, 75.0), 28.0],       # pelouse de pique-nique
	"relax": [Vector2(76.0, 75.0), 22.0],       # espace détente
}
# nord-est (la piste z ≈ 204 sert d'allée centrale) et sud, entre le lac et le bassin DFCI
var park_origins := [Vector2(200.0, 167.0), Vector2(340.0, -205.0)]
var park_zones: Array = []    # par parc : zone -> [centre, rayon]
var park_ground: Array = []   # par parc : zone -> altitude du plat (calculée à la génération)
var pond_radius := 15.0       # rayon du plan d'eau
var pond_water: Array = []    # par parc : altitude de l'eau de l'étang


func generate(seed_val: int) -> void:
	noise.seed = seed_val
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	noise.frequency = 0.006
	noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	noise.fractal_octaves = 4
	detail.seed = seed_val + 7
	detail.frequency = 0.04
	basin_ground = INF
	basin_ground = height_at(basin_center.x, basin_center.y)
	basin_water = basin_ground + 1.2
	ranger_ground = INF
	ranger_ground = height_at(ranger_center.x, ranger_center.y)
	park_zones.clear()
	park_ground.clear()
	pond_water.clear()
	for o in park_origins:
		var zones := {}
		for k in PARK_LAYOUT:
			zones[k] = [o + PARK_LAYOUT[k][0], PARK_LAYOUT[k][1]]
		park_zones.append(zones)
	for i in park_zones.size():
		var g := {}
		for k in park_zones[i]:
			var zc: Vector2 = park_zones[i][k][0]
			g[k] = height_at(zc.x, zc.y)
		park_ground.append(g)   # ajouté après calcul : altitude prise sur le relief naturel
		pond_water.append(g["pond"] - 0.7)
	_build_mesh()
	_build_water()
	_build_basin()
	_build_pond()
	_build_outer_ground()
	_init_obstacles()
	_register_basin_obstacle()


# ------------------------------------------------------------ obstacles
## Grille des hauteurs d'obstacles (sol, eau, immeubles, arbres...) : sert aux
## drones pour ne jamais traverser le décor. Les obstacles sont ajoutés par la
## ville, la forêt et la base après la génération du terrain.

const OBS_STEP := 2.5
var obs_n := 0
var obs_top := PackedFloat32Array()


func _init_obstacles() -> void:
	obs_n = int(SIZE / OBS_STEP)
	obs_top.resize(obs_n * obs_n)
	var half := SIZE * 0.5
	for j in obs_n:
		for i in obs_n:
			var x := -half + (i + 0.5) * OBS_STEP
			var z := -half + (j + 0.5) * OBS_STEP
			var h := height_at(x, z)
			# relief : on prend le point le plus haut de la cellule
			for o in [Vector2(-1.25, -1.25), Vector2(1.25, 1.25)]:
				h = maxf(h, height_at(x + o.x, z + o.y))
			if Vector2(x, z).distance_to(lake_center2) < lake_radius * 1.45:
				h = maxf(h, water_level)
			for w in pond_water.size():
				if Vector2(x, z).distance_to(pond_center(w)) < pond_radius:
					h = maxf(h, pond_water[w])
			obs_top[j * obs_n + i] = h


func _obs_index(x: float, z: float) -> int:
	var half := SIZE * 0.5
	var i := int(floor((x + half) / OBS_STEP))
	var j := int(floor((z + half) / OBS_STEP))
	if i < 0 or j < 0 or i >= obs_n or j >= obs_n:
		return -1
	return j * obs_n + i


## Obstacle rectangulaire (immeuble, bâtiment) de sommet `top`.
func add_obstacle_box(center: Vector2, size: Vector2, top: float) -> void:
	var x := center.x - size.x * 0.5
	while x <= center.x + size.x * 0.5 + 0.01:
		var z := center.y - size.y * 0.5
		while z <= center.y + size.y * 0.5 + 0.01:
			var k := _obs_index(x, z)
			if k >= 0:
				obs_top[k] = maxf(obs_top[k], top)
			z += OBS_STEP * 0.5
		x += OBS_STEP * 0.5


## Obstacle circulaire (arbre) de sommet `top`.
func add_obstacle_disc(center: Vector2, radius: float, top: float) -> void:
	var x := center.x - radius
	while x <= center.x + radius + 0.01:
		var z := center.y - radius
		while z <= center.y + radius + 0.01:
			if Vector2(x, z).distance_to(center) <= radius + OBS_STEP * 0.5:
				var k := _obs_index(x, z)
				if k >= 0:
					obs_top[k] = maxf(obs_top[k], top)
			z += OBS_STEP * 0.5
		x += OBS_STEP * 0.5


## Hauteur du plus haut obstacle (sol compris) dans un disque de rayon r.
func obstacle_top(x: float, z: float, r: float) -> float:
	if obs_n == 0:
		return height_at(x, z)
	var half := SIZE * 0.5
	var i0 := clampi(int(floor((x - r + half) / OBS_STEP)), 0, obs_n - 1)
	var i1 := clampi(int(floor((x + r + half) / OBS_STEP)), 0, obs_n - 1)
	var j0 := clampi(int(floor((z - r + half) / OBS_STEP)), 0, obs_n - 1)
	var j1 := clampi(int(floor((z + r + half) / OBS_STEP)), 0, obs_n - 1)
	var r2 := (r + OBS_STEP) * (r + OBS_STEP)
	var top := -INF
	for j in range(j0, j1 + 1):
		var cz := -half + (j + 0.5) * OBS_STEP - z
		for i in range(i0, i1 + 1):
			var cx := -half + (i + 0.5) * OBS_STEP - x
			if cx * cx + cz * cz <= r2:
				top = maxf(top, obs_top[j * obs_n + i])
	return top if top > -INF else height_at(x, z)


func _smooth(t: float) -> float:
	return t * t * (3.0 - 2.0 * t)


## 1 dans la ville, 0 loin d'elle (transition douce sur 30 m).
func city_mask(x: float, z: float) -> float:
	var dx := maxf(maxf(city_rect.position.x - x, x - city_rect.end.x), 0.0)
	var dz := maxf(maxf(city_rect.position.y - z, z - city_rect.end.y), 0.0)
	return clampf(1.0 - sqrt(dx * dx + dz * dz) / 30.0, 0.0, 1.0)


func base_mask(x: float, z: float) -> float:
	var db := Vector2(x, z).distance_to(base_pos2)
	return _smooth(clampf((base_radius * 2.0 - db) / base_radius, 0.0, 1.0))


func height_at(x: float, z: float) -> float:
	var h := noise.get_noise_2d(x, z) * 16.0 + detail.get_noise_2d(x, z) * 1.2
	# relief plus marqué à l'est (collines de la forêt)
	h += clampf((x - 40.0) / 160.0, 0.0, 1.0) * 5.0
	h = lerpf(h, 0.0, _smooth(city_mask(x, z)))
	h = lerpf(h, 0.0, base_mask(x, z))
	var dl := Vector2(x, z).distance_to(lake_center2)
	var tl := _smooth(clampf((lake_radius * 1.7 - dl) / (lake_radius * 1.1), 0.0, 1.0))
	h = lerpf(h, water_level - 6.0, tl)
	if basin_ground < INF:   # plateforme aplanie autour du bassin
		var db := Vector2(x, z).distance_to(basin_center)
		h = lerpf(h, basin_ground, _smooth(clampf((basin_size * 1.6 - db) / (basin_size * 0.8), 0.0, 1.0)))
	if ranger_ground < INF:   # plateforme de la maison forestière
		var rdx := maxf(absf(x - ranger_center.x) - ranger_size.x * 0.5, 0.0)
		var rdz := maxf(absf(z - ranger_center.y) - ranger_size.y * 0.5, 0.0)
		h = lerpf(h, ranger_ground, _smooth(clampf(1.0 - sqrt(rdx * rdx + rdz * rdz) / 14.0, 0.0, 1.0)))
	for i in park_ground.size():   # clairières des parcs : plat, raccordé en douceur au relief
		for k in park_ground[i]:
			var zc: Vector2 = park_zones[i][k][0]
			var zr: float = park_zones[i][k][1]
			var dz := Vector2(x, z).distance_to(zc)
			if dz < zr * 1.35:
				h = lerpf(h, park_ground[i][k], _smooth(clampf((zr * 1.35 - dz) / (zr * 0.35), 0.0, 1.0)))
				if k == "pond" and i < pond_water.size():   # cuvette de l'étang : berges en pente douce
					h = lerpf(h, pond_water[i] - 1.8, _smooth(clampf((pond_radius + 2.0 - dz) / 6.0, 0.0, 1.0)))
	return h


func near_ranger(x: float, z: float, margin: float) -> bool:
	return absf(x - ranger_center.x) < ranger_size.x * 0.5 + margin and absf(z - ranger_center.y) < ranger_size.y * 0.5 + margin


func park_center(i: int, zone: String) -> Vector2:
	return park_zones[i][zone][0]


func pond_center(i: int) -> Vector2:
	return park_zones[i]["pond"][0]


## Vrai si (x, z) est dans une clairière d'un parc (agrandie de `margin`) : pas d'arbres.
func in_park(x: float, z: float, margin: float) -> bool:
	for zones in park_zones:
		for k in zones:
			if Vector2(x, z).distance_to(zones[k][0]) < zones[k][1] + margin:
				return true
	return false


func _terrain_material() -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = TERRAIN_SHADER
	for pair in [["meadow", "meadow"], ["forest", "forest_floor"], ["rock", "rock"], ["sand", "sand"],
			["burnt", "burnt"], ["conc", "concrete"]]:
		m.set_shader_parameter(pair[0] + "_d", Look.tex(pair[1], "diff"))
		m.set_shader_parameter(pair[0] + "_n", Look.tex(pair[1], "nor"))
		m.set_shader_parameter(pair[0] + "_a", Look.tex(pair[1], "arm"))
	m.set_shader_parameter("forest_rect", Vector4(forest_rect.position.x, forest_rect.position.y, forest_rect.size.x, forest_rect.size.y))
	m.set_shader_parameter("city_rect", Vector4(city_rect.position.x, city_rect.position.y, city_rect.size.x, city_rect.size.y))
	m.set_shader_parameter("base_rect", Vector4(base_pos2.x - 17.0, base_pos2.y - 37.0, 34.0, 74.0))
	m.set_shader_parameter("lake_center", lake_center2)
	m.set_shader_parameter("lake_radius", lake_radius)
	m.set_shader_parameter("water_level", water_level)
	m.set_shader_parameter("map_half", SIZE * 0.5)
	m.set_shader_parameter("basin_rect", Vector4(basin_center.x - basin_size, basin_center.y - basin_size, basin_size * 2.0, basin_size * 2.0))
	# parc : gazon tondu (pique-nique, détente), sable (aire de jeux), berges de l'étang
	m.set_shader_parameter("lawn_d", Look.tex("park_grass", "diff"))
	m.set_shader_parameter("lawn_n", Look.tex("park_grass", "nor"))
	m.set_shader_parameter("lawn_a", Look.tex("park_grass", "arm"))
	var rp := ranger_parking
	m.set_shader_parameter("ranger_rect", Vector4(rp.position.x, rp.position.y, rp.size.x, rp.size.y))
	var lawns := PackedVector4Array()
	var plays := PackedVector4Array()
	var ponds := PackedVector4Array()
	for o in park_origins:   # 2 parcs au maximum (taille des tableaux du shader)
		for k in ["picnic", "relax"]:
			var lc: Vector2 = o + PARK_LAYOUT[k][0]
			lawns.append(Vector4(lc.x, lc.y, PARK_LAYOUT[k][1], 0.0))
		var gc: Vector2 = o + PARK_LAYOUT["playground"][0]
		plays.append(Vector4(gc.x, gc.y, PARK_LAYOUT["playground"][1] * 0.72, 0.0))
		var wc: Vector2 = o + PARK_LAYOUT["pond"][0]
		ponds.append(Vector4(wc.x, wc.y, pond_radius, 0.0))
	m.set_shader_parameter("lawn_circles", lawns)
	m.set_shader_parameter("play_circles", plays)
	m.set_shader_parameter("pond_circles", ponds)
	var nt := NoiseTexture2D.new()   # variations à grande échelle (zones sèches, massifs lointains)
	nt.width = 512
	nt.height = 512
	nt.seamless = true
	var fn := FastNoiseLite.new()
	fn.frequency = 0.008
	fn.fractal_octaves = 5
	fn.seed = 1234
	nt.noise = fn
	m.set_shader_parameter("macro_noise", nt)
	return m


## Relief au-delà de la carte : le même relief, puis des collines et des montagnes
## qui montent progressivement vers l'horizon.
func far_height(x: float, z: float) -> float:
	var h := height_at(x, z)
	var d := maxf(absf(x), absf(z))
	var t := clampf((d - SIZE * 0.5) / 900.0, 0.0, 1.0)
	var m := (noise.get_noise_2d(x * 0.18, z * 0.18) * 0.5 + 0.5)
	return h + t * t * (40.0 + m * 230.0) - t * 6.0


func _build_mesh() -> void:
	var n := int(SIZE / STEP)
	var half := SIZE * 0.5
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for iz in range(n + 1):
		for ix in range(n + 1):
			var x := -half + ix * STEP
			var z := -half + iz * STEP
			var h := height_at(x, z)
			var nrm := Vector3(height_at(x - 1.0, z) - height_at(x + 1.0, z), 2.0,
				height_at(x, z - 1.0) - height_at(x, z + 1.0)).normalized()
			st.set_normal(nrm)
			st.add_vertex(Vector3(x, h, z))
	for iz in range(n):
		for ix in range(n):
			var i := iz * (n + 1) + ix
			st.add_index(i)
			st.add_index(i + 1)
			st.add_index(i + n + 1)
			st.add_index(i + 1)
			st.add_index(i + n + 2)
			st.add_index(i + n + 1)
	var mesh := st.commit()
	var mi := MeshInstance3D.new()
	mi.name = "TerrainMesh"
	mi.mesh = mesh
	material = _terrain_material()
	mi.material_override = material
	add_child(mi)
	# collision pour les clics (allumer un feu à la souris)
	var body := StaticBody3D.new()
	var cs := CollisionShape3D.new()
	var shape: ConcavePolygonShape3D = mesh.create_trimesh_shape()
	shape.backface_collision = true
	cs.shape = shape
	body.add_child(cs)
	add_child(body)


func _build_water() -> void:
	var mi := MeshInstance3D.new()
	mi.name = "Lake"
	var m := PlaneMesh.new()
	var r := lake_radius * 1.6
	m.size = Vector2(r * 2.0, r * 2.0)
	m.subdivide_width = 24
	m.subdivide_depth = 24
	var mat := ShaderMaterial.new()
	mat.shader = WATER_SHADER
	for k in 2:
		var nt := NoiseTexture2D.new()
		nt.width = 512
		nt.height = 512
		nt.seamless = true
		nt.as_normal_map = true
		nt.bump_strength = 6.0 if k == 0 else 3.0
		var fn := FastNoiseLite.new()
		fn.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
		fn.frequency = 0.012 if k == 0 else 0.03
		fn.fractal_octaves = 4
		fn.seed = 91 + k
		nt.noise = fn
		mat.set_shader_parameter("wave_a" if k == 0 else "wave_b", nt)
	m.material = mat
	lake_material = mat
	mi.mesh = m
	mi.position = Vector3(lake_center2.x, water_level, lake_center2.y)
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)


## Points d'eau où les drones d'action se remplissent : [centre (y = surface), rayon de manœuvre].
func water_points() -> Array:
	return [[Vector3(lake_center2.x, water_level, lake_center2.y), 14.0],
		[Vector3(basin_center.x, basin_water, basin_center.y), 9.0],
		[Vector3(pond_center(0).x, pond_water[0], pond_center(0).y), pond_radius * 0.55],
		[Vector3(pond_center(1).x, pond_water[1], pond_center(1).y), pond_radius * 0.55]]


func near_basin(x: float, z: float, margin: float) -> bool:
	return absf(x - basin_center.x) < basin_size * 0.5 + margin and absf(z - basin_center.y) < basin_size * 0.5 + margin


## Bassin DFCI : murs en béton, eau, plateforme ; déclaré comme obstacle pour les drones.
func _build_basin() -> void:
	var c := Vector3(basin_center.x, basin_ground, basin_center.y)
	var half := basin_size * 0.5
	var wall_mat := Look.pbr("concrete", 3.0, Color(0.82, 0.84, 0.86))
	for w in [[Vector3(0, 0, -half), Vector3(basin_size + 1.0, 2.6, 0.5)], [Vector3(0, 0, half), Vector3(basin_size + 1.0, 2.6, 0.5)],
			[Vector3(-half, 0, 0), Vector3(0.5, 2.6, basin_size)], [Vector3(half, 0, 0), Vector3(0.5, 2.6, basin_size)]]:
		var mi := MeshInstance3D.new()
		var bm := BoxMesh.new()
		bm.size = w[1]
		mi.mesh = bm
		mi.material_override = wall_mat
		mi.position = c + w[0] + Vector3(0, 0.3, 0)
		add_child(mi)
	# fond du bassin
	var floor_mi := MeshInstance3D.new()
	var fm := BoxMesh.new()
	fm.size = Vector3(basin_size, 0.3, basin_size)
	floor_mi.mesh = fm
	floor_mi.material_override = wall_mat
	floor_mi.position = c + Vector3(0, -0.9, 0)
	add_child(floor_mi)
	# eau (même rendu que le lac)
	var water := MeshInstance3D.new()
	water.name = "Basin"
	var pm := PlaneMesh.new()
	pm.size = Vector2(basin_size - 0.2, basin_size - 0.2)
	pm.subdivide_width = 8
	pm.subdivide_depth = 8
	pm.material = lake_material
	water.mesh = pm
	water.position = Vector3(c.x, basin_water, c.z)
	water.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(water)
	var tag := Label3D.new()
	tag.text = "BASSIN DFCI"
	tag.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	tag.font_size = 56
	tag.outline_size = 10
	tag.pixel_size = 0.03
	tag.modulate = Color(0.7, 0.85, 1.0)
	tag.position = c + Vector3(0, 9.0, 0)
	add_child(tag)


## Étangs des parcs : plans d'eau ronds (même rendu que le lac) dans les cuvettes.
func _build_pond() -> void:
	var cm := CylinderMesh.new()
	cm.top_radius = pond_radius + 1.5
	cm.bottom_radius = pond_radius + 1.5
	cm.height = 0.02
	cm.radial_segments = 48
	cm.rings = 1
	cm.material = lake_material
	for i in pond_water.size():
		var water := MeshInstance3D.new()
		water.name = "Pond%d" % i
		water.mesh = cm
		var c := pond_center(i)
		water.position = Vector3(c.x, pond_water[i], c.y)
		water.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(water)


func _register_basin_obstacle() -> void:
	add_obstacle_box(basin_center, Vector2(basin_size + 1.0, basin_size + 1.0), basin_water)
	var half := basin_size * 0.5
	for w in [[Vector2(0, -half), Vector2(basin_size + 1.0, 0.6)], [Vector2(0, half), Vector2(basin_size + 1.0, 0.6)],
			[Vector2(-half, 0), Vector2(0.6, basin_size)], [Vector2(half, 0), Vector2(0.6, basin_size)]]:
		add_obstacle_box(basin_center + w[0], w[1], basin_ground + 1.6)


## Paysage lointain : anneau de relief à résolution décroissante autour de la carte.
func _build_outer_ground() -> void:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	# coordonnées de grille : fines près de la carte, grossières à l'horizon
	var coords: Array = []
	var x := -FAR_SIZE * 0.5
	while x < FAR_SIZE * 0.5:
		coords.append(x)
		var d := absf(x)
		x += 10.0 if d < 600.0 else (30.0 if d < 1400.0 else 80.0)
	coords.append(FAR_SIZE * 0.5)
	var n := coords.size()
	var half := SIZE * 0.5 - 1.0
	for iz in n:
		for ix in n:
			var px: float = coords[ix]
			var pz: float = coords[iz]
			var h := far_height(px, pz)
			if absf(px) < half and absf(pz) < half:
				h -= 3.0   # sous la carte : masqué par le terrain détaillé
			var nrm := Vector3(far_height(px - 4.0, pz) - far_height(px + 4.0, pz), 8.0,
				far_height(px, pz - 4.0) - far_height(px, pz + 4.0)).normalized()
			st.set_normal(nrm)
			st.add_vertex(Vector3(px, h, pz))
	for iz in n - 1:
		for ix in n - 1:
			var i := iz * n + ix
			st.add_index(i)
			st.add_index(i + 1)
			st.add_index(i + n)
			st.add_index(i + 1)
			st.add_index(i + n + 1)
			st.add_index(i + n)
	var mi := MeshInstance3D.new()
	mi.name = "FarLand"
	mi.mesh = st.commit()
	mi.material_override = material
	add_child(mi)
