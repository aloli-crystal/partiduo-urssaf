# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

# Écran URSSAF en ligne : extension inactive, commandes refusées selon les
# permissions, IBAN jamais réaffiché (ADR-005 D4, ADR-007 D7, D-URS-003).

private alias S = Urssaf::SpecSupport

describe "Écran URSSAF en ligne — accès et permissions" do
  it "répond 404 quand l'extension est inactive et la retire du menu" do
    S.books
    browser = PartiduoUi::Accounts.signed_in
    browser.get("/ext/URSSAF/").status.should eq(200)
    Partiduo::Api::Modules.deactivate(S::SYSTEM, Urssaf::CODE).value!
    browser.get("/ext/URSSAF/").status.should eq(404)
    browser.post("/ext/URSSAF/refresh").status.should eq(404)
    browser.get("/").html.should_not contain(%(href="/ext/URSSAF/"))
  end

  it "refuse au simple lecteur de traiter une anomalie et de gérer le mandat SEPA ; montre le suivi sans boutons" do
    S.books
    S.connect
    S.mandate
    S.declared_quarter
    profile = PartiduoUi::Accounts.profile("Lecteur", [Urssaf::Api::READ, "micro.register.read"])
    PartiduoUi::Accounts.create("bob@example.com", profile: nil, profile_id: profile)
    reader = PartiduoUi::Accounts.signed_in("bob@example.com")
    reader.post("/ext/URSSAF/anomaly/resolve", {"id" => "1"}).status.should eq(403)
    reader.post("/ext/URSSAF/sepa/revoke", {"rum" => "RUM-732829320-1"}).status.should eq(403)
    page = reader.get("/ext/URSSAF/?year=2026").html
    page.should contain(%(data-urssaf-period="2026-07-01"))
    page.should_not contain("data-urssaf-sepa-form")
    page.should_not contain("data-urssaf-pay>")
  end

  it "ne réaffiche jamais l'IBAN saisi, même valide, quand le mandat SEPA est refusé" do
    S.books
    S.connect
    S.mandate
    browser = PartiduoUi::Accounts.signed_in
    # IBAN valide, mais autorisation du prélèvement non cochée.
    refused = browser.follow(browser.post("/ext/URSSAF/sepa/register", {"iban" => S::IBAN, "bic" => "AGRIFRPP",
                                                                        "holder" => "Jeanne Martin", "signed_on" => "2026-01-05"})).html
    refused.should_not contain("3000 6000 0112")
    refused.should_not contain("30006000011234567890")
    S.urssaf.sepa.should be_empty
  end
end

describe "Écran URSSAF en ligne — textes traduits et données bornées (D-URS-011)" do
  it "borne l'année demandée et réserve le relevé aux titulaires de la transmission" do
    S.books
    S.connect
    browser = PartiduoUi::Accounts.signed_in
    far = browser.get("/ext/URSSAF/?year=99999")
    far.status.should eq(200)
    far.html.should contain("?year=#{Partiduo::Config.today.year}")
    browser.get("/ext/URSSAF/?year=-5").status.should eq(200)
    browser.get("/ext/URSSAF/").html.should contain("data-urssaf-refresh")
    profile = PartiduoUi::Accounts.profile("Lecteur", [Urssaf::Api::READ, "micro.register.read"])
    PartiduoUi::Accounts.create("bob@example.com", profile: nil, profile_id: profile)
    reader = PartiduoUi::Accounts.signed_in("bob@example.com")
    reader.get("/ext/URSSAF/").html.should_not contain("data-urssaf-refresh")
    reader.post("/ext/URSSAF/refresh").status.should eq(403)
  end

  it "traduit les détails neutres des anomalies et de l'historique dans la langue du lecteur" do
    anomaly = Urssaf::Api::AnomalyView.new(1_i64, "contributions_changed", %({"before":"105.00","after":"120.00"}),
      nil, Time.utc, nil)
    I18n.with_locale("fr") do
      Urssaf::Ui::Present.anomaly(anomaly, PartiduoUi::Format.new("fr")).values["detail"].to_s
        .should eq("105,00 à l'accusé, 120,00 selon l'URSSAF")
    end
    I18n.with_locale("en") do
      Urssaf::Ui::Present.anomaly(anomaly, PartiduoUi::Format.new("en")).values["detail"].to_s.should contain("according to the URSSAF")
    end
    event = Urssaf::Api::EventView.new("eligibility", %({"eligible":"true","periodicity":"monthly"}), nil, Time.utc)
    I18n.with_locale("nl") do
      Urssaf::Ui::Present.event(event, PartiduoUi::Format.new("nl")).values["detail"].should eq("In aanmerking: ja; periodiciteit: Maandelijks")
    end
    # Motif de l'URSSAF, texte libre : rendu tel quel.
    plain = Urssaf::Api::AnomalyView.new(2_i64, "urssaf", "{Activité à préciser", nil, Time.utc, nil)
    Urssaf::Ui::Present.anomaly(plain, PartiduoUi::Format.new("fr")).values["detail"].should eq("{Activité à préciser")
  end

  it "met en forme l'estimation selon la langue" do
    I18n.with_locale("en") do
      I18n.t("urssaf_ui.flash.estimate_line", category: "Services", amount: "105.00").should eq("Services: 105.00")
      I18n.t("urssaf_ui.period_range", from: "1", to: "2").should eq("1 – 2")
    end
    I18n.with_locale("fr") do
      I18n.t("urssaf_ui.flash.estimate_line", category: "Services", amount: "105,00").should eq("Services : 105,00")
    end
  end
end
