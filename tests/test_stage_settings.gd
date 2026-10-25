extends SceneTree


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	create_timer(10.0).timeout.connect(func(): quit(1))
	var scene := Node3D.new()
	var environment := WorldEnvironment.new()
	environment.name = "Environment"
	environment.environment = Environment.new()
	scene.add_child(environment)
	var floor := Node3D.new()
	floor.name = "Floor"
	scene.add_child(floor)
	root.add_child(scene)
	var stage = preload("res://scripts/stage_settings.gd").new()
	scene.add_child(stage)
	stage.setup(scene)
	assert(stage.transparent and root.transparent_bg)
	stage.set_transparent(false)
	stage.set_background_color(Color(0.2, 0.4, 0.6, 0.1))
	assert(environment.environment.background_color == Color(0.2, 0.4, 0.6, 1))
	var image := Image.create(8, 8, false, Image.FORMAT_RGB8)
	image.fill(Color.GREEN)
	var image_path := ProjectSettings.globalize_path("res://outputs/stage_test.png")
	assert(image.save_png(image_path) == OK)
	assert(stage.load_asset(image_path) and stage._background.visible)
	assert(not stage.load_asset(image_path + ".missing") and stage.asset_path == image_path)
	var external := Node3D.new()
	var mesh := MeshInstance3D.new()
	mesh.mesh = BoxMesh.new()
	external.add_child(mesh)
	mesh.owner = external
	var camera := Camera3D.new()
	external.add_child(camera)
	camera.owner = external
	var state := GLTFState.new()
	var document := GLTFDocument.new()
	assert(document.append_from_scene(external, state) == OK)
	var scene_path := ProjectSettings.globalize_path("res://outputs/stage_test.glb")
	assert(document.write_to_filesystem(state, scene_path) == OK)
	external.free()
	assert(stage.load_asset(scene_path) and stage._extra != null and stage._image.texture == null)
	for imported_camera in stage._extra.find_children("*", "Camera3D", true, false):
		assert(not imported_camera.current)
	stage.set_transparent(true)
	assert(root.transparent_bg)
	if DisplayServer.get_name() != "headless":
		assert(root.transparent and not root.borderless)
	assert(not stage._extra.visible and not floor.visible)
	stage.set_transparent(false)
	assert(not root.transparent_bg and stage._extra.visible)
	stage.clear_asset()
	assert(stage.asset_path.is_empty() and stage._extra == null)
	scene.queue_free()
	await process_frame
	DirAccess.remove_absolute(image_path)
	DirAccess.remove_absolute(scene_path)
	print("STAGE_SETTINGS_PASS")
	quit(0)
