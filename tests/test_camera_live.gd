extends SceneTree


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var adapter = preload("res://scripts/native_mocap.gd").new()
	assert(adapter.open() == OK)
	var total := 0
	var previews := 0
	for cycle in 2:
		adapter.set_preview_enabled(true)
		var started: bool = adapter.start({"device": 0, "width": 640, "height": 480, "fps": 30})
		var frames := 0
		var preview_count := 0
		var deadline := Time.get_ticks_msec() + 8000
		while started and adapter.is_running() and (frames < 5 or preview_count < 5) and Time.get_ticks_msec() < deadline:
			if not adapter.poll().is_empty():
				frames += 1
			var preview: Dictionary = adapter.poll_preview()
			if not preview.is_empty():
				assert(preview.image.get_width() > 0 and preview.image.get_height() > 0)
				assert(preview.frame.seq == preview.sequence)
				preview_count += 1
			await process_frame
		var error: String = adapter.get_error()
		adapter.set_preview_enabled(false)
		assert(adapter.poll_preview().is_empty(), "Disabling preview must discard pending images")
		assert(not started or not error.is_empty() or adapter.is_running(), "Closing preview must preserve capture")
		adapter.stop()
		assert(not adapter.is_running(), "Stop must release the capture worker")
		if frames < 5 or preview_count < 5:
			adapter.close()
			push_error("CAMERA_LIVE_FAIL cycle=%d frames=%d error=%s" % [cycle, frames, error])
			quit(1)
			return
		total += frames
		previews += preview_count
	adapter.close()
	print("CAMERA_LIVE_PASS frames=%d preview_frames=%d cycles=2 stopped=true images_saved=false" % [total, previews])
	quit(0)
