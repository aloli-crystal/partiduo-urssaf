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

    # Télépaiement SEPA : initié, effectué, rejeté (motif).
    PAYMENT_STATUSES = %w[initiated done rejected]

    # Mandat de prélèvement SEPA.
    SEPA_STATUSES = %w[active revoked]

    # Anomalies du suivi (`paid_elsewhere`, `payment_unknown` : migration
    # 0004).
    ANOMALY_CODES = %w[rejected urssaf contributions_changed payment_rejected mandate_revoked paid_elsewhere
      payment_unknown]

    # Actions de l'historique.
    EVENT_ACTIONS = %w[signed notified revoked eligibility estimated declared rejected error paid payment_done
      payment_rejected sepa_registered sepa_revoked refreshed anomaly resolved remote_revoked]

    # Catégories de chiffre d'affaires du module `micro` déclarées.
    CATEGORIES = %w[sale_bic service_bic bnc]
  end
end
