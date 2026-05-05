import { Command } from 'commander'
import { ExecutorManager } from './executor-manager.js'
import { TcpServer } from './tcp-server.js'
import { createHttpApp } from './http-server.js'

const program = new Command()

program
	.option('--tcp-port <port>', 'TCP port for executor connections', '5301')
	.option('--http-port <port>', 'HTTP port for API', '5302')
	.option('--host <host>', 'Host to bind to', 'localhost')
	.parse()

const options = program.opts()
const tcpPort = parseInt(options.tcpPort as string, 10)
const httpPort = parseInt(options.httpPort as string, 10)
const host = options.host as string

const executorManager = new ExecutorManager()
const tcpServer = new TcpServer(executorManager)
const app = createHttpApp(executorManager, tcpServer, tcpPort, httpPort)

async function main(): Promise<void> {
	await tcpServer.start(host, tcpPort)
	console.log(`TCP server listening on ${host}:${tcpPort}`)

	const httpServer = app.listen(httpPort, host, () => {
		console.log(`HTTP server listening on ${host}:${httpPort}`)
	})

	const shutdown = async (): Promise<void> => {
		console.log('Shutting down...')
		await tcpServer.stop()
		httpServer.close()
		process.exit(0)
	}

	process.on('SIGINT', shutdown)
	process.on('SIGTERM', shutdown)
}

main().catch((err: unknown) => {
	console.error('Failed to start:', err)
	process.exit(1)
})
