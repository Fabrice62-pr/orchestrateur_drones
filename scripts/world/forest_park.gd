extends Node3D
## Parc de loisirs aménagé dans la forêt, autour de la piste pare-feu z ≈ 204
## qui lui sert d'allée centrale :
##   - aire de jeux pour enfants (balançoires, toboggan, tourniquet, bac à sable...)
##   - étang avec ponton : point d'eau supplémentaire où les drones se remplissent
##   - pelouse de pique-nique (tables, abri couvert, nappes)
##   - espace détente (kiosque, transats, hamacs, massif fleuri)
## Les clairières sont aplanies et sans combustible (voir terrain.gd / forest.gd).

const Look := preload("res://scripts/render/look.gd")
const Vegetation := preload("res://scripts/render/vegetation.gd")

var terrain: Node3D
var park := 0   # parc en cours de construction (indice dans terrain.park_origins)
var rng := RandomNumberGenerator.new()
var wood: StandardMaterial3D
var wood_dark: StandardMaterial3D
var steel: StandardMaterial3D
var tint_mat: StandardMaterial3D   # couleur par instance (MultiMesh)

# instances regroupées en MultiMesh : [Transform3D, Color]
var trees: Array = []
var trunks: Array = []
var posts: Array = []
var reeds: Array = []
var flowers: Array = []


func build(t: Node3D, seed_val: int) -> void:
	terrain = t
	rng.seed = seed_val + 515
	wood = Look.plastic(Color(0.47, 0.31, 0.18), 0.8)
	wood_dark = Look.plastic(Color(0.3, 0.2, 0.12), 0.85)
	steel = Look.metal(Color(0.62, 0.64, 0.67), 0.4)
	tint_mat = StandardMaterial3D.new()
	tint_mat.vertex_color_use_as_albedo = true
	tint_mat.roughness = 0.7
	for i in terrain.park_origins.size():
		park = i
		_playground()
		_pond()
		_picnic()
		_relax()
		var o: Vector2 = terrain.park_origins[i]
		_tag("PARC DE LOISIRS", Vector3(o.x + 36.0, _gy("playground") + 12.0, o.y + 38.0), Color(0.75, 1.0, 0.7), 64)
	_multimesh("ParkTrees", trees, Vegetation.broadleaf_mesh(), Vegetation.foliage_material())
	_multimesh("ParkTrunks", trunks, Vegetation.trunk_mesh(), Vegetation.trunk_material())
	_multimesh("ParkFences", posts, BoxMesh.new(), wood)
	var reed := CylinderMesh.new()
	reed.top_radius = 0.015
	reed.bottom_radius = 0.04
	reed.height = 1.0
	reed.radial_segments = 4
	reed.rings = 1
	_multimesh("Reeds", reeds, reed, tint_mat)
	var bloom := SphereMesh.new()
	bloom.radius = 0.5
	bloom.height = 1.0
	bloom.radial_segments = 6
	bloom.rings = 3
	_multimesh("Flowers", flowers, bloom, tint_mat)


# ------------------------------------------------------------ aire de jeux

