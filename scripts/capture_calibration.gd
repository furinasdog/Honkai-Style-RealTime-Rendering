class_name CaptureCalibration
extends RefCounted

signal changed

var settings_path := "user://capture_calibration.json"
var device := 0
var profile: Dictionary = defaults()
var _profiles := {}
var _rotation := Basis.IDENTITY


static func defaults() -> Dictionary:
	return {"enabled": false, "position": [0.0, 0.0, 1.5], "yaw": 0.0, "pitch": 0.0, "roll": 0.0}


func set_device(index: int) -> void:
	device = clampi(index, 0, 255)
	profile = _profiles.get(str(device), defaults()).duplicate(true)
	_rebuild()
	changed.emit()


func update_profile(values: Dictionary) -> bool:
	var next := profile.duplicate(true)
	for key: String in values:
		if not next.has(key):
			return false
		next[key] = values[key]
	if not _valid(next):
		return false
	profile = next
	_profiles[str(device)] = next.duplicate(true)
	_rebuild()
	changed.emit()
	return true


func reset_device() -> void:
	update_profile(defaults())


func angles() -> Vector3:
	var p := Vector3(profile.position[0], profile.position[1], profile.position[2])
	return Vector3(clampf(rad_to_deg(atan2(p.y, Vector2(p.x, p.z).length())) + float(profile.pitch), -85, 85), rad_to_deg(atan2(p.x, p.z)) + float(profile.yaw), float(profile.roll))


func _rebuild() -> void:
	var a := angles()
	_rotation = Basis(Vector3.UP, deg_to_rad(a.y)) * Basis(Vector3.RIGHT, -deg_to_rad(a.x)) * Basis(Vector3.BACK, deg_to_rad(a.z))


func correct_frame(frame: Dictionary) -> Dictionary:
	if not profile.enabled or _rotation.is_equal_approx(Basis.IDENTITY):
		return frame
	var result := frame.duplicate(true)
	if result.get("pose") is Dictionary:
		_rotate_points(result.pose.get("world", []))
	for hand: Dictionary in result.get("hands", []):
		_rotate_points(hand.get("world", []))
	if result.get("face") is Dictionary:
		var matrix: Array = result.face.get("matrix", [])
		if matrix.size() == 16:
			# Face matrices already use OpenGL camera axes; world landmarks use MediaPipe Y-down/Z-away.
			var basis := _rotation * Basis(Vector3(matrix[0], matrix[4], matrix[8]), Vector3(matrix[1], matrix[5], matrix[9]), Vector3(matrix[2], matrix[6], matrix[10]))
			for column in 3:
				for row in 3:
					matrix[row * 4 + column] = basis[column][row]
	return result


func _rotate_points(points: Array) -> void:
	for point: Array in points:
		if point.size() < 3:
			continue
		var rotated := _rotation * Vector3(point[0], -point[1], -point[2])
		point[0] = rotated.x
		point[1] = -rotated.y
		point[2] = -rotated.z


func save_file() -> Error:
	_profiles[str(device)] = profile.duplicate(true)
	var file := FileAccess.open(settings_path + ".tmp", FileAccess.WRITE)
	if file == null:
		return FileAccess.get_open_error()
	file.store_string(JSON.stringify({"version": 1, "devices": _profiles}, "\t"))
	file.close()
	return DirAccess.rename_absolute(ProjectSettings.globalize_path(settings_path + ".tmp"), ProjectSettings.globalize_path(settings_path))


func load_file() -> Error:
	_profiles.clear()
	var result := ERR_FILE_NOT_FOUND
	if FileAccess.file_exists(settings_path):
		var file := FileAccess.open(settings_path, FileAccess.READ)
		if file == null or file.get_length() > 262144:
			result = ERR_PARSE_ERROR
		else:
			var data = JSON.parse_string(file.get_as_text())
			if data is Dictionary and data.get("version") == 1 and data.get("devices") is Dictionary and data.devices.size() <= 256:
				result = OK
				for key: String in data.devices:
					if key.is_valid_int() and int(key) in range(256) and data.devices[key] is Dictionary and _valid(data.devices[key]):
						_profiles[key] = data.devices[key].duplicate(true)
			else:
				result = ERR_PARSE_ERROR
	set_device(device)
	return result


static func _valid(value: Dictionary) -> bool:
	if not value.get("enabled") is bool or not value.get("position") is Array or value.position.size() != 3:
		return false
	for item in value.position:
		if not _number(item) or absf(float(item)) > 4.0:
			return false
	if float(value.position[2]) < 0.25:
		return false
	for key in ["yaw", "pitch", "roll"]:
		if not _number(value.get(key)) or absf(float(value[key])) > 180:
			return false
	return true


static func _number(value: Variant) -> bool:
	return (value is float or value is int) and is_finite(float(value))
