// Semi-transparent wireframe (add-body preview sphere).
shader_type spatial;
render_mode unshaded, wireframe, cull_disabled, depth_draw_never;

uniform vec4 wire_color : source_color = vec4(0.624, 0.839, 1.0, 0.55);

void fragment() {
	ALBEDO = wire_color.rgb;
	ALPHA = wire_color.a;
}