func _playground() -> void:
	var c := _center("playground")
	var y := _gy("playground")
	var red := Look.plastic(Color(0.78, 0.12, 0.1), 0.45)
	var blue := Look.plastic(Color(0.1, 0.32, 0.75), 0.45)
	var yellow := Look.plastic(Color(0.95, 0.75, 0.1), 0.4)
	var green := Look.plastic(Color(0.2, 0.6, 0.25), 0.45)

	# balançoires : portique en A, deux sièges
	var sw := _group("Swings", Vector3(c.x - 8.0, y, c.y - 6.0), 0.0)
	for sx in [-3.0, 3.0]:
		for sz in [-1.0, 1.0]:
			_cyl(sw, 0.07, 0.07, 2.7, Vector3(sx, 1.27, sz * 0.62), steel, Vector3(-sz * 0.25, 0, 0))
	_cyl(sw, 0.07, 0.07, 6.4, Vector3(0, 2.55, 0), steel, Vector3(0, 0, PI * 0.5))
	for k in 2:
		var x := -1.3 + k * 2.6
		for cx in [-0.24, 0.24]:
			_box(sw, Vector3(0.025, 1.9, 0.025), Vector3(x + cx, 1.55, 0), steel)
		_box(sw, Vector3(0.55, 0.06, 0.24), Vector3(x, 0.6, 0), red if k == 0 else blue)
	terrain.add_obstacle_box(Vector2(c.x - 8.0, c.y - 6.0), Vector2(6.6, 1.6), y + 2.7)

	# toboggan : tour avec toit, échelle et glissière
	var sl := _group("Slide", Vector3(c.x + 6.0, y, c.y - 6.0), 0.0)
	for px in [-0.8, 0.8]:
		for pz in [-0.8, 0.8]:
			_box(sl, Vector3(0.12, 3.3, 0.12), Vector3(px, 1.65, pz), wood)
	_box(sl, Vector3(1.8, 0.12, 1.8), Vector3(0, 1.5, 0), wood_dark)
	for side in [-1.0, 1.0]:
		_box(sl, Vector3(0.05, 0.6, 1.6), Vector3(side * 0.85, 1.85, 0), blue)
	_cyl(sl, 0.0, 1.45, 1.0, Vector3(0, 3.8, 0), red, Vector3(0, PI * 0.25, 0), 4)
	for rx in [-0.3, 0.3]:   # échelle (côté nord)
		_box(sl, Vector3(0.07, 1.8, 0.07), Vector3(rx, 0.8, -1.2), wood, Vector3(0.3, 0, 0))
	for r in 4:
		_box(sl, Vector3(0.6, 0.05, 0.06), Vector3(0, 0.3 + r * 0.38, -1.38 + r * 0.115), wood_dark)
	_box(sl, Vector3(0.7, 0.05, 3.25), Vector3(0, 0.88, 2.35), yellow, Vector3(0.42, 0, 0))
	for side in [-1.0, 1.0]:
		_box(sl, Vector3(0.05, 0.2, 3.25), Vector3(side * 0.36, 0.98, 2.35), yellow, Vector3(0.42, 0, 0))
	terrain.add_obstacle_box(Vector2(c.x + 6.0, c.y - 6.0), Vector2(2.2, 2.2), y + 4.3)

	# bascule
	var ss := _group("Seesaw", Vector3(c.x - 8.0, y, c.y + 6.0), 0.4)
	_box(ss, Vector3(0.3, 0.5, 0.35), Vector3(0, 0.25, 0), steel)
	_box(ss, Vector3(3.8, 0.08, 0.32), Vector3(0, 0.56, 0), green, Vector3(0, 0, 0.16))
	for hx in [-1.4, 1.4]:
		_cyl(ss, 0.03, 0.03, 0.4, Vector3(hx, 0.56 + hx * 0.16 + 0.2, 0), steel)

	# bac à sable
	var sb := _group("Sandbox", Vector3(c.x + 7.0, y, c.y + 6.0), 0.0)
	for e in [[Vector3(0, 0.15, -1.6), Vector3(3.4, 0.3, 0.2)], [Vector3(0, 0.15, 1.6), Vector3(3.4, 0.3, 0.2)],
			[Vector3(-1.6, 0.15, 0), Vector3(0.2, 0.3, 3.0)], [Vector3(1.6, 0.15, 0), Vector3(0.2, 0.3, 3.0)]]:
		_box(sb, e[1], e[0], wood)
	_box(sb, Vector3(3.0, 0.12, 3.0), Vector3(0, 0.12, 0), Look.pbr("sand", 3.0, Color(1.05, 1.0, 0.9)))
	_box(sb, Vector3(0.3, 0.25, 0.3), Vector3(-0.6, 0.3, 0.4), red)   # seau
	_cyl(sb, 0.0, 0.25, 0.3, Vector3(0.7, 0.3, -0.3), blue)            # château de sable

	# tourniquet
	var mg := _group("MerryGoRound", Vector3(c.x, y, c.y + 1.0), 0.0)
	_cyl(mg, 1.4, 1.4, 0.12, Vector3(0, 0.35, 0), yellow, Vector3.ZERO, 24)
	_cyl(mg, 0.08, 0.08, 1.0, Vector3(0, 0.85, 0), steel)
	for k in 4:
		var a := k * TAU / 4.0
		_box(mg, Vector3(0.04, 0.04, 1.2), Vector3(cos(a) * 0.65, 1.05, sin(a) * 0.65), red, Vector3(0, -a + PI * 0.5, 0))

	# jeux à ressort
	for k in 2:
		var spr := _group("SpringRider%d" % k, Vector3(c.x - 2.5 + k * 5.0, y, c.y - 11.0), 0.0)
		_cyl(spr, 0.12, 0.12, 0.5, Vector3(0, 0.25, 0), steel)
		_box(spr, Vector3(0.35, 0.45, 0.9), Vector3(0, 0.7, 0), green if k == 0 else red)
		_box(spr, Vector3(0.3, 0.3, 0.3), Vector3(0, 1.05, 0.38), green if k == 0 else red)

	# clôture basse (ouverte vers l'allée au sud) et bancs pour les parents
	_fence(c, y, 17.0, PI * 0.5, 0.35)
	for a in [PI * 0.15, PI * 0.85, PI * 1.25, PI * 1.75]:
		_bench_facing(c + Vector2(cos(a), sin(a)) * 14.0, y, c)
	_trees_around(c, y, 19.5, 7)
	_tag("AIRE DE JEUX", Vector3(c.x, y + 7.0, c.y), Color(1.0, 0.85, 0.4))


