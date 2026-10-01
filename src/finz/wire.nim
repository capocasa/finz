## FinTS wire format: escaping, amounts, segment building and parsing.

import std/[strutils, strformat, times]
import finz/types

proc generateReference*(): string =
  ## Generate a message reference
  let now = now()
  result = now.format("yyyyMMddHHmmss")

proc escapeFintsData*(s: string): string =
  ## Escape special characters in FinTS segment data: ? + : ' @
  result = s
  result = result.replace("?", "??")
  result = result.replace("+", "?+")
  result = result.replace(":", "?:")
  result = result.replace("'", "?'")
  result = result.replace("@", "?@")

proc unescapeFintsData*(s: string): string =
  ## Unescape FinTS data
  result = ""
  var i = 0
  while i < s.len:
    if i + 1 < s.len and s[i] == '?':
      result.add(s[i + 1])
      i += 2
    else:
      result.add(s[i])
      i += 1

proc extractBinary*(s: string): string =
  ## Extract binary content from @len@data format
  if s.len > 2 and s[0] == '@':
    var lenEnd = 1
    while lenEnd < s.len and s[lenEnd] in '0'..'9':
      lenEnd += 1
    if lenEnd < s.len and s[lenEnd] == '@':
      return s[lenEnd + 1 .. ^1]
  return s

proc formatAmount*(amount: float): string =
  ## Format amount with comma decimal separator (German format)
  let parts = ($amount).split('.')
  if parts.len == 2:
    result = parts[0] & "," & parts[1].alignLeft(2, '0')[0..1]
  else:
    result = parts[0] & ",00"

proc buildSegment*(name: string, version, num: int, data: seq[string]): string =
  ## Build a FinTS segment, omitting trailing empty fields
  let header = fmt"{name}:{num}:{version}"
  if data.len > 0:
    # Find last non-empty element
    var lastNonEmpty = -1
    for i in countdown(data.len - 1, 0):
      if data[i].len > 0:
        lastNonEmpty = i
        break
    if lastNonEmpty >= 0:
      result = header & "+" & data[0..lastNonEmpty].join("+") & "'"
    else:
      result = header & "'"
  else:
    result = header & "'"

proc buildHNHBK*(msgLen: int, dialogId: string, msgNum: int): string =
  ## Message header segment (Nachrichtenkopf)
  ## Format: HNHBK:1:3+msgLen(12)+hbciVersion+dialogId+msgNum'
  let lenStr = align($msgLen, 12, '0')  # 12 digits, zero-padded
  let data = @[
    lenStr,
    $HbciVersion,
    dialogId,
    $msgNum
  ]
  result = buildSegment("HNHBK", 3, 1, data)

proc buildHNHBS*(msgNum, segNum: int): string =
  ## Message end segment (Nachrichtenabschluss)
  let data = @[$msgNum]
  result = buildSegment("HNHBS", 1, segNum, data)

proc buildHNVSK*(blz, user, systemId: string): string =
  ## Encryption header segment (Verschluesselungskopf) for PIN/TAN
  ## Uses "dummy" encryption - no actual encryption
  let now = now()
  let dateStr = now.format("yyyyMMdd")
  let timeStr = now.format("HHmmss")
  let data = @[
    "PIN:1",                       # Security profile
    "998",                         # Security function (998=PIN/TAN encryption)
    "1",                           # Security role (1=ISS)
    "2::" & systemId,              # Security identification
    "1:" & dateStr & ":" & timeStr, # Security date/time
    "2:2:13:@8@00000000:5:1",      # Encryption algorithm (2-key 3DES, CBC)
    "280:" & blz & ":" & escapeFintsData(user) & ":V:0:0",  # Key name
    "0"                            # Compression (0=none)
  ]
  result = buildSegment("HNVSK", 3, 998, data)

proc buildHNVSD*(encryptedData: string): string =
  ## Encrypted data segment (Verschluesselte Daten)
  ## Contains the signed segments as "encrypted" binary data
  result = "HNVSD:999:1+@" & $encryptedData.len & "@" & encryptedData & "'"

