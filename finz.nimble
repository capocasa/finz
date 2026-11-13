# Package

version       = "0.2.0"
author        = "Carlo Capocasa"
description   = "FinTS 3.0 client library: SEPA transfers, VoP, statements"
license       = "MIT"
srcDir        = "src"

# Dependencies

requires "nim >= 2.0.0"
task test, "Run tests":
  exec "nim c -r --path:src tests/test_finz.nim"
