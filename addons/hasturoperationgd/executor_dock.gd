@tool
extends Control


var _code_edit: CodeEdit
var _result_edit: CodeEdit
var _editor_api_status: Label
var _editor_api_url: LineEdit
var _game_api_status: Label
var _game_api_url: LineEdit
var _history_list: ItemList
var _backend: ExecutorBackend


class _SectionEditors:
	var panel: PanelContainer
	var editor: CodeEdit


func initialize(backend: ExecutorBackend) -> void:
	_backend = backend


func _ready() -> void:
	_build_ui()
	if not ProjectSettings.settings_changed.is_connected(_on_project_settings_changed):
		ProjectSettings.settings_changed.connect(_on_project_settings_changed)
	if _backend:
		_backend.connection_state_changed.connect(_on_connection_state_changed)
		_backend.execution_completed.connect(_on_execution_completed)
		_backend.history_cleared.connect(_on_history_cleared)
		call_deferred("_sync_remote_http_ui")


func _exit_tree() -> void:
	if ProjectSettings.settings_changed.is_connected(_on_project_settings_changed):
		ProjectSettings.settings_changed.disconnect(_on_project_settings_changed)


func _build_ui() -> void:
	var ed := EditorInterface.get_editor_theme()
	var sep: int = int(ed.get_constant("separation", "VBoxContainer"))
	if sep < 1:
		sep = 4

	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	for side in ["margin_left", "margin_top", "margin_right", "margin_bottom"]:
		margin.add_theme_constant_override(side, 8)
	margin.theme = ed
	add_child(margin)

	var root := VBoxContainer.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.add_theme_constant_override("separation", sep)
	margin.add_child(root)

	root.add_child(_make_header_block(ed, sep))

	var script_section := _make_labeled_editor_block(
		ed,
		"Script",
		true,
		5.0,
		140,
	)
	_code_edit = script_section.editor
	root.add_child(script_section.panel)

	var exec_row := HBoxContainer.new()
	exec_row.add_theme_constant_override("separation", sep)
	var execute_button := Button.new()
	execute_button.text = "Execute"
	execute_button.tooltip_text = "Run the script in the editor executor."
	execute_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	execute_button.custom_minimum_size.y = maxi(28, execute_button.custom_minimum_size.y)
	execute_button.pressed.connect(_on_execute_pressed)
	if ed.has_icon("MainPlay", "EditorIcons"):
		execute_button.icon = ed.get_icon("MainPlay", "EditorIcons")
	exec_row.add_child(execute_button)
	root.add_child(exec_row)

	var output_section := _make_labeled_editor_block(
		ed,
		"Output",
		false,
		3.0,
		96,
	)
	_result_edit = output_section.editor
	root.add_child(output_section.panel)

	var history_panel := PanelContainer.new()
	history_panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	history_panel.custom_minimum_size = Vector2(0, 120)
	var history_body := VBoxContainer.new()
	history_body.add_theme_constant_override("separation", sep)

	var history_header := HBoxContainer.new()
	history_header.add_theme_constant_override("separation", sep)
	var history_title := Label.new()
	history_title.text = "Execution history"
	history_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	history_header.add_child(history_title)

	var clear_button := Button.new()
	clear_button.text = "Clear"
	clear_button.tooltip_text = "Remove all entries from the history list."
	clear_button.pressed.connect(_on_clear_history)
	history_header.add_child(clear_button)
	history_body.add_child(history_header)

	_history_list = ItemList.new()
	_history_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_history_list.custom_minimum_size = Vector2(0, 72)
	_history_list.item_selected.connect(_on_history_selected)
	history_body.add_child(_history_list)

	history_panel.add_child(history_body)
	root.add_child(history_panel)


func _make_header_block(theme: Theme, separation: int) -> PanelContainer:
	var panel := PanelContainer.new()
	var inner := VBoxContainer.new()
	inner.add_theme_constant_override("separation", maxi(3, separation / 2))
	var small_title_fs := maxi(11, theme.get_font_size("font_size", "EditorFonts"))

	var editor_heading := Label.new()
	editor_heading.text = "Editor HTTP API"
	editor_heading.add_theme_font_size_override("font_size", small_title_fs)
	inner.add_child(editor_heading)

	_editor_api_status = Label.new()
	_editor_api_status.text = "Status: initializing…"
	_editor_api_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_editor_api_status.add_theme_color_override("font_color", Color(0.55, 0.55, 0.58))
	inner.add_child(_editor_api_status)

	_editor_api_url = _make_readonly_url_line()
	_editor_api_url.placeholder_text = "http://127.0.0.1:5302"
	inner.add_child(_editor_api_url)

	var game_heading := Label.new()
	game_heading.text = "Game HTTP API"
	game_heading.add_theme_font_size_override("font_size", small_title_fs)
	inner.add_child(game_heading)

	_game_api_status = Label.new()
	_game_api_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	inner.add_child(_game_api_status)

	_game_api_url = _make_readonly_url_line()
	_game_api_url.placeholder_text = "http://127.0.0.1:5303"
	inner.add_child(_game_api_url)

	var hint := Label.new()
	hint.text = "Ports: Project Settings → filter hastur_operation"
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.tooltip_text = "Keys: http_bind_host, http_port, game_http_port"
	var hint_fs := theme.get_font_size("font_size", "EditorFonts")
	hint.add_theme_font_size_override("font_size", maxi(10, hint_fs - 1))
	inner.add_child(hint)

	panel.add_child(inner)
	return panel


