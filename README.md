# finz

FinTS 3.0 client library for Nim. SEPA (instant) transfers with
Verification of Payee, camt/MT940 statement retrieval, decoupled TAN
(pushTAN, SecureGo), no dependencies beyond the standard library.

```nim
import finz

var client = newFintsClient(url, blz, user, pin, productId)
client.account = Account(iban: iban, bic: bic, blz: blz)
defer: client.close()

let r = client.transfer(TransferRequest(
  recipientName: "Erika Musterfrau",
  recipientIban: "DE75512108001245126199",
  amount: 100.50,
  reference: "Invoice 12345"
))
```

The library never touches the terminal. User interaction (TAN approval
prompts, press-enter waits, protocol tracing) is injected via hooks:

```nim
client.ui = UiHooks(
  onPrompt: proc (msg: string) = stderr.writeLine "approve: " & msg,
  onWait: proc () = discard stdin.readLine(),
  onDebug: proc (msg: string) = stderr.writeLine msg
)
```

Higher-level one-shot helpers that include TAN orchestration:

```nim
let stmt = fetchStatements(url, blz, user, pin, productId,
                           iban, bic, "20250101", "20250401")
let res = makeTransfer(url, blz, user, pin, productId,
                       iban, bic, "Max Mustermann",
                       "DE75512108001245126199", "", "Erika Musterfrau",
                       100.50, "Invoice 12345")
```

`productId` is the FinTS product registration of the calling application,
not of finz. Get your own from your bank's FinTS registration office.

MIT license.
