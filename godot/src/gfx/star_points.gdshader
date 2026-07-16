// Point-cloud shader with distance attenuation (three.js PointsMaterial
// sizeAttenuation equivalent). Used by the starfield layers and impact debris.
shader_type spatial;
render_mode unshaded, depth_draw_never, blend_mix;

uniform float size_px = 3.2;      // base size in pixels at reference distance
uniform float opacity = 0.95;

varying vec3 vcol;

void vertex() {
	vcol = COLOR.rgb;
	vec4 mv = MODELVIEW_MATRIX * vec4(VERTEX, 1.0);
	float dist = max(1.0, -mv.z);
	// ~three.js sizeAttenuation at devicePixelRatio 2 (the prototype's look)
	POINT_SIZE = clamp(size_px * VIEWPORT_SIZE.y / dist, 1.5, 24.0);
}

void fragment() {
	float d = length(POINT_COORD - vec2(0.5));
	float a = 1.0 - smoothstep(0.30, 0.5, d);
	ALBEDO = vcol;
	ALPHA = opacity * a;
}
