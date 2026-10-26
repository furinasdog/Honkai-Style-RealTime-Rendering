extends Window

signal preview_changed(enabled: bool)
const UI_THEME = preload("res://scripts/ui_theme.tres")

class PreviewCanvas extends Control:
	const BODY_LINKS := [[11, 12], [11, 13], [13, 15], [12, 14], [14, 16], [11, 23], [12, 24], [23, 24]]
	const LEG_LINKS := [[23, 25], [25, 27], [27, 29], [29, 31], [27, 31], [24, 26], [26, 28], [28, 30], [30, 32], [28, 32]]
	var mode := "vtuber"
	var texture: ImageTexture
	var frame: Dictionary = {}
	var face_points := PackedFloat32Array()
	var mirror := true
	var landmarks := true
	var last_update_ms := -1

	func update_frame(data: Dictionary) -> void:
		var source: Image = data.image
		if texture == null or texture.get_size() != Vector2(source.get_size()):
			texture = ImageTexture.create_from_image(source)
		else:
			texture.update(source)
		frame = data.frame
		face_points = data.face_points
		last_update_ms = Time.get_ticks_msec()
		queue_redraw()

	func clear_frame() -> void:
		texture = null
		frame.clear()
		face_points.clear()
		last_update_ms = -1
		queue_redraw()

	func image_rect() -> Rect2:
		if texture == null:
			return Rect2()
		var source := texture.get_size()
		var scale := minf(size.x / source.x, size.y / source.y)
		var display := source * scale
		return Rect2((size - display) * 0.5, display)

	func point_position(point: Variant, box: Rect2) -> Vector2:
		return box.position + Vector2(1.0 - float(point[0]) if mirror else float(point[0]), float(point[1])) * box.size

	func _draw() -> void:
		draw_rect(Rect2(Vector2.ZERO, size), Color("080d12"))
		if texture == null:
			return
		var box := image_rect()
		var destination := box
		if mirror:
			destination.size.x = -destination.size.x
		draw_texture_rect(texture, destination, false)
		if not landmarks:
			return
		var scale := maxf(1.0, box.size.x / 640.0)
		var pose = frame.get("pose")
		if pose is Dictionary:
			for link in (BODY_LINKS + LEG_LINKS if mode == "full_body" else BODY_LINKS):
				var first: Array = pose.image[link[0]]
				var second: Array = pose.image[link[1]]
				if MocapRetarget.image_point_visible(first) and MocapRetarget.image_point_visible(second):
					draw_line(point_position(first, box), point_position(second, box), Color("64d5ed"), 2.0 * scale, true)
			var indices := [11, 12, 13, 14, 15, 16, 23, 24]
			if mode == "full_body":
				indices.append_array([25, 26, 27, 28, 29, 30, 31, 32])
			for index in indices:
				if MocapRetarget.image_point_visible(pose.image[index]):
					draw_circle(point_position(pose.image[index], box), 3.5 * scale, Color("64d5ed"))
		for hand: Dictionary in frame.get("hands", []):
			var valid := true
			for point: Array in hand.image:
				valid = valid and MocapRetarget.image_point_visible(point)
			if not valid:
				continue
			var color := Color("87efad")
			for finger in 5:
				var indices := [0, 1 + finger * 4, 2 + finger * 4, 3 + finger * 4, 4 + finger * 4]
				for segment in 4:
					draw_line(point_position(hand.image[indices[segment]], box), point_position(hand.image[indices[segment + 1]], box), color, 1.5 * scale, true)
			for point in hand.image:
				draw_circle(point_position(point, box), 2.5 * scale, color)
		for index in int(face_points.size() / 3):
			var point := Vector2(face_points[index * 3], face_points[index * 3 + 1])
			if point.x >= 0 and point.x <= 1 and point.y >= 0 and point.y <= 1:
				draw_circle(point_position(point, box), 1.3 * scale, Color("ffd181"))

var _receiver
var canvas: PreviewCanvas
var _status: Label
var _enabled := false
var _mode := "vtuber"


func setup(receiver) -> void:
	_receiver = receiver
	title = "摄像头预览"
	size = Vector2i(800, 670)
	min_size = Vector2i(480, 400)
	visible = false
	transient = true
	transparent = false
	force_native = DisplayServer.has_feature(DisplayServer.FEATURE_SUBWINDOWS)
	close_requested.connect(func(): set_enabled(false))
	var root := PanelContainer.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.theme_type_variation = &"StudioPanel"
	root.theme = UI_THEME
	add_child(root)
	var box := VBoxContainer.new()
	root.add_child(box)
	var controls := HFlowContainer.new()
	box.add_child(controls)
	var mirror := CheckButton.new()
	mirror.text = "镜像"
	mirror.button_pressed = true
	controls.add_child(mirror)
	var points := CheckButton.new()
	points.text = "显示关键点"
	points.button_pressed = true
	controls.add_child(points)
	canvas = PreviewCanvas.new()
	canvas.mode = _mode
	canvas.clip_contents = true
	canvas.size_flags_vertical = Control.SIZE_EXPAND_FILL
	box.add_child(canvas)
	mirror.toggled.connect(func(value: bool): canvas.mirror = value; canvas.queue_redraw())
	points.toggled.connect(func(value: bool): canvas.landmarks = value; canvas.queue_redraw())
	_status = Label.new()
	_status.text = "开始捕捉后显示画面"
	_status.tooltip_text = "预览与动捕共用摄像头，不录像，也不包含在 OBS 角色输出中。\n青色：身体；绿色：手；金色：面部。"
	_status.add_theme_color_override("font_color", UI_THEME.get_color("muted", "Studio"))
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(_status)
	set_capture_mode(_mode)


func set_capture_mode(mode: String) -> void:
	_mode = "full_body" if mode == "full_body" else "vtuber"
	if canvas != null:
		canvas.mode = _mode
		canvas.queue_redraw()
	if _status != null:
		_status.text = ("全身动捕" if _mode == "full_body" else "VTuber") + " · 等待画面"


func set_enabled(enabled: bool) -> void:
	_enabled = enabled
	_receiver.set_preview_enabled(enabled)
	if enabled:
		popup_centered()
	else:
		hide()
		canvas.clear_frame()
	preview_changed.emit(enabled)


func _process(_delta: float) -> void:
	if not _enabled:
		return
	if not _receiver.is_running():
		canvas.clear_frame()
		_status.text = "捕捉未启动"
		return
	var data: Dictionary = _receiver.poll_preview()
	if not data.is_empty():
		canvas.update_frame(data)
		_status.text = "%s · %d × %d" % ["全身动捕" if _mode == "full_body" else "VTuber", data.image.get_width(), data.image.get_height()]
	elif canvas.last_update_ms >= 0 and Time.get_ticks_msec() - canvas.last_update_ms > 1000:
		canvas.clear_frame()
		_status.text = "等待画面…"


func _exit_tree() -> void:
	if _receiver != null:
		_receiver.set_preview_enabled(false)
