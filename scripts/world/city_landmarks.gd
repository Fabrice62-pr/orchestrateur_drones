extends Node3D
## Bâtiments remarquables et services publics de la ville (les volumes principaux de
## l'hôpital et du commissariat sont des immeubles de city.gd ; ici les détails) :
##   - hôpital : héliport sur le toit, croix rouges, auvent des urgences, ambulances
##   - commissariat de police : bandeau bleu, enseignes, antenne radio, voitures de police
##   - grande mosquée : salle de prière à toit de tuiles vertes, arcades, zellige, minaret
##   - place centrale : fontaine monumentale entourée de palmiers
##   - médina : remparts ocre crénelés, tours d'angle et porte monumentale (bab)

const Look := preload("res://scripts/render/look.gd")
const Models := preload("res://scripts/render/models.gd")

var city: Node3D
var terrain: Node3D
var merlons: Array = []      # créneaux des remparts (MultiMesh)
var vehicles: Array = []     # [Transform3D, Color] ambulances et voitures de police
var police_spots: Array = [] # places des voitures de patrouille (véhicules animés, poaching.gd)
var cream: StandardMaterial3D
var green_tile: StandardMaterial3D
var zellige: StandardMaterial3D
var dark: StandardMaterial3D
var gold: StandardMaterial3D
var white: StandardMaterial3D
var red: StandardMaterial3D
var navy: StandardMaterial3D
var asphalt: StandardMaterial3D


func build(c: Node3D, t: Node3D, _seed_val: int) -> void:
	city = c
	terrain = t
	cream = Look.plastic(Color(0.93, 0.89, 0.8), 0.7)
	green_tile = Look.plastic(Color(0.06, 0.38, 0.24), 0.3)
	zellige = Look.plastic(Color(0.08, 0.45, 0.5), 0.25)
	dark = Look.plastic(Color(0.05, 0.045, 0.04), 0.9)
	gold = Look.metal(Color(0.9, 0.72, 0.3), 0.25)
	white = Look.plastic(Color(0.96, 0.96, 0.95), 0.5)
	red = Look.emissive(Color(0.85, 0.05, 0.05), 0.6)
	navy = Look.plastic(Color(0.05, 0.12, 0.35), 0.45)
	asphalt = Look.pbr("asphalt", 4.0, Color(0.8, 0.8, 0.8))
	var lm: Dictionary = city.landmarks
	if lm.has("hospital"):
		_hospital(city.lot_rect(lm["hospital"]))
	if lm.has("police"):
		_police(city.lot_rect(lm["police"]))
	if lm.has("mosque"):
		_mosque(city.lot_rect(lm["mosque"]))
	if lm.has("plaza"):
		_plaza(city.block_rect(lm["plaza"]))
	if lm.has("twin"):
		var tc: Vector2 = city.block_rect(lm["twin"]).get_center()
		_tag("QUARTIER DES AFFAIRES", Vector3(tc.x, 138.0, tc.y), Color(0.7, 0.85, 1.0), 72)
	_medina_walls()
	_flush_multimeshes()


# ------------------------------------------------------------ hôpital