# ------------------------------------------------------------ étang

func _pond() -> void:
	var c := _center("pond")
	var y := _gy("pond")
	var r: float = terrain.pond_radius
	var wy: float = terrain.pond_water[park]
	# ponton en bois qui avance dans l'eau (côté sud, vers l'allée)
	var dk := _group("Pontoon", Vector3(c.x, y, c.y + r - 1.5), 0.0)
	_box(dk, Vector3(2.4, 0.14, 8.0), Vector3(0, 0.35, 0), wood)
	for px in [-1.1, 1.1]:
		for pz in [-3.6, -1.2, 1.2, 3.6]:
			_cyl(dk, 0.1, 0.1, 2.6, Vector3(px, -0.9, pz), wood_dark)
	for side in [-1.0, 1.0]:   # garde-corps
		for pz in [-3.8, -1.9, 0.0]:
			_box(dk, Vector3(0.08, 0.9, 0.08), Vector3(side * 1.15, 0.85, pz), wood_dark)
		_box(dk, Vector3(0.06, 0.06, 3.9), Vector3(side * 1.15, 1.28, -1.9), wood_dark)
	# canards
	var duck_body := Look.plastic(Color(0.45, 0.35, 0.22), 0.6)
	var duck_head := Look.plastic(Color(0.08, 0.35, 0.15), 0.4)
	for k in 5:
		var a := rng.randf() * TAU
		var d := rng.randf_range(2.0, r - 4.0)
		var du := _group("Duck%d" % k, Vector3(c.x + cos(a) * d, wy, c.y + sin(a) * d), rng.randf() * TAU)
		_sphere(du, Vector3(0.22, 0.14, 0.35), Vector3(0, 0.06, 0), duck_body)
		_sphere(du, Vector3(0.11, 0.11, 0.11), Vector3(0, 0.26, 0.22), duck_head)
		_box(du, Vector3(0.06, 0.03, 0.1), Vector3(0, 0.25, 0.35), Look.plastic(Color(0.95, 0.6, 0.1)))
	# roseaux sur les berges (sauf devant le ponton)
	for k in 260:
		var a := rng.randf() * TAU
		if absf(wrapf(a - PI * 0.5, -PI, PI)) < 0.35:
			continue
		var d := r + rng.randf_range(-1.2, 1.0)
		var px := c.x + cos(a) * d
		var pz := c.y + sin(a) * d
		var h := rng.randf_range(0.9, 1.9)
		var gy := maxf(terrain.height_at(px, pz), wy - 0.2)
		var tilt := Basis(Vector3(rng.randf_range(-1, 1), 0, rng.randf_range(-1, 1)).normalized(), rng.randf_range(0.0, 0.18))
		reeds.append([Transform3D(tilt * Basis.from_scale(Vector3(1, h, 1)), Vector3(px, gy + h * 0.5, pz)),
			Color(0.22, 0.32, 0.1).lerp(Color(0.45, 0.42, 0.2), rng.randf())])
	# bancs tournés vers l'eau
	for a in [PI * 1.5, PI * 1.15, PI * 1.85, PI * 0.95, PI * 0.05]:
		_bench_facing(c + Vector2(cos(a), sin(a)) * (r + 6.0), y, c)
	_trees_around(c, y, r + 9.5, 9)
	_tag("ÉTANG  ·  point d'eau", Vector3(c.x, y + 8.0, c.y), Color(0.6, 0.85, 1.0))


# ------------------------------------------------------------ pique-nique

