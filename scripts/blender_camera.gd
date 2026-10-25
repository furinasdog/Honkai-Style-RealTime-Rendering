class_name BlenderCamera
extends Camera3D

@export var subject_center := Vector3(0.0, 1.25, 0.0)
@export var framing_distance := 3.2

var focus := Vector3(0.0, 1.25, 0.0)
var distance := 3.2
var yaw := 0.0
var pitch := 0.05
var _dragging := false


func _ready() -> void:
	physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	fov = 35.0
	frame_subject()


func frame_subject() -> void:
	focus = subject_center
	distance = framing_distance
	_dragging = false
	_update_transform()


func set_view(view: String) -> void:
	match view:
		"front": yaw = 0.0; pitch = 0.0
		"back": yaw = PI; pitch = 0.0
		"right": yaw = PI * 0.5; pitch = 0.0
		"left": yaw = -PI * 0.5; pitch = 0.0
		"top": yaw = 0.0; pitch = PI * 0.5
		"bottom": yaw = 0.0; pitch = -PI * 0.5
		_: return
	projection = Camera3D.PROJECTION_ORTHOGONAL
	_update_transform()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_MIDDLE:
			_dragging = event.pressed
			get_viewport().set_input_as_handled()
		elif event.pressed and event.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN]:
			_zoom(0.9 if event.button_index == MOUSE_BUTTON_WHEEL_UP else 1.0 / 0.9)
			get_viewport().set_input_as_handled()
	elif event is InputEventMouseMotion:
		if not event.button_mask & MOUSE_BUTTON_MASK_MIDDLE:
			_dragging = false
		if not _dragging:
			return
		if event.shift_pressed:
			var pixels := maxf(get_viewport().get_visible_rect().size.y, 1.0)
			var scale := 2.0 * distance * tan(deg_to_rad(fov) * 0.5) / pixels
			focus += (-global_basis.x * event.relative.x + global_basis.y * event.relative.y) * scale
		elif event.ctrl_pressed:
			_zoom(exp(event.relative.y * 0.01))
		else:
			yaw -= event.relative.x * 0.006
			pitch = clampf(pitch + event.relative.y * 0.006, -PI * 0.5, PI * 0.5)
		_update_transform()
		get_viewport().set_input_as_handled()
	elif event is InputEventKey and event.pressed and not event.echo:
		var key: Key = event.physical_keycode if event.physical_keycode != KEY_NONE else event.keycode
		match key:
			KEY_KP_1: set_view("back" if event.ctrl_pressed else "front")
			KEY_KP_3: set_view("left" if event.ctrl_pressed else "right")
			KEY_KP_7: set_view("bottom" if event.ctrl_pressed else "top")
			KEY_KP_5:
				projection = Camera3D.PROJECTION_PERSPECTIVE if projection == Camera3D.PROJECTION_ORTHOGONAL else Camera3D.PROJECTION_ORTHOGONAL
			KEY_KP_2: pitch = maxf(-PI * 0.5, pitch - deg_to_rad(15.0))
			KEY_KP_8: pitch = minf(PI * 0.5, pitch + deg_to_rad(15.0))
			KEY_KP_4: yaw -= deg_to_rad(15.0)
			KEY_KP_6: yaw += deg_to_rad(15.0)
			KEY_KP_ADD: _zoom(0.9)
			KEY_KP_SUBTRACT: _zoom(1.0 / 0.9)
			KEY_HOME, KEY_KP_PERIOD: frame_subject()
			_: return
		_update_transform()
		get_viewport().set_input_as_handled()


func _zoom(factor: float) -> void:
	distance = clampf(distance * factor, 0.35, 12.0)
	_update_transform()


func _update_transform() -> void:
	# Construct the basis directly so exact top/bottom views never have a degenerate look_at up vector.
	global_basis = Basis.from_euler(Vector3(-pitch, yaw, 0.0))
	global_position = focus + global_basis.z * distance
	size = 2.0 * distance * tan(deg_to_rad(fov) * 0.5)
