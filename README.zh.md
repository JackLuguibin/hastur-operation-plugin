[English](README.md)

# Hastur Operation Plugin

一个 Godot 编辑器插件，在编辑器进程内提供 HTTP API，供 coding agent 远程执行任意 GDScript（可选地在运行中的游戏里通过 Autoload 再开一组端口）。

## 它是做什么的？

如今的 coding agent 执行 shell 命令已经非常熟练——`npm install`、`git commit`、`docker compose up`，在文件系统里操作自如，终端一行命令即可完成。

但 Godot 编辑器是一个 GUI 应用，无法通过 `curl` 之类的命令行工具来操控场景节点。此前做不到，现在可以了。

本插件为 coding agent 提供了一个操控 Godot 的「shell」接口。**HTTP 服务跑在插件内部**，agent 可以：

- 查看和操作场景树
- 创建、修改、删除节点
- 读取和修改项目设置
- 执行各类编辑器操作
- 凡是在编辑器脚本面板中手写 GDScript 能做到的事，均可完成

简而言之，就是给 AI 助手提供了一把专门操作 Godot 的螺丝刀。

## 工作原理

```
┌─────────────────┐         ┌──────────────────────────────┐
│   Coding Agent  │  HTTP   │  Godot 编辑器                │
│  (opencode,     │ ──────> │  Hastur 插件绑定 host:port    │
│   Claude 等)    │ <────── │  （默认 127.0.0.1:5302）执行   │
└─────────────────┘         │  GDScript                     │
                            └──────────────────────────────┘

可选：运行中游戏进程上的第二个 HTTP 监听（GameExecutor autoload）：

┌─────────────────┐         ┌──────────────────────────────┐
│   Coding Agent  │  HTTP   │  游戏进程 + GameExecutor      │
│                 │ ──────> │  （默认 127.0.0.1:5303）       │
└─────────────────┘         └──────────────────────────────┘
```

1. Agent 向**编辑器**或**游戏**各自的 HTTP 地址发送 `GET /api/executors`、`POST /api/execute`。
2. **编辑器插件**或 **GameExecutor** 直接在进程内处理请求，**不再需要单独的 Node 中继服务**。

HTTP API **不对调用方鉴权**，须视为高权限本地服务：建议 **项目设置 → Hastur Operation GD → HTTP bind host** 保持 `127.0.0.1`（默认），或仅在完全信任的网络中使用。

## 项目结构

```
hastur-operation-plugin/
├── addons/
│   └── hasturoperationgd/          # Godot 插件（拷贝到项目目录即可）
│       ├── plugin.cfg               # 插件配置
│       ├── hasturoperationgd.gd     # 入口，EditorPlugin
│       ├── executor_backend.gd      # 后端（本地 + HTTP 远程执行）
│       ├── hastur_executor_http_api.gd  # 精简 HTTP 服务
│       ├── gdscript_executor.gd     # 编译并执行 GDScript 代码片段
│       ├── execution_context.gd     # 执行结果收集器
│       ├── executor_dock.gd         # 编辑器 Dock 面板 UI
│       ├── game_executor.gd         # 可选 Autoload — 游戏进程内 HTTP API
│       └── hastur_operation_gd_plugin_settings.gd  # 项目设置
│
└── .claude/skills/
	└── godot-remote-executor/       # Coding agent 技能定义
		└── SKILL.md                 # Agent 操控 Godot 的指令文档
```

## 使用方法

### 环境要求

- [Godot 4.x](https://godotengine.org/)（已测试 4.6+）
- 支持加载自定义技能的 coding agent（如 opencode、Claude）

### 第一步：在 Godot 中安装插件

将 `addons/hasturoperationgd/` 拷贝到项目的 `addons/` 下，在 **项目 → 项目设置 → 插件** 中启用。

在 **项目设置 → Hastur Operation GD** 中配置：

- **HTTP bind host**：默认 `127.0.0.1`
- **HTTP port**：编辑器 API，默认 `5302`
- **Game HTTP port**：`GameExecutor` Autoload 的游戏进程 API，默认 `5303`；设为 `0` 表示关闭

（若曾使用 `hastur_operation/broker_host`、`broker_port`，请改用上方的 HTTP 相关设置。）

插件成功绑定端口后，Dock 会显示 **Remote HTTP listening** 及 Base URL（例如 `http://127.0.0.1:5302`）。若绑定失败（端口占用），请查看 Output 并更换端口。

### 第二步：把 Base URL 告诉 Coding Agent

加载 `godot-remote-executor` 技能，告知编辑器 **Base URL**（默认 `http://127.0.0.1:5302`）。若要操控**运行中的游戏**，需配置 `GameExecutor` Autoload，并使用游戏端 URL（默认 `http://127.0.0.1:5303`）。

示例（编辑器）：

```bash
curl -s http://127.0.0.1:5302/api/executors

curl -s -X POST \
  -H "Content-Type: application/json" \
  -d '{"code": "print(\"hello from the other side\")"}' \
  http://127.0.0.1:5302/api/execute
```

## API 参考

### `GET /api/health`

健康检查；`data` 中含 `http_host`、`http_port`。

### `GET /api/executors`

仅返回**当前该 HTTP 监听进程**对应的执行器信息（数组长度为 1）。

### `POST /api/execute`

在本进程内执行 GDScript。

**请求体：**

| 字段            | 类型   | 说明                                      |
| --------------- | ------ | ----------------------------------------- |
| `code`          | string | 要执行的 GDScript（必填）                 |
| `executor_id`   | string | 若填写则须与本实例一致                     |
| `project_name`  | string | 项目名模糊匹配（可选）                     |
| `project_path`  | string | 项目路径模糊匹配（可选）                   |
| `type`          | string | `"editor"` / `"game"`，须与本监听进程一致 |

若不提供 `executor_id`、`project_name`、`project_path`，请求发往哪个地址就在哪个实例上执行；若提供且不匹配则返回 404。

**响应示例：**

```json
{
  "success": true,
  "data": {
	"compile_success": true,
	"compile_error": "",
	"run_success": true,
	"run_error": "",
	"outputs": [["key", "value"]]
  }
}
```

### 执行模式

**代码片段模式**（默认）：代码中不含 `extends` 时，会自动包装为 `@tool extends RefCounted` 类，并注入 `executeContext`。

**完整类模式**：代码含 `extends` 时需自行定义 `func execute(executeContext):`。

## 安全提醒

本插件会在编辑器或游戏进程中执行任意代码。**HTTP API 不提供鉴权**：任何能访问所绑定地址与端口的客户端都可执行代码。

- **切勿把监听地址暴露到公网**，优先使用 `127.0.0.1`。
- **务必信任 coding agent 与当前网络环境。**

## 许可证

MIT
