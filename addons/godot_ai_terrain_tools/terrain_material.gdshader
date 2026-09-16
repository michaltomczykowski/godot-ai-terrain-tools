shader_type spatial;
render_mode diffuse_burley, specular_schlick_ggx;

// Colour-only terrain material. The build and paint passes write semantic
// weights into COLOR (r = ground, g = road/dirt/sand, b = rock, a = snow);
// this shader blends one palette colour per layer and adds a little
// deterministic grain so large flat areas do not read as untextured plastic.
// No textures are sampled.

uniform vec4 ground_color : source_color = vec4(0.36, 0.55, 0.25, 1.0);
uniform vec4 road_color : source_color = vec4(0.42, 0.31, 0.20, 1.0);
uniform vec4 rock_color : source_color = vec4(0.44, 0.42, 0.40, 1.0);
uniform vec4 snow_color : source_color = vec4(0.92, 0.94, 0.97, 1.0);
uniform float grain_strength : hint_range(0.0, 0.3) = 0.07;
uniform float surface_roughness : hint_range(0.0, 1.0) = 0.9;

varying vec3 terrain_position;

void vertex() {
	terrain_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

float hash_noise(vec2 point) {
	return fract(sin(dot(point, vec2(12.9898, 78.233))) * 43758.5453);
}

void fragment() {
	vec4 layers = max(COLOR, vec4(0.0));
	layers /= max(dot(layers, vec4(1.0)), 0.0001);
	vec3 palette = ground_color.rgb * layers.r + road_color.rgb * layers.g
		+ rock_color.rgb * layers.b + snow_color.rgb * layers.a;
	float grain = hash_noise(terrain_position.xz * 0.37) - 0.5;
	ALBEDO = clamp(palette + grain * grain_strength, vec3(0.0), vec3(1.0));
	ROUGHNESS = surface_roughness;
}
