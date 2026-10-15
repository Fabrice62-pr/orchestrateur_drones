// Sol réaliste : textures photo (CC0) mélangées selon la zone, la pente et la hauteur.
// prairie / sol forestier / roche (pentes) / sable (berges) / béton (ville, base)
// + sol calciné là où le feu est passé (carte de brûlure mise à jour en direct)
// + météo : sol mouillé (sombre, brillant, flaques) et neige sur les surfaces planes.
shader_type spatial;
render_mode cull_disabled;

global uniform float wetness;
global uniform float snow_cover;

uniform sampler2D meadow_d : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D meadow_n : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D meadow_a : filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D forest_d : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D forest_n : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D forest_a : filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D rock_d : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D rock_n : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D rock_a : filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D sand_d : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D sand_n : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D sand_a : filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D burnt_d : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D burnt_n : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D burnt_a : filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D conc_d : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D conc_n : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D conc_a : filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D burn_map : filter_linear, repeat_disable;
uniform sampler2D macro_noise : filter_linear_mipmap, repeat_enable;

uniform vec4 forest_rect = vec4(48.0, -140.0, 157.0, 300.0);
uniform vec4 city_rect = vec4(-205.0, -175.0, 215.0, 350.0);
uniform vec4 base_rect = vec4(9.0, -26.0, 34.0, 52.0);
uniform vec4 burn_rect = vec4(48.0, -140.0, 155.0, 300.0);
uniform vec2 lake_center = vec2(122.0, -168.0);
uniform float lake_radius = 36.0;
uniform float water_level = -2.0;

varying vec3 wpos;
varying vec3 wnrm;

void vertex() {
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	wnrm = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
	// projection plane en X/Z : repère tangent cohérent avec les UV monde
	TANGENT = normalize(cross(NORMAL, vec3(0.0, 0.0, 1.0)));
	BINORMAL = normalize(cross(TANGENT, NORMAL));
}

float rect_mask(vec2 p, vec4 r, float soft) {
	vec2 d = max(max(r.xy - p, p - (r.xy + r.zw)), vec2(0.0));
	return 1.0 - clamp(length(d) / soft, 0.0, 1.0);
}

void layer(inout vec3 alb, inout vec3 nrm, inout vec3 arm, float w,
		sampler2D d, sampler2D n, sampler2D a, vec2 uv) {
	if (w <= 0.001) return;
	alb = mix(alb, texture(d, uv).rgb, w);
	nrm = mix(nrm, texture(n, uv).rgb, w);
	arm = mix(arm, texture(a, uv).rgb, w);
}

