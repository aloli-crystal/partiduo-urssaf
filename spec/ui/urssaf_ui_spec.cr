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
  end
end
