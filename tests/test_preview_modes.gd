extends SceneTree

class Receiver extends RefCounted:
	var preview_enabled := false
	func set_preview_enabled(value: bool) -> void:
		preview_enabled = value


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	create_timer(15.0).timeout.connect(func(): quit(1))
	var receiver := Receiver.new()
	var window = preload("res://scripts/capture_preview.gd").new()
	root.add_child(window)
	window.setup(receiver)
	window.set_process(false)
	window.canvas.mirror = false
	var image := Image.create(640, 480, false, Image.FORMAT_RGB8)
	image.fill(Color(0.08, 0.09, 0.1))
	var points := []
	for index in 33:
		points.append([-1.0, -1.0, 0.0, 0.0])
	for item in [[11, 0.4, 0.2], [12, 0.6, 0.2], [23, 0.4, 0.5], [24, 0.6, 0.5], [25, 0.4, 0.7], [26, 0.6, 0.7], [27, 0.4, 0.9], [28, 0.6, 0.9]]:
		points[item[0]] = [item[1], item[2], 0.0, 1.0]
	var data := {"image": image, "frame": {"pose": {"image": points}, "hands": []}, "face_points": PackedFloat32Array()}
	window.canvas.update_frame(data)
	var original: Dictionary = data.frame.duplicate(true)
	window.set_capture_mode("full_body")
	assert(window.canvas.mode == "full_body" and data.frame == original and not receiver.preview_enabled, "Mode display must not rewrite raw tracking or activate capture")
	window.set_capture_mode("unknown")
	assert(window.canvas.mode == "vtuber")
	if DisplayServer.get_name() != "headless":
		DirAccess.make_dir_recursive_absolute("res://outputs")
		window.popup_centered()
		for mode in ["vtuber", "full_body"]:
			window.set_capture_mode(mode)
			for frame in 2:
				await process_frame
			await RenderingServer.frame_post_draw
			var rendered: Image = window.get_texture().get_image()
			var location: Vector2 = window.canvas.global_position + window.canvas.point_position(Vector2(0.4, 0.6), window.canvas.image_rect())
			var pixel := rendered.get_pixelv(Vector2i(location))
			assert(pixel.g > 0.6 if mode == "full_body" else pixel.g < 0.2, "Leg overlay must only appear in full-body mode")
			assert(rendered.save_png("res://outputs/preview_mode_%s.png" % mode) == OK)
	assert(data.frame == original)
	window.queue_free()
	await process_frame
	print("PREVIEW_MODES_PASS display-only mode, VTuber/full-body leg overlay, unchanged raw frame, no capture")
	quit(0)
