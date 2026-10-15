extends Node3D
## Atmosphère réaliste : ciel photographique HDRI (qui éclaire aussi la scène),
## soleil placé à l'endroit exact du soleil de la photo, illumination globale (SDFGI),
## occlusion ambiante, réflexions, perspective aérienne et brouillard volumétrique.
##
## Gère aussi les transitions météo visibles : ciel couvert sous la pluie/neige,
## surfaces qui se mouillent puis sèchent, neige qui s'accumule puis fond.

const Look := preload("res://scripts/render/look.gd")
const SKY_PATH := "res://assets/sky/sky.hdr"

const SKY_SHADER := """
shader_type sky;
// ciel HDRI équirectangulaire (données linéaires HDR)
uniform sampler2D hdri : filter_linear, repeat_enable;
uniform float energy = 1.0;
uniform float overcast = 0.0;
uniform vec3 overcast_color = vec3(0.52, 0.55, 0.6);
uniform float has_hdri = 1.0;

void sky() {
	vec3 d = EYEDIR;
	vec2 uv = vec2(atan(d.x, -d.z) / (2.0 * PI) + 0.5, acos(clamp(d.y, -1.0, 1.0)) / PI);
	vec3 c = texture(hdri, uv).rgb;
	if (has_hdri < 0.5) {
		c = mix(vec3(0.75, 0.82, 0.9), vec3(0.25, 0.45, 0.8), clamp(d.y * 1.5, 0.0, 1.0));
	}
	// sous l'horizon (ciel « pur » sans sol) : brume de la couleur de l'horizon
	vec3 haze = has_hdri > 0.5 ? texture(hdri, vec2(uv.x, 0.49)).rgb : vec3(0.7, 0.75, 0.8);
	c = mix(c, haze * 0.75, smoothstep(0.0, -0.06, d.y));
	// ciel couvert : nuages gris uniformes, plus clairs au zénith
	vec3 ov = overcast_color * (0.55 + 0.45 * clamp(d.y * 1.6 + 0.2, 0.0, 1.0));
	c = mix(c, ov, overcast);
	COLOR = c * energy;
}
"""

var env: Environment
var sun: DirectionalLight3D
var sky_mat: ShaderMaterial
var sun_energy := 2.6
var overcast := 0.0
var wet := 0.0
var snow := 0.0


func setup() -> void:
	Look.init_globals()
	env = Environment.new()
	env.background_mode = Environment.BG_SKY
	var sky := Sky.new()
	sky_mat = Look.shader_material(SKY_SHADER)
	var hdri: Texture2D = load(SKY_PATH) if ResourceLoader.exists(SKY_PATH) else null
	sky_mat.set_shader_parameter("hdri", hdri)
	sky_mat.set_shader_parameter("has_hdri", 1.0 if hdri else 0.0)
	sky.sky_material = sky_mat
	sky.radiance_size = Sky.RADIANCE_SIZE_256
	env.sky = sky
	# lumière ambiante et reflets issus du ciel
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.reflected_light_source = Environment.REFLECTION_SOURCE_SKY
	env.ambient_light_energy = 1.0
	# rendu « caméra » : tonemapping AgX (couleurs naturelles, hautes lumières douces)
	env.tonemap_mode = Environment.TONE_MAPPER_AGX
	env.tonemap_exposure = 1.0
	# illumination globale : la lumière rebondit sur le sol, les façades, la forêt
	env.sdfgi_enabled = true
	env.sdfgi_use_occlusion = true
	env.sdfgi_cascades = 6
	env.sdfgi_min_cell_size = 0.4
	env.sdfgi_energy = 1.0
	env.ssao_enabled = true
	env.ssao_radius = 1.4
	env.ssao_intensity = 1.8
	env.ssil_enabled = true
	env.ssr_enabled = true
	env.ssr_max_steps = 48
	env.glow_enabled = true
	env.glow_intensity = 0.35
	env.glow_hdr_threshold = 1.4
	env.glow_bloom = 0.03
	# perspective aérienne : le lointain se fond dans la couleur du ciel
	env.fog_enabled = true
	env.fog_mode = Environment.FOG_MODE_EXPONENTIAL
	env.fog_density = 0.00032
	env.fog_aerial_perspective = 0.85
	env.fog_sky_affect = 0.0
	env.fog_light_color = Color(0.72, 0.78, 0.86)
	# brouillard volumétrique léger : rayons de soleil, fumées éclairées
	env.volumetric_fog_enabled = true
	env.volumetric_fog_density = 0.0003
	env.volumetric_fog_albedo = Color(0.9, 0.92, 0.95)
	env.volumetric_fog_anisotropy = 0.55
	env.volumetric_fog_length = 260.0
	env.volumetric_fog_detail_spread = 2.0
	env.volumetric_fog_sky_affect = 0.0
	env.adjustment_enabled = true
	env.adjustment_saturation = 1.06
	env.adjustment_contrast = 1.04
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)

	sun = DirectionalLight3D.new()
	sun.name = "Sun"
	sun.light_energy = sun_energy
	sun.light_color = Color(1.0, 0.96, 0.9)
	sun.shadow_enabled = true
	sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS
	sun.directional_shadow_max_distance = 650.0
	sun.directional_shadow_blend_splits = true
	sun.light_angular_distance = 0.4   # ombres à pénombre douce, comme le vrai soleil
	sun.shadow_bias = 0.03
	sun.light_volumetric_fog_energy = 1.2
	add_child(sun)
	_place_sun(hdri)


