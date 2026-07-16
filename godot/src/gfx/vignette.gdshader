// Full-screen vignette: radial-gradient(ellipse at center,
// transparent 55%, rgba(0,0,0,0.42) 100%)
shader_type canvas_item;

void fragment() {
	vec2 c = (UV - vec2(0.5)) * 2.0;
	float t = length(c) / 1.41421356;   // farthest corner = 1
	float a = 0.42 * clamp((t - 0.55) / 0.45, 0.0, 1.0);
	COLOR = vec4(0.0, 0.0, 0.0, a);
}
