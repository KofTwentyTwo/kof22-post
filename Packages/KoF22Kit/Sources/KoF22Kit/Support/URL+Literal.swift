/*
 * Copyright (c) 2026 James Maes (KofTwentyTwo)
 * SPDX-License-Identifier: MIT
 */

import Foundation

extension URL {
   /// Builds a URL from a literal that is fixed at compile time, such as the API host or
   /// the OAuth endpoints. A malformed literal is a programming error, so it stops the
   /// app (the backtrace names the caller) instead of being force-unwrapped
   /// (K22-CODE-SW-03).
   public init(literal: StaticString) {
      //////////////////////////////////////////////////////////////////
      // One line on purpose: the trap cannot run in a test, and a    //
      // message would add an autoclosure that coverage counts apart. //
      //////////////////////////////////////////////////////////////////
      guard let url = URL(string: "\(literal)") else { preconditionFailure() }
      self = url
   }
}
