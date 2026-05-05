class_name HasturOperationGDPluginSettings


static func register_settings() -> void:
	if not ProjectSettings.has_setting("hastur_operation/output_max_char_length"):
		ProjectSettings.set_setting("hastur_operation/output_max_char_length", 800)
	ProjectSettings.set_initial_value("hastur_operation/output_max_char_length", 800)
	ProjectSettings.add_property_info({
		"name": "hastur_operation/output_max_char_length",
		"type": TYPE_INT,
		"hint": PROPERTY_HINT_RANGE,
		"hint_string": "100,10000,1"
	})

	if not ProjectSettings.has_setting("hastur_operation/http_bind_host"):
		ProjectSettings.set_setting("hastur_operation/http_bind_host", "127.0.0.1")
	ProjectSettings.set_initial_value("hastur_operation/http_bind_host", "127.0.0.1")
	ProjectSettings.add_property_info({
		"name": "hastur_operation/http_bind_host",
		"type": TYPE_STRING,
	})

	if not ProjectSettings.has_setting("hastur_operation/http_port"):
		ProjectSettings.set_setting("hastur_operation/http_port", 5302)
	ProjectSettings.set_initial_value("hastur_operation/http_port", 5302)
	ProjectSettings.add_property_info({
		"name": "hastur_operation/http_port",
		"type": TYPE_INT,
		"hint": PROPERTY_HINT_RANGE,
		"hint_string": "1,65535,1"
	})

	if not ProjectSettings.has_setting("hastur_operation/game_http_port"):
		ProjectSettings.set_setting("hastur_operation/game_http_port", 5303)
	ProjectSettings.set_initial_value("hastur_operation/game_http_port", 5303)
	ProjectSettings.add_property_info({
		"name": "hastur_operation/game_http_port",
		"type": TYPE_INT,
		"hint": PROPERTY_HINT_RANGE,
		"hint_string": "0,65535,1"
	})


static func get_output_max_char_length() -> int:
	return ProjectSettings.get_setting("hastur_operation/output_max_char_length", 800)


static func get_http_bind_host() -> String:
	return ProjectSettings.get_setting("hastur_operation/http_bind_host", "127.0.0.1")


static func get_http_port() -> int:
	return ProjectSettings.get_setting("hastur_operation/http_port", 5302)


static func get_game_http_port() -> int:
	return ProjectSettings.get_setting("hastur_operation/game_http_port", 5303)


static func deterministic_executor_id(project_name: String, project_path: String, process_id: int) -> String:
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	var input := "%s|%s|%d" % [project_name, project_path, process_id]
	ctx.update(input.to_utf8_buffer())
	var digest := ctx.finish()
	var hex := digest.hex_encode()
	return "%s-%s-%s-%s-%s" % [
		hex.substr(0, 8),
		hex.substr(8, 4),
		hex.substr(12, 4),
		hex.substr(16, 4),
		hex.substr(20, 12),
	]
