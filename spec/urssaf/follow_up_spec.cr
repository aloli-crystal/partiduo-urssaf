# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

# Suivi de la tierce déclaration (ADR-007 D7) : accusé en pièce jointe,
# mandats SEPA, télépaiement, relevé auprès de l'URSSAF (paiements,
# régularisations, anomalies, mandat révoqué depuis l'espace URSSAF), vue
# d'ensemble et compteur.

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

describe "URSSAF — suivi, paiements et anomalies (ADR-007 D7)" do
  it "garde l'accusé de l'URSSAF en pièce jointe, sinon un accusé établi d'après sa réponse" do
    ready
    S.declared_quarter
    receipt = Api.receipt(S.admin, july)
    {receipt.filename, receipt.content_type}.should eq({"accuse-DECL-101.pdf", "application/pdf"})
    String.new(receipt.content).should start_with("%PDF-")

    S.urssaf.pdf_receipt = false
    S.receipt("2026-04-10", "100")
    Partiduo::Config.travel_to(Time.utc(2026, 10, 5, 9, 0, 0)) do
      Api.declare(S.admin, S::Books.date("2026-04-01")).value!
    end
    text = Api.receipt(S.admin, S::Books.date("2026-04-01"))
    text.content_type.should eq("text/plain")
    String.new(text.content).should contain("DECL-102")
    String.new(text.content).should contain("732829320")
    expect_raises(Partiduo::Api::NotFound) { Api.receipt(S.admin, S::Books.date("2026-01-01")) }
  end

  it "enregistre un mandat SEPA sans garder l'IBAN, puis paie le reste dû une seule fois" do
    ready
    period = S.declared_quarter
    period.payable?.should be_true
    keys(Api.pay(S.admin, july)).should eq(["urssaf.errors.payment.no_sepa"])

    invalid = Api.register_sepa_mandate(S.admin, Api::SepaMandateInput.new("FR76 3000 6000 0112 3456 7890 188", "XX",
      "", S::Books.date("2026-01-05"), false))
    keys(invalid).should eq(%w[urssaf.errors.sepa.iban urssaf.errors.sepa.bic urssaf.errors.sepa.holder urssaf.errors.sepa.accept])
    mandate = S.sepa
    {mandate.rum, mandate.iban_masked, mandate.status}.should eq({"RUM-732829320-1", "FR76 **** **** 0189", "active"})
    Urssaf::SepaMandateRow.all.map(&.iban_masked).should eq(["FR76 **** **** 0189"])

    payment = Api.pay(S.admin, july).value!
    {payment.status, payment.amount, payment.sepa_rum}.should eq({"initiated", S::Books.d("105"), "RUM-732829320-1"})
    keys(Api.pay(S.admin, july)).should eq(["urssaf.errors.payment.nothing_due"])
    keys(Api.pay(S.admin, S::Books.date("2026-04-01"))).should eq(["urssaf.errors.payment.not_declared"])

    Api.refresh(S.admin).value!.should eq(0)
    filing = Api.periods(S.admin, 2026).find!(&.starts_on.==(july)).filing || raise "sans déclaration"
    {filing.paid_total, filing.remaining}.should eq({S::Books.d("105"), S::Books.d("0")})
    Api.payments(S.admin).map(&.status).should eq(["done"])
    Api.events(S.admin).map(&.action).first(3).should eq(%w[refreshed payment_done paid])
  end

  it "ouvre une anomalie pour un paiement rejeté et permet de payer de nouveau" do
    ready
    S.declared_quarter
    S.sepa
    Api.pay(S.admin, july).value!
    S.urssaf.payment_outcome = "rejected"
    Api.refresh(S.admin).value!.should eq(1)
    anomaly = Api.anomalies(S.admin).first
    {anomaly.code, anomaly.detail, anomaly.starts_on}.should eq({"payment_rejected", "Provision insuffisante", july})
    Api.pay(S.admin, july).value!.amount.should eq(S::Books.d("105"))
    Api.resolve_anomaly(S.admin, anomaly.id).value!
    Api.anomalies(S.admin).should be_empty
    Api.anomalies(S.admin, open_only: false).size.should eq(1)
    keys(Api.resolve_anomaly(S.admin, anomaly.id)).should eq(["urssaf.errors.anomaly"])
  end

  it "relève les régularisations, les anomalies de l'URSSAF et le mandat révoqué depuis l'espace URSSAF" do
    ready
    S.declared_quarter
    S.urssaf.adjusted["DECL-101"] = S::Books.d("120")
    S.urssaf.reported["DECL-101"] = ["Chiffre d'affaires incohérent avec l'activité"]
    S.urssaf.mandates.clear
    Api.refresh(S.admin).value!.should eq(3)
    Api.anomalies(S.admin).map(&.code).sort!.should eq(%w[contributions_changed mandate_revoked urssaf])
    Api.settings(S.admin).mandate_status.should eq("revoked")
    # Un second relevé n'ouvre pas deux fois la même anomalie.
    Api.refresh(S.admin).value!.should eq(3)
    Api.events(S.admin).map(&.action).should contain("remote_revoked")
  end

  it "présente la vue d'ensemble et le compteur : à déclarer, à payer, anomalies" do
    ready
    S.sepa
    S.receipt("2026-04-10", "200")
    today = S::Books.date("2026-10-05")
    Partiduo::Config.travel_to(Time.utc(2026, 10, 5, 9, 0, 0)) do
      S.receipt("2026-07-10", "500")
      Api.declare(S.admin, july).value!
      view = Api.overview(S.admin, today)
      view.to_declare.map(&.starts_on).should eq([S::Books.date("2026-04-01")])
      view.to_pay.map(&.starts_on).should eq([july])
      {view.contributions_due, view.paid, view.remaining}.should eq({S::Books.d("105"), S::Books.d("0"), S::Books.d("105")})
      view.sepa_mandate.try(&.rum).should eq("RUM-732829320-1")
      Api.pending_count(S.admin, today).should eq(2)
    end
  end

  it "révoque un mandat SEPA ; exige la permission de payer" do
    ready
    mandate = S.sepa
    expect_raises(Partiduo::Api::Forbidden) { Api.pay(S.admin([Api::READ, Api::TRANSMIT]), july) }
    expect_raises(Partiduo::Api::Forbidden) do
      Api.revoke_sepa_mandate(S.admin([Api::READ, Api::TRANSMIT, Api::SETTINGS]), mandate.rum)
    end
    Api.revoke_sepa_mandate(S.admin, mandate.rum).value!.status.should eq("revoked")
    keys(Api.revoke_sepa_mandate(S.admin, mandate.rum)).should eq(["urssaf.errors.sepa.unknown"])
    S.urssaf.sepa.should be_empty
  end
