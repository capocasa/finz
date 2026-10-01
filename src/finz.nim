## fint - FinTS 3.0 client library for Nim.
##
## SEPA (instant) transfers with Verification of Payee, camt/MT940
## statement retrieval, and decoupled TAN (pushTAN, SecureGo) flows.
## Stdlib only. The library never touches the terminal; user interaction
## is injected via UiHooks on the client.

import finz/[types, wire, pain, statement, client]
export types, wire, pain, statement, client
