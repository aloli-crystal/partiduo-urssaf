# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

# Suivi de la tierce déclaration (ADR-007 D7, DECISIONS D-URS-001 à
# D-URS-004) : cas limites. Extension inactive, permissions de chaque
# commande, refus du télépaiement et du mandat SEPA, IBAN jamais conservé en
# clair (même rendu en clair par un adaptateur), relevé des mandats SEPA
# révoqués chez l'URSSAF, panne pendant le relevé, anomalies sans doublon,
# rejet d'une déclaration noté en anomalie.

private alias S = Urssaf::SpecSupport
private alias Api = Urssaf::Api

private def keys(result) : Array(String)
  result.errors.map(&.key)
end

private def july : Time
  S::Books.date("2026-07-01")
end

private def ready : Nil
  S.books
  S.connect
  S.mandate
end

private def sepa_input(iban : String = S::IBAN, holder : String = "Jeanne Martin",
                       signed_on : Time = S::Books.date("2026-01-05"), accepted : Bool = true) : Api::SepaMandateInput
  Api::SepaMandateInput.new(iban, "AGRIFRPP", holder, signed_on, accepted)
end

# Adaptateur qui rendrait l'IBAN en clair, groupé par quatre caractères
# comme sur un relevé bancaire.
private class ClearIbanUrssaf < Urssaf::SimulatedUrssaf
  def register_sepa_mandate(credentials : Urssaf::Credentials, request : Urssaf::SepaMandateRequest) : Urssaf::SepaMandate
    mandate = super
    spaced = request.iban.scan(/.{1,4}/).map(&.[0]).join(" ")
    clear = Urssaf::SepaMandate.new(mandate.rum, spaced, mandate.holder, mandate.status, mandate.signed_on)
    sepa[mandate.rum] = clear
    clear
  end
end

describe "URSSAF — suivi : extension inactive et permissions" do
  it "lève ModuleDisabled sur chaque commande du suivi quand l'extension est inactive" do
    S.books
    Partiduo::Api::Modules.deactivate(S::SYSTEM, Urssaf::CODE).value!
    admin = S.admin
    expect_raises(Partiduo::Api::ModuleDisabled) { Api.overview(admin) }
    expect_raises(Partiduo::Api::ModuleDisabled) { Api.pending_count(admin) }
    expect_raises(Partiduo::Api::ModuleDisabled) { Api.payments(admin) }
    expect_raises(Partiduo::Api::ModuleDisabled) { Api.anomalies(admin) }
    expect_raises(Partiduo::Api::ModuleDisabled) { Api.resolve_anomaly(admin, 1_i64) }
    expect_raises(Partiduo::Api::ModuleDisabled) { Api.refresh(admin) }
    expect_raises(Partiduo::Api::ModuleDisabled) { Api.pay(admin, july) }
    expect_raises(Partiduo::Api::ModuleDisabled) { Api.sepa_mandates(admin) }
    expect_raises(Partiduo::Api::ModuleDisabled) { Api.register_sepa_mandate(admin, sepa_input) }
    expect_raises(Partiduo::Api::ModuleDisabled) { Api.revoke_sepa_mandate(admin, "RUM-1") }
    expect_raises(Partiduo::Api::ModuleDisabled) { Api.receipt(admin, july) }
    S.urssaf.sepa.should be_empty
    Urssaf::Event.all.count.should eq(0)
  end

  it "exige la lecture pour consulter, la transmission pour traiter une anomalie, le paiement pour le SEPA" do
    ready
    S.declared_quarter
    S.urssaf.reported["DECL-101"] = ["Activité à préciser"]
    Api.refresh(S.admin).value!.should eq(1)
    anomaly = Api.anomalies(S.admin).first

    nobody = S.admin([] of String)
    expect_raises(Partiduo::Api::Forbidden) { Api.overview(nobody) }
    expect_raises(Partiduo::Api::Forbidden) { Api.pending_count(nobody) }
    expect_raises(Partiduo::Api::Forbidden) { Api.anomalies(nobody) }
    expect_raises(Partiduo::Api::Forbidden) { Api.refresh(nobody) }
    expect_raises(Partiduo::Api::Forbidden) { Api.receipt(nobody, july) }

    reader = S.admin([Api::READ])
    Api.overview(reader).anomalies.size.should eq(1)
    Api.receipt(reader, july).filename.should eq("accuse-DECL-101.pdf")
    expect_raises(Partiduo::Api::Forbidden) { Api.resolve_anomaly(reader, anomaly.id) }
    expect_raises(Partiduo::Api::Forbidden) { Api.register_sepa_mandate(reader, sepa_input) }
    # La transmission des déclarations ne donne pas le droit de payer.
    declarer = S.admin([Api::READ, Api::TRANSMIT, Api::SETTINGS])
    expect_raises(Partiduo::Api::Forbidden) { Api.register_sepa_mandate(declarer, sepa_input) }
    Api.resolve_anomaly(declarer, anomaly.id).value!
    S.urssaf.sepa.should be_empty
  end
