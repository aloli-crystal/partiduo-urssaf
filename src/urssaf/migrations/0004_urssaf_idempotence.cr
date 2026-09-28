# SPDX-License-Identifier: AGPL-3.0-or-later

# Déclaration idempotente et suivi des paiements (DECISIONS D-URS-008,
# D-URS-009) : nombre de rejets reçus par période (`attempts`), dont dépend
# la référence de la tentative suivante ; anomalies `paid_elsewhere`
# (l'URSSAF compte plus de paiements que Partiduo) et `payment_unknown`
# (paiement initié sans numéro de l'URSSAF).
class Migration::Urssaf::V0004 < Marten::Migration
  depends_on :urssaf, "0003_urssaf_iban_mask"

  CODES_V2 = "'rejected', 'urssaf', 'contributions_changed', 'payment_rejected', 'mandate_revoked'"
  CODES_V3 = CODES_V2 + ", 'paid_elsewhere', 'payment_unknown'"

  def plan
    add_column :urssaf_filing, :attempts, :int, default: 0

    execute(<<-SQL, <<-SQL)
      ALTER TABLE urssaf_filing
        ADD CONSTRAINT urssaf_filing_attempts_check CHECK (attempts >= 0)
      SQL
      ALTER TABLE urssaf_filing DROP CONSTRAINT urssaf_filing_attempts_check
      SQL
    execute(<<-SQL, <<-SQL)
      ALTER TABLE urssaf_anomaly
        DROP CONSTRAINT urssaf_anomaly_code_check,
        ADD CONSTRAINT urssaf_anomaly_code_check CHECK (code IN (#{CODES_V3}))
      SQL
      ALTER TABLE urssaf_anomaly
        DROP CONSTRAINT urssaf_anomaly_code_check,
        ADD CONSTRAINT urssaf_anomaly_code_check CHECK (code IN (#{CODES_V2}))
      SQL
  end
end
