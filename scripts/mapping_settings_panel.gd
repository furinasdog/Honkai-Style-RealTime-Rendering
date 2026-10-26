extends Window

const SETTINGS = preload("res://scripts/mapping_settings.gd")
const UI_THEME = preload("res://scripts/ui_theme.tres")
const INK := "text"
const MUTED := "muted"
const ACCENT := "accent"

class ResponseCurve extends Control:
	var model
	var channel_id := "left_eye"
	func _process(_delta: float) -> void:
		if is_visible_in_tree():
			queue_redraw()
	func _draw() -> void:
		var box := Rect2(Vector2(8, 8), size - Vector2(16, 16))
		draw_rect(Rect2(Vector2.ZERO, size), get_theme_color("field", "Studio"))
		draw_rect(Rect2(Vector2.ZERO, size), get_theme_color("border", "Studio"), false, 1.0)
		if model == null or not model.channels.has(channel_id) or box.size.x <= 0 or box.size.y <= 0:
			return
		for line in 5:
			var t := float(line) / 4.0
			draw_line(box.position + Vector2(box.size.x * t, 0), box.position + Vector2(box.size.x * t, box.size.y), get_theme_color("grid", "Studio"))
			draw_line(box.position + Vector2(0, box.size.y * t), box.position + Vector2(box.size.x, box.size.y * t), get_theme_color("grid", "Studio"))
		var bipolar: bool = model.channels[channel_id].bipolar
		var floor := -1.0 if bipolar else 0.0
		var points := PackedVector2Array()
		for sample in 101:
			var x := float(sample) / 100.0
			var output: float = model.response_value(channel_id, lerpf(floor, 1.0, x))
			var y := (output - floor) / (1.0 - floor)
			points.append(box.position + Vector2(x * box.size.x, (1.0 - y) * box.size.y))
		draw_polyline(points, get_theme_color("text", "Studio"), 2.0, true)
		if model.input_values.has(channel_id):
			var raw := clampf(float(model.input_values[channel_id]), floor, 1.0)
			var output: float = model.output_values.get(channel_id, 0.0)
			var point := Vector2((raw - floor) / (1.0 - floor), 1.0 - (output - floor) / (1.0 - floor))
			draw_circle(box.position + point * box.size, 4.5, get_theme_color("accent", "Studio"))

var model
var selected_channel := "left_eye"
var _built := false
var _refreshing := false
var _tabs: TabBar
var _content: GridContainer
var _body_scroll: ScrollContainer
var _curve_layout: GridContainer
var _options: VBoxContainer
var _list: VBoxContainer
var _title: Label
var _description: Label
var _invert: CheckButton
var _curve: ResponseCurve
var _live: Label
var _save_status: Label
var _rows: Dictionary = {}
var _channel_buttons: Dictionary = {}
var _enabled_checks: Dictionary = {}
var _save_timer: Timer
var _available: Array = []
var _availability_set := false


func setup(settings) -> void:
	if model != null and model.changed.is_connected(_on_changed):
		model.changed.disconnect(_on_changed)
	model = settings
	if not _built:
		_build()
	model.changed.connect(_on_changed)
	_curve.model = model
	_change_tab(0)


func set_available_channels(ids: Array) -> void:
	_available = ids.duplicate()
	_availability_set = true
	_rebuild_list()
	_refresh()


func _ready() -> void:
	if not _built:
		_build()
	close_requested.connect(_close)


func _exit_tree() -> void:
	if model != null and _save_timer != null and not _save_timer.is_stopped():
		_save()


func _process(_delta: float) -> void:
	if visible and model != null:
		_live.text = "输入  %.3f     输出  %.3f" % [float(model.input_values.get(selected_channel, 0.0)), float(model.output_values.get(selected_channel, 0.0))]


