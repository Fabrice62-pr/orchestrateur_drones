extends Node3D
## Maison forestière : poste des gardes forestiers à l'entrée de la forêt.
## Chalet en bois sur soubassement en pierre (toit à deux pans, porche), garage
## pour les véhicules, deux 4x4 verts garés devant, mât avec drapeau, panneau
## d'accueil et tas de bois. Façade tournée vers la piste (+z).

const Look := preload("res://scripts/render/look.gd")
const Models := preload("res://scripts/render/models.gd")

var terrain: Node3D


func build(t: Node3D) -> void:
	terrain = t
	var y: float = terrain.ranger_ground
	var c: Vector2 = terrain.ranger_center
	var wood := Look.plastic(Color(0.5, 0.33, 0.19), 0.8)
	var wood_dark := Look.plastic(Color(0.28, 0.18, 0.1), 0.85)
	var stone := Look.pbr("rock", 2.0, Color(0.8, 0.78, 0.74))
	var roof := Look.plastic(Color(0.22, 0.24, 0.2), 0.75)
	var trim := Look.plastic(Color(0.15, 0.32, 0.18), 0.6)   # vert « Office des forêts »
	var glass := Look.glass(Color(0.1, 0.13, 0.15))

	# --- chalet principal : 14 x 9 m
	var h := _group("RangerHouse", Vector3(c.x - 2.0, y, c.y - 7.0))
	_box(h, Vector3(14.4, 0.6, 9.4), Vector3(0, 0.3, 0), stone)
	_box(h, Vector3(14.0, 3.2, 9.0), Vector3(0, 2.2, 0), wood)
	for x in [-6.9, 6.9]:   # poteaux d'angle
		for z in [-4.4, 4.4]:
			_box(h, Vector3(0.3, 3.2, 0.3), Vector3(x, 2.2, z), wood_dark)
	var attic := PrismMesh.new()   # pignon : prisme sous le toit
	attic.size = Vector3(9.0, 3.1, 14.0)
	_part(h, attic, Vector3(0, 3.8 + 1.55, 0), wood, Vector3(0, PI * 0.5, 0))
	for side in [-1.0, 1.0]:   # deux pans débordants
		_box(h, Vector3(15.4, 0.18, 6.2), Vector3(0, 5.2, side * 2.62), roof, Vector3(side * 0.6, 0, 0))
	_box(h, Vector3(15.4, 0.3, 0.3), Vector3(0, 6.9, 0), wood_dark)   # faîtage
	_cyl(h, 0.35, 0.4, 1.4, Vector3(4.0, 6.6, -1.5), stone)           # cheminée
	# façade : porte, fenêtres à volets verts
	_box(h, Vector3(1.3, 2.3, 0.12), Vector3(-1.5, 1.75, 4.55), trim)
	_box(h, Vector3(0.1, 0.1, 0.1), Vector3(-1.0, 1.7, 4.65), Look.metal(Color(0.8, 0.7, 0.3)))
	for wx in [-5.0, 1.5, 4.8]:
		_window(h, Vector3(wx, 2.3, 4.55), 0.0, glass, wood_dark, trim)
	for wx in [-4.0, 0.0, 4.0]:
		_window(h, Vector3(wx, 2.3, -4.55), PI, glass, wood_dark, trim)
	for wz in [-2.0, 2.0]:
		_window(h, Vector3(-7.05, 2.3, wz), -PI * 0.5, glass, wood_dark, trim)
	# porche couvert devant la porte
	_box(h, Vector3(5.0, 0.25, 2.6), Vector3(-1.5, 0.5, 5.8), wood_dark)
	for px in [-3.8, 0.8]:
		_box(h, Vector3(0.2, 2.6, 0.2), Vector3(px, 1.9, 6.9), wood_dark)
	_box(h, Vector3(5.4, 0.15, 2.9), Vector3(-1.5, 3.35, 5.9), roof, Vector3(0.2, 0, 0))
	for k in 2:   # marches
		_box(h, Vector3(1.6, 0.18, 0.4), Vector3(-1.5, 0.09 + k * 0.18, 7.5 - k * 0.35), stone)
	# enseigne au-dessus du porche
	_box(h, Vector3(4.2, 0.6, 0.08), Vector3(-1.5, 3.9, 7.25), trim)
	_text(h, "GARDES FORESTIERS", Vector3(-1.5, 3.9, 7.3), 0.0, 40, Color(0.95, 0.9, 0.7))
	terrain.add_obstacle_box(Vector2(c.x - 2.0, c.y - 6.0), Vector2(15.4, 12.0), y + 7.5)

	# --- garage pour les véhicules
	var g := _group("RangerGarage", Vector3(c.x + 10.5, y, c.y - 7.5))
	_box(g, Vector3(7.0, 3.6, 8.0), Vector3(0, 1.8, 0), wood)
	_box(g, Vector3(7.6, 0.2, 8.6), Vector3(0, 3.75, 0), roof, Vector3(0.08, 0, 0))
	_box(g, Vector3(5.2, 2.8, 0.1), Vector3(0, 1.4, 4.02), Look.metal(Color(0.55, 0.57, 0.55), 0.5))
	for k in 6:   # rainures de la porte sectionnelle
		_box(g, Vector3(5.2, 0.04, 0.04), Vector3(0, 0.3 + k * 0.45, 4.08), Look.plastic(Color(0.3, 0.3, 0.3)))
	terrain.add_obstacle_box(Vector2(c.x + 10.5, c.y - 7.5), Vector2(7.6, 8.6), y + 4.0)

	# --- véhicules des gardes (4x4 vert) garés face au bâtiment
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.mesh = Models.car_mesh()
	mm.instance_count = 2
	for k in 2:
		var p := Vector3(c.x + 4.0 + k * 3.4, y, c.y + 5.0)
		mm.set_instance_transform(k, Transform3D(Basis.from_scale(Vector3(1.08, 1.18, 1.0)), p))
		mm.set_instance_color(k, Color(0.12, 0.3, 0.14))
	var cars := MultiMeshInstance3D.new()
	cars.name = "RangerVehicles"
	cars.multimesh = mm
	add_child(cars)
	for k in 4:   # marquage des places
		_box(self, Vector3(0.12, 0.02, 5.0), Vector3(c.x + 2.3 + k * 3.4, y + 0.03, c.y + 5.0), Look.plastic(Color(0.9, 0.9, 0.85)))

	# --- mât et drapeau
	var f := _group("Flag", Vector3(c.x - 15.0, y, c.y + 6.0))
	_cyl(f, 0.05, 0.08, 8.0, Vector3(0, 4.0, 0), Look.metal(Color(0.85, 0.85, 0.85)))
	_box(f, Vector3(1.6, 1.0, 0.03), Vector3(0.82, 7.3, 0), trim)
	_box(f, Vector3(0.5, 0.5, 0.035), Vector3(0.82, 7.3, 0), Look.plastic(Color(0.95, 0.85, 0.3)))

	# --- panneau d'accueil au bord de la piste
	var s := _group("WelcomeSign", Vector3(c.x - 12.0, y, c.y + 13.0))
	for sx in [-1.5, 1.5]:
		_box(s, Vector3(0.18, 2.2, 0.18), Vector3(sx, 1.1, 0), wood_dark)
	_box(s, Vector3(3.6, 1.2, 0.12), Vector3(0, 1.65, 0), wood)
	_box(s, Vector3(3.9, 0.12, 0.4), Vector3(0, 2.3, 0), roof)
	_text(s, "MAISON FORESTIÈRE", Vector3(0, 1.9, 0.07), 0.0, 32, Color(0.98, 0.95, 0.8))
	_text(s, "Office des gardes forestiers", Vector3(0, 1.45, 0.07), 0.0, 22, Color(0.9, 0.88, 0.75))

	# --- tas de bois de chauffage contre le pignon ouest
	var logs := _group("Woodpile", Vector3(c.x - 10.2, y, c.y - 7.0))
	for row in 3:
		for k in 6 - row:
			_cyl(logs, 0.17, 0.17, 1.0, Vector3(0, 0.18 + row * 0.3, -1.5 + k * 0.36 + row * 0.18), wood_dark,
				Vector3(0, 0, PI * 0.5), 8)

	var tag := Label3D.new()
	tag.text = "GARDES FORESTIERS"
	tag.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	tag.font_size = 56
	tag.outline_size = 10
	tag.pixel_size = 0.03
	tag.modulate = Color(0.6, 1.0, 0.6)
	tag.position = Vector3(c.x - 2.0, y + 12.0, c.y - 6.0)
	add_child(tag)


