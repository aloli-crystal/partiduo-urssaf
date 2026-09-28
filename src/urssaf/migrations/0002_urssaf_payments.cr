# SPDX-License-Identifier: AGPL-3.0-or-later

# Suivi complet de la tierce déclaration (ADR-007 D7, DECISIONS D-URS-001 à
# D-URS-005) : accusé en pièce jointe du socle, télépaiements SEPA,
# anomalies, mandats SEPA (IBAN masqué seulement), actions de l'historique
# étendues.
#
# Intégrité en base : un paiement a un montant positif, un statut connu et
# un motif s'il est rejeté ; une anomalie a un code connu ; un mandat SEPA
# révoqué a sa date ; l'IBAN conservé est masqué (jamais plus de quatre
# caractères du compte en clair).
class Migration::Urssaf::V0002 < Marten::Migration
  depends_on :urssaf, "0001_create_urssaf"
  depends_on :core, "0002_core_referential"

  EVENT_ACTIONS_V1 = "'signed', 'notified', 'revoked', 'eligibility', 'estimated', 'declared', 'rejected', 'error'"
  EVENT_ACTIONS_V2 = EVENT_ACTIONS_V1 + ", 'paid', 'payment_done', 'payment_rejected', 'sepa_registered', " \
                                        "'sepa_revoked', 'refreshed', 'anomaly', 'resolved', 'remote_revoked'"

  CONSTRAINTS = [
    {<<-SQL, "ALTER TABLE urssaf_filing DROP CONSTRAINT IF EXISTS urssaf_filing_receipt_fk"},
      ALTER TABLE urssaf_filing
        ADD CONSTRAINT urssaf_filing_receipt_fk FOREIGN KEY (receipt_attachment_id) REFERENCES core_attachment (id)
      SQL
    {<<-SQL, "SELECT 1"},
      ALTER TABLE urssaf_payment
        ADD CONSTRAINT urssaf_payment_filing_fk FOREIGN KEY (filing_id) REFERENCES urssaf_filing (id),
        ADD CONSTRAINT urssaf_payment_user_fk FOREIGN KEY (initiated_by_id) REFERENCES auth_user (id) ON DELETE SET NULL,
        ADD CONSTRAINT urssaf_payment_amount_check CHECK (amount > 0),
        ADD CONSTRAINT urssaf_payment_status_check CHECK (status IN ('initiated', 'done', 'rejected')),
        ADD CONSTRAINT urssaf_payment_reason_check CHECK (status <> 'rejected' OR reason <> '')
      SQL
    {<<-SQL, "SELECT 1"},
      ALTER TABLE urssaf_anomaly
        ADD CONSTRAINT urssaf_anomaly_filing_fk FOREIGN KEY (filing_id) REFERENCES urssaf_filing (id),
        ADD CONSTRAINT urssaf_anomaly_code_check CHECK (code IN
          ('rejected', 'urssaf', 'contributions_changed', 'payment_rejected', 'mandate_revoked'))
      SQL
    {<<-SQL, "SELECT 1"},
      ALTER TABLE urssaf_sepa_mandate
        ADD CONSTRAINT urssaf_sepa_mandate_status_check CHECK (status IN ('active', 'revoked')),
        ADD CONSTRAINT urssaf_sepa_mandate_revoked_check CHECK (status <> 'revoked' OR revoked_at IS NOT NULL),
        ADD CONSTRAINT urssaf_sepa_mandate_masked_check CHECK (iban_masked !~ '[0-9A-Z]{9,}')
      SQL
    {<<-SQL, <<-SQL},
      ALTER TABLE urssaf_event
        DROP CONSTRAINT urssaf_event_action_check,
        ADD CONSTRAINT urssaf_event_action_check CHECK (action IN (#{EVENT_ACTIONS_V2}))
      SQL
      ALTER TABLE urssaf_event
        DROP CONSTRAINT urssaf_event_action_check,
        ADD CONSTRAINT urssaf_event_action_check CHECK (action IN (#{EVENT_ACTIONS_V1}))
      SQL
  ]

  def plan
    add_column :urssaf_filing, :receipt_attachment_id, :big_int, null: true

    create_table :urssaf_payment do
      column :id, :big_int, primary_key: true, auto: true
      column :filing_id, :big_int
      column :reference, :string, max_size: 128, unique: true
      column :remote_id, :string, max_size: 128, default: ""
      column :amount, :decimal, max_digits: 20, decimal_places: 2
      column :sepa_rum, :string, max_size: 64
      column :status, :string, max_size: 16
      column :reason, :text, default: ""
      column :initiated_by_id, :big_int, null: true
      column :created_at, :date_time
      column :updated_at, :date_time
    end

    create_table :urssaf_anomaly do
      column :id, :big_int, primary_key: true, auto: true
      column :filing_id, :big_int, null: true
      column :code, :string, max_size: 32
      column :detail, :text, default: ""
      column :resolved_at, :date_time, null: true
      column :resolved_by_id, :big_int, null: true
      column :created_at, :date_time
      column :updated_at, :date_time
    end

    create_table :urssaf_sepa_mandate do
      column :id, :big_int, primary_key: true, auto: true
      column :rum, :string, max_size: 64, unique: true
      column :iban_masked, :string, max_size: 40
      column :holder, :string, max_size: 140
      column :status, :string, max_size: 16
      column :signed_on, :date
      column :revoked_at, :date_time, null: true
      column :created_at, :date_time
      column :updated_at, :date_time
    end

    CONSTRAINTS.each { |(forward, backward)| execute(forward, backward) }
  end
end
