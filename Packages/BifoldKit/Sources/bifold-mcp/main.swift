import BifoldBridgeKit
import Darwin
import Foundation

// bifold-mcp — serwer MCP (stdio) uruchamiany przez CLI agenta; przekazuje wiadomości
// do aplikacji przez gniazdo Unix. Użycie: bifold-mcp --socket <ścieżka>
signal(SIGPIPE, SIG_IGN)
do {
    let options = try Bridge.options(arguments: CommandLine.arguments, environment: ProcessInfo.processInfo.environment)
    try Bridge.run(options)
    exit(0)
} catch {
    FileHandle.standardError.write(Data("bifold-mcp: \(error)\n".utf8))
    exit(1)
}
