// Immeubles : façades photo (4 styles), fenêtres vitrées réfléchissantes étage par
// étage (rideaux, stores, cadres), vitrines en rez-de-chaussée, soubassement, corniche,
// toit en gravier avec acrotère. Taille de l'immeuble lue dans la transformation
// d'instance (boîte unité mise à l'échelle). Couleur d'instance = teinte de l'enduit.
// L'alpha de la couleur d'instance choisit le type de façade :
//   1.0        : un des 4 styles au hasard (brique comprise)
//   0.5 .. 0.95 : enduit uniquement (immeubles blancs / ocre façon Casablanca, Rabat)
//   < 0.5      : mur-rideau en verre (tours du quartier d'affaires), teinté par la couleur
shader_type spatial;
render_mode specular_schlick_ggx;

global uniform float wetness;
global uniform float snow_cover;

uniform sampler2D fa_d : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D fa_n : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D fb_d : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D fb_n : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D fc_d : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D fc_n : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D fd_d : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D fd_n : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D roof_d : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D roof_n : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;

varying vec3 wpos;
varying vec3 wnrm;
varying vec3 bsize;
varying vec3 bcenter;

float hash(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

void vertex() {
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	wnrm = normalize(mat3(MODEL_MATRIX) * NORMAL);
	bsize = vec3(length(MODEL_MATRIX[0].xyz), length(MODEL_MATRIX[1].xyz), length(MODEL_MATRIX[2].xyz));
	bcenter = MODEL_MATRIX[3].xyz;
}

void fragment() {
	float seed = hash(floor(bcenter.xz));
	int style = int(floor(seed * 4.0));
	bool curtain = COLOR.a < 0.5;
	if (COLOR.a < 0.95) style = int(floor(seed * 3.0));   // pas de brique
	float base_y = bcenter.y - bsize.y * 0.5;
	float y = wpos.y - base_y;
	vec3 tint = COLOR.rgb;
	vec3 alb;
	vec3 nrm = vec3(0.5, 0.5, 1.0);
	float rough = 0.85;
	float metal = 0.0;

	if (wnrm.y > 0.5) {
		// --- toit : gravier + acrotère (rebord) le long du périmètre
		vec2 uv = wpos.xz / 4.0;
		alb = texture(roof_d, uv).rgb * 0.85;
		nrm = texture(roof_n, uv).rgb;
		vec2 d = bsize.xz * 0.5 - abs(wpos.xz - bcenter.xz);
		float parapet = 1.0 - smoothstep(0.35, 0.45, min(d.x, d.y));
		alb = mix(alb, tint * 0.75, parapet);
		rough = mix(0.95, 0.7, parapet);
		float snow = smoothstep(0.05, 0.5, snow_cover);
		alb = mix(alb, vec3(0.92, 0.94, 0.97), snow);
		alb *= mix(1.0, 0.6, wetness * (1.0 - snow));
		rough = mix(rough, 0.25, wetness * (1.0 - snow));
	} else if (wnrm.y < -0.5) {
		alb = vec3(0.2);
	} else if (curtain) {
		// --- mur-rideau : panneaux de verre réfléchissants, montants et lisses métalliques
		bool along_zc = abs(wnrm.x) > 0.5;
		float uc = along_zc ? wpos.z : wpos.x;
		float gu = fract(uc / 1.6);
		float gv = fract(y / 3.6);
		float mull = 1.0 - step(0.05, gu) * step(gu, 0.95) * step(0.07, gv) * step(gv, 0.93);
		float cellc = hash(vec2(floor(uc / 1.6), floor(y / 3.6)) + bcenter.xz);
		vec3 g = COLOR.rgb * 0.32 * mix(0.82, 1.15, cellc);
		float spandrel = step(0.8, fract(y / 3.6));   // allège opaque entre deux étages
		g = mix(g, COLOR.rgb * 0.18, spandrel * 0.7);
		alb = mix(g, vec3(0.62, 0.64, 0.67), mull);
		rough = mix(0.05, 0.35, mull);
		metal = mix(0.85, 0.9, mull);
		nrm = vec3(0.5, 0.5, 1.0);
		alb = mix(alb, vec3(0.08), 1.0 - step(0.6, y));   // socle sombre
		rough = mix(rough, rough * 0.6, wetness);
	} else {
		// --- façade : coordonnée horizontale le long de la face
		bool along_z = abs(wnrm.x) > 0.5;
		float u = along_z ? wpos.z : wpos.x;
		float face_len = along_z ? bsize.z : bsize.x;
		float face_start = (along_z ? bcenter.z : bcenter.x) - face_len * 0.5;
		vec2 uv = vec2(u, -wpos.y) / 3.0;
		vec3 wall;
		if (style == 0) { wall = texture(fa_d, uv).rgb; nrm = texture(fa_n, uv).rgb; }
		else if (style == 1) { wall = texture(fb_d, uv).rgb; nrm = texture(fb_n, uv).rgb; }
		else if (style == 2) { wall = texture(fc_d, uv).rgb; nrm = texture(fc_n, uv).rgb; }
		else { wall = texture(fd_d, uv * 0.8).rgb; nrm = texture(fd_n, uv * 0.8).rgb; }
		// l'enduit prend la teinte propre à l'immeuble (la brique garde sa couleur)
		float tint_amt = style == 3 ? 0.15 : 0.55;
		wall = mix(wall, wall * tint * 1.7, tint_amt);
		alb = wall;

		// trame des fenêtres
		float ground_h = 4.2;
		float floor_h = 3.15;
		float bay = style == 1 ? 2.4 : 3.0;
		float lu = u - face_start;
		float nb = max(1.0, floor((face_len - 1.2) / bay));
		float margin = (face_len - nb * bay) * 0.5;
		float bx = (lu - margin) / bay;
		float fx = fract(bx);
		bool in_bays = bx > 0.0 && bx < nb;
		float storey;
		float fy;
		bool shop = y < ground_h;
		if (shop) {
			storey = 0.0;
			fy = y / ground_h;
		} else {
			storey = floor((y - ground_h) / floor_h) + 1.0;
			fy = fract((y - ground_h) / floor_h);
		}
		float top_band = 1.0 - step(bsize.y - 0.9, y);   // corniche : pas de fenêtre
		vec2 wmin = shop ? vec2(0.05, 0.1) : vec2(0.2, 0.28);
		vec2 wmax = shop ? vec2(0.95, 0.82) : vec2(0.8, 0.86);
		if (style == 1 && !shop) { wmin.x = 0.08; wmax.x = 0.92; }   // bandeaux vitrés
		float win = (in_bays ? 1.0 : 0.0) * top_band
			* step(wmin.x, fx) * step(fx, wmax.x) * step(wmin.y, fy) * step(fy, wmax.y);
		float frame = (in_bays ? 1.0 : 0.0) * top_band
			* step(wmin.x - 0.035, fx) * step(fx, wmax.x + 0.035) * step(wmin.y - 0.035, fy) * step(fy, wmax.y + 0.035) - win;
		if (win > 0.5) {
			float cell = hash(vec2(floor(bx) + face_start * 3.1, storey + bcenter.x));
			// vitre sombre et réfléchissante ; parfois rideaux / stores visibles derrière
			vec3 glass = vec3(0.035, 0.045, 0.055);
			if (!shop && cell > 0.72) glass = mix(glass, vec3(0.55, 0.5, 0.42), 0.35);
			if (!shop && cell < 0.12) glass = mix(glass, vec3(0.25, 0.27, 0.3), step(0.5, fract(fy * 9.0)) * 0.6);
			if (shop) glass = mix(glass, vec3(0.3, 0.26, 0.2), 0.25);   // vitrine éclairée
			alb = glass;
			rough = 0.1;
			metal = 0.35;
			nrm = vec3(0.5, 0.5, 1.0);
		} else if (frame > 0.5) {
			alb = shop ? vec3(0.12) : vec3(0.75, 0.75, 0.72);
			rough = 0.5;
			nrm = vec3(0.5, 0.5, 1.0);
		}
		// soubassement sombre, corniche, ombre de retrait sous les fenêtres
		alb = mix(alb, alb * 0.55, 1.0 - step(0.45, y));
		alb = mix(alb, tint * 0.6, (1.0 - top_band) * step(bsize.y - 0.9, y));
		// salissures : coulures plus marquées en bas
		alb *= mix(0.86, 1.0, smoothstep(0.0, 6.0, y));
		alb *= mix(1.0, 0.78, wetness * (1.0 - win));
		rough = mix(rough, rough * 0.55, wetness);
	}
	ALBEDO = alb;
	NORMAL_MAP = nrm;
	NORMAL_MAP_DEPTH = 0.8;
	ROUGHNESS = rough;
	METALLIC = metal;
}
