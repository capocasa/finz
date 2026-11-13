## Tests for FinTS library

import std/[unittest, strutils]
import ../src/finz

suite "FinTS message building":
  test "SEPA pain.001 generation":
    let account = Account(
      iban: "DE89370400440532013000",
      bic: "COBADEFFXXX",
      holder: "Max Mustermann",
      blz: "37040044"
    )

    let transfer = TransferRequest(
      recipientName: "Erika Musterfrau",
      recipientIban: "DE75512108001245126199",
      recipientBic: "SOLADEST600",
      amount: 100.50,
      currency: "EUR",
      reference: "Invoice 12345",
      instant: true
    )

    let messageId = "TEST123456"
    let xml = generatePain001(transfer, account, messageId)

    check xml.contains("pain.001.001.09")
    check xml.contains("DE89370400440532013000")
    check xml.contains("DE75512108001245126199")
    check xml.contains("100.50")  # XML uses dot format
    check xml.contains("INST")  # Instant payment marker
    check xml.contains("Invoice 12345")

  test "empty reference omits RmtInf entirely":
    let account = Account(
      iban: "DE89370400440532013000",
      bic: "COBADEFFXXX",
      holder: "Max Mustermann",
      blz: "37040044"
    )

    let transfer = TransferRequest(
      recipientName: "PayPal (Europe) S.a r.l. et Cie, S.C.A.",
      recipientIban: "LU897510000110287619",
      recipientBic: "PPLXLUL2XXX",
      amount: 44.74,
      currency: "EUR",
      reference: "",
      instant: true
    )

    let xml = generatePain001(transfer, account, "TEST123")
    # Ustrd has minLength=1 in pain.001.001.09; an empty one is schema-invalid
    check not xml.contains("<RmtInf>")
    check not xml.contains("<Ustrd>")

  test "non-instant transfer omits INST":
    let account = Account(
      iban: "DE89370400440532013000",
      bic: "COBADEFFXXX",
      holder: "Test",
      blz: "37040044"
    )

    let transfer = TransferRequest(
      recipientName: "Test",
      recipientIban: "DE75512108001245126199",
      recipientBic: "SOLADEST600",
      amount: 10.00,
      currency: "EUR",
      reference: "Test",
      instant: false  # Not instant
    )

    let xml = generatePain001(transfer, account, "TEST")
    check not xml.contains("<Cd>INST</Cd>")

suite "FinTS data escaping":
  test "escape special characters":
    check escapeFintsData("Hello+World") == "Hello?+World"
    check escapeFintsData("A:B:C") == "A?:B?:C"
    check escapeFintsData("Test'End") == "Test?'End"
    check escapeFintsData("100@200") == "100?@200"
    check escapeFintsData("??") == "????"

  test "unescape data":
    check unescapeFintsData("Hello?+World") == "Hello+World"
    check unescapeFintsData("A?:B?:C") == "A:B:C"
    check unescapeFintsData("????") == "??"

suite "Amount formatting":
  test "German decimal format":
    check formatAmount(100.50) == "100,50"
    check formatAmount(1000.00) == "1000,00"
    check formatAmount(0.01) == "0,01"
    check formatAmount(99999.99) == "99999,99"

suite "MT940 parsing":
  test "parse simple MT940 statement":
    let mt940 = """
:20:STARTUM
:25:37040044/0532013000
:28C:00001
:60F:C240101EUR1000,00
:61:2401020102D50,00NTRFNONREF//AUXREF
:86:?00ÜBERWEISUNG?20Test Reference?30COBADEFFXXX?31DE75512108001245126199?32Erika Musterfrau
:62F:C240102EUR950,00
"""
    let txs = parseMT940(mt940)
    check txs.len == 1
    check txs[0].amount == -50.0  # Debit
    check txs[0].currency == "EUR"
    check txs[0].valutaDate == "20240102"
    check txs[0].date == "20240102"
    check txs[0].name == "Erika Musterfrau"
    check txs[0].iban == "DE75512108001245126199"
    check txs[0].bic == "COBADEFFXXX"
    check txs[0].bookingText == "ÜBERWEISUNG"
    check "Test Reference" in txs[0].reference

  test "parse credit transaction":
    let mt940 = """
:60F:C240101EUR1000,00
:61:240103C200,00NTRFNONREF
:86:?00GUTSCHRIFT?20Payment received?32Max Mustermann
:62F:C240103EUR1200,00
"""
    let txs = parseMT940(mt940)
    check txs.len == 1
    check txs[0].amount == 200.0  # Credit (positive)

  test "parse multiple transactions":
    let mt940 = """
:60F:C240101EUR1000,00
:61:240102D100,00NTRFNONREF
:86:?00LASTSCHRIFT?32Company A
:61:240103C50,00NTRFNONREF
:86:?00GUTSCHRIFT?32Company B
:61:240104D25,50NTRFNONREF
:86:?00ÜBERWEISUNG?32Company C
:62F:C240104EUR924,50
"""
    let txs = parseMT940(mt940)
    check txs.len == 3
    check txs[0].amount == -100.0
    check txs[1].amount == 50.0
    check txs[2].amount == -25.5

  test "parse end-to-end reference":
    let mt940 = """
:60F:C240101EUR1000,00
:61:240102D50,00NTRFNONREF
:86:?00SEPA?20EREF+E2E123456789?21KREF+CUST123?32Someone
:62F:C240102EUR950,00
"""
    let txs = parseMT940(mt940)
    check txs.len == 1
    check txs[0].endToEndId == "E2E123456789"

