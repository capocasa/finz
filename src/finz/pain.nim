## pain.001 (SEPA credit transfer initiation) XML generation and the
## HKIPZ/HKCCS job segments that carry it.

import std/[strutils, times]
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
