## FinTS client: dialog handling, transfers, TAN flows, statements.

import std/[httpclient, base64, strutils, random, os]
import std/net
import finz/[types, wire, pain, statement]

type
  FintsClient* = object
    url*: string
    blz*: string
    user*: string
    pin*: string
    productId*: string
    productVersion*: string
    account*: Account
    dialogId*: string
    msgNum*: int
    systemId*: string
    bankParams*: BankParams
    selectedTanMethod*: string
    hktanVersion*: int  # HKTAN segment version (6 or 7)
    hkkazVersion*: int  # HKKAZ segment version (5, 6, or 7)
    hicazVersion*: int  # HICAZ segment version (1 or 2)
    hicazCamtUrn*: string  # camt URN for HICAZ (e.g., urn:iso:std:iso:20022:tech:xsd:camt.052.001.08)
    vopReportFormat*: string  # VoP report format from HIVPPS
    vopRequired*: bool  # Whether VoP is required for transfers
    needsHksyn*: bool  # Whether bank requires system ID synchronization
    decoupledMaxPolls*: int  # Max status requests (0=unlimited, from HITANS BPD)
    decoupledFirstPollSec*: int  # Seconds before first poll (from HITANS BPD)
    decoupledNextPollSec*: int  # Seconds between polls (from HITANS BPD)
    ui*: UiHooks
    http: HttpClient

# Forward declaration: initDialog ends the HKSYN sync dialog and re-inits
proc endDialog*(client: var FintsClient)

proc debug(c: FintsClient, msg: string) =
  if c.ui.onDebug != nil: c.ui.onDebug(msg)

proc info(c: FintsClient, msg: string) =
  if c.ui.onInfo != nil: c.ui.onInfo(msg)

proc prompt(c: FintsClient, msg: string) =
  if c.ui.onPrompt != nil: c.ui.onPrompt(msg)

proc wait(c: FintsClient) =
  if c.ui.onWait != nil: c.ui.onWait()

proc newFintsClient*(url, blz, user, pin, productId: string, productVersion: string = "0.1.0"): FintsClient =
  ## Create a new FinTS client
  result = FintsClient(
    url: url,
    blz: blz,
    user: user,
    pin: pin,
    productId: productId,
    productVersion: productVersion,
    dialogId: "0",
    msgNum: 0,
    systemId: "0",
    http: newHttpClient(sslContext = newContext(verifyMode = CVerifyPeer))
  )
  result.http.headers = newHttpHeaders({"Content-Type": "text/plain"})

proc close*(client: var FintsClient) =
  ## Close the HTTP client
  client.http.close()

proc reconnect*(client: var FintsClient) =
  ## Recreate HTTP client (needed after bank closes connection)
  client.http.close()
  client.http = newHttpClient(sslContext = newContext(verifyMode = CVerifyPeer))
  client.http.headers = newHttpHeaders({"Content-Type": "text/plain"})

proc sendMessage(client: var FintsClient, segments: string, lastSegNum: int): string =
  ## Send FinTS message and return response
  ## segments should contain HNSHK...HNSHA (signed content)
  ## lastSegNum is the segment number of the last inner segment
  client.msgNum += 1

  # Build encryption wrapper
  let hnvsk = buildHNVSK(client.blz, client.user, client.systemId)
  let hnvsd = buildHNVSD(segments)

  # Calculate message length
  # Structure: HNHBK + HNVSK + HNVSD + HNHBS
  let innerContent = hnvsk & hnvsd
  var msg = buildHNHBK(0, client.dialogId, client.msgNum)
  let headerLen = msg.len
  let hnhbs = buildHNHBS(client.msgNum, lastSegNum + 1)

  # Calculate total length and rebuild
  let totalLen = headerLen + innerContent.len + hnhbs.len
  msg = buildHNHBK(totalLen, client.dialogId, client.msgNum) & innerContent & hnhbs

  # Encode and send
  let encoded = encode(msg)

  client.debug("Sending to: " & client.url)
  client.debug("Request: " & msg[0 .. min(500, msg.len - 1)] & "...")

  var response: string
  try:
    response = client.http.postContent(client.url, body = encoded)
  except:
    # Reconnect once on connection failure (bank may close idle connections)
    client.debug("Connection failed, reconnecting: " & getCurrentExceptionMsg())
    client.reconnect()
    try:
      response = client.http.postContent(client.url, body = encoded)
    except:
      raise newException(FintsError, "HTTP request failed: " & getCurrentExceptionMsg())
  try:
    # Strip whitespace/newlines — some banks return MIME-style base64
    let cleaned = response.replace("\r", "").replace("\n", "").strip()
    result = decode(cleaned)
  except:
    client.debug("Raw response (not base64): " & response[0 .. min(500, response.len - 1)])
    raise newException(FintsError, "Invalid base64 response from bank")
  client.debug("Response: " & result[0 .. min(1000, result.len - 1)] & "...")