void fragment() {
	vec2 p = wpos.xz;
	// bruit « macro » pris dans la texture de prairie à très grande échelle : casse la répétition
	float macro = texture(macro_noise, p / 900.0).r;
	float macro2 = texture(macro_noise, p / 230.0 + 0.37).r;

	// prairie : deux échelles mélangées
	vec2 uvm = p / 26.0;
	vec3 alb = mix(texture(meadow_d, uvm).rgb, texture(meadow_d, p / 9.0 + 0.5).rgb, 0.35);
	vec3 nrm = texture(meadow_n, uvm).rgb;
	vec3 arm = texture(meadow_a, uvm).rgb;
	alb *= mix(0.85, 1.1, macro2);
	// herbe plus verte (le JPEG photo est pris en fin d'été)
	float lum = dot(alb, vec3(0.299, 0.587, 0.114));
	alb = mix(vec3(lum), alb, 1.15) * vec3(0.74, 0.95, 0.6);
	// zones plus sèches / plus vertes à grande échelle
	alb = mix(alb, alb * vec3(1.08, 1.0, 0.82), smoothstep(0.35, 0.75, macro) * 0.5);

	// carte de la forêt : R = brûlé, G = en feu, B = densité de végétation
	vec2 buv = (p - burn_rect.xy) / burn_rect.zw;
	vec3 fmap = vec3(0.0);
	if (buv.x > 0.0 && buv.y > 0.0 && buv.x < 1.0 && buv.y < 1.0) {
		fmap = texture(burn_map, buv).rgb;
	}
	// sol forestier : suit exactement la densité des arbres (lisière naturelle)
	float forest = smoothstep(0.12, 0.42, fmap.b + (macro2 - 0.5) * 0.15);
	layer(alb, nrm, arm, forest, forest_d, forest_n, forest_a, p / 5.5);

	// au-delà de la carte : massifs forestiers et prairies vus de loin
	float far = smoothstep(640.0, 760.0, max(abs(p.x), abs(p.y)));
	float woods = far * smoothstep(0.5, 0.56, macro + (macro2 - 0.5) * 0.35);
	vec3 canopy = vec3(0.045, 0.075, 0.035) * mix(0.7, 1.3, texture(forest_d, p / 40.0).g * 2.0);
	alb = mix(alb, canopy, woods);
	arm.g = mix(arm.g, 0.9, woods);

	// roche sur les pentes
	float slope = 1.0 - clamp(wnrm.y, 0.0, 1.0);
	float rock = smoothstep(0.16, 0.32, slope + (macro2 - 0.5) * 0.12);
	layer(alb, nrm, arm, rock, rock_d, rock_n, rock_a, p / 14.0);

	// berges sableuses du lac
	float dl = distance(p, lake_center);
	float shore = (1.0 - smoothstep(lake_radius * 1.55, lake_radius * 1.95, dl)) * (1.0 - smoothstep(water_level + 1.0, water_level + 3.0, wpos.y));
	layer(alb, nrm, arm, shore, sand_d, sand_n, sand_a, p / 7.0);

	// ville et base : sol bétonné
	float urban = max(rect_mask(p, city_rect, 8.0), rect_mask(p, base_rect, 3.0));
	layer(alb, nrm, arm, urban, conc_d, conc_n, conc_a, p / 6.0);
	alb = mix(alb, alb * vec3(0.82, 0.84, 0.86), urban);   // béton urbain gris

	// sol calciné : là où le feu est passé (R) ou brûle (G)
	vec2 burn = fmap.rg;
	float burnt = smoothstep(0.15, 0.55, burn.r + (macro2 - 0.5) * 0.4);
	layer(alb, nrm, arm, burnt, burnt_d, burnt_n, burnt_a, p / 6.0);
	// braises : lueur orangée sous les foyers actifs
	// braises : plaques irrégulières (bruit fin) et non la grille de 5 m de la simulation
	float ember_n = texture(macro_noise, p / 5.0).r * texture(macro_noise, p / 1.7 + 0.21).r * 2.0;
	float embers = smoothstep(0.35, 0.8, burn.g) * smoothstep(0.45, 0.75, ember_n);
	vec3 glow = vec3(1.0, 0.3, 0.04) * embers * (0.6 + 0.4 * sin(TIME * 6.0 + ember_n * 30.0)) * 1.6;

	// pluie : sol plus sombre et brillant, flaques dans les creux
	float porous = 1.0 - urban * 0.5;
	alb *= mix(1.0, 0.62, wetness * porous);
	float puddle = smoothstep(0.62, 0.7, macro + (1.0 - wnrm.y) * -3.0) * wetness * (urban * 0.8 + 0.2);
	float rough = arm.g * mix(1.0, 0.45, wetness);
	rough = mix(rough, 0.04, puddle);
	alb = mix(alb, alb * 0.5, puddle);
	nrm = mix(nrm, vec3(0.5, 0.5, 1.0), puddle);

	// neige : tient sur les surfaces planes, en plaques irrégulières au début
	float snow = smoothstep(0.55, 0.85, wnrm.y) * smoothstep(0.0, 0.35, snow_cover * 1.3 - (1.0 - macro) * 0.35);
	alb = mix(alb, vec3(0.92, 0.94, 0.97), snow);
	rough = mix(rough, 0.65, snow);
	nrm = mix(nrm, vec3(0.5, 0.5, 1.0), snow * 0.8);

	ALBEDO = alb;
	NORMAL_MAP = nrm;
	ROUGHNESS = rough;
	AO = arm.r;
	AO_LIGHT_AFFECT = 0.4;
	EMISSION = glow * (1.0 - snow);
}