func _hospital(lot: Rect2) -> void:
	var c := lot.get_center()
	var main_z := lot.position.y + 7.0    # aile principale : 26 m de haut, 14 m de profondeur
	var front := lot.position.y + 14.0    # façade sud (côté cour des ambulances)
	# héliport sur le toit
	var hp := Vector3(c.x - 4.0, 26.0, main_z)
	_cyl(Vector3(5.6, 0.16, 5.6), hp + Vector3(0, 0.08, 0), Look.plastic(Color(0.22, 0.23, 0.24), 0.8), 32)
	_cyl(Vector3(5.2, 0.18, 5.2), hp + Vector3(0, 0.1, 0), Look.plastic(Color(0.95, 0.8, 0.1), 0.6), 32)
	_cyl(Vector3(4.8, 0.2, 4.8), hp + Vector3(0, 0.11, 0), Look.plastic(Color(0.22, 0.23, 0.24), 0.8), 32)
	for sx: float in [-1.0, 1.0]:
		_box(Vector3(0.7, 0.05, 3.6), hp + Vector3(sx * 1.1, 0.24, 0), white)
	_box(Vector3(1.6, 0.05, 0.7), hp + Vector3(0, 0.24, 0), white)
	# croix rouges sur panneaux blancs (façades nord et sud)
	for side: float in [-1.0, 1.0]:
		var z: float = main_z + side * 7.15
		var x := c.x + 9.0
		_box(Vector3(4.4, 4.4, 0.25), Vector3(x, 21.5, z), white)
		_box(Vector3(3.2, 1.0, 0.3), Vector3(x, 21.5, z + side * 0.05), red)
		_box(Vector3(1.0, 3.2, 0.3), Vector3(x, 21.5, z + side * 0.05), red)
	_text("HÔPITAL", Vector3(c.x - 3.0, 21.0, front + 0.2), 0.0, 160, Color(0.75, 0.05, 0.05))
	_text("HÔPITAL", Vector3(c.x - 3.0, 21.0, lot.position.y - 0.2), PI, 160, Color(0.75, 0.05, 0.05))
	# cour des ambulances (enrobé) et auvent des urgences
	var court := Rect2(lot.position.x + 12.0, front, lot.end.x - lot.position.x - 12.0, lot.end.y - front)
	_box(Vector3(court.size.x, 0.1, court.size.y), Vector3(court.get_center().x, 0.06, court.get_center().y), asphalt)
	var cx := court.get_center().x
	_box(Vector3(10.0, 0.35, 5.0), Vector3(cx, 4.4, front + 2.5), white)
	_box(Vector3(10.0, 0.5, 0.1), Vector3(cx, 4.4, front + 5.05), red)
	for px: float in [-4.6, 4.6]:
		_box(Vector3(0.3, 4.3, 0.3), Vector3(cx + px, 2.15, front + 4.7), white)
	_text("URGENCES", Vector3(cx, 5.1, front + 5.12), 0.0, 90, Color(1.0, 1.0, 1.0))
	for k in 3:   # ambulances blanches, gyrophares rouges et bleus
		var p := Vector3(court.position.x + 3.5 + k * 3.6, 0.11, court.end.y - 4.0)
		vehicles.append([Transform3D(Basis.from_scale(Vector3(1.1, 1.45, 1.15)), p), Color(0.97, 0.97, 0.95)])
		_box(Vector3(0.7, 0.16, 0.22), p + Vector3(-0.38, 2.15, -0.9), red)
		_box(Vector3(0.7, 0.16, 0.22), p + Vector3(0.38, 2.15, -0.9), Look.emissive(Color(0.1, 0.3, 1.0), 1.5))
		_box(Vector3(1.95, 0.35, 0.05), p + Vector3(0, 1.1, 0), red, Vector3(0, PI * 0.5, 0))
	_tag("HÔPITAL", Vector3(c.x, 36.0, c.y), Color(1.0, 0.55, 0.55), 72)


# ------------------------------------------------------------ police

