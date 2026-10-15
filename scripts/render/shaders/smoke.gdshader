// Fumée : particules face caméra, éclairées par le soleil (pas « autolumineuses »),
// contours doux en volutes (bruit), fondu au contact du décor (particules douces).
shader_type spatial;
render_mode blend_mix, depth_draw_never, cull_disabled, shadows_disabled, specular_disabled;

uniform sampler2D noise_tex : filter_linear_mipmap, repeat_enable;
uniform sampler2D depth_tex : hint_depth_texture, filter_linear;
uniform float softness = 3.0;

varying float seed;

void vertex() {
	// face caméra en conservant l'échelle de la particule
	MODELVIEW_MATRIX = VIEW_MATRIX * mat4(INV_VIEW_MATRIX[0], INV_VIEW_MATRIX[1], INV_VIEW_MATRIX[2], MODEL_MATRIX[3]);
	MODELVIEW_MATRIX = MODELVIEW_MATRIX * mat4(vec4(length(MODEL_MATRIX[0].xyz), 0.0, 0.0, 0.0),
		vec4(0.0, length(MODEL_MATRIX[1].xyz), 0.0, 0.0), vec4(0.0, 0.0, length(MODEL_MATRIX[2].xyz), 0.0), vec4(0.0, 0.0, 0.0, 1.0));
	seed = fract(sin(dot(MODEL_MATRIX[3].xyz, vec3(12.9898, 78.233, 37.719))) * 43758.5453);
}

void fragment() {
	vec2 c = UV - 0.5;
	float r = length(c) * 2.0;
	float n = texture(noise_tex, UV * 0.8 + vec2(seed * 3.7, seed * 1.3 + TIME * 0.02)).r;
	float n2 = texture(noise_tex, UV * 1.9 - vec2(TIME * 0.015, seed * 5.0)).r;
	float puff = (1.0 - smoothstep(0.35, 1.0, r + (n - 0.5) * 0.7)) * (0.55 + n2 * 0.6);
	// fondu doux quand la particule traverse le sol ou un arbre
	float scene = texture(depth_tex, SCREEN_UV).r;
	vec4 sv = INV_PROJECTION_MATRIX * vec4(SCREEN_UV * 2.0 - 1.0, scene, 1.0);
	float scene_z = -sv.z / sv.w;
	float soft = clamp((scene_z - (-VERTEX.z)) / softness, 0.0, 1.0);
	ALBEDO = COLOR.rgb * mix(0.85, 1.15, n2);
	ALPHA = clamp(puff * COLOR.a * soft, 0.0, 1.0);
	ROUGHNESS = 1.0;
	BACKLIGHT = COLOR.rgb * 0.6;   // le soleil traverse la fumée (bords lumineux)
}
