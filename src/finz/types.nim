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
    supportsInstantBatch*: bool  # HKIPM (SEPA instant Sammelüberweisung)

  Account* = object
    iban*: string
    bic*: string
    number*: string
    subaccount*: string
    blz*: string
    holder*: string

  VopItem* = object
    ## One Verification-of-Payee result. Single transfers yield one item
    ## (from the HIVPP result DEG); batch transfers one per payment (from
    ## the pain.002 status report the bank returns instead).
    iban*: string
    submittedName*: string   # name as sent by us (pain.002 OrgnlTxRef)
    actualName*: string      # name suggested by the bank (close match)
    amount*: string
    code*: string            # RCVC match, RVMC close, RVNM no match, RVNA unavailable

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
    vopItems*: seq[VopItem]  # payee verification result per payment (batch: N)

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

  Saldo* = object
    ## Balance from a HISAL response (booked balance plus extras).
    balance*: float         ## booked balance (Saldo), negative if in debit
    currency*: string
    date*: string           # balance date YYYYMMDD
    pending*: float         # pending/registered amount (0 if not reported)
    available*: float       # verfügbarer Betrag (0 if not reported)

  BalanceResult* = object
    success*: bool
    saldo*: Saldo
    errorCode*: string
    errorMsg*: string
    tanRequired*: bool
    orderRef*: string
    tanChallenge*: string