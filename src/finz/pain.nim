## pain.001 (SEPA credit transfer initiation) XML generation, the
## HKIPZ/HKIPM job segments that carry it, and pain.002 (VoP report)
## parsing for batch results.

import std/[strutils, times]
import std/xmltree
import std/math
import std/xmlparser
import finz/[types, wire]

proc escapeXml*(s: string): string =
  ## Escape special characters for XML content: & < > " '
  result = s
  result = result.replace("&", "&amp;")
  result = result.replace("<", "&lt;")
  result = result.replace(">", "&gt;")
  result = result.replace("\"", "&quot;")
  result = result.replace("'", "&apos;")

proc formatAmountXml*(amount: float): string =
  ## Format amount with dot decimal separator for pain.001 XML
  let parts = ($amount).split('.')
  if parts.len == 2:
    result = parts[0] & "." & parts[1].alignLeft(2, '0')[0..1]
  else:
    result = parts[0] & ".00"

proc generatePain001*(transfer: TransferRequest, debtor: Account, messageId: string): string =
  ## Generate pain.001.001.09 XML for SEPA instant transfer
  let amountStr = formatAmountXml(transfer.amount)
  let now = now()
  let creationDate = now.format("yyyy-MM-dd'T'HH:mm:ss")
  let requestedDate = if transfer.instant: "1999-01-01" else: now.format("yyyy-MM-dd")

  result = """<?xml version="1.0" encoding="UTF-8"?>
<Document xmlns="urn:iso:std:iso:20022:tech:xsd:pain.001.001.09" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
  <CstmrCdtTrfInitn>
    <GrpHdr>
      <MsgId>""" & messageId & """</MsgId>
      <CreDtTm>""" & creationDate & """</CreDtTm>
      <NbOfTxs>1</NbOfTxs>
      <CtrlSum>""" & amountStr & """</CtrlSum>
      <InitgPty>
        <Nm>""" & escapeXml(debtor.holder) & """</Nm>
      </InitgPty>
    </GrpHdr>
    <PmtInf>
      <PmtInfId>""" & messageId & """-1</PmtInfId>
      <PmtMtd>TRF</PmtMtd>
      <BtchBookg>true</BtchBookg>
      <NbOfTxs>1</NbOfTxs>
      <CtrlSum>""" & amountStr & """</CtrlSum>
      <PmtTpInf>
        <SvcLvl>
          <Cd>SEPA</Cd>
        </SvcLvl>"""

  # Add instant payment local instrument if requested
  if transfer.instant:
    result.add """
        <LclInstrm>
          <Cd>INST</Cd>
        </LclInstrm>"""

  result.add """
      </PmtTpInf>
      <ReqdExctnDt>
        <Dt>""" & requestedDate & """</Dt>
      </ReqdExctnDt>
      <Dbtr>
        <Nm>""" & escapeXml(debtor.holder) & """</Nm>
      </Dbtr>
      <DbtrAcct>
        <Id>
          <IBAN>""" & debtor.iban & """</IBAN>
        </Id>
      </DbtrAcct>
      <DbtrAgt>
        <FinInstnId>
          <BICFI>""" & debtor.bic & """</BICFI>
        </FinInstnId>
      </DbtrAgt>
      <ChrgBr>SLEV</ChrgBr>
      <CdtTrfTxInf>
        <PmtId>
          <EndToEndId>""" & messageId & """</EndToEndId>
        </PmtId>
        <Amt>
          <InstdAmt Ccy='""" & transfer.currency & """'>""" & amountStr & """</InstdAmt>
        </Amt>"""

  if transfer.recipientBic.len > 0:
    result.add """
        <CdtrAgt>
          <FinInstnId>
            <BICFI>""" & transfer.recipientBic & """</BICFI>
          </FinInstnId>
        </CdtrAgt>"""

  result.add """
        <Cdtr>
          <Nm>""" & escapeXml(transfer.recipientName) & """</Nm>
        </Cdtr>
        <CdtrAcct>
          <Id>
            <IBAN>""" & transfer.recipientIban & """</IBAN>
          </Id>
        </CdtrAcct>"""

  # Ustrd has minLength=1 in pain.001.001.09 — omit RmtInf entirely when empty
  if transfer.reference.len > 0:
    result.add """
        <RmtInf>
          <Ustrd>""" & escapeXml(transfer.reference) & """</Ustrd>
        </RmtInf>"""

  result.add """
      </CdtTrfTxInf>
    </PmtInf>
  </CstmrCdtTrfInitn>
</Document>"""