func _picnic() -> void:
	var c := _center("picnic")
	var y := _gy("picnic")
	var spots := [Vector2(-12, -10), Vector2(0, -14), Vector2(12, -9), Vector2(-15, 4), Vector2(15, 5),
		Vector2(-6, 14), Vector2(7, 15)]
	for k in spots.size():
		_picnic_table(Vector3(c.x + spots[k].x, y, c.y + spots[k].y), rng.randf_range(-0.6, 0.6), "Table%d" % k)
	# abri couvert avec deux tables
	var sh := _group("Shelter", Vector3(c.x, y, c.y + 1.0), 0.0)
	for px in [-4.0, 4.0]:
		for pz in [-2.6, 2.6]:
			_box(sh, Vector3(0.22, 3.0, 0.22), Vector3(px, 1.5, pz), wood_dark)
	for side in [-1.0, 1.0]:
		_box(sh, Vector3(9.4, 0.12, 3.4), Vector3(0, 3.35, side * 1.55), Look.plastic(Color(0.42, 0.18, 0.12), 0.75),
			Vector3(side * 0.42, 0, 0))
	_box(sh, Vector3(9.4, 0.2, 0.25), Vector3(0, 3.95, 0), wood_dark)
	terrain.add_obstacle_box(Vector2(c.x, c.y + 1.0), Vector2(9.6, 6.4), y + 4.1)
	_picnic_table(Vector3(c.x - 2.2, y, c.y + 1.0), 0.0, "ShelterTable0")
	_picnic_table(Vector3(c.x + 2.2, y, c.y + 1.0), 0.0, "ShelterTable1")
	# nappes posées sur l'herbe, avec un panier
	var cloth := [Color(0.8, 0.15, 0.15), Color(0.2, 0.4, 0.8), Color(0.9, 0.8, 0.3)]
	for k in 3:
		var a := PI * (0.2 + k * 0.6) + 0.3
		var p := c + Vector2(cos(a), sin(a)) * 20.0
		var nap := _group("Blanket%d" % k, Vector3(p.x, y, p.y), rng.randf() * TAU)
		_box(nap, Vector3(2.0, 0.02, 1.6), Vector3(0, 0.01, 0), Look.plastic(cloth[k], 0.9))
		_box(nap, Vector3(0.5, 0.3, 0.35), Vector3(0.5, 0.16, 0.3), wood)
	# poubelles
	for a in [PI * 0.5, PI * 1.1, PI * 1.9]:
		var p := c + Vector2(cos(a), sin(a)) * 24.0
		var bin := _group("Bin", Vector3(p.x, y, p.y), 0.0)
		_cyl(bin, 0.3, 0.27, 0.9, Vector3(0, 0.45, 0), Look.plastic(Color(0.15, 0.35, 0.18), 0.5))
	_trees_around(c, y, 26.0, 10)
	_tag("PIQUE-NIQUE", Vector3(c.x, y + 8.0, c.y), Color(0.75, 1.0, 0.55))


func _picnic_table(p: Vector3, yaw: float, node_name: String) -> void:
	var g := _group(node_name, p, yaw)
	_box(g, Vector3(2.0, 0.06, 0.8), Vector3(0, 0.76, 0), wood)
	for sz in [-0.68, 0.68]:
		_box(g, Vector3(2.0, 0.05, 0.3), Vector3(0, 0.45, sz), wood)
	for sx in [-0.75, 0.75]:   # pieds en A + traverse
		for sz in [-1.0, 1.0]:
			_box(g, Vector3(0.07, 0.86, 0.07), Vector3(sx, 0.4, sz * 0.36), wood_dark, Vector3(-sz * 0.55, 0, 0))
		_box(g, Vector3(0.07, 0.06, 1.66), Vector3(sx, 0.4, 0), wood_dark)


# ------------------------------------------------------------ espace détente