func _police(lot: Rect2) -> void:
	var c := lot.get_center()
	var w := lot.size.x - 2.0
	var bz := lot.position.y + 7.5
	var front := lot.position.y + 15.0
	# bandeau bleu en ceinture et acrotère bleu
	_box(Vector3(w + 0.3, 1.0, 15.3), Vector3(c.x, 4.7, bz), navy)
	_box(Vector3(w + 0.3, 0.5, 15.3), Vector3(c.x, 12.9, bz), navy)
	# enseignes (rue au nord, cour au sud)
	for side: float in [-1.0, 1.0]:
		var z: float = bz + side * 7.72
		_box(Vector3(11.0, 2.0, 0.15), Vector3(c.x, 9.0, z), navy)
		_text("POLICE", Vector3(c.x, 9.0, z + side * 0.1), 0.0 if side > 0.0 else PI, 150, Color(1, 1, 1))
	# entrée : auvent bleu et portes vitrées
	_box(Vector3(7.0, 0.3, 3.0), Vector3(c.x, 3.6, front + 1.5), navy)
	_box(Vector3(3.2, 2.6, 0.1), Vector3(c.x, 1.3, front + 0.05), Look.glass())
	# antenne radio et feu d'obstacle
	var ap := Vector3(c.x + w * 0.5 - 3.0, 13.0, lot.position.y + 3.0)
	_cyl(Vector3(0.12, 16.0, 0.12), ap + Vector3(0, 8.0, 0), Look.metal(Color(0.75, 0.75, 0.78)), 8)
	_box(Vector3(0.35, 0.35, 0.35), ap + Vector3(0, 16.2, 0), red)
	terrain.add_obstacle_box(Vector2(ap.x, ap.z), Vector2(1.0, 1.0), 30.0)
	# parking et voitures de police (bleu nuit, gyrophares bleus)
	var court := Rect2(lot.position.x, front, lot.size.x, lot.end.y - front)
	_box(Vector3(court.size.x, 0.1, court.size.y), Vector3(court.get_center().x, 0.06, court.get_center().y), asphalt)
	for k in 4:
		var p := Vector3(court.position.x + 4.5 + k * 3.4, 0.11, court.end.y - 4.0)
		if k >= 2:   # deux voitures de patrouille qui partent en intervention
			police_spots.append(p)
			continue
		vehicles.append([Transform3D(Basis.IDENTITY, p), Color(0.06, 0.12, 0.34)])
		_box(Vector3(1.1, 0.14, 0.25), p + Vector3(0, 1.53, 0.2), Look.emissive(Color(0.1, 0.3, 1.0), 1.8))
		_box(Vector3(1.86, 0.25, 0.05), p + Vector3(0, 0.7, 0), white, Vector3(0, PI * 0.5, 0))
	# mât et drapeau rouge à étoile verte
	var fp := Vector3(court.end.x - 2.0, 0.0, front + 2.0)
	_cyl(Vector3(0.07, 10.0, 0.07), fp + Vector3(0, 5.0, 0), Look.metal(Color(0.85, 0.85, 0.85)), 8)
	var flag := Vector3(fp.x - 1.0, 9.2, fp.z)
	_box(Vector3(1.9, 1.25, 0.04), flag, Look.plastic(Color(0.75, 0.06, 0.08), 0.7))
	for k in 5:   # pentagramme : cinq traits verts
		var a0 := PI * 0.5 + k * TAU / 5.0
		var a1 := PI * 0.5 + (k + 2) * TAU / 5.0
		var p0 := Vector2(cos(a0), sin(a0)) * 0.36
		var p1 := Vector2(cos(a1), sin(a1)) * 0.36
		var m := (p0 + p1) * 0.5
		var dv := p1 - p0
		for sd: float in [-1.0, 1.0]:
			_box(Vector3(dv.length(), 0.05, 0.02), flag + Vector3(m.x, m.y, sd * 0.03), Look.plastic(Color(0.05, 0.4, 0.15)),
				Vector3(0, 0, atan2(dv.y, dv.x)))
	_tag("COMMISSARIAT DE POLICE", Vector3(c.x, 24.0, c.y), Color(0.6, 0.75, 1.0), 64)


# ------------------------------------------------------------ mosquée