## Fenêtre : vitrage, encadrement et volets ouverts (tournée selon yaw, +z = extérieur).
func _window(parent: Node3D, pos: Vector3, yaw: float, glass: Material, frame: Material, shutter: Material) -> void:
	var w := Node3D.new()
	w.position = pos
	w.rotation.y = yaw
	parent.add_child(w)
	_box(w, Vector3(1.3, 1.1, 0.08), Vector3.ZERO, glass)
	_box(w, Vector3(1.5, 0.1, 0.14), Vector3(0, 0.6, 0.02), frame)
	_box(w, Vector3(1.6, 0.1, 0.25), Vector3(0, -0.6, 0.06), frame)
	_box(w, Vector3(0.06, 1.1, 0.1), Vector3(0, 0, 0.03), frame)
	for sx in [-1.0, 1.0]:
		_box(w, Vector3(0.65, 1.2, 0.06), Vector3(sx * 1.05, 0, 0.06), shutter)


func _group(node_name: String, pos: Vector3) -> Node3D:
	var g := Node3D.new()
	g.name = node_name
	g.position = pos
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


func _part(parent: Node3D, mesh: Mesh, pos: Vector3, mat: Material, rot: Vector3) -> void:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = mat
	mi.position = pos
	mi.rotation = rot
	parent.add_child(mi)


## Texte peint sur un panneau (non orienté vers la caméra).
func _text(parent: Node3D, txt: String, pos: Vector3, yaw: float, size: int, col: Color) -> void:
	var l := Label3D.new()
	l.text = txt
	l.font_size = size
	l.pixel_size = 0.01
	l.modulate = col
	l.outline_size = 0
	l.position = pos
	l.rotation.y = yaw
	parent.add_child(l)
