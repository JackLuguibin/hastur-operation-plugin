[English](README.md)

# Hastur Operation Plugin

一个 Godot 编辑器插件，可通过 HTTP API 远程执行任意 GDScript 代码。

## 它是做什么的？

如今的 coding agent 执行 shell 命令已经非常熟练——`npm install`、`git commit`、`docker compose up`，在文件系统里操作自如，终端一行命令即可完成。

但 Godot 编辑器是一个 GUI 应用，无法通过 `curl` 之类的命令行工具来操控场景节点。此前做不到，现在可以了。

本插件为 coding agent 提供了一个操控 Godot 编辑器的"shell"接口。通过 REST API，agent 可以做到：

- 查看和操作场景树
- 创建、修改、删除节点
- 读取和修改项目设置
- 执行各类编辑器操作
- 凡是在编辑器脚本面板中手写 GDScript 能做到的事，均可完成

简而言之，就是给 AI 助手提供了一把专门操作 Godot 编辑器的螺丝刀。

## 工作原理

架构简洁清晰，采用三级转发：

```
┌─────────────────┐         ┌─────────────────┐         ┌─────────────────────┐
│   Coding Agent  │  HTTP   │  Broker Server   │   TCP   │  Godot 编辑器        │
│  (opencode,     │ ──────> │  (Node.js/Express│ ──────> │  (Hastur Executor   │
│   Claude 等)    │ <────── │   + TCP 中继)    │ <────── │   插件)              │
└─────────────────┘         └─────────────────┘         └─────────────────────┘
```

1. **Coding Agent** 发送 `POST /api/execute` 请求，携带 GDScript 代码及用于选定执行器的标识字段。
2. **Broker Server** 通过 TCP 定位目标编辑器并转发代码。
3. **Hastur Executor 插件**（运行在 Godot 编辑器内部）接收代码，编译执行后将结果原路返回。

中间设置 Broker Server 的原因在于：Godot 自身的 HTTP 能力较为有限。当前 HTTP API **不对请求方做鉴权** —— 须将其视为高权限本地服务：默认绑定 `localhost`，或仅部署在你完全信任的网络上。

## 项目结构

```
hastur-operation-plugin/
├── addons/
│   └── hasturoperationgd/          # Godot 插件（拷贝到项目目录即可）
│       ├── plugin.cfg               # 插件配置
│       ├── hasturoperationgd.gd     # 入口，EditorPlugin
│       ├── executor_backend.gd      # 后端协调器（本地 + 远程执行）
│       ├── gdscript_executor.gd     # 编译并执行 GDScript 代码片段
│       ├── execution_context.gd     # 执行结果收集器
│       ├── broker_client.gd         # 连接 broker server 的 TCP 客户端
│       ├── executor_dock.gd         # 编辑器 Dock 面板 UI
│       └── hastur_operation_gd_plugin_settings.gd  # 项目设置
│
├── broker-server/                   # 中继服务器（Node.js）
│   ├── src/
│   │   ├── index.ts                 # 命令行入口（commander）
│   │   ├── http-server.ts           # Express HTTP API（执行、执行器列表、健康检查）
│   │   ├── tcp-server.ts            # TCP 中继，转发至 Godot 插件
│   │   ├── executor-manager.ts      # 管理已连接的编辑器实例
│   │   └── types.ts                 # 共享的 TypeScript 类型定义
│   └── package.json
│
└── .claude/skills/
	└── godot-remote-executor/       # Coding agent 技能定义
		└── SKILL.md                 # Agent 操控 Godot 的指令文档
```

## 使用方法

### 环境要求

- [Godot 4.x](https://godotengine.org/)（已测试 4.6+）
- [Node.js](https://nodejs.org/) 18+（用于 broker server）
- 支持加载自定义技能的 coding agent（如 opencode、Claude）

### 第一步：启动 Broker Server

```bash
cd broker-server
npm install
npm run dev
```

启动后，HTTP 服务监听 `localhost:5302`，TCP 服务监听 `localhost:5301`。

也可手动指定主机与端口：

```bash
npx tsx src/index.ts --http-port 8080 --tcp-port 8081 --host localhost
```

### 第二步：在 Godot 中安装插件

将 `addons/hasturoperationgd/` 文件夹拷贝到 Godot 项目的 `addons/` 目录下，然后在 **项目 → 项目设置 → 插件** 中启用。

插件启动后会自动连接 broker server（默认地址 `localhost:5301`）。连接配置可在 **项目设置 → Hastur Operation GD** 中修改。

连接成功后，编辑器 Dock 面板会显示绿色状态。若未显示，请检查 broker server 是否正在运行。

### 第三步：将控制权交给 Coding Agent

在 coding agent 中加载 `godot-remote-executor` 技能，并告知 **Base URL**（默认为 `http://localhost:5302`）。

之后 agent 即可发现已连接的编辑器并在其上执行 GDScript 代码。示例：

```bash
# 查看已连接的编辑器
curl -s http://localhost:5302/api/executors

# 执行代码
curl -s -X POST \
  -H "Content-Type: application/json" \
  -d '{"code": "print(\"hello from the other side\")", "project_name": "my-game"}' \
  http://localhost:5302/api/execute
```

## API 参考

### `GET /api/health`

健康检查。

### `GET /api/executors`

列出所有已连接的 Godot 编辑器实例。

### `POST /api/execute`

在指定编辑器上执行 GDScript 代码。

**请求体：**

| 字段            | 类型   | 说明                      |
| --------------- | ------ | ------------------------- |
| `code`          | string | 要执行的 GDScript 代码    |
| `executor_id`   | string | 精确匹配执行器 ID（可选） |
| `project_name`  | string | 项目名模糊匹配（可选）    |
| `project_path`  | string | 项目路径模糊匹配（可选）  |

三个定位字段任选其一即可，用于指定目标编辑器。

**响应：**

```json
{
  "success": true,
  "data": {
	"request_id": "uuid",
	"compile_success": true,
	"compile_error": "",
	"run_success": true,
	"run_error": "",
	"outputs": [["key", "value"]]
  }
}
```

### 执行模式

**代码片段模式**（默认）：当代码中不含 `extends` 时，会自动包装为 `@tool extends RefCounted` 类，并注入 `executeContext` 变量用于返回结果：

```gdscript
var tree = Engine.get_main_loop() as SceneTree
var scene = tree.edited_scene_root
executeContext.output("scene_name", scene.name)
executeContext.output("child_count", str(scene.get_child_count()))
```

**完整类模式**：当代码中包含 `extends` 时，需自行定义 `func execute(executeContext):`：

```gdscript
extends Node

func execute(executeContext):
	var root = get_tree().root
	executeContext.output("viewport_size", str(root.get_visible_rect().size))
```

## 安全提醒

本插件会在编辑器中执行任意代码，这一点务必清楚。**HTTP API 不提供鉴权**：任何能访问 broker HTTP 端口的客户端都可以列出执行器并在已连接的编辑器或游戏进程中执行代码。因此：

- **切勿将 broker server 暴露至公网。** 默认绑定 `localhost`，或仅放在你完全信任的内网环境中。
- **务必信任 coding agent 与当前网络。** 只要端口可达，即应视为可获得与编辑器等同的操控能力。

## 许可证

MIT