end

describe "URSSAF — télépaiement : refus" do
  it "refuse sans transport, sur une panne ou sans mandat notifié, sans rien enregistrer" do
    ready
    S.declared_quarter
    S.sepa
    simulated = S.urssaf

    simulated.failure = "panne"
    keys(Api.pay(S.admin, july)).should eq(["urssaf.errors.transport.unavailable"])
    Urssaf::Payment.all.count.should eq(0)
    Api.events(S.admin).first.action.should eq("error")
    simulated.failure = nil

    Urssaf::Transports.current = nil
    keys(Api.pay(S.admin, july)).should eq(["urssaf.controls.no_transport"])
    Urssaf::Transports.current = simulated

    Api.revoke_mandate(S.admin).value!
    keys(Api.pay(S.admin, july)).should eq(["urssaf.controls.mandate_missing"])
    Urssaf::Payment.all.count.should eq(0)
    simulated.payments.should be_empty
  end

  it "refuse de payer une déclaration rejetée" do
    ready
    S.sepa
    S.receipt("2026-07-10", "500")
    Partiduo::Config.travel_to(Time.utc(2026, 10, 5, 9, 0, 0)) do
      S.urssaf.rejection = "Compte suspendu"
      Api.declare(S.admin, july)
    end
    keys(Api.pay(S.admin, july)).should eq(["urssaf.errors.payment.not_declared"])
  end

  it "numérote les ordres de paiement de la période : un nouvel ordre après un rejet" do
    ready
    S.declared_quarter
    S.sepa
    Api.pay(S.admin, july).value!
    S.urssaf.payment_outcome = "rejected"
    Api.refresh(S.admin).value!
    S.urssaf.payment_outcome = "done"
    Api.pay(S.admin, july).value!
    Urssaf::Payment.all.order("id").map(&.reference)
      .should eq(%w[PDUO-PAY-732829320-20260701-1 PDUO-PAY-732829320-20260701-2])
    Api.refresh(S.admin).value!.should eq(1)
    Api.payments(S.admin).map(&.status).should eq(%w[done rejected])
    rejected = Urssaf::Payment.filter(status: "rejected").first || raise "paiement rejeté absent"
    rejected.reason.should eq("Provision insuffisante")
    filing = Api.periods(S.admin, 2026).find!(&.starts_on.==(july)).filing || raise "sans déclaration"
    {filing.paid_total, filing.remaining}.should eq({S::Books.d("105"), S::Books.d("0")})
  end
end

describe "URSSAF — mandats SEPA : refus et IBAN" do
  it "refuse le mandat SEPA sans mandat notifié, daté du futur ou au titulaire trop long" do
    S.books
    S.connect
    keys(Api.register_sepa_mandate(S.admin, sepa_input)).should eq(["urssaf.controls.mandate_missing"])
    S.mandate
    future = Partiduo::Config.today + 1.day
    keys(Api.register_sepa_mandate(S.admin, sepa_input(signed_on: future))).should eq(["urssaf.errors.mandate.future"])
    keys(Api.register_sepa_mandate(S.admin, sepa_input(holder: "x" * 141))).should eq(["urssaf.errors.sepa.holder"])
    keys(Api.register_sepa_mandate(S.admin, sepa_input(holder: "   "))).should eq(["urssaf.errors.sepa.holder"])
    S.urssaf.sepa.should be_empty
    Urssaf::SepaMandateRow.all.count.should eq(0)
  end

  it "ne garde l'IBAN ni en base ni dans l'historique, ni dans la représentation de l'entrée" do
    ready
    S.sepa
    S.urssaf.sepa_ibans.values.should eq(["FR7630006000011234567890189"])
    Urssaf::SepaMandateRow.all.map(&.iban_masked).should eq(["FR76 **** **** 0189"])
    Api.events(S.admin).map(&.detail).join(" ").should_not contain("3000600001123456789")
    input = sepa_input
    input.to_s.should_not contain("30006000")
    input.inspect.should_not contain("30006000")
  end

  it "masque un IBAN rendu en clair par l'adaptateur, groupé ou non" do
    Urssaf::Transports.current = ClearIbanUrssaf.new
    ready
    mandate = S.sepa
    mandate.iban_masked.should eq("FR76 **** **** 0189")
    Urssaf::SepaMandateRow.all.map(&.iban_masked).should eq(["FR76 **** **** 0189"])
    # Au relevé aussi : l'URSSAF rend la liste de ses mandats SEPA.
    Api.refresh(S.admin).value!
    Urssaf::SepaMandateRow.all.map(&.iban_masked).should eq(["FR76 **** **** 0189"])
  end

  it "note révoqué un mandat SEPA absent chez l'URSSAF ; le paiement est alors refusé" do
    ready
    S.declared_quarter
    mandate = S.sepa
    S.urssaf.sepa.delete(mandate.rum)
    Api.refresh(S.admin).value!
    row = Urssaf::SepaMandateRow.filter(rum: mandate.rum).first || raise "mandat SEPA absent"
    row.status.should eq("revoked")
    row.revoked_at.should_not be_nil
    Api.overview(S.admin, S::Books.date("2026-10-05")).sepa_mandate.should be_nil
    keys(Api.pay(S.admin, july)).should eq(["urssaf.errors.payment.no_sepa"])
  end
