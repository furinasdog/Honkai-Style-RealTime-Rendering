extends SceneTree

const CAMERA = preload("res://scripts/blender_camera.gd")


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	create_timer(8.0).timeout.connect(func(): quit(1))
	var world := Node3D.new()
	root.add_child(world)
	var camera := CAMERA.new()
	world.add_child(camera)
	await process_frame
	assert(camera.focus.is_equal_approx(Vector3(0.0, 1.25, 0.0)))
	assert(is_equal_approx(camera.distance, 3.2))
	assert(camera.global_position.z > 3.1 and camera.global_basis.z.dot((camera.global_position - camera.focus).normalized()) > 0.999)

	_mouse_button(camera, MOUSE_BUTTON_MIDDLE, true)
	var initial_basis: Basis = camera.global_basis
	_motion(camera, Vector2(30, 20))
	assert(not camera.global_basis.is_equal_approx(initial_basis), "MMB must orbit")
	var panned_focus: Vector3 = camera.focus
	var before_pan: Basis = camera.global_basis
	_motion(camera, Vector2(40, -25), true)
	assert(camera.focus.distance_to(panned_focus) > 0.001 and camera.global_basis.is_equal_approx(before_pan), "Shift+MMB pans in camera space without orbiting")
	panned_focus = camera.focus
	var before_zoom: float = camera.distance
	_mouse_button(camera, MOUSE_BUTTON_WHEEL_UP, true)
	assert(camera.distance < before_zoom and camera.focus.is_equal_approx(panned_focus), "Wheel zoom keeps the panned focus")
	before_zoom = camera.distance
	_motion(camera, Vector2(0, 30), false, true)
	assert(camera.distance > before_zoom and camera.focus.is_equal_approx(panned_focus), "Ctrl+MMB zoom keeps the focus")
	_mouse_button(camera, MOUSE_BUTTON_MIDDLE, false)
	initial_basis = camera.global_basis
	_motion(camera, Vector2(30, 20))
	assert(camera.global_basis.is_equal_approx(initial_basis), "MMB release ends orbit")

	_key(camera, KEY_KP_1)
	assert(camera.projection == Camera3D.PROJECTION_ORTHOGONAL and camera.global_basis.z.dot(Vector3.BACK) > 0.999)
	_key(camera, KEY_KP_1, true)
	assert(camera.global_basis.z.dot(Vector3.FORWARD) > 0.999)
	_key(camera, KEY_KP_3)
	assert(camera.global_basis.z.dot(Vector3.RIGHT) > 0.999)
	_key(camera, KEY_KP_3, true)
	assert(camera.global_basis.z.dot(Vector3.LEFT) > 0.999)
	_key(camera, KEY_KP_7)
	assert(camera.global_basis.z.dot(Vector3.UP) > 0.999 and camera.global_basis.determinant() > 0.999, "Top view must have a stable finite basis")
	_key(camera, KEY_KP_7, true)
	assert(camera.global_basis.z.dot(Vector3.DOWN) > 0.999 and camera.global_transform.is_finite())
	_key(camera, KEY_KP_5)
	assert(camera.projection == Camera3D.PROJECTION_PERSPECTIVE)
	_key(camera, KEY_KP_5)
	assert(camera.projection == Camera3D.PROJECTION_ORTHOGONAL)

	_key(camera, KEY_KP_1)
	_key(camera, KEY_KP_6)
	assert(is_equal_approx(camera.yaw, deg_to_rad(15.0)))
	_key(camera, KEY_KP_4)
	_key(camera, KEY_KP_8)
	assert(is_equal_approx(camera.yaw, 0.0) and is_equal_approx(camera.pitch, deg_to_rad(15.0)))
	_key(camera, KEY_KP_2)
	assert(is_equal_approx(camera.pitch, 0.0))
	_key(camera, KEY_HOME)
	assert(camera.focus.is_equal_approx(camera.subject_center) and is_equal_approx(camera.distance, camera.framing_distance), "Home frames the actor after pan and zoom")
	camera.focus += Vector3(2, 1, -1)
	_key(camera, KEY_KP_PERIOD)
	assert(camera.focus.is_equal_approx(camera.subject_center))
	for frame in 150:
		_mouse_button(camera, MOUSE_BUTTON_WHEEL_UP, true)
	assert(is_equal_approx(camera.distance, 0.35) and camera.global_transform.is_finite())
	for frame in 150:
		_mouse_button(camera, MOUSE_BUTTON_WHEEL_DOWN, true)
	assert(is_equal_approx(camera.distance, 12.0) and camera.global_transform.is_finite())
	var ui := Control.new()
	ui.size = Vector2(200, 200)
	ui.mouse_filter = Control.MOUSE_FILTER_STOP
	root.add_child(ui)
	await process_frame
	camera.frame_subject()
	var blocked_press := InputEventMouseButton.new()
	blocked_press.button_index = MOUSE_BUTTON_MIDDLE
	blocked_press.pressed = true
	blocked_press.position = Vector2(20, 20)
	root.push_input(blocked_press, true)
	await process_frame
	assert(not camera._dragging, "MMB handled by UI must not start camera navigation")
	initial_basis = camera.global_basis
	_motion(camera, Vector2(20, 10))
	assert(camera.global_basis.is_equal_approx(initial_basis), "Dragging from UI into the scene must not capture the camera")
	print("PASS: Blender camera orbit, pan, zoom, keypad views, top/bottom basis and actor framing")
	quit(0)


func _mouse_button(camera: Camera3D, button: MouseButton, pressed: bool) -> void:
	var event := InputEventMouseButton.new()
	event.button_index = button
	event.pressed = pressed
	camera._unhandled_input(event)


func _motion(camera: Camera3D, relative: Vector2, shift := false, ctrl := false) -> void:
	var event := InputEventMouseMotion.new()
	event.relative = relative
	event.button_mask = MOUSE_BUTTON_MASK_MIDDLE
	event.shift_pressed = shift
	event.ctrl_pressed = ctrl
	camera._unhandled_input(event)


func _key(camera: Camera3D, key: Key, ctrl := false) -> void:
	var event := InputEventKey.new()
	event.physical_keycode = key
	event.pressed = true
	event.ctrl_pressed = ctrl
	camera._unhandled_input(event)