func _build() -> void:
	_built = true
	title = "动作映射设置"
	size = Vector2i(820, 620)
	min_size = Vector2i(720, 570)
	transient = true
	visible = false
	var root := PanelContainer.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.theme_type_variation = &"StudioPanel"
	root.theme = UI_THEME
	add_child(root)
	var layout := VBoxContainer.new()
	layout.add_theme_constant_override("separation", 12)
	root.add_child(layout)
	_tabs = TabBar.new()
	for name in ["面部", "手臂与手", "选项"]:
		_tabs.add_tab(name)
	_tabs.tab_changed.connect(_change_tab)
	layout.add_child(_tabs)
	var body_scroll := ScrollContainer.new()
	_body_scroll = body_scroll
	body_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	body_scroll.follow_focus = true
	body_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	layout.add_child(body_scroll)
	var body := VBoxContainer.new()
	body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	body_scroll.add_child(body)
	_content = GridContainer.new()
	_content.columns = 2
	_content.add_theme_constant_override("h_separation", 22)
	_content.add_theme_constant_override("v_separation", 16)
	_content.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.add_child(_content)
	var scroll := ScrollContainer.new()
	scroll.follow_focus = true
	scroll.custom_minimum_size.x = 218
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_content.add_child(scroll)
	_list = VBoxContainer.new()
	_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_list)
	var right := VBoxContainer.new()
	right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right.add_theme_constant_override("separation", 8)
	_content.add_child(right)
	_title = _label(right, "左眼", 22, ACCENT)
	_description = _label(right, "", 13, MUTED)
	_description.custom_minimum_size.y = 26
	_invert = CheckButton.new()
	_invert.text = "反转"
	_invert.tooltip_text = "反转当前通道的动作方向。"
	_invert.toggled.connect(func(value: bool): _set_value("invert", value))
	right.add_child(_invert)
	_make_row(right, "smoothing", "平滑时间", 0.0, 0.5, 0.01, " 秒")
	_rows.smoothing.spin.tooltip_text = "数值越大，抖动越少，延迟越大。单位：秒。"
	_make_row(right, "sensitivity", "灵敏度", 0.1, 3.0, 0.05)
	_rows.sensitivity.spin.tooltip_text = "调整当前通道的动作响应幅度。"
	_make_row(right, "curvature", "曲率", 0.0, 1.0, 0.01)
	_rows.curvature.spin.tooltip_text = "0 为线性；越大越接近陡峭的 Sigmoid S 形。睁眼、闭眼阈值保持不变。"
	_make_row(right, "precision", "精度", 0, 200, 1, " 级")
	_rows.precision.spin.tooltip_text = "0 为连续输出；其他数值为每单位的量化级数。"
	for field in ["smoothing", "sensitivity", "curvature", "precision"]:
		_rows[field].slider.tooltip_text = _rows[field].spin.tooltip_text
		_rows[field].label.tooltip_text = _rows[field].spin.tooltip_text
	var range := GridContainer.new()
	_curve_layout = range
	range.columns = 2
	range.add_theme_constant_override("h_separation", 16)
	range.add_theme_constant_override("v_separation", 12)
	range.size_flags_vertical = Control.SIZE_EXPAND_FILL
	right.add_child(range)
	_curve = ResponseCurve.new()
	_curve.custom_minimum_size = Vector2(178, 124)
	_curve.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_curve.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	range.add_child(_curve)
	var thresholds := VBoxContainer.new()
	thresholds.custom_minimum_size.x = 220
	thresholds.alignment = BoxContainer.ALIGNMENT_CENTER
	thresholds.add_theme_constant_override("separation", 16)
	range.add_child(thresholds)
	_make_row(thresholds, "upper", "闭眼阈值", 0.01, 1.0, 0.01)
	_make_row(thresholds, "lower", "睁眼阈值", 0.0, 0.99, 0.01)
	_live = _label(right, "输入  0.000     输出  0.000", 14, ACCENT)
	var actions := HBoxContainer.new()
	right.add_child(actions)
	_button(actions, "重置当前通道", _reset_selected)
	_options = VBoxContainer.new()
	_options.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_options.add_theme_constant_override("separation", 16)
	body.add_child(_options)
	_label(_options, "设置自动保存", 17, INK)
	var hint := _label(_options, "悬停参数查看说明。", 14, MUTED)
	hint.tooltip_text = "左右眼可分别校准。睁眼阈值应小于闭眼阈值。\n平滑时间越长，抖动越少、延迟越大；精度为 0 时连续输出。"
	_button(_options, "恢复所有默认设置", func(): model.reset_defaults())
	var footer := HBoxContainer.new()
	layout.add_child(footer)
	_save_status = _label(footer, "设置自动保存", 13, MUTED)
	_save_status.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_button(footer, "关闭", _close)
	_save_timer = Timer.new()
	_save_timer.one_shot = true
	_save_timer.wait_time = 0.35
	_save_timer.timeout.connect(_save)
	add_child(_save_timer)
	_body_scroll.resized.connect(_update_layout)
	_update_layout.call_deferred()


func _update_layout() -> void:
	var narrow := _body_scroll.size.x < 700.0
	_content.columns = 1 if narrow else 2
	var list_scroll := _list.get_parent() as ScrollContainer
	list_scroll.custom_minimum_size.y = 200.0 if narrow else 0.0
	_curve_layout.columns = 1 if _body_scroll.size.x < 460.0 else 2


func _make_row(parent: Node, field: String, label: String, low: float, high: float, step: float, suffix: String = "") -> void:
	var box: BoxContainer = HBoxContainer.new() if field not in ["lower", "upper"] else VBoxContainer.new()
	parent.add_child(box)
	var heading := _label(box, label, 14, INK)
	if box is HBoxContainer:
		heading.custom_minimum_size.x = 82
	var controls := HBoxContainer.new()
	controls.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.add_child(controls)
	var slider := HSlider.new()
	slider.min_value = low
	slider.max_value = high
	slider.step = step
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slider.value_changed.connect(func(value: float): _set_value(field, value))
	controls.add_child(slider)
	var spin := SpinBox.new()
	spin.min_value = low
	spin.max_value = high
	spin.step = step
	spin.suffix = suffix
	spin.custom_minimum_size.x = 84
	spin.value_changed.connect(func(value: float): _set_value(field, value))
	controls.add_child(spin)
	_rows[field] = {"slider": slider, "spin": spin, "label": heading}


