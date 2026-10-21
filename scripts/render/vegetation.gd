extends RefCounted
## Modèles de végétation générés par code (sans fichier externe) :
##  - conifère : étages de branches retombantes à bords irréguliers
##  - feuillu : houppier de plusieurs masses de feuillage bosselées
## Les maillages sont normalisés (y de -0.5 à 0.5, rayon 1) : la taille réelle est
## donnée par la transformation de chaque instance (MultiMesh).

const Look := preload("res://scripts/render/look.gd")
const FOLIAGE_SHADER := preload("res://scripts/render/shaders/foliage.gdshader")

static var _conifer: ArrayMesh
static var _broadleaf: ArrayMesh
static var _palm: ArrayMesh
static var _trunk: Mesh
static var _foliage_mat: ShaderMaterial


static func conifer_mesh() -> ArrayMesh:
	if _conifer:
		return _conifer
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var tiers := 8
	var seg := 14
	var rng := RandomNumberGenerator.new()
	rng.seed = 4242
	for t in tiers:
		var f := float(t) / float(tiers - 1)          # 0 en haut, 1 en bas
		var apex_y := lerpf(0.5, -0.28, f)
		var radius := lerpf(0.22, 1.0, pow(f, 0.85))
		var drop := lerpf(0.16, 0.24, f)
		var ring_y := apex_y - drop
		var ring: Array = []
		for k in seg + 1:
			var a := TAU * float(k % seg) / seg + t * 0.37
			var jag := 1.0 if k % 2 == 0 else rng.randf_range(0.62, 0.8)   # bouts de branches
			var r := radius * jag * rng.randf_range(0.9, 1.08)
			var tip_drop := (1.0 - jag) * -0.05 + (jag - 0.7) * 0.06       # les pointes retombent
			ring.append(Vector3(cos(a) * r, ring_y - tip_drop, sin(a) * r))
		var apex := Vector3(0, apex_y, 0)
		var under := Vector3(0, ring_y + drop * 0.35, 0)
		for k in seg:
			var a: Vector3 = ring[k]
			var b: Vector3 = ring[k + 1]
			var u0 := float(k) / seg * 4.0
			var u1 := float(k + 1) / seg * 4.0
			# dessus de l'étage (normales arrondies vers l'extérieur/le haut)
			_v(st, apex, Vector3(0, 1, 0), Vector2((u0 + u1) * 0.5, 0.0), 0.85)
			_v(st, b, (Vector3(b.x, 0, b.z).normalized() + Vector3.UP * 0.7).normalized(), Vector2(u1, 1.2), 1.0)
			_v(st, a, (Vector3(a.x, 0, a.z).normalized() + Vector3.UP * 0.7).normalized(), Vector2(u0, 1.2), 1.0)
			# dessous (ombragé)
			_v(st, under, Vector3.DOWN, Vector2((u0 + u1) * 0.5, 0.0), 0.35)
			_v(st, a, (Vector3(a.x, 0, a.z).normalized() - Vector3.UP * 0.4).normalized(), Vector2(u0, 1.2), 0.55)
			_v(st, b, (Vector3(b.x, 0, b.z).normalized() - Vector3.UP * 0.4).normalized(), Vector2(u1, 1.2), 0.55)
	_conifer = st.commit()
	return _conifer


static func broadleaf_mesh() -> ArrayMesh:
	if _broadleaf:
		return _broadleaf
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var rng := RandomNumberGenerator.new()
	rng.seed = 777
	var noise := FastNoiseLite.new()
	noise.frequency = 3.0
	var blobs := [[Vector3(0, 0.05, 0), 0.62], [Vector3(0.38, -0.08, 0.1), 0.45], [Vector3(-0.35, -0.05, -0.15), 0.47],
		[Vector3(0.05, 0.22, 0.32), 0.4], [Vector3(-0.1, 0.2, -0.33), 0.42], [Vector3(0.15, -0.25, -0.2), 0.38]]
	for bl in blobs:
		var c: Vector3 = bl[0]
		var r: float = bl[1]
		var sm := SphereMesh.new()
		sm.radius = 1.0
		sm.height = 2.0
		sm.radial_segments = 12
		sm.rings = 7
		var arr := sm.get_mesh_arrays()
		var verts: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
		var idx: PackedInt32Array = arr[Mesh.ARRAY_INDEX]
		for i in idx:
			var v: Vector3 = verts[i]
			var bump := 1.0 + noise.get_noise_3dv(v + c * 3.0) * 0.28
			var p := c + v * r * bump
			var shade := clampf(0.45 + (v.y * 0.5 + 0.5) * 0.6, 0.0, 1.0)
			_v(st, p, v.normalized(), Vector2(atan2(v.z, v.x) * 2.0, v.y * 2.0), shade)
	_broadleaf = st.commit()
	return _broadleaf


