// Feuillage : aiguilles/feuilles texturées, balancement au vent, translucidité à
// contre-jour, neige sur les branches, et état du feu porté par la couleur d'instance :
//   orangé = en feu (rougeoie et scintille), quasi noir = calciné.
shader_type spatial;
render_mode cull_disabled, specular_schlick_ggx;

global uniform float snow_cover;
global uniform float wetness;

uniform sampler2D detail : filter_linear_mipmap, repeat_enable;
uniform vec2 wind = vec2(1.0, 0.0);
uniform float wind_strength = 0.5;

varying vec3 wnrm;
varying float height01;

void vertex() {
	vec3 wp = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	height01 = clamp(VERTEX.y + 0.5, 0.0, 1.0);
	// balancement : plus fort en haut, déphasé d'un arbre à l'autre
	float ph = wp.x * 0.11 + wp.z * 0.07 + MODEL_MATRIX[3].x * 0.37;
	float sway = sin(TIME * 1.3 + ph) * 0.7 + sin(TIME * 3.1 + ph * 2.3) * 0.3;
	VERTEX.xz += wind * sway * wind_strength * 0.05 * height01 * height01;
	wnrm = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
}

void fragment() {
	vec3 c = COLOR.rgb;
	float burning = clamp((c.r - c.g * 1.6) * 4.0, 0.0, 1.0);
	float n = texture(detail, UV).r;
	float n2 = texture(detail, UV * 3.7 + 0.31).r;
	vec3 alb = c * (0.55 + 0.9 * n * n2 * 1.6);
	// neige posée sur les branches orientées vers le ciel
	float snow = smoothstep(0.05, 0.45, wnrm.y) * smoothstep(0.05, 0.5, snow_cover * 1.3 - n * 0.35) * (1.0 - burning);
	alb = mix(alb, vec3(0.85, 0.88, 0.92), snow);
	alb *= mix(1.0, 0.75, wetness);
	alb = mix(alb, vec3(0.03, 0.02, 0.015), burning);   // branches carbonisées
	ALBEDO = alb;
	ROUGHNESS = mix(0.85, 0.5, wetness);
	SPECULAR = 0.25;
	BACKLIGHT = alb * 0.55 * (1.0 - snow) * (1.0 - burning);
	// flammes dans la couronne : lueur vacillante
	float flick = 0.6 + 0.4 * sin(TIME * 13.0 + n * 20.0) * sin(TIME * 7.3 + height01 * 9.0);
	// incandescence par plaques (les flammes elles-mêmes sont des billboards séparés)
	float glow = smoothstep(0.45, 0.75, n * n2 * 2.2 + (1.0 - height01) * 0.25);
	EMISSION = vec3(1.0, 0.28, 0.03) * burning * flick * glow * 2.2;
	AO = mix(0.45, 1.0, height01) * COLOR.a;
	AO_LIGHT_AFFECT = 0.6;
}
