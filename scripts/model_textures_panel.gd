extends Window

var _renderer: HonkaiMMDMaterials
var _materials: OptionButton
var _roles: OptionButton
var _status: Label
var _preview: TextureRect
var _dialog: FileDialog
var _choose: Button
var _remove: Button
var _ids: Array[String] = []
var _role_ids: Array[String] = []


func _ready() -> void:
	title = "增强贴图"
	size = Vector2i(560, 420)
	min_size = Vector2i(420, 340)
	visible = false
	transient = true
	transparent = false
	close_requested.connect(hide)
	var panel := PanelContainer.new()
	panel.theme = preload("res://scripts/ui_theme.tres")
	panel.add_theme_stylebox_override("panel", panel.theme.get_stylebox("panel", "StudioPanel").duplicate())
	panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(panel)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 14)
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	panel.add_child(scroll)
	scroll.add_child(box)
	_materials = OptionButton.new()
	_materials.item_selected.connect(func(_index: int): _refresh_roles())
	box.add_child(_materials)
	_roles = OptionButton.new()
	_roles.item_selected.connect(func(_index: int): _refresh_preview())
	box.add_child(_roles)
	var actions := HBoxContainer.new()
	box.add_child(actions)
	_choose = Button.new()
	_choose.theme_type_variation = "PrimaryButton"
	_choose.text = "导入贴图…"
	_choose.pressed.connect(func():
		if not _ids.is_empty() and not _role_ids.is_empty():
			_dialog.popup_centered_ratio(0.65))
	actions.add_child(_choose)
	_remove = Button.new()
	_remove.text = "移除"
	_remove.pressed.connect(func():
		if not _ids.is_empty() and not _role_ids.is_empty():
			_renderer.remove_custom_map(_ids[_materials.selected], _role_ids[_roles.selected])
			_refresh_preview())
	actions.add_child(_remove)
	_status = Label.new()
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(_status)
	_preview = TextureRect.new()
	_preview.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_preview.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_preview.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_preview.custom_minimum_size = Vector2(0, 160)
	box.add_child(_preview)
	_dialog = FileDialog.new()
	_dialog.theme = panel.theme
	_dialog.title = "导入增强贴图"
	_dialog.access = FileDialog.ACCESS_FILESYSTEM
	_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	_dialog.filters = PackedStringArray(["*.png,*.tga,*.jpg,*.jpeg,*.bmp,*.webp ; 图像贴图"])
	_dialog.file_selected.connect(_import_texture)
	add_child(_dialog)


func set_renderer(renderer: HonkaiMMDMaterials) -> void:
	_renderer = renderer
	_dialog.hide()
	_ids.clear()
	_materials.clear()
	for slot in renderer.material_slots:
		if slot.kind == "eye":
			continue
		_ids.append(slot.id)
		_materials.add_item(slot.name)
	if _ids.is_empty():
		_materials.add_item("未加载模型")
	_refresh_roles()


func _refresh_roles() -> void:
	_role_ids.clear()
	_roles.clear()
	if not _ids.is_empty():
		var kind := ""
		for slot in _renderer.material_slots:
			if slot.id == _ids[_materials.selected]:
				kind = slot.kind
		for role: String in HonkaiMMDMaterials.MAP_ROLES:
			if (role in ["face_map", "face_sdf"]) != (kind == "face"):
				continue
			_role_ids.append(role)
			_roles.add_item(HonkaiMMDMaterials.MAP_ROLES[role])
	if _role_ids.is_empty():
		_roles.add_item("选择贴图用途")
	_refresh_preview()


func _refresh_preview() -> void:
	_preview.texture = null
	_materials.disabled = _ids.is_empty()
	_roles.disabled = _role_ids.is_empty()
	_choose.disabled = _ids.is_empty() or _role_ids.is_empty()
	_remove.disabled = true
	if _ids.is_empty() or _role_ids.is_empty():
		_status.text = "先导入角色。"
		return
	_roles.tooltip_text = {"face_map": "R 区域（低值为脸部）、G 遮蔽、B 鼻线、A 阴影 SDF。", "face_sdf": "灰度阴影阈值，需匹配当前材质 UV；左右光自动镜像。", "light_map": "R 遮蔽、G 明暗阈值、B 高光、A 材质分区。", "warm_ramp": "暖色带：身体 8 行、头发 1 行。", "cool_ramp": "冷色带：身体 8 行、头发 1 行。", "highlight_map": "灰度高光遮罩，替代自动高光遮罩。"}[_role_ids[_roles.selected]]
	var maps = _renderer.custom_maps.get(_ids[_materials.selected], {})
	var entry = maps.get(_role_ids[_roles.selected], {}) if maps is Dictionary else {}
	if not entry is Dictionary:
		entry = {}
	_remove.disabled = entry.is_empty()
	_status.text = str(entry.get("name", "未导入；使用自动辅助图或原始方案。"))
	if not _renderer.enhanced:
		_status.text += "　增强表现已关闭。"
	var path := str(entry.get("path", ""))
	if path.begins_with("user://render_maps/imported/") and not ".." in path and FileAccess.file_exists(path):
		var image := Image.new()
		if image.load(path) == OK:
			_preview.texture = ImageTexture.create_from_image(image)


func _import_texture(path: String) -> void:
	if _ids.is_empty() or _role_ids.is_empty():
		return
	if not _renderer.import_custom_map(_ids[_materials.selected], _role_ids[_roles.selected], path):
		_status.text = _renderer.map_error
		return
	_refresh_preview()
