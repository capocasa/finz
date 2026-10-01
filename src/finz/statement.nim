## Statement parsing: MT940 (SWIFT) and camt.052/053 XML.

import std/strutils
import finz/types

proc parseMT940Date(s: string): string =
  ## Parse MT940 date (YYMMDD) to YYYYMMDD
  if s.len >= 6:
    let yy = s[0..1]
    let year = if yy.parseInt >= 80: "19" & yy else: "20" & yy
    result = year & s[2..5]
  else:
    result = s

proc parseMT940Amount(s: string): float =
  ## Parse MT940 amount (with comma decimal separator)
  result = parseFloat(s.replace(",", "."))

proc parseMT940*(data: string): seq[Transaction] =
  ## Parse MT940 SWIFT message format into transactions
  result = @[]
  var currentTx: Transaction
  var inTx = false
  var multiLineRef = ""

  let lines = data.replace("\r\n", "\n").split('\n')
  var i = 0
  while i < lines.len:
    let line = lines[i]

    # :60F: or :60M: Opening balance - contains currency
    # Format: C/D + YYMMDD + CCY + amount (e.g., C240101EUR1000,00)
    if line.startsWith(":60F:") or line.startsWith(":60M:"):
      let content = line[5..^1]
      if content.len >= 10:
        currentTx.currency = content[7..9]

    # :61: Transaction line
    if line.startsWith(":61:"):
      if inTx:
        result.add(currentTx)
      currentTx = Transaction(currency: currentTx.currency)
      inTx = true
      multiLineRef = ""

      let content = line[4..^1]
      # Format: YYMMDD[YYMMDD]CD[R]amount[N...]//[ref]
      # Valuta date: first 6 chars
      if content.len >= 6:
        currentTx.valutaDate = parseMT940Date(content[0..5])
      # Booking date: next 4 chars (MMDD) if present
      var pos = 6
      if content.len > pos + 4 and content[pos] in '0'..'9':
        let mmdd = content[pos..pos+3]
        currentTx.date = currentTx.valutaDate[0..3] & mmdd
        pos += 4
      else:
        currentTx.date = currentTx.valutaDate

      # Credit/Debit indicator + optional R (reversal)
      if pos < content.len:
        let cd = content[pos]
        pos += 1
        if pos < content.len and content[pos] == 'R':
          pos += 1
        # Amount until N or /
        var amountStr = ""
        while pos < content.len and content[pos] notin {'N', '/'}:
          amountStr.add(content[pos])
          pos += 1
        if amountStr.len > 0:
          currentTx.amount = parseMT940Amount(amountStr)
          if cd == 'D':
            currentTx.amount = -currentTx.amount

    # :86: Details (multiple fields with separators)
    if line.startsWith(":86:"):
      let content = line[4..^1]
      # Collect continuation lines
      var fullContent = content
      while i + 1 < lines.len and not lines[i+1].startsWith(":"):
        i += 1
        fullContent.add(lines[i])

      # Parse structured format with ?XX fields
      if "?" in fullContent:
        var fields: array[100, string]
        var currentField = -1
        var j = 0
        while j < fullContent.len:
          if j + 2 < fullContent.len and fullContent[j] == '?':
            let fieldNum = try: parseInt(fullContent[j+1..j+2]) except: -1
            if fieldNum >= 0:
              currentField = fieldNum
              j += 3
              continue
          if currentField >= 0 and currentField < 100:
            fields[currentField].add(fullContent[j])
          j += 1

        # ?00 = booking text
        currentTx.bookingText = fields[0]
        # ?20-?29 = reference (Verwendungszweck)
        for k in 20..29:
          if fields[k].len > 0:
            if currentTx.reference.len > 0:
              currentTx.reference.add(" ")
            currentTx.reference.add(fields[k])
        # ?30 = BIC
        currentTx.bic = fields[30]
        # ?31 = IBAN (or account number)
        currentTx.iban = fields[31]
        # ?32-?33 = counterparty name
        currentTx.name = fields[32]
        if fields[33].len > 0:
          currentTx.name.add(" " & fields[33])
        # EREF+ in reference contains end-to-end ID
        let erefPos = currentTx.reference.find("EREF+")
        if erefPos >= 0:
          let afterEref = currentTx.reference[erefPos+5 .. ^1]
          # End-to-end ID ends at next + or space or end of string
          var endPos = afterEref.len
          for terminator in ["+", " "]:
            let pos = afterEref.find(terminator)
            if pos >= 0 and pos < endPos:
              endPos = pos
          currentTx.endToEndId = afterEref[0 ..< endPos]
      else:
        # Unstructured format - use as reference
        currentTx.reference = fullContent

    i += 1

  if inTx:
    result.add(currentTx)

proc extractXmlTag(xml: string, tag: string): string =
  ## Extract content between <tag> and </tag>
  let startTag = "<" & tag & ">"
  let endTag = "</" & tag & ">"
  let startPos = xml.find(startTag)
  if startPos < 0:
    return ""
  let contentStart = startPos + startTag.len
  let endPos = xml.find(endTag, contentStart)
  if endPos < 0:
    return ""
  return xml[contentStart ..< endPos]

proc extractXmlTagWithNs(xml: string, tag: string): string =
  ## Extract content, handling namespace prefixes like <ns:tag>
  # Try without namespace first
  result = extractXmlTag(xml, tag)
  if result.len > 0:
    return
  # Try to find tag with any namespace prefix
  let tagStart = "<"
  var pos = 0
  while pos < xml.len:
    let nextTag = xml.find(tagStart, pos)
    if nextTag < 0:
      break
    let tagEnd = xml.find(">", nextTag)
    if tagEnd < 0:
      break
    let fullTag = xml[nextTag+1 ..< tagEnd]
    # Check if this tag ends with :tagname or is just tagname
    if fullTag == tag or fullTag.endsWith(":" & tag):
      let closeTag = "</" & fullTag & ">"
      let contentStart = tagEnd + 1
      let closePos = xml.find(closeTag, contentStart)
      if closePos > 0:
        return xml[contentStart ..< closePos]
    pos = tagEnd + 1
  return ""

