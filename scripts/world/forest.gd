extends Node3D
## Forêt procédurale + simulation d'incendie par automate cellulaire.
##
## La forêt est une grille de cellules de 5 m. Chaque cellule a une densité de
## végétation (combustible) et un état : VIDE, COMBUSTIBLE, EN_FEU, BRÛLÉE.
## À chaque tick, une cellule en feu peut enflammer ses 8 voisines avec une
## probabilité qui dépend de la densité, du vent, de la pente et de la pluie.
## Les drones d'action « mouillent » les cellules, ce qui éteint le feu et
## empêche temporairement la ré-inflammation.

enum { EMPTY, FUEL, BURNING, BURNT }
const CELL := 5.0

const COL_BURNING := Color(1.0, 0.36, 0.05)
const COL_BURNT := Color(0.025, 0.022, 0.02)
const COL_WET_TINT := Color(0.04, 0.07, 0.07)
const Vegetation := preload("res://scripts/render/vegetation.gd")

var terrain: Node3D
var network: Node3D = null   # réseau routier : pistes forestières (pas d'arbres dessus)
var origin := Vector2.ZERO
var gw := 0
var gh := 0
var state := PackedInt32Array()
var density := PackedFloat32Array()
var burn_t := PackedFloat32Array()
var wet_t := PackedFloat32Array()
var cell_pos := PackedVector3Array()
var tree_first := PackedInt32Array()
var tree_count := PackedInt32Array()
var tree_colors := PackedColorArray()

var burning := {}   # idx -> true
var wet := {}       # idx -> true
var total_burnt := 0
var total_extinguished := 0
var was_burning := false
var tick_acc := 0.0
var rng := RandomNumberGenerator.new()
var centroid := Vector3.ZERO

var foliage_xforms: Array = []   # transformations d'origine (un arbre calciné perd son feuillage)
# la forêt est découpée en secteurs de CHUNK m : chaque secteur est un MultiMesh,
# que le moteur n'affiche que s'il est dans le champ de la caméra
const CHUNK := 96.0
var tree_mm: Array = []          # arbre -> MultiMesh de feuillage de son secteur
var tree_local: PackedInt32Array = PackedInt32Array()   # arbre -> indice dans ce MultiMesh
var flames_mm: MultiMesh
var smoke: CPUParticles3D
var embers: CPUParticles3D
var smoke_column: FogVolume
var fire_light: OmniLight3D
const FLAME_SHADER := preload("res://scripts/render/shaders/flame.gdshader")
const SMOKE_SHADER := preload("res://scripts/render/shaders/smoke.gdshader")
var burn_img: Image          # carte de brûlure lue par le shader du sol (R = brûlé, G = en feu)
var burn_tex: ImageTexture
var burn_dirty := false


