extends SceneTree


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	create_timer(30.0).timeout.connect(func(): quit(1))
	var args := OS.get_cmdline_user_args()
	assert(args.size() == 1)
	var metadata: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(args[0]))
	var scene = load("res://scenes/main.tscn").instantiate()
	root.add_child(scene)
	await process_frame
	scene._preferences_ready = false
	assert(scene._adopt_model(metadata.model_file, metadata, args[0], false))
	var previous: Node3D = scene.actor.model_root
	assert(previous != null and scene.actor.skeleton != null)
	var broken := "res://outputs/invalid_model_transaction.pmx"
	var file := FileAccess.open(broken, FileAccess.WRITE)
	file.store_buffer("not a PMX".to_utf8_buffer())
	file.close()
	assert(not scene._adopt_model(ProjectSettings.globalize_path(broken), {}, "", false))
	assert(scene.actor.model_root == previous and previous.visible, "A failed import destroyed the current character")
	assert(not scene.actor.import_error.is_empty() and not scene.receiver.is_running())
	DirAccess.remove_absolute(ProjectSettings.globalize_path(broken))
	scene.queue_free()
	await process_frame
	print("MODEL_TRANSACTION_PASS original PMX, mapping, physics, failed-import rollback, no webcam")
	quit(0)