proc initDialog*(client: var FintsClient): bool =
  ## Initialize FinTS dialog (anonymous dialog for BPD/UPD)
  ## Raises FintsError on failure with detailed error message
  client.dialogId = "0"
  client.msgNum = 0

  client.debug("PIN length: " & $client.pin.len & ", escaped: " & $escapeFintsData(client.pin).len)

  # Build init segments
  var segments = ""
  var segNum = 2
  let secRef = $rand(1000000..9999999)
  let secFunc = if client.selectedTanMethod.len > 0: client.selectedTanMethod else: "999"

  # Security header
  segments.add buildHNSHK(segNum, secFunc, secRef, client.blz, client.user, client.systemId)
  segNum += 1

  # Identification
  segments.add buildHKIDN(segNum, client.blz, client.user, client.systemId)
  segNum += 1

  # Processing preparation
  segments.add buildHKVVB(segNum, 0, 0, client.productId, client.productVersion)
  segNum += 1

  # Synchronize system ID if requested
  if client.needsHksyn and client.systemId == "0":
    segments.add buildHKSYN(segNum, 0)
    segNum += 1

  # TAN process (only for two-step auth when TAN method is known)
  if client.selectedTanMethod.len > 0:
    segments.add buildHKTAN(segNum, "4", "HKIDN", version = client.hktanVersion)
    segNum += 1

  # Security footer
  segments.add buildHNSHA(segNum, secRef.parseInt, client.pin)

  let response = client.sendMessage(segments, segNum)
  let respSegments = parseAllSegments(response)

  client.debug("Parsed " & $respSegments.len & " segments")
  for seg in respSegments:
    client.debug("  - " & seg.name & ":" & $seg.num & ":" & $seg.version & " (" & $seg.data.len & " data elements)")

  # Check for HIRMG/HIRMS for errors FIRST (before extracting dialog ID)
  var errors: seq[string] = @[]
  for seg in respSegments:
    if seg.name == "HIRMG" or seg.name == "HIRMS":
      for de in seg.data:
        let parsed = parseResponse(de)
        client.debug(seg.name & " response: code=" & parsed.code & " msg=" & parsed.msg)
        if parsed.code.len >= 4 and parsed.code[0] == '9':  # Error codes start with 9
          errors.add(parsed.code & ": " & parsed.msg)

  if errors.len > 0:
    # Check if bank requires system ID synchronization
    for err in errors:
      if "9391" in err:
        if not client.needsHksyn:
          client.needsHksyn = true
          client.dialogId = "0"
          client.msgNum = 0
          client.debug("Bank requires HKSYN, retrying with system ID sync...")
          return client.initDialog()
    raise newException(FintsError, "Dialog initialization failed: " & errors.join("; "))

  # Parse TAN method from HIRMS 3920 response
  for seg in respSegments:
    if seg.name == "HIRMS":
      for de in seg.data:
        let parsed = parseResponse(de)
        if parsed.code == "3920":
          # Format: "Zugelassene TAN-Verfahren für den Benutzer:methodId"
          let parts = parsed.msg.split(':')
          if parts.len >= 2:
            client.selectedTanMethod = parts[^1].strip()
            client.debug("Selected TAN method: " & client.selectedTanMethod)

  # Check for HNHBK to get dialog ID
  let hnhbkIdx = findSegment(respSegments, "HNHBK")
  if hnhbkIdx >= 0 and respSegments[hnhbkIdx].data.len >= 3:
    client.dialogId = respSegments[hnhbkIdx].data[2]
    client.debug("Dialog ID: " & client.dialogId)

  # Parse BPD for supported segments
  for seg in respSegments:
    if seg.name == "HIPINS":  # PIN/TAN info
      discard
    elif seg.name == "HIIPZS":  # SEPA instant payment info
      client.bankParams.supportsInstantPayment = true
      client.debug("HIIPZS data: " & $seg.data)
    elif seg.name == "HISPAS":
      client.debug("HISPAS data: " & $seg.data)
    elif seg.name == "HICCSS":
      client.debug("HICCSS data: " & $seg.data)
    elif seg.name == "HIVPPS":
      client.debug("HIVPPS data: " & $seg.data)
      # Parse VoP parameters - check if HKIPZ/HKCCS requires VoP
      if seg.data.len > 3:
        let paramData = seg.data[3]
        if "HKIPZ" in paramData or "HKCCS" in paramData:
          client.vopRequired = true
          # Extract the full URN for pain.002 report format
          # Format in DEG: "999:J:V:J:J:urn:iso:std:iso:20022:tech:xsd:pain.002.001.10:HKCCS:..."
          # The URN starts with "urn" and ends before the first HK segment code
          let urnStart = paramData.find("urn")
          if urnStart >= 0:
            let afterUrn = paramData[urnStart .. ^1]
            # Find end of URN - it ends before :HK or at end of string
            let hkPos = afterUrn.find(":HK")
            if hkPos > 0:
              client.vopReportFormat = afterUrn[0 ..< hkPos]
            else:
              client.vopReportFormat = afterUrn
          client.debug("VoP required, report format: " & client.vopReportFormat)
    elif seg.name == "HIKAZS":
      # HIKAZS is the BPD parameter segment for HKKAZ (account statements)
      # Store the highest supported version
      if seg.version > client.hkkazVersion:
        client.hkkazVersion = seg.version
        client.debug("HKKAZ version " & $seg.version & " supported")
    elif seg.name == "HICAZS":
      # HICAZS is the BPD parameter segment for HICAZ (camt statements)
      if seg.version > client.hicazVersion:
        client.hicazVersion = seg.version
        # Extract camt URN from segment data (usually in field 4)
        if seg.data.len > 3:
          let paramData = seg.data[3]
          # URN looks like: urn:iso:std:iso:20022:tech:xsd:camt.052.001.08
          # Note: colons are part of the URN, only terminate on FinTS separators
          # Extract the last camt URN (banks may list multiple versions)
          let urnStart = paramData.find("urn:")
          if urnStart >= 0:
            var urnEnd = paramData.len
            for ch in ['+', '\'', ' ']:
              let pos = paramData.find(ch, urnStart)
              if pos > 0 and pos < urnEnd:
                urnEnd = pos
            let allUrns = paramData[urnStart ..< urnEnd]
            # Multiple URNs may be colon-separated; take the last one
            let lastUrn = allUrns.rfind(":urn:")
            if lastUrn >= 0:
              client.hicazCamtUrn = allUrns[lastUrn + 1 .. ^1]
            else:
              client.hicazCamtUrn = allUrns
        client.debug("HICAZ version " & $seg.version & " supported, URN: " & client.hicazCamtUrn)
    elif seg.name == "HISYN":
      # Synchronization response - extract system ID
      if seg.data.len > 0 and seg.data[0].len > 0:
        client.systemId = seg.data[0]
        client.debug("Got system ID: " & client.systemId)
    elif seg.name == "HITANS":
      client.debug("HITANS version " & $seg.version & " data: " & $seg.data)
      # Check if this HITANS version contains the selected TAN method
      if client.selectedTanMethod.len > 0 and seg.data.len > 3:
        if client.selectedTanMethod in seg.data[3]:
          client.hktanVersion = seg.version
          # Parse decoupled timing from TAN method parameters
          # Fields are colon-separated within DEG; find the selected method's block
          let paramStr = seg.data[3]
          let methodPos = paramStr.find(":" & client.selectedTanMethod & ":")
          if methodPos >= 0:
            # Split from method start (secfunc is field 1 of TAN2StepParams)
            let methodFields = paramStr[methodPos + 1 .. ^1].split(':')
            # Fields: 0=secfunc, ..., 20=nofactivetanmedia, 21=max_polls, 22=first_poll_sec, 23=next_poll_sec
            if methodFields.len > 23:
              try:
                if methodFields[21].len > 0: client.decoupledMaxPolls = parseInt(methodFields[21])
                if methodFields[22].len > 0: client.decoupledFirstPollSec = parseInt(methodFields[22])
                if methodFields[23].len > 0: client.decoupledNextPollSec = parseInt(methodFields[23])
              except ValueError: discard
              client.debug("Decoupled polling: max=" & $client.decoupledMaxPolls &
                  " first=" & $client.decoupledFirstPollSec & "s next=" & $client.decoupledNextPollSec & "s")
          client.debug("Using HKTAN version " & $seg.version & " for TAN method " & client.selectedTanMethod)

  # Handle decoupled TAN for dialog init (some banks require app approval)
  var initOrderRef = ""
  var initTanPending = false
  for seg in respSegments:
    if seg.name == "HIRMS":
      for de in seg.data:
        let parsed = parseResponse(de)
        if parsed.code == "3955":
          initTanPending = true
    elif seg.name == "HITAN":
      if seg.data.len > 2 and seg.data[2].len > 0:
        initOrderRef = seg.data[2]

  if initTanPending and initOrderRef.len > 0:
    client.debug("Dialog init requires decoupled TAN approval, polling...")
    client.prompt("approve login in your banking app")
    let secFunc = if client.selectedTanMethod.len > 0: client.selectedTanMethod else: "999"
    let hktanVer = if client.hktanVersion > 0: client.hktanVersion else: 7
    var dialogConfirmed = false
    let maxPolls = if client.decoupledMaxPolls > 0: client.decoupledMaxPolls else: 60
    let firstPollMs = if client.decoupledFirstPollSec > 0: client.decoupledFirstPollSec * 1000 else: 5000
    let nextPollMs = if client.decoupledNextPollSec > 0: client.decoupledNextPollSec * 1000 else: 5000
    client.debug("Polling: max=" & $maxPolls & " first=" & $firstPollMs & "ms next=" & $nextPollMs & "ms")
    for attempt in 0 ..< maxPolls:
      sleep(if attempt == 0: firstPollMs else: nextPollMs)
      client.debug("Polling dialog TAN, attempt " & $(attempt + 1))
      var pollSegs = ""
      var pollSegNum = 2
      let pollSecRef = $rand(1000000..9999999)
      pollSegs.add buildHNSHK(pollSegNum, secFunc, pollSecRef, client.blz, client.user, client.systemId)
      pollSegNum += 1
      pollSegs.add buildHKTAN(pollSegNum, "S", "", initOrderRef, version = hktanVer)
      pollSegNum += 1
      pollSegs.add buildHNSHA(pollSegNum, pollSecRef.parseInt, client.pin)
      let pollResp = client.sendMessage(pollSegs, pollSegNum)
      let pollSegments = parseAllSegments(pollResp)
      var confirmed = false
      var stillPending = false
      for seg in pollSegments:
        if seg.name == "HIRMG" or seg.name == "HIRMS":
          for de in seg.data:
            let parsed = parseResponse(de)
            client.debug("Poll " & seg.name & ": " & parsed.code & " " & parsed.msg)
            if parsed.code == "0020" or parsed.code == "0010":
              confirmed = true
            elif parsed.code == "3955" or parsed.code == "3956":
              stillPending = true
      if confirmed:
        client.debug("Dialog TAN confirmed")
        dialogConfirmed = true
        break
      if not stillPending:
        raise newException(FintsError, "Dialog TAN confirmation failed")
    if not dialogConfirmed:
      raise newException(FintsError, "Dialog TAN confirmation timed out")

  # After HKSYN, the sync dialog cannot be used for operations.
  # End it and start a fresh dialog with the new system ID.
  if client.needsHksyn and client.systemId != "0":
    var gotSyncId = false
    for seg in respSegments:
      if seg.name == "HISYN":
        gotSyncId = true
        break
    if gotSyncId:
      client.debug("HKSYN complete, starting fresh dialog with system ID " & client.systemId)
      client.endDialog()
      return client.initDialog()

  return true

