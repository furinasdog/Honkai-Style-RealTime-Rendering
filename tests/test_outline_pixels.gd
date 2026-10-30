extends SceneTree

const OUTLINE: Shader = preload("res://plugins/honkai_mmd/render/outline.gdshader")
var outline: ShaderMaterial
var camera: Camera3D
var instance: MeshInstance3D
var failed := false


func _initialize() -> void:
	call_deferred("_run")


func _texture(color: Color) -> Texture2D:
	var image := Image.create(2, 2, false, Image.FORMAT_RGBA8)
	image.fill(color)
	return ImageTexture.create_from_image(image)


func _image() -> Image:
	for frame in 4:
		await process_frame
	await RenderingServer.frame_post_draw
	return root.get_texture().get_image()


func _width(image: Image) -> float:
	var count := 0
	for x in image.get_width():
		var color := image.get_pixel(x, image.get_height() / 2)
		if color.r > 0.45 and color.g < 0.15 and color.b < 0.15:
			count += 1
	return count * 0.5


func _check_width(actual: float, expected: float, label: String) -> void:
	if absf(actual - expected) > 0.8:
		failed = true
		push_error("%s: outline %.2f px, expected %.2f px" % [label, actual, expected])


func _edge_red(image: Image) -> float:
	var maximum := 0.0
	for x in image.get_width():
		var color := image.get_pixel(x, image.get_height() / 2)
		if color.g < 0.1 and color.b < 0.1:
			maximum = maxf(maximum, color.r)
	return maximum