func _mosque(lot: Rect2) -> void:
	var c := lot.get_center()
	# esplanade en marbre
	_box(Vector3(lot.size.x + 1.6, 0.35, lot.size.y + 1.6), Vector3(c.x, 0.175, c.y), Look.plastic(Color(0.9, 0.88, 0.84), 0.3))
	# salle de prière
	var hall := Vector3(c.x + 1.5, 0.35, c.y + 4.0)
	var hs := Vector3(27.0, 11.0, 21.0)
	_box(hs, hall + Vector3(0, hs.y * 0.5, 0), cream)
	_box(Vector3(hs.x + 0.2, 1.1, hs.z + 0.2), hall + Vector3(0, hs.y - 1.6, 0), zellige)   # frise de zellige
	_box(Vector3(hs.x + 1.0, 0.4, hs.z + 1.0), hall + Vector3(0, hs.y + 0.2, 0), cream)    # corniche
	var roof := PrismMesh.new()   # toit à deux pans en tuiles vertes vernissées
	roof.size = Vector3(hs.z + 1.0, 4.2, hs.x + 1.0)
	_part(roof, hall + Vector3(0, hs.y + 0.4 + 2.1, 0), green_tile, Vector3(0, PI * 0.5, 0))
	var dome := SphereMesh.new()   # coupole verte au-dessus du mihrab
	dome.radius = 3.4
	dome.height = 3.4
	dome.is_hemisphere = true
	_part(dome, hall + Vector3(0, hs.y + 3.6, hs.z * 0.25), green_tile)
	# arcades sur la façade nord (côté cour) : arcs outrepassés sombres
	var fz := hall.z - hs.z * 0.5 - 0.06
	for k in 9:
		var ax := hall.x - hs.x * 0.5 + 2.0 + k * (hs.x - 4.0) / 8.0
		var big := k == 4
		var aw := 2.4 if big else 1.6
		var ah := 6.5 if big else 4.6
		_box(Vector3(aw, ah, 0.12), Vector3(ax, 0.35 + ah * 0.5, fz), dark)
		_cyl(Vector3(aw * 0.55, 0.12, aw * 0.55), Vector3(ax, 0.35 + ah, fz), dark, 16, Vector3(PI * 0.5, 0, 0))
		if big:   # porte monumentale en bois sculpté, encadrement de zellige
			_box(Vector3(aw + 1.2, ah + 2.2, 0.08), Vector3(ax, 0.35 + (ah + 2.2) * 0.5, fz - 0.03), zellige)
			_box(Vector3(aw - 0.3, ah - 0.4, 0.16), Vector3(ax, 0.35 + (ah - 0.4) * 0.5, fz - 0.04), Look.plastic(Color(0.4, 0.22, 0.1)))
	terrain.add_obstacle_box(Vector2(hall.x, hall.z), Vector2(hs.x + 1.0, hs.z + 1.0), hs.y + 5.0)
	# fontaine aux ablutions dans la cour
	_fountain(Vector3(c.x + 6.0, 0.35, lot.position.y + 4.5), 2.2)
	# minaret (angle nord-ouest)
	var mp := Vector3(lot.position.x + 3.6, 0.35, lot.position.y + 3.6)
	var mw := 6.4
	var mh := 52.0
	_box(Vector3(mw, mh, mw), mp + Vector3(0, mh * 0.5, 0), Look.plastic(Color(0.9, 0.84, 0.72), 0.7))
	for bh: float in [16.0, 30.0, 44.0]:   # bandeaux de zellige
		_box(Vector3(mw + 0.12, 1.2, mw + 0.12), mp + Vector3(0, bh, 0), zellige)
	for k in 4:   # baies en arc sur chaque face
		var a := k * PI * 0.5
		var n := Vector3(sin(a), 0, cos(a))
		for wy: float in [10.0, 22.0, 37.0]:
			_box(Vector3(1.0, 2.6, 0.12), mp + n * (mw * 0.5 + 0.02) + Vector3(0, wy, 0), dark, Vector3(0, a, 0))
		for wx: float in [-1.0, 1.0]:   # panneaux d'entrelacs (darj w ktaf)
			_box(Vector3(1.1, 7.0, 0.1), mp + n * (mw * 0.5 + 0.03) + Basis(Vector3.UP, a) * Vector3(wx * 1.9, 48.0 - 3.5, 0),
				green_tile, Vector3(0, a, 0))
	_box(Vector3(mw + 1.2, 0.6, mw + 1.2), mp + Vector3(0, mh + 0.3, 0), cream)   # balcon du muezzin
	for k in 4:   # créneaux en dents de scie
		for j in 4:
			var a := k * PI * 0.5
			var o := Basis(Vector3.UP, a) * Vector3(-mw * 0.5 + 0.8 + j * 1.6, 0, mw * 0.5 + 0.35)
			merlons.append([Transform3D(Basis.from_scale(Vector3(0.7, 0.9, 0.35)), mp + o + Vector3(0, mh + 1.05, 0)), Color(0.9, 0.84, 0.72)])
	_box(Vector3(2.8, 6.0, 2.8), mp + Vector3(0, mh + 3.6, 0), Look.plastic(Color(0.9, 0.84, 0.72), 0.7))   # lanternon
	_box(Vector3(2.9, 0.7, 2.9), mp + Vector3(0, mh + 4.5, 0), zellige)
	var cap := SphereMesh.new()
	cap.radius = 1.5
	cap.height = 1.5
	cap.is_hemisphere = true
	_part(cap, mp + Vector3(0, mh + 6.6, 0), green_tile)
	_cyl(Vector3(0.08, 3.2, 0.08), mp + Vector3(0, mh + 9.2, 0), gold, 6)
	for k in 3:   # jamour : trois boules dorées
		var r := 0.42 - k * 0.1
		var s := SphereMesh.new()
		s.radius = r
		s.height = r * 2.0
		_part(s, mp + Vector3(0, mh + 8.4 + k * 0.85, 0), gold)
	terrain.add_obstacle_box(Vector2(mp.x, mp.z), Vector2(mw + 1.2, mw + 1.2), mh + 11.0)
	_tag("GRANDE MOSQUÉE", Vector3(c.x, mh + 18.0, c.y), Color(0.6, 1.0, 0.75), 72)


