@tool
class_name HasturExecutorHttpApi
extends RefCounted

const MAX_HEADER_PLUS_BODY := 600000

var _tcp := TCPServer.new()
var _bind_host: String = "127.0.0.1"
var _bind_port: int = 5302
var _executor_type: String = "editor"
var _editor_plugin = null
var _executor: GDScriptExecutor
var _remote_done_cb: Callable = Callable()

var _clients: Array = []


func configure(
	bind_host: String,
	bind_port: int,
	executor_type: String,
	editor_plugin,
	gd_executor: GDScriptExecutor,
	remote_done_cb: Callable = Callable(),
) -> void:
	_bind_host = bind_host
	_bind_port = bind_port
	_executor_type = executor_type
	_editor_plugin = editor_plugin
	_executor = gd_executor
	_remote_done_cb = remote_done_cb


func start() -> int:
	stop()
	var err: Error = _tcp.listen(_bind_port, _bind_host)
	return err


func stop() -> void:
	for c in _clients:
		var peer: StreamPeerTCP = c.peer
		if peer.get_status() != StreamPeerTCP.STATUS_NONE:
			peer.disconnect_from_host()
	_clients.clear()
	if _tcp.is_listening():
		_tcp.stop()


func is_listening() -> bool:
	return _tcp.is_listening()


func get_listen_port() -> int:
	return _bind_port


func get_bind_host() -> String:
	return _bind_host


func poll() -> void:
	if not _tcp.is_listening():
		return
	while _tcp.is_connection_available():
		var peer := _tcp.take_connection()
		_clients.append({"peer": peer, "buf": PackedByteArray(), "sent_100": false})
	var idx := 0
	while idx < _clients.size():
		var done := _poll_one_client(_clients[idx])
		if done:
			_clients.remove_at(idx)
		else:
			idx += 1


func _executor_snapshot() -> Dictionary:
	var project_name: String = ProjectSettings.get_setting("application/config/name", "Unnamed")
	var project_path: String = ProjectSettings.globalize_path("res://")
	var pid: int = OS.get_process_id()
	var plugin_version: String = HasturOperationGDPluginSettings.get_plugin_version()
	var version_info := Engine.get_version_info()
	var editor_version := "%d.%d.%d" % [
		version_info.get("major", 0),
		version_info.get("minor", 0),
		version_info.get("patch", 0),
	]
	return {
		"id": HasturOperationGDPluginSettings.deterministic_executor_id(project_name, project_path, pid),
		"project_name": project_name,
		"project_path": project_path,
		"editor_pid": pid,
		"plugin_version": plugin_version,
		"editor_version": editor_version,
		"supported_languages": ["gdscript"],
		"connected_at": _iso8601_utc_now(),
		"status": "connected",
		"type": _executor_type,
	}


func _iso8601_utc_now() -> String:
	var unix := int(Time.get_unix_time_from_system())
	var dt := Time.get_datetime_dict_from_unix_time(unix)
	return "%04d-%02d-%02dT%02d:%02d:%02d.000Z" % [
		dt.year,
		dt.month,
		dt.day,
		dt.hour,
		dt.minute,
		dt.second,
	]


func _poll_one_client(entry: Dictionary) -> bool:
	var peer: StreamPeerTCP = entry.peer
	var buf: PackedByteArray = entry.buf
	peer.poll()
	var st := peer.get_status()
	if st != StreamPeerTCP.STATUS_CONNECTED:
		return true
	while peer.get_available_bytes() > 0:
		var chunk := peer.get_partial_data(peer.get_available_bytes())
		if chunk[0] != OK:
			break
		var data: PackedByteArray = chunk[1]
		if buf.size() + data.size() > MAX_HEADER_PLUS_BODY:
			_send_http(peer, 413, {"success": false, "error": "Payload too large"})
			return true
		buf.append_array(data)
	entry.buf = buf
	return _try_dispatch(peer, entry)


func _locate_header_body_split(buf: PackedByteArray) -> Dictionary:
	var n := buf.size()
	var i := 0
	while i <= n - 4:
		if buf[i] == 13 and buf[i + 1] == 10 and buf[i + 2] == 13 and buf[i + 3] == 10:
			return {"sep_at": i, "sep_len": 4}
		i += 1
	i = 0
	while i <= n - 2:
		if buf[i] == 10 and buf[i + 1] == 10:
			return {"sep_at": i, "sep_len": 2}
		i += 1
	return {"sep_at": -1, "sep_len": 0}


func _headers_expect_continue(headers_blob: String) -> bool:
	var norm := headers_blob.replace("\r\n", "\n")
	for line in norm.split("\n"):
		var colon := line.find(":")
		if colon == -1:
			continue
		var key := line.substr(0, colon).strip_edges().to_lower()
		var val := line.substr(colon + 1).strip_edges().to_lower()
		if key == "expect" and val == "100-continue":
			return true
	return false


func _send_100_continue(peer: StreamPeerTCP) -> void:
	peer.put_data("HTTP/1.1 100 Continue\r\n\r\n".to_utf8_buffer())