func generate(t: Node3D, seed_val: int) -> void:
	terrain = t
	rng.seed = seed_val + 202
	var fr: Rect2 = terrain.forest_rect
	origin = fr.position
	gw = int(fr.size.x / CELL)
	gh = int(fr.size.y / CELL)
	var n := gw * gh
	state.resize(n)
	density.resize(n)
	burn_t.resize(n)
	wet_t.resize(n)
	cell_pos.resize(n)
	tree_first.resize(n)
	tree_count.resize(n)

	var dn := FastNoiseLite.new()
	dn.seed = seed_val + 303
	dn.frequency = 0.018
	dn.fractal_octaves = 3
	var lake: Vector2 = terrain.lake_center2
	var lake_r: float = terrain.lake_radius
	var trunk_xf: Array = []
	var foliage_xf: Array = []

	for j in gh:
		for i in gw:
			var idx := j * gw + i
			var cx := origin.x + (i + 0.5) * CELL
			var cz := origin.y + (j + 0.5) * CELL
			var edge := minf(minf(cx - fr.position.x, fr.end.x - cx), minf(cz - fr.position.y, fr.end.y - cz))
			# lisière irrégulière : la distance au bord est perturbée par un bruit lent
			var edge_n := edge + dn.get_noise_2d(cx * 0.35 + 500.0, cz * 0.35) * 12.0
			# forêt dense jusqu'aux limites (lisière courte et irrégulière)
			var d := (dn.get_noise_2d(cx, cz) * 0.5 + 0.5) * 0.7 + clampf(edge_n / 12.0, -1.0, 1.0) * 0.45 + 0.02
			if Vector2(cx, cz).distance_to(lake) < lake_r * 1.7:
				d = 0.0
			elif terrain.near_basin(cx, cz, 14.0):
				d = 0.0   # clairière du bassin DFCI
			elif terrain.near_ranger(cx, cz, 3.0):
				d = 0.0   # clairière de la maison forestière
			elif terrain.in_park(cx, cz, 4.0):
				d = 0.0   # clairières du parc de loisirs
			elif network and network.distance_to_tracks(Vector2(cx, cz)) < 2.6:
				d = 0.2   # piste : herbe rase, brûle mal, aucun arbre
			d = clampf(d, 0.0, 1.0)
			var gy: float = terrain.height_at(cx, cz)
			cell_pos[idx] = Vector3(cx, gy, cz)
			density[idx] = d
			state[idx] = FUEL if d >= 0.18 else EMPTY
			tree_first[idx] = tree_colors.size()
			var count := 0
			if d > 0.4:
				count = 1
			if d > 0.65:
				count = 2
			for k in count:
				var px := cx + rng.randf_range(-2.0, 2.0)
				var pz := cz + rng.randf_range(-2.0, 2.0)
				var py: float = terrain.height_at(px, pz)
				_add_tree(trunk_xf, foliage_xf, Vector3(px, py, pz), rng.randf_range(0.75, 1.35))
			tree_count[idx] = count

	_scatter_meadow_trees(trunk_xf, foliage_xf)
	_build_visuals(trunk_xf, foliage_xf)
	_init_burn_map()
	_build_far_forests()


func _green() -> Color:
	return Vegetation.needle_color(rng)


## Pin : fût jusque dans la couronne, couronne de 1,6 s à 11,5 s (9 à 16 m de haut).
func _add_tree(trunks: Array, foliages: Array, p: Vector3, s: float) -> void:
	var yaw := Basis(Vector3.UP, rng.randf() * TAU)
	trunks.append(Transform3D(yaw * Basis.from_scale(Vector3(s, s * 9.0, s)), p + Vector3(0, 4.4 * s, 0)))
	var w := 2.2 * s * rng.randf_range(0.85, 1.12)
	foliages.append(Transform3D(yaw * Basis.from_scale(Vector3(w, 9.9 * s, w)), p + Vector3(0, 1.6 * s + 4.95 * s, 0)))
	tree_colors.append(_green())
	terrain.add_obstacle_disc(Vector2(p.x, p.z), w, p.y + 11.5 * s)   # cime de la couronne


## Arbres décoratifs (non inflammables) dans les prairies autour de la ville.
func _scatter_meadow_trees(trunks: Array, foliages: Array) -> void:
	var half: float = terrain.SIZE * 0.5 - 5.0
	var fr: Rect2 = terrain.forest_rect.grow(6.0)
	var lake: Vector2 = terrain.lake_center2
	var lake_r: float = terrain.lake_radius
	var base: Vector2 = terrain.base_pos2
	for k in int(260.0 * pow(terrain.SIZE / 440.0, 2.0) * 0.4):
		var x := rng.randf_range(-half, half)
		var z := rng.randf_range(-half, half)
		var p2 := Vector2(x, z)
		var cm: float = terrain.city_mask(x, z)
		if cm > 0.0 or fr.has_point(p2) or p2.distance_to(lake) < lake_r * 1.8 or p2.distance_to(base) < 60.0:
			continue
		if network and network.distance_to_tracks(p2) < 9.0:
			continue
		var y: float = terrain.height_at(x, z)
		_add_tree(trunks, foliages, Vector3(x, y, z), rng.randf_range(0.7, 1.2))


