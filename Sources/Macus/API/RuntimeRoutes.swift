import Foundation

public struct RuntimeRoutes: Sendable {
  public let service: RuntimeService
  public init(service: RuntimeService) { self.service = service }
  public func handle(_ request: HTTPRequest) async -> HTTPResponse {
    struct Stop: Decodable { let force: Bool }
    struct Delete: Decodable { let confirm: Bool }
    do {
      switch (request.method, request.path) {
      case ("GET", "/v1/runtime/status"): return try HTTPResponse(value: await service.status())
      case ("GET", "/v1/runtime/capabilities"):
        return try HTTPResponse(value: await service.capabilities())
      case ("GET", "/v1/runtime/health"): return try HTTPResponse(value: await service.health())
      case ("GET", "/v1/runtime/config"): return try HTTPResponse(value: await service.config())
      case ("POST", "/v1/runtime/create"):
        return try HTTPResponse(
          value: await service.create(decode(RuntimeConfiguration.self, request.body)))
      case ("PUT", "/v1/runtime/config"):
        return try HTTPResponse(
          value: await service.update(decode(RuntimeConfiguration.self, request.body)))
      case ("POST", "/v1/runtime/start"): return try HTTPResponse(value: await service.start())
      case ("POST", "/v1/runtime/restart"): return try HTTPResponse(value: await service.restart())
      case ("POST", "/v1/runtime/stop"):
        let force = request.body.isEmpty ? false : try decode(Stop.self, request.body).force
        return try HTTPResponse(value: await service.stop(force: force))
      case ("DELETE", "/v1/runtime"):
        return try HTTPResponse(
          value: await service.delete(confirm: decode(Delete.self, request.body).confirm))
      default: throw RuntimeError(.notFound, "Unknown runtime route")
      }
    } catch { return HTTPResponse.error(error) }
  }
  private func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
    do { return try JSON.decoder().decode(type, from: data) } catch {
      throw RuntimeError(.invalidRequest, "Invalid JSON payload: \(error.localizedDescription)")
    }
  }
}
