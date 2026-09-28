# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

# Corrections de relecture du lot U (DECISIONS D-URS-008 à D-URS-012) :
# déclaration idempotente et sérialisée, télépaiement tenant compte des
# paiements faits hors de Partiduo, permissions du module `micro` exigées,
# relevé réservé à la transmission, anomalies au détail neutre, paiement
# sans numéro de l'URSSAF, chiffre d'affaires négatif refusé, compteur
# léger.

private alias S = Urssaf::SpecSupport
private alias Api = Urssaf::Api
private alias Micro = Partiduo::Api::Micro

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

private def at_october(&)
  Partiduo::Config.travel_to(Time.utc(2026, 10, 5, 9, 0, 0)) { yield }
end

# URSSAF qui accepte la déclaration, puis dont la réponse se perd (coupure
# du réseau) : `cuts` fois.
private class CutAfterAcceptUrssaf < Urssaf::SimulatedUrssaf
  property cuts = 1

  def declare(credentials : Urssaf::Credentials, submission : Urssaf::Submission) : Urssaf::Acknowledgement
    ack = super
    if cuts > 0
      @cuts -= 1
      raise Urssaf::TransportError.new("urssaf.errors.transport.unavailable")
    end
    ack
  end
end

# URSSAF lente : laisse une seconde déclaration concurrente se présenter
# pendant l'appel.
private class SlowUrssaf < Urssaf::SimulatedUrssaf
  def declare(credentials : Urssaf::Credentials, submission : Urssaf::Submission) : Urssaf::Acknowledgement
    sleep 50.milliseconds
    super
  end
end

private def contribution(category : String, turnover : String) : Micro::ContributionView
  zero = BigDecimal.new(0)
  Micro::ContributionView.new(category, BigDecimal.new(turnover), nil, zero, nil, zero, nil, zero)
end

describe "URSSAF — déclaration idempotente et sérialisée (D-URS-008)" do
  it "renvoie la même référence après une réponse perdue : une seule déclaration à l'URSSAF" do
    Urssaf::Transports.current = CutAfterAcceptUrssaf.new
    ready
    S.receipt("2026-07-10", "500")
    at_october do
      keys(Api.declare(S.admin, july)).should eq(["urssaf.errors.transport.unavailable"])
      Urssaf::Filing.all.count.should eq(0)
      filing = Api.declare(S.admin, july).value!.filing || raise "sans déclaration"
      {filing.status, filing.remote_id}.should eq({"accepted", "DECL-101"})
    end
    S.urssaf.declarations.keys.should eq(["PDUO-URSSAF-732829320-20260701-1"])
  end

  it "numérote la tentative suivant un rejet, sans horodatage" do
    ready
    S.receipt("2026-07-10", "500")
    at_october do
      S.urssaf.rejection = "Compte suspendu"
      Api.declare(S.admin, july)
      S.urssaf.rejection = nil
      Api.declare(S.admin, july).value!
    end
    S.urssaf.declarations.keys.should eq(["PDUO-URSSAF-732829320-20260701-2"])
    Urssaf::Filing.all.first.try(&.attempts).should eq(1)
  end

  it "sérialise deux déclarations simultanées de la même période" do
    Urssaf::Transports.current = SlowUrssaf.new
    ready
    S.receipt("2026-07-10", "500")
    results = Channel(Array(String)).new
    at_october do
      2.times do
        spawn do
          outcome = Api.declare(S.admin, july)
          results.send(outcome.success? ? ["ok"] : keys(outcome))
        rescue ex
          results.send(["exception: #{ex.message}"])
        end
      end
      outcomes = [results.receive, results.receive]
      outcomes.sort_by!(&.first).should eq([["ok"], ["urssaf.controls.already_transmitted"]])
    end
    S.urssaf.declarations.size.should eq(1)
    Urssaf::Filing.all.count.should eq(1)
  end

  it "tient un verrou consultatif pendant la section sérialisée" do
    S.books
    held = Urssaf::Declarations.serialized("essai") do
      Marten::DB::Connection.default.open do |db|
        db.scalar("SELECT count(*) FROM pg_locks WHERE locktype = 'advisory' AND pid = pg_backend_pid()").as(Int64)
      end
    end
    held.should eq(1)
  end
end

