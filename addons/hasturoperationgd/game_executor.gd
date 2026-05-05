extends Node

const _GdScriptExecutorRes = preload("./gdscript_executor.gd")
const _HasturExecutorHttpApiRes = preload("./hastur_executor_http_api.gd")

var _http_api = null
var _executor: GDScriptExecutor


func _ready() -> void:
	if not OS.is_debug_build():
		queue_free()
		return

	var game_port := HasturOperationGDPluginSettings.get_game_http_port()
	if game_port <= 0:
		return

	_executor = _GdScriptExecutorRes.new() as GDScriptExecutor
	_http_api = _HasturExecutorHttpApiRes.new()
	var bind_host := HasturOperationGDPluginSettings.get_http_bind_host()
	_http_api.configure(bind_host, game_port, "game", null, _executor, Callable())
	var err: Error = _http_api.start()
	if err != OK:
		push_warning(
			"GameExecutor HTTP API: listen failed (%s) on %s:%d."
			% [error_string(err), bind_host, game_port],
		)
		_http_api = null


func _process(_delta: float) -> void:
	if _http_api and _http_api.is_listening():
		_http_api.poll()


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST or what == NOTIFICATION_PREDELETE:
		if _http_api:
			_http_api.stop()
			_http_api = null
		_executor = null
