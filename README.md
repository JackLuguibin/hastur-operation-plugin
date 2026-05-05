[中文文档](README.zh.md)

# Hastur Operation Plugin

A Godot editor plugin that exposes a small HTTP API so coding agents can remotely execute arbitrary GDScript in the editor (and optionally in a running game via an autoload).

Yes, you read that correctly. Arbitrary code. Over HTTP. On purpose this time.

## What Problem Does This Solve?

Coding agents are frighteningly good at executing shell commands. They can `npm install`, `git commit`, `docker compose up`, and generally wreak productive havoc across your filesystem — all from the comfort of a terminal.

But a Godot editor? That's a GUI application. You can't exactly `curl` your way into rearranging scene nodes. Until now.

This plugin gives coding agents a "shell" into the Godot editor. Through a simple REST API served **inside the plugin**, an agent can:

- Inspect and manipulate the scene tree
- Create, modify, or delete nodes
- Query and change project settings
- Run editor operations
- Basically anything you could do by typing GDScript into the editor's script panel

Think of it as giving your AI assistant a Godot-sized screwdriver.

## How It Works

```
┌─────────────────┐         ┌──────────────────────────────┐
│   Coding Agent  │  HTTP   │  Godot Editor               │
│  (opencode,     │ ──────> │  Hastur plugin binds host:   │
│   Claude, etc.) │ <────── │  port (default 127.0.0.1:   │
└─────────────────┘         │  5302) → executes GDScript  │
                            └──────────────────────────────┘

 Optional second HTTP listener (running game process):

┌─────────────────┐         ┌──────────────────────────────┐
│   Coding Agent  │  HTTP   │  Game + GameExecutor autoload│
│                 │ ──────> │  (default 127.0.0.1:5303)    │
└─────────────────┘         └──────────────────────────────┘
```

1. **Coding Agent** sends `GET /api/executors` or `POST /api/execute` to the **editor** HTTP endpoint (or to the **game** endpoint when targeting runtime code).
2. The **Hastur plugin** (editor) or **GameExecutor** autoload (game) handles the request directly — no separate relay process.

The HTTP API does **not** authenticate callers — treat it as a privileged local service: keep **Project Settings → Hastur Operation GD → HTTP bind host** on `127.0.0.1` (default) or a network you fully trust.

## Project Structure

```
hastur-operation-plugin/
├── addons/
│   └── hasturoperationgd/          # The Godot plugin (copy this to your project)
│       ├── plugin.cfg               # Plugin manifest
│       ├── hasturoperationgd.gd     # Entry point — EditorPlugin
│       ├── executor_backend.gd      # Backend (local + HTTP remote execution)
│       ├── hastur_executor_http_api.gd  # Minimal HTTP server (health, executors, execute)
│       ├── gdscript_executor.gd     # Compiles and runs GDScript snippets
│       ├── execution_context.gd     # Output collector for execution results
│       ├── executor_dock.gd         # Dock UI for the editor panel
│       ├── game_executor.gd         # Optional autoload — HTTP API inside the game process
│       └── hastur_operation_gd_plugin_settings.gd  # Project settings
│
└── .claude/skills/
    └── godot-remote-executor/       # Skill definition for coding agents
        └── SKILL.md                 # Instructions for agent-driven Godot control
```

## Getting Started

### Prerequisites

- [Godot 4.x](https://godotengine.org/) (tested with 4.6+)
- A coding agent that supports loading custom skills (e.g., opencode, Claude)

### Step 1: Install the Plugin in Godot

Copy the `addons/hasturoperationgd/` folder into your Godot project's `addons/` directory, then enable the plugin in **Project → Project Settings → Plugins**.

Under **Project Settings → Hastur Operation GD**:

- **HTTP bind host** — default `127.0.0.1`
- **HTTP port** — editor API, default `5302`
- **Game HTTP port** — runtime API when using the `GameExecutor` autoload, default `5303`; set to `0` to disable

*(If you previously used `hastur_operation/broker_host` / `broker_port`, those settings are obsolete — configure the HTTP fields above instead.)*

When the editor plugin loads successfully, the dock shows **Remote HTTP listening** with the base URL (for example `http://127.0.0.1:5302`). If binding fails (port already in use), check the Output panel and adjust the port.

### Step 2: Give Your Coding Agent the Base URL

Load the `godot-remote-executor` skill and tell the agent the editor **base URL** (defaults to `http://127.0.0.1:5302`). To drive code in a **running game**, configure the `GameExecutor` autoload and use the game URL (defaults to `http://127.0.0.1:5303`).

Example (editor):

```bash
# This instance's executor metadata (always a single entry — this listener)
curl -s http://127.0.0.1:5302/api/executors

# Execute code (minimal body — targets whoever owns this port)
curl -s -X POST \
  -H "Content-Type: application/json" \
  -d '{"code": "print(\"hello from the other side\")"}' \
  http://127.0.0.1:5302/api/execute
```

## API Reference

### `GET /api/health`

Health check. Response `data` includes `http_host` and `http_port`.

### `GET /api/executors`

Returns metadata for **this** HTTP listener only (an array with one object).

### `POST /api/execute`

Execute GDScript in the process that owns this HTTP port.

**Request body:**

| Field           | Type   | Description                                      |
| --------------- | ------ | ------------------------------------------------ |
| `code`          | string | GDScript code to execute (required)              |
| `executor_id`   | string | Must match this instance if provided             |
| `project_name`  | string | Fuzzy substring match on project name (optional) |
| `project_path`  | string | Fuzzy substring match on project path (optional) |
| `type`          | string | `"editor"` or `"game"` — must match this listener |

If you omit `executor_id`, `project_name`, and `project_path`, the snippet runs on the instance you connected to. Use identifiers when you want the server to reject mismatched payloads.

**Response:**

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

### Execution Modes

**Snippet mode** (default): If your code doesn't contain `extends`, it's automatically wrapped in a `@tool extends RefCounted` class with an `executeContext` variable available for returning results:

```gdscript
var tree = Engine.get_main_loop() as SceneTree
var scene = tree.edited_scene_root
executeContext.output("scene_name", scene.name)
executeContext.output("child_count", str(scene.get_child_count()))
```

**Full class mode**: If your code contains `extends`, you must define `func execute(executeContext):` yourself:

```gdscript
extends Node

func execute(executeContext):
    var root = get_tree().root
    executeContext.output("viewport_size", str(root.get_visible_rect().size))
```

## A Note on Security

This plugin literally executes arbitrary code in your editor (or game). The HTTP API has **no authentication** — anyone who can reach the bound host/port can run code. You should:

- **Never expose these ports to the public internet.** Prefer `127.0.0.1`.
- **Trust your coding agent and your network.** If the port is reachable, assume full access to that Godot process.

## License

MIT