## Forêts du paysage environnant (décor, non inflammables) : vrais arbres en 3D
## sur une ceinture de ~500 m autour de la carte, en massifs irréguliers.
func _build_far_forests() -> void:
	var fn := FastNoiseLite.new()
	fn.seed = rng.seed + 9
	fn.frequency = 0.0045
	fn.fractal_octaves = 3
	var inner: float = terrain.SIZE * 0.5 + 8.0
	var outer: float = inner + 340.0
	var step := 9.5
	var xfs: Array = []
	var cols: Array = []
	var x := -outer
	while x <= outer:
		var z := -outer
		while z <= outer:
			var px := x + rng.randf_range(-3.5, 3.5)
			var pz := z + rng.randf_range(-3.5, 3.5)
			if maxf(absf(px), absf(pz)) > inner:
				var dens := fn.get_noise_2d(px, pz)
				if dens > -0.02 and rng.randf() < clampf((dens + 0.02) * 7.0, 0.0, 0.95):
					var s := rng.randf_range(0.8, 1.4)
					var y: float = terrain.far_height(px, pz)
					var w := 2.2 * s * rng.randf_range(0.85, 1.12)
					xfs.append(Transform3D(Basis(Vector3.UP, rng.randf() * TAU) * Basis.from_scale(Vector3(w, 9.9 * s, w)),
						Vector3(px, y + 1.6 * s + 4.95 * s, pz)))
					cols.append(_green())
			z += step
		x += step
	_chunked(xfs, cols, Vegetation.conifer_mesh(), Vegetation.foliage_material(), "FarForests", 200.0, true)


## Répartit des instances en MultiMesh par secteur (culling par secteur).
## Renvoie, pour chaque instance, [MultiMesh, indice local].
func _chunked(xfs: Array, cols: Array, mesh: Mesh, mat: Material, prefix: String, size: float, no_shadow := false) -> Array:
	var groups := {}
	for k in xfs.size():
		var o: Vector3 = (xfs[k] as Transform3D).origin
		var key := Vector2i(floori(o.x / size), floori(o.z / size))
		if not groups.has(key):
			groups[key] = []
		groups[key].append(k)
	var where: Array = []
	where.resize(xfs.size())
	for key in groups:
		var ids: Array = groups[key]
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.use_colors = true
		mm.mesh = mesh
		mm.instance_count = ids.size()
		for i in ids.size():
			mm.set_instance_transform(i, xfs[ids[i]])
			mm.set_instance_color(i, cols[ids[i]] if not cols.is_empty() else Color(0.8, 0.72, 0.62))
			where[ids[i]] = [mm, i]
		var mi := MultiMeshInstance3D.new()
		mi.name = "%s_%d_%d" % [prefix, key.x, key.y]
		mi.multimesh = mm
		mi.material_override = mat
		if no_shadow:   # décor lointain : pas d'ombre projetée (gain de performance)
			mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(mi)
	return where


func _vc_material() -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.vertex_color_use_as_albedo = true
	m.roughness = 0.9
	return m


