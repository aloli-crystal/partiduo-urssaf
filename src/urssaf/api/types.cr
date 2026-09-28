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

    # Mandat de prélèvement SEPA autorisé par le micro-entrepreneur : IBAN
    # (transmis à l'URSSAF, jamais conservé ni rendu en clair), BIC
    # facultatif, titulaire, date, autorisation explicite (`accepted`).
    record SepaMandateInput, iban : String, bic : String, holder : String, signed_on : Time, accepted : Bool do
      def to_s(io : IO) : Nil
        io << "Urssaf::Api::SepaMandateInput(" << Urssaf::Iban.mask(iban) << ", " << holder << ")"
      end

      def inspect(io : IO) : Nil
        to_s(io)
      end
    end

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

    # Télépaiement SEPA : période payée, numéro chez l'URSSAF, montant,
    # mandat SEPA (RUM), état (`initiated`, `done`, `rejected`) et motif.
    record PaymentView,
      id : Int64,
      starts_on : Time,
      remote_id : String,
      amount : BigDecimal,
      sepa_rum : String,
      status : String,
      reason : String,
      created_at : Time,
      updated_at : Time do
      def status_key : String
        "urssaf.payment_statuses.#{status}"
      end
    end

    # Déclaration transmise : `accepted` (numéro, cotisations dues, date
    # limite de paiement, accusé en pièce jointe, paiements) ou `rejected`
    # (motif).
    record FilingView,
      status : String,
      remote_id : String,
      turnover : Hash(String, BigDecimal),
      contributions : Array(ContributionView),
      contributions_total : BigDecimal,
      payment_due_on : Time?,
      reason : String,
      transmitted_at : Time,
      receipt_attachment_id : Int64? = nil,
      payments : Array(PaymentView) = [] of PaymentView do
      def status_key : String
        "urssaf.statuses.#{status}"
      end

      # Payé (paiements effectués).
      def paid_total : BigDecimal
        payments.select(&.status.==("done")).sum(BigDecimal.new(0), &.amount)
      end

      # Reste dû : cotisations moins paiements effectués ou en cours.
      def remaining : BigDecimal
        return BigDecimal.new(0) unless status == "accepted"
        committed = payments.reject(&.status.==("rejected")).sum(BigDecimal.new(0), &.amount)
        rest = contributions_total - committed
        rest > BigDecimal.new(0) ? rest : BigDecimal.new(0)
      end

      def receipt? : Bool
        !receipt_attachment_id.nil?
      end
    end

    # Anomalie du suivi (`code` : `rejected`, `urssaf`,
    # `contributions_changed`, `payment_rejected`, `mandate_revoked`).
    record AnomalyView, id : Int64, code : String, detail : String, starts_on : Time?, created_at : Time,
      resolved_at : Time? do
      def code_key : String
        "urssaf.anomalies.#{code}"
      end
    end

    # Mandat de prélèvement SEPA : RUM, IBAN masqué, titulaire, état.
    record SepaMandateView, rum : String, iban_masked : String, holder : String, status : String, signed_on : Time,
      revoked_at : Time? do
      def status_key : String
        "urssaf.sepa_statuses.#{status}"
      end
    end

    # Accusé conservé : nom, type, contenu.
    record ReceiptView, filename : String, content_type : String, content : Bytes

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

      # Déclaration acceptée dont il reste des cotisations à payer.
      def payable? : Bool
        filing.try { |row| row.status == "accepted" && row.remaining > BigDecimal.new(0) } || false
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

    # Vue d'ensemble du suivi : mandat, cotisations dues, payées, reste dû ;
    # périodes à déclarer (échéance passée ou proche) et à payer ;
    # anomalies ouvertes ; mandat SEPA actif.
    record OverviewView,
      mandate_status : String,
      transport : String?,
      contributions_due : BigDecimal,
      paid : BigDecimal,
      remaining : BigDecimal,
      to_declare : Array(PeriodView),
      to_pay : Array(PeriodView),
      anomalies : Array(AnomalyView),
      sepa_mandate : SepaMandateView?
  end
end
