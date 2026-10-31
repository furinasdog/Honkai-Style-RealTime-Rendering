extends SceneTree

const Materials = preload("res://plugins/honkai_mmd/render/materials.gd")
var setup := Materials.new()
var patch: MeshInstance3D
var light: DirectionalLight3D
var failed := false


func _initialize() -> void:
	call_deferred("run")


func sample() -> Color:
	for frame in 3:
		await process_frame
	await RenderingServer.frame_post_draw
	return root.get_texture().get_image().get_pixel(128, 128)


func check(condition: bool, label: String) -> void:
	if not condition:
		failed = true
		push_error(label)


func check_color(actual: Color, expected: Color, label: String) -> void:
	var linear := actual.srgb_to_linear()
	check(maxf(absf(linear.r-expected.r), maxf(absf(linear.g-expected.g), absf(linear.b-expected.b))) < 0.02, "%s actual=%s expected=%s" % [label, linear, expected])


func image_texture(color: Color) -> Texture2D:
	var image := Image.create(4, 4, false, Image.FORMAT_RGBA8)
	image.fill(color)
	return ImageTexture.create_from_image(image)


func material(kind: String, color := Color(0.5, 0.5, 0.5)) -> ShaderMaterial:
	var result := setup._make_material({"name": kind, "category": kind, "base_color": [color.r, color.g, color.b, 1.0], "edge_enabled": false}, {}, null)
	result.set_shader_parameter("rim_strength", 0.0)
	result.set_shader_parameter("specular_strength", 0.0)
	result.set_shader_parameter("world_to_head", Transform3D.IDENTITY)
	result.set_shader_parameter("head_to_world", Transform3D.IDENTITY)
	return result


