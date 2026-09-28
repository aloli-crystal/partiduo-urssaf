# SPDX-License-Identifier: AGPL-3.0-or-later

module Urssaf
  # URSSAF simulée pour les specs (ADR-007 D7) : identifiants de test,
  # comptes auto-entrepreneurs par SIREN (éligibilité, périodicité), mandats,
  # estimation et déclaration idempotente (taux simples par catégorie) avec
  # accusé PDF, suivi (régularisation, anomalies), mandats SEPA,
  # télépaiement idempotent ; rejets, révocations et pannes à la demande.
  # Aucun appel réseau.
  class SimulatedUrssaf < Transport
    CLIENT_ID     = "tiers-declarant-test"
    CLIENT_SECRET = "secret-urssaf-0123456789"

    # Taux de la simulation (pas ceux de l'URSSAF) : de quoi distinguer le
    # calcul de l'URSSAF de l'estimation de Partiduo.
    RATES = {"sale_bic" => BigDecimal.new("0.12"), "service_bic" => BigDecimal.new("0.21"), "bnc" => BigDecimal.new("0.23")}

    getter accounts = {} of String => Eligibility
    getter mandates = {} of String => String
    getter declarations = {} of String => Submission
    getter acknowledgements = {} of String => Acknowledgement
    getter sepa = {} of String => SepaMandate
    getter sepa_ibans = {} of String => String
    getter payments = {} of String => PaymentState
    getter orders = {} of String => PaymentOrder
    # Cotisations régularisées et anomalies signalées, par numéro de
    # déclaration.
    getter adjusted = {} of String => BigDecimal
    getter reported = {} of String => Array(String)
    property failure : String? = nil
    property rejection : String? = nil
    # Accusé rendu en PDF (sinon aucun document : Partiduo établit l'accusé).
    property? pdf_receipt = true
    # Issue des paiements au relevé suivant : `done` ou `rejected`.
    property payment_outcome = "done"

    def initialize(siren : String = "732829320", periodicity : String = "quarterly")
      @accounts[siren] = Eligibility.new(true, periodicity)
    end

    def name : String
      "URSSAF simulée"
    end

    def check(credentials : Credentials) : Nil
      raise TransportError.new("urssaf.errors.transport.unavailable") if failure
      unless credentials.client_id == CLIENT_ID && credentials.client_secret == CLIENT_SECRET
        raise TransportError.new("urssaf.errors.transport.credentials")
      end
    end

    def eligibility(credentials : Credentials, siren : String) : Eligibility
      check(credentials)
      accounts[siren]? || raise TransportError.new("urssaf.errors.transport.account_unknown")
    end

    def notify_mandate(credentials : Credentials, siren : String, signed_on : Time) : String
      eligibility(credentials, siren)
      ref = "MDT-#{siren}-#{mandates.size + 1}"
      mandates[ref] = siren
      ref
    end

    def revoke_mandate(credentials : Credentials, mandate_ref : String) : Nil
      check(credentials)
      mandates.delete(mandate_ref) || raise TransportError.new("urssaf.errors.transport.mandate_unknown")
    end

    def estimate(credentials : Credentials, submission : Submission) : Array(Contribution)
      check(credentials)
      contributions(submission)
    end

    def declare(credentials : Credentials, submission : Submission) : Acknowledgement
      check(credentials)
      raise TransportError.new("urssaf.errors.transport.mandate_unknown") unless mandates.has_key?(submission.mandate_ref)
      if reason = rejection
        raise TransportError.new("urssaf.errors.transport.rejected", {"reason" => reason})
      end
      if existing = acknowledgements[submission.reference]?
        return existing
      end
      declarations[submission.reference] = submission
      remote_id = "DECL-#{100 + declarations.size}"
      ack = Acknowledgement.new(remote_id, contributions(submission),
        submission.ends_on.shift(months: 1).at_end_of_month.at_beginning_of_day, receipt_for(remote_id))
      acknowledgements[submission.reference] = ack
      ack
    end

    def mandate_active?(credentials : Credentials, mandate_ref : String) : Bool
      check(credentials)
      mandates.has_key?(mandate_ref)
    end

    def declaration_state(credentials : Credentials, remote_id : String) : DeclarationState
      check(credentials)
      reference, ack = acknowledgements.find { |_, item| item.remote_id == remote_id } ||
                       raise TransportError.new("urssaf.errors.transport.unavailable")
      contributions = ack.contributions
      if total = adjusted[remote_id]?
        contributions = [Contribution.new(contributions.first?.try(&.category) || "service_bic",
          declarations[reference].turnover.values.sum(BigDecimal.new(0)), total)]
      end
      paid = orders.select { |key, order| order.declaration_id == remote_id && payments[key].status == "done" }
        .sum(BigDecimal.new(0)) { |(_, order)| order.amount }
      DeclarationState.new(remote_id, contributions, ack.due_on, paid, reported[remote_id]? || [] of String)
    end

    def sepa_mandates(credentials : Credentials, siren : String) : Array(SepaMandate)
      check(credentials)
      sepa.values
    end

    def register_sepa_mandate(credentials : Credentials, request : SepaMandateRequest) : SepaMandate
      check(credentials)
      rum = "RUM-#{request.siren}-#{sepa.size + 1}"
      mandate = SepaMandate.new(rum, Iban.mask(request.iban), request.holder, "active", request.signed_on)
      sepa[rum] = mandate
      sepa_ibans[rum] = request.iban
      mandate
    end

    def revoke_sepa_mandate(credentials : Credentials, siren : String, rum : String) : Nil
      check(credentials)
      sepa.delete(rum) || raise TransportError.new("urssaf.errors.transport.sepa_refused", {"reason" => "RUM inconnue"})
      nil
    end

    def pay(credentials : Credentials, order : PaymentOrder) : PaymentState
      check(credentials)
      if existing = payments[order.reference]?
        return existing
      end
      unless sepa.has_key?(order.sepa_rum)
        raise TransportError.new("urssaf.errors.transport.sepa_refused", {"reason" => "mandat SEPA inconnu"})
      end
      state = PaymentState.new("PAY-#{500 + payments.size + 1}", "initiated")
      payments[order.reference] = state
      orders[order.reference] = order
      state
    end

    # Au relevé, les paiements initiés prennent l'issue `payment_outcome`.
    def payment_state(credentials : Credentials, remote_id : String) : PaymentState
      check(credentials)
      reference, state = payments.find { |_, item| item.remote_id == remote_id } ||
                         raise TransportError.new("urssaf.errors.transport.unavailable")
      if state.status == "initiated"
        state = payment_outcome == "rejected" ? PaymentState.new(remote_id, "rejected", "Provision insuffisante") : PaymentState.new(remote_id, "done")
        payments[reference] = state
      end
      state
    end

    private def receipt_for(remote_id : String) : Receipt?
      return unless pdf_receipt?
      Receipt.new("accuse-#{remote_id}.pdf", "application/pdf",
        "%PDF-1.4\n% Accusé URSSAF simulé #{remote_id}\n%%EOF\n".to_slice)
    end

    private def contributions(submission : Submission) : Array(Contribution)
      submission.turnover.compact_map do |category, amount|
        next if amount.zero?
        Contribution.new(category, amount, (amount * RATES[category]).round(2))
      end
    end
  end
end