end

describe "URSSAF — relevé et anomalies" do
  it "ne change rien si l'URSSAF est en panne pendant le relevé" do
    ready
    S.declared_quarter
    S.urssaf.mandates.clear
    S.urssaf.failure = "panne"
    keys(Api.refresh(S.admin)).should eq(["urssaf.errors.transport.unavailable"])
    Api.settings(S.admin).mandate_status.should eq("notified")
    Api.anomalies(S.admin).should be_empty
    Api.events(S.admin).first.action.should eq("error")
  end

  it "refuse le relevé sans identifiants" do
    S.books
    keys(Api.refresh(S.admin)).should eq(["urssaf.controls.no_credentials"])
  end

  it "tronque le détail d'une anomalie à 2 000 caractères, sans doublon au relevé suivant" do
    ready
    S.declared_quarter
    S.urssaf.reported["DECL-101"] = ["é" * 2500, "Autre point"]
    Api.refresh(S.admin).value!.should eq(2)
    Api.refresh(S.admin).value!.should eq(2)
    details = Api.anomalies(S.admin).map(&.detail)
    details.map(&.size).sort!.should eq([11, 2000])
    # Traitée, la même anomalie signalée de nouveau est rouverte.
    Api.anomalies(S.admin).each { |item| Api.resolve_anomaly(S.admin, item.id).value! }
    Api.refresh(S.admin).value!.should eq(2)
    Api.anomalies(S.admin, open_only: false).size.should eq(4)
  end

  it "note en anomalie le rejet d'une déclaration, une seule fois pour le même motif" do
    ready
    S.receipt("2026-07-10", "500")
    Partiduo::Config.travel_to(Time.utc(2026, 10, 5, 9, 0, 0)) do
      S.urssaf.rejection = "Compte suspendu"
      2.times { keys(Api.declare(S.admin, july)).should eq(["urssaf.errors.transport.rejected"]) }
    end
    anomalies = Api.anomalies(S.admin)
    anomalies.map { |item| {item.code, item.detail, item.starts_on} }.should eq([{"rejected", "Compte suspendu", july}])
    Api.pending_count(S.admin, S::Books.date("2026-10-05")).should be >= 1
  end

  it "refuse de traiter une anomalie inconnue" do
    S.books
    keys(Api.resolve_anomaly(S.admin, 424_242_i64)).should eq(["urssaf.errors.anomaly"])
  end
end

describe "Urssaf::Iban — IBAN en clair" do
  it "reconnaît un IBAN en clair quels que soient les séparateurs, et le masque" do
    Urssaf::Iban.clear?("FR7630006000011234567890189").should be_true
    Urssaf::Iban.clear?("FR76 3000 6000 0112 3456 7890 189").should be_true
    Urssaf::Iban.clear?("FR76-3000-6000-0112-3456-7890-189").should be_true
    Urssaf::Iban.clear?("FR76 **** **** 0189").should be_false
    Urssaf::Iban.mask("FR76-3000-6000-0112-3456-7890-189").should eq("FR76 **** **** 0189")
    Urssaf::Iban.mask("FR76 3000").should eq("FR76 **** **** 3000")
    Urssaf::Iban.mask("FR76").should eq("****")
  end
end
