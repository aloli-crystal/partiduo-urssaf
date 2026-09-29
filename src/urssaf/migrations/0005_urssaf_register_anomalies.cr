# SPDX-License-Identifier: AGPL-3.0-or-later

# Déclarations acceptées que le module `micro` ne reflète plus (DECISIONS
# D-MIC2-004) : anomalies `not_marked` (période non notée comme déclarée
# dans le module) et `turnover_changed` (chiffre d'affaires du registre
# différent de celui transmis : déclaration à corriger).
class Migration::Urssaf::V0005 < Marten::Migration
  depends_on :urssaf, "0004_urssaf_idempotence"

  CODES_V3 = Migration::Urssaf::V0004::CODES_V3
  CODES_V4 = CODES_V3 + ", 'not_marked', 'turnover_changed'"

  def plan
    execute(<<-SQL, <<-SQL)
      ALTER TABLE urssaf_anomaly
        DROP CONSTRAINT urssaf_anomaly_code_check,
        ADD CONSTRAINT urssaf_anomaly_code_check CHECK (code IN (#{CODES_V4}))
      SQL
      ALTER TABLE urssaf_anomaly
        DROP CONSTRAINT urssaf_anomaly_code_check,
        ADD CONSTRAINT urssaf_anomaly_code_check CHECK (code IN (#{CODES_V3}))
      SQL
  end
end
