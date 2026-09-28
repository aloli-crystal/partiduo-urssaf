# SPDX-License-Identifier: AGPL-3.0-or-later

# IBAN masqué seulement, séparateurs compris (DECISIONS D-URS-003,
# D-URS-007) : la contrainte de la migration 0002 laissait passer un IBAN en
# clair groupé par quatre caractères (`FR76 3000 6000 …`) ; les séparateurs
# sont désormais ignorés avant de chercher neuf caractères en clair d'affilée.
class Migration::Urssaf::V0003 < Marten::Migration
  depends_on :urssaf, "0002_urssaf_payments"

  def plan
    execute(<<-SQL, <<-SQL)
      ALTER TABLE urssaf_sepa_mandate
        DROP CONSTRAINT urssaf_sepa_mandate_masked_check,
        ADD CONSTRAINT urssaf_sepa_mandate_masked_check
          CHECK (regexp_replace(iban_masked, '[^0-9A-Za-z*]', '', 'g') !~ '[0-9A-Za-z]{9,}')
      SQL
      ALTER TABLE urssaf_sepa_mandate
        DROP CONSTRAINT urssaf_sepa_mandate_masked_check,
        ADD CONSTRAINT urssaf_sepa_mandate_masked_check CHECK (iban_masked !~ '[0-9A-Z]{9,}')
      SQL
  end
end
