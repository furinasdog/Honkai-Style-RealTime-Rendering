extends SceneTree

const FIXTURE = preload("res://tests/test_mocap_retarget.gd")


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	create_timer(10).timeout.connect(func(): quit(1))
	var model := FIXTURE._synthetic_model()
	root.add_child(model)
	var rig: Skeleton3D = model.get_child(0)
	rig.reset_bone_poses()
	var mesh: MeshInstance3D = model.get_child(1)
	var right := mesh.find_blend_shape_by_name("ウィンク右")
	mesh.mesh.set_blend_shape_name(right, "unsupported_right")
	var retarget = preload("res://scripts/mocap_retarget.gd").new()
	assert(retarget.apply(rig, model))
	var packet := {"version": 1, "seq": 1, "timestamp_ms": 33, "pose": null, "hands": [], "face": {"blendshapes": {"eyeBlinkLeft": 1.0, "eyeBlinkRight": 0.0}, "matrix": [1,0,0,0,0,1,0,0,0,0,1,0,0,0,0,1]}}
	assert(retarget.ingest(packet))
	assert(is_equal_approx(retarget._morph_targets["まばたき"], 0.5))
	assert(is_zero_approx(retarget._morph_targets["ウィンク"]), "Fallback blink must not also apply the remaining single-eye morph")
	var fixture := FIXTURE.new()
	var hand: Dictionary = fixture._hand(rig, "左")
	for i in 21:
		hand.world[i] = [0.0, 0.0, 0.0]
	packet.face = null
	packet.hands = [hand]
	packet.seq += 1
	packet.timestamp_ms += 33
	assert(retarget.ingest(packet))
	assert(not retarget.tracking.left_hand and retarget.tracking.hands == 0, "A collapsed palm must not count as tracked or drive fingers")
	fixture.free()
	model.free()
	print("PARTIAL_TRACKING_PASS single-eye fallback without double closure and degenerate palm rejection")
	quit()
