extends Node

signal failed(message: String)

var enabled := false
var frame_rate := 30
var _source: SubViewport
var _native: RefCounted
var _rd: RenderingDevice
var _export_texture: RID
var _next_copy_us := 0
var _copy_due := false
var _copied := false
var _mutex := Mutex.new()
var _error := ""
var _frames := 0


func start(viewport: SubViewport, fps: int) -> Error:
	stop()
	if RenderingServer.get_current_rendering_driver_name() != "d3d12":
		return ERR_UNAVAILABLE
	if not ClassDB.class_exists("NativeSpoutOutput"):
		var result := GDExtensionManager.load_extension("res://native/mocap.gdextension")
		if result not in [GDExtensionManager.LOAD_STATUS_OK, GDExtensionManager.LOAD_STATUS_ALREADY_LOADED]:
			return ERR_CANT_OPEN
	_native = ClassDB.instantiate("NativeSpoutOutput")
	if _native == null:
		return ERR_CANT_CREATE
	_source = viewport
	frame_rate = clampi(fps, 1, 60)
	_error = ""
	_frames = 0
	_next_copy_us = 0
	enabled = true
	RenderingServer.frame_pre_draw.connect(_before_draw)
	RenderingServer.frame_post_draw.connect(_after_draw)
	return OK


func stop() -> void:
	enabled = false
	if RenderingServer.frame_pre_draw.is_connected(_before_draw):
		RenderingServer.frame_pre_draw.disconnect(_before_draw)
	if RenderingServer.frame_post_draw.is_connected(_after_draw):
		RenderingServer.frame_post_draw.disconnect(_after_draw)
	if _native != null:
		# Submit any recorded RD copy before retiring externally owned D3D12 resources.
		RenderingServer.force_draw(false, 0.0)
		var finished := Semaphore.new()
		RenderingServer.call_on_render_thread(func(): _render_close(); finished.post())
		finished.wait()
	_native = null
	_source = null
	_copy_due = false
	_copied = false


func _exit_tree() -> void:
	stop()


func _process(delta: float) -> void:
	_mutex.lock()
	var error := _error
	_mutex.unlock()
	if enabled and not error.is_empty():
		stop()
		failed.emit(error)
	if enabled and get_tree().root.mode == Window.MODE_MINIMIZED and Time.get_ticks_usec() >= _next_copy_us:
		RenderingServer.force_draw(false, delta)


func get_frames() -> int:
	_mutex.lock()
	var result := _frames
	_mutex.unlock()
	return result


func _before_draw() -> void:
	if not enabled or not is_instance_valid(_source):
		return
	var now := Time.get_ticks_usec()
	var period := int(1000000.0 / frame_rate)
	_copy_due = now >= _next_copy_us
	if not _copy_due:
		return
	if now > _next_copy_us + period * 2:
		_next_copy_us = now
	_next_copy_us += period
	_source.render_target_update_mode = SubViewport.UPDATE_ONCE
	RenderingServer.call_on_render_thread(_render_copy.bind(_source.get_texture().get_rid(), _source.size))


func _after_draw() -> void:
	if enabled and _copy_due:
		RenderingServer.call_on_render_thread(_render_send)


func _render_copy(source: RID, dimensions: Vector2i) -> void:
	if _rd == null:
		_rd = RenderingServer.get_rendering_device()
	var source_rd := RenderingServer.texture_get_rd_texture(source, false)
	if not source_rd.is_valid():
		return
	if not _export_texture.is_valid():
		var pointer := int(_native.create(_rd.get_driver_resource(RenderingDevice.DRIVER_RESOURCE_LOGICAL_DEVICE, RID(), 0), _rd.get_driver_resource(RenderingDevice.DRIVER_RESOURCE_COMMAND_QUEUE, RID(), 0), dimensions.x, dimensions.y))
		if pointer == 0:
			_set_error(str(_native.get_error()))
			return
		_export_texture = _rd.texture_create_from_extension(RenderingDevice.TEXTURE_TYPE_2D, RenderingDevice.DATA_FORMAT_R8G8B8A8_UNORM, RenderingDevice.TEXTURE_SAMPLES_1, RenderingDevice.TEXTURE_USAGE_COLOR_ATTACHMENT_BIT | RenderingDevice.TEXTURE_USAGE_CAN_COPY_TO_BIT, pointer, dimensions.x, dimensions.y, 1, 1, 1)
		if not _export_texture.is_valid():
			_set_error("无法将 Spout RGBA 纹理接入渲染器。")
			return
	var result := _rd.texture_copy(source_rd, _export_texture, Vector3.ZERO, Vector3.ZERO, Vector3(dimensions.x, dimensions.y, 1), 0, 0, 0, 0)
	if result != OK:
		_set_error("输出纹理复制失败：" + error_string(result))
		return
	_copied = true


func _render_send() -> void:
	if not _copied:
		return
	if not bool(_native.send()):
		_set_error(str(_native.get_error()))
		return
	_mutex.lock()
	_frames += 1
	_mutex.unlock()


func _render_close() -> void:
	if _export_texture.is_valid():
		_rd.free_rid(_export_texture)
		_export_texture = RID()
	_native.close()
	_rd = null


func _set_error(message: String) -> void:
	_mutex.lock()
	_error = message if not message.is_empty() else "Spout 输出初始化失败。"
	_mutex.unlock()
