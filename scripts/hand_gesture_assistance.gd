extends RefCounted

const DWELL_SECONDS := 0.18
const UNKNOWN_SECONDS := 0.12
var _states := {}


func reset() -> void:
	_states.clear()


func reset_side(side: String) -> void:
	_states.erase(side)


func sample(side: String, points: Array, image: Array, delta: float) -> Dictionary:
	if not is_finite(delta) or delta <= 0.0:
		return {"gesture": "", "weight": 0.0}
	var state: Dictionary = _states.get(side, {"active": "", "candidate": "", "samples": 0, "age": 0.0, "unknown": 0.0, "weight": 0.0})
	var label := classify(points, image, state.active)
	var target := 0.0
	if label.is_empty():
		state.candidate = ""
		state.samples = 0
		state.age = 0.0
		state.unknown += delta
	else:
		state.unknown = 0.0
		if label == state.active:
			state.candidate = ""
			state.samples = 0
			state.age = 0.0
			target = 1.0
		else:
			if label != state.candidate:
				state.candidate = label
				state.age = 0.0
				state.samples = 0
			state.age += delta
			state.samples += 1
			# Elapsed packet time alone cannot prove that a gesture was observed continuously.
			if state.age >= DWELL_SECONDS and state.samples >= 3:
				state.active = label
				state.candidate = ""
				state.samples = 0
				state.age = 0.0
				target = 1.0
	var speed := 12.0 if target > state.weight else 25.0
	state.weight = lerpf(state.weight, target, 1.0 - exp(-speed * minf(delta, 0.2)))
	if label.is_empty() and state.unknown >= UNKNOWN_SECONDS and state.weight < 0.001:
		state.active = ""
	if state.active.is_empty():
		state.weight = 0.0
	_states[side] = state
	return {"gesture": state.active, "weight": state.weight}


static func classify(points: Array, image: Array, previous: String = "") -> String:
	if points.size() != 21 or image.size() != 21:
		return ""
	for i in 21:
		if not points[i] is Array or points[i].size() < 3 or not image[i] is Array or image[i].size() < 2:
			return ""
		if not _point(points[i]).is_finite() or not is_finite(float(image[i][0])) or not is_finite(float(image[i][1])):
			return ""
		if image[i][0] < 0.0 or image[i][0] > 1.0 or image[i][1] < 0.0 or image[i][1] > 1.0:
			return ""
	var wrist := _point(points[0])
	var middle := _point(points[9])
	var along := middle - wrist
	var across := _point(points[5]) - _point(points[17])
	var palm := along.length()
	if palm < 0.01 or palm > 0.4 or across.length() < palm * 0.15 or across.length() > palm * 2.5:
		return ""
	if along.normalized().cross(across.normalized()).length() < 0.25:
		return ""
	var metrics: Array[Dictionary] = []
	for finger in 5:
		var first := 1 if finger == 0 else finger * 4 + 1
		var lengths := 0.0
		var directions: Array[Vector3] = []
		for segment in 3:
			var direction := _point(points[first + segment + 1]) - _point(points[first + segment])
			var length := direction.length()
			if length < palm * 0.06 or length > palm * 0.95:
				return ""
			lengths += length
			directions.append(direction / length)
		if lengths < palm * 0.4 or lengths > palm * 2.4:
			return ""
		var first_bend := directions[0].angle_to(directions[1])
		var second_bend := directions[1].angle_to(directions[2])
		var base := _point(points[first])
		var tip := _point(points[first + 3])
		var extension := tip.distance_to(base) / lengths
		var reach := (tip.distance_to(wrist) - base.distance_to(wrist)) / lengths
		metrics.append({"extension": extension, "bend": first_bend + second_bend, "maximum_bend": maxf(first_bend, second_bend), "reach": reach, "length": lengths})
	var center := (_point(points[5]) + middle + _point(points[13]) + _point(points[17])) * 0.25
	var thumb: Dictionary = metrics[0]
	thumb.outward = (_point(points[4]).distance_to(center) - _point(points[1]).distance_to(center)) / thumb.length
	for relaxed in [false, true]:
		var open: Array[bool] = []
		var closed: Array[bool] = []
		for finger in range(1, 5):
			var metric: Dictionary = metrics[finger]
			open.append(metric.extension > (0.86 if relaxed else 0.92) and metric.maximum_bend < (0.60 if relaxed else 0.40) and metric.reach > (0.30 if relaxed else 0.40))
			closed.append(metric.extension < (0.75 if relaxed else 0.68) and metric.bend > (0.95 if relaxed else 1.20) and metric.reach < (0.55 if relaxed else 0.45))
		var thumb_open: bool = thumb.extension > (0.80 if relaxed else 0.86) and thumb.bend < (0.75 if relaxed else 0.55) and thumb.outward > (0.08 if relaxed else 0.15)
		var thumb_closed: bool = thumb.bend > (0.50 if relaxed else 0.65) or thumb.outward < (-0.01 if relaxed else -0.05) or thumb.extension < (0.80 if relaxed else 0.75)
		var label := ""
		if open.all(func(value: bool): return value) and thumb_open:
			label = "open"
		elif closed.all(func(value: bool): return value) and thumb_closed and not thumb_open:
			label = "fist"
		elif open[0] and closed[1] and closed[2] and closed[3] and not thumb_open:
			label = "index"
		if not label.is_empty() and (not relaxed or label == previous):
			return label
	return ""


static func preset_rotation(gesture: String, finger: int, segment: int, base_direction: Vector3, palm_normal: Vector3, toward_palm: Vector3) -> Basis:
	if gesture == "open" or (gesture == "index" and finger == 1):
		return Basis.IDENTITY
	var base := base_direction.normalized()
	var normal := palm_normal.normalized()
	var opposition := Basis.IDENTITY
	if finger == 0:
		var planar := base - normal * base.dot(normal)
		var toward := toward_palm - normal * toward_palm.dot(normal)
		if minf(planar.length_squared(), toward.length_squared()) > 0.00000001:
			opposition = Basis(normal, clampf(planar.signed_angle_to(toward, normal), -0.8, 0.8) * 0.75)
		base = opposition * base
	var axis := base.cross(normal).normalized()
	if axis.is_zero_approx():
		return Basis.IDENTITY
	var angle: float = [0.35, 0.85, 1.35][segment] if finger == 0 else [deg_to_rad(75.0), deg_to_rad(165.0), deg_to_rad(230.0)][segment]
	return Basis(axis, angle) * opposition


static func _point(value: Array) -> Vector3:
	return Vector3(value[0], -value[1], -value[2])
