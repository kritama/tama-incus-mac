import Foundation

@MainActor
public final class APIServer {
  private let control: UnixListener
  private let incus: UnixListener
  public init(service: RuntimeService, paths: RuntimePaths) throws {
    let routes = RuntimeRoutes(service: service)
    control = try UnixListener(path: paths.controlSocket) { socket in
      socket.timeout(seconds: 15)
      let request: HTTPRequest
      do { request = try await Task.detached { try HTTPRequest.read(from: socket) }.value } catch {
        let response = HTTPResponse.error(error)
        _ = await Task.detached { try? response.write(to: socket) }.value
        return
      }
      let response = await routes.handle(request)
      _ = await Task.detached { try? response.write(to: socket) }.value
    }
    do {
      incus = try UnixListener(path: paths.incusSocket) { socket in
        do {
          let stream = try await service.openIncusStream()
          await SocketRelay.relay(socket, stream.socket)
          await stream.release()
        } catch { socket.shutdown() }
      }
    } catch {
      control.stop()
      throw error
    }
  }
  public func stop() {
    control.stop()
    incus.stop()
  }
}
