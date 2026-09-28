# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

private alias S = Urssaf::SpecSupport

describe "Écran URSSAF en ligne sous /ext/URSSAF/ (ADR-005 D4, ADR-007 D7)" do
  it "est montée sous le code de l'extension, avec la permission de lecture" do
    Marten.routes.reverse("urssaf:index").should eq("/ext/URSSAF/")
    mount = PartiduoUi::Extensions["URSSAF"]? || raise("interface non montée")
    mount.permission.should eq(Urssaf::Api::READ)
  end

  it "enregistre les identifiants, recueille et notifie le mandat, puis déclare un trimestre" do
    S.books
    browser = PartiduoUi::Accounts.signed_in
    settings = browser.get("/ext/URSSAF/settings").html
    settings.should contain(%(data-urssaf-env="sandbox"))
    settings.should contain("data-urssaf-sign")
    saved = browser.post("/ext/URSSAF/settings", {"env" => "sandbox", "client_id" => Urssaf::SimulatedUrssaf::CLIENT_ID,
                                                  "client_secret" => Urssaf::SimulatedUrssaf::CLIENT_SECRET})
    browser.follow(saved).html.should contain("Identifiants enregistrés.")
    refused = browser.post("/ext/URSSAF/mandate/sign", {"signed_on" => "2026-01-05"})
    browser.follow(refused).html.should contain("Le micro-entrepreneur doit accepter les termes du mandat.")
    browser.follow(browser.post("/ext/URSSAF/mandate/sign", {"signed_on" => "2026-01-05", "accepted" => "1"})).html
      .should contain("Mandat recueilli.")
    notified = browser.follow(browser.post("/ext/URSSAF/mandate/notify")).html
    notified.should contain("Mandat notifié à l'URSSAF.")
    notified.should contain("MDT-732829320-1")

    S.receipt("2026-07-10", "800")
    Partiduo::Config.travel_to(Time.utc(2026, 10, 5, 9, 0, 0)) do
      index = browser.get("/ext/URSSAF/?year=2026").html
      index.should contain(%(data-urssaf-mandate="notified"))
      index.should contain(%(data-urssaf-period="2026-07-01"))
      index.should contain("data-urssaf-declare")
      declared = browser.post("/ext/URSSAF/declare", {"starts_on" => "2026-07-01"})
      page = browser.follow(declared).html
      page.should contain("Déclaration acceptée par l'URSSAF.")
      page.should contain(%(data-urssaf-status="accepted"))
      page.should contain("DECL-101")
    end
  end

  it "refuse les paramètres sans le droit de les gérer" do
    S.books
    profile = PartiduoUi::Accounts.profile("Lecteur", [Urssaf::Api::READ, "micro.register.read"])
    PartiduoUi::Accounts.create("bob@example.com", profile: nil, profile_id: profile)
    reader = PartiduoUi::Accounts.signed_in("bob@example.com")
    reader.get("/ext/URSSAF/").status.should eq(200)
    reader.get("/ext/URSSAF/settings").status.should eq(403)
    reader.post("/ext/URSSAF/declare", {"starts_on" => "2026-07-01"}).status.should eq(403)
    reader.post("/ext/URSSAF/pay", {"starts_on" => "2026-07-01"}).status.should eq(403)
    reader.post("/ext/URSSAF/sepa/register", {"iban" => S::IBAN}).status.should eq(403)
  end
end

describe "Écran URSSAF en ligne — mode simplifié, paiement, suivi (ADR-007 D3, D7)" do
  it "figure dans le menu du mode simplifié, après l'aide URSSAF, avec son compteur" do
    PartiduoUi::SimpleMode::MENU.map(&.code).should contain("URSSAF_ONLINE")
    codes = PartiduoUi::SimpleMode::MENU.map(&.code)
    codes.index("URSSAF_ONLINE").should eq((codes.index("MICRO_URSSAF") || raise "aide URSSAF absente") + 1)
    Urssaf::Ui.add_simple_entry(PartiduoUi::SimpleMode::MENU)
    PartiduoUi::SimpleMode::MENU.count(&.code.==("URSSAF_ONLINE")).should eq(1)
    S.books
    S.receipt("2026-04-10", "100")
    browser = PartiduoUi::Accounts.signed_in
    Partiduo::Config.travel_to(Time.utc(2026, 10, 5, 9, 0, 0)) do
      dashboard = browser.get("/").html
      dashboard.should contain(%(href="/ext/URSSAF/"))
      dashboard.should contain("2 éléments URSSAF à traiter")
    end
  end

  it "déclare, télécharge l'accusé, enregistre le mandat SEPA, paie, relève le suivi et traite une anomalie" do
    S.books
    S.connect
    S.mandate
    S.receipt("2026-07-10", "500")
    browser = PartiduoUi::Accounts.signed_in
    Partiduo::Config.travel_to(Time.utc(2026, 10, 5, 9, 0, 0)) do
      browser.follow(browser.post("/ext/URSSAF/declare", {"starts_on" => "2026-07-01"}))
      page = browser.get("/ext/URSSAF/?year=2026").html
      page.should contain("data-urssaf-receipt")
      page.should contain("data-urssaf-sepa-form")
      page.should_not contain("data-urssaf-pay>")
      page.should contain("gardez la main")

      receipt = browser.get("/ext/URSSAF/receipt?starts_on=2026-07-01")
      receipt.status.should eq(200)
      receipt.headers["Content-Disposition"].should contain("accuse-DECL-101.pdf")

      refused = browser.follow(browser.post("/ext/URSSAF/sepa/register", {"iban" => "FR00 1234", "holder" => "Jeanne Martin"})).html
      refused.should contain("IBAN invalide.")
      refused.should_not contain("FR00 1234")
      registered = browser.follow(browser.post("/ext/URSSAF/sepa/register", {"iban" => S::IBAN, "bic" => "AGRIFRPP",
                                                                             "holder" => "Jeanne Martin", "signed_on" => "2026-10-01",
                                                                             "accepted" => "1"})).html
      registered.should contain("Mandat SEPA enregistré.")
      registered.should contain("FR76 **** **** 0189")
      registered.should_not contain("30006000011234567890")
      registered.should contain("data-urssaf-pay>")

      paid = browser.follow(browser.post("/ext/URSSAF/pay", {"starts_on" => "2026-07-01"})).html
      paid.should contain(%(data-urssaf-payment="initiated"))
      S.urssaf.payment_outcome = "rejected"
      refreshed = browser.follow(browser.post("/ext/URSSAF/refresh")).html
      refreshed.should contain("1 anomalie à traiter")
      refreshed.should contain(%(data-urssaf-anomaly="payment_rejected"))
      id = Urssaf::Api.anomalies(S.admin).first.id
      resolved = browser.follow(browser.post("/ext/URSSAF/anomaly/resolve", {"id" => id.to_s})).html
      resolved.should contain("Anomalie notée traitée.")
      resolved.should_not contain(%(data-urssaf-anomaly="payment_rejected"))
    end
  end
end