end

describe Urssaf::Iban do
  it "contrôle la clé, normalise et masque" do
    Urssaf::Iban.valid?("fr76 3000 6000 0112 3456 7890 189").should be_true
    Urssaf::Iban.valid?("FR7630006000011234567890188").should be_false
    Urssaf::Iban.valid?("BE68539007547034").should be_true
    Urssaf::Iban.mask("BE68539007547034").should eq("BE68 **** **** 7034")
    Urssaf::Iban.valid_bic?("").should be_true
    Urssaf::Iban.valid_bic?("AGRIFRPP882").should be_true
    Urssaf::Iban.valid_bic?("AGRI").should be_false
  end
end

private class FakeTokenHttp < Urssaf::OAuth2::Http
  getter calls = [] of {String, HTTP::Headers, String}
  property status = 200

  def post(url : String, headers : HTTP::Headers, body : String) : Response
    calls << {url, headers, body}
    Response.new(status, %({"access_token":"jeton-#{calls.size}","token_type":"Bearer","expires_in":3600}))
  end
end

describe Urssaf::OAuth2 do
  it "demande un jeton client credentials, le garde jusqu'à son échéance, l'oublie sur demande" do
    http = FakeTokenHttp.new
    oauth = Urssaf::OAuth2.new("https://jeton.example/oauth/token", "td-ae", http)
    credentials = Urssaf::Credentials.new("appli", "s3cret", "sandbox")
    now = Time.utc(2026, 9, 28, 12, 0, 0)
    oauth.token(credentials, now).should eq("jeton-1")
    oauth.token(credentials, now + 30.minutes).should eq("jeton-1")
    oauth.token(credentials, now + 59.minutes + 30.seconds).should eq("jeton-2")
    oauth.forget(credentials)
    oauth.token(credentials, now).should eq("jeton-3")
    url, headers, body = http.calls.first
    url.should eq("https://jeton.example/oauth/token")
    body.should eq("grant_type=client_credentials&scope=td-ae")
    headers["Authorization"].should eq("Basic #{Base64.strict_encode("appli:s3cret")}")
  end

  it "traduit un refus en erreur d'identifiants, sans le secret" do
    http = FakeTokenHttp.new
    http.status = 401
    oauth = Urssaf::OAuth2.new("https://jeton.example/oauth/token", http: http)
    error = expect_raises(Urssaf::TransportError) { oauth.token(Urssaf::Credentials.new("appli", "s3cret", "sandbox")) }
    error.key.should eq("urssaf.errors.transport.credentials")
    error.message.to_s.should_not contain("s3cret")
  end
end
