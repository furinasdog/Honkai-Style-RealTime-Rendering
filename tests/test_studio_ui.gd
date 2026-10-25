extends SceneTree


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	create_timer(25.0).timeout.connect(func(): quit(1))
	var scene = load("res://scenes/main.tscn").instantiate()
	root.add_child(scene)
	await process_frame
	assert(scene.actor.model_root == null, "A clean install must not contain a character")
	assert(not scene.receiver.is_running(), "Startup must not occupy a camera")
	assert(scene.start_button.disabled)
	assert(scene.stage.transparent and root.transparent_bg)
	assert(not root.borderless, "Transparency must retain the system title bar")
	assert(scene.menu_windows.size() == 4)
	scene._open_menu("捕捉")
	assert(scene.app_settings.visible and scene.app_settings._tabs.current_tab == 1)
	scene._open_menu("模型")
	assert(scene.menu_windows["模型"].visible and not scene.app_settings.visible)
	scene.menu_windows["模型"].hide()
	scene.main_panel.set_collapsed(true)
	assert(scene.main_panel.collapsed and not scene.main_panel.body.visible)
	scene.main_panel.set_collapsed(false)
	if DisplayServer.get_name() != "headless":
		for size in [Vector2i(1280, 720), Vector2i(1920, 1080), Vector2i(2560, 1440)]:
			root.size = size
			await process_frame
			await RenderingServer.frame_post_draw
			assert(root.get_texture().get_size() == Vector2(size), "UI must render at native window pixels")
			var image := root.get_texture().get_image()
			assert(image.get_pixel(500, 500).a < 0.01, "Display background must retain alpha")
			assert(image.get_pixel(30, 30).a > 0.99, "Navigation must remain opaque")
			var path := "res://outputs/ui_%d.png" % size.x
			assert(root.get_texture().get_image().save_png(path) == OK)
		scene._set_ui_scale(1.5)
		await process_frame
		await RenderingServer.frame_post_draw
		assert(root.get_texture().get_image().save_png("res://outputs/ui_150percent.png") == OK)
	assert(not scene.receiver.is_running())
	scene.queue_free()
	await process_frame
	print("STUDIO_UI_PASS: empty startup, native module, no camera, transparent decorated window, menus, collapse and native pixels")
	quit(0)