proc endDialog*(client: var FintsClient) =
  ## End FinTS dialog
  if client.dialogId != "0":
    var segments = ""
    var segNum = 2
    let secRef = $rand(1000000..9999999)

    segments.add buildHNSHK(segNum, "999", secRef, client.blz, client.user, client.systemId)
    segNum += 1

    segments.add buildHKEND(segNum, client.dialogId)
    segNum += 1

    segments.add buildHNSHA(segNum, secRef.parseInt, client.pin)

    try:
      discard client.sendMessage(segments, segNum)
    except FintsError:
      discard  # Dialog may already be closed by bank
    client.dialogId = "0"

proc parseHIVPP(seg: Segment, client: FintsClient): tuple[vopId, pollingId, resultCode, differentName: string, waitSec: int] =
  ## Parse HIVPP response fields
  ## Fields: vopid(0), vopidvalidto(1), pollingid(2), reportdesc(3), report(4), result_DEG(5), infotext(6), wait(7)
  result.waitSec = 2
  client.debug("HIVPP: " & $seg.data)
  # Field 0: vopId (binary @len@data)
  if seg.data.len > 0 and seg.data[0].len > 0:
    let raw = seg.data[0]
    if raw.startsWith("@"):
      result.vopId = extractBinary(raw)
    else:
      result.vopId = raw
  # Field 2: pollingId (binary @len@data)
  if seg.data.len > 2 and seg.data[2].len > 0:
    let raw = seg.data[2]
    if raw.startsWith("@"):
      result.pollingId = extractBinary(raw)
    else:
      result.pollingId = raw
  # Field 5: result DEG (iban:ibanaddon:differentname:otheridentifier:result_code:reason)
  if seg.data.len > 5 and seg.data[5].len > 0:
    let parts = seg.data[5].split(':')
    if parts.len >= 5:
      result.resultCode = parts[4]
    if parts.len >= 3 and parts[2].len > 0:
      result.differentName = parts[2]
  # Field 7: wait seconds
  if seg.data.len > 7 and seg.data[7].len > 0:
    try:
      result.waitSec = parseInt(seg.data[7])
    except: discard

