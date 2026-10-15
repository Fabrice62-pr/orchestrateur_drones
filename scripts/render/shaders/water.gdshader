// Eau de lac : vagues animées (2 cartes de relief qui défilent), couleur selon la
// profondeur, transparence et réfraction près du bord, écume sur les berges,
// reflets du ciel (Fresnel) et gouttes de pluie.
shader_type spatial;
render_mode cull_back, specular_schlick_ggx;

global uniform float wetness;

uniform sampler2D wave_a : hint_normal, filter_linear_mipmap, repeat_enable;
uniform sampler2D wave_b : hint_normal, filter_linear_mipmap, repeat_enable;
uniform sampler2D screen_tex : hint_screen_texture, filter_linear_mipmap;
uniform sampler2D depth_tex : hint_depth_texture, filter_linear;
uniform vec3 shallow_color : source_color = vec3(0.16, 0.30, 0.28);
uniform vec3 deep_color : source_color = vec3(0.02, 0.07, 0.10);
uniform float clarity = 3.5;
uniform vec2 wind = vec2(1.0, 0.3);

varying vec3 wpos;

void vertex() {
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	vec2 p = wpos.xz;
	float speed = 0.02 + length(wind) * 0.004;
	vec3 n1 = texture(wave_a, p / 14.0 + wind * TIME * speed).rgb;
	vec3 n2 = texture(wave_b, p / 6.0 - wind.yx * TIME * speed * 1.7).rgb;
	vec3 n = normalize(mix(n1, n2, 0.5) * 2.0 - 1.0);
	// impacts de pluie : petites ondes
	float rain = wetness * (0.5 + 0.5 * sin(TIME * 9.0 + texture(wave_b, p * 0.9).r * 40.0));
	n.xy += (texture(wave_a, p * 0.8 + TIME * 0.3).rg - 0.5) * rain * 0.6;
	NORMAL_MAP = normalize(n) * 0.5 + 0.5;
	NORMAL_MAP_DEPTH = 0.7;

	// profondeur d'eau sous ce pixel
	float scene_depth = texture(depth_tex, SCREEN_UV).r;
	vec4 world = INV_VIEW_MATRIX * INV_PROJECTION_MATRIX * vec4(SCREEN_UV * 2.0 - 1.0, scene_depth, 1.0);
	world.xyz /= world.w;
	float water_depth = clamp(wpos.y - world.y, 0.0, 50.0);
	float t = 1.0 - exp(-water_depth / clarity);

	// réfraction : le fond est vu légèrement déformé
	vec2 ruv = SCREEN_UV + n.xy * 0.025 * (1.0 - t);
	vec3 refr = textureLod(screen_tex, ruv, 0.0).rgb;
	vec3 col = mix(refr * shallow_color * 2.2, deep_color, t);
	col = mix(col, shallow_color, 0.15 * (1.0 - t));

	// écume le long des berges
	float foam = (1.0 - smoothstep(0.0, 0.18, water_depth)) * 0.6;
	foam *= smoothstep(0.45, 0.7, texture(wave_b, p / 2.0 + TIME * 0.05).r + 0.2);

	ALBEDO = mix(col, vec3(0.85, 0.88, 0.9), foam * 0.8);
	ROUGHNESS = mix(0.03, 0.4, foam);
	METALLIC = 0.0;
	SPECULAR = 0.6;
}
