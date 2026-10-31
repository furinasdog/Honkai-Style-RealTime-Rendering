extends SceneTree


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	create_timer(25.0).timeout.connect(func(): quit(1))
	var scene = load("res://scenes/main.tscn").instantiate()
	root.add_child(scene)
	await process_frame
	assert(is_equal_approx(scene.outline_width, 2.6), "The default outline must match the video-calibrated capture")
	assert(scene.actor.model_root == null, "A clean install must not contain a character")
	assert(not scene.receiver.is_running(), "Startup must not occupy a camera")
	assert(scene.start_button.disabled)
	assert(scene.stage.transparent and root.transparent_bg)
	assert(not root.borderless, "Transparency must retain the system title bar")
	assert(scene.menu_windows.size() == 4)
	assert(scene.menu_windows["场景"].is_ancestor_of(scene.shadows_toggle), "Shadow controls belong to the scene page")
	for label: Label in scene.menu_windows["场景"].find_children("*", "Label", true, false):
		assert(label.text not in ["灯光方向", "灯光高度"], "Fixed lighting must not expose direction sliders")
	for button: BaseButton in scene.menu_windows["场景"].find_children("*", "BaseButton", true, false):
		assert(button.text != "自动转灯", "Fixed lighting must not expose automatic light rotation")
	var fixed_basis: Basis = scene.key_light.global_basis
	var azimuth := deg_to_rad(20.0)
	var elevation := deg_to_rad(48.4)
	var to_light := Vector3(sin(azimuth) * cos(elevation), sin(elevation), cos(azimuth) * cos(elevation))
	assert(fixed_basis.z.is_equal_approx(to_light), "The scene must retain the calibrated fixed world-light direction")
	var initial_camera_transform: Transform3D = scene.camera.transform
	var initial_camera_projection: int = scene.camera.projection
	var initial_camera_yaw: float = scene.camera.yaw
	var initial_camera_pitch: float = scene.camera.pitch
	var initial_actor_transform: Transform3D = scene.actor.transform
	scene.camera.set_view("right")
	assert(scene.key_light.global_basis.is_equal_approx(fixed_basis), "Orbiting the camera must not rotate the light")
	scene.actor.rotate_y(PI * 0.5)
	scene.actor.position += Vector3(0.3, 0.1, -0.2)
	assert(scene.key_light.global_basis.is_equal_approx(fixed_basis), "Moving or rotating the actor must not rotate the light")
	for frame in 3:
		await process_frame
	scene._process(0.25)
	assert(scene.key_light.global_basis.is_equal_approx(fixed_basis), "Process updates must preserve the fixed world-light direction")
	scene.camera.yaw = initial_camera_yaw
	scene.camera.pitch = initial_camera_pitch
	scene.camera.projection = initial_camera_projection
	scene.camera.transform = initial_camera_transform
	scene.actor.transform = initial_actor_transform
	assert(scene.enhanced and not scene.eye_transparency)
	assert(scene.menu_windows["模型"].is_ancestor_of(scene.enhanced_toggle))
	scene.enhanced_toggle.button_pressed = false
	assert(not scene.material_setup.enhanced)
	scene.eye_transparency_toggle.button_pressed = true
	assert(scene.material_setup.eye_transparency)
	scene.enhanced_toggle.button_pressed = true
	scene.eye_transparency_toggle.button_pressed = false
	scene.shadows_toggle.button_pressed = false
	assert(not scene.shadows_enabled and not scene.key_light.shadow_enabled and not scene.material_setup.shadows_enabled)
	var config := ConfigFile.new()
	assert(config.load("user://showcase.cfg") == OK and config.get_value("render", "shadows_enabled") == false)
	scene.shadows_toggle.button_pressed = true
	assert(scene.retarget.mode == "vtuber" and scene.app_settings.tracking_mode == "vtuber")
	scene.app_settings._gesture_toggle.button_pressed = true
	assert(scene.retarget.hand_gesture_assistance and not scene.receiver.is_running())
	scene.app_settings._gesture_toggle.button_pressed = false
	scene._open_menu("捕捉")
	assert(scene.app_settings.visible and scene.app_settings._tabs.current_tab == 1)
	assert(scene.app_settings._tabs.get_tab_count() == 2)
	scene.app_settings._mode.item_selected.emit(1)
	assert(scene.retarget.mode == "full_body" and scene.capture_preview._mode == "full_body" and not scene.receiver.is_running())
	scene.app_settings.recenter_requested.emit()
	scene.app_settings._mode.item_selected.emit(0)
	var camera_transform: Transform3D = scene.camera.transform
	scene.app_settings.calibration_requested.emit()
	assert(scene.calibration_panel.visible and not scene.app_settings.visible)
	scene.capture_alignment.update_profile({"enabled": true, "position": [1.0, 0.3, 1.5]})
	assert(scene.camera.transform == camera_transform, "Capture calibration must not move the presentation camera")
	scene._open_menu("模型")
	assert(scene.menu_windows["模型"].visible and not scene.app_settings.visible and not scene.calibration_panel.visible)
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
		for scale in [1.0, 1.5, 2.0]:
			scene._set_ui_scale(scale)
			for section: String in ["模型", "画面", "场景", "应用", "捕捉"]:
				scene._open_menu(section)
				await process_frame
				await RenderingServer.frame_post_draw
				var window: Window = scene.app_settings if section == "捕捉" else scene.menu_windows[section]
				assert(window.get_texture().get_image().save_png("res://outputs/ui_%s_%d.png" % [section, scale * 100]) == OK)
				scene.app_settings.calibration_requested.emit()
			await process_frame
			await RenderingServer.frame_post_draw
			assert(scene.calibration_panel.get_texture().get_image().save_png("res://outputs/ui_calibration_%d.png" % (scale * 100)) == OK)
			assert(scene.calibration_panel._views.columns == (2 if scale == 1.0 else 1))
			scene.calibration_panel.hide()
			scene.texture_panel.set_renderer(scene.material_setup)
			scene.texture_panel.popup_centered()
			await process_frame
			await RenderingServer.frame_post_draw
			assert(scene.texture_panel.get_texture().get_image().save_png("res://outputs/ui_textures_%d.png" % (scale * 100)) == OK)
			scene.texture_panel.hide()
			await process_frame
			await RenderingServer.frame_post_draw
			assert(root.get_texture().get_image().save_png("res://outputs/ui_navigation_%d.png" % (scale * 100)) == OK)
	assert(not scene.receiver.is_running())
	scene.queue_free()
	await process_frame
	print("STUDIO_UI_PASS: fixed world light, independent camera/actor rotation, empty startup, native module, no camera, transparent decorated window, menus, collapse and native pixels")
	quit(0)