func _build_visuals(trunk_xf: Array, foliage_xf: Array) -> void:
	_chunked(trunk_xf, [], Vegetation.trunk_mesh(), Vegetation.trunk_material(), "Trunks", CHUNK)
	foliage_xforms = foliage_xf
	var cols: Array = []
	for c in tree_colors:
		cols.append(c)
	var where := _chunked(foliage_xf, cols, Vegetation.conifer_mesh(), Vegetation.foliage_material(), "Foliage", CHUNK)
	tree_mm.resize(where.size())
	tree_local.resize(where.size())
	for t in where.size():
		tree_mm[t] = where[t][0]
		tree_local[t] = where[t][1]

	# Flammes : flamme au sol par cellule en feu + grande flamme de couronne si arbres
	var noise_tex := NoiseTexture2D.new()
	noise_tex.width = 256
	noise_tex.height = 256
	noise_tex.seamless = true
	var fn := FastNoiseLite.new()
	fn.frequency = 0.02
	fn.fractal_octaves = 4
	noise_tex.noise = fn
	var quad_f := QuadMesh.new()
	quad_f.size = Vector2(1, 1)
	quad_f.center_offset = Vector3(0, 0.5, 0)   # bas de la flamme à l'origine
	var fmat := ShaderMaterial.new()
	fmat.shader = FLAME_SHADER
	fmat.set_shader_parameter("noise_tex", noise_tex)
	quad_f.material = fmat
	flames_mm = MultiMesh.new()
	flames_mm.transform_format = MultiMesh.TRANSFORM_3D
	flames_mm.mesh = quad_f
	flames_mm.instance_count = maxi(1, gw * gh * 2)
	flames_mm.visible_instance_count = 0
	var flmi := MultiMeshInstance3D.new()
	flmi.name = "Flames"
	flmi.multimesh = flames_mm
	flmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	flmi.custom_aabb = AABB(Vector3(origin.x, -50, origin.y), Vector3(gw * CELL, 150, gh * CELL))
	add_child(flmi)

	# Fumée : volutes éclairées par le soleil, qui grossissent et dérivent avec le vent
	smoke = CPUParticles3D.new()
	smoke.name = "Smoke"
	smoke.amount = 420
	smoke.lifetime = 16.0
	smoke.emitting = false
	smoke.local_coords = false
	smoke.emission_shape = CPUParticles3D.EMISSION_SHAPE_BOX
	smoke.emission_box_extents = Vector3(5, 2, 5)
	smoke.direction = Vector3(0, 1, 0)
	smoke.spread = 15.0
	smoke.initial_velocity_min = 3.0
	smoke.initial_velocity_max = 6.0
	smoke.gravity = Vector3(0, 0.6, 0)
	smoke.damping_min = 0.2
	smoke.damping_max = 0.4
	smoke.angle_min = -180.0
	smoke.angle_max = 180.0
	smoke.scale_amount_min = 6.0
	smoke.scale_amount_max = 11.0
	var sc := Curve.new()
	sc.add_point(Vector2(0, 0.35))
	sc.add_point(Vector2(1, 2.6))
	smoke.scale_amount_curve = sc
	var grad := Gradient.new()
	grad.set_color(0, Color(0.08, 0.07, 0.06, 0.0))
	grad.set_color(1, Color(0.62, 0.62, 0.64, 0.0))
	grad.add_point(0.06, Color(0.12, 0.11, 0.1, 0.85))
	grad.add_point(0.45, Color(0.34, 0.33, 0.32, 0.6))
	smoke.color_ramp = grad
	var quad := QuadMesh.new()
	quad.size = Vector2(1, 1)
	var smat := ShaderMaterial.new()
	smat.shader = SMOKE_SHADER
	smat.set_shader_parameter("noise_tex", noise_tex)
	quad.material = smat
	smoke.mesh = quad
	add_child(smoke)

	# braises qui s'envolent
	embers = CPUParticles3D.new()
	embers.name = "Embers"
	embers.amount = 160
	embers.lifetime = 3.5
	embers.emitting = false
	embers.local_coords = false
	embers.emission_shape = CPUParticles3D.EMISSION_SHAPE_BOX
	embers.direction = Vector3(0, 1, 0)
	embers.spread = 35.0
	embers.initial_velocity_min = 4.0
	embers.initial_velocity_max = 10.0
	embers.gravity = Vector3(0, 1.5, 0)
	embers.scale_amount_min = 0.06
	embers.scale_amount_max = 0.16
	var eg := Gradient.new()
	eg.set_color(0, Color(1.0, 0.7, 0.3, 1.0))
	eg.set_color(1, Color(0.6, 0.1, 0.0, 0.0))
	embers.color_ramp = eg
	var ebox := BoxMesh.new()
	ebox.size = Vector3.ONE
	var emat := StandardMaterial3D.new()
	emat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	emat.vertex_color_use_as_albedo = true
	emat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	emat.albedo_color = Color(4.0, 1.6, 0.4)
	ebox.material = emat
	embers.mesh = ebox
	add_child(embers)

	# colonne de fumée volumétrique (brouillard localisé : ombre portée, rayons de soleil)
	smoke_column = FogVolume.new()
	smoke_column.name = "SmokeColumn"
	smoke_column.shape = RenderingServer.FOG_VOLUME_SHAPE_ELLIPSOID
	var fog := FogMaterial.new()
	fog.density = 0.08
	fog.albedo = Color(0.58, 0.57, 0.56)
	fog.height_falloff = 0.0
	fog.edge_fade = 1.2
	var n3 := NoiseTexture3D.new()
	n3.width = 64
	n3.height = 64
	n3.depth = 64
	n3.seamless = true
	var fn3 := FastNoiseLite.new()
	fn3.frequency = 0.06
	fn3.fractal_octaves = 3
	n3.noise = fn3
	fog.density_texture = n3
	smoke_column.material = fog
	smoke_column.visible = false
	add_child(smoke_column)

	fire_light = OmniLight3D.new()
	fire_light.light_color = Color(1.0, 0.5, 0.15)
	fire_light.omni_range = 45.0
	fire_light.visible = false
	add_child(fire_light)