proc transfer*(client: var FintsClient, request: TransferRequest): TransferResult =
  ## Execute SEPA transfer (instant or standard)
  ## Implements the correct VoP flow: Check → Poll → Auth
  result = TransferResult(success: false)

  # Ensure dialog is initialized with proper TAN method
  if client.dialogId == "0":
    try:
      let oldSystemId = client.systemId
      # First dialog: discover TAN methods, BPD, and system ID
      discard client.initDialog()
      # Re-init if we got a new system ID or discovered a TAN method
      if (client.selectedTanMethod.len > 0 and client.selectedTanMethod != "999") or
         (oldSystemId == "0" and client.systemId != "0"):
        client.endDialog()
        discard client.initDialog()
    except FintsError as e:
      result.errorMsg = e.msg
      return

  let secFunc = if client.selectedTanMethod.len > 0: client.selectedTanMethod else: "999"
  let hktanVer = if client.hktanVersion > 0: client.hktanVersion else: 7

  # Step 1: Send HKVPP (VoP Check) + HKIPZ (transfer) + HKTAN (process 4)
  var vopId = ""
  var vopPollingId = ""
  var vopWaitSec = 2
  var vopResultCode = ""
  var vopDifferentName = ""
  var vopOffset = ""
  var vopPending = false
  var skipVopAuth = false

  # Generate pain.001 XML once — must be identical in Step 1 and Step 3
  let transferMessageId = generateReference()
  let painXml = generatePain001(request, client.account, transferMessageId)
  client.debug("pain.001 XML:\n" & painXml)

  block:
    var segments = ""
    var segNum = 2
    let secRef = $rand(1000000..9999999)

    segments.add buildHNSHK(segNum, secFunc, secRef, client.blz, client.user, client.systemId)
    segNum += 1

    if client.vopRequired and client.vopReportFormat.len > 0:
      segments.add buildHKVPP(segNum, client.vopReportFormat)
      segNum += 1

    segments.add buildHKIPZFromPain(segNum, client.account, painXml)
    segNum += 1

    segments.add buildHKTAN(segNum, "4", "HKIPZ", version = hktanVer)
    segNum += 1

    segments.add buildHNSHA(segNum, secRef.parseInt, client.pin)

    let response = client.sendMessage(segments, segNum)
    let respSegments = parseAllSegments(response)

    for seg in respSegments:
      if seg.name == "HIRMG" or seg.name == "HIRMS":
        for de in seg.data:
          let parsed = parseResponse(de)
          client.debug(seg.name & ": " & parsed.code & " " & parsed.msg)
          if parsed.code == "0010" or parsed.code == "0020" or parsed.code == "0030":
            result.success = true
          elif parsed.code == "3091":
            # Bank skips VoP auth entirely — proceed directly with TAN
            skipVopAuth = true
          elif parsed.code == "3945":
            # VoP pending — bank hasn't completed name check yet
            vopPending = true
          elif parsed.code == "3040":
            # More data available — extract aufsetzpunkt for polling
            let msgParts = parsed.msg.split(':')
            if msgParts.len >= 2 and msgParts[^1].len > 0:
              vopOffset = msgParts[^1]
          elif parsed.code == "9050":
            discard  # Generic "message has errors" — check HIRMS for details
          elif parsed.code.startsWith("9"):
            # Prefer HIRMS-specific errors over earlier generic ones
            result.errorCode = parsed.code
            result.errorMsg = parsed.msg
      elif seg.name == "HITAN":
        client.debug("HITAN data: " & $seg.data)
        # HITAN v7: process(0) + orderHash(1) + orderRef(2) + challenge(3) + ...
        if seg.data.len > 2:
          result.orderRef = seg.data[2]
        if seg.data.len > 3:
          result.tanChallenge = seg.data[3]
        if seg.data.len > 6:
          result.tanMediaName = seg.data[6]
        result.tanRequired = true
      elif seg.name == "HIVPP":
        let hivpp = parseHIVPP(seg, client)
        vopId = hivpp.vopId
        vopPollingId = hivpp.pollingId
        vopWaitSec = hivpp.waitSec
        vopResultCode = hivpp.resultCode
        vopDifferentName = hivpp.differentName

    if result.errorCode.len > 0:
      result.success = false
      return result

    # If bank skips VoP auth (3091) or no VoP required, we're done
    if skipVopAuth or not client.vopRequired:
      return result

    # If we got a vopId, skip polling — go straight to Step 3 (VoP Auth)
    if vopId.len > 0:
      discard  # Fall through to Step 3 below
    elif vopPollingId.len > 0:
      # VoP is pending — try polling, fall back to async if polling fails
      discard  # Fall through to Step 2 below
    else:
      # No vopId and no pollingId — bank may handle VoP asynchronously
      # (Atruvia banks send SecureGo notification even without HITAN)
      if result.tanRequired or vopPending:
        result.tanRequired = true
        return result
      result.errorMsg = "VoP: no vopId or pollingId in HIVPP response"
      return result

  # Step 2: Poll if PENDING (no vopId yet) — use pollingId + offset
  if vopId.len == 0 and vopPollingId.len > 0:
    client.info("Verifying payee name")
    client.debug("VoP polling with pollingId=" & vopPollingId & " offset=" & vopOffset & " waitSec=" & $vopWaitSec)

    for attempt in 0 ..< 5:
      sleep(vopWaitSec * 1000)
      client.debug("VoP poll attempt " & $(attempt + 1))

      var segments = ""
      var segNum = 2
      let secRef = $rand(1000000..9999999)

      segments.add buildHNSHK(segNum, secFunc, secRef, client.blz, client.user, client.systemId)
      segNum += 1

      segments.add buildHKVPP(segNum, client.vopReportFormat, vopPollingId, vopOffset)
      segNum += 1

      segments.add buildHNSHA(segNum, secRef.parseInt, client.pin)

      let response = client.sendMessage(segments, segNum)
      let respSegments = parseAllSegments(response)

      var gotVopId = false
      var pollError = false
      var otherError = ""
      var otherErrorCode = ""
      for seg in respSegments:
        if seg.name == "HIRMG" or seg.name == "HIRMS":
          for de in seg.data:
            let parsed = parseResponse(de)
            client.debug("VoP " & seg.name & ": " & parsed.code & " " & parsed.msg)
            if parsed.code == "9210" or parsed.code == "9050":
              # 9210 = VOP order invalid, 9050 = message contains errors
              # Both indicate polling not supported — fall back to async
              pollError = true
            elif parsed.code == "3040":
              # Update offset for next poll
              let msgParts = parsed.msg.split(':')
              if msgParts.len >= 2 and msgParts[^1].len > 0:
                vopOffset = msgParts[^1]
            elif parsed.code.startsWith("9"):
              otherErrorCode = parsed.code
              otherError = parsed.msg
        elif seg.name == "HIVPP":
          let hivpp = parseHIVPP(seg, client)
          if hivpp.vopId.len > 0:
            vopId = hivpp.vopId
            vopResultCode = hivpp.resultCode
            vopDifferentName = hivpp.differentName
            gotVopId = true
          if hivpp.pollingId.len > 0:
            vopPollingId = hivpp.pollingId
          if hivpp.waitSec > 0:
            vopWaitSec = hivpp.waitSec

      # Non-polling errors take priority
      if otherError.len > 0 and not pollError:
        result.errorCode = otherErrorCode
        result.errorMsg = otherError
        return

      if pollError:
        # Polling not supported (e.g. Atruvia banks).
        # Bank processes VoP asynchronously and sends SecureGo notification
        # even without HITAN. Return tanRequired to trigger manual approval.
        client.debug("VoP polling not supported, falling back to async approval")
        result.tanRequired = true
        return result

      if gotVopId:
        client.info("Payee verified")
        break

    if vopId.len == 0:
      # Polling timed out — fall back to async approval
      client.info("VoP still pending, proceeding with async approval")
      result.tanRequired = true
      return result

  # Handle VoP result codes
  case vopResultCode
  of "RVNM":
    client.prompt("warning: payee name does NOT match")
  of "RVMC":
    if vopDifferentName.len > 0:
      client.prompt("payee name close match, bank suggests: " & vopDifferentName)
  of "RVNA":
    client.info("Receiving bank does not support payee verification")
  of "RCVC", "":
    discard  # Match or not provided — proceed normally
  else:
    client.debug("VoP result code: " & vopResultCode)

  # Step 3: Send HKVPA (VoP Auth with vopId) + HKIPZ (transfer again) + HKTAN
  block:
    var segments = ""
    var segNum = 2
    let secRef = $rand(1000000..9999999)

    segments.add buildHNSHK(segNum, secFunc, secRef, client.blz, client.user, client.systemId)
    segNum += 1

    segments.add buildHKVPA(segNum, vopId)
    segNum += 1

    segments.add buildHKIPZFromPain(segNum, client.account, painXml)
    segNum += 1

    segments.add buildHKTAN(segNum, "4", "HKIPZ", version = hktanVer)
    segNum += 1

    segments.add buildHNSHA(segNum, secRef.parseInt, client.pin)

    let response = client.sendMessage(segments, segNum)
    let respSegments = parseAllSegments(response)

    result = TransferResult(success: false)
    var scaNotRequired = false
    for seg in respSegments:
      if seg.name == "HIRMG" or seg.name == "HIRMS":
        for de in seg.data:
          let parsed = parseResponse(de)
          client.debug(seg.name & ": " & parsed.code & " " & parsed.msg)
          if parsed.code == "0010" or parsed.code == "0020" or parsed.code == "0030":
            result.success = true
          elif parsed.code == "3076":
            scaNotRequired = true
          elif parsed.code == "9050":
            discard  # Generic "message has errors" — check HIRMS for details
          elif parsed.code.startsWith("9"):
            result.errorCode = parsed.code
            result.errorMsg = parsed.msg
      elif seg.name == "HITAN":
        client.debug("HITAN data: " & $seg.data)
        if seg.data.len > 2:
          result.orderRef = seg.data[2]
        if seg.data.len > 3:
          result.tanChallenge = seg.data[3]
        if seg.data.len > 6:
          result.tanMediaName = seg.data[6]
        result.tanRequired = true

    # 3076 = SCA not required — transfer already complete
    if scaNotRequired:
      result.tanRequired = false

    if result.errorCode.len > 0:
      result.success = false
      return result

  return result

