# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

# Intégrité en base du suivi (migration 0002, DECISIONS D-URS-001 et
# D-URS-003), vérifiée par des instructions SQL directes : ce que la base
# refuse même si le code se trompait.

private alias S = Urssaf::SpecSupport

private def sql(statement : String) : Nil
  Marten::DB::Connection.default.open(&.exec(statement))
  nil
end

private def filing_id : Int64
  (Urssaf::Filing.all.first || raise "déclaration absente").id!.to_i64
end

private def payment(amount : String = "10", status : String = "initiated", reason : String = "",
                    filing : Int64 = filing_id, reference : String = "REF-#{Random::Secure.hex(4)}") : Nil
  sql("INSERT INTO urssaf_payment (filing_id, reference, remote_id, amount, sepa_rum, status, reason, " \
      "created_at, updated_at) VALUES (#{filing}, '#{reference}', '', #{amount}, 'RUM-1', '#{status}', " \
      "'#{reason}', now(), now())")
end

private def sepa(iban : String, status : String = "active", revoked_at : String = "NULL",
                 rum : String = "RUM-#{Random::Secure.hex(4)}") : Nil
  sql("INSERT INTO urssaf_sepa_mandate (rum, iban_masked, holder, status, signed_on, revoked_at, created_at, " \
      "updated_at) VALUES ('#{rum}', '#{iban}', 'Jeanne Martin', '#{status}', '2026-01-05', #{revoked_at}, now(), now())")
end

describe "URSSAF — intégrité en base du suivi" do
  it "exige un paiement positif, d'un statut connu, motivé s'il est rejeté, rattaché à une déclaration" do
    S.books
    S.connect
    S.mandate
    S.declared_quarter
    payment
    payment(status: "rejected", reason: "Provision insuffisante")
    expect_raises(Exception, /urssaf_payment_amount_check/) { payment(amount: "0") }
    expect_raises(Exception, /urssaf_payment_amount_check/) { payment(amount: "-5") }
    expect_raises(Exception, /urssaf_payment_status_check/) { payment(status: "pending") }
    expect_raises(Exception, /urssaf_payment_reason_check/) { payment(status: "rejected") }
    expect_raises(Exception, /urssaf_payment_filing_fk/) { payment(filing: 999_999_i64) }
    payment(reference: "UNIQUE-1")
    expect_raises(Exception, /unique|duplicate|dupliqu/i) { payment(reference: "UNIQUE-1") }
    Urssaf::Payment.all.count.should eq(3)
  end

  it "n'accepte que les codes d'anomalie connus" do
    S.books
    Urssaf::Config::ANOMALY_CODES.each do |code|
      sql("INSERT INTO urssaf_anomaly (code, detail, created_at, updated_at) VALUES ('#{code}', '', now(), now())")
    end
    expect_raises(Exception, /urssaf_anomaly_code_check/) do
      sql("INSERT INTO urssaf_anomaly (code, detail, created_at, updated_at) VALUES ('autre', '', now(), now())")
    end
    expect_raises(Exception, /urssaf_anomaly_filing_fk/) do
      sql("INSERT INTO urssaf_anomaly (filing_id, code, created_at, updated_at) VALUES (999999, 'urssaf', now(), now())")
    end
  end

  it "ne garde qu'un IBAN masqué, une RUM unique et la date d'un mandat SEPA révoqué" do
    S.books
    sepa("FR76 **** **** 0189")
    sepa("BE68 **** **** 7034", status: "revoked", revoked_at: "now()")
    expect_raises(Exception, /urssaf_sepa_mandate_masked_check/) { sepa("FR7630006000011234567890189") }
    expect_raises(Exception, /urssaf_sepa_mandate_masked_check/) { sepa("FR76 3000 6000 0112 3456 7890 189") }
    expect_raises(Exception, /urssaf_sepa_mandate_revoked_check/) { sepa("FR76 **** **** 0189", status: "revoked") }
    expect_raises(Exception, /urssaf_sepa_mandate_status_check/) { sepa("FR76 **** **** 0189", status: "suspended") }
    sepa("FR76 **** **** 0189", rum: "RUM-X")
    expect_raises(Exception, /unique|duplicate|dupliqu/i) { sepa("FR76 **** **** 0189", rum: "RUM-X") }
    Urssaf::SepaMandateRow.all.count.should eq(3)
  end

  it "n'accepte dans l'historique que les actions connues, celles du suivi comprises" do
    S.books
    Urssaf::Config::EVENT_ACTIONS.each do |action|
      sql("INSERT INTO urssaf_event (action, detail, created_at) VALUES ('#{action}', '', now())")
    end
    expect_raises(Exception, /urssaf_event_action_check/) do
      sql("INSERT INTO urssaf_event (action, detail, created_at) VALUES ('hack', '', now())")
    end
  end

  it "rattache l'accusé à une pièce jointe existante" do
    S.books
    S.connect
    S.mandate
    # Déclaration rejetée : modifiable (une acceptée est intangible).
    S.receipt("2026-07-10", "500")
    S.urssaf.rejection = "Compte suspendu"
    Partiduo::Config.travel_to(Time.utc(2026, 10, 5, 9, 0, 0)) do
      Urssaf::Api.declare(S.admin, S::Books.date("2026-07-01"))
    end
    expect_raises(Exception, /urssaf_filing_receipt_fk/) do
      sql("UPDATE urssaf_filing SET receipt_attachment_id = 999999")
    end
  end
end
