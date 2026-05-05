import express, { type Request, type Response } from 'express'
import { ExecutorManager } from './executor-manager.js'
import { TcpServer } from './tcp-server.js'
import type { ApiResponse } from './types.js'

export function createHttpApp(
	executorManager: ExecutorManager,
	tcpServer: TcpServer,
	tcpPort: number,
	httpPort: number,
) {
	const app = express()

	app.use(express.json())

	app.get('/api/health', (_req: Request, res: Response) => {
		res.json({
			success: true,
			data: {
				status: 'ok',
				tcp_port: tcpPort,
				http_port: httpPort,
				executors_connected: executorManager.getAll().length,
			},
		})
	})

	app.get('/api/executors', (_req: Request, res: Response) => {
		const executors = executorManager.getAll()
		const response: ApiResponse = {
			success: true,
			data: executors,
		}
		if (executors.length === 0) {
			response.hint = 'No Hastur Executors are currently connected. Ensure the Hastur Executor plugin is enabled in a Godot editor and can reach the broker-server.'
		}
		res.json(response)
	})

	app.post('/api/executors', (_req: Request, res: Response) => {
		res.status(405).json({
			success: false,
			error: 'Method not allowed',
			hint: 'GET /api/executors to list executors, POST /api/execute to execute code',
		})
	})

	app.post('/api/execute', async (req: Request, res: Response) => {
		const { code, executor_id, project_name, project_path, type } = req.body

		if (!code) {
			res.status(400).json({
				success: false,
				error: 'Missing required field: code',
				hint: 'The request body must include a \'code\' field (string) containing the GDScript code to execute. Example: {"code": "print(\\"hello\\")"}',
			})
			return
		}

		if (!executor_id && !project_name && !project_path) {
			res.status(400).json({
				success: false,
				error: 'No executor identifier provided',
				hint: 'Provide one of: executor_id (exact match), project_name (fuzzy match), or project_path (fuzzy match) to target a specific executor. Optionally specify type: "editor" or "game".',
			})
			return
		}

		const executorType = type as ('editor' | 'game') | undefined
		let executor
		if (executor_id) {
			executor = executorManager.findById(executor_id)
			if (executor && executorType && executor.type !== executorType) {
				executor = undefined
			}
		} else if (project_name) {
			executor = executorManager.findByProjectName(project_name, executorType)
		} else if (project_path) {
			executor = executorManager.findByProjectPath(project_path, executorType)
		}

		if (!executor) {
			res.status(404).json({
				success: false,
				error: 'No connected Hastur Executor matched the query',
				hint: 'Use GET /api/executors to list available executors. You can filter by type: "editor" or "game".',
			})
			return
		}

		try {
			const result = await tcpServer.sendExecute(executor.id, code, 'gdscript')
			res.json({ success: true, data: result })
		} catch (err: unknown) {
			const error = err as Error
			if (error.message === 'TIMEOUT') {
				res.status(504).json({
					success: false,
					error: 'Executor execution timed out (30s)',
					hint: 'The code execution took too long. Try simplifying the code or check if the Godot editor is responsive.',
				})
			} else {
				res.status(500).json({
					success: false,
					error: error.message || 'Execution failed',
					hint: 'An unexpected error occurred during code execution.',
				})
			}
		}
	})

	app.use((_req: Request, res: Response) => {
		res.status(404).json({
			success: false,
			error: 'Route not found',
			hint: 'Available endpoints: GET /api/executors - List connected Hastur Executors, POST /api/execute - Execute code on a Hastur Executor',
		})
	})

	return app
}