func _try_dispatch(peer: StreamPeerTCP, entry: Dictionary) -> bool:
	var buf: PackedByteArray = entry.buf
	var split := _locate_header_body_split(buf)
	var sep_at: int = split["sep_at"]
	if sep_at < 0:
		if buf.size() > MAX_HEADER_PLUS_BODY:
			_send_http(peer, 400, {"success": false, "error": "Bad request"})
			return true
		return false
	var sep_len: int = split["sep_len"]
	var body_start: int = sep_at + sep_len
	var headers_blob := buf.slice(0, sep_at).get_string_from_utf8()
	var content_length := _parse_content_length(headers_blob)
	var needed_total := body_start + content_length
	if buf.size() < needed_total:
		if content_length > 0 and _headers_expect_continue(headers_blob) and not entry.get("sent_100", false):
			_send_100_continue(peer)
			entry.sent_100 = true
		return false
	var body_bytes := buf.slice(body_start, body_start + content_length)
	var body_str := body_bytes.get_string_from_utf8()
	var norm_headers := headers_blob.replace("\r\n", "\n")
	var header_lines := norm_headers.split("\n")
	if header_lines.is_empty():
		_send_http(peer, 400, {"success": false, "error": "Bad request"})
		return true
	var first_line := header_lines[0].strip_edges()
	var parts := first_line.split(" ")
	if parts.size() < 2:
		_send_http(peer, 400, {"success": false, "error": "Bad request"})
		return true
	var method := parts[0].strip_edges().to_upper()
	var path := parts[1].strip_edges().split(" ")[0]
	if path.contains("?"):
		path = path.split("?")[0]
	var handled := _handle_route(peer, method, path, body_str)
	return handled


func _parse_content_length(headers_blob: String) -> int:
	var norm := headers_blob.replace("\r\n", "\n")
	for line in norm.split("\n"):
		var colon := line.find(":")
		if colon == -1:
			continue
		var key := line.substr(0, colon).strip_edges().to_lower()
		if key == "content-length":
			return line.substr(colon + 1).strip_edges().to_int()
	return 0


func _handle_route(peer: StreamPeerTCP, method: String, path: String, body_str: String) -> bool:
	match path:
		"/api/health":
			if method != "GET":
				_send_http(peer, 405, {"success": false, "error": "Method not allowed"})
				return true
			_send_http(peer, 200, {
				"success": true,
				"data": {
					"status": "ok",
					"http_host": _bind_host,
					"http_port": _bind_port,
					"executors_connected": 1 if _tcp.is_listening() else 0,
				},
			})
			return true
		"/api/executors":
			if method != "GET":
				_send_http(peer, 405, {"success": false, "error": "Method not allowed"})
				return true
			_send_http(peer, 200, {"success": true, "data": [_executor_snapshot()]})
			return true
		"/api/execute":
			if method != "POST":
				_send_http(peer, 405, {"success": false, "error": "Method not allowed"})
				return true
			return _handle_execute(peer, body_str)
		_:
			_send_http(
				peer,
				404,
				{
					"success": false,
					"error": "Route not found",
					"hint": "Try GET /api/health, GET /api/executors, POST /api/execute",
				},
			)
			return true


func _handle_execute(peer: StreamPeerTCP, body_str: String) -> bool:
	var json := JSON.new()
	if json.parse(body_str) != OK:
		_send_http(peer, 400, {"success": false, "error": "Invalid JSON body"})
		return true
	var root = json.data
	if not root is Dictionary:
		_send_http(peer, 400, {"success": false, "error": "Body must be a JSON object"})
		return true
	var body: Dictionary = root
	if not body.has("code"):
		_send_http(peer, 400, {
			"success": false,
			"error": "Missing required field: code",
			"hint": "Include a string field \"code\" with GDScript to run.",
		})
		return true
	var code := str(body.code)
	var info := _executor_snapshot()
	if not _targets_this_executor(body, info):
		_send_http(peer, 404, {
			"success": false,
			"error": "Request does not target this executor instance",
			"hint": "Use GET /api/executors on this host/port to see id, project_name, and type.",
		})
		return true
	var start_ms := Time.get_ticks_msec()
	var result := _executor.execute_code(code, {}, _editor_plugin)
	var elapsed := Time.get_ticks_msec() - start_ms
	if _remote_done_cb.is_valid():
		_remote_done_cb.call(code, result, elapsed)
	if elapsed > 30000:
		_send_http(peer, 504, {
			"success": false,
			"error": "Executor execution timed out (30s)",
			"hint": "Simplify the snippet or check if Godot is responsive.",
		})
		return true
	_send_http(peer, 200, {"success": true, "data": result})
	return true


func _nonempty_body_field(body: Dictionary, key: String) -> bool:
	return body.has(key) and str(body[key]).strip_edges() != ""


func _targets_this_executor(body: Dictionary, info: Dictionary) -> bool:
	if _nonempty_body_field(body, "type"):
		if str(body.type) != _executor_type:
			return false
	var has_id := _nonempty_body_field(body, "executor_id")
	var has_pn := _nonempty_body_field(body, "project_name")
	var has_pp := _nonempty_body_field(body, "project_path")
	if not has_id and not has_pn and not has_pp:
		return true
	if has_id:
		return str(body.executor_id) == info.id
	if has_pn:
		var needle := str(body.project_name).to_lower()
		return str(info.project_name).to_lower().contains(needle)
	if has_pp:
		var needlep := str(body.project_path).to_lower()
		return str(info.project_path).to_lower().contains(needlep)
	return true


func _send_http(peer: StreamPeerTCP, status: int, obj: Dictionary) -> void:
	var phrase := _status_phrase(status)
	var json_text := JSON.stringify(obj)
	var payload := json_text.to_utf8_buffer()
	var hdr := "HTTP/1.1 %d %s\r\nContent-Type: application/json; charset=utf-8\r\nConnection: close\r\nContent-Length: %d\r\n\r\n" % [
		status,
		phrase,
		payload.size(),
	]
	var out := hdr.to_utf8_buffer()
	out.append_array(payload)
	peer.put_data(out)
	peer.disconnect_from_host()


func _status_phrase(code: int) -> String:
	match code:
		200:
			return "OK"
		400:
			return "Bad Request"
		404:
			return "Not Found"
		405:
			return "Method Not Allowed"
		413:
			return "Payload Too Large"
		504:
			return "Gateway Timeout"
		_:
			return "Error"
