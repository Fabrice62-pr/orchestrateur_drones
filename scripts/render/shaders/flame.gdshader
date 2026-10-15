// Flamme : quad orienté vers la caméra (rotation autour de la verticale uniquement),
// forme turbulente animée par un bruit qui monte, dégradé de température
// (cœur blanc-jaune -> orange -> rouge sombre), lumière additive HDR.
shader_type spatial;
render_mode blend_add, unshaded, depth_draw_never, cull_disabled, shadows_disabled;

uniform sampler2D noise_tex : filter_linear_mipmap, repeat_enable;
uniform float intensity = 1.25;

varying float seed;

void vertex() {
	vec3 pos = MODEL_MATRIX[3].xyz;
	vec3 cam = INV_VIEW_MATRIX[3].xyz;
	vec3 dir = cam - pos;
	dir.y = 0.0;
	dir = normalize(dir + vec3(0.0001));
	vec3 right = normalize(cross(vec3(0.0, 1.0, 0.0), dir));
	float sx = length(MODEL_MATRIX[0].xyz);
	float sy = length(MODEL_MATRIX[1].xyz);
	mat4 m = mat4(vec4(right * sx, 0.0), vec4(0.0, sy, 0.0, 0.0), vec4(dir, 0.0), vec4(pos, 1.0));
	MODELVIEW_MATRIX = VIEW_MATRIX * m;
	seed = fract(sin(dot(pos.xz, vec2(12.9898, 78.233))) * 43758.5453);
}

void fragment() {
	vec2 uv = UV;
	uv.y = 1.0 - uv.y;                     // 0 en bas, 1 en haut
	float t = TIME * (1.3 + seed * 0.6);
	// turbulence ascendante sur deux échelles
	float n1 = texture(noise_tex, vec2(uv.x * 0.9 + seed * 7.0, uv.y * 0.8 - t * 0.9)).r;
	float n2 = texture(noise_tex, vec2(uv.x * 2.1 - seed * 3.0, uv.y * 1.9 - t * 1.7)).r;
	float n = n1 * 0.65 + n2 * 0.35;
	// silhouette : large en bas, effilée et déchiquetée en haut
	float x = (uv.x - 0.5) * 2.0;
	x += (n1 - 0.5) * 0.5 * uv.y;
	float width = mix(0.85, 0.08, pow(uv.y, 0.8));
	float body = 1.0 - smoothstep(width * 0.55, width, abs(x));
	float top = 1.0 - smoothstep(0.35, 0.95, uv.y + (n - 0.5) * 0.7);
	float base = smoothstep(0.0, 0.08, uv.y);
	float f = clamp(body * top * base * (0.55 + n * 0.9), 0.0, 1.0);
	// température -> couleur
	float temp = clamp(f * 1.4 - uv.y * 0.45, 0.0, 1.0);
	vec3 col = mix(vec3(0.5, 0.05, 0.0), vec3(1.0, 0.35, 0.03), smoothstep(0.1, 0.45, temp));
	col = mix(col, vec3(1.0, 0.75, 0.25), smoothstep(0.45, 0.75, temp));
	col = mix(col, vec3(1.0, 0.88, 0.55), smoothstep(0.82, 1.0, temp));
	float flicker = 0.8 + 0.2 * sin(TIME * 17.0 + seed * 40.0);
	ALBEDO = col * f * intensity * flicker;
	ALPHA = f * 0.8;
}