proc submitTan*(client: var FintsClient, orderRef: string, tan: string): TransferResult =
  ## Submit TAN for pending transfer
  result = TransferResult(success: false)

  var segments = ""
  var segNum = 2
  let secRef = $rand(1000000..9999999)
  let secFunc = if client.selectedTanMethod.len > 0: client.selectedTanMethod else: "999"

  segments.add buildHNSHK(segNum, secFunc, secRef, client.blz, client.user, client.systemId)
  segNum += 1

  let hktanVer = if client.hktanVersion > 0: client.hktanVersion else: 7
  segments.add buildHKTAN(segNum, "2", "", orderRef, version = hktanVer)
  segNum += 1

  segments.add buildHNSHA(segNum, secRef.parseInt, client.pin, tan)

  let response = client.sendMessage(segments, segNum)
  let respSegments = parseAllSegments(response)

  for seg in respSegments:
    if seg.name == "HIRMG" or seg.name == "HIRMS":
      for de in respSegments[findSegment(respSegments, seg.name)].data:
        if de.startsWith("0010") or de.startsWith("0020"):
          result.success = true
        elif de.startsWith("9"):
          result.errorCode = de[0..3]
          if de.len > 5:
            result.errorMsg = de[5..^1]

  return result

proc pollDecoupledTan*(client: var FintsClient, orderRef: string): TransferResult =
  ## Poll for decoupled TAN confirmation (SecureGo plus etc.)
  ## Returns success=true if bank confirms, errorCode="POLL_UNSUPPORTED" if
  ## bank doesn't support HKTAN process "S" polling.
  result = TransferResult(success: false)

  let secFunc = if client.selectedTanMethod.len > 0: client.selectedTanMethod else: "999"
  let hktanVer = if client.hktanVersion > 0: client.hktanVersion else: 7

  let maxPolls = if client.decoupledMaxPolls > 0: client.decoupledMaxPolls else: 60
  let firstPollMs = if client.decoupledFirstPollSec > 0: client.decoupledFirstPollSec * 1000 else: 5000
  let nextPollMs = if client.decoupledNextPollSec > 0: client.decoupledNextPollSec * 1000 else: 5000
  for attempt in 0 ..< maxPolls:
    sleep(if attempt == 0: firstPollMs else: nextPollMs)
    client.debug("Polling decoupled TAN, attempt " & $(attempt + 1))

    var segments = ""
    var segNum = 2
    let secRef = $rand(1000000..9999999)

    segments.add buildHNSHK(segNum, secFunc, secRef, client.blz, client.user, client.systemId)
    segNum += 1

    segments.add buildHKTAN(segNum, "S", "", orderRef, version = hktanVer)
    segNum += 1

    segments.add buildHNSHA(segNum, secRef.parseInt, client.pin)

    let response = client.sendMessage(segments, segNum)
    let respSegments = parseAllSegments(response)

    var stillPending = false
    for seg in respSegments:
      if seg.name == "HIRMG" or seg.name == "HIRMS":
        for de in seg.data:
          let parsed = parseResponse(de)
          client.debug("Poll " & seg.name & ": " & parsed.code & " " & parsed.msg)
          if parsed.code == "0010" or parsed.code == "0020" or parsed.code == "0030" or parsed.code == "0900":
            result.success = true
          elif parsed.code == "3955" or parsed.code == "3956":
            stillPending = true  # Decoupled auth still pending
          elif parsed.code.startsWith("3"):
            discard  # Informational (3060 warnings, etc.)
          elif parsed.code == "9050":
            discard  # Generic "message has errors" — check HIRMS for details
          elif parsed.code == "9110" or parsed.code == "9100":
            # Bank doesn't support HKTAN process "S" polling
            client.debug("Bank does not support decoupled TAN polling")
            result.errorCode = "POLL_UNSUPPORTED"
            result.errorMsg = "Bank does not support status polling"
            return
          elif parsed.code.startsWith("9"):
            result.errorCode = parsed.code
            result.errorMsg = parsed.msg
            return

    if result.success:
      return

    if not stillPending and not result.success:
      # No success and no pending status — unexpected state
      result.errorMsg = "Unexpected response during TAN polling"
      return

  result.errorMsg = "Decoupled TAN confirmation timed out"

