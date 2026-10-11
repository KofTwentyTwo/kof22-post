import Foundation

extension URL {
   /// Builds a URL from a literal that is fixed at compile time, such as the API host or
   /// the OAuth endpoints. A malformed literal is a programming error, so it stops the
   /// app with a message instead of being force-unwrapped (K22-CODE-SW-03).
   public init(literal: StaticString) {
      guard let url = URL(string: "\(literal)") else {
         preconditionFailure("Invalid URL literal: \(literal)")
      }
      self = url
   }
}
