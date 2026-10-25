extends SceneTree

const ADAPTER = preload("res://scripts/native_mocap.gd")


func _initialize() -> void:
	var data := PackedFloat32Array()
	data.resize(590)
	data[0] = 1.0
	data[1] = 2.0
	data[2] = 1.0
	data[268] = 0.0
	data[395] = 1.0
	data[4] = 0.25
	data[136] = 0.75
	data[269] = 0.1
	data[332] = 0.9
	data[522 + 9] = 0.8
	var frame := ADAPTER.decode_frame(data, 4, 1000)
	var retarget = preload("res://scripts/mocap_retarget.gd").new()
	assert(retarget._valid_frame(frame), "Native layout must satisfy the actual retarget consumer")
	assert(frame.pose.world.size() == 33 and frame.pose.world[0][0] == 0.25)
	assert(frame.pose.image[0][0] == 0.75)
	assert(frame.hands[0].side == "Left" and frame.hands[1].side == "Right")
	assert(is_equal_approx(frame.hands[0].world[0][0], 0.1))
	assert(is_equal_approx(frame.hands[0].image[0][0], 0.9))
	assert(is_equal_approx(frame.face.blendshapes.eyeBlinkLeft, 0.8))
	assert(frame.face.matrix[0] == 1.0 and frame.face.matrix.size() == 16)
	data[3] = 1.0
	data[574 + 3] = 2.0
	frame = ADAPTER.decode_frame(data, 5, 1001)
	assert(frame.face.matrix[3] == 2.0, "Face transforms must retain row-major translation")
	assert(ADAPTER.decode_frame(PackedFloat32Array(), 1, 1).is_empty())
	data[10] = NAN
	assert(ADAPTER.decode_frame(data, 1, 1).is_empty())
	print("NATIVE_ADAPTER_PASS: layout, handedness, face matrix fallback and invalid frame rejection")
	quit(0)
