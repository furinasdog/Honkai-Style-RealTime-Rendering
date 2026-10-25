class_name MappingSettings
extends RefCounted

signal changed(channel_id: String)

const SAVE_PATH := "user://mapping_settings.json"
const MIN_RANGE := 0.01
const DEFINITIONS := {
	"head_x": {"label": "头部俯仰 X", "group": "face", "bipolar": true},
	"head_y": {"label": "头部转向 Y", "group": "face", "bipolar": true},
	"head_z": {"label": "头部侧倾 Z", "group": "face", "bipolar": true},
	"left_eye": {"label": "左眼", "group": "face", "bipolar": false},
	"right_eye": {"label": "右眼", "group": "face", "bipolar": false},
	"jaw_open": {"label": "嘴部开闭", "group": "face", "bipolar": false},
	"mouth_wide": {"label": "嘴部拉伸", "group": "face", "bipolar": false},
	"mouth_pucker": {"label": "撅嘴", "group": "face", "bipolar": false},
	"smile": {"label": "微笑", "group": "face", "bipolar": false},
	"frown": {"label": "嘴角下压", "group": "face", "bipolar": false},
	"brow_up": {"label": "抬眉", "group": "face", "bipolar": false},
	"brow_down": {"label": "皱眉", "group": "face", "bipolar": false},
	"left_arm": {"label": "左手臂", "group": "hands", "bipolar": true},
	"right_arm": {"label": "右手臂", "group": "hands", "bipolar": true},
	"left_hand": {"label": "左手与手指", "group": "hands", "bipolar": true},
	"right_hand": {"label": "右手与手指", "group": "hands", "bipolar": true},
}

var channels: Dictionary = {}
var input_values: Dictionary = {}
var output_values: Dictionary = {}
var _filtered: Dictionary = {}


func _init() -> void:
	reset_defaults(false)


func reset_defaults(notify: bool = true) -> void:
	channels.clear()
	for id: String in DEFINITIONS:
		var definition: Dictionary = DEFINITIONS[id]
		var eye: bool = id in ["left_eye", "right_eye"]
		channels[id] = {"enabled": true, "invert": false, "smoothing": 0.02, "sensitivity": 1.0, "curvature": 0.0, "precision": 0, "lower": 0.3 if eye else (-1.0 if definition.bipolar else 0.0), "upper": 0.7 if eye else 1.0, "bipolar": definition.bipolar}
	reset_filters()
	if notify:
		changed.emit("")


func get_channel(id: String) -> Dictionary:
	return channels.get(id, {})


func set_channel_value(id: String, field: String, value: Variant) -> bool:
	if not channels.has(id):
		return false
	var channel: Dictionary = channels[id]
	if field in ["enabled", "invert"]:
		if not value is bool:
			return false
		channel[field] = value
	elif field in ["smoothing", "sensitivity", "curvature", "precision", "lower", "upper"]:
		if not _number(value):
			return false
		var number := float(value)
		match field:
			"smoothing": channel[field] = clampf(number, 0.0, 0.5)
			"sensitivity": channel[field] = clampf(number, 0.1, 3.0)
			"curvature": channel[field] = clampf(number, 0.0, 1.0)
			"precision": channel[field] = clampi(roundi(number), 0, 200)
			"lower": channel[field] = clampf(number, -1.0 if channel.bipolar else 0.0, float(channel.upper) - MIN_RANGE)
			"upper": channel[field] = clampf(number, float(channel.lower) + MIN_RANGE, 1.0)
	else:
		return false
	reset_filters(id)
	changed.emit(id)
	return true


func response_value(id: String, raw: float) -> float:
	if not channels.has(id) or not is_finite(raw):
		return 0.0
	var channel: Dictionary = channels[id]
	if not channel.enabled:
		return 0.0
	var t := clampf((raw - float(channel.lower)) / maxf(float(channel.upper) - float(channel.lower), MIN_RANGE), 0.0, 1.0)
	var curvature := float(channel.curvature) * 6.0
	if curvature > 0.0001:
		var low := 1.0 / (1.0 + exp(curvature))
		var high := 1.0 - low
		t = (1.0 / (1.0 + exp(-curvature * (2.0 * t - 1.0))) - low) / (high - low)
	var output := t * 2.0 - 1.0 if channel.bipolar else t
	if channel.invert:
		output = -output if channel.bipolar else 1.0 - output
	output = clampf(output * float(channel.sensitivity), -1.0 if channel.bipolar else 0.0, 1.0)
	if int(channel.precision) > 0:
		output = roundf(output * int(channel.precision)) / int(channel.precision)
	return output


func map_value(id: String, raw: float, delta: float, state_key: String = "") -> float:
	if not channels.has(id) or not is_finite(raw) or not is_finite(delta):
		return 0.0
	input_values[id] = raw
	var target := response_value(id, raw)
	var key := id + ":" + state_key
	var smoothing: float = channels[id].smoothing
	if not channels[id].enabled or smoothing <= 0.0 or not _filtered.has(key):
		_filtered[key] = target
	else:
		_filtered[key] = lerpf(float(_filtered[key]), target, 1.0 - exp(-clampf(delta, 0.0, 0.2) / smoothing))
	output_values[id] = _filtered[key]
	return float(_filtered[key])


func reset_filters(id: String = "") -> void:
	if id.is_empty():
		_filtered.clear()
		input_values.clear()
		output_values.clear()
		return
	for key: String in _filtered.keys():
		if key.begins_with(id + ":"):
			_filtered.erase(key)
	input_values.erase(id)
	output_values.erase(id)


func save(path: String = SAVE_PATH) -> Error:
	var temporary := path + ".tmp"
	var file := FileAccess.open(temporary, FileAccess.WRITE)
	if file == null:
		return FileAccess.get_open_error()
	file.store_string(JSON.stringify({"version": 1, "channels": channels}, "\t"))
	file.close()
	return DirAccess.rename_absolute(ProjectSettings.globalize_path(temporary), ProjectSettings.globalize_path(path))


func load_file(path: String = SAVE_PATH) -> Error:
	reset_defaults(false)
	if not FileAccess.file_exists(path):
		return ERR_FILE_NOT_FOUND
	var decoded = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not decoded is Dictionary or decoded.get("version") != 1 or not decoded.get("channels") is Dictionary:
		changed.emit("")
		return ERR_PARSE_ERROR
	for id: String in decoded.channels:
		if not channels.has(id) or not decoded.channels[id] is Dictionary:
			continue
		var input: Dictionary = decoded.channels[id]
		for field in ["enabled", "invert", "smoothing", "sensitivity", "curvature", "precision"]:
			if input.has(field):
				set_channel_value(id, field, input[field])
		var channel: Dictionary = channels[id]
		var floor := -1.0 if channel.bipolar else 0.0
		var low := clampf(float(input.lower), floor, 1.0 - MIN_RANGE) if _number(input.get("lower")) else float(channel.lower)
		var high := clampf(float(input.upper), floor + MIN_RANGE, 1.0) if _number(input.get("upper")) else float(channel.upper)
		channel.lower = minf(low, high - MIN_RANGE)
		channel.upper = high
	reset_filters()
	changed.emit("")
	return OK


static func _number(value: Variant) -> bool:
	return (value is float or value is int) and is_finite(float(value))
