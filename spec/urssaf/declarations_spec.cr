# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

# Tierce déclaration URSSAF (ADR-007 D7) : mandat recueilli, notifié et
# révocable ; éligibilité et périodicité ; chiffre d'affaires du module
# `micro` par catégorie, arrondi à l'euro ; estimation ; déclaration
# idempotente, accusé et cotisations dues, notée dans le module ; rejet
# conservé ; contrôles ; permissions ; secret chiffré.

private alias S = Urssaf::SpecSupport
private alias Api = Urssaf::Api
private alias Micro = Partiduo::Api::Micro

private def keys(result) : Array(String)
  result.errors.map(&.key)
end

private def third_quarter(periods : Array(Api::PeriodView)) : Api::PeriodView
  periods.find(&.starts_on.==(S::Books.date("2026-07-01"))) || raise "trimestre absent"
end

private def filing_of(period : Api::PeriodView) : Api::FilingView
  period.filing || raise "période sans déclaration"
end

describe "URSSAF — tierce déclaration (ADR-007 D7)" do
  it "recueille, notifie et révoque le mandat ; relève l'éligibilité et la périodicité" do
    S.books
    S.connect
    keys(Api.notify_mandate(S.admin)).should eq(["urssaf.errors.mandate.not_signed"])
    keys(Api.sign_mandate(S.admin, Api::MandateInput.new(S::Books.date("2026-01-05"), false)))
      .should eq(["urssaf.errors.mandate.accept"])
    signed = Api.sign_mandate(S.admin, Api::MandateInput.new(S::Books.date("2026-01-05"), true)).value!
    signed.mandate_status.should eq("signed")
    notified = Api.notify_mandate(S.admin).value!
    {notified.mandate_status, notified.mandate_ref, notified.eligible, notified.periodicity}
      .should eq({"notified", "MDT-732829320-1", true, "quarterly"})
    keys(Api.sign_mandate(S.admin, Api::MandateInput.new(S::Books.date("2026-01-05"), true)))
      .should eq(["urssaf.errors.mandate.active"])
    revoked = Api.revoke_mandate(S.admin).value!
    revoked.mandate_status.should eq("revoked")
    S.urssaf.mandates.should be_empty
    Api.events(S.admin).map(&.action).should eq(%w[revoked notified signed])
  end

  it "déclare le chiffre d'affaires du module, arrondi à l'euro, et le note déclaré dans le module" do
    S.books
    S.connect
    S.mandate
    S.receipt("2026-07-10", "1200.40", "SERVICE")
    S.receipt("2026-08-20", "300.50", "SALE")
    period = third_quarter(Api.periods(S.admin, 2026, S::Books.date("2026-10-05")))
    period.turnover.should eq({"sale_bic" => S::Books.d("301"), "service_bic" => S::Books.d("1200"), "bnc" => S::Books.d("0")})
    period.controls.map(&.key).should be_empty

    estimate = Api.estimate(S.admin, period.starts_on).value!
    estimate.map { |item| {item.category, item.amount} }.should eq([{"sale_bic", S::Books.d("36.12")}, {"service_bic", S::Books.d("252")}])

    Partiduo::Config.travel_to(Time.utc(2026, 10, 5, 9, 0, 0)) do
      declared = Api.declare(S.admin, period.starts_on).value!
      filing = filing_of(declared)
      {filing.status, filing.remote_id, filing.contributions_total}.should eq({"accepted", "DECL-101", S::Books.d("288.12")})
      filing.payment_due_on.should eq(S::Books.date("2026-10-31"))
      declared.micro_status.should eq("declared")
      micro = Micro.declarations(S::SYSTEM, 2026).find!(&.starts_on.==(period.starts_on))
      {micro.status, micro.reference}.should eq({"declared", "DECL-101"})
      keys(Api.declare(S.admin, period.starts_on)).should eq(["urssaf.controls.already_transmitted"])
      S.urssaf.declarations.size.should eq(1)
    end
  end

  it "refuse une période en cours, sans mandat, sans identifiants, non éligible ou de périodicité différente" do
    S.books
    S.receipt("2026-07-10", "500")
    july = S::Books.date("2026-07-01")
    keys(Api.declare(S.admin, july)).should contain("urssaf.controls.mandate_missing")
    Partiduo::Config.travel_to(Time.utc(2026, 8, 15, 9, 0, 0)) do
      keys(Api.declare(S.admin, july)).should contain("urssaf.controls.period_open")
    end
    Partiduo::Config.travel_to(Time.utc(2026, 10, 5, 9, 0, 0)) do
      keys(Api.estimate(S.admin, july)).should eq(["urssaf.controls.no_credentials"])
      Urssaf::Transports.current = Urssaf::SimulatedUrssaf.new(periodicity: "monthly")
      S.connect
      S.mandate
      keys(Api.declare(S.admin, july)).should eq(["urssaf.controls.periodicity_mismatch"])
      Urssaf::Transports.current = nil
      keys(Api.declare(S.admin, july)).should eq(["urssaf.controls.periodicity_mismatch"])
    end
  end

  it "garde le rejet de l'URSSAF avec son motif, puis accepte une nouvelle déclaration" do
    S.books
    S.connect
    S.mandate
    S.receipt("2026-07-10", "500")
    july = S::Books.date("2026-07-01")
    Partiduo::Config.travel_to(Time.utc(2026, 10, 5, 9, 0, 0)) do
      S.urssaf.rejection = "Compte suspendu"
      rejected = Api.declare(S.admin, july)
      keys(rejected).should eq(["urssaf.errors.transport.rejected"])
      filing = filing_of(third_quarter(Api.periods(S.admin, 2026)))
      {filing.status, filing.reason}.should eq({"rejected", "Compte suspendu"})
      S.urssaf.rejection = nil
      filing_of(Api.declare(S.admin, july).value!).status.should eq("accepted")
    end
  end

  it "chiffre le secret, ne le rend jamais, le vérifie auprès de l'URSSAF ; exige ses permissions" do
    S.books
    keys(Api.save_credentials(S.admin, Api::CredentialsInput.new(Urssaf::SimulatedUrssaf::CLIENT_ID, "faux")))
      .should eq(["urssaf.errors.transport.credentials"])
    S.connect
    row = Urssaf::Settings.current || raise "paramètres absents"
    row.client_secret.to_s.should start_with("v1:")
    Api.settings(S.admin).secret_stored.should be_true
    Api.settings(S.admin([Api::READ])).client_id.should eq("")
    expect_raises(Partiduo::Api::Forbidden) { Api.declare(S.admin([Api::READ]), S::Books.date("2026-07-01")) }
    expect_raises(Partiduo::Api::Forbidden) { Api.notify_mandate(S.admin([Api::READ, Api::TRANSMIT])) }
    Api.clear_credentials(S.admin).secret_stored.should be_false
  end

  it "garde une déclaration acceptée intangible (base)" do
    S.books
    S.connect
    S.mandate
    S.receipt("2026-07-10", "500")
    Partiduo::Config.travel_to(Time.utc(2026, 10, 5, 9, 0, 0)) do
      Api.declare(S.admin, S::Books.date("2026-07-01")).value!
    end
    expect_raises(Exception, /intangible/) { Urssaf::Filing.all.first.try(&.delete) }
  end
end