# ------------------------------------------------------------ place centrale

func _plaza(br: Rect2) -> void:
	var c := br.get_center()
	_box(Vector3(18.0, 0.12, 18.0), Vector3(c.x, 0.3, c.y), Look.plastic(Color(0.86, 0.83, 0.78), 0.4))   # dallage
	_fountain(Vector3(c.x, 0.36, c.y), 5.0)
	_tag("PLACE CENTRALE", Vector3(c.x, 18.0, c.y), Color(1.0, 0.95, 0.7), 56)


## Fontaine : bassin octogonal de marbre, vasque centrale et jets d'eau.
func _fountain(p: Vector3, r: float) -> void:
	var marble := Look.plastic(Color(0.92, 0.9, 0.86), 0.25)
	_cyl(Vector3(r, 0.7, r), p + Vector3(0, 0.35, 0), marble, 8)
	var water := MeshInstance3D.new()
	var wm := CylinderMesh.new()
	wm.top_radius = r - 0.35
	wm.bottom_radius = r - 0.35
	wm.height = 0.02
	wm.radial_segments = 8
	wm.material = terrain.lake_material
	water.mesh = wm
	water.position = p + Vector3(0, 0.62, 0)
	add_child(water)
	_cyl(Vector3(0.35, 1.8, 0.35), p + Vector3(0, 1.4, 0), marble, 8)
	_cyl(Vector3(r * 0.32, 0.25, r * 0.32), p + Vector3(0, 2.3, 0), zellige, 12)
	var jet := CPUParticles3D.new()
	jet.amount = 60
	jet.lifetime = 1.1
	jet.direction = Vector3.UP
	jet.spread = 14.0
	jet.initial_velocity_min = 3.5
	jet.initial_velocity_max = 4.5
	jet.gravity = Vector3(0, -9.8, 0)
	jet.scale_amount_min = 0.08
	jet.scale_amount_max = 0.14
	var dm := SphereMesh.new()
	dm.radius = 0.5
	dm.height = 1.0
	dm.radial_segments = 4
	dm.rings = 2
	var jm := StandardMaterial3D.new()
	jm.albedo_color = Color(0.85, 0.92, 1.0, 0.6)
	jm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	jm.roughness = 0.1
	dm.material = jm
	jet.mesh = dm
	jet.position = p + Vector3(0, 2.5, 0)
	add_child(jet)