func _change_tab(index: int) -> void:
	if _content == null:
		return
	_content.visible = index != 2
	_options.visible = index == 2
	if index != 2 and model != null:
		if index == 0 and SETTINGS.DEFINITIONS[selected_channel].group != "face":
			selected_channel = "left_eye"
		elif index == 1 and SETTINGS.DEFINITIONS[selected_channel].group != "hands":
			selected_channel = "left_arm"
		_rebuild_list()
		_refresh()


func _rebuild_list() -> void:
	if _list == null or model == null:
		return
	for child in _list.get_children():
		_list.remove_child(child)
		child.queue_free()
	_channel_buttons.clear()
	_enabled_checks.clear()
	var group := "hands" if _tabs.current_tab == 1 else "face"
	for id: String in SETTINGS.DEFINITIONS:
		var definition: Dictionary = SETTINGS.DEFINITIONS[id]
		if definition.group != group:
			continue
		var row := HBoxContainer.new()
		_list.add_child(row)
		var select := Button.new()
		select.text = definition.label
		select.alignment = HORIZONTAL_ALIGNMENT_LEFT
		select.toggle_mode = true
		select.flat = true
		select.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		select.custom_minimum_size.y = 34
		select.pressed.connect(_select.bind(id))
		row.add_child(select)
		var enabled := CheckBox.new()
		enabled.set_pressed_no_signal(model.channels[id].enabled)
		enabled.toggled.connect(func(value: bool): model.set_channel_value(id, "enabled", value))
		row.add_child(enabled)
		_channel_buttons[id] = select
		_enabled_checks[id] = enabled
		if not _channel_available(id):
			select.disabled = true
			enabled.disabled = true
			select.tooltip_text = "当前模型没有对应骨骼或表情"
	if not _channel_available(selected_channel):
		for id: String in _channel_buttons:
			if _channel_available(id):
				selected_channel = id
				break


func _select(id: String) -> void:
	selected_channel = id
	_refresh()


func _refresh() -> void:
	if model == null or not model.channels.has(selected_channel):
		return
	_refreshing = true
	var channel: Dictionary = model.channels[selected_channel]
	var supported := _channel_available(selected_channel)
	_title.text = SETTINGS.DEFINITIONS[selected_channel].label
	_description.text = "在睁眼与闭眼阈值间过渡。" if selected_channel in ["left_eye", "right_eye"] else "圆点表示当前输入与输出。"
	if not supported:
		_description.text = "当前模型不支持此通道。"
	_invert.set_pressed_no_signal(channel.invert)
	_invert.disabled = not supported
	for field: String in _rows:
		var row: Dictionary = _rows[field]
		if field == "lower":
			row.slider.min_value = -1.0 if channel.bipolar else 0.0
			row.spin.min_value = row.slider.min_value
			row.slider.max_value = channel.upper - SETTINGS.MIN_RANGE
			row.spin.max_value = row.slider.max_value
		elif field == "upper":
			row.slider.min_value = channel.lower + SETTINGS.MIN_RANGE
			row.spin.min_value = row.slider.min_value
		row.slider.set_value_no_signal(float(channel[field]))
		row.spin.set_value_no_signal(float(channel[field]))
		row.slider.editable = supported
		row.spin.editable = supported
	_rows.lower.label.text = "睁眼阈值" if selected_channel in ["left_eye", "right_eye"] else "输入下限"
	_rows.upper.label.text = "闭眼阈值" if selected_channel in ["left_eye", "right_eye"] else "输入上限"
	for id: String in _channel_buttons:
		_channel_buttons[id].set_pressed_no_signal(id == selected_channel)
		_enabled_checks[id].set_pressed_no_signal(model.channels[id].enabled)
	_curve.channel_id = selected_channel
	_curve.queue_redraw()
	_refreshing = false


func _channel_available(id: String) -> bool:
	return not _availability_set or id in _available


func _set_value(field: String, value: Variant) -> void:
	if not _refreshing and model != null:
		model.set_channel_value(selected_channel, field, value)


func _on_changed(_id: String) -> void:
	_refresh()
	_save_status.text = "正在保存…"
	_save_timer.start()


func _save() -> void:
	var result: Error = model.save()
	_save_status.text = "已保存" if result == OK else "保存失败：" + error_string(result)
	_save_status.add_theme_color_override("font_color", UI_THEME.get_color("muted" if result == OK else "error", "Studio"))
	_save_timer.stop()


func _close() -> void:
	if not _save_timer.is_stopped():
		_save()
	hide()


func _reset_selected() -> void:
	var defaults = SETTINGS.new()
	model.channels[selected_channel] = defaults.channels[selected_channel].duplicate(true)
	model.reset_filters(selected_channel)
	model.changed.emit(selected_channel)


func _label(parent: Node, text: String, font_size: int, color: String) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", UI_THEME.get_color(color, "Studio"))
	parent.add_child(label)
	return label


func _button(parent: Node, text: String, callback: Callable) -> Button:
	var button := Button.new()
	button.text = text
	button.pressed.connect(callback)
	parent.add_child(button)
	return button
