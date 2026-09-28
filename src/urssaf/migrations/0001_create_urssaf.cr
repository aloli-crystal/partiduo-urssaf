# SPDX-License-Identifier: AGPL-3.0-or-later

# Tables de l'extension URSSAF (ADR-007 D7) : paramètres (secret chiffré,
# mandat), déclarations transmises, historique.
#
# Intégrité en base : une seule ligne de paramètres ; environnement, état du
# mandat, statuts et périodicité contrôlés ; un mandat notifié a sa
# référence et sa date de signature ; une déclaration acceptée a son
# numéro, une déclaration rejetée son motif ; une déclaration acceptée ne
# change plus et ne se supprime pas (déclencheur `urssaf_filing_guard`).
class Migration::Urssaf::V0001 < Marten::Migration
  depends_on :micro, "0001_micro"
  depends_on :auth, "0001_create_auth_user_table"

  CONSTRAINTS = [
    {<<-SQL, "SELECT 1"},
      ALTER TABLE urssaf_settings
        ADD CONSTRAINT urssaf_settings_key_check CHECK (key = 'default'),
        ADD CONSTRAINT urssaf_settings_env_check CHECK (env IN ('sandbox', 'production')),
        ADD CONSTRAINT urssaf_settings_mandate_check CHECK (mandate_status IN ('none', 'signed', 'notified', 'revoked')),
        ADD CONSTRAINT urssaf_settings_notified_check CHECK (mandate_status <> 'notified'
          OR (mandate_ref <> '' AND mandate_signed_on IS NOT NULL AND mandate_notified_at IS NOT NULL)),
        ADD CONSTRAINT urssaf_settings_periodicity_check CHECK (periodicity IN ('', 'monthly', 'quarterly'))
      SQL
    {<<-SQL, "SELECT 1"},
      ALTER TABLE urssaf_filing
        ADD CONSTRAINT urssaf_filing_status_check CHECK (status IN ('accepted', 'rejected')),
        ADD CONSTRAINT urssaf_filing_period_check CHECK (starts_on <= ends_on),
        ADD CONSTRAINT urssaf_filing_remote_check CHECK (status <> 'accepted' OR remote_id <> ''),
        ADD CONSTRAINT urssaf_filing_reason_check CHECK (status <> 'rejected' OR reason <> ''),
        ADD CONSTRAINT urssaf_filing_total_check CHECK (contributions_total >= 0),
        ADD CONSTRAINT urssaf_filing_user_fk FOREIGN KEY (transmitted_by_id) REFERENCES auth_user (id)
      SQL
    {<<-SQL, "SELECT 1"},
      ALTER TABLE urssaf_event
        ADD CONSTRAINT urssaf_event_action_check CHECK (action IN
          ('signed', 'notified', 'revoked', 'eligibility', 'estimated', 'declared', 'rejected', 'error'))
      SQL
    {<<-SQL, "DROP FUNCTION IF EXISTS urssaf_filing_guard() CASCADE"},
      CREATE FUNCTION urssaf_filing_guard() RETURNS trigger AS $$
      BEGIN
        IF OLD.status = 'accepted' THEN
          RAISE EXCEPTION 'urssaf: déclaration du % acceptée, intangible', OLD.starts_on;
        END IF;
        IF TG_OP = 'DELETE' THEN
          RETURN OLD;
        END IF;
        RETURN NEW;
      END;
      $$ LANGUAGE plpgsql
      SQL
    {"CREATE TRIGGER urssaf_filing_guard BEFORE UPDATE OR DELETE ON urssaf_filing " \
     "FOR EACH ROW EXECUTE FUNCTION urssaf_filing_guard()", "SELECT 1"},
  ]

  def plan
    create_table :urssaf_settings do
      column :id, :big_int, primary_key: true, auto: true
      column :key, :string, max_size: 16, unique: true, default: "default"
      column :env, :string, max_size: 16, default: "sandbox"
      column :client_id, :string, max_size: 255, default: ""
      column :client_secret, :text, default: ""
      column :checked_at, :date_time, null: true
      column :mandate_status, :string, max_size: 16, default: "none"
      column :mandate_signed_on, :date, null: true
      column :mandate_signed_by_id, :big_int, null: true
      column :mandate_ref, :string, max_size: 128, default: ""
      column :mandate_notified_at, :date_time, null: true
      column :mandate_revoked_at, :date_time, null: true
      column :eligible, :bool, null: true
      column :periodicity, :string, max_size: 16, default: ""
      column :eligibility_reason, :text, default: ""
      column :eligibility_checked_at, :date_time, null: true
      column :updated_by_id, :big_int, null: true
      column :created_at, :date_time
      column :updated_at, :date_time
    end

    create_table :urssaf_filing do
      column :id, :big_int, primary_key: true, auto: true
      column :starts_on, :date, unique: true
      column :ends_on, :date
      column :turnover, :text
      column :status, :string, max_size: 16
      column :remote_id, :string, max_size: 128, default: ""
      column :contributions, :text, default: "[]"
      column :contributions_total, :decimal, max_digits: 20, decimal_places: 2, default: "0.0"
      column :payment_due_on, :date, null: true
      column :reason, :text, default: ""
      column :transmitted_at, :date_time
      column :transmitted_by_id, :big_int, null: true
      column :created_at, :date_time
      column :updated_at, :date_time
    end

    create_table :urssaf_event do
      column :id, :big_int, primary_key: true, auto: true
      column :action, :string, max_size: 16
      column :detail, :text, default: ""
      column :user_id, :big_int, null: true
      column :created_at, :date_time
    end

    CONSTRAINTS.each { |(forward, backward)| execute(forward, backward) }
  end
end