proc pollDecoupledStatements*(client: var FintsClient, orderRef: string): StatementResult =
  ## Poll for decoupled TAN confirmation for statement retrieval
  ## Returns statements when confirmed, or error codes
  result = StatementResult(success: false, transactions: @[])

  let secFunc = if client.selectedTanMethod.len > 0: client.selectedTanMethod else: "999"
  let hktanVer = if client.hktanVersion > 0: client.hktanVersion else: 7

  let maxPolls = if client.decoupledMaxPolls > 0: client.decoupledMaxPolls else: 60
  let firstPollMs = if client.decoupledFirstPollSec > 0: client.decoupledFirstPollSec * 1000 else: 5000
  let nextPollMs = if client.decoupledNextPollSec > 0: client.decoupledNextPollSec * 1000 else: 5000
  for attempt in 0 ..< maxPolls:
    sleep(if attempt == 0: firstPollMs else: nextPollMs)
    client.debug("Polling decoupled TAN for statements, attempt " & $(attempt + 1))

    var segments = ""
    var segNum = 2
    let secRef = $rand(1000000..9999999)

    segments.add buildHNSHK(segNum, secFunc, secRef, client.blz, client.user, client.systemId)
    segNum += 1

    segments.add buildHKTAN(segNum, "S", "", orderRef, version = hktanVer)
    segNum += 1

    segments.add buildHNSHA(segNum, secRef.parseInt, client.pin)

    let response = client.sendMessage(segments, segNum)
    let respSegments = parseAllSegments(response)

    var stillPending = false
    for seg in respSegments:
      if seg.name == "HIRMG" or seg.name == "HIRMS":
        for de in seg.data:
          let parsed = parseResponse(de)
          client.debug("Poll " & seg.name & ": " & parsed.code & " " & parsed.msg)
          if parsed.code == "0010" or parsed.code == "0020" or parsed.code == "0030" or parsed.code == "0900":
            result.success = true
          elif parsed.code == "3955" or parsed.code == "3956":
            stillPending = true  # Decoupled auth still pending
          elif parsed.code == "3040":
            # Pagination — more data available
            result.success = true
            let msgParts = parsed.msg.split(':')
            if msgParts.len >= 2 and msgParts[^1].len > 0:
              result.nextOffset = msgParts[^1]
          elif parsed.code.startsWith("3"):
            discard  # Informational (3060 warnings, etc.)
          elif parsed.code == "9050":
            discard  # Generic "message has errors" — check HIRMS for details
          elif parsed.code == "9110" or parsed.code == "9100":
            # Bank doesn't support HKTAN process "S" polling
            client.debug("Bank does not support decoupled TAN polling")
            result.errorCode = "POLL_UNSUPPORTED"
            result.errorMsg = "Bank does not support status polling"
            return
          elif parsed.code.startsWith("9"):
            result.errorCode = parsed.code
            result.errorMsg = parsed.msg
            return

      elif seg.name == "HICAZ":
        # Statements might come back with polling response (camt format)
        for dataElem in seg.data:
          if dataElem.len > 0 and dataElem.startsWith("@"):
            let camtData = extractBinary(dataElem)
            if camtData.len > 0 and camtData.startsWith("<?xml"):
              client.debug("Got camt data in poll response")
              let txs = parseCamt(camtData)
              result.transactions.add(txs)
              break

      elif seg.name == "HIKAZ":
        # Statements might come back with polling response (MT940 format)
        if seg.data.len > 0:
          let mt940Data = extractBinary(seg.data[0])
          if mt940Data.len > 0:
            client.debug("Got MT940 data in poll response")
            let txs = parseMT940(mt940Data)
            result.transactions.add(txs)

    if result.success:
      return

    if not stillPending and not result.success:
      # No success and no pending status — unexpected state
      result.errorMsg = "Unexpected response during TAN polling"
      return

  result.errorMsg = "Decoupled TAN confirmation timed out"

proc getStatementsHICAZ(client: var FintsClient, fromDate, toDate: string, withTan: bool = true, startOffset: string = ""): StatementResult =
  ## Fetch account statements via HICAZ (camt format)
  ## withTan: if true, include HKTAN for decoupled TAN flow
  result = StatementResult(success: false, transactions: @[])

  let secFunc = if client.selectedTanMethod.len > 0: client.selectedTanMethod else: "999"
  let hicazVer = client.hicazVersion
  let camtUrn = client.hicazCamtUrn
  let hktanVer = if client.hktanVersion > 0: client.hktanVersion else: 7
  var offset = startOffset

  client.debug("Using HICAZ version " & $hicazVer & " with URN: " & camtUrn)

  while true:
    var segments = ""
    var segNum = 2
    let secRef = $rand(1000000..9999999)

    segments.add buildHNSHK(segNum, secFunc, secRef, client.blz, client.user, client.systemId)
    segNum += 1

    segments.add buildHKCAZ(segNum, client.account, fromDate, toDate, camtUrn, offset, hicazVer)
    segNum += 1

    if withTan:
      segments.add buildHKTAN(segNum, "4", "HKCAZ", version = hktanVer)
      segNum += 1

    segments.add buildHNSHA(segNum, secRef.parseInt, client.pin)

    let response = client.sendMessage(segments, segNum)
    let respSegments = parseAllSegments(response)

    var gotMore = false
    var newOffset = ""

    var hirmgError = ("", "")  # Store HIRMG error temporarily

    for seg in respSegments:
      if seg.name == "HIRMG" or seg.name == "HIRMS":
        for de in seg.data:
          let parsed = parseResponse(de)
          client.debug(seg.name & ": " & parsed.code & " " & parsed.msg)
          if parsed.code == "0010" or parsed.code == "0020" or parsed.code == "3010":
            result.success = true
          elif parsed.code == "3040":
            gotMore = true
            let msgParts = parsed.msg.split(':')
            if msgParts.len >= 2 and msgParts[^1].len > 0:
              newOffset = msgParts[^1]
          elif parsed.code == "9370":
            # TAN required - not an error if we're doing TAN flow
            result.tanRequired = true
          elif parsed.code.startsWith("9"):
            if seg.name == "HIRMS":
              # HIRMS errors are more specific, use them directly
              result.errorCode = parsed.code
              result.errorMsg = parsed.msg
              return
            else:
              # Store HIRMG error as fallback
              hirmgError = (parsed.code, parsed.msg)

      elif seg.name == "HITAN":
        # HITAN contains TAN challenge/order reference for decoupled TAN
        client.debug("HITAN data: " & $seg.data)
        if seg.data.len > 2 and seg.data[2] != "noref":
          result.orderRef = seg.data[2]
          if seg.data.len > 3 and seg.data[3] != "nochallenge":
            result.tanChallenge = seg.data[3]
          result.tanRequired = true

      elif seg.name == "HICAZ":
        # HICAZ contains camt XML data in binary format
        # Format: account:bic + urn + @len@xmldata
        client.debug("HICAZ segment has " & $seg.data.len & " data elements")
        for i, dataElem in seg.data:
          if dataElem.len > 0:
            client.debug("HICAZ data[" & $i & "]: " & dataElem[0 .. min(80, dataElem.len - 1)] & (if dataElem.len > 80: "..." else: ""))
          if dataElem.len > 0 and dataElem.startsWith("@"):
            let camtData = extractBinary(dataElem)
            if camtData.len > 0 and camtData.startsWith("<?xml"):
              client.debug("Extracted camt XML: " & camtData[0 .. min(200, camtData.len - 1)] & "...")
              let txs = parseCamt(camtData)
              client.debug("Parsed " & $txs.len & " transactions from camt")
              result.transactions.add(txs)
              break

    # If TAN required and we have orderRef, return for polling
    if result.tanRequired and result.orderRef.len > 0:
      return

    # If HIRMG error but no HIRMS error, use HIRMG
    if hirmgError[0].len > 0:
      result.errorCode = hirmgError[0]
      result.errorMsg = hirmgError[1]
      return

    if not gotMore or newOffset.len == 0:
      break
    offset = newOffset

  result.success = true

