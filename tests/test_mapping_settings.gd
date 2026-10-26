extends SceneTree

const SETTINGS = preload("res://scripts/mapping_settings.gd")
const PANEL = preload("res://scripts/mapping_settings_panel.gd")
const FLOATING = preload("res://scripts/floating_panel.gd")


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	create_timer(10.0).timeout.connect(func(): quit(1))
	root.size = Vector2i(1280, 720)
	var settings = SETTINGS.new()
	assert(is_zero_approx(settings.response_value("left_eye", 0.3)))
	assert(is_equal_approx(settings.response_value("left_eye", 0.5), 0.5))
	assert(is_equal_approx(settings.response_value("left_eye", 0.7), 1.0))
	settings.set_channel_value("left_eye", "curvature", 1.0)
	assert(is_zero_approx(settings.response_value("left_eye", 0.3)))
	assert(is_equal_approx(settings.response_value("left_eye", 0.5), 0.5))
	assert(is_equal_approx(settings.response_value("left_eye", 0.7), 1.0))
	assert(settings.response_value("left_eye", 0.4) < 0.1)
	assert(settings.response_value("left_eye", 0.6) > 0.9)
	var previous := -1.0
	for step in 101:
		var current: float = settings.response_value("left_eye", 0.3 + step * 0.004)
		assert(is_finite(current) and current >= previous and current >= 0.0 and current <= 1.0)
		previous = current
	assert(is_equal_approx(settings.response_value("right_eye", 0.4), 0.25), "Curvature is per channel")
	settings.set_channel_value("left_eye", "curvature", 0.0)
	assert(settings.set_channel_value("left_eye", "lower", 0.5))
	assert(is_zero_approx(settings.response_value("left_eye", 0.5)))
	assert(is_equal_approx(settings.response_value("right_eye", 0.5), 0.5), "Eye thresholds must be independent")
	settings.set_channel_value("left_eye", "invert", true)
	assert(is_equal_approx(settings.response_value("left_eye", 0.5), 1.0))
	settings.set_channel_value("left_eye", "enabled", false)
	assert(is_zero_approx(settings.map_value("left_eye", 0.9, 0.033)))
	settings.set_channel_value("right_eye", "lower", 1.0)
	assert(settings.channels.right_eye.upper - settings.channels.right_eye.lower >= 0.0099)
	settings.set_channel_value("right_eye", "upper", 0.0)
	assert(settings.channels.right_eye.upper - settings.channels.right_eye.lower >= 0.0099)
	assert(not settings.set_channel_value("head_x", "smoothing", INF))
	settings.set_channel_value("head_x", "smoothing", 0.1)
	assert(is_zero_approx(settings.map_value("head_x", 0.0, 0.033)))
	var first: float = settings.map_value("head_x", 1.0, 0.033)
	assert(first > 0.1 and first < 0.5)
	settings.reset_filters()
	settings.map_value("left_arm", 0.0, 0.033, "upper")
	settings.map_value("left_arm", 1.0, 0.033, "elbow")
	assert(settings.map_value("left_arm", 0.0, 0.033, "upper") == 0.0, "Bone smoothing must not share state")
	settings.set_channel_value("jaw_open", "precision", 4)
	assert(is_equal_approx(settings.response_value("jaw_open", 0.37), 0.25))
	settings.set_channel_value("head_y", "invert", true)
	assert(is_equal_approx(settings.response_value("head_y", 0.5), -0.5))
	settings.set_channel_value("right_eye", "curvature", 0.65)
	var path := "res://outputs/mapping_settings_test.json"
	assert(settings.save(path) == OK)
	settings.set_channel_value("head_y", "sensitivity", 1.5)
	assert(settings.save(path) == OK, "Saving must replace an existing preferences file")
	var restored = SETTINGS.new()
	assert(restored.load_file(path) == OK)
	assert(restored.channels == settings.channels)
	var legacy = JSON.parse_string(FileAccess.get_file_as_string(path))
	for channel: String in legacy.channels:
		legacy.channels[channel].erase("curvature")
	var legacy_file := FileAccess.open(path, FileAccess.WRITE)
	legacy_file.store_string(JSON.stringify(legacy))
	legacy_file.close()
	assert(restored.load_file(path) == OK and restored.channels.right_eye.curvature == 0.0, "Old presets must retain a linear response")
	var bad := FileAccess.open(path, FileAccess.WRITE)
	bad.store_string("[]")
	bad.close()
	assert(restored.load_file(path) == ERR_PARSE_ERROR)
	assert(is_equal_approx(restored.channels.left_eye.lower, 0.3))
	var panel = PANEL.new()
	root.add_child(panel)
	panel.setup(settings)
	assert(panel.selected_channel == "left_eye")
	panel._rows.lower.spin.value = 0.2
	assert(is_equal_approx(settings.channels.left_eye.lower, 0.2), "UI must update the shared mapping model")
	panel._tabs.current_tab = 1
	assert(panel.selected_channel == "left_arm" and panel._channel_buttons.size() == 4)
	await process_frame
	assert(panel.get_child(0).get_combined_minimum_size().y <= 620, "Settings controls must fit the default window height")
	panel.content_scale_factor = 2.0
	panel.size = Vector2i(740, 570)
	for frame in 3:
		await process_frame
	assert(panel._content.columns == 1 and panel._curve_layout.columns == 1, "Narrow scaled windows must stack the channel list and curve controls")
	assert(panel._content.get_combined_minimum_size().x <= panel._body_scroll.size.x, "Scaled controls must remain horizontally reachable")
	panel.content_scale_factor = 1.0
	panel.size = Vector2i(820, 620)
	await process_frame
	panel.set_available_channels(["head_x", "left_arm"])
	panel._tabs.current_tab = 0
	assert(panel.selected_channel == "head_x" and panel._enabled_checks.left_eye.disabled)
	panel.set_available_channels([])
	assert(panel._invert.disabled and not panel._rows.lower.slider.editable, "Unsupported model channels must not show active controls")
	panel._save_timer.stop()
	panel.queue_free()
	var floating = FLOATING.new()
	root.add_child(floating)
	floating.setup("动捕控制")
	floating.position = Vector2(120, 160)
	floating.custom_minimum_size.x = 310
	var slider := HSlider.new()
	slider.custom_minimum_size = Vector2(280, 28)
	floating.body.add_child(slider)
	await process_frame
	await process_frame
	var point: Vector2 = floating._header.global_position + Vector2(20, 10)
	var press := InputEventMouseButton.new()
	press.button_index = MOUSE_BUTTON_LEFT
	press.pressed = true
	press.position = point
	root.push_input(press, true)
	await process_frame
	assert(floating._dragging, "Only the title bar should begin panel dragging")
	var motion := InputEventMouseMotion.new()
	motion.position = point + Vector2(80, 40)
	motion.relative = Vector2(80, 40)
	motion.button_mask = MOUSE_BUTTON_MASK_LEFT
	root.push_input(motion, true)
	await process_frame
	assert(floating.position.distance_to(Vector2(120, 160)) > 20.0, "Dragging the title must move the panel")
	press = press.duplicate()
	press.position = motion.position
	press.pressed = false
	root.push_input(press, true)
	await process_frame
	var expanded_position: Vector2 = floating.position
	press.position = slider.global_position + slider.size * 0.5
	press.pressed = true
	root.push_input(press, true)
	await process_frame
	assert(not floating._dragging, "A slider must not begin panel dragging")
	press.pressed = false
	root.push_input(press, true)
	floating.set_collapsed(true)
	assert(floating.collapsed and not floating.body.visible and is_equal_approx(floating.position.y, 8.0))
	floating.set_collapsed(false)
	assert(floating.body.visible and floating.position.is_equal_approx(expanded_position))
	floating.set_collapsed(true)
	press.position = floating._header.global_position + Vector2(20, 10)
	press.pressed = true
	root.push_input(press, true)
	await process_frame
	motion.position = press.position + Vector2(5, 70)
	motion.relative = Vector2(5, 70)
	root.push_input(motion, true)
	await process_frame
	assert(not floating.collapsed and floating.body.visible and floating.position.y > 20.0, "Dragging a minimized title must restore the panel at its dragged position")
	press.position = motion.position
	press.pressed = false
	root.push_input(press, true)
	floating.queue_free()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	print("MAPPING_SETTINGS_PASS: eye thresholds, inversion, smoothing, range validation, persistence, panel binding and collapse")
	quit(0)
