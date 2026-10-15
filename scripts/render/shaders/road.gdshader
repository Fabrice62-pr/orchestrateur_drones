// Chaussée : asphalte photo, marquage au sol (axe en tirets, lignes de rive,
// passages piétons « zébras » aux carrefours, lignes d'arrêt), usure, flaques sous la pluie.
// La grille des rues est régulière : origine + pas (bloc + rue).
shader_type spatial;

global uniform float wetness;
global uniform float snow_cover;

uniform sampler2D asp_d : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D asp_n : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D asp_a : filter_linear_mipmap_anisotropic, repeat_enable;
uniform vec2 grid_origin = vec2(-200.5, -170.5);   // centre de la première rue (x, z)
uniform float grid_step = 45.0;
uniform float road_width = 9.0;
uniform int axis = 0;                               // 0 : rue orientée selon X ; 1 : selon Z

varying vec3 wpos;

void vertex() {
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

float centered(float v, float origin) {
	return mod(v - origin + grid_step * 0.5, grid_step) - grid_step * 0.5;
}

void fragment() {
	vec2 p = wpos.xz;
	vec3 alb = texture(asp_d, p / 5.0).rgb * 0.8;
	vec3 nrm = texture(asp_n, p / 5.0).rgb;
	vec3 arm = texture(asp_a, p / 5.0).rgb;
	// usure : bandes de roulement plus claires et polies
	float along = axis == 0 ? p.x : p.y;
	float across = axis == 0 ? centered(p.y, grid_origin.y) : centered(p.x, grid_origin.x);
	float to_cross = abs(centered(along, axis == 0 ? grid_origin.x : grid_origin.y));   // distance au carrefour
	float hw = road_width * 0.5;
	float lanes = abs(abs(across) - 2.3);
	alb *= mix(1.0, 1.12, (1.0 - smoothstep(0.3, 0.9, abs(lanes - 0.9))) * 0.5);

	float paint = 0.0;
	bool in_crossing = to_cross < hw;
	if (!in_crossing) {
		// axe central en tirets (3 m peints, 6 m vides)
		float dash = step(fract(along / 9.0), 0.33);
		paint += (1.0 - smoothstep(0.07, 0.1, abs(across))) * dash * step(hw + 3.2, to_cross);
		// lignes de rive
		paint += 1.0 - smoothstep(0.06, 0.09, abs(abs(across) - (hw - 0.35)));
		// passage piéton : bandes de 0,5 m parallèles à la rue
		float zebra = step(hw + 0.4, to_cross) * step(to_cross, hw + 3.0);
		paint += zebra * step(0.5, fract(across / 1.0)) * step(abs(across), hw - 0.6);
		// ligne d'arrêt
		paint += (1.0 - smoothstep(0.15, 0.2, abs(to_cross - (hw + 3.5)))) * step(0.0, across) * step(abs(across), hw - 0.6);
	}
	paint = clamp(paint, 0.0, 1.0) * mix(0.75, 1.0, texture(asp_d, p / 1.3).r);   // peinture usée
	alb = mix(alb, vec3(0.82, 0.82, 0.78), paint);
	float rough = mix(arm.g, 0.55, paint);

	// pluie : asphalte sombre et miroitant, flaques dans les ornières
	float puddle = smoothstep(0.55, 0.62, texture(asp_a, p / 23.0).r + lanes * -0.1) * wetness;
	alb *= mix(1.0, 0.5, wetness);
	rough = mix(rough, 0.18, wetness);
	rough = mix(rough, 0.02, puddle);
	nrm = mix(nrm, vec3(0.5, 0.5, 1.0), max(puddle, wetness * 0.5));
	// neige : plus présente sur les bords que sur les traces de roues
	float snow = smoothstep(0.2, 0.8, snow_cover) * mix(0.6, 1.0, smoothstep(1.5, 3.5, lanes));
	alb = mix(alb, vec3(0.85, 0.87, 0.9), snow);

	ALBEDO = alb;
	NORMAL_MAP = nrm;
	ROUGHNESS = rough;
	AO = arm.r;
}
