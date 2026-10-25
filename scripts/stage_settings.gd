extends Node

signal message(text: String)

var transparent: bool = true
var background_color := Color(0.075, 0.088, 0.13)
var asset_path: String = ""
var _environment: Environment
var _floor: Node3D
var _viewport: Viewport
var _window: Window
var _scene_parent: Node3D
var _extra: Node3D
var _background: CanvasLayer
var _image: TextureRect


func setup(scene: Node3D) -> void:
	_viewport = scene.get_viewport()
	_window = scene.get_window()
	_window.transparent = true
	_viewport.transparent_bg = true
	_environment = scene.get_node("Environment").environment
	_floor = scene.get_node("Floor")
	_scene_parent = scene
	_background = CanvasLayer.new()
	_background.layer = -10
	_background.name = "UserBackground"
	scene.add_child(_background)
	_image = TextureRect.new()
	_image.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_image.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_image.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	_background.add_child(_image)
	_image.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_apply()


func set_background_color(color: Color) -> void:
	background_color = Color(color.r, color.g, color.b, 1.0)
	_apply()


func set_transparent(enabled: bool) -> void:
	transparent = enabled
	_window.transparent = enabled
	_viewport.transparent_bg = enabled
	_apply()


func load_asset(path: String) -> bool:
	var extension := path.get_extension().to_lower()
	if extension in ["png", "jpg", "jpeg", "webp"]:
		var source := Image.new()
		if source.load(path) != OK:
			message.emit("背景图片无法读取，原场景已保留。")
			return false
		clear_asset()
		_image.texture = ImageTexture.create_from_image(source)
	elif extension in ["glb", "gltf"]:
		var document := GLTFDocument.new()
		var state := GLTFState.new()
		if document.append_from_file(path, state) != OK:
			message.emit("场景无法读取，原场景已保留。")
			return false
		var candidate := document.generate_scene(state) as Node3D
		if candidate == null:
			return false
		clear_asset()
		_extra = candidate
		_scene_parent.add_child(_extra)
		for node in candidate.find_children("*", "GeometryInstance3D", true, false):
			node.layers = 2
		for node in candidate.find_children("*", "Camera3D", true, false):
			node.clear_current(false)
	else:
		message.emit("场景支持 GLB/GLTF，图片背景支持 PNG/JPG/WebP。")
		return false
	asset_path = path
	_apply()
	message.emit("已添加场景：" + path.get_file())
	return true


func clear_asset() -> void:
	if is_instance_valid(_extra):
		_extra.queue_free()
	_extra = null
	if _image != null:
		_image.texture = null
	asset_path = ""
	if _environment != null:
		_apply()


func _apply() -> void:
	_environment.background_mode = Environment.BG_CLEAR_COLOR if transparent else Environment.BG_COLOR
	_environment.background_color = background_color
	RenderingServer.set_default_clear_color(Color(0, 0, 0, 0) if transparent else background_color)
	_floor.visible = false
	_background.visible = not transparent and _image.texture != null
	if is_instance_valid(_extra):
		_extra.visible = not transparent