proc parseCamtAmount(s: string): float =
  ## Parse camt amount (uses dot decimal separator)
  try:
    result = parseFloat(s)
  except:
    result = 0.0

proc parseCamtDate(s: string): string =
  ## Parse camt date (YYYY-MM-DD) to YYYYMMDD
  result = s.replace("-", "")

proc parseCamt*(xml: string): seq[Transaction] =
  ## Parse camt.052/053 XML into transactions
  ## Handles both camt.052 (intraday) and camt.053 (end of day)
  result = @[]

  # Find all Ntry (entry) elements
  var pos = 0
  while pos < xml.len:
    let ntryStart = xml.find("<Ntry>", pos)
    if ntryStart < 0:
      # Try with namespace
      let nsNtryStart = xml.find(":Ntry>", pos)
      if nsNtryStart < 0:
        break
      pos = nsNtryStart
      continue

    # Find end of this Ntry
    let ntryEnd = xml.find("</Ntry>", ntryStart)
    if ntryEnd < 0:
      break

    let ntry = xml[ntryStart ..< ntryEnd + 7]
    var tx = Transaction()

    # Amount: <Amt Ccy="EUR">123.45</Amt>
    let amtStart = ntry.find("<Amt")
    if amtStart >= 0:
      let ccyStart = ntry.find("Ccy=\"", amtStart)
      if ccyStart >= 0:
        let ccyEnd = ntry.find("\"", ccyStart + 5)
        if ccyEnd > ccyStart:
          tx.currency = ntry[ccyStart + 5 ..< ccyEnd]
      let amtContentStart = ntry.find(">", amtStart) + 1
      let amtEnd = ntry.find("</Amt>", amtContentStart)
      if amtEnd > amtContentStart:
        tx.amount = parseCamtAmount(ntry[amtContentStart ..< amtEnd])

    # Credit/Debit: <CdtDbtInd>CRDT</CdtDbtInd> or DBIT
    let cdtDbt = extractXmlTag(ntry, "CdtDbtInd")
    if cdtDbt == "DBIT":
      tx.amount = -tx.amount

    # Booking date: <BookgDt><Dt>2024-01-15</Dt></BookgDt>
    let bookgDt = extractXmlTag(ntry, "BookgDt")
    if bookgDt.len > 0:
      tx.date = parseCamtDate(extractXmlTag(bookgDt, "Dt"))

    # Value date: <ValDt><Dt>2024-01-15</Dt></ValDt>
    let valDt = extractXmlTag(ntry, "ValDt")
    if valDt.len > 0:
      tx.valutaDate = parseCamtDate(extractXmlTag(valDt, "Dt"))
    if tx.valutaDate.len == 0:
      tx.valutaDate = tx.date

    # Bank transaction code / booking text
    let domn = extractXmlTag(ntry, "Domn")
    if domn.len > 0:
      tx.bookingText = extractXmlTag(domn, "Cd")

    # Entry details
    let ntryDtls = extractXmlTag(ntry, "NtryDtls")
    if ntryDtls.len > 0:
      let txDtls = extractXmlTag(ntryDtls, "TxDtls")
      if txDtls.len > 0:
        # Related parties
        let rltdPties = extractXmlTag(txDtls, "RltdPties")
        if rltdPties.len > 0:
          # Creditor or Debtor name
          let cdtr = extractXmlTag(rltdPties, "Cdtr")
          let dbtr = extractXmlTag(rltdPties, "Dbtr")
          let party = if cdtr.len > 0: cdtr else: dbtr
          if party.len > 0:
            tx.name = extractXmlTag(party, "Nm")
          # Creditor or Debtor account
          let cdtrAcct = extractXmlTag(rltdPties, "CdtrAcct")
          let dbtrAcct = extractXmlTag(rltdPties, "DbtrAcct")
          let acct = if cdtrAcct.len > 0: cdtrAcct else: dbtrAcct
          if acct.len > 0:
            let id = extractXmlTag(acct, "Id")
            tx.iban = extractXmlTag(id, "IBAN")

        # Related agents (BIC)
        let rltdAgts = extractXmlTag(txDtls, "RltdAgts")
        if rltdAgts.len > 0:
          let cdtrAgt = extractXmlTag(rltdAgts, "CdtrAgt")
          let dbtrAgt = extractXmlTag(rltdAgts, "DbtrAgt")
          let agt = if cdtrAgt.len > 0: cdtrAgt else: dbtrAgt
          if agt.len > 0:
            let finInstnId = extractXmlTag(agt, "FinInstnId")
            tx.bic = extractXmlTag(finInstnId, "BICFI")
            if tx.bic.len == 0:
              tx.bic = extractXmlTag(finInstnId, "BIC")

        # Remittance info (reference)
        let rmtInf = extractXmlTag(txDtls, "RmtInf")
        if rmtInf.len > 0:
          tx.reference = extractXmlTag(rmtInf, "Ustrd")

        # End-to-end ID
        let refs = extractXmlTag(txDtls, "Refs")
        if refs.len > 0:
          tx.endToEndId = extractXmlTag(refs, "EndToEndId")

    if tx.date.len > 0 or tx.amount != 0:
      result.add(tx)

    pos = ntryEnd + 7
