extends RefCounted
## Bibliothèque de matériaux réalistes (PBR) : charge les textures CC0 de assets/
## et fabrique les matériaux partagés par toute la scène (sol, routes, façades...).
## Utilisation : const Look := preload("res://scripts/render/look.gd") puis Look.xxx().
##
## Uniformes globaux (tous les shaders) : météo visible sur les surfaces.
##   wetness    0..1  surfaces mouillées (pluie) : plus sombres et brillantes, flaques
##   snow_cover 0..1  neige au sol et sur les toits

const TEX_DIR := "res://assets/textures/"

static var _tex := {}
static var _mats := {}
static var _globals_ready := false


## Texture d'un jeu PBR : kind = "diff" | "nor" | "arm" (R = occlusion, G = rugosité, B = métal).
static func tex(set_name: String, kind: String) -> Texture2D:
	var key := set_name + "/" + kind
	if not _tex.has(key):
		var path := TEX_DIR + set_name + "/" + kind + ".jpg"
		_tex[key] = load(path) if ResourceLoader.exists(path) else null
		if _tex[key] == null:
			push_warning("Texture manquante : %s (lancer tools/download_assets.py)" % path)
	return _tex[key]


static func has_assets() -> bool:
	return ResourceLoader.exists(TEX_DIR + "meadow/diff.jpg")


## Déclare les uniformes globaux AVANT la compilation des shaders qui les utilisent.
static func init_globals() -> void:
	# (global_shader_parameter_get_list() est réservée à l'éditeur : on mémorise nous-mêmes)
	for p in [["wetness", 0.0], ["snow_cover", 0.0]]:
		if not _globals_ready:
			RenderingServer.global_shader_parameter_add(p[0], RenderingServer.GLOBAL_VAR_TYPE_FLOAT, p[1])
		else:
			RenderingServer.global_shader_parameter_set(p[0], p[1])
	_globals_ready = true


static func set_weather(wet: float, snow: float) -> void:
	RenderingServer.global_shader_parameter_set("wetness", wet)
	RenderingServer.global_shader_parameter_set("snow_cover", snow)


## Matériau PBR standard projeté en coordonnées monde (triplanaire) : aucun UV nécessaire.
static func pbr(set_name: String, scale_m: float, tint := Color(1, 1, 1), use_vertex_color := false) -> StandardMaterial3D:
	var key := "pbr:%s:%.2f:%s:%s" % [set_name, scale_m, tint.to_html(), use_vertex_color]
	if _mats.has(key):
		return _mats[key]
	var m := StandardMaterial3D.new()
	m.albedo_color = tint
	m.albedo_texture = tex(set_name, "diff")
	m.normal_enabled = true
	m.normal_texture = tex(set_name, "nor")
	m.roughness_texture = tex(set_name, "arm")
	m.roughness_texture_channel = BaseMaterial3D.TEXTURE_CHANNEL_GREEN
	m.ao_enabled = true
	m.ao_texture = tex(set_name, "arm")
	m.ao_texture_channel = BaseMaterial3D.TEXTURE_CHANNEL_RED
	m.uv1_triplanar = true
	m.uv1_world_triplanar = true
	m.uv1_scale = Vector3.ONE / scale_m
	m.uv1_triplanar_sharpness = 4.0
	m.vertex_color_use_as_albedo = use_vertex_color
	m.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
	_mats[key] = m
	return m


## Peinture automobile / carrosserie : vernis brillant (clearcoat).
static func paint(c: Color, rough := 0.28, metal := 0.35) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.roughness = rough
	m.metallic = metal
	m.clearcoat_enabled = true
	m.clearcoat = 0.8
	m.clearcoat_roughness = 0.12
	return m


static func plastic(c: Color, rough := 0.55) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.roughness = rough
	return m


static func metal(c: Color, rough := 0.3) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.metallic = 1.0
	m.roughness = rough
	return m


static func glass(tint := Color(0.08, 0.1, 0.12)) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = tint
	m.metallic = 0.6
	m.roughness = 0.04
	return m


static func emissive(c: Color, energy: float) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.emission_enabled = true
	m.emission = c
	m.emission_energy_multiplier = energy
	return m


static func shader_material(code: String) -> ShaderMaterial:
	var sh := Shader.new()
	sh.code = code
	var m := ShaderMaterial.new()
	m.shader = sh
	return m
