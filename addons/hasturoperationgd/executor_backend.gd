@tool
class_name ExecutorBackend
extends Node

signal connection_state_changed(listening: bool, executor_id: String, listen_url: String)
signal execution_completed(entry: Dictionary)
signal history_cleared()

const _GdScriptExecutorRes = preload("./gdscript_executor.gd")
const _HasturExecutorHttpApiRes = preload("./hastur_executor_http_api.gd")


var _executor: GDScriptExecutor
var _http_api = null
var _editor_plugin = null
var _history: Array = []
var _max_history: int = 50


func initialize(p_editor_plugin) -> void:
	_editor_plugin = p_editor_plugin


func _ready() -> void:
	process_mode = PROCESS_MODE_ALWAYS
	_executor = _GdScriptExecutorRes.new() as GDScriptExecutor
	_http_api = _HasturExecutorHttpApiRes.new()
	var bind_host := HasturOperationGDPluginSettings.get_http_bind_host()
	var bind_port := HasturOperationGDPluginSettings.get_http_port()
	_http_api.configure(
		bind_host,
		bind_port,
		"editor",
		_editor_plugin,
		_executor,
		_on_remote_http_execution,
	)
	var err: Error = _http_api.start()
	var executor_id := _compute_executor_id()
	var listen_url := _format_listen_url(bind_host, bind_port)
	if err != OK:
		push_error(
			"HasturExecutorHttpApi: listen failed (%s) on %s:%d — remote HTTP API disabled."
			% [error_string(err), bind_host, bind_port],
		)
	# Defer so UI that connects in _ready() is guaranteed to receive the first update.
	call_deferred("_emit_connection_state", err == OK, executor_id, listen_url if err == OK else "")


func _emit_connection_state(listening: bool, executor_id: String, listen_url: String) -> void:
	connection_state_changed.emit(listening, executor_id, listen_url)


func is_remote_http_listening() -> bool:
	return _http_api != null and _http_api.is_listening()


func _process(_delta: float) -> void:
	if _http_api and _http_api.is_listening():
		_http_api.poll()


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE:
		if _http_api:
			_http_api.stop()
			_http_api = null
		_executor = null


func execute_code(code: String) -> Dictionary:
	var start_time = Time.get_ticks_msec()
	var result = _executor.execute_code(code, {}, _editor_plugin)
	var end_time = Time.get_ticks_msec()
	var duration_ms = end_time - start_time
	var entry = {
		"code": code,
		"result": result,
		"timestamp": Time.get_time_string_from_system(),
		"duration_ms": duration_ms,
		"source": "local"
	}
	_add_to_history(entry)
	execution_completed.emit(entry)
	return result


func get_history() -> Array:
	return _history


func clear_history() -> void:
	_history.clear()
	history_cleared.emit()


func get_listen_url() -> String:
	if _http_api == null or not _http_api.is_listening():
		return ""
	return _format_listen_url(
		HasturOperationGDPluginSettings.get_http_bind_host(),
		HasturOperationGDPluginSettings.get_http_port(),
	)


func get_executor_id() -> String:
	return _compute_executor_id()


func _compute_executor_id() -> String:
	var project_name: String = ProjectSettings.get_setting("application/config/name", "Unnamed")
	var project_path: String = ProjectSettings.globalize_path("res://")
	return HasturOperationGDPluginSettings.deterministic_executor_id(project_name, project_path, OS.get_process_id())


func _format_listen_url(host: String, port: int) -> String:
	var safe_host := host
	if ":" in safe_host and not safe_host.begins_with("["):
		safe_host = "[%s]" % safe_host
	return "http://%s:%d" % [safe_host, port]


func _on_remote_http_execution(code: String, result: Dictionary, duration_ms: int) -> void:
	var entry = {
		"code": code,
		"result": result,
		"timestamp": Time.get_time_string_from_system(),
		"duration_ms": duration_ms,
		"source": "remote"
	}
	_add_to_history(entry)
	execution_completed.emit(entry)


func _add_to_history(entry: Dictionary) -> void:
	_history.append(entry)
	if _history.size() > _max_history:
		_history.pop_front()