## Le soleil est placé là où se trouve le soleil de la photo du ciel (direction
## calculée une fois par tools/compute_sun.gd -> assets/sky/sun.json) :
## ombres et reflets cohérents avec le ciel visible.
func _place_sun(_hdri: Texture2D) -> void:
	var dir := Vector3(0.37, 0.75, -0.55).normalized()
	if FileAccess.file_exists("res://assets/sky/sun.json"):
		var d = JSON.parse_string(FileAccess.get_file_as_string("res://assets/sky/sun.json"))
		if typeof(d) == TYPE_DICTIONARY and typeof(d.get("direction")) == TYPE_ARRAY:
			var a: Array = d["direction"]
			dir = Vector3(float(a[0]), float(a[1]), float(a[2])).normalized()
	# le soleil ne doit pas être trop rasant (ombres démesurées) ni au zénith
	var elev := clampf(asin(dir.y), deg_to_rad(28.0), deg_to_rad(62.0))
	var flat := Vector3(dir.x, 0.0, dir.z).normalized()
	dir = (flat * cos(elev) + Vector3.UP * sin(elev)).normalized()
	sun.global_transform.basis = Basis.looking_at(-dir, Vector3.UP if absf(dir.y) < 0.99 else Vector3.FORWARD)


func _process(delta: float) -> void:
	var dt := clampf(delta, 0.0, 0.5)
	var precip := GameState.raining or GameState.snowing
	overcast = move_toward(overcast, 1.0 if precip else 0.0, dt / 10.0)
	# les surfaces se mouillent en ~30 s de pluie, sèchent en ~3 min
	wet = move_toward(wet, 1.0 if GameState.raining else 0.0, dt / (30.0 if GameState.raining else 180.0))
	# la neige tient en ~1 min, fond en ~4 min (plus vite sous la pluie)
	if GameState.snowing:
		snow = move_toward(snow, 1.0, dt / 60.0)
	else:
		snow = move_toward(snow, 0.0, dt / (60.0 if GameState.raining else 240.0))
	Look.set_weather(wet, snow)
	sky_mat.set_shader_parameter("overcast", overcast)
	sky_mat.set_shader_parameter("energy", lerpf(1.0, 0.55, overcast))
	sun.light_energy = sun_energy * lerpf(1.0, 0.12, overcast)
	env.fog_density = lerpf(0.00032, 0.0028, overcast)
	env.volumetric_fog_density = lerpf(0.0003, 0.006, overcast)
