shader_type spatial;
render_mode diffuse_burley, specular_schlick_ggx;

uniform int material_mode = 0; // 0 procedural, 1 bundled/custom textures.
uniform float texture_scale : hint_range(0.01, 4.0) = 0.2;
uniform float normal_strength : hint_range(0.0, 1.0) = 0.08;

uniform vec4 ground_color : source_color = vec4(0.36, 0.55, 0.25, 1.0);
uniform vec4 road_color : source_color = vec4(0.42, 0.31, 0.20, 1.0);
uniform vec4 rock_color : source_color = vec4(0.44, 0.42, 0.40, 1.0);
uniform vec4 snow_color : source_color = vec4(0.92, 0.94, 0.97, 1.0);

uniform sampler2D ground_albedo : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D ground_normal : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D ground_roughness : hint_default_white, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D road_albedo : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D road_normal : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D road_roughness : hint_default_white, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D rock_albedo : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D rock_normal : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D rock_roughness : hint_default_white, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D snow_albedo : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D snow_normal : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D snow_roughness : hint_default_white, filter_linear_mipmap_anisotropic, repeat_enable;

varying vec3 terrain_position;
varying vec3 terrain_normal;

void vertex() {
	terrain_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	terrain_normal = normalize(MODEL_NORMAL_MATRIX * NORMAL);
}

vec3 projection_weights(vec3 normal_value) {
	vec3 weights = pow(abs(normal_value), vec3(6.0));
	return weights / max(weights.x + weights.y + weights.z, 0.0001);
}

vec4 triplanar(sampler2D source, vec3 position, vec3 weights) {
	vec4 x_sample = texture(source, position.zy * texture_scale);
	vec4 y_sample = texture(source, position.xz * texture_scale);
	vec4 z_sample = texture(source, position.xy * texture_scale);
	return x_sample * weights.x + y_sample * weights.y + z_sample * weights.z;
}

vec3 triplanar_normal(sampler2D source, vec3 position, vec3 weights) {
	vec3 nx = texture(source, position.zy * texture_scale).xyz * 2.0 - 1.0;
	vec3 ny = texture(source, position.xz * texture_scale).xyz * 2.0 - 1.0;
	vec3 nz = texture(source, position.xy * texture_scale).xyz * 2.0 - 1.0;
	float sx = terrain_normal.x < 0.0 ? -1.0 : 1.0;
	float sy = terrain_normal.y < 0.0 ? -1.0 : 1.0;
	float sz = terrain_normal.z < 0.0 ? -1.0 : 1.0;
	// Reorient tangent-space OpenGL normals into the three world-space planes.
	vec3 world_x = normalize(vec3(nx.z * sx, nx.y, nx.x));
	vec3 world_y = normalize(vec3(ny.x, ny.z * sy, ny.y));
	vec3 world_z = normalize(vec3(nz.x, nz.y, nz.z * sz));
	return normalize(world_x * weights.x + world_y * weights.y + world_z * weights.z);
}

float hash_noise(vec2 point) {
	return fract(sin(dot(point, vec2(12.9898, 78.233))) * 43758.5453);
}

void fragment() {
	vec4 layers = max(COLOR, vec4(0.0));
	layers /= max(dot(layers, vec4(1.0)), 0.0001);
	vec3 axis_weights = projection_weights(terrain_normal);
	vec3 palette = ground_color.rgb * layers.r + road_color.rgb * layers.g
		+ rock_color.rgb * layers.b + snow_color.rgb * layers.a;

	if (material_mode == 0) {
		float grain = hash_noise(terrain_position.xz * 0.37) - 0.5;
		ALBEDO = clamp(palette + grain * 0.07, vec3(0.0), vec3(1.0));
		ROUGHNESS = 0.9;
	} else {
		float macro = hash_noise(floor(terrain_position.xz * 0.018)) - 0.5;
		vec3 albedo_value =
			triplanar(ground_albedo, terrain_position, axis_weights).rgb * layers.r
			+ triplanar(road_albedo, terrain_position, axis_weights).rgb * layers.g
			+ triplanar(rock_albedo, terrain_position, axis_weights).rgb * layers.b
			+ triplanar(snow_albedo, terrain_position, axis_weights).rgb * layers.a;
		float roughness_value =
			triplanar(ground_roughness, terrain_position, axis_weights).r * layers.r
			+ triplanar(road_roughness, terrain_position, axis_weights).r * layers.g
			+ triplanar(rock_roughness, terrain_position, axis_weights).r * layers.b
			+ triplanar(snow_roughness, terrain_position, axis_weights).r * layers.a;
		ALBEDO = clamp(albedo_value * mix(vec3(1.0), palette, 0.10) * (1.0 + macro * 0.08), vec3(0.0), vec3(1.0));
		ROUGHNESS = clamp(roughness_value, 0.2, 1.0);
		if (normal_strength > 0.001) {
			vec3 detail_normal = normalize(
				triplanar_normal(ground_normal, terrain_position, axis_weights) * layers.r
				+ triplanar_normal(road_normal, terrain_position, axis_weights) * layers.g
				+ triplanar_normal(rock_normal, terrain_position, axis_weights) * layers.b
				+ triplanar_normal(snow_normal, terrain_position, axis_weights) * layers.a
			);
			if (dot(detail_normal, terrain_normal) < 0.0) {
				detail_normal = -detail_normal;
			}
			detail_normal = normalize(mix(terrain_normal, detail_normal, normal_strength));
			NORMAL = normalize((VIEW_MATRIX * vec4(detail_normal, 0.0)).xyz);
		}
	}
}
