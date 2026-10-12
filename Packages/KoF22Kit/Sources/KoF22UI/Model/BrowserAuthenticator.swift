/*
 * Copyright (c) 2026 James Maes (KofTwentyTwo)
 * SPDX-License-Identifier: MIT
 */

#if canImport(UIKit)
   import AuthenticationServices
   import UIKit

   /// `ASWebAuthenticationSession` for the Authentik sign-in. Uses the shared browser
   /// session so an existing Authentik login (and passkeys) carry over.
   public final class BrowserAuthenticator: NSObject, WebAuthenticator, ASWebAuthenticationPresentationContextProviding, @unchecked Sendable {
      /// Creates an authenticator; it holds no state between sign-ins.
      override public init() {}

      /// Opens `url` in the system browser sheet and returns the callback URL that carries
      /// the authorization code. Closing the sheet, or a session that cannot start, throws
      /// `AuthError.cancelled` so the caller can treat it as a user cancel.
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
               if !session.start() {
                  Log.auth.warning("The web authentication session could not start")
                  continuation.resume(throwing: AuthError.cancelled)
               }
            }
         }
      }

      /// Presents the sheet over the key window, or a new window in the first connected
      /// scene when no window is key.
      @MainActor
      public func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
         let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
         if let keyWindow = scenes.flatMap(\.windows).first(where: \.isKeyWindow) {
            return keyWindow
         }
         guard let scene = scenes.first else {
            /////////////////////////////////////////////////////////////////////
            // Sign-in starts from a button on screen, so a window scene must  //
            // exist; reaching this is a programming error, not a user state.  //
            /////////////////////////////////////////////////////////////////////
            Log.auth.fault("Sign-in was started without a connected window scene")
            preconditionFailure("Sign-in requires a connected window scene")
         }
         return ASPresentationAnchor(windowScene: scene)
      }
   }
#endif