# ------------------------------------------------------------ médina

## Remparts sur le pourtour extérieur des îlots de la médina, tours aux angles, une porte.
func _medina_walls() -> void:
	var md: Dictionary = city.medina
	if md.is_empty():
		return
	var wall_mat := Look.pbr("sand", 3.0, Color(0.95, 0.68, 0.48))
	var thick := 1.2
	var h := 7.5
	var sum := Vector2.ZERO
	var gate_key := Vector2i(-1, -1)
	for key in md:
		sum += city.block_rect(key).get_center()
		if gate_key.x < 0 or key.x > gate_key.x or (key.x == gate_key.x and key.y < gate_key.y):
			gate_key = key
	for key in md:
		var lot: Rect2 = city.lot_rect(key)
		var edges := [[Vector2i(0, -1), Vector2(lot.get_center().x, lot.position.y + thick * 0.5), Vector2(lot.size.x, thick)],
			[Vector2i(0, 1), Vector2(lot.get_center().x, lot.end.y - thick * 0.5), Vector2(lot.size.x, thick)],
			[Vector2i(-1, 0), Vector2(lot.position.x + thick * 0.5, lot.get_center().y), Vector2(thick, lot.size.y)],
			[Vector2i(1, 0), Vector2(lot.end.x - thick * 0.5, lot.get_center().y), Vector2(thick, lot.size.y)]]
		for e in edges:
			var dirv: Vector2i = e[0]
			if md.has(key + dirv):
				continue   # côté intérieur de la médina : pas de rempart
			var ec: Vector2 = e[1]
			var es: Vector2 = e[2]
			var gate: bool = key == gate_key and dirv == Vector2i(1, 0)
			if gate:   # porte : rempart coupé au milieu, arc monumental
				var half := (es.y - 6.0) * 0.5
				for sd: float in [-1.0, 1.0]:
					var gc := Vector2(ec.x, ec.y + sd * (3.0 + half * 0.5))
					_box(Vector3(es.x, h, half), Vector3(gc.x, h * 0.5, gc.y), wall_mat)
					terrain.add_obstacle_box(gc, Vector2(es.x, half), h)
					_box(Vector3(3.6, h + 3.0, 3.6), Vector3(ec.x, (h + 3.0) * 0.5, ec.y + sd * 4.6), wall_mat)
				_box(Vector3(es.x + 0.6, 3.2, 9.4), Vector3(ec.x, h + 1.0, ec.y), wall_mat)   # linteau
				_box(Vector3(0.1, 1.0, 6.0), Vector3(ec.x + 0.92, h + 0.9, ec.y), zellige)
				_text("BAB", Vector3(ec.x + 0.98, h + 0.9, ec.y), PI * 0.5, 80, Color(1.0, 0.95, 0.85))
			else:
				_box(Vector3(es.x, h, es.y), Vector3(ec.x, h * 0.5, ec.y), wall_mat)
				terrain.add_obstacle_box(ec, es, h)
			# créneaux
			var along_x := es.x > es.y
			var length := es.x if along_x else es.y
			var n := int(length / 1.5)
			for k in n:
				var u := -length * 0.5 + (k + 0.5) * length / n
				if gate and absf(u) < 5.0:
					continue
				var mpos := Vector3(ec.x + (u if along_x else 0.0), h + 0.45, ec.y + (0.0 if along_x else u))
				merlons.append([Transform3D(Basis.from_scale(Vector3(0.8 if along_x else thick, 0.9, thick if along_x else 0.8)), mpos),
					Color(0.95, 0.68, 0.48)])
		# tours carrées aux angles extérieurs
		for corner: Vector2i in [Vector2i(-1, -1), Vector2i(1, -1), Vector2i(-1, 1), Vector2i(1, 1)]:
			if md.has(key + Vector2i(corner.x, 0)) and md.has(key + Vector2i(0, corner.y)):
				continue
			var tp := Vector2(lot.position.x if corner.x < 0 else lot.end.x, lot.position.y if corner.y < 0 else lot.end.y)
			tp -= Vector2(corner.x, corner.y) * 1.2
			_box(Vector3(3.4, h + 2.5, 3.4), Vector3(tp.x, (h + 2.5) * 0.5, tp.y), wall_mat)
			terrain.add_obstacle_box(tp, Vector2(3.4, 3.4), h + 2.5)
	var mc := sum / md.size()
	_tag("MÉDINA", Vector3(mc.x, 30.0, mc.y), Color(1.0, 0.8, 0.55), 80)


