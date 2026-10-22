extends Node3D
## Arbre abattu : copie visuelle d'un pin de la forêt (tronc + houppier) qui pivote
## autour de son pied pendant la chute, puis reste couché au sol.
## Utilisé par les bûcherons (coupe légale) et par les braconniers (coupe illégale).
##
## Le nœud est en coordonnées monde (top_level) : on l'ajoute d'abord à un parent,
## puis on appelle setup().

const Vegetation := preload("res://scripts/render/vegetation.gd")
const Look := preload("res://scripts/render/look.gd")
const LIFT := 0.15              # le pivot est légèrement au-dessus du sol

var base := Vector3.ZERO        # pied de l'arbre
var tree_s := 1.0               # échelle de l'arbre (1 = pin de 11,5 m)
var fall_dir := Vector2.RIGHT   # direction de chute (horizontale)
var trunk: Node3D
var foliage: Node3D

static var _bark: Material


static func bark_material() -> Material:
	if _bark == null:
		_bark = Look.pbr("bark", 1.2, Color(0.75, 0.65, 0.55))
	return _bark


## Copie l'arbre t de la forêt, prêt à tomber dans la direction dir.
func setup(forest: Node3D, t: int, dir: Vector2) -> void:
	top_level = true
	base = forest.tree_base[t]
	tree_s = forest.tree_scale(t)
	fall_dir = dir.normalized()
	global_position = base + Vector3(0, LIFT, 0)
	trunk = _single(forest.trunk_xforms[t], Vegetation.trunk_mesh(), Vegetation.trunk_material(), Color(0.8, 0.72, 0.62))
	foliage = _single(forest.foliage_xforms[t], Vegetation.conifer_mesh(), Vegetation.foliage_material(), forest.tree_colors[t])


## Axe horizontal autour duquel l'arbre bascule.
func axis() -> Vector3:
	return Vector3.UP.cross(Vector3(fall_dir.x, 0, fall_dir.y)).normalized()


## u = 0 : debout, u = 1 : couché (chute accélérée, arrêtée à 86° par les branches).
func set_fall(u: float) -> void:
	basis = Basis(axis(), pow(clampf(u, 0.0, 1.0), 2.0) * deg_to_rad(86.0))


## Point au sol le long du tronc couché, à la distance d du pied, décalé de lat sur le côté.
func along(d: float, lat: float) -> Vector3:
	var p := Vector2(base.x, base.z) + fall_dir * d + Vector2(-fall_dir.y, fall_dir.x) * lat
	return Vector3(p.x, 0.0, p.y)


## Grume posée au sol le long du tronc couché, de d0 à d1 m du pied.
func make_log(d0: float, d1: float, parent: Node) -> MeshInstance3D:
	var r := 0.2 * tree_s * (1.0 - 0.06 * d0 / maxf(tree_s, 0.1))
	var lg := log_mesh((d1 - d0) * 0.95, r)
	lg.top_level = true
	parent.add_child(lg)
	var c := along((d0 + d1) * 0.5, 0.0)
	lg.global_transform = Transform3D(Basis(axis(), PI * 0.5), Vector3(c.x, GameState.terrain.height_at(c.x, c.z) + r, c.z))
	return lg


## Grume (cylindre d'écorce) de longueur et rayon donnés, axe local Y.
static func log_mesh(length: float, r: float) -> MeshInstance3D:
	var cm := CylinderMesh.new()
	cm.top_radius = r * 0.92
	cm.bottom_radius = r
	cm.height = length
	cm.radial_segments = 10
	cm.rings = 1
	var mi := MeshInstance3D.new()
	mi.mesh = cm
	mi.material_override = bark_material()
	return mi


## Une instance MultiMesh (pour garder les couleurs d'instance des matériaux de la végétation).
func _single(xf: Transform3D, mesh: Mesh, mat: Material, col: Color) -> Node3D:
	var holder := Node3D.new()
	add_child(holder)
	holder.position = xf.origin - base - Vector3(0, LIFT, 0)
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.mesh = mesh
	mm.instance_count = 1
	mm.set_instance_transform(0, Transform3D(xf.basis, Vector3.ZERO))
	mm.set_instance_color(0, col)
	var mi := MultiMeshInstance3D.new()
	mi.multimesh = mm
	mi.material_override = mat
	holder.add_child(mi)
	return holder
