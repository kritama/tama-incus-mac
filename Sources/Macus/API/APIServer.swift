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
      do { request = try await SocketIO.run { try HTTPRequest.read(from: socket) } } catch {
        let response = HTTPResponse.error(error)
        _ = try? await SocketIO.run { try response.write(to: socket) }
        return
      }
      let response = await routes.handle(request)
      _ = try? await SocketIO.run { try response.write(to: socket) }
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