proc buildHNSHK*(segNum: int, secFunc, secRef: string, blz, user, systemId: string): string =
  ## Security header (Sicherheitskopf) for PIN/TAN
  ## Format based on FinTS 3.0 spec and working implementations
  let escapedUser = escapeFintsData(user)
  let now = now()
  let dateStr = now.format("yyyyMMdd")
  let timeStr = now.format("HHmmss")
  let secData = @[
    "PIN:1",                       # Security profile (PIN version 1)
    secFunc,                       # Security function (999=single step)
    secRef,                        # Security reference
    "1",                           # Security area (1=SHM)
    "1",                           # Security role (1=ISS)
    "2::" & systemId,              # Security identification (2=system ID based)
    "1",                           # Security reference number
    "1:" & dateStr & ":" & timeStr, # Security datetime (1=STS, date, time)
    "1:999:1",                     # Hash algorithm
    "6:10:16",                     # Signature algorithm
    "280:" & blz & ":" & escapedUser & ":S:0:0"  # Key name (280=Germany)
  ]
  result = buildSegment("HNSHK", 4, segNum, secData)

proc buildHNSHA*(segNum, hnshkRef: int, pin: string, tanValue: string = ""): string =
  ## Security footer (Sicherheitsabschluss)
  ## PIN must be escaped for FinTS special chars
  var authData = escapeFintsData(pin)
  if tanValue.len > 0:
    authData = authData & ":" & escapeFintsData(tanValue)

  let data = @[
    $hnshkRef,
    "",
    authData
  ]
  result = buildSegment("HNSHA", 2, segNum, data)

proc buildHKIDN*(segNum: int, blz, customerId, systemId: string): string =
  ## Identification segment (Identifikation)
  let data = @[
    "280:" & blz,           # Bank identifier (280=Germany, then BLZ)
    escapeFintsData(customerId),  # Customer ID (user login)
    systemId,               # System ID ("0" for new)
    "1"                     # System ID status (1=ID required)
  ]
  result = buildSegment("HKIDN", 2, segNum, data)

proc buildHKVVB*(segNum: int, bpdVersion, updVersion: int, productId, productVersion: string, lang: int = 0): string =
  ## Processing preparation segment (Verarbeitungsvorbereitung)
  let data = @[
    bpdVersion.intToStr,
    updVersion.intToStr,
    lang.intToStr,
    productId,       # Registered product ID of the calling application
    productVersion   # Product version
  ]
  result = buildSegment("HKVVB", 3, segNum, data)

proc buildHKTAN*(segNum: int, tanProcess: string, segmentType: string = "", orderRef: string = "", tanMediaName: string = "", version: int = 7): string =
  ## TAN process segment
  ## tanProcess: "4" = start, "2" = submit TAN, "S" = check decoupled status
  ## segmentType: for process 4, the segment type needing TAN (e.g., "HKIDN")
  var data: seq[string]
  case tanProcess
  of "4":  # Start TAN process
    data = @[tanProcess, segmentType, "", "", "", "", "", "", "", "", tanMediaName]
  of "2":  # Submit TAN
    data = @[tanProcess, "", "", "", escapeFintsData(orderRef)]
  of "S":  # Check decoupled status
    data = @[tanProcess, "", "", "", escapeFintsData(orderRef), "N"]
  else:
    data = @[tanProcess]
  result = buildSegment("HKTAN", version, segNum, data)

proc buildHKSYN*(segNum: int, mode: int = 0): string =
  ## Synchronization segment (Synchronisierung)
  ## mode: 0 = request new system ID, 1 = last message number, 2 = signature ID
  let data = @[$mode]
  result = buildSegment("HKSYN", 3, segNum, data)

proc buildHKVPP*(segNum: int, reportFormat: string, pollingId: string = "", offset: string = ""): string =
  ## VoP name check request (Namensabgleich Prüfauftrag)
  ## HKVPP1 fields: supported_reports, polling_id, max_queries, offset
  if pollingId.len > 0 or offset.len > 0:
    let pidField = if pollingId.len > 0: "@" & $pollingId.len & "@" & pollingId else: ""
    let offField = if offset.len > 0: escapeFintsData(offset) else: ""
    let data = @[escapeFintsData(reportFormat), pidField, "", offField]
    result = buildSegment("HKVPP", 1, segNum, data)
  else:
    let data = @[escapeFintsData(reportFormat)]
    result = buildSegment("HKVPP", 1, segNum, data)