func _run() -> void:
	create_timer(30).timeout.connect(func(): quit(1))
	root.msaa_3d = Viewport.MSAA_4X
	var environment := WorldEnvironment.new()
	environment.environment = Environment.new()
	environment.environment.background_mode = Environment.BG_COLOR
	environment.environment.background_color = Color.BLACK
	root.add_child(environment)
	camera = Camera3D.new()
	camera.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	camera.fov = 40
	camera.size = 2
	camera.far = 20
	root.add_child(camera)
	camera.make_current()
	var sphere := SphereMesh.new()
	sphere.radius = 0.4
	sphere.height = 0.8
	sphere.radial_segments = 128
	sphere.rings = 64
	var arrays := sphere.surface_get_arrays(0)
	var colors := PackedColorArray()
	colors.resize(arrays[Mesh.ARRAY_VERTEX].size())
	colors.fill(Color(1, 1, 1, 0.5))
	arrays[Mesh.ARRAY_COLOR] = colors
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	instance = MeshInstance3D.new()
	instance.mesh = mesh
	root.add_child(instance)
	var base := StandardMaterial3D.new()
	base.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	base.albedo_color = Color.WHITE
	outline = ShaderMaterial.new()
	outline.shader = OUTLINE
	outline.set_shader_parameter("texture_albedo", _texture(Color.WHITE))
	outline.set_shader_parameter("outline_color", Color.RED)
	outline.set_shader_parameter("outline_width", 3.0)
	outline.set_shader_parameter("use_texture_color", false)
	base.next_pass = outline
	instance.material_override = base
	var widths := []
	for projection in [Camera3D.PROJECTION_ORTHOGONAL, Camera3D.PROJECTION_PERSPECTIVE]:
		camera.projection = projection
		for size in [256, 512]:
			root.size = Vector2i(size, size)
			for distance in [2.0, 5.0]:
				camera.position.z = distance
				var width := _width(await _image())
				widths.append(width)
				_check_width(width, 3.0, "projection %d, %d px, distance %.1f" % [projection, size, distance])
	outline.set_shader_parameter("material_edge_scale", 0.5)
	_check_width(_width(await _image()), 1.5, "PMX material edge scale")
	outline.set_shader_parameter("outline_width", 4.5)
	outline.set_shader_parameter("material_edge_scale", 0.66)
	_check_width(_width(await _image()), 2.97, "Game-sized PMX outline")
	outline.set_shader_parameter("outline_width", 3.0)
	outline.set_shader_parameter("material_edge_scale", 0.0)
	_check_width(_width(await _image()), 0.0, "Authored zero material edge size hides the shell")
	outline.set_shader_parameter("material_edge_scale", 1.0)
	outline.set_shader_parameter("use_mmd_edge_weights", true)
	_check_width(_width(await _image()), 1.5, "PMX vertex edge weight")
	outline.set_shader_parameter("use_mmd_edge_weights", false)
	outline.set_shader_parameter("texture_albedo", _texture(Color(1,1,1,0)))
	_check_width(_width(await _image()), 0.0, "Original texture alpha cutout")
	outline.set_shader_parameter("texture_albedo", _texture(Color.WHITE))
	outline.set_shader_parameter("use_texture_color", true)
	outline.set_shader_parameter("base_color", Color(0.2,0.4,0.8))
	var colored := await _image()
	var blue_pixels := 0
	for x in colored.get_width():
		var color := colored.get_pixel(x, colored.get_height() / 2)
		if color.b > color.r * 1.3 and color.b > color.g * 1.1:
			blue_pixels += 1
	if blue_pixels < 2:
		failed = true
		push_error("Texture-colored outline must retain blue PMX diffuse even when the texture is white")
	outline.set_shader_parameter("use_texture_color", false)
	_check_width(_width(await _image()), 3.0, "Authored PMX outline color is retained")
	outline.set_shader_parameter("use_face_outline_mask", true)
	_check_width(_width(await _image()), 3.0, "Face silhouette keeps its authored mask")
	colors.fill(Color(0,1,1,0.5))
	arrays[Mesh.ARRAY_COLOR] = colors
	var masked := ArrayMesh.new()
	masked.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	instance.mesh = masked
	_check_width(_width(await _image()), 0.0, "Internal face opening suppresses the shell")
	instance.mesh = mesh
	outline.set_shader_parameter("use_face_outline_mask", false)
	outline.set_shader_parameter("outline_color", Color(1,0,0,0))
	_check_width(_width(await _image()), 0.0, "Authored zero edge alpha hides the shell")
	outline.set_shader_parameter("outline_color", Color.RED)
	instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY
	var receiver := MeshInstance3D.new()
	var plane := QuadMesh.new()
	plane.size = Vector2(3,3)
	receiver.mesh = plane
	receiver.position.z = -0.8
	var receiver_material := StandardMaterial3D.new()
	receiver_material.albedo_color = Color.WHITE
	receiver.material_override = receiver_material
	root.add_child(receiver)
	var light := DirectionalLight3D.new()
	root.add_child(light)
	light.look_at_from_position(Vector3(1,1,2), Vector3.ZERO)
	light.shadow_enabled = true
	light.light_angular_distance = 0
	light.shadow_bias = 0.001
	light.shadow_normal_bias = 0.01
	var cast_with_shell := await _image()
	var shadow_point := camera.unproject_position(Vector3(-0.4,-0.4,-0.8))
	var lit_point := camera.unproject_position(Vector3(0.7,0.7,-0.8))
	var shadow_luma := cast_with_shell.get_pixelv(Vector2i(shadow_point)).get_luminance()
	var lit_luma := cast_with_shell.get_pixelv(Vector2i(lit_point)).get_luminance()
	if shadow_luma >= lit_luma * 0.6:
		failed = true
		push_error("The cast-shadow preservation fixture must contain a real shadow")
	outline.set_shader_parameter("outline_width", 0.0)
	var cast_without_shell := await _image()
	if cast_with_shell.get_data() != cast_without_shell.get_data():
		failed = true
		push_error("Outline shell must not enlarge the real mesh's cast shadow")
	var renderer = load("res://plugins/honkai_mmd/render/materials.gd").new()
	var imported: ShaderMaterial = renderer._make_material({"name":"cloth", "category":"cloth", "base_color":[0.3,0.6,0.8,1.0], "edge_size":0.75, "edge_color":[0.1,0.2,0.3,1.0]}, {}, null)
	var imported_outline: ShaderMaterial = imported.next_pass
	assert(imported_outline.get_shader_parameter("use_texture_color"), "Enhanced material must bind texture-colored outlines")
	assert(is_equal_approx(imported_outline.get_shader_parameter("material_edge_scale"), 0.75))
	assert(imported_outline.get_shader_parameter("base_color") == imported.get_shader_parameter("base_color"), "Outline must inherit the same PMX diffuse as the main surface")
	renderer.set_outline_width(4.5)
	assert(is_equal_approx(imported_outline.get_shader_parameter("outline_width"), 4.5), "Wider game-sized outlines must pass through the material control")
	renderer.set_pmx_outline_colors(true)
	assert(not imported_outline.get_shader_parameter("use_texture_color") and imported_outline.get_shader_parameter("outline_color") == Color(0.1,0.2,0.3,1.0), "PMX-color toggle must restore the exact authored edge color")
	renderer.set_pmx_outline_colors(false)
	renderer.set_enhanced(false)
	assert(not imported_outline.get_shader_parameter("use_texture_color"), "Disabling enhancement must bypass automatic outline colors")
	renderer.set_enhanced(true)
	assert(imported_outline.get_shader_parameter("use_texture_color"), "Reenabling enhancement must restore material-colored outlines")
	receiver.free()
	light.free()
	instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.position.z = 2
	root.size = Vector2i(256,256)
	renderer.set_pmx_outline_colors(true)
	var edge_intensities := []
	for alpha in [1.0,0.2]:
		var surface: ShaderMaterial = renderer._make_material({"name":"cloth", "category":"cloth", "base_color":[1.0,1.0,1.0,1.0], "edge_color":[1.0,0.0,0.0,alpha]}, {}, null)
		var edge: ShaderMaterial = surface.next_pass
		edge.set_shader_parameter("outline_width", 3.0)
		base.next_pass = edge
		edge_intensities.append(_edge_red(await _image()))
		if alpha == 1.0:
			assert(not edge.shader.code.contains("ALPHA ="), "Opaque outlines must retain the opaque render pass")
		else:
			assert(edge.shader.code.contains("ALPHA = outline_color.a;"), "Partial edge alpha must select the transparent shader variant")
	if edge_intensities[1] < 0.1 or edge_intensities[1] >= edge_intensities[0] - 0.2:
		failed = true
		push_error("Authored edge alpha .2 must remain visible but fainter than alpha 1: %s" % [edge_intensities])
	if failed:
		quit(1)
		return
	print("OUTLINE_PIXELS_PASS ortho/perspective, near/far, 256/512, material and vertex edge weights, texture/edge alpha and transparent variants, face openings, material-colored and PMX color, cast shadow unchanged; widths=", widths, " edge_alpha_intensities=", edge_intensities)
	quit()
