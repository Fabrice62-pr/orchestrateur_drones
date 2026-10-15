extends RefCounted
## Modèles 3D générés par code : voiture (berline) et pièces de personnage.
## Les modèles regardent vers -Z (l'avant) ; le sol est à y = 0.

const Look := preload("res://scripts/render/look.gd")

static var _car: ArrayMesh
static var _limb: Mesh
static var _torso: Mesh
static var _head: Mesh
static var _hair: Mesh


## Berline de 4,4 m : surfaces = carrosserie (couleur d'instance), vitrage, pneus,
## pare-chocs/plastiques, phares, feux arrière.
static func car_mesh() -> ArrayMesh:
	if _car:
		return _car
	var mesh := ArrayMesh.new()
	# profil latéral (z le long de la voiture, avant en -z ; y hauteur)
	var body := PackedVector2Array([Vector2(-2.2, 0.3), Vector2(-2.24, 0.62), Vector2(-2.08, 0.8), Vector2(-0.95, 0.93),
		Vector2(1.4, 0.97), Vector2(2.16, 0.88), Vector2(2.22, 0.36), Vector2(1.8, 0.28), Vector2(-1.8, 0.28)])
	var cabin := PackedVector2Array([Vector2(-0.95, 0.92), Vector2(-0.22, 1.4), Vector2(0.9, 1.42), Vector2(1.42, 0.96)])
	_add_surface(mesh, _extrude(body, -0.9, 0.9, 0.06), Look.paint(Color(1, 1, 1), 0.3, 0.45), true)
	_add_surface(mesh, _extrude(cabin, -0.78, 0.78, 0.1), Look.glass(Color(0.05, 0.06, 0.07)))
	# toit peint (fine couche au-dessus du vitrage)
	var roof := PackedVector2Array([Vector2(-0.18, 1.4), Vector2(-0.12, 1.445), Vector2(0.85, 1.46), Vector2(0.9, 1.42)])
	_add_surface(mesh, _extrude(roof, -0.74, 0.74, 0.0), Look.paint(Color(1, 1, 1), 0.3, 0.45), true)
	# roues
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for z in [-1.38, 1.36]:
		for x in [-0.82, 0.82]:
			_cylinder_x(st, Vector3(x, 0.33, z), 0.33, 0.24)
	_add_surface(mesh, st, Look.plastic(Color(0.03, 0.03, 0.03), 0.85))
	# pare-chocs et bas de caisse (plastique sombre)
	var trim := SurfaceTool.new()
	trim.begin(Mesh.PRIMITIVE_TRIANGLES)
	_box(trim, Vector3(0, 0.42, -2.2), Vector3(1.86, 0.2, 0.12))
	_box(trim, Vector3(0, 0.42, 2.21), Vector3(1.86, 0.2, 0.12))
	_box(trim, Vector3(-0.92, 0.36, 0), Vector3(0.05, 0.1, 2.6))
	_box(trim, Vector3(0.92, 0.36, 0), Vector3(0.05, 0.1, 2.6))
	_add_surface(mesh, trim, Look.plastic(Color(0.06, 0.06, 0.065), 0.6))
	# phares (blancs) et feux (rouges)
	var heads := SurfaceTool.new()
	heads.begin(Mesh.PRIMITIVE_TRIANGLES)
	for x in [-0.62, 0.62]:
		_box(heads, Vector3(x, 0.72, -2.19), Vector3(0.38, 0.1, 0.06))
	_add_surface(mesh, heads, Look.emissive(Color(1.0, 0.97, 0.9), 2.5))
	var tails := SurfaceTool.new()
	tails.begin(Mesh.PRIMITIVE_TRIANGLES)
	for x in [-0.66, 0.66]:
		_box(tails, Vector3(x, 0.78, 2.19), Vector3(0.36, 0.1, 0.06))
	_add_surface(mesh, tails, Look.emissive(Color(0.9, 0.05, 0.03), 1.6))
	_car = mesh
	return mesh


