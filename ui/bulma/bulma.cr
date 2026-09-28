# SPDX-License-Identifier: AGPL-3.0-or-later

# Interface Bulma de l'extension URSSAF (ADR-005 D4, ADR-007 D7) : écran
# « Déclaration URSSAF en ligne » (périodes de l'année, chiffre d'affaires
# du module `micro`, estimation, déclaration, cotisations dues, historique),
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
    end
  end
end

# Toutes les routes exigent au moins `urssaf.declaration.read` ; le contrat
# vérifie ensuite la permission propre à chaque commande.
PartiduoUi::Extensions.mount Urssaf::CODE, Urssaf::Ui::ROUTES, permission: Urssaf::Api::READ