suite "HKCAZ segment structure":
  test "HKCAZ without offset has 5 data fields":
    let account = Account(iban: "DE89370400440532013000", bic: "COBADEFFXXX", blz: "37040044")
    let seg = buildHKCAZ(3, account, "20250101", "20250401", "urn:iso:std:iso:20022:tech:xsd:camt.052.001.08")
    # Should be: HKCAZ:3:1+IBAN:BIC+escapedUrn+N+fromDate+toDate'
    let parts = seg.split('+')
    check parts.len == 6  # header + 5 data fields
    check parts[0] == "HKCAZ:3:1"
    check parts[3] == "N"
    check seg.endsWith("'")

  test "HKCAZ with offset has 7 data fields (empty max_responses before offset)":
    let account = Account(iban: "DE89370400440532013000", bic: "COBADEFFXXX", blz: "37040044")
    let seg = buildHKCAZ(3, account, "20250101", "20250401", "urn:iso:std:iso:20022:tech:xsd:camt.052.001.08", offset = "0_=2#=20251119")
    # Should be: HKCAZ:3:1+IBAN:BIC+escapedUrn+N+fromDate+toDate++offset'
    # Fields: account, camt_messages, all_accounts, date_start, date_end, max_number_responses(empty), touchdown_point
    let parts = seg.split('+')
    check parts.len == 8  # header + 7 data fields
    check parts[6] == ""  # empty max_number_responses
    check parts[7].endsWith("'")
    check "0_=2#=20251119" in parts[7]

  test "HKKAZ without offset has 4 data fields":
    let account = Account(iban: "DE89370400440532013000", bic: "COBADEFFXXX", blz: "37040044")
    let seg = buildHKKAZ(3, account, "20250101", "20250401", version = 7)
    let parts = seg.split('+')
    check parts.len == 5  # header + 4 data fields

  test "HKKAZ with offset has 6 data fields (empty max_responses before offset)":
    let account = Account(iban: "DE89370400440532013000", bic: "COBADEFFXXX", blz: "37040044")
    let seg = buildHKKAZ(3, account, "20250101", "20250401", offset = "OFFSET123", version = 7)
    let parts = seg.split('+')
    check parts.len == 7  # header + 6 data fields
    check parts[5] == ""  # empty max_number_responses
    check "OFFSET123" in parts[6]

suite "HKSAL balance":
  test "HKSAL v7 uses KTI and all_accounts flag":
    let account = Account(iban: "DE89370400440532013000", bic: "COBADEFFXXX", blz: "37040044")
    let seg = buildHKSAL(3, account, version = 7)
    # Should be: HKSAL:3:7+IBAN:BIC+N'
    let parts = seg.split('+')
    check parts[0] == "HKSAL:3:7"
    check parts[1] == "DE89370400440532013000:COBADEFFXXX"
    check parts[2] == "N'"
    check seg.endsWith("'")

  test "HKSAL v5 uses KTO":
    let account = Account(iban: "DE89370400440532013000", bic: "COBADEFFXXX", blz: "37040044")
    let seg = buildHKSAL(3, account, version = 5)
    let parts = seg.split('+')
    check parts[0] == "HKSAL:3:5"
    check parts[1] == "532013000::280:37040044"
    check parts[2] == "N'"

  test "HISAL v7 booked/pending/available parse":
    let hisal = "HISAL:7:4+DE89370400440532013000:COBADEFFXXX:532013000::280:37040044+Girokonto+EUR+C:1234,56:EUR:20260401:123025+C:-12,5:EUR:20260401:123025+:EUR+1500,00:EUR+1500,00:EUR'"
    let segments = parseAllSegments(hisal)
    check segments.len == 1
    let saldo = parseHISAL(segments[0])
    check saldo.balance == 1234.56
    check saldo.currency == "EUR"
    check saldo.date == "20260401"
    check saldo.pending == -12.5
    check saldo.available == 1500.00

  test "HISAL debit balance is negative":
    let hisal = "HISAL:7:4+DE89370400440532013000:COBADEFFXXX+Girokonto+EUR+D:50,00:EUR:20260401'"
    let segments = parseAllSegments(hisal)
    let saldo = parseHISAL(segments[0])
    check saldo.balance == -50.0
    check saldo.pending == 0.0
    check saldo.available == 0.0

