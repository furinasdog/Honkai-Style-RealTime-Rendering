extends SceneTree

var output
var viewport: SubViewport


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	create_timer(20.0).timeout.connect(func(): quit(1))
	viewport = SubViewport.new()
	viewport.size = Vector2i(1280, 720)
	viewport.transparent_bg = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(viewport)
	for part in [[Vector2(0, 0), Color.RED], [Vector2(640, 0), Color(0, 1, 0, 0.5)], [Vector2(0, 360), Color.BLUE]]:
		var rectangle := ColorRect.new()
		rectangle.position = part[0]
		rectangle.size = Vector2(640, 360)
		rectangle.color = part[1]
		viewport.add_child(rectangle)
	output = preload("res://scripts/spout_output.gd").new()
	root.add_child(output)
	output.failed.connect(func(error: String): push_error(error); quit(1))
	await RenderingServer.frame_post_draw
	assert(output.start(viewport, 30) == OK)
	await create_timer(7.0).timeout
	assert(output.get_frames() >= 10, "Spout output did not send real frames")
	output.stop()
	assert(not output.enabled)
	output.queue_free()
	viewport.queue_free()
	await process_frame
	print("SPOUT_OUTPUT_PASS: real GPU frames, explicit stop and resource cleanup; camera not opened")
	quit(0)