proc getStatementsHKKAZ(client: var FintsClient, fromDate, toDate: string, withTan: bool = true, startOffset: string = ""): StatementResult =
  ## Fetch account statements via HKKAZ (MT940 format)
  ## withTan: if true, include HKTAN for decoupled TAN flow
  result = StatementResult(success: false, transactions: @[])

  let secFunc = if client.selectedTanMethod.len > 0: client.selectedTanMethod else: "999"
  let hkkazVer = if client.hkkazVersion > 0: client.hkkazVersion else: 7
  let hktanVer = if client.hktanVersion > 0: client.hktanVersion else: 7
  var offset = startOffset

  client.debug("Using HKKAZ version " & $hkkazVer)

  while true:
    var segments = ""
    var segNum = 2
    let secRef = $rand(1000000..9999999)

    segments.add buildHNSHK(segNum, secFunc, secRef, client.blz, client.user, client.systemId)
    segNum += 1

    segments.add buildHKKAZ(segNum, client.account, fromDate, toDate, offset, hkkazVer)
    segNum += 1

    if withTan:
      segments.add buildHKTAN(segNum, "4", "HKKAZ", version = hktanVer)
      segNum += 1

    segments.add buildHNSHA(segNum, secRef.parseInt, client.pin)

    let response = client.sendMessage(segments, segNum)
    let respSegments = parseAllSegments(response)

    var gotMore = false
    var newOffset = ""

    var hirmgError = ("", "")  # Store HIRMG error temporarily

    for seg in respSegments:
      if seg.name == "HIRMG" or seg.name == "HIRMS":
        for de in seg.data:
          let parsed = parseResponse(de)
          client.debug(seg.name & ": " & parsed.code & " " & parsed.msg)
          if parsed.code == "0010" or parsed.code == "0020" or parsed.code == "3010":
            result.success = true
          elif parsed.code == "3040":
            gotMore = true
            let msgParts = parsed.msg.split(':')
            if msgParts.len >= 2 and msgParts[^1].len > 0:
              newOffset = msgParts[^1]
          elif parsed.code == "9370":
            # TAN required
            result.tanRequired = true
          elif parsed.code.startsWith("9"):
            if seg.name == "HIRMS":
              # HIRMS errors are more specific, use them directly
              result.errorCode = parsed.code
              result.errorMsg = parsed.msg
              return
            else:
              # Store HIRMG error as fallback
              hirmgError = (parsed.code, parsed.msg)

      elif seg.name == "HITAN":
        client.debug("HITAN data: " & $seg.data)
        if seg.data.len > 2 and seg.data[2] != "noref":
          result.orderRef = seg.data[2]
          if seg.data.len > 3 and seg.data[3] != "nochallenge":
            result.tanChallenge = seg.data[3]
          result.tanRequired = true

      elif seg.name == "HIKAZ":
        # HIKAZ contains MT940 data in binary format
        if seg.data.len > 0:
          let mt940Data = extractBinary(seg.data[0])
          if mt940Data.len > 0:
            let txs = parseMT940(mt940Data)
            result.transactions.add(txs)

    # If TAN required and we have orderRef, return for polling
    if result.tanRequired and result.orderRef.len > 0:
      return

    # If HIRMG error but no HIRMS error, use HIRMG
    if hirmgError[0].len > 0:
      result.errorCode = hirmgError[0]
      result.errorMsg = hirmgError[1]
      return

    if not gotMore or newOffset.len == 0:
      break
    offset = newOffset

  result.success = true