# ------------------------------------------------------------ outils

func _flush_multimeshes() -> void:
	if not merlons.is_empty():
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.use_colors = true
		mm.mesh = BoxMesh.new()
		mm.instance_count = merlons.size()
		for k in merlons.size():
			mm.set_instance_transform(k, merlons[k][0])
			mm.set_instance_color(k, merlons[k][1])
		var mi := MultiMeshInstance3D.new()
		mi.name = "Merlons"
		mi.multimesh = mm
		var m := StandardMaterial3D.new()
		m.vertex_color_use_as_albedo = true
		m.roughness = 0.9
		mi.material_override = m
		add_child(mi)
	if not vehicles.is_empty():
		var vm := MultiMesh.new()
		vm.transform_format = MultiMesh.TRANSFORM_3D
		vm.use_colors = true
		vm.mesh = Models.car_mesh()
		vm.instance_count = vehicles.size()
		for k in vehicles.size():
			vm.set_instance_transform(k, vehicles[k][0])
			vm.set_instance_color(k, vehicles[k][1])
		var vi := MultiMeshInstance3D.new()
		vi.name = "ServiceVehicles"
		vi.multimesh = vm
		add_child(vi)


func _box(size: Vector3, pos: Vector3, mat: Material, rot := Vector3.ZERO) -> void:
	var bm := BoxMesh.new()
	bm.size = size
	_part(bm, pos, mat, rot)


## Cylindre : size = (rayon haut, hauteur, rayon bas).
func _cyl(size: Vector3, pos: Vector3, mat: Material, seg := 12, rot := Vector3.ZERO) -> void:
	var cm := CylinderMesh.new()
	cm.top_radius = size.x
	cm.height = size.y
	cm.bottom_radius = size.z
	cm.radial_segments = seg
	cm.rings = 1
	_part(cm, pos, mat, rot)


func _part(mesh: Mesh, pos: Vector3, mat: Material, rot := Vector3.ZERO) -> void:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = mat
	mi.position = pos
	mi.rotation = rot
	add_child(mi)


## Texte peint sur une façade (lisible depuis +z local, tourné de yaw).
func _text(txt: String, pos: Vector3, yaw: float, size: int, col: Color) -> void:
	var l := Label3D.new()
	l.text = txt
	l.font_size = size
	l.pixel_size = 0.02
	l.outline_size = 8
	l.outline_modulate = Color(0, 0, 0, 0.5)
	l.modulate = col
	l.position = pos
	l.rotation.y = yaw
	add_child(l)


func _tag(text: String, pos: Vector3, col: Color, size: int) -> void:
	var tag := Label3D.new()
	tag.text = text
	tag.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	tag.font_size = size
	tag.outline_size = 12
	tag.pixel_size = 0.03
	tag.modulate = col
	tag.position = pos
	add_child(tag)
