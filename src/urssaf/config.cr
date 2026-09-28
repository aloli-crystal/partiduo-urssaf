# SPDX-License-Identifier: AGPL-3.0-or-later

module Urssaf
  # Valeurs fermées de l'extension (vérifiées aussi en base par la
  # migration 0001).
  module Config
    # État du mandat du micro-entrepreneur : recueilli dans Partiduo
    # (`signed`), notifié à l'URSSAF (`notified`), révoqué (`revoked`).
    MANDATE_STATUSES = %w[none signed notified revoked]

    # Statut d'une déclaration transmise : acceptée (accusé et cotisations
    # dues), rejetée (motif).
    STATUSES = %w[accepted rejected]

    ENVIRONMENTS = %w[sandbox production]

    # Catégories de chiffre d'affaires du module `micro` déclarées.
    CATEGORIES = %w[sale_bic service_bic bnc]
  end
end
