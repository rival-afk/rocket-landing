extends Node

# Постоянный хост HTTP API. Живёт ДОЧЕРНИМ УЗЛОМ /root, то есть ПЕРЕЖИВАЕТ
# reload_current_scene(): сокет и порт не закрываются во время перезагрузки
# сцены, клиенты не получают "connection refused".
#
# Пока игра перезагружается (game == null), хост отвечает 503 + Retry-After
# вместо сброса соединения — клиенты могут просто повторить запрос через ~500 мс.

var server := TCPServer.new()
var peers := {}

# Ссылка на текущий экземпляр game.gd; null пока сцена перезагружается.
var game: Node = null
var bound_port := 0
var listen_error := OK

func _ready() -> void:
	# хост добавляется под root — именно там он не умирает при reload
	process_mode = Node.PROCESS_MODE_ALWAYS

func start(port: int) -> int:
	# слушаем один раз за жизнь процесса
	if server.is_listening():
		return bound_port
	listen_error = server.listen(port)
	bound_port = port
	return listen_error

func stop() -> void:
	server.stop()

func _process(_delta: float) -> void:
	if game == null:
		# сцена перезагружается: отвечаем 503 вместо сброса
		_poll_reloading()
	else:
		game._poll_api()  # на игре висит обычная логика поллинга
		game._poll_shot()

func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		stop()
		get_tree().quit()

# --- 503 на время перезагрузки ---

func _poll_reloading() -> void:
	while server.is_connection_available():
		var p: StreamPeerTCP = server.take_connection()
		p.poll()
		peers[p] = ""
	for p: StreamPeerTCP in peers.keys():
		p.poll()
		var res: Array = p.get_partial_data(65536)
		if res.size() == 2 and res[1] is PackedByteArray and res[1].size() > 0:
			peers[p] += (res[1] as PackedByteArray).get_string_from_utf8()
		var buf: String = peers[p]
		if buf.find("\r\n\r\n") == -1:
			if p.get_status() != StreamPeerTCP.STATUS_CONNECTED:
				peers.erase(p)
			continue
		var body := "{\"error\":\"scene reloading\",\"retry_after_ms\":500}"
		var response := "HTTP/1.1 503 Service Unavailable\r\nContent-Type: application/json\r\nRetry-After: 1\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s" % [body.length(), body]
		p.put_data(response.to_utf8_buffer())
		p.disconnect_from_host()
		peers.erase(p)