# ---------------------------------------------------------------- simulation

func _process(delta: float) -> void:
	if gw == 0:
		return
	if burn_dirty:
		burn_dirty = false
		burn_tex.update(burn_img)
	var tick := float(GameState.cfgv("fire", "tick", 0.5))
	tick_acc += delta
	var guard := 0
	while tick_acc >= tick and guard < 8:
		tick_acc -= tick
		guard += 1
		_tick(tick)
	if fire_light.visible and delta > 0.0:
		fire_light.light_energy = clampf(1.0 + burning.size() * 0.08, 1.0, 10.0) * rng.randf_range(0.8, 1.15)


@warning_ignore("integer_division")
func _tick(dt: float) -> void:
	var spread := float(GameState.cfgv("fire", "spread", 0.07))
	var wind := GameState.wind_vector()
	var ws := GameState.wind_speed
	var rain_f := 0.25 if GameState.raining else 1.0
	if GameState.snowing:
		rain_f = 0.12   # la neige freine davantage la propagation que la pluie
	var damp := 2.0 if GameState.snowing else (1.5 if GameState.raining else 1.0)
	var to_ignite: Array = []
	var to_burnout: Array = []
	for idx in burning.keys():
		burn_t[idx] -= dt * damp
		if burn_t[idx] <= 0.0:
			to_burnout.append(idx)
			continue
		var i: int = idx % gw
		var j: int = idx / gw
		for dj in [-1, 0, 1]:
			for di in [-1, 0, 1]:
				if di == 0 and dj == 0:
					continue
				var ni: int = i + di
				var nj: int = j + dj
				if ni < 0 or nj < 0 or ni >= gw or nj >= gh:
					continue
				var nidx := nj * gw + ni
				if state[nidx] != FUEL or wet_t[nidx] > 0.0:
					continue
				var dir := Vector2(di, dj).normalized()
				var wf := clampf(1.0 + dir.dot(wind) * ws * 0.15, 0.15, 3.5)
				var dh := cell_pos[nidx].y - cell_pos[idx].y
				var sf := clampf(1.0 + dh * 0.08, 0.5, 1.8)
				var diag := 0.7 if (di != 0 and dj != 0) else 1.0
				var p := spread * density[nidx] * wf * sf * rain_f * diag
				if rng.randf() < p:
					to_ignite.append(nidx)
	for idx in to_burnout:
		burning.erase(idx)
		state[idx] = BURNT
		total_burnt += 1
		_paint(idx)
	for idx in to_ignite:
		if state[idx] == FUEL:
			_ignite_cell(idx)
	for idx in wet.keys():
		wet_t[idx] -= dt
		if wet_t[idx] <= 0.0:
			wet_t[idx] = 0.0
			wet.erase(idx)
			_paint(idx)
	_update_fire_visuals()
	var count := burning.size()
	if was_burning and count == 0:
		EventBus.emit_event("fire_extinguished", {"burnt_cells": total_burnt, "extinguished_cells": total_extinguished})
	was_burning = count > 0


func _ignite_cell(idx: int) -> void:
	state[idx] = BURNING
	var bt := float(GameState.cfgv("fire", "burn_time", 16.0))
	burn_t[idx] = bt * (0.6 + density[idx] * 0.8)
	burning[idx] = true
	_paint(idx)


@warning_ignore("integer_division")
func _init_burn_map() -> void:
	# R = brûlé, G = en feu, B = densité de végétation (le sol forestier suit les arbres)
	burn_img = Image.create(gw, gh, false, Image.FORMAT_RGB8)
	for idx in gw * gh:
		burn_img.set_pixel(idx % gw, idx / gw, Color(0, 0, density[idx] if state[idx] == FUEL else 0.0))
	burn_tex = ImageTexture.create_from_image(burn_img)
	var m: ShaderMaterial = terrain.get("material")
	if m:
		m.set_shader_parameter("burn_map", burn_tex)
		m.set_shader_parameter("burn_rect", Vector4(origin.x, origin.y, gw * CELL, gh * CELL))


