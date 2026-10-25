extends SceneTree


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	create_timer(30.0).timeout.connect(func(): quit(1))
	assert(GDExtensionManager.load_extension("res://native/mocap.gdextension") == GDExtensionManager.LOAD_STATUS_OK)
	assert(ClassDB.class_exists("NativeMocap"))
	var native = ClassDB.instantiate("NativeMocap")
	assert(native != null)
	var models: Array = []
	for name in ["pose_landmarker_lite.task", "hand_landmarker.task", "face_landmarker.task"]:
		models.append(FileAccess.get_file_as_bytes("res://mocap/models/" + name))
	assert(native.initialize(models), native.get_error())
	assert(not native.is_running(), "Loading models must not open a webcam")
	var blank := Image.create(160, 120, false, Image.FORMAT_RGB8)
	blank.fill(Color.BLACK)
	var packet = native.detect_rgb(blank.get_data(), 160, 120, 1000)
	assert(packet is PackedFloat32Array and packet.size() == 590, native.get_error())
	assert(packet[0] == 0 and packet[1] == 0 and packet[2] == 0, "Blank frames must report tracking loss")
	var report := {"backend": "native C++ MediaPipe C API", "python_process": false, "camera_opened": false, "blank_frame": true, "fixtures": {}}
	var timestamp := 1100
	for item in [["pose.jpg", 0], ["thumb_up.jpg", 1], ["portrait.jpg", 2]]:
		var image := Image.load_from_file("res://mocap/test_data/" + str(item[0]))
		assert(image != null)
		image.convert(Image.FORMAT_RGB8)
		packet = native.detect_rgb(image.get_data(), image.get_width(), image.get_height(), timestamp)
		assert(packet is PackedFloat32Array and packet.size() == 590, native.get_error())
		assert(packet[int(item[1])] > 0, "Real native inference did not detect " + str(item[0]))
		for value in packet:
			assert(is_finite(value))
		report.fixtures[item[0]] = {"pose": packet[0] > 0, "hands": int(packet[1]), "face": packet[2] > 0, "matrix": packet[3] > 0}
		assert(native.get_timestamp_ms() == timestamp)
		timestamp += 100
	assert(native.start_camera(255, 640, 480, 30), "Invalid-index lifecycle check could not start its worker")
	var deadline := Time.get_ticks_msec() + 5000
	while native.is_running() and Time.get_ticks_msec() < deadline:
		await process_frame
	assert(not native.is_running() and not native.get_error().is_empty(), "A missing camera must report failure and finish its worker")
	native.stop()
	native.stop()
	assert(not native.is_running())
	report["invalid_camera_worker_closed"] = true
	native = null
	var file := FileAccess.open("res://outputs/native_mediapipe_validation.json", FileAccess.WRITE)
	file.store_string(JSON.stringify(report, "\t"))
	print("NATIVE_MEDIAPIPE_PASS ", JSON.stringify(report))
	quit(0)
