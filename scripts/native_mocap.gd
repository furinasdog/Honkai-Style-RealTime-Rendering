extends RefCounted

const FACE_CHANNELS := ["_neutral", "browDownLeft", "browDownRight", "browInnerUp", "browOuterUpLeft", "browOuterUpRight", "cheekPuff", "cheekSquintLeft", "cheekSquintRight", "eyeBlinkLeft", "eyeBlinkRight", "eyeLookDownLeft", "eyeLookDownRight", "eyeLookInLeft", "eyeLookInRight", "eyeLookOutLeft", "eyeLookOutRight", "eyeLookUpLeft", "eyeLookUpRight", "eyeSquintLeft", "eyeSquintRight", "eyeWideLeft", "eyeWideRight", "jawForward", "jawLeft", "jawOpen", "jawRight", "mouthClose", "mouthDimpleLeft", "mouthDimpleRight", "mouthFrownLeft", "mouthFrownRight", "mouthFunnel", "mouthLeft", "mouthLowerDownLeft", "mouthLowerDownRight", "mouthPressLeft", "mouthPressRight", "mouthPucker", "mouthRight", "mouthRollLower", "mouthRollUpper", "mouthShrugLower", "mouthShrugUpper", "mouthSmileLeft", "mouthSmileRight", "mouthStretchLeft", "mouthStretchRight", "mouthUpperUpLeft", "mouthUpperUpRight", "noseSneerLeft", "noseSneerRight"]

var _native: RefCounted
var _initialized := false
var pose_model := ""
var _model_error := ""
var last_packet_ms := -1
var packet_count := 0
var capture_fps: float:
	get:
		return float(_native.get_fps()) if _native != null else 0.0


func open() -> Error:
	if _native != null:
		return OK
	if not ClassDB.class_exists("NativeMocap"):
		var result := GDExtensionManager.load_extension("res://native/mocap.gdextension")
		if result not in [GDExtensionManager.LOAD_STATUS_OK, GDExtensionManager.LOAD_STATUS_ALREADY_LOADED]:
			return ERR_CANT_OPEN
	_native = ClassDB.instantiate("NativeMocap") as RefCounted
	return OK if _native != null else ERR_CANT_CREATE


func start(options: Dictionary) -> bool:
	if not _prepare_pose_model(str(options.get("pose_model", "full"))):
		return false
	reset()
	return bool(_native.start_camera(int(options.device), int(options.width), int(options.height), int(options.fps)))


func _prepare_pose_model(selected: String) -> bool:
	_model_error = ""
	if selected not in ["full", "lite"]:
		_model_error = "不支持的姿态模型：" + selected
		return false
	if open() != OK:
		return false
	if _initialized and pose_model == selected:
		return true
	if is_running():
		_model_error = "请先停止捕捉，再切换姿态模型。"
		return false
	var models: Array = []
	for name: String in ["pose_landmarker_%s.task" % selected, "hand_landmarker.task", "face_landmarker.task"]:
		var path := "res://mocap/models/" + name
		if not FileAccess.file_exists(path):
			_model_error = "缺少动捕模型：" + name + "，请检查完整发行包。"
			return false
		models.append(FileAccess.get_file_as_bytes(path))
	_initialized = bool(_native.initialize(models))
	pose_model = selected if _initialized else ""
	reset()
	return _initialized


func stop() -> void:
	if _native != null:
		_native.stop()
	reset()


func close() -> void:
	stop()
	_native = null
	_initialized = false
	pose_model = ""
	_model_error = ""


func reset() -> void:
	last_packet_ms = -1
	packet_count = 0


func is_running() -> bool:
	return _native != null and bool(_native.is_running())


func is_live() -> bool:
	return is_running() and last_packet_ms >= 0 and Time.get_ticks_msec() - last_packet_ms < 500


func get_error() -> String:
	if not _model_error.is_empty():
		return _model_error
	return str(_native.get_error()) if _native != null else "无法加载原生动捕模块，请检查完整发行文件。"


func set_preview_enabled(enabled: bool) -> void:
	if not enabled and _native == null:
		return
	if open() == OK:
		_native.set_preview_enabled(enabled)


func poll_preview() -> Dictionary:
	if _native == null:
		return {}
	return decode_preview(_native.poll_preview())


static func decode_preview(value: Variant) -> Dictionary:
	if not value is Array or value.size() != 7:
		return {}
	if not value[0] is int or not value[1] is int or not value[2] is PackedByteArray or not value[3] is PackedFloat32Array or not value[4] is PackedFloat32Array or not value[5] is int or not value[6] is int:
		return {}
	var width: int = value[0]
	var height: int = value[1]
	if width < 1 or width > 8192 or height < 1 or height > 8192 or value[2].size() != width * height * 3 or value[4].size() > 3072 or value[4].size() % 3 != 0:
		return {}
	for coordinate: float in value[4]:
		if not is_finite(coordinate):
			return {}
	var frame := decode_frame(value[3], value[5], value[6])
	if frame.is_empty():
		return {}
	return {"image": Image.create_from_data(width, height, false, Image.FORMAT_RGB8, value[2]), "frame": frame, "face_points": value[4], "sequence": value[5]}


func poll() -> Dictionary:
	if _native == null:
		return {}
	var values = _native.poll()
	if not values is PackedFloat32Array or values.size() != 590:
		return {}
	var packet := decode_frame(values, int(_native.get_sequence()), int(_native.get_timestamp_ms()))
	if not packet.is_empty():
		last_packet_ms = Time.get_ticks_msec()
		packet_count += 1
	return packet


static func decode_frame(values: PackedFloat32Array, sequence: int, timestamp_ms: int) -> Dictionary:
	if values.size() != 590 or sequence < 0 or timestamp_ms < 0:
		return {}
	for value in values:
		if not is_finite(value):
			return {}
	var pose = null
	if values[0] > 0.5:
		pose = {"world": _rows(values, 4, 33, 4), "image": _rows(values, 136, 33, 4)}
	var hands: Array = []
	for hand in clampi(int(values[1]), 0, 2):
		var offset := 268 + hand * 127
		hands.append({"side": "Left" if values[offset] < 0.5 else "Right", "world": _rows(values, offset + 1, 21, 3), "image": _rows(values, offset + 64, 21, 3)})
	var face = null
	if values[2] > 0.5:
		var blendshapes := {}
		for channel in FACE_CHANNELS.size():
			blendshapes[FACE_CHANNELS[channel]] = values[522 + channel]
		face = {"blendshapes": blendshapes, "matrix": Array(values.slice(574, 590)) if values[3] > 0.5 else [1.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 1.0]}
	return {"version": 1, "seq": sequence, "timestamp_ms": timestamp_ms, "pose": pose, "hands": hands, "face": face}


static func _rows(values: PackedFloat32Array, start: int, count: int, width: int) -> Array:
	var rows: Array = []
	for index in count:
		rows.append(Array(values.slice(start + index * width, start + (index + 1) * width)))
	return rows