@warning_ignore("integer_division")
func _paint(idx: int) -> void:
	if burn_img:
		var c := Color(0, 0, density[idx] if state[idx] != EMPTY else 0.0)
		if state[idx] == BURNING:
			c.r = 0.55
			c.g = 1.0
		elif state[idx] == BURNT:
			c.r = 1.0
		burn_img.set_pixel(idx % gw, idx / gw, c)
		burn_dirty = true
	var first := tree_first[idx]
	for t in range(first, first + tree_count[idx]):
		var c: Color = tree_colors[t]
		match state[idx]:
			BURNING:
				c = COL_BURNING
			BURNT:
				c = COL_BURNT
			_:
				if wet_t[idx] > 0.0:
					c = c.lerp(COL_WET_TINT, 0.4)
		var mm: MultiMesh = tree_mm[t]
		mm.set_instance_color(tree_local[t], c)
		# arbre calciné : il ne reste que des branches noircies, plus maigres
		var xf: Transform3D = foliage_xforms[t]
		if state[idx] == BURNT:
			xf.basis = xf.basis * Basis.from_scale(Vector3(0.42, 0.88, 0.42))
		mm.set_instance_transform(tree_local[t], xf)


func _update_fire_visuals() -> void:
	var keys := burning.keys()
	var n := 0
	var mn := Vector3(INF, 0, INF)
	var mx := Vector3(-INF, 0, -INF)
	var sum := Vector3.ZERO
	for idx in keys:
		if n + 2 > flames_mm.instance_count:
			break
		var p: Vector3 = cell_pos[idx]
		sum += p
		mn.x = minf(mn.x, p.x)
		mn.z = minf(mn.z, p.z)
		mx.x = maxf(mx.x, p.x)
		mx.z = maxf(mx.z, p.z)
		var j := Vector3(rng.randf_range(-1.5, 1.5), 0, rng.randf_range(-1.5, 1.5))
		# flamme au sol (herbes, broussailles)
		var s := rng.randf_range(0.8, 1.3)
		flames_mm.set_instance_transform(n, Transform3D(Basis.from_scale(Vector3(4.5 * s, 3.2 * s, 1)), p + j))
		n += 1
		# feu de couronne : grandes flammes dans les arbres
		if tree_count[idx] > 0:
			var h := rng.randf_range(9.0, 16.0)
			flames_mm.set_instance_transform(n, Transform3D(Basis.from_scale(Vector3(h * 0.5, h, 1)), p + j * 0.5 + Vector3(0, 2.0, 0)))
			n += 1
	flames_mm.visible_instance_count = n
	var count := keys.size()
	if count > 0:
		centroid = sum / count
		var ext := Vector3(maxf(4.0, (mx.x - mn.x) * 0.5), 2.0, maxf(4.0, (mx.z - mn.z) * 0.5))
		var w := GameState.wind_vector() * GameState.wind_speed
		smoke.global_position = centroid + Vector3(0, 8, 0)
		smoke.emission_box_extents = ext
		smoke.gravity = Vector3(w.x * 0.45, 0.6, w.y * 0.45)
		embers.global_position = centroid + Vector3(0, 6, 0)
		embers.emission_box_extents = ext
		embers.gravity = Vector3(w.x * 0.6, 1.5, w.y * 0.6)
		# colonne : grandit avec le feu et s'incline sous le vent
		var hgt := clampf(50.0 + count * 0.6, 50.0, 160.0)
		smoke_column.size = Vector3(ext.x * 2.0 + 20.0, hgt, ext.z * 2.0 + 20.0)
		var lean := Vector3(w.x, 0, w.y) * 0.08
		var up := (Vector3.UP + lean).normalized()
		var right := up.cross(Vector3.FORWARD).normalized()
		smoke_column.global_transform = Transform3D(Basis(right, up, right.cross(up)), centroid + up * hgt * 0.5 + Vector3(0, 4, 0))
		fire_light.global_position = centroid + Vector3(0, 10, 0)
		fire_light.omni_range = clampf(40.0 + count * 0.5, 40.0, 120.0)
	smoke.emitting = count > 0
	embers.emitting = count > 0
	smoke_column.visible = count > 0
	fire_light.visible = count > 0