proc getStatements*(client: var FintsClient, fromDate, toDate: string): StatementResult =
  ## Fetch account statements (tries HICAZ first, falls back to HKKAZ)
  ## fromDate/toDate format: YYYYMMDD
  result = StatementResult(success: false, transactions: @[])

  # Ensure dialog is initialized
  if client.dialogId == "0":
    try:
      let oldSystemId = client.systemId
      discard client.initDialog()
      # Re-init if we got a new system ID or discovered a TAN method
      if (client.selectedTanMethod.len > 0 and client.selectedTanMethod != "999") or
         (oldSystemId == "0" and client.systemId != "0"):
        client.endDialog()
        discard client.initDialog()
    except FintsError as e:
      result.errorMsg = e.msg
      return

  var hicazResult: StatementResult

  # Prefer HICAZ (camt) if available - newer, cleaner format
  if client.hicazVersion > 0 and client.hicazCamtUrn.len > 0:
    client.debug("Trying HICAZ (camt format)...")
    hicazResult = client.getStatementsHICAZ(fromDate, toDate)

    if hicazResult.success:
      return hicazResult

    # Handle decoupled TAN (SecureGo plus)
    if hicazResult.tanRequired and hicazResult.orderRef.len > 0:
      client.debug("TAN required for statement retrieval")

      # Show challenge message if present
      if hicazResult.tanChallenge.len > 0 and hicazResult.tanChallenge != "nochallenge":
        client.prompt(hicazResult.tanChallenge)
      else:
        client.prompt("approve statement retrieval in your banking app")

      # Poll for decoupled TAN confirmation
      let pollResult = client.pollDecoupledStatements(hicazResult.orderRef)
      if pollResult.success:
        # If we got statements during polling, return them
        if pollResult.transactions.len > 0:
          # Check if there are more pages to fetch (offset-based, same dialog)
          if pollResult.nextOffset.len > 0:
            var allTransactions = pollResult.transactions
            var curOffset = pollResult.nextOffset
            while curOffset.len > 0:
              client.debug("More data available, continuing with offset: " & curOffset)
              let moreResult = client.getStatementsHICAZ(fromDate, toDate, withTan = true, startOffset = curOffset)
              if moreResult.tanRequired and moreResult.orderRef.len > 0:
                # Bank wants TAN for continuation page — poll for it
                client.debug("TAN required for continuation page, polling...")
                let morePoll = client.pollDecoupledStatements(moreResult.orderRef)
                if morePoll.success:
                  allTransactions.add(morePoll.transactions)
                  curOffset = morePoll.nextOffset
                else:
                  client.debug("Continuation poll failed: " & morePoll.errorMsg)
                  break
              elif moreResult.success:
                allTransactions.add(moreResult.transactions)
                # getStatementsHICAZ handles its own pagination loop,
                # so if it returns success, all remaining pages are included
                curOffset = ""
              else:
                client.debug("Pagination failed: " & moreResult.errorCode & " " & moreResult.errorMsg)
                break
            result.success = true
            result.transactions = allTransactions
            return
          return pollResult
        # Otherwise try to fetch statements again (TAN should be confirmed now)
        let retryResult = client.getStatementsHICAZ(fromDate, toDate, withTan = false)
        if retryResult.success:
          return retryResult
        result = retryResult
        return
      elif pollResult.errorCode == "POLL_UNSUPPORTED":
        # Bank doesn't support polling - need manual confirmation
        client.prompt("press Enter after approving in app")
        client.wait()
        let retryResult = client.getStatementsHICAZ(fromDate, toDate, withTan = false)
        if retryResult.success:
          return retryResult
        result = retryResult
        return
      else:
        result = pollResult
        return

    # Try HKKAZ fallback if HICAZ fails
    client.debug("HICAZ failed, falling back to HKKAZ...")

  # Fall back to HKKAZ (MT940)
  if client.hkkazVersion > 0:
    client.debug("Trying HKKAZ (MT940 format)...")
    let hkkazResult = client.getStatementsHKKAZ(fromDate, toDate)
    if hkkazResult.success:
      return hkkazResult

    # Handle decoupled TAN for HKKAZ
    if hkkazResult.tanRequired and hkkazResult.orderRef.len > 0:
      client.debug("TAN required for HKKAZ statement retrieval")
      if hkkazResult.tanChallenge.len > 0 and hkkazResult.tanChallenge != "nochallenge":
        client.prompt(hkkazResult.tanChallenge)
      else:
        client.prompt("approve statement retrieval in your banking app")
      let pollResult = client.pollDecoupledStatements(hkkazResult.orderRef)
      if pollResult.success:
        if pollResult.transactions.len > 0:
          if pollResult.nextOffset.len > 0:
            var allTransactions = pollResult.transactions
            var curOffset = pollResult.nextOffset
            while curOffset.len > 0:
              client.debug("HKKAZ: more data available, continuing with offset: " & curOffset)
              let moreResult = client.getStatementsHKKAZ(fromDate, toDate, withTan = true, startOffset = curOffset)
              if moreResult.tanRequired and moreResult.orderRef.len > 0:
                client.debug("TAN required for HKKAZ continuation, polling...")
                let morePoll = client.pollDecoupledStatements(moreResult.orderRef)
                if morePoll.success:
                  allTransactions.add(morePoll.transactions)
                  curOffset = morePoll.nextOffset
                else:
                  client.debug("HKKAZ continuation poll failed: " & morePoll.errorMsg)
                  break
              elif moreResult.success:
                allTransactions.add(moreResult.transactions)
                curOffset = ""
              else:
                client.debug("HKKAZ pagination failed: " & moreResult.errorCode & " " & moreResult.errorMsg)
                break
            result.success = true
            result.transactions = allTransactions
            return
          return pollResult
        let retryResult = client.getStatementsHKKAZ(fromDate, toDate, withTan = false)
        if retryResult.success:
          return retryResult
        return retryResult
      elif pollResult.errorCode == "POLL_UNSUPPORTED":
        client.prompt("press Enter after approving in app")
        client.wait()
        let retryResult = client.getStatementsHKKAZ(fromDate, toDate, withTan = false)
        if retryResult.success:
          return retryResult
        return retryResult
      else:
        return pollResult

    result = hkkazResult
    return

  # HICAZ was tried but failed, use its error
  if hicazResult.errorCode.len > 0:
    return hicazResult

  # Neither supported
  result.errorMsg = "Bank does not advertise HICAZ or HKKAZ support"

proc fetchStatements*(url, blz, user, pin, productId: string,
                      iban, bic: string,
                      fromDate, toDate: string,
                      ui: UiHooks = UiHooks()): StatementResult =
  ## Convenience function to fetch account statements
  var client = newFintsClient(url, blz, user, pin, productId)
  client.ui = ui
  defer: client.close()

  client.account = Account(
    iban: iban,
    bic: bic,
    blz: blz
  )

  result = client.getStatements(fromDate, toDate)
  client.endDialog()

proc makeTransfer*(url, blz, user, pin, productId: string,
                   senderIban, senderBic, senderName: string,
                   recipientIban, recipientBic, recipientName: string,
                   amount: float, reference: string,
                   ui: UiHooks = UiHooks(),
                   instant: bool = true): TransferResult =
  ## Execute a complete transfer including TAN handling
  var client = newFintsClient(url, blz, user, pin, productId)
  client.ui = ui
  defer: client.close()

  client.account = Account(
    iban: senderIban,
    bic: senderBic,
    holder: senderName,
    blz: blz
  )

  let request = TransferRequest(
    recipientName: recipientName,
    recipientIban: recipientIban,
    recipientBic: recipientBic,
    amount: amount,
    currency: "EUR",
    reference: reference,
    instant: instant
  )

  result = client.transfer(request)

  # Handle decoupled TAN (SecureGo plus)
  if result.tanRequired:
    if result.tanChallenge.len > 0 and result.tanChallenge != "nochallenge":
      client.prompt(result.tanChallenge)
    else:
      client.prompt("approve transfer in your banking app")

    if result.orderRef.len > 0:
      let pollResult = client.pollDecoupledTan(result.orderRef)
      if pollResult.success:
        result = pollResult
      elif pollResult.errorCode == "POLL_UNSUPPORTED":
        client.prompt("press Enter after approving")
        client.wait()
        # Bank already confirmed acceptance (0020) in Step 3
        result.success = true
      else:
        result = pollResult
    else:
      client.prompt("press Enter after approving")
      client.wait()
      result.success = true

  client.endDialog()