func _make_readonly_url_line() -> LineEdit:
	var line := LineEdit.new()
	line.editable = false
	line.caret_blink = false
	line.selecting_enabled = true
	line.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	line.tooltip_text = "Select text and copy base URL (Ctrl+C)."
	return line


func _on_project_settings_changed() -> void:
	if _editor_api_url:
		_editor_api_url.text = HasturOperationGDPluginSettings.get_editor_http_base_url()
	_refresh_game_api_display()


func _make_labeled_editor_block(
	theme: Theme,
	title_text: String,
	gdscript_highlight: bool,
	stretch_ratio: float,
	min_editor_height: int,
) -> _SectionEditors:
	var wrap := PanelContainer.new()
	wrap.size_flags_vertical = Control.SIZE_EXPAND_FILL
	wrap.size_flags_stretch_ratio = stretch_ratio

	var column := VBoxContainer.new()
	var title := Label.new()
	title.text = title_text
	var title_fs := theme.get_font_size("font_size", "EditorFonts")
	title.add_theme_font_size_override("font_size", maxi(12, title_fs + 1))
	column.add_child(title)

	var editor := CodeEdit.new()
	editor.size_flags_vertical = Control.SIZE_EXPAND_FILL
	editor.custom_minimum_size = Vector2(0, min_editor_height)
	editor.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	_apply_code_edit_theme(editor, theme, gdscript_highlight)
	column.add_child(editor)

	wrap.add_child(column)

	var out := _SectionEditors.new()
	out.panel = wrap
	out.editor = editor
	return out


func _apply_code_edit_theme(editor: CodeEdit, theme: Theme, gdscript_highlight: bool) -> void:
	editor.gutters_draw_line_numbers = true
	editor.gutters_zero_pad_line_numbers = false
	editor.scroll_fit_content_height = false
	if theme.has_font("source", "EditorFonts"):
		editor.add_theme_font_override("font", theme.get_font("source", "EditorFonts"))
	elif theme.has_font("status_source", "EditorFonts"):
		editor.add_theme_font_override("font", theme.get_font("status_source", "EditorFonts"))
	if gdscript_highlight:
		editor.syntax_highlighter = GDScriptSyntaxHighlighter.new()
	else:
		editor.editable = false


func _sync_remote_http_ui() -> void:
	_refresh_game_api_display()
	if not _backend:
		_editor_api_status.text = "Backend not available."
		_editor_api_url.text = HasturOperationGDPluginSettings.get_editor_http_base_url()
		return
	_on_connection_state_changed(
		_backend.is_remote_http_listening(),
		_backend.get_executor_id(),
		_backend.get_listen_url(),
	)


func _refresh_game_api_display() -> void:
	if not _game_api_status or not _game_api_url:
		return
	var theme := EditorInterface.get_editor_theme()
	var default_label := Color(0.75, 0.75, 0.78)
	if theme.has_color("font_color", "Editor"):
		default_label = theme.get_color("font_color", "Editor")
	var port := HasturOperationGDPluginSettings.get_game_http_port()
	if port <= 0:
		_game_api_url.visible = false
		_game_api_url.text = ""
		_game_api_status.text = "Disabled — set hastur_operation/game_http_port > 0 in Project Settings."
		_game_api_status.add_theme_color_override("font_color", Color(0.72, 0.65, 0.45))
	else:
		_game_api_url.visible = true
		_game_api_url.text = HasturOperationGDPluginSettings.get_game_http_base_url()
		_game_api_url.tooltip_text = "Game listens here when a debug build is running (GameExecutor autoload)."
		_game_api_status.text = "Configured — use this base URL for the running game process (debug)."
		_game_api_status.add_theme_color_override("font_color", default_label)


func _on_execute_pressed() -> void:
	if not _backend:
		return
	_backend.execute_code(_code_edit.text)


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
	var theme := EditorInterface.get_editor_theme()
	_editor_api_url.text = HasturOperationGDPluginSettings.get_editor_http_base_url()
	if listening:
		_editor_api_status.text = "Listening — remote clients can execute in the editor."
		var ok := Color(0.45, 0.82, 0.52)
		if theme.has_color("property_color", "Editor"):
			ok = theme.get_color("property_color", "Editor").lightened(0.15)
		_editor_api_status.add_theme_color_override("font_color", ok)
		var id_note: String = listen_url if listen_url != "" else HasturOperationGDPluginSettings.get_editor_http_base_url()
		_editor_api_url.tooltip_text = "Executor ID: %s\nBase URL: %s" % [executor_id, id_note]
	else:
		_editor_api_status.text = "Not listening — port may be in use or bind failed (see Output)."
		var bad := Color(0.95, 0.45, 0.42)
		if theme.has_color("property_color", "Editor"):
			bad = theme.get_color("property_color", "Editor").darkened(0.2)
			bad = Color(bad.r + 0.25, bad.g * 0.6, bad.b * 0.65)
		_editor_api_status.add_theme_color_override("font_color", bad)
		_editor_api_url.tooltip_text = "Configured editor base URL (plugin is not accepting HTTP)."


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
		var ed := EditorInterface.get_editor_theme()
		if status_str == "OK":
			_history_list.set_item_custom_fg_color(idx, Color(0.45, 0.82, 0.52))
		else:
			var fail := Color(0.95, 0.45, 0.42)
			if ed.has_color("property_color", "Editor"):
				fail = ed.get_color("property_color", "Editor").darkened(0.15)
				fail = Color(fail.r + 0.28, fail.g * 0.55, fail.b * 0.58)
			_history_list.set_item_custom_fg_color(idx, fail)
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
