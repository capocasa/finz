## Shared types: segments, interaction hooks, bank and transfer data.

const
  FintsVersion* = "300"
  HbciVersion* = 300

type
  FintsError* = object of CatchableError

  Segment* = object
    ## One parsed FinTS segment (header fields plus split data elements).
    name*: string
    version*: int
    num*: int
    data*: seq[string]

  UiHooks* = object
    ## User interaction hooks. The library never touches the terminal;
    ## the embedding application decides what a prompt or a wait means.
    onDebug*: proc (msg: string) {.closure.}   ## protocol trace
    onInfo*: proc (msg: string) {.closure.}    ## notable events
    onPrompt*: proc (msg: string) {.closure.}  ## user must act (TAN approval)
    onWait*: proc () {.closure.}               ## block until user confirms

  TanMethod* = object
    id*: string
    name*: string
    version*: int
    processType*: int  # 1=one-step, 2=two-step, 4=decoupled

  BankParams* = object
    bpdVersion*: int
    updVersion*: int
    supportedTanMethods*: seq[TanMethod]
    supportsInstantPayment*: bool

  Account* = object
    iban*: string
    bic*: string
    number*: string
    subaccount*: string
    blz*: string
    holder*: string

  TransferRequest* = object
    recipientName*: string
    recipientIban*: string
    recipientBic*: string
    amount*: float
    currency*: string
    reference*: string
    instant*: bool

  TransferResult* = object
    success*: bool
    tanRequired*: bool
    tanChallenge*: string
    tanMediaName*: string
    orderRef*: string
    errorCode*: string
    errorMsg*: string

  Transaction* = object
    date*: string           # Booking date (YYYYMMDD)
    valutaDate*: string     # Value date (YYYYMMDD)
    amount*: float          # Positive = credit, negative = debit
    currency*: string
    name*: string           # Counterparty name
    iban*: string           # Counterparty IBAN
    bic*: string            # Counterparty BIC
    reference*: string      # Payment reference
    bookingText*: string    # Booking type (e.g. "UEBERWEISUNG")
    endToEndId*: string     # End-to-end ID

  StatementResult* = object
    success*: bool
    transactions*: seq[Transaction]
    errorCode*: string
    errorMsg*: string
    tanRequired*: bool
    orderRef*: string
    tanChallenge*: string
    nextOffset*: string