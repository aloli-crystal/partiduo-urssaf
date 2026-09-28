# SPDX-License-Identifier: AGPL-3.0-or-later

# Interface Bulma de l'extension URSSAF (ADR-005 D4, ADR-007 D7) : écran
# « Déclaration URSSAF en ligne » (suivi : cotisations dues, payées, reste,
# anomalies ; périodes de l'année, chiffre d'affaires du module `micro`,
# estimation, déclaration, accusé, télépaiement SEPA et mandat SEPA ;
# paiements ; historique), entrée du menu du mode simplifié et compteur,
# paramètres (identifiants de l'API, mandat recueilli, notifié, révoqué).
# Montée par `partiduo-ui-bulma` sous `/ext/URSSAF/` (ADR-003 D3). La
# distribution la requiert après l'interface :
#
# ```
# require "partiduo-ui-bulma/partiduo_ui"
# require "partiduo-urssaf"
# require "partiduo-urssaf/ui/bulma"
# ```
#
# puis ajoute `Urssaf::Ui::INSTALLED_APPS` à ses applications Marten. Ce
# dossier ne parle au métier que par `Urssaf::Api` et `Partiduo::Api`.
require "../../src/partiduo-urssaf"

require "./presenters"
require "./handlers/**"

module Urssaf
  module Ui
    class App < Marten::App
      label "urssaf_ui"
    end

    INSTALLED_APPS = [Urssaf::Ui::App] of Marten::Apps::Config.class

    # Routes servies sous `/ext/URSSAF/`, nommées `urssaf:<nom>`.
    ROUTES = Marten::Routing::Map.draw do
      path "/", Urssaf::Ui::IndexHandler, name: "index"
      path "/estimate", Urssaf::Ui::EstimateHandler, name: "estimate"
      path "/declare", Urssaf::Ui::DeclareHandler, name: "declare"
      path "/settings", Urssaf::Ui::SettingsHandler, name: "settings"
      path "/settings/clear", Urssaf::Ui::ClearCredentialsHandler, name: "clear_credentials"
      path "/mandate/sign", Urssaf::Ui::SignMandateHandler, name: "sign_mandate"
      path "/mandate/notify", Urssaf::Ui::NotifyMandateHandler, name: "notify_mandate"
      path "/mandate/revoke", Urssaf::Ui::RevokeMandateHandler, name: "revoke_mandate"
      path "/mandate/eligibility", Urssaf::Ui::EligibilityHandler, name: "eligibility"
      path "/pay", Urssaf::Ui::PayHandler, name: "pay"
      path "/refresh", Urssaf::Ui::RefreshHandler, name: "refresh"
      path "/receipt", Urssaf::Ui::ReceiptHandler, name: "receipt"
      path "/anomaly/resolve", Urssaf::Ui::ResolveAnomalyHandler, name: "resolve_anomaly"
      path "/sepa/register", Urssaf::Ui::RegisterSepaHandler, name: "register_sepa"
      path "/sepa/revoke", Urssaf::Ui::RevokeSepaHandler, name: "revoke_sepa"
    end

    # Entrée du menu réduit du mode simplifié de la micro-entreprise
    # (ADR-007 D3), juste après l'aide URSSAF du module : visible seulement
    # si l'extension est active et l'utilisateur autorisé (l'entrée
    # `URSSAF_ONLINE` du manifeste doit figurer dans son menu).
    SIMPLE_ENTRY = PartiduoUi::SimpleMode::Entry.new("URSSAF_ONLINE", "urssaf_ui.simple_menu")

    def self.add_simple_entry(menu : Array(PartiduoUi::SimpleMode::Entry)) : Nil
      return if menu.any?(&.code.==(SIMPLE_ENTRY.code))
      after = menu.index(&.code.==("MICRO_URSSAF")) || menu.size - 1
      menu.insert(after + 1, SIMPLE_ENTRY)
      nil
    end
  end
end

Urssaf::Ui.add_simple_entry(PartiduoUi::SimpleMode::MENU)

# Compteur du menu et « À traiter » du tableau de bord : périodes à
# déclarer, cotisations à payer, anomalies ouvertes.
PartiduoUi::Extensions.counter("URSSAF_ONLINE", route: "urssaf:index", todo: "urssaf_ui.todo", tone: "warn") do |actor|
  Urssaf::Api.pending_count(actor)
end

# Toutes les routes exigent au moins `urssaf.declaration.read` ; le contrat
# vérifie ensuite la permission propre à chaque commande.
PartiduoUi::Extensions.mount Urssaf::CODE, Urssaf::Ui::ROUTES, permission: Urssaf::Api::READ
