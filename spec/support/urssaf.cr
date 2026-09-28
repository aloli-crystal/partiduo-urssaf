# SPDX-License-Identifier: AGPL-3.0-or-later

module Urssaf
  module SpecSupport
    alias Api = Urssaf::Api
    alias Micro = Partiduo::Api::Micro
    alias Books = PartiduoUi::Books

    SYSTEM = Partiduo::Api::Actor.system
    ALL    = [Api::READ, Api::TRANSMIT, Api::SETTINGS, Api::PAY]
    # IBAN de test (clé valide, banque fictive).
    IBAN = "FR76 3000 6000 0112 3456 7890 189"
    @@admin_id = 1_i64

    def self.urssaf : SimulatedUrssaf
      Transports.current.as(SimulatedUrssaf)
    end

    def self.admin(permissions : Array(String) = ALL) : Partiduo::Api::Actor
      Partiduo::Api::Actor.user(@@admin_id, permissions, level: 3)
    end

    # Micro-entreprise française (SIREN 732829320), exercice 2026, module
    # `micro` seul (configuration `micro` d'ADR-007), déclaration
    # trimestrielle, URSSAF active.
    def self.books(periodicity : String = "quarterly") : Nil
      PartiduoUi::Reference.provision("fr")
      PartiduoUi::Reference.fiscal_year(2026)
      @@admin_id = PartiduoUi::Accounts.create.user.id
      %w[ANALYTIC ACCOUNTING].each { |code| Partiduo::Api::Modules.deactivate(SYSTEM, code) }
      Partiduo::Api::Modules.activate(SYSTEM, "MICRO").value!
      Micro.load_defaults(SYSTEM)
      Micro.update_settings(SYSTEM, Micro::SettingsInput.new(periodicity: periodicity)).value!
      Partiduo::Api::Modules.activate(SYSTEM, CODE).value!
      nil
    end

    def self.connect : Nil
      Api.save_credentials(SYSTEM, Api::CredentialsInput.new(SimulatedUrssaf::CLIENT_ID, SimulatedUrssaf::CLIENT_SECRET)).value!
      nil
    end

    # Mandat recueilli puis notifié.
    def self.mandate : Nil
      Api.sign_mandate(admin, Api::MandateInput.new(Books.date("2026-01-05"), true)).value!
      Api.notify_mandate(admin).value!
      nil
    end

    # Mandat de prélèvement SEPA enregistré.
    def self.sepa : Api::SepaMandateView
      Api.register_sepa_mandate(admin, Api::SepaMandateInput.new(IBAN, "AGRIFRPP", "Jeanne Martin",
        Books.date("2026-01-05"), true)).value!
    end

    # Recette de 500 € au troisième trimestre, déclarée le 5 octobre.
    def self.declared_quarter : Api::PeriodView
      receipt("2026-07-10", "500")
      Partiduo::Config.travel_to(Time.utc(2026, 10, 5, 9, 0, 0)) do
        Api.declare(admin, Books.date("2026-07-01")).value!
      end
    end

    def self.receipt(day : String, amount : String, code : String = "SERVICE") : Micro::LineView
      nature = Micro.natures(SYSTEM).find { |item| item.code == code } || raise "nature #{code} absente"
      Micro.record_receipt(SYSTEM, Micro::ReceiptInput.new(date: Books.date(day), nature_id: nature.id,
        amount: Books.d(amount), method: "transfer", party_name: "Jeanne Martin")).value!
    end
  end
end

# Chaque exemple part d'une URSSAF simulée vierge.
Spec.before_each do
  Urssaf::Transports.current = Urssaf::SimulatedUrssaf.new
end