## Profil 2D (z, y) extrudé sur la largeur x0..x1, avec un léger chanfrein sur les arêtes.
static func _extrude(profile: PackedVector2Array, x0: float, x1: float, bevel: float) -> SurfaceTool:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var n := profile.size()
	var tri := Geometry2D.triangulate_polygon(profile)
	if tri.is_empty():
		var rev := profile.duplicate()
		rev.reverse()
		profile = rev
		tri = Geometry2D.triangulate_polygon(profile)
	var c := Vector2.ZERO
	for q in profile:
		c += q
	c /= n
	# flancs (légèrement rentrés en haut : carrosserie galbée)
	for side in [-1, 1]:
		var x := x0 if side < 0 else x1
		for k in range(0, tri.size(), 3):
			var ids := [tri[k], tri[k + 1], tri[k + 2]]
			if side > 0:
				ids.reverse()
			for id in ids:
				var q: Vector2 = profile[id]
				var inset := bevel * clampf((q.y - c.y) * 2.0, 0.0, 1.0)
				st.set_normal(Vector3(side, 0, 0))
				st.add_vertex(Vector3(x - side * inset, q.y, q.x))
	# pourtour
	for k in n:
		var a: Vector2 = profile[k]
		var b: Vector2 = profile[(k + 1) % n]
		var e := b - a
		var nrm := Vector3(0, -e.x, e.y).normalized()
		if nrm.dot(Vector3(0, a.y - c.y, a.x - c.x)) < 0.0:
			nrm = -nrm
		var ia := bevel * clampf((a.y - c.y) * 2.0, 0.0, 1.0)
		var ib := bevel * clampf((b.y - c.y) * 2.0, 0.0, 1.0)
		var quad := [Vector3(x0 + ia, a.y, a.x), Vector3(x1 - ia, a.y, a.x), Vector3(x1 - ib, b.y, b.x), Vector3(x0 + ib, b.y, b.x)]
		for i in [0, 1, 2, 0, 2, 3]:
			st.set_normal(nrm)
			st.add_vertex(quad[i])
	return st


static func _box(st: SurfaceTool, center: Vector3, size: Vector3) -> void:
	var bm := BoxMesh.new()
	bm.size = size
	_append(st, bm, Transform3D(Basis(), center))


static func _cylinder_x(st: SurfaceTool, center: Vector3, r: float, w: float) -> void:
	var cm := CylinderMesh.new()
	cm.top_radius = r
	cm.bottom_radius = r
	cm.height = w
	cm.radial_segments = 14
	cm.rings = 1
	_append(st, cm, Transform3D(Basis(Vector3.FORWARD, PI * 0.5), center))


static func _append(st: SurfaceTool, m: PrimitiveMesh, xf: Transform3D) -> void:
	var arr := m.get_mesh_arrays()
	var verts: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
	var norms: PackedVector3Array = arr[Mesh.ARRAY_NORMAL]
	var idx: PackedInt32Array = arr[Mesh.ARRAY_INDEX]
	for i in idx:
		st.set_normal((xf.basis * norms[i]).normalized())
		st.add_vertex(xf * verts[i])


static func _add_surface(mesh: ArrayMesh, st: SurfaceTool, mat: Material, painted := false) -> void:
	var arrays := st.commit_to_arrays()
	(mat as BaseMaterial3D).cull_mode = BaseMaterial3D.CULL_DISABLED
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	if painted:
		(mat as StandardMaterial3D).vertex_color_use_as_albedo = true   # teinte = couleur d'instance
	mesh.surface_set_material(mesh.get_surface_count() - 1, mat)


# ------------------------------------------------------------ personnages
# Pièces normalisées : le pivot d'un membre est en haut (articulation).

static func limb_mesh() -> Mesh:
	if _limb == null:
		var c := CapsuleMesh.new()
		c.radius = 0.5
		c.height = 2.0
		c.radial_segments = 8
		c.rings = 3
		var st := SurfaceTool.new()
		st.begin(Mesh.PRIMITIVE_TRIANGLES)
		_append(st, c, Transform3D(Basis(), Vector3(0, -1.0, 0)))   # de 0 (articulation) à -2
		_limb = st.commit()
	return _limb


static func torso_mesh() -> Mesh:
	if _torso == null:
		var c := CapsuleMesh.new()
		c.radius = 0.5
		c.height = 1.6
		c.radial_segments = 10
		c.rings = 4
		_torso = c
	return _torso


static func head_mesh() -> Mesh:
	if _head == null:
		var s := SphereMesh.new()
		s.radius = 0.5
		s.height = 1.15
		s.radial_segments = 12
		s.rings = 6
		_head = s
	return _head


static func hair_mesh() -> Mesh:
	if _hair == null:
		var s := SphereMesh.new()
		s.radius = 0.53
		s.height = 0.6
		s.is_hemisphere = true
		s.radial_segments = 12
		s.rings = 4
		_hair = s
	return _hair
