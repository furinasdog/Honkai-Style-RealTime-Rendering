extends SceneTree


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	create_timer(15.0).timeout.connect(func(): quit(1))
	var world := Node3D.new()
	root.add_child(world)
	var rig := Skeleton3D.new()
	world.add_child(rig)
	var data := {"rigid_bodies": [], "joints": []}
	for index in 3:
		rig.add_bone("Coat%d" % index)
		var x: float = [0.0, 0.05, 0.6][index]
		rig.set_bone_rest(index, Transform3D(Basis.IDENTITY, Vector3(x, 1, 0)))
		data.rigid_bodies.append({"name": "Coat%d" % index, "bone": "Coat%d" % index, "type": 1, "shape": "box", "size": [0.1,0.1,0.03], "position": [x,1,0], "rotation": [0,0,0,1], "mass": 1.0, "collision_group": 3, "collision_mask": 8})
	rig.reset_bone_poses()
	var physics_path := "res://scripts/mmd_physics.gd"
	if not OS.get_cmdline_user_args().is_empty():
		physics_path = OS.get_cmdline_user_args()[0]
	var setup = load(physics_path).new()
	assert(setup.apply(rig, world, data))
	assert(setup.bodies[1] in setup.bodies[0].get_collision_exceptions(), "Authored interpenetrating cloth boxes must not push the cape upward at rest")
	assert(not setup.bodies[2] in setup.bodies[0].get_collision_exceptions(), "Separated cloth must retain future self-collision")
	var a := {"source": {"shape": "box", "size": [0.1,0.01,0.01]}, "rest_world": Transform3D.IDENTITY}
	var b: Dictionary = a.duplicate(true)
	b.rest_world.origin.z = 0.03
	assert(not setup._rest_overlap(a,b), "A bounding-sphere test falsely disables separated thin cloth boxes")
	b.rest_world.origin.z = 0.01
	assert(setup._rest_overlap(a,b))
	a.source.size[2] = 0.0
	b = a.duplicate(true)
	assert(setup._rest_overlap(a,b), "Zero-thickness PMX boxes must use the same minimum thickness as their Jolt shapes")
	setup.set_body_collision_assistance(false)
	assert(setup.bodies[1] in setup.bodies[0].get_collision_exceptions(), "Rest overlap protection is independent of optional hair assistance")
	setup.dispose()
	await process_frame
	world.free()
	print("CLOTH_CONTACTS_PASS rest-overlap exclusion, thin-box separation, future collisions and assistance toggle")
	quit()
