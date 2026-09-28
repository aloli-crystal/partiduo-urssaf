# SPDX-License-Identifier: AGPL-3.0-or-later

module Urssaf
  module Api
    # --- Entrées -----------------------------------------------------------------

    # Identifiants de l'opérateur (tiers déclarant) ; un secret vide garde
    # celui enregistré.
    record CredentialsInput, client_id : String, client_secret : String, env : String = "sandbox"

    # Mandat donné par le micro-entrepreneur : date de signature et
    # acceptation explicite des termes (`accepted`).
    record MandateInput, signed_on : Time, accepted : Bool

    # --- Vues --------------------------------------------------------------------

    record ControlView, key : String, params : Hash(String, String), severity : String do
      def error? : Bool
        severity == "error"
      end
    end

    record ContributionView, category : String, turnover : BigDecimal, amount : BigDecimal do
      def category_key : String
        "micro.categories.#{category}"
      end
    end

    # Déclaration transmise : `accepted` (numéro, cotisations dues, date
    # limite de paiement) ou `rejected` (motif).
    record FilingView,
      status : String,
      remote_id : String,
      turnover : Hash(String, BigDecimal),
      contributions : Array(ContributionView),
      contributions_total : BigDecimal,
      payment_due_on : Time?,
      reason : String,
      transmitted_at : Time do
      def status_key : String
        "urssaf.statuses.#{status}"
      end
    end

    # Période de déclaration du module `micro` : bornes, échéance, statut
    # du module (`open`, `upcoming`, `due`, `late`, `declared`), chiffre
    # d'affaires à déclarer par catégorie (arrondi à l'euro), cotisations
    # estimées par le module, déclaration transmise, contrôles.
    record PeriodView,
      starts_on : Time,
      ends_on : Time,
      due_on : Time,
      micro_status : String,
      turnover : Hash(String, BigDecimal),
      estimated_total : BigDecimal,
      filing : FilingView?,
      controls : Array(ControlView) do
      def transmittable? : Bool
        controls.none?(&.error?)
      end

      def total_turnover : BigDecimal
        turnover.values.sum(BigDecimal.new(0))
      end
    end

    record EventView, action : String, detail : String, user_id : Int64?, created_at : Time do
      def action_key : String
        "urssaf.actions.#{action}"
      end
    end

    # Paramètres : le secret n'est jamais rendu ; l'identifiant de l'API ne
    # l'est qu'aux titulaires de `urssaf.settings.manage`.
    record SettingsView,
      env : String,
      client_id : String,
      secret_stored : Bool,
      checked_at : Time?,
      transport : String?,
      siren : String,
      mandate_status : String,
      mandate_signed_on : Time?,
      mandate_ref : String,
      mandate_notified_at : Time?,
      mandate_revoked_at : Time?,
      eligible : Bool?,
      periodicity : String,
      eligibility_reason : String,
      eligibility_checked_at : Time? do
      def mandate_key : String
        "urssaf.mandate_statuses.#{mandate_status}"
      end
    end
  end
end
