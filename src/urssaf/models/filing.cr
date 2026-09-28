# SPDX-License-Identifier: AGPL-3.0-or-later

module Urssaf
  # Déclaration transmise à l'URSSAF pour une période (une ligne par
  # période, `starts_on`) : chiffre d'affaires déclaré par catégorie (JSON,
  # montants en chaîne décimale), numéro de la déclaration, cotisations dues
  # (JSON) et leur total, date limite de paiement ; `rejected` avec motif.
  # Intangible une fois acceptée (déclencheur). Interne.
  class Filing < Marten::Model
    field :id, :big_int, primary_key: true, auto: true
    field :starts_on, :date, unique: true
    field :ends_on, :date
    field :turnover, :text
    field :status, :string, max_size: 16
    field :remote_id, :string, max_size: 128, blank: true, default: ""
    field :contributions, :text, blank: true, default: "[]"
    field :contributions_total, :decimal, max_digits: 20, decimal_places: 2, default: BigDecimal.new(0)
    field :payment_due_on, :date, blank: true, null: true
    field :reason, :text, blank: true, default: ""
    field :transmitted_at, :date_time
    field :transmitted_by_id, :big_int, blank: true, null: true

    with_timestamp_fields
  end

  # Historique : mandat recueilli, notifié, révoqué ; éligibilité ;
  # estimation ; déclaration ; erreur du transport. Interne.
  class Event < Marten::Model
    field :id, :big_int, primary_key: true, auto: true
    field :action, :string, max_size: 16
    field :detail, :text, blank: true, default: ""
    field :user_id, :big_int, blank: true, null: true
    field :created_at, :date_time
  end
end