func _relax() -> void:
	var c := _center("relax")
	var y := _gy("relax")
	# kiosque hexagonal
	var gz := _group("Gazebo", Vector3(c.x, y, c.y), 0.0)
	_cyl(gz, 3.2, 3.3, 0.3, Vector3(0, 0.15, 0), wood_dark, Vector3.ZERO, 6)
	for k in 6:
		var a := k * TAU / 6.0
		_box(gz, Vector3(0.16, 2.6, 0.16), Vector3(cos(a) * 2.8, 1.6, sin(a) * 2.8), Look.plastic(Color(0.92, 0.9, 0.85), 0.6))
	_cyl(gz, 0.15, 3.8, 1.5, Vector3(0, 3.65, 0), Look.plastic(Color(0.25, 0.35, 0.3), 0.7), Vector3.ZERO, 6)
	_cyl(gz, 2.6, 2.6, 0.08, Vector3(0, 0.6, 0), wood, Vector3.ZERO, 6)   # banc circulaire
	terrain.add_obstacle_disc(c, 3.9, y + 4.4)
	# transats tournés vers la clairière
	var canvas := [Color(0.9, 0.45, 0.15), Color(0.2, 0.55, 0.7), Color(0.85, 0.85, 0.8), Color(0.75, 0.2, 0.3)]
	for k in 4:
		var dc := _group("Deckchair%d" % k, Vector3(c.x - 6.0 + k * 2.6, y, c.y + 9.0), rng.randf_range(-0.2, 0.2))
		var m := Look.plastic(canvas[k], 0.85)
		_box(dc, Vector3(0.62, 0.04, 1.1), Vector3(0, 0.32, 0.25), m, Vector3(-0.12, 0, 0))
		_box(dc, Vector3(0.62, 0.04, 0.8), Vector3(0, 0.62, -0.5), m, Vector3(1.0, 0, 0))
		for sx in [-0.32, 0.32]:
			_box(dc, Vector3(0.04, 0.04, 1.6), Vector3(sx, 0.3, 0.0), wood, Vector3(-0.2, 0, 0))
	# hamacs entre deux poteaux
	for k in 2:
		var hm := _group("Hammock%d" % k, Vector3(c.x + 10.0, y, c.y - 6.0 + k * 6.0), 0.3)
		for sx in [-1.9, 1.9]:
			_cyl(hm, 0.1, 0.12, 1.9, Vector3(sx, 0.95, 0), wood_dark)
		var fab := Look.plastic(Color(0.85, 0.75, 0.45) if k == 0 else Color(0.35, 0.6, 0.45), 0.9)
		_box(hm, Vector3(1.6, 0.04, 0.85), Vector3(0, 0.62, 0), fab)
		for sx in [-1.0, 1.0]:
			_box(hm, Vector3(1.15, 0.04, 0.7), Vector3(sx * 1.32, 1.05, 0), fab, Vector3(0, 0, sx * 0.75))
	# massif fleuri entouré de bancs
	var fc := c + Vector2(-9.0, -6.0)
	var bed := _group("FlowerBed", Vector3(fc.x, y, fc.y), 0.0)
	_cyl(bed, 2.4, 2.5, 0.3, Vector3(0, 0.15, 0), Look.plastic(Color(0.22, 0.15, 0.1), 0.95), Vector3.ZERO, 24)
	var petals := [Color(0.9, 0.15, 0.2), Color(0.95, 0.8, 0.15), Color(0.65, 0.3, 0.8), Color(0.98, 0.95, 0.95), Color(0.95, 0.45, 0.6)]
	for k in 90:
		var a := rng.randf() * TAU
		var d := sqrt(rng.randf()) * 2.2
		var s := rng.randf_range(0.14, 0.26)
		flowers.append([Transform3D(Basis.from_scale(Vector3(s, s * 0.8, s)),
			Vector3(fc.x + cos(a) * d, y + 0.35 + rng.randf() * 0.15, fc.y + sin(a) * d)), petals[rng.randi() % petals.size()]])
	for a in [0.0, PI * 0.5, PI, PI * 1.5]:
		_bench_facing(fc + Vector2(cos(a), sin(a)) * 4.2, y, fc)
	_trees_around(c, y, 19.5, 8)
	_tag("ESPACE DÉTENTE", Vector3(c.x, y + 8.0, c.y), Color(0.85, 0.8, 1.0))


# ------------------------------------------------------------ éléments communs

func _bench_facing(p: Vector2, y: float, look_at_p: Vector2) -> void:
	var d := look_at_p - p
	var b := _group("Bench", Vector3(p.x, y, p.y), atan2(d.x, d.y))
	_box(b, Vector3(1.8, 0.06, 0.45), Vector3(0, 0.45, 0), wood)
	_box(b, Vector3(1.8, 0.35, 0.05), Vector3(0, 0.78, -0.24), wood, Vector3(-0.15, 0, 0))
	for sx in [-0.75, 0.75]:
		_box(b, Vector3(0.07, 0.45, 0.4), Vector3(sx, 0.22, 0), steel)


