extends PanelContainer

var body: VBoxContainer
var collapsed := false
var _header: PanelContainer
var _title: Label
var _toggle: Button
var _dragging := false
var _expanded_position := Vector2(24, 24)
var _built := false


func setup(title: String) -> void:
	_build()
	_title.text = title


func _ready() -> void:
	_build()


func _build() -> void:
	if _built:
		return
	_built = true
	mouse_filter = Control.MOUSE_FILTER_STOP
	var layout := VBoxContainer.new()
	layout.add_theme_constant_override("separation", 10)
	add_child(layout)
	_header = PanelContainer.new()
	_header.mouse_default_cursor_shape = Control.CURSOR_MOVE
	_header.gui_input.connect(_header_input)
	layout.add_child(_header)
	var bar := HBoxContainer.new()
	bar.mouse_filter = Control.MOUSE_FILTER_PASS
	_header.add_child(bar)
	_title = Label.new()
	_title.text = "控制面板"
	_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_title.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_title.add_theme_font_size_override("font_size", 19)
	bar.add_child(_title)
	_toggle = Button.new()
	_toggle.text = "收起"
	_toggle.pressed.connect(func(): set_collapsed(not collapsed))
	bar.add_child(_toggle)
	body = VBoxContainer.new()
	body.add_theme_constant_override("separation", 10)
	layout.add_child(body)


func set_collapsed(value: bool) -> void:
	_build()
	if value == collapsed:
		return
	collapsed = value
	if collapsed:
		_expanded_position = position
		body.hide()
		position.y = 8.0
	else:
		body.show()
		position = _expanded_position
	_toggle.text = "展开" if collapsed else "收起"
	size = get_combined_minimum_size()
	_keep_on_screen()


func _header_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		_dragging = event.pressed
		_header.accept_event()
	elif event is InputEventMouseMotion:
		if not event.button_mask & MOUSE_BUTTON_MASK_LEFT:
			_dragging = false
		if not _dragging:
			return
		if collapsed:
			var minimized_position := position
			set_collapsed(false)
			position = minimized_position
		position += event.relative
		_keep_on_screen()
		_expanded_position = position
		_header.accept_event()


func _keep_on_screen() -> void:
	if not is_inside_tree():
		return
	var viewport_size := get_viewport_rect().size
	position.x = clampf(position.x, 0.0, maxf(0.0, viewport_size.x - size.x))
	position.y = clampf(position.y, 0.0, maxf(0.0, viewport_size.y - _header.size.y - 12.0))
