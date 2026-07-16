// Additive glow billboard matching three.js AdditiveBlending (SRC_ALPHA, ONE).
// Godot's blend_add does not premultiply source alpha, so we bake alpha into
// the color and output ALPHA = 1 — correct under any additive blend factors.
shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never;

uniform sampler2D glow_tex : source_color, filter_linear;
uniform vec4 tint : source_color = vec4(1.0);
uniform float opacity : hint_range(0.0, 2.0) = 1.0;

void vertex() {
	// billboard, keeping node scale (same math as BaseMaterial3D's
	// BILLBOARD_ENABLED + keep_scale)
	MODELVIEW_MATRIX = VIEW_MATRIX * mat4(
		MAIN_CAM_INV_VIEW_MATRIX[0],
		MAIN_CAM_INV_VIEW_MATRIX[1],
		MAIN_CAM_INV_VIEW_MATRIX[2],
		MODEL_MATRIX[3]);
	MODELVIEW_MATRIX = MODELVIEW_MATRIX * mat4(
		vec4(length(MODEL_MATRIX[0].xyz), 0.0, 0.0, 0.0),
		vec4(0.0, length(MODEL_MATRIX[1].xyz), 0.0, 0.0),
		vec4(0.0, 0.0, length(MODEL_MATRIX[2].xyz), 0.0),
		vec4(0.0, 0.0, 0.0, 1.0));
	MODELVIEW_NORMAL_MATRIX = mat3(MODELVIEW_MATRIX);
}

void fragment() {
	vec4 t = texture(glow_tex, UV);
	ALBEDO = t.rgb * t.a * tint.rgb * tint.a * opacity;
	ALPHA = 1.0;
}
