extends SceneTree

const RECEIVER = preload("res://scripts/native_mocap.gd")

class FakeNative extends RefCounted:
	var sizes := []
	var active := false
	var starts := 0
	func initialize(models: Array) -> bool:
		sizes.append(models[0].size())
		return true
	func is_running() -> bool:
		return active
	func start_camera(_device: int, _width: int, _height: int, _fps: int) -> bool:
		starts += 1
		active = true
		return true
	func stop() -> void:
		active = false
	func get_error() -> String:
		return ""


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	create_timer(35).timeout.connect(func(): quit(1))
	var receiver := RECEIVER.new()
	var fake := FakeNative.new()
	receiver._native = fake
	var options := {"device": 0, "width": 640, "height": 480, "fps": 30}
	assert(receiver.start(options) and receiver.pose_model == "full")
	assert(fake.sizes == [9398198] and fake.starts == 1)
	assert(not receiver.start(options.merged({"pose_model": "lite"})))
	assert(fake.active and fake.sizes.size() == 1 and receiver.pose_model == "full", "A model change must not silently stop an active capture")
	receiver.stop()
	assert(receiver.start(options.merged({"pose_model": "lite"})) and receiver.pose_model == "lite")
	assert(fake.sizes == [9398198, 5777746] and fake.starts == 2)
	receiver.stop()
	assert(receiver.start(options.merged({"pose_model": "lite"})))
	assert(fake.sizes.size() == 2 and fake.starts == 3, "The same model must not be initialized again on every start")
	assert(not receiver.start(options.merged({"pose_model": "../../other"})))
	assert(not receiver.get_error().is_empty() and fake.active and receiver.pose_model == "lite")
	receiver.close()
	assert(not fake.active and receiver.pose_model.is_empty())
	var actual := RECEIVER.new()
	var fixture := "res://mocap/test_data/pose.jpg"
	var args := OS.get_cmdline_user_args()
	if not args.is_empty():
		fixture = args[0]
		assert(FileAccess.file_exists(fixture), "The explicitly selected image must exist")
	var positive_fixture := FileAccess.file_exists(fixture)
	var image: Image
	if positive_fixture:
		image = Image.load_from_file(fixture)
		assert(image != null)
	else:
		image = Image.create(160, 120, false, Image.FORMAT_RGB8)
		image.fill(Color.BLACK)
	image.convert(Image.FORMAT_RGB8)
	for selected in ["full", "lite", "full"]:
		assert(actual._prepare_pose_model(selected), actual.get_error())
		assert(actual.pose_model == selected and not actual.is_running())
		var packet = actual._native.detect_rgb(image.get_data(), image.get_width(), image.get_height(), 1000)
		assert(packet is PackedFloat32Array and packet.size() == 590, actual.get_error())
		var frame := RECEIVER.decode_frame(packet, 1, 1000)
		if positive_fixture:
			assert(packet[0] > 0.5 and frame.pose.world.size() == 33 and frame.pose.image.size() == 33)
		else:
			assert(packet[0] == 0 and frame.pose == null, "Blank input must report tracking loss")
		assert(preload("res://scripts/mocap_retarget.gd").new()._valid_frame(frame))
	actual.close()
	print("POSE_MODELS_PASS Full/Lite/Full native offline inference, cache, active-switch guard, invalid selection; positive_33_landmark_fixture=", positive_fixture, "; no camera opened")
	quit(0)
