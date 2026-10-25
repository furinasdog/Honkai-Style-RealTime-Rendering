extends SceneTree


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	create_timer(25.0).timeout.connect(func(): quit(1))
	var receiver = preload("res://scripts/native_mocap.gd").new()
	assert(receiver.open() == OK)
	var models: Array = []
	for name in ["pose_landmarker_lite.task", "hand_landmarker.task", "face_landmarker.task"]:
		models.append(FileAccess.get_file_as_bytes("res://mocap/models/" + name))
	assert(receiver._native.initialize(models))
	assert(receiver.poll_preview().is_empty(), "Preview is opt-in")
	receiver.set_preview_enabled(true)
	var image := Image.load_from_file("res://mocap/test_data/portrait.jpg")
	image.convert(Image.FORMAT_RGB8)
	var values = receiver._native.detect_rgb(image.get_data(), image.get_width(), image.get_height(), 1000)
	assert(values.size() == 590, "Preview must preserve the existing retarget frame layout")
	var data: Dictionary = receiver.poll_preview()
	assert(not data.is_empty() and data.frame.face != null)
	assert(data.image.get_data() == image.get_data(), "Preview pixels must belong to the inferred frame")
	assert(data.sequence == receiver._native.get_sequence() and data.frame.timestamp_ms == 1000)
	assert(data.face_points.size() >= 468 * 3 and data.face_points.size() % 3 == 0)
	assert(receiver.poll_preview().is_empty(), "Preview keeps only one latest frame")
	assert(not receiver.is_running(), "Fixture inference must not open a webcam")
	var window = preload("res://scripts/capture_preview.gd").new()
	root.add_child(window)
	window.setup(receiver)
	window.set_process(false)
	window.canvas.size = Vector2(640, 480)
	window.canvas.update_frame(data)
	var box: Rect2 = window.canvas.image_rect()
	var mirrored: Vector2 = window.canvas.point_position(Vector2(0.2, 0.3), box)
	window.canvas.mirror = false
	var normal: Vector2 = window.canvas.point_position(Vector2(0.2, 0.3), box)
	assert(is_equal_approx(normal.x + mirrored.x, box.position.x * 2 + box.size.x))
	assert(normal.y == mirrored.y, "Mirror must transform video and landmarks together")
	window.canvas.mirror = true
	if DisplayServer.get_name() != "headless":
		window.popup_centered()
		window.canvas.landmarks = false
		window.canvas.queue_redraw()
		await process_frame
		await RenderingServer.frame_post_draw
		var rendered: Image = window.get_texture().get_image()
		var rect: Rect2 = window.canvas.image_rect()
		var location: Vector2 = window.canvas.global_position + rect.position + rect.size * Vector2(0.1, 0.1)
		var actual: Color = rendered.get_pixelv(Vector2i(location))
		var expected: Color = image.get_pixel(int(image.get_width() * 0.9), int(image.get_height() * 0.1))
		assert(Vector3(actual.r, actual.g, actual.b).distance_to(Vector3(expected.r, expected.g, expected.b)) < 0.08, "Mirrored image must fill the same rectangle as its landmarks")
		window.canvas.landmarks = true
		window.canvas.queue_redraw()
		await RenderingServer.frame_post_draw
		assert(window.get_texture().get_image().save_png("res://outputs/preview_fixture.png") == OK)
	window.close_requested.emit()
	assert(not window.visible and window.canvas.texture == null)
	assert(receiver.poll_preview().is_empty())
	receiver.close()
	window.queue_free()
	await process_frame
	var settings = preload("res://scripts/mapping_settings.gd").new()
	settings.set_channel_value("left_eye", "curvature", 0.8)
	settings.map_value("left_eye", 0.48, 0.033)
	var mapping = preload("res://scripts/mapping_settings_panel.gd").new()
	root.add_child(mapping)
	mapping.setup(settings)
	assert(mapping._rows.curvature.spin.value == 0.8)
	if DisplayServer.get_name() != "headless":
		mapping.popup_centered()
		await process_frame
		await RenderingServer.frame_post_draw
		assert(mapping.get_texture().get_image().save_png("res://outputs/curvature_fixture.png") == OK)
	mapping._save_timer.stop()
	mapping.queue_free()
	await process_frame
	print("CAPTURE_PREVIEW_PASS: native RGB/face landmarks, same-frame metadata, mirror, close and Sigmoid UI; no webcam opened")
	quit(0)