proc generatePain001Batch*(payments: seq[TransferRequest], debtor: Account, messageId: string): string =
  ## Generate pain.001.001.09 XML for a SEPA instant batch transfer
  ## (Sammelüberweisung): one PmtInf holding one CdtTrfTxInf per payment.
  ## Banks accept exactly one PmtInf per collective order; GrpHdr and
  ## PmtInf carry the true NbOfTxs/CtrlSum.
  var totalCents = 0
  for p in payments:
    totalCents += (p.amount * 100).round.int
  let totalStr = formatAmountXml(totalCents / 100)
  let now = now()
  let creationDate = now.format("yyyy-MM-dd'T'HH:mm:ss")

  result = """
<?xml version="1.0" encoding="UTF-8"?>
<Document xmlns="urn:iso:std:iso:20022:tech:xsd:pain.001.001.09" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
  <CstmrCdtTrfInitn>
    <GrpHdr>
      <MsgId>""" & messageId & """</MsgId>
      <CreDtTm>""" & creationDate & """</CreDtTm>
      <NbOfTxs>""" & $payments.len & """</NbOfTxs>
      <CtrlSum>""" & totalStr & """</CtrlSum>
      <InitgPty>
        <Nm>""" & escapeXml(debtor.holder) & """</Nm>
      </InitgPty>
    </GrpHdr>
    <PmtInf>
      <PmtInfId>""" & messageId & """-1</PmtInfId>
      <PmtMtd>TRF</PmtMtd>
      <BtchBookg>false</BtchBookg>
      <NbOfTxs>""" & $payments.len & """</NbOfTxs>
      <CtrlSum>""" & totalStr & """</CtrlSum>
      <PmtTpInf>
        <SvcLvl>
          <Cd>SEPA</Cd>
        </SvcLvl>
        <LclInstrm>
          <Cd>INST</Cd>
        </LclInstrm>
      </PmtTpInf>
      <ReqdExctnDt>
        <Dt>1999-01-01</Dt>
      </ReqdExctnDt>
      <Dbtr>
        <Nm>""" & escapeXml(debtor.holder) & """</Nm>
      </Dbtr>
      <DbtrAcct>
        <Id>
          <IBAN>""" & debtor.iban & """</IBAN>
        </Id>
      </DbtrAcct>
      <DbtrAgt>
        <FinInstnId>
          <BICFI>""" & debtor.bic & """</BICFI>
        </FinInstnId>
      </DbtrAgt>
      <ChrgBr>SLEV</ChrgBr>"""

  for i, p in payments:
    let amountStr = formatAmountXml(p.amount)
    result.add """
      <CdtTrfTxInf>
        <PmtId>
          <EndToEndId>""" & messageId & "-" & $(i + 1) & """</EndToEndId>
        </PmtId>
        <Amt>
          <InstdAmt Ccy='""" & p.currency & """'>""" & amountStr & """</InstdAmt>
        </Amt>"""
    if p.recipientBic.len > 0:
      result.add """
        <CdtrAgt>
          <FinInstnId>
            <BICFI>""" & p.recipientBic & """</BICFI>
          </FinInstnId>
        </CdtrAgt>"""
    result.add """
        <Cdtr>
          <Nm>""" & escapeXml(p.recipientName) & """</Nm>
        </Cdtr>
        <CdtrAcct>
          <Id>
            <IBAN>""" & p.recipientIban & """</IBAN>
          </Id>
        </CdtrAcct>"""
    # Ustrd has minLength=1 in pain.001.001.09 — omit RmtInf entirely when empty
    if p.reference.len > 0:
      result.add """
        <RmtInf>
          <Ustrd>""" & escapeXml(p.reference) & """</Ustrd>
        </RmtInf>"""
    result.add """
      </CdtTrfTxInf>"""

  result.add """
    </PmtInf>
  </CstmrCdtTrfInitn>
</Document>"""