describe "URSSAF — paiement et état chez l'URSSAF (D-URS-009)" do
  it "ne prélève pas des cotisations déjà payées dans l'espace URSSAF, et le signale" do
    ready
    S.declared_quarter
    S.sepa
    S.urssaf.external_paid["DECL-101"] = S::Books.d("105")
    keys(Api.pay(S.admin, july)).should eq(["urssaf.errors.payment.nothing_due"])
    Urssaf::Payment.all.count.should eq(0)
    S.urssaf.payments.should be_empty
    Api.anomalies(S.admin).map(&.code).should eq(["paid_elsewhere"])
    # Le relevé ne l'ouvre pas une seconde fois.
    Api.refresh(S.admin).value!.should eq(1)
  end

  it "ne prélève que ce que l'URSSAF attend encore" do
    ready
    S.declared_quarter
    S.sepa
    S.urssaf.external_paid["DECL-101"] = S::Books.d("40")
    Api.pay(S.admin, july).value!.amount.should eq(S::Books.d("65"))
    S.urssaf.orders.values.map(&.amount).should eq([S::Books.d("65")])
  end

  it "ouvre au relevé une anomalie pour un paiement fait hors de Partiduo" do
    ready
    S.declared_quarter
    S.urssaf.external_paid["DECL-101"] = S::Books.d("105")
    Api.refresh(S.admin).value!.should eq(1)
    anomaly = Api.anomalies(S.admin).first
    anomaly.code.should eq("paid_elsewhere")
    Hash(String, String).from_json(anomaly.detail).should eq({"urssaf" => "105.00", "partiduo" => "0.00"})
  end

  it "signale un paiement initié sans numéro de l'URSSAF" do
    ready
    S.declared_quarter
    S.sepa
    filing = Urssaf::Filing.all.first || raise "sans déclaration"
    Urssaf::Payment.create!(filing_id: filing.id, reference: "PDUO-PAY-732829320-20260701-1", remote_id: "",
      amount: S::Books.d("105"), sepa_rum: "RUM-732829320-1", status: "initiated")
    Api.refresh(S.admin).value!.should eq(1)
    Api.anomalies(S.admin).map(&.code).should eq(["payment_unknown"])
    Api.refresh(S.admin).value!.should eq(1)
  end
end

describe "URSSAF — permissions du module micro et du relevé (D-URS-010)" do
  it "exige les droits du module micro pour lire le chiffre d'affaires et noter la déclaration" do
    ready
    S.receipt("2026-07-10", "500")
    urssaf_only = S.admin([Api::READ, Api::TRANSMIT, Api::SETTINGS, Api::PAY])
    expect_raises(Partiduo::Api::Forbidden) { Api.periods(urssaf_only, 2026) }
    expect_raises(Partiduo::Api::Forbidden) { Api.estimate(urssaf_only, july) }
    at_october do
      expect_raises(Partiduo::Api::Forbidden) { Api.declare(urssaf_only, july) }
      reader = S.admin([Api::READ, Api::TRANSMIT, Micro::READ])
      expect_raises(Partiduo::Api::Forbidden) { Api.declare(reader, july) }
      S.urssaf.declarations.should be_empty
      Urssaf::Filing.all.count.should eq(0)
      # Le suivi reste lisible, sans les périodes du module.
      Api.overview(urssaf_only).to_declare.should be_empty
      Api.pending_count(urssaf_only).should eq(0)
      Api.pending_count(S.admin).should eq(1)
    end
  end

  it "réserve le relevé aux titulaires de la transmission" do
    ready
    expect_raises(Partiduo::Api::Forbidden) { Api.refresh(S.admin([Api::READ] + S::MICRO)) }
    Api.refresh(S.admin([Api::READ, Api::TRANSMIT])).value!.should eq(0)
  end
end

describe "URSSAF — détails neutres et contrôles (D-URS-011)" do
  it "garde un détail neutre, sans doublon quelle que soit la langue de celui qui relève" do
    ready
    S.declared_quarter
    S.urssaf.adjusted["DECL-101"] = S::Books.d("120")
    I18n.with_locale("fr") { Api.refresh(S.admin).value! }
    I18n.with_locale("nl") { Api.refresh(S.admin).value!.should eq(1) }
    detail = Api.anomalies(S.admin).first.detail
    Hash(String, String).from_json(detail).should eq({"before" => "105.00", "after" => "120.00"})
  end

  it "journalise l'éligibilité et les paiements en détails neutres" do
    ready
    S.declared_quarter
    S.sepa
    Api.check_eligibility(S.admin).value!
    Api.pay(S.admin, july).value!
    details = Api.events(S.admin, 3).map { |event| {event.action, event.detail} }
    details.size.should eq(3)
    details.to_h["paid"].should eq(%({"declaration":"DECL-101","amount":"105.00"}))
    details.to_h["eligibility"].should eq(%({"eligible":"true","periodicity":"quarterly"}))
    Api.payments(S.admin, 1).size.should eq(1)
  end

  it "refuse un chiffre d'affaires négatif" do
    ready
    settings = Urssaf::Settings.current!
    declaration = Micro::DeclarationView.new(july, S::Books.date("2026-09-30"), S::Books.date("2026-10-31"),
      [contribution("sale_bic", "-120.40"), contribution("service_bic", "300")], "due", nil, "", [] of String)
    controls = Urssaf::Declarations.controls(declaration, nil, settings, "quarterly")
    control = controls.find(&.key.==("urssaf.controls.negative_turnover")) || raise "contrôle absent"
    control.error?.should be_true
    control.params.should eq({"categories" => "sale_bic"})
  end
end
