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


func balanced(color: Color, gain: Color) -> Color:
	return Color(color.r + color.r*(gain.r-1.0)*clampf(1.0-color.r,0.0,1.0), color.g + color.g*(gain.g-1.0)*clampf(1.0-color.g,0.0,1.0), color.b + color.b*(gain.b-1.0)*clampf(1.0-color.b,0.0,1.0))


func material(kind: String, color := Color(0.5, 0.5, 0.5)) -> ShaderMaterial:
	var result := setup._make_material({"name": kind, "category": kind, "base_color": [color.r, color.g, color.b, 1.0], "edge_enabled": false}, {}, null)
	result.set_shader_parameter("rim_strength", 0.0)
	result.set_shader_parameter("specular_strength", 0.0)
	result.set_shader_parameter("world_to_head", Transform3D.IDENTITY)
	result.set_shader_parameter("head_to_world", Transform3D.IDENTITY)
	return result


func run() -> void:
	create_timer(40).timeout.connect(func(): quit(1))
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
	var cloth_balanced := balanced(Color(0.5,0.5,0.5),Color(1.06,1.04,1.02))
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
	check_color(await sample(), balanced(Color(0.5,0.5,0.5),Color(1.03,1.11,1.07)), "Original receive-shadow flag must remain effective")
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
	for pigment in [Color(0.2,0.4,0.7), Color(0.1,0.6,0.65)]:
		patch.material_override = material("cloth", pigment)
		var graded := (await sample()).srgb_to_linear()
		var ungraded := balanced(pigment, Color(1.06,1.04,1.02))
		check(graded.r > 0.01 and graded.r < graded.g and graded.g < graded.b, "Cloth contrast must retain blue/cyan hue and nonzero channel detail")
		check(graded.g < ungraded.g - 0.05 and graded.b <= ungraded.b + 0.02, "Enhanced cloth should deepen colored fabric without lifting its blue channel")
	var blue_folds := material("cloth", Color(0.08,0.22,0.55))
	patch.material_override = blue_folds
	setup.set_shadows_enabled(false)
	var painted_blue := (await sample()).srgb_to_linear()
	setup.set_shadows_enabled(true)
	var folded_blue := (await sample()).srgb_to_linear()
	check(folded_blue.g < painted_blue.g * 0.6 and folded_blue.b > folded_blue.g, "Dark blue painted folds must deepen without losing their hue")
	var deep_blue := material("cloth", Color(0.03,0.07,0.25))
	patch.material_override = deep_blue
	setup.set_shadows_enabled(false)
	var painted_deep_blue := (await sample()).srgb_to_linear()
	setup.set_shadows_enabled(true)
	var graded_deep_blue := (await sample()).srgb_to_linear()
	check(absf(graded_deep_blue.g-painted_deep_blue.g) < 0.015, "Near-black blue cloth must retain its painted depth")
	var bright_blue := material("cloth", Color(0.25,0.55,0.80))
	patch.material_override = bright_blue
	setup.set_shadows_enabled(false)
	var painted_bright_blue := (await sample()).srgb_to_linear()
	setup.set_shadows_enabled(true)
	var graded_bright_blue := (await sample()).srgb_to_linear()
	check(graded_bright_blue.g < painted_bright_blue.g - 0.04 and graded_bright_blue.b < painted_bright_blue.b - 0.02, "Bright blue cloth should be less cyan without crushing dark detail")
	patch.material_override = blue_folds
	blue_folds.set_shader_parameter("has_warm_ramp", true)
	blue_folds.set_shader_parameter("warm_ramp", image_texture(Color.WHITE))
	setup.set_enhanced(true)
	var ramped_blue := (await sample()).srgb_to_linear()
	check(ramped_blue.g > folded_blue.g * 2.0, "A user Ramp must bypass automatic blue cloth folds")
	var pink_cloth := material("cloth", Color(0.70,0.35,0.68))
	patch.material_override = pink_cloth
	setup.set_shadows_enabled(false)
	var painted_pink := (await sample()).srgb_to_linear()
	setup.set_shadows_enabled(true)
	var graded_pink := (await sample()).srgb_to_linear()
	check(graded_pink.r < painted_pink.r and graded_pink.g > painted_pink.g, "Bright pink cloth must be less saturated")
	var pale_cloth := material("cloth", Color(0.82,0.80,0.82))
	patch.material_override = pale_cloth
	setup.set_shadows_enabled(false)
	setup.set_enhanced(false)
	var pale_plain := (await sample()).srgb_to_linear()
	setup.set_enhanced(true)
	var pale_graded := (await sample()).srgb_to_linear()
	check(pale_graded.r > pale_plain.r + 0.03 and pale_graded.g > pale_plain.g + 0.015 and pale_graded.b > pale_plain.b + 0.025, "Near-neutral pale cloth should gain a restrained warm highlight")
	check(maxf(pale_graded.r,maxf(pale_graded.g,pale_graded.b)) < 0.99, "Pale cloth highlights must retain headroom")
	var last_cloth_luminance := -1.0
	for level in [0.0, 0.015, 0.03, 0.06, 0.1, 0.2, 0.4, 0.7, 1.0]:
		patch.material_override = material("cloth", Color(level, level, level))
		var gray_step := (await sample()).srgb_to_linear()
		check(gray_step.get_luminance() >= last_cloth_luminance, "Neutral cloth contrast must preserve grayscale ordering")
		if level == 0.0 or level == 1.0:
			check_color(gray_step.linear_to_srgb(), Color(level,level,level), "Neutral contrast keeps black and white endpoints")
		last_cloth_luminance = gray_step.get_luminance()
	setup.set_shadows_enabled(true)
	var previous := -1.0
	var hair_without_edge := setup._make_material({"name":"hair", "category":"hair", "base_color":[0.5,0.5,0.5,1.0], "edge_enabled":false, "edge_color":[0.45,0.2,0.3,1.0]}, {}, null)
	check(hair_without_edge.get_shader_parameter("palette_mix") > 0.5, "Hair palette must not depend on outline enablement")
	for level in [0.0,0.1,0.5,0.9,0.96,1.0]:
		patch.material_override = material("hair",Color(level,level,level))
		var step_color := (await sample()).srgb_to_linear()
		check_color(step_color.linear_to_srgb(),balanced(Color(level,level,level),Color(1.10,1.06,1.02)),"Bounded style balance must preserve highlight headroom")
		check(step_color.g >= previous,"Style brightness must remain monotonic")
		if level < 0.99:
			check(maxf(step_color.r,maxf(step_color.g,step_color.b)) < 0.999,"Sub-white texture steps must not collapse to white")
		previous = step_color.g
	var ao_material := material("cloth")
	patch.material_override = ao_material
	ao_material.set_shader_parameter("has_warm_ramp",true)
	ao_material.set_shader_parameter("warm_ramp",image_texture(Color.WHITE))
	ao_material.set_shader_parameter("has_light_map",true)
	setup.set_enhanced(true)
	ao_material.set_shader_parameter("light_map",image_texture(Color(1,0.5,0.5,0)))
	var ao_open := (await sample()).srgb_to_linear()
	ao_material.set_shader_parameter("light_map",image_texture(Color(0,0.5,0.5,0)))
	var ao_closed := (await sample()).srgb_to_linear()
	check(ao_closed.g < ao_open.g-0.1,"A user Ramp must retain the LightMap red-channel occlusion")
	var ao_ramp := Image.create(2, 1, false, Image.FORMAT_RGBA8)
	ao_ramp.set_pixel(0, 0, Color(0.1, 0.2, 0.6))
	ao_ramp.set_pixel(1, 0, Color.WHITE)
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
