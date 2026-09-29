# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

# DECISIONS D-MIC2-001, D-MIC2-004 : une période transmise à l'URSSAF est
# notée déclarée dans le module `micro`, qui la clôt (lignes intangibles,
# correction par contre-passation reportée sur la période suivante) ; une
# déclaration acceptée que le module ne reflète plus (non notée, chiffre
# d'affaires du registre différent) est signalée — contrôle de la période et
# anomalie « déclaration à corriger » —, sans rien bloquer.

private alias S = Urssaf::SpecSupport
private alias Api = Urssaf::Api
private alias Micro = Partiduo::Api::Micro

private def second_quarter(periods : Array(Api::PeriodView)) : Api::PeriodView
  periods.find(&.starts_on.==(S::Books.date("2026-04-01"))) || raise "trimestre absent"
end

# Déclaration acceptée par l'URSSAF, que le module `micro` n'a pas notée
# (note échouée, déclaration faite avant la mise en service…).
private def accepted_unmarked(turnover : String) : Urssaf::Filing
  Urssaf::Filing.create!(starts_on: S::Books.date("2026-04-01"), ends_on: S::Books.date("2026-06-30"),
    turnover: {"sale_bic" => "0", "service_bic" => turnover, "bnc" => "0"}.to_json, status: "accepted",
    remote_id: "DECL-900", transmitted_at: Time.utc)
end

describe "URSSAF — registres de la micro-entreprise et déclarations transmises (D-MIC2-001, D-MIC2-004)" do
  it "clôt la période transmise dans le module : lignes intangibles, contre-passation sur la période suivante" do
    S.books
    S.connect
    S.mandate
    S.declared_quarter
    line = Micro.receipts(S::SYSTEM).first
    line.locked.should be_true
    line.declared_on.should eq(S::Books.date("2026-10-05"))
    Partiduo::Config.travel_to(Time.utc(2026, 10, 6, 9, 0, 0)) do
      nature = Micro.natures(S::SYSTEM).find!(&.code.==("SERVICE"))
      input = Micro::ReceiptInput.new(date: S::Books.date("2026-07-10"), nature_id: nature.id, amount: S::Books.d("400"),
        method: "transfer")
      Micro.update_receipt(S.admin, line.id, input).errors.map(&.key).should eq(["micro.errors.line.change.declared_period"])
      Micro.delete_receipt(S.admin, line.id).errors.map(&.key).should eq(["micro.errors.line.change.declared_period"])
      Micro.reverse_receipt(S.admin, Micro::ReverseInput.new(line.id, S::Books.date("2026-10-06"))).value!
      periods = Api.periods(S.admin, 2026)
      periods.find!(&.starts_on.==(S::Books.date("2026-07-01"))).controls.map(&.key)
        .should eq(["urssaf.controls.already_transmitted"])
      periods.find!(&.starts_on.==(S::Books.date("2026-10-01"))).turnover["service_bic"].should eq(S::Books.d("-500"))
    end
    Urssaf::FollowUp.check_registers(S.admin)
    Api.anomalies(S.admin).should be_empty
  end

  it "signale une déclaration acceptée non notée dans le module, puis à corriger quand le registre change" do
    S.books
    line = S.receipt("2026-05-10", "500")
    accepted_unmarked("500")
    Partiduo::Config.travel_to(Time.utc(2026, 10, 5, 9, 0, 0)) do
      period = second_quarter(Api.periods(S.admin, 2026))
      period.controls.map(&.key).should eq(%w[urssaf.controls.already_transmitted urssaf.controls.not_marked])
      period.controls.none?(&.error?).should be_true

      # La période n'étant pas close dans le module, la ligne se modifie :
      # la déclaration transmise est alors à corriger.
      nature = Micro.natures(S::SYSTEM).find!(&.code.==("SERVICE"))
      Micro.update_receipt(S.admin, line.id, Micro::ReceiptInput.new(date: S::Books.date("2026-05-10"), nature_id: nature.id,
        amount: S::Books.d("450"), method: "transfer")).value!
      period = second_quarter(Api.periods(S.admin, 2026))
      changed = period.controls.find!(&.key.==("urssaf.controls.turnover_changed"))
      changed.params["declared"].should eq("500.00")
      changed.params["registered"].should eq("450.00")
      changed.severity.should eq("warning")

      Urssaf::FollowUp.check_registers(S.admin)
      Urssaf::FollowUp.check_registers(S.admin)
      anomalies = Api.anomalies(S.admin)
      anomalies.map(&.code).sort!.should eq(%w[not_marked turnover_changed])
      anomalies.each { |item| item.starts_on.should eq(S::Books.date("2026-04-01")) }
      fmt = PartiduoUi::Format.new("fr", "FR")
      detail = Urssaf::Ui::Present.anomaly(anomalies.find!(&.code.==("turnover_changed")), fmt).values["detail"].to_s
      detail.should contain("500,00")
      detail.should contain("450,00")
      detail.should_not contain("missing translation")
      Urssaf::Ui::Present.control_message(changed, fmt).should_not contain("missing translation")
    end
  end
end