func run() -> void:
	create_timer(40).timeout.connect(func(): quit(1))
	var environment := WorldEnvironment.new()
	environment.environment = Environment.new()
	environment.environment.ambient_light_source = Environment.AMBIENT_SOURCE_DISABLED
	root.add_child(environment)
	root.size = Vector2i(256, 256)
	var camera := Camera3D.new()
	root.add_child(camera)
	camera.position.z = 2
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = 1.5
	camera.make_current()
	light = DirectionalLight3D.new()
	light.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	root.add_child(light)
	patch = MeshInstance3D.new()
	patch.mesh = QuadMesh.new()
	root.add_child(patch)
	var face := material("face")
	patch.material_override = face
	face.set_shader_parameter("has_warm_ramp", true)
	face.set_shader_parameter("warm_ramp", image_texture(Color.RED))
	setup.set_enhanced(true)
	var warm := await sample()
	face.set_shader_parameter("warm_ramp", image_texture(Color.BLUE))
	var changed := await sample()
	check(warm.r > 0.7 and warm.b < 0.05 and changed.b > 0.7 and changed.r < 0.05, "Face warm Ramp replacement must affect rendered colors")
	face.set_shader_parameter("has_warm_ramp", false)
	face.set_shader_parameter("has_cool_ramp", true)
	face.set_shader_parameter("cool_ramp", image_texture(Color.GREEN))
	var cool := await sample()
	check(cool.g > 0.7 and cool.r < 0.05, "Face cool-only Ramp must also render")
	setup.set_shadows_enabled(false)
	var full_bright := await sample()
	check(absf(full_bright.r - full_bright.g) < 0.02 and full_bright.b > 0.6, "Full-bright bypass must retain source color instead of the Ramp")
	setup.set_shadows_enabled(true)
	setup.set_enhanced(false)
	var original := await sample()
	check(absf(original.r - original.g) < 0.02 and original.b > 0.6, "Enhancement off must bypass user Ramp")
	for name in ["衣饰铁", "鉄飾り", "steel trim", "金属"]:
		check(setup.classify_material(name) == "metal", "Generic metal semantics lost: " + name)
	check(setup.classify_material("金发") == "hair", "Golden hair must not become metal")
	setup.set_enhanced(true)
	var image := Image.create(4, 4, false, Image.FORMAT_RGBA8)
	var shade := Color(0.6, 0.2, 0.5)
	image.fill(Color.WHITE)
	for x in 4:
		image.set_pixel(x, 3, shade)
	assert(image.save_png("user://authored_toon.png") == OK)
	var entry := {"name":"cloth", "category":"cloth", "base_color":[0.5,0.5,0.5,1.0], "edge_enabled":false, "toon_texture":"user://authored_toon.png"}
	var authored := setup._make_material(entry, {}, null)
	authored.set_shader_parameter("rim_strength", 0.0)
	patch.material_override = authored
	var authored_bright := (await sample()).srgb_to_linear()
	var cloth_balanced := Color(0.5,0.5,0.5)
	check_color(authored_bright.linear_to_srgb(), cloth_balanced, "Enhanced authored Toon receives the same category balance as other diffuse materials")
	light.rotation.y = PI
	var authored_dark := (await sample()).srgb_to_linear()
	check_color(authored_dark.linear_to_srgb(), cloth_balanced * shade.srgb_to_linear(), "Enhanced authored Toon preserves its original shadow color relationship")
	var original_toon := shade.srgb_to_linear()
	check(absf(authored_dark.r/authored_bright.r-original_toon.r)<0.02 and absf(authored_dark.g/authored_bright.g-original_toon.g)<0.02 and absf(authored_dark.b/authored_bright.b-original_toon.b)<0.02, "Style balance must not replace or distort the authored Toon shadow/lit ratio")
	setup.set_enhanced(false)
	check_color(await sample(), Color(0.5,0.5,0.5) * original_toon, "Enhancement off restores the exact authored Toon shadow appearance")
	light.rotation.y = 0
	check_color(await sample(), Color(0.5,0.5,0.5), "Enhancement off restores original bright diffuse with authored Toon")
	setup.set_enhanced(true)
	image.fill(Color.BLACK)
	assert(image.save_png("user://authored_sphere.png") == OK)
	entry.erase("toon_texture")
	patch.material_override = setup._make_material(entry, {}, null)
	patch.material_override.set_shader_parameter("rim_strength", 0.0)
	var no_sphere := await sample()
	entry["sphere_texture"] = "user://authored_sphere.png"
	entry["sphere_mode"] = 2
	patch.material_override = setup._make_material(entry, {}, null)
	patch.material_override.set_shader_parameter("rim_strength", 0.0)
	check_color(await sample(), no_sphere.srgb_to_linear(), "A black additive Sphere is an identity operation and must not disable category grading")
	entry["sphere_mode"] = 1
	var multiply := setup._make_material(entry, {}, null)
	multiply.set_shader_parameter("rim_strength", 0.0)
	patch.material_override = multiply
	check_color(await sample(), Color.BLACK, "Black multiply sphere map must darken the original diffuse")
	entry["sphere_mode"] = 2
	# A second path also checks that separate authored source images are not conflated in the cache.
	image.fill(Color(0.25,0.1,0.0))
	assert(image.save_png("user://authored_add.png") == OK)
	entry["sphere_texture"] = "user://authored_add.png"
	var additive := setup._make_material(entry, {}, null)
	additive.set_shader_parameter("rim_strength", 0.0)
	patch.material_override = additive
	var added := Color(0.5,0.5,0.5) + Color(0.25,0.1,0.0).srgb_to_linear()
	check_color(await sample(), cloth_balanced + Color(0.25,0.1,0.0).srgb_to_linear(), "Additive sphere map contributes its original color after the generic diffuse grade")
	setup.set_enhanced(false)
	check_color(await sample(), added, "Original-model fallback retains authored sphere data")
	setup.set_shadows_enabled(false)
	check_color(await sample(), added, "Full bright retains authored appearance while bypassing lighting")
	setup.set_shadows_enabled(true)
	setup.set_enhanced(true)
	image.fill(Color.BLACK)
	assert(image.save_png("user://authored_dark_toon.png") == OK)
	entry["toon_texture"] = "user://authored_dark_toon.png"
	var dark_additive := setup._make_material(entry, {}, null)
	dark_additive.set_shader_parameter("rim_strength", 0.0)
	patch.material_override = dark_additive
	check_color(await sample(), Color(0.25,0.1,0.0).srgb_to_linear(), "Additive sphere color must be combined after the authored dark Toon")
	var white_black := setup._make_material({"name":"cloth", "category":"cloth", "base_color":[1.0,1.0,1.0,1.0], "edge_enabled":false, "toon_texture":"user://authored_dark_toon.png"}, {}, null)
	patch.material_override = white_black
	check_color(await sample(), Color.BLACK, "White cloth must retain an authored black Toon shadow")
	image.fill(Color.WHITE)
	for x in 4:
		image.set_pixel(x, 3, Color(0.75,0.72,0.82))
	assert(image.save_png("user://authored_soft_toon.png") == OK)
	var white_soft := setup._make_material({"name":"cloth", "category":"cloth", "base_color":[1.0,1.0,1.0,1.0], "edge_enabled":false, "toon_texture":"user://authored_soft_toon.png"}, {}, null)
	patch.material_override = white_soft
	light.rotation.y = PI
	var soft_shadow := await sample()
	light.rotation.y = 0
	var soft_lit := await sample()
	check(soft_shadow.r < soft_lit.r - 0.04 and soft_shadow.g < soft_lit.g - 0.04 and soft_shadow.b < soft_lit.b - 0.02, "Near-white cloth must retain a medium-strength authored Toon shadow")
	entry.erase("toon_texture")
	var before_override := setup._make_material({"name":"cloth", "category":"cloth", "base_color":[0.5,0.5,0.5,1.0], "edge_enabled":false, "toon_texture":"user://authored_toon.png"}, {}, null)
	patch.material_override = before_override
	before_override.set_shader_parameter("has_warm_ramp", true)
	before_override.set_shader_parameter("warm_ramp", image_texture(Color.BLUE))
	setup.set_enhanced(true)
	var overridden := await sample()
	check(overridden.b > 0.7 and overridden.r < 0.05, "A user Ramp must override the original PMX Toon")
	var sub_image := Image.create(2,2,false,Image.FORMAT_RGBA8)
	sub_image.fill(Color.WHITE)
	sub_image.set_pixel(0,0,Color.BLACK)
	sub_image.set_pixel(0,1,Color.BLACK)
	assert(sub_image.save_png("user://authored_subtexture.png") == OK)
	entry["sphere_texture"] = "user://authored_subtexture.png"
	entry["sphere_mode"] = 3
	entry["has_sphere_uv1"] = true
	var subtexture := setup._make_material(entry, {}, null)
	subtexture.set_shader_parameter("rim_strength", 0.0)
	patch.material_override = subtexture
	var arrays := QuadMesh.new().surface_get_arrays(0)
	var values := PackedFloat32Array()
	for vertex in arrays[Mesh.ARRAY_VERTEX].size():
		values.append_array(PackedFloat32Array([0.25,0.5,0.0,0.0]))
	arrays[Mesh.ARRAY_CUSTOM0] = values
	var sub_mesh := ArrayMesh.new()
	var flags := Mesh.ARRAY_FORMAT_CUSTOM0 | (Mesh.ARRAY_CUSTOM_RGBA_FLOAT << Mesh.ARRAY_FORMAT_CUSTOM0_SHIFT)
	sub_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays, [], {}, flags)
	patch.mesh = sub_mesh
	check_color(await sample(), Color.BLACK, "Sphere mode 3 must use PMX additional UV1")
	subtexture.set_shader_parameter("has_sphere_uv1", false)
	check_color(await sample(), cloth_balanced, "Missing additional UV1 must preserve the generic diffuse grade instead of sampling an arbitrary location")
	patch.mesh = QuadMesh.new()
	var receiver := setup._make_material({"name":"skin", "category":"skin", "base_color":[0.5,0.5,0.5,1.0], "edge_enabled":false, "receive_shadow":false}, {}, null)
	var blocked := Shader.new()
	blocked.code = Materials.TOON.code.replace("ATTENUATION", "0.0")
	receiver.shader = blocked
	receiver.set_shader_parameter("rim_strength", 0.0)
	patch.material_override = receiver
	check_color(await sample(), Color(0.5,0.5,0.5), "Original receive-shadow flag must remain effective")
	var glossy := setup._make_material({"name":"cloth", "category":"cloth", "base_color":[0.1,0.1,0.1,1.0], "edge_enabled":false, "specular":[0.2,0.0,0.0], "shininess":1.0}, {}, null)
	glossy.set_shader_parameter("rim_strength", 0.0)
	patch.material_override = glossy
	light.rotation.y = deg_to_rad(60)
	var broad_gloss := await sample()
	glossy.set_shader_parameter("authored_shininess", 128.0)
	var narrow_gloss := await sample()
	check(broad_gloss.r > narrow_gloss.r + 0.1 and absf(broad_gloss.g - narrow_gloss.g) < 0.02, "Original specular color and shininess must reach the rendered highlight")
	light.rotation.y = 0
	setup.set_enhanced(false)
	var original_metal := setup._make_material({"name":"metal", "category":"metal", "base_color":[0.5,0.5,0.5,1.0], "edge_enabled":false, "specular":[0.0,0.0,0.0]}, {}, null)
	patch.material_override = original_metal
	check_color(await sample(), Color(0.5,0.5,0.5), "Enhancement off must not add an invented highlight to a matte authored metal")
	setup.set_enhanced(true)
	for kind in ["cloth", "hair", "skin"]:
		for pigment in [Color(0.2,0.4,0.7), Color(0.7,0.3,0.6), Color(0.8,0.8,0.8), Color.BLACK]:
			patch.material_override = material(kind, pigment)
			check_color(await sample(), pigment, "Generic lighting preserves source pigments: " + kind)
	var ao_material := material("cloth")
	patch.material_override = ao_material
	ao_material.set_shader_parameter("has_warm_ramp",true)
	ao_material.set_shader_parameter("warm_ramp",image_texture(Color.WHITE))
	ao_material.set_shader_parameter("has_light_map",true)
	setup.set_enhanced(true)
	ao_material.set_shader_parameter("light_map",image_texture(Color(1,0.5,0,0)))
	var ao_open := (await sample()).srgb_to_linear()
	ao_material.set_shader_parameter("light_map",image_texture(Color(0,0.5,0,0)))
	var ao_closed := (await sample()).srgb_to_linear()
	check_color(ao_closed.linear_to_srgb(), ao_open, "A constant Ramp must not receive a second direct-light AO multiplier")
	var ao_ramp := Image.create(8, 1, false, Image.FORMAT_RGBA8)
	ao_ramp.fill(Color(0.1, 0.2, 0.6))
	ao_ramp.set_pixel(7, 0, Color.WHITE)
	ao_material.set_shader_parameter("warm_ramp", ImageTexture.create_from_image(ao_ramp))
	var occluded_ramp := (await sample()).srgb_to_linear()
	check(occluded_ramp.b > occluded_ramp.r * 3.0 and occluded_ramp.b > 0.03, "LightMap AO must select the shadow end of the Ramp, not merely dim its lit color")
	var edged := {"name":"cloth", "category":"cloth", "base_color":[0.5,0.5,0.5,1.0], "edge_enabled":true, "edge_color":[0.2,0.1,0.1,0.2]}
	var translucent_outline := setup._make_material(edged, {}, null).next_pass as ShaderMaterial
	edged.edge_color[3] = 1.0
	var opaque_outline := setup._make_material(edged, {}, null).next_pass as ShaderMaterial
	check(translucent_outline.shader != Materials.OUTLINE and translucent_outline.shader.code.contains("ALPHA = outline_color.a;"), "Only authored translucent outlines need an alpha shader variant")
	check(opaque_outline.shader == Materials.OUTLINE, "Opaque outlines must stay in the opaque render pass")
	light.visible = false
	var point := OmniLight3D.new()
	point.position.z = 2
	point.omni_range = 10
	point.shadow_bias = 0.001
	point.shadow_normal_bias = 0.01
	root.add_child(point)
	var blocker := MeshInstance3D.new()
	blocker.mesh = SphereMesh.new()
	blocker.mesh.radius = 0.15
	blocker.mesh.height = 0.3
	blocker.position.z = 1
	blocker.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY
	root.add_child(blocker)
	patch.material_override = setup._make_material({"name":"skin", "category":"skin", "base_color":[0.5,0.5,0.5,1.0], "edge_enabled":false, "receive_shadow":false}, {}, null)
	patch.material_override.set_shader_parameter("rim_strength", 0.0)
	var unblocked := await sample()
	point.shadow_enabled = true
	check_color(await sample(), unblocked.srgb_to_linear(), "A point-light shadow must honor the original receive-shadow=false flag")
	point.shadow_enabled = false
	point.position.z = 4
	var distant := await sample()
	check(distant.get_luminance() < unblocked.get_luminance() - 0.05, "Disabling shadow reception must retain point-light distance falloff")
	point.position.z = 2
	point.shadow_enabled = true
	patch.material_override = setup._make_material({"name":"skin", "category":"skin", "base_color":[0.5,0.5,0.5,1.0], "edge_enabled":false, "receive_shadow":true}, {}, null)
	patch.material_override.set_shader_parameter("rim_strength", 0.0)
	check((await sample()).get_luminance() < unblocked.get_luminance() - 0.05, "The point-light fixture must actually cast a shadow on an enabled receiver")
	print("MATERIAL_FIDELITY_FACE warm=", warm, " blue=", changed, " cool=", cool)
	patch.free()
	if failed:
		quit(1)
		return
	print("MATERIAL_FIDELITY_PASS face/user Ramp, authored Toon, sphere multiply/add/subtexture, source fallback, full bright, receive-shadow, specular, metal semantics, blue/cyan detail")
	quit()
