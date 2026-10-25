shader_type spatial;
render_mode diffuse_burley, specular_disabled;

varying vec3 world_position;

void vertex() {
	world_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	vec2 coordinate = world_position.xz;
	vec2 cell = abs(fract(coordinate - 0.5) - 0.5) / max(fwidth(coordinate), vec2(0.0001));
	float grid = 1.0 - min(min(cell.x, cell.y), 1.0);
	float fade = 1.0 - smoothstep(5.0, 16.0, length(coordinate));
	vec3 ground = mix(vec3(0.09, 0.105, 0.15), vec3(0.145, 0.17, 0.23), grid * 0.35 * fade);
	ALBEDO = ground;
	EMISSION = ground * 0.32;
	ROUGHNESS = 1.0;
}
