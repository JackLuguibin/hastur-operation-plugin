@tool
extends Control


var _code_edit: CodeEdit
var _result_edit: CodeEdit
var _status_label: Label
var _id_label: LineEdit
var _history_list: ItemList
var _backend: ExecutorBackend


func initialize(backend: ExecutorBackend) -> void:
	_backend = backend


func _ready() -> void:
	var vbox = VBoxContainer.new()
	vbox.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(vbox)

	var status_bar = HBoxContainer.new()
	_status_label = Label.new()
	_status_label.text = "Remote HTTP (syncing…)"
	_status_label.add_theme_color_override("font_color", Color(0.55, 0.55, 0.58))
	status_bar.add_child(_status_label)

	_id_label = LineEdit.new()
	_id_label.text = ""
	_id_label.visible = false
	_id_label.editable = false
	_id_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_id_label.alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_id_label.custom_minimum_size = Vector2(200, 0)
	_id_label.tooltip_text = "Click and Ctrl+C to copy"
	status_bar.add_child(_id_label)
	vbox.add_child(status_bar)

	var settings_hint := Label.new()
	settings_hint.text = "Ports live under Project Settings → search hastur_operation (http_bind_host, http_port, game_http_port)."
	settings_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	settings_hint.add_theme_font_size_override("font_size", 11)
	settings_hint.add_theme_color_override("font_color", Color(0.5, 0.5, 0.52))
	vbox.add_child(settings_hint)

	_code_edit = CodeEdit.new()
	_code_edit.custom_minimum_size = Vector2(0, 200)
	_code_edit.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vbox.add_child(_code_edit)

	var button = Button.new()
	button.text = "Execute"
	button.pressed.connect(_on_execute_pressed)
	vbox.add_child(button)

	_result_edit = CodeEdit.new()
	_result_edit.custom_minimum_size = Vector2(0, 100)
	_result_edit.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_result_edit.editable = false
	_result_edit.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	vbox.add_child(_result_edit)

	var history_vbox = VBoxContainer.new()
	history_vbox.custom_minimum_size = Vector2(0, 100)
	history_vbox.size_flags_vertical = Control.SIZE_EXPAND_FILL

	var history_header = HBoxContainer.new()
	var history_title = Label.new()
	history_title.text = "Execution History"
	history_header.add_child(history_title)

	var clear_button = Button.new()
	clear_button.text = "Clear History"
	clear_button.pressed.connect(_on_clear_history)
	history_header.add_child(clear_button)
	history_vbox.add_child(history_header)

	_history_list = ItemList.new()
	_history_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_history_list.item_selected.connect(_on_history_selected)
	history_vbox.add_child(_history_list)

	vbox.add_child(history_vbox)

	if _backend:
		_backend.connection_state_changed.connect(_on_connection_state_changed)
		_backend.execution_completed.connect(_on_execution_completed)
		_backend.history_cleared.connect(_on_history_cleared)
		call_deferred("_sync_remote_http_ui")


func _sync_remote_http_ui() -> void:
	if not _backend:
		return
	_on_connection_state_changed(
		_backend.is_remote_http_listening(),
		_backend.get_executor_id(),
		_backend.get_listen_url(),
	)


func _on_execute_pressed() -> void:
	if not _backend:
		return
	var code = _code_edit.text
	_backend.execute_code(code)


func _display_result(result: Dictionary) -> void:
	var text = ""

	if result.compile_success:
		text += "Compile: SUCCESS\n"
	else:
		text += "Compile: FAILED\n"
		text += result.compile_error + "\n"

	if not result.compile_success:
		text += "Run: (skipped)\n"
	elif result.run_success:
		text += "Run: SUCCESS\n"
	else:
		text += "Run: FAILED\n"
		text += result.run_error + "\n"

	if result.outputs.size() > 0:
		text += "---\n"
		text += "Output:\n"
		for entry in result.outputs:
			text += str(entry[0]) + ": " + str(entry[1]) + "\n"

	_result_edit.text = text


func _on_connection_state_changed(listening: bool, executor_id: String, listen_url: String) -> void:
	if listening:
		_status_label.text = "Remote HTTP listening"
		_status_label.add_theme_color_override("font_color", Color.GREEN)
		_id_label.text = listen_url if listen_url != "" else ("ID: " + executor_id)
		_id_label.tooltip_text = "Executor ID: " + executor_id
		_id_label.visible = true
	else:
		_status_label.text = "Remote HTTP unavailable"
		_status_label.add_theme_color_override("font_color", Color.RED)
		_id_label.text = ""
		_id_label.tooltip_text = ""
		_id_label.visible = false


func _on_execution_completed(entry: Dictionary) -> void:
	if entry.source == "local":
		_display_result(entry.result)
	_refresh_history_list()


func _refresh_history_list() -> void:
	if not _backend:
		return
	_history_list.clear()
	var history = _backend.get_history()
	for entry in history:
		var status_str = "OK"
		if not entry.result.get("compile_success", false):
			status_str = "FAIL"
		elif not entry.result.get("run_success", false):
			status_str = "FAIL"
		var source_str = entry.source
		var display = "[%s] %s - %dms (%s)" % [status_str, entry.timestamp, entry.duration_ms, source_str]
		var idx = _history_list.add_item(display)
		if status_str == "OK":
			_history_list.set_item_custom_fg_color(idx, Color.GREEN)
		else:
			_history_list.set_item_custom_fg_color(idx, Color.RED)
	if _history_list.item_count > 0:
		_history_list.select(_history_list.item_count - 1)
		_history_list.ensure_current_is_visible()


func _on_history_selected(index: int) -> void:
	if not _backend:
		return
	var history = _backend.get_history()
	if index < 0 or index >= history.size():
		return
	var entry = history[index]
	_code_edit.text = entry.code
	_display_result(entry.result)


func _on_clear_history() -> void:
	if _backend:
		_backend.clear_history()


func _on_history_cleared() -> void:
	_history_list.clear()