## Couronne de palmier (palmier dattier / washingtonia des boulevards) : palmes
## arquées qui retombent, normalisée (y de -0.5 à 0.5, rayon 1). Le stipe est un
## tronc (trunk_mesh) étiré séparément.
static func palm_crown_mesh() -> ArrayMesh:
	if _palm:
		return _palm
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var rng := RandomNumberGenerator.new()
	rng.seed = 909
	var fronds := 11
	var segs := 6
	for f in fronds:
		var a := TAU * f / fronds + rng.randf_range(-0.15, 0.15)
		var dir := Vector3(cos(a), 0, sin(a))
		var side := Vector3(-dir.z, 0, dir.x)
		var lift := rng.randf_range(-0.15, 0.15)
		var prev_c := Vector3.ZERO
		var prev_w := 0.0
		for s in segs + 1:
			var t := float(s) / segs
			# palme : monte puis retombe en arc
			var c := dir * t + Vector3(0, 0.3 + (0.55 + lift) * t - (1.25 + lift) * t * t, 0)
			var w := 0.2 * sin(PI * minf(t * 1.15, 1.0)) + 0.015
			if s > 0:
				var droop := Vector3(0, -0.08, 0)   # folioles inclinées : section en V
				for sd: float in [-1.0, 1.0]:
					var a0 := prev_c
					var b0 := c
					var a1: Vector3 = prev_c + side * sd * prev_w + droop * prev_w * 4.0
					var b1: Vector3 = c + side * sd * w + droop * w * 4.0
					var nrm := Vector3.UP
					var sh := lerpf(0.55, 1.0, t)
					_v(st, a0, nrm, Vector2(t - 1.0 / segs, 0.5), sh)
					_v(st, b0, nrm, Vector2(t, 0.5), sh)
					_v(st, b1, nrm, Vector2(t, 0.5 + sd * 0.5), sh)
					_v(st, a0, nrm, Vector2(t - 1.0 / segs, 0.5), sh)
					_v(st, b1, nrm, Vector2(t, 0.5 + sd * 0.5), sh)
					_v(st, a1, nrm, Vector2(t - 1.0 / segs, 0.5 + sd * 0.5), sh)
			prev_c = c
			prev_w = w
	_palm = st.commit()
	return _palm


static func _v(st: SurfaceTool, p: Vector3, n: Vector3, uv: Vector2, shade: float) -> void:
	st.set_normal(n)
	st.set_uv(uv)
	st.set_color(Color(1, 1, 1, shade))   # alpha = occlusion propre au maillage
	st.add_vertex(p)


static func trunk_mesh() -> Mesh:
	if _trunk:
		return _trunk
	var cm := CylinderMesh.new()
	cm.top_radius = 0.08
	cm.bottom_radius = 0.26
	cm.height = 1.0
	cm.radial_segments = 8
	cm.rings = 2
	_trunk = cm
	return _trunk


static func trunk_material() -> Material:
	return Look.pbr("bark", 1.2, Color(0.85, 0.8, 0.75), true)


static func foliage_material() -> ShaderMaterial:
	if _foliage_mat:
		return _foliage_mat
	_foliage_mat = ShaderMaterial.new()
	_foliage_mat.shader = FOLIAGE_SHADER
	var nt := NoiseTexture2D.new()
	nt.width = 256
	nt.height = 256
	nt.seamless = true
	var fn := FastNoiseLite.new()
	fn.noise_type = FastNoiseLite.TYPE_CELLULAR
	fn.frequency = 0.09
	fn.fractal_octaves = 2
	nt.noise = fn
	_foliage_mat.set_shader_parameter("detail", nt)
	return _foliage_mat


## Couleur réaliste d'aiguilles de pin (albédo sombre, légèrement varié).
static func needle_color(rng: RandomNumberGenerator) -> Color:
	return Color(0.07, 0.115, 0.05).lerp(Color(0.12, 0.165, 0.07), rng.randf())


static func leaf_color(rng: RandomNumberGenerator) -> Color:
	return Color(0.07, 0.13, 0.04).lerp(Color(0.16, 0.2, 0.06), rng.randf())