## Clôture circulaire de piquets et lisses, avec une ouverture centrée sur l'angle `gap_at`.
func _fence(c: Vector2, y: float, r: float, gap_at: float, gap_half: float) -> void:
	var n := int(TAU * r / 2.5)
	var prev := Vector3.INF
	for k in n + 1:
		var a := k * TAU / n
		if absf(wrapf(a - gap_at, -PI, PI)) < gap_half:
			prev = Vector3.INF
			continue
		var p := Vector3(c.x + cos(a) * r, y, c.y + sin(a) * r)
		posts.append([Transform3D(Basis.from_scale(Vector3(0.1, 0.9, 0.1)), p + Vector3(0, 0.45, 0)), Color.WHITE])
		if prev != Vector3.INF:
			var dv := p - prev
			var yaw := Basis(Vector3.UP, atan2(dv.x, dv.z))
			for h in [0.4, 0.75]:
				posts.append([Transform3D(yaw * Basis.from_scale(Vector3(0.05, 0.08, dv.length())),
					(p + prev) * 0.5 + Vector3(0, h, 0)), Color.WHITE])
		prev = p


## Feuillus d'ombrage en couronne autour d'une zone.
func _trees_around(c: Vector2, y: float, r: float, count: int) -> void:
	var a0 := rng.randf() * TAU
	for k in count:
		var a := a0 + k * TAU / count + rng.randf_range(-0.2, 0.2)
		var d := r + rng.randf_range(-1.5, 1.5)
		var gx := c.x + cos(a) * d
		var gz := c.y + sin(a) * d
		var gy: float = terrain.height_at(gx, gz)
		var s := rng.randf_range(2.8, 4.2)
		var crown := Vector3(gx, gy + s * 0.75 + s * 0.55, gz)
		trees.append([Transform3D(Basis(Vector3.UP, rng.randf() * TAU) * Basis.from_scale(Vector3(s, s * 1.05, s)), crown),
			Vegetation.leaf_color(rng)])
		trunks.append([Transform3D(Basis.from_scale(Vector3(0.9, s * 1.1, 0.9)), Vector3(gx, gy + s * 0.55, gz)),
			Color(0.75, 0.68, 0.6)])
		terrain.add_obstacle_disc(Vector2(gx, gz), s * 0.6, crown.y + s * 0.55)


func _center(zone: String) -> Vector2:
	return terrain.park_center(park, zone)


func _gy(zone: String) -> float:
	return terrain.park_ground[park][zone]


func _group(node_name: String, pos: Vector3, yaw: float) -> Node3D:
	var g := Node3D.new()
	g.name = node_name
	g.position = pos
	g.rotation.y = yaw
	add_child(g)
	return g


func _box(parent: Node3D, size: Vector3, pos: Vector3, mat: Material, rot := Vector3.ZERO) -> void:
	var bm := BoxMesh.new()
	bm.size = size
	_part(parent, bm, pos, mat, rot)


func _cyl(parent: Node3D, r_top: float, r_bot: float, h: float, pos: Vector3, mat: Material,
		rot := Vector3.ZERO, seg := 12) -> void:
	var cm := CylinderMesh.new()
	cm.top_radius = r_top
	cm.bottom_radius = r_bot
	cm.height = h
	cm.radial_segments = seg
	cm.rings = 1
	_part(parent, cm, pos, mat, rot)


func _sphere(parent: Node3D, radii: Vector3, pos: Vector3, mat: Material) -> void:
	var sm := SphereMesh.new()
	sm.radius = 1.0
	sm.height = 2.0
	sm.radial_segments = 10
	sm.rings = 5
	var mi := MeshInstance3D.new()
	mi.mesh = sm
	mi.material_override = mat
	mi.position = pos
	mi.scale = radii
	parent.add_child(mi)


func _part(parent: Node3D, mesh: Mesh, pos: Vector3, mat: Material, rot: Vector3) -> void:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = mat
	mi.position = pos
	mi.rotation = rot
	parent.add_child(mi)


func _tag(text: String, pos: Vector3, col: Color, size := 48) -> void:
	var tag := Label3D.new()
	tag.text = text
	tag.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	tag.font_size = size
	tag.outline_size = 10
	tag.pixel_size = 0.03
	tag.modulate = col
	tag.position = pos
	add_child(tag)


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