proc buildHKVPA*(segNum: int, vopId: string): string =
  ## VoP approval (Namensabgleich Ausführungsauftrag)
  let data = @["@" & $vopId.len & "@" & vopId]
  result = buildSegment("HKVPA", 1, segNum, data)

proc buildHKEND*(segNum: int, dialogId: string): string =
  ## Dialog end segment
  let data = @[dialogId]
  result = buildSegment("HKEND", 1, segNum, data)

proc deriveAccountNumber(iban: string): string =
  ## Derive account number from German IBAN
  ## German IBAN: DE + 2 check digits + 8 digit BLZ + 10 digit account number
  if iban.len >= 22 and iban.startsWith("DE"):
    result = iban[12..21]  # Last 10 digits
    # Strip leading zeros
    while result.len > 1 and result[0] == '0':
      result = result[1..^1]
  else:
    result = ""

proc buildHKKAZ*(segNum: int, account: Account, fromDate, toDate: string, offset: string = "", version: int = 7): string =
  ## Build HKKAZ segment (Kontoumsätze) for fetching account statements
  ## fromDate/toDate format: YYYYMMDD
  var data: seq[string]

  # Derive account number from IBAN if not provided
  let accountNum = if account.number.len > 0: account.number else: deriveAccountNumber(account.iban)
  let subaccount = account.subaccount  # Usually empty

  if version >= 7:
    # HKKAZ version 7: KTI format (just IBAN:BIC)
    var kti = account.iban
    if account.bic.len > 0:
      kti.add(":" & account.bic)
    data = @[kti, "N", fromDate, toDate]
  elif version == 6:
    # HKKAZ version 6: KTV format (IBAN:BIC:account:subaccount:280:blz)
    var ktv = account.iban
    if account.bic.len > 0:
      ktv.add(":" & account.bic)
    ktv.add(":" & accountNum & ":" & subaccount & ":280:" & account.blz)
    data = @[ktv, "N", fromDate, toDate]
  else:
    # HKKAZ version 5 and below: KTO format (account:subaccount:country:blz)
    let kto = accountNum & ":" & subaccount & ":280:" & account.blz
    data = @[kto, "N", fromDate, toDate]
  if offset.len > 0:
    data.add("")  # max_number_responses (empty = no limit)
    data.add(offset)
  result = buildSegment("HKKAZ", version, segNum, data)

proc buildHKCAZ*(segNum: int, account: Account, fromDate, toDate: string, camtUrn: string, offset: string = "", version: int = 1): string =
  ## Build HKCAZ segment (CAMT-Kontoumsätze) for fetching account statements in camt format
  ## fromDate/toDate format: YYYYMMDD
  var kti = account.iban
  if account.bic.len > 0:
    kti.add(":" & account.bic)
  # Escape colons in camt URN (colons are FinTS DEG separators)
  let escapedUrn = escapeFintsData(camtUrn)
  var data = @[kti, escapedUrn, "N", fromDate, toDate]
  if offset.len > 0:
    data.add("")  # max_number_responses (empty = no limit)
    data.add(offset)
  result = buildSegment("HKCAZ", version, segNum, data)