proc buildHKIPM*(segNum: int, account: Account, totalAmount: float, pain: string): string =
  ## Build HKIPM segment (SEPA-Instant-Sammelüberweisung) from a batch
  ## pain.001. Unlike HKCCM there is no "Einzelbuchung gewünscht" element:
  ## the layout is KTI, Summenfeld, SEPA-Descriptor, pain message. An extra
  ## jn element shifts the binary pain by one position and banks answer
  ## 9130 (kein Binärfeld gefunden). The booking mode lives in the pain
  ## (BtchBookg).
  let kti = account.iban & ":" & account.bic
  let data = @[
    kti,
    formatAmount(totalAmount) & ":EUR",
    "urn?:iso?:std?:iso?:20022?:tech?:xsd?:pain.001.001.09",
    "@" & $pain.len & "@" & pain
  ]
  result = buildSegment("HKIPM", 1, segNum, data)

proc el(n: XmlNode, path: varargs[string]): XmlNode =
  ## First descendant element along an explicit tag path, nil if absent.
  result = n
  for tag in path:
    if result == nil: return
    result = result.child(tag)

proc parseVopReport*(report: string): seq[VopItem] =
  ## Parse a pain.002 payment status report carrying VoP results for a
  ## batch: one TxInfAndSts per payment with the match code in TxSts, the
  ## bank-suggested name in StsRsnInf/AddtlInf and the submitted payment
  ## in OrgnlTxRef. Some banks omit TxInfAndSts and report only a status
  ## for the whole PmtInf — that yields a single item without details.
  result = @[]
  let doc = parseXml(report)
  for pmtInf in doc.findAll("OrgnlPmtInfAndSts"):
    let txs = pmtInf.findAll("TxInfAndSts")
    if txs.len == 0:
      var code = ""
      for tag in ["PmtInfSts", "OrgnlPmtInfSts"]:
        let n = pmtInf.findAll(tag)
        if n.len > 0 and n[0].innerText.len > 0:
          code = n[0].innerText
          break
      if code.len > 0:
        result.add VopItem(code: code)
      continue
    for tx in txs:
      var item = VopItem()
      let sts = tx.findAll("TxSts")
      if sts.len > 0:
        item.code = sts[0].innerText
      # Bank-suggested (close match) name; banks wrap it in quotes
      let addtl = tx.findAll("AddtlInf")
      if addtl.len > 0:
        item.actualName = addtl[0].innerText.strip
        # quote marks may be ASCII or typographic (multi-byte: removePrefix
        # cuts whole characters, byte slicing would not)
        for q in ["\"", "\u201C"]:
          item.actualName.removePrefix(q)
        for q in ["\"", "\u201D"]:
          item.actualName.removeSuffix(q)
      if el(tx, "OrgnlTxRef", "Cdtr", "Pty", "Nm") != nil:
        item.submittedName = el(tx, "OrgnlTxRef", "Cdtr", "Pty", "Nm").innerText
      if el(tx, "OrgnlTxRef", "CdtrAcct", "Id", "IBAN") != nil:
        item.iban = el(tx, "OrgnlTxRef", "CdtrAcct", "Id", "IBAN").innerText
      if el(tx, "OrgnlTxRef", "Amt", "InstdAmt") != nil:
        item.amount = el(tx, "OrgnlTxRef", "Amt", "InstdAmt").innerText
      result.add item

proc buildHKIPZFromPain*(segNum: int, account: Account, pain: string): string =
  ## Build HKIPZ segment from pre-generated pain.001 XML
  let kti = account.iban & ":" & account.bic
  let data = @[
    kti,
    "urn?:iso?:std?:iso?:20022?:tech?:xsd?:pain.001.001.09",
    "@" & $pain.len & "@" & pain
  ]
  result = buildSegment("HKIPZ", 1, segNum, data)

proc buildHKIPZ(segNum: int, account: Account, transfer: TransferRequest): string =
  ## Build HKIPZ segment (Einzelne SEPA-Instant-Überweisung)
  let messageId = generateReference()
  let pain = generatePain001(transfer, account, messageId)
  result = buildHKIPZFromPain(segNum, account, pain)

proc buildHKCCS(segNum: int, account: Account, transfer: TransferRequest): string =
  ## Build HKCCS segment (Einzelne SEPA-Überweisung) - standard non-instant
  let messageId = generateReference()
  let pain = generatePain001(transfer, account, messageId)

  let kti = account.iban & ":" & account.bic

  let data = @[
    kti,
    "urn?:iso?:std?:iso?:20022?:tech?:xsd?:pain.001.001.09",
    "@" & $pain.len & "@" & pain
  ]
  result = buildSegment("HKCCS", 1, segNum, data)
