#if canImport(UIKit)
   import AuthenticationServices
   import UIKit

   /// `ASWebAuthenticationSession` for the Authentik sign-in. Uses the shared browser
   /// session so an existing Authentik login (and passkeys) carry over.
   public final class BrowserAuthenticator: NSObject, WebAuthenticator, ASWebAuthenticationPresentationContextProviding, @unchecked Sendable {
      override public init() {}

      public func authenticate(url: URL, callbackScheme: String) async throws -> URL {
         try await withCheckedThrowingContinuation { continuation in
            Task { @MainActor in
               let session = ASWebAuthenticationSession(url: url, callback: .customScheme(callbackScheme)) { callback, error in
                  if let callback {
                     continuation.resume(returning: callback)
                  }
                  else if let error = error as? ASWebAuthenticationSessionError, error.code == .canceledLogin {
                     continuation.resume(throwing: AuthError.cancelled)
                  }
                  else {
                     continuation.resume(throwing: error ?? AuthError.cancelled)
                  }
               }
               session.presentationContextProvider = self
               session.prefersEphemeralWebBrowserSession = false
               if !session.start() { continuation.resume(throwing: AuthError.cancelled) }
            }
         }
      }

      @MainActor
      public func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
         let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
         return scenes.flatMap(\.windows).first(where: \.isKeyWindow) ?? ASPresentationAnchor()
      }
   }
#endif
