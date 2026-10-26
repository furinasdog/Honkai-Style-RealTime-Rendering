extends SceneTree

const PANEL = preload("res://scripts/app_settings_panel.gd")
const CAMERA = preload("res://scripts/blender_camera.gd")
const TEST_PATH := "res://outputs/app_settings_test.json"

var _capture_events: Array[Dictionary] = []
var _mode_events: Array[String] = []
var _calibration_events := 0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	create_timer(12.0).timeout.connect(func(): quit(1))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(TEST_PATH))
	var world := Node3D.new()
	root.add_child(world)
	var camera = CAMERA.new()
	world.add_child(camera)
	await process_frame
	var viewport := SubViewport.new()
	viewport.size = Vector2i(64, 64)
	root.add_child(viewport)
	viewport.use_taa = true
	var panel = PANEL.new()
	panel.settings_path = TEST_PATH
	root.add_child(panel)
	panel.setup(camera, viewport)
	panel.capture_options_changed.connect(func(options: Dictionary): _capture_events.append(options))
	panel.calibration_requested.connect(func(): _calibration_events += 1)
	panel.tracking_mode_changed.connect(func(value: String): _mode_events.append(value))
	assert(panel.tracking_mode == "vtuber" and not panel._recenter_button.visible)
	assert(panel._tabs.get_tab_count() == 2 and not panel.has_signal("blender_path_changed"))
	var calibration: Button
	for button: Button in panel.find_children("*", "Button", true, false):
		if button.text == "相机方位校正…":
			calibration = button
	assert(calibration != null)
	calibration.pressed.emit()
	assert(_calibration_events == 1 and _capture_events.is_empty(), "Calibration must request its dialog without restarting capture")
	panel.popup_section(99)
	assert(panel._tabs.current_tab == 1 and panel.title == "捕捉设置")
	panel.popup_section(-1)
	assert(panel._tabs.current_tab == 0 and panel.title == "相机与抗锯齿")
	panel.hide()
	assert(not viewport.use_taa and viewport.msaa_3d == Viewport.MSAA_4X)
	assert(panel.capture_options == {"device": 0, "width": 640, "height": 480, "fps": 30})
	for level: int in 4:
		panel._aa.item_selected.emit(level)
		assert(int(viewport.msaa_3d) == level and not viewport.use_taa, "Every AA option must change the actual viewport")
	panel._rows.fov.spin.value = 50.0
	panel._rows.distance.spin.value = 4.5
	panel._rows.focus_height.spin.value = 1.6
	assert(is_equal_approx(camera.fov, 50.0) and is_equal_approx(camera.distance, 4.5))
	assert(is_equal_approx(camera.focus.y, 1.6) and is_equal_approx(camera.subject_center.y, 1.6))
	assert(is_equal_approx(camera.global_position.distance_to(camera.focus), 4.5))
	panel._projection.item_selected.emit(1)
	assert(camera.projection == Camera3D.PROJECTION_ORTHOGONAL and is_equal_approx(camera.size, 2.0 * 4.5 * tan(deg_to_rad(50.0) * 0.5)))
	camera._zoom(0.9)
	var key := InputEventKey.new()
	key.physical_keycode = KEY_KP_5
	key.pressed = true
	camera._unhandled_input(key)
	await process_frame
	assert(panel._projection.selected == 0 and is_equal_approx(panel._rows.distance.spin.value, camera.distance), "Blender keys and wheel must update settings controls")
	panel._device.value = 2
	panel._resolution.select(1)
	panel._fps.select(3)
	assert(_capture_events.is_empty() and panel.capture_options.device == 0, "Editing capture controls must not restart the camera")
	panel._apply_capture()
	assert(_capture_events == [{"device": 2, "width": 1280, "height": 720, "fps": 60}])
	panel.set_capture_device(3)
	assert(panel.capture_options.device == 3 and panel._device.value == 3 and _capture_events.size() == 1, "Main-panel device sync must save without restarting capture twice")
	panel._mode.item_selected.emit(1)
	assert(panel.tracking_mode == "full_body" and panel._recenter_button.visible and _mode_events == ["full_body"])
	assert(_capture_events.size() == 1, "Changing the tracking solver must not restart the camera")
	assert(panel.save_settings() == OK)
	var saved: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(TEST_PATH))
	assert(not saved.has("blender_path"), "Retired converter settings must not be saved")
	saved.blender_path = "legacy-converter-location"
	var legacy := FileAccess.open(TEST_PATH, FileAccess.WRITE)
	legacy.store_string(JSON.stringify(saved))
	legacy.close()
	var saved_capture: Dictionary = panel.capture_options.duplicate()
	var saved_distance: float = camera.distance
	panel.capture_options.device = 9
	camera.distance = 9.0
	assert(panel.load_settings() == OK)
	assert(panel.capture_options == saved_capture)
	assert(panel.tracking_mode == "full_body" and panel._mode.selected == 1)
	assert(is_equal_approx(camera.distance, saved_distance) and is_equal_approx(camera.fov, 50.0))
	assert(panel.save_settings() == OK)
	assert(not JSON.parse_string(FileAccess.get_file_as_string(TEST_PATH)).has("blender_path"), "Loading old settings must discard the retired converter field")
	var corrupt := FileAccess.open(TEST_PATH, FileAccess.WRITE)
	corrupt.store_string("[]")
	corrupt.close()
	assert(panel.load_settings() == ERR_PARSE_ERROR)
	assert(panel.capture_options.device == 0)
	assert(panel.tracking_mode == "vtuber")
	assert(is_equal_approx(camera.distance, 3.2) and is_equal_approx(camera.fov, 35.0))
	var invalid := FileAccess.open(TEST_PATH, FileAccess.WRITE)
	invalid.store_string(JSON.stringify({"version": 1, "rendering": {"msaa_3d": 99}, "camera": {"fov": -50, "distance": -3, "focus_height": 999, "projection": 9}, "capture": {"device": -3, "width": 999, "height": 999, "fps": 999}, "blender_path": false}))
	invalid.close()
	assert(panel.load_settings() == OK)
	assert(viewport.msaa_3d == Viewport.MSAA_8X and not viewport.use_taa)
	assert(is_equal_approx(camera.fov, 10.0) and is_equal_approx(camera.distance, 0.35) and is_equal_approx(camera.focus.y, 100.0))
	assert(panel.capture_options == {"device": 0, "width": 640, "height": 480, "fps": 30})
	await process_frame
	assert(panel.get_child(0).get_combined_minimum_size().y <= 530, "Settings must fit the default window height")
	panel._save_timer.stop()
	panel.queue_free()
	await process_frame
	DirAccess.remove_absolute(ProjectSettings.globalize_path(TEST_PATH))
	print("APP_SETTINGS_PASS: AA viewport, live camera sync, two settings pages, calibration request, explicit capture apply, legacy-field removal and persistence; no camera opened")
	quit(0)
