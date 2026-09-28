# SPDX-License-Identifier: AGPL-3.0-or-later

module Urssaf
  # URSSAF simulée pour les specs (ADR-007 D7) : identifiants de test,
  # comptes auto-entrepreneurs par SIREN (éligibilité, périodicité), mandats,
  # estimation et déclaration idempotente (taux simples par catégorie),
  # rejets et pannes à la demande. Aucun appel réseau.
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
    property failure : String? = nil
    property rejection : String? = nil

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
      ack = Acknowledgement.new("DECL-#{100 + declarations.size}", contributions(submission),
        submission.ends_on.shift(months: 1).at_end_of_month.at_beginning_of_day)
      acknowledgements[submission.reference] = ack
      ack
    end

    private def contributions(submission : Submission) : Array(Contribution)
      submission.turnover.compact_map do |category, amount|
        next if amount.zero?
        Contribution.new(category, amount, (amount * RATES[category]).round(2))
      end
    end
  end
end
