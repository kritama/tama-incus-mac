import Foundation

public struct RuntimeError: Error, Sendable, Codable, Equatable, LocalizedError {
  public enum Code: String, Codable, Sendable {
    case conflict
    case invalidConfiguration = "invalid_configuration"
    case notFound = "not_found"
    case unavailable, timeout, io
    case invalidRequest = "invalid_request"
  }
  public let code: Code
  public let message: String
  public init(_ code: Code, _ message: String) {
    self.code = code
    self.message = message
  }
  public var errorDescription: String? { message }
  public var httpStatus: Int {
    switch code {
    case .conflict: 409
    case .invalidConfiguration, .invalidRequest: 400
    case .notFound: 404
    case .timeout: 504
    case .unavailable, .io: 503
    }
  }
}

public enum JSON {
  public static func encoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.keyEncodingStrategy = .convertToSnakeCase
    encoder.outputFormatting = [.sortedKeys]
    return encoder
  }
  public static func decoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    return decoder
  }
}