# ------------------------------------------------------------------- API

func burning_count() -> int:
	return burning.size()


func burning_near(pos: Vector3, radius: float) -> Array:
	var out: Array = []
	for idx in burning.keys():
		var p: Vector3 = cell_pos[idx]
		if Vector2(p.x - pos.x, p.z - pos.z).length() <= radius:
			out.append(p)
	return out


func centroid_of(list: Array) -> Vector3:
	if list.is_empty():
		return Vector3.ZERO
	var s := Vector3.ZERO
	for p in list:
		s += p
	return s / list.size()


## Cellule en feu la plus proche, en évitant celles déjà ciblées par d'autres drones.
func find_target(from: Vector3, avoid: Array, avoid_radius: float = 22.0):
	var best := -1
	var best_score := INF
	for idx in burning.keys():
		var p: Vector3 = cell_pos[idx]
		var score := Vector2(p.x - from.x, p.z - from.z).length()
		for a in avoid:
			var av: Vector3 = a
			if Vector2(p.x - av.x, p.z - av.z).length() < avoid_radius:
				score += 80.0
		if score < best_score:
			best_score = score
			best = idx
	if best < 0:
		return null
	return cell_pos[best]


## Mouille une zone : éteint les cellules en feu et protège les autres. Retourne le nb de cellules éteintes.
func apply_water(pos: Vector3, radius: float) -> int:
	var wet_duration := float(GameState.cfgv("fire", "wet_duration", 45.0))
	var put_out := 0
	var i0 := clampi(int(floor((pos.x - radius - origin.x) / CELL)), 0, gw - 1)
	var i1 := clampi(int(floor((pos.x + radius - origin.x) / CELL)), 0, gw - 1)
	var j0 := clampi(int(floor((pos.z - radius - origin.y) / CELL)), 0, gh - 1)
	var j1 := clampi(int(floor((pos.z + radius - origin.y) / CELL)), 0, gh - 1)
	for j in range(j0, j1 + 1):
		for i in range(i0, i1 + 1):
			var idx := j * gw + i
			if state[idx] == EMPTY or state[idx] == BURNT:
				continue
			var p := cell_pos[idx]
			if Vector2(p.x - pos.x, p.z - pos.z).length() > radius:
				continue
			if state[idx] == BURNING:
				burning.erase(idx)
				state[idx] = FUEL
				put_out += 1
				total_extinguished += 1
			wet_t[idx] = wet_duration
			wet[idx] = true
			_paint(idx)
	_update_fire_visuals()
	return put_out


## Allume la cellule combustible la plus proche de pos (rayon 30 m).
func ignite_at(pos: Vector3) -> bool:
	var best := -1
	var bd := 30.0
	for idx in state.size():
		if state[idx] != FUEL or wet_t[idx] > 0.0:
			continue
		var p := cell_pos[idx]
		var d := Vector2(p.x - pos.x, p.z - pos.z).length()
		if d < bd:
			bd = d
			best = idx
	if best < 0:
		EventBus.log_msg("Aucune végétation combustible à cet endroit", "warn")
		return false
	_ignite_cell(best)
	_update_fire_visuals()
	var c := cell_pos[best]
	EventBus.log_msg("Départ de feu en (%d, %d)" % [int(c.x), int(c.z)], "warn")
	EventBus.emit_event("fire_ignited", {"position": [snappedf(c.x, 0.1), snappedf(c.y, 0.1), snappedf(c.z, 0.1)]})
	return true


func ignite_random() -> bool:
	var candidates: Array = []
	for idx in state.size():
		if state[idx] == FUEL and density[idx] > 0.5 and tree_count[idx] > 0 and wet_t[idx] <= 0.0:
			candidates.append(idx)
	if candidates.is_empty():
		EventBus.log_msg("Plus de végétation à enflammer", "warn")
		return false
	var idx: int = candidates[rng.randi() % candidates.size()]
	return ignite_at(cell_pos[idx])
