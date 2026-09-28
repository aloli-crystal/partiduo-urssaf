# SPDX-License-Identifier: AGPL-3.0-or-later

module Urssaf
  # Télépaiement SEPA des cotisations d'une déclaration acceptée : montant,
  # mandat SEPA (RUM), numéro chez l'URSSAF, état (`initiated`, `done`,
  # `rejected` avec motif). Interne.
  class Payment < Marten::Model
    field :id, :big_int, primary_key: true, auto: true
    field :filing_id, :big_int
    field :reference, :string, max_size: 128, unique: true
    field :remote_id, :string, max_size: 128, blank: true, default: ""
    field :amount, :decimal, max_digits: 20, decimal_places: 2
    field :sepa_rum, :string, max_size: 64
    field :status, :string, max_size: 16
    field :reason, :text, blank: true, default: ""
    field :initiated_by_id, :big_int, blank: true, null: true

    with_timestamp_fields
  end

  # Anomalie du suivi : rejet d'une déclaration, anomalie signalée par
  # l'URSSAF, cotisations changées après l'accusé, paiement rejeté, mandat
  # révoqué depuis l'espace URSSAF. Ouverte jusqu'à ce qu'on la note
  # traitée. Interne.
  class Anomaly < Marten::Model
    field :id, :big_int, primary_key: true, auto: true
    field :filing_id, :big_int, blank: true, null: true
    field :code, :string, max_size: 32
    field :detail, :text, blank: true, default: ""
    field :resolved_at, :date_time, blank: true, null: true
    field :resolved_by_id, :big_int, blank: true, null: true

    with_timestamp_fields
  end

  # Mandat de prélèvement SEPA enregistré à l'URSSAF (copie locale : RUM,
  # IBAN masqué, titulaire, état). L'IBAN complet n'est jamais conservé.
  # Interne.
  class SepaMandateRow < Marten::Model
    db_table :urssaf_sepa_mandate

    field :id, :big_int, primary_key: true, auto: true
    field :rum, :string, max_size: 64, unique: true
    field :iban_masked, :string, max_size: 40
    field :holder, :string, max_size: 140
    field :status, :string, max_size: 16
    field :signed_on, :date
    field :revoked_at, :date_time, blank: true, null: true

    with_timestamp_fields
  end
end