proc parseSegments(msg: string): seq[Segment] =
  ## Parse FinTS message into segments
  result = @[]
  var pos = 0
  var segmentStart = 0
  var inBinary = false
  var binaryLen = 0
  var binaryCount = 0

  while pos < msg.len:
    if inBinary:
      binaryCount += 1
      if binaryCount >= binaryLen:
        inBinary = false
      pos += 1
      continue

    # Check for binary data marker @123@
    if msg[pos] == '@' and not inBinary:
      var numEnd = pos + 1
      while numEnd < msg.len and msg[numEnd] in '0'..'9':
        numEnd += 1
      if numEnd > pos + 1 and numEnd < msg.len and msg[numEnd] == '@':
        binaryLen = parseInt(msg[pos+1 ..< numEnd])
        pos = numEnd + 1
        inBinary = true
        binaryCount = 0
        continue

    # Check for segment end (unescaped ')
    if msg[pos] == '\'' and (pos == 0 or msg[pos-1] != '?'):
      let segment = msg[segmentStart .. pos - 1]
      if segment.len > 0:
        # Parse segment header: NAME:num:version+data or NAME:num:version:ref+data
        let colonPos = segment.find(':')
        if colonPos > 0:
          let name = segment[0 ..< colonPos]
          # Find segment number, version, and optional ref
          var rest = segment[colonPos + 1 .. ^1]
          let colonPos2 = rest.find(':')
          if colonPos2 > 0:
            let num = try: parseInt(rest[0 ..< colonPos2]) except: 0
            rest = rest[colonPos2 + 1 .. ^1]
            # Version might be followed by :ref or +data
            let plusPos = rest.find('+')
            let colonPos3 = rest.find(':')
            var version: int
            var dataStr: string
            if colonPos3 > 0 and (plusPos < 0 or colonPos3 < plusPos):
              # Format: version:ref+data or version:ref
              version = try: parseInt(rest[0 ..< colonPos3]) except: 0
              let afterRef = rest[colonPos3 + 1 .. ^1]
              let plusPos2 = afterRef.find('+')
              if plusPos2 > 0:
                dataStr = afterRef[plusPos2 + 1 .. ^1]
              else:
                dataStr = ""
            elif plusPos > 0:
              version = try: parseInt(rest[0 ..< plusPos]) except: 0
              dataStr = rest[plusPos + 1 .. ^1]
            else:
              version = try: parseInt(rest) except: 0
              dataStr = ""

            # Split data by + (respecting escapes and binary blocks)
            var data: seq[string] = @[]
            if dataStr.len > 0:
              var current = ""
              var i = 0
              while i < dataStr.len:
                # Check for binary data marker @len@
                if dataStr[i] == '@':
                  var numEnd = i + 1
                  while numEnd < dataStr.len and dataStr[numEnd] in '0'..'9':
                    numEnd += 1
                  if numEnd > i + 1 and numEnd < dataStr.len and dataStr[numEnd] == '@':
                    let binLen = parseInt(dataStr[i+1 ..< numEnd])
                    let binEnd = min(numEnd + 1 + binLen, dataStr.len)
                    current.add(dataStr[i ..< binEnd])
                    i = binEnd
                    continue
                if dataStr[i] == '?' and i + 1 < dataStr.len:
                  current.add(dataStr[i + 1])
                  i += 2
                elif dataStr[i] == '+':
                  data.add(current)
                  current = ""
                  i += 1
                else:
                  current.add(dataStr[i])
                  i += 1
              data.add(current)

            result.add Segment(name: name, version: version, num: num, data: data)

      segmentStart = pos + 1

    pos += 1

proc findSegment*(segments: seq[Segment], name: string): int =
  ## Find segment index by name, returns -1 if not found
  for i, seg in segments:
    if seg.name == name:
      return i
  return -1

proc extractHNVSDContent(msg: string): string =
  ## Extract the inner content from HNVSD segment directly from raw message
  ## HNVSD format: HNVSD:999:1+@length@<content>'
  let hnvsdPos = msg.find("HNVSD:999:1+@")
  if hnvsdPos < 0:
    return ""

  # Find the length prefix
  var lenStart = hnvsdPos + 13  # after "HNVSD:999:1+@"
  var lenEnd = lenStart
  while lenEnd < msg.len and msg[lenEnd] in '0'..'9':
    lenEnd += 1

  if lenEnd >= msg.len or msg[lenEnd] != '@':
    return ""

  let contentLen = try: parseInt(msg[lenStart ..< lenEnd]) except: return ""
  let contentStart = lenEnd + 1

  if contentStart + contentLen > msg.len:
    return ""

  return msg[contentStart ..< contentStart + contentLen]

proc parseAllSegments*(msg: string): seq[Segment] =
  ## Parse FinTS message including inner HNVSD content
  let outerSegments = parseSegments(msg)
  let innerContent = extractHNVSDContent(msg)
  if innerContent.len > 0:
    # Parse inner segments and combine with outer
    let innerSegments = parseSegments(innerContent)
    result = outerSegments & innerSegments
  else:
    result = outerSegments

proc parseResponse*(de: string): tuple[code: string, refSeg: string, msg: string] =
  ## Parse HIRMG/HIRMS data element: "code:refSeg:message" or "code::message"
  let parts = de.split(':', maxsplit = 2)
  if parts.len >= 1:
    result.code = parts[0]
  if parts.len >= 2:
    result.refSeg = parts[1]
  if parts.len >= 3:
    result.msg = parts[2]