suite "SEPA instant batch (HKIPM)":
  setup:
    var account {.inject.} = Account(
      iban: "DE89370400440532013000",
      bic: "COBADEFFXXX",
      holder: "Max Mustermann",
      blz: "37040044"
    )

  test "batch pain.001: totals, single PmtInf, per-tx EndToEndId":
    let payments = @[
      TransferRequest(recipientName: "Erika Musterfrau", recipientIban: "DE75512108001245126199",
        amount: 100.50, currency: "EUR", reference: "Invoice 1", instant: true),
      TransferRequest(recipientName: "Bob Bauers", recipientIban: "DE02120300000000202051",
        amount: 10.00, currency: "EUR", reference: "", instant: true)
    ]
    let xml = generatePain001Batch(payments, account, "20260101120000")

    check xml.contains("<NbOfTxs>2</NbOfTxs>")
    check xml.contains("<CtrlSum>110.50</CtrlSum>")
    check xml.count("<PmtInf>") == 1
    check xml.count("<CdtTrfTxInf>") == 2
    check xml.contains("<BtchBookg>false</BtchBookg>")
    check xml.contains("<Cd>INST</Cd>")
    check xml.contains("<EndToEndId>20260101120000-1</EndToEndId>")
    check xml.contains("<EndToEndId>20260101120000-2</EndToEndId>")
    # empty reference omits RmtInf entirely (Ustrd has minLength=1)
    check xml.count("<RmtInf>") == 1

  test "HKIPM segment: KTI, Summenfeld, descriptor, binary pain — no jn field":
    let pain = "<Document>x</Document>"
    let seg = buildHKIPM(3, account, 110.50, pain)
    let parts = seg.split('+')
    # header + kti + sum + descriptor + binary; an "Einzelbuchung" jn element
    # between sum and descriptor would shift the pain and the bank answers 9130
    check parts.len == 5
    check parts[0] == "HKIPM:3:1"
    check parts[1] == "DE89370400440532013000:COBADEFFXXX"
    check parts[2] == "110,50:EUR"
    check parts[3] == "urn?:iso?:std?:iso?:20022?:tech?:xsd?:pain.001.001.09"
    check parts[4] == "@" & $pain.len & "@" & pain & "'"

suite "VoP batch report (pain.002)":
  test "parse per-payment results":
    let report = """<?xml version="1.0" encoding="UTF-8"?>
<Document xmlns="urn:iso:std:iso:20022:tech:xsd:pain.002.001.10">
  <CstmrPmtStsRpt>
    <GrpHdr><MsgId>R1</MsgId></GrpHdr>
    <OrgnlGrpInfAndSts><OrgnlMsgId>M1</OrgnlMsgId></OrgnlGrpInfAndSts>
    <OrgnlPmtInfAndSts>
      <OrgnlPmtInfId>P1</OrgnlPmtInfId>
      <TxInfAndSts>
        <TxSts>RCVC</TxSts>
        <OrgnlTxRef>
          <Amt><InstdAmt Ccy="EUR">10.00</InstdAmt></Amt>
          <Cdtr><Pty><Nm>Bob Bauers</Nm></Pty></Cdtr>
          <CdtrAcct><Id><IBAN>DE02120300000000202051</IBAN></Id></CdtrAcct>
        </OrgnlTxRef>
      </TxInfAndSts>
      <TxInfAndSts>
        <TxSts>RVMC</TxSts>
        <StsRsnInf><AddtlInf>“Bob Bauer”</AddtlInf></StsRsnInf>
        <OrgnlTxRef>
          <Amt><InstdAmt Ccy="EUR">100.50</InstdAmt></Amt>
          <Cdtr><Pty><Nm>Erika Musterfrah</Nm></Pty></Cdtr>
          <CdtrAcct><Id><IBAN>DE75512108001245126199</IBAN></Id></CdtrAcct>
        </OrgnlTxRef>
      </TxInfAndSts>
    </OrgnlPmtInfAndSts>
  </CstmrPmtStsRpt>
</Document>"""
    let items = parseVopReport(report)
    check items.len == 2
    check items[0].code == "RCVC"
    check items[0].submittedName == "Bob Bauers"
    check items[0].iban == "DE02120300000000202051"
    check items[0].amount == "10.00"
    check items[1].code == "RVMC"
    # banks wrap the suggested name in typographic quotes — strip them
    check items[1].actualName == "Bob Bauer"
    check items[1].submittedName == "Erika Musterfrah"

  test "block-level status without TxInfAndSts":
    let report = """<?xml version="1.0" encoding="UTF-8"?>
<Document xmlns="urn:iso:std:iso:20022:tech:xsd:pain.002.001.10">
  <CstmrPmtStsRpt><OrgnlPmtInfAndSts>
    <OrgnlPmtInfId>P1</OrgnlPmtInfId>
    <PmtInfSts>RVNA</PmtInfSts>
  </OrgnlPmtInfAndSts></CstmrPmtStsRpt>
</Document>"""
    let items = parseVopReport(report)
    check items.len == 1
    check items[0].code == "RVNA"
    check items[0].submittedName == ""

when isMainModule:
  discard
