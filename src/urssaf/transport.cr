# SPDX-License-Identifier: AGPL-3.0-or-later

module Urssaf
  # Identifiants de l'opérateur, tiers déclarant (OAuth 2 _client
  # credentials_), déchiffrés le temps d'un appel, jamais journalisés.
  record Credentials, client_id : String, client_secret : String, env : String do
    def to_s(io : IO) : Nil
      io << "Urssaf::Credentials(" << client_id << ", ***, " << env << ")"
    end

    def inspect(io : IO) : Nil
      to_s(io)
    end
  end

  # Éligibilité du compte auto-entrepreneur : `periodicity` `monthly` ou
  # `quarterly` ; `reason` si le compte n'est pas éligible.
  record Eligibility, eligible : Bool, periodicity : String, reason : String = ""

  # Cotisation calculée par l'URSSAF pour une catégorie.
  record Contribution, category : String, turnover : BigDecimal, amount : BigDecimal

  # Déclaration remise au transport : `reference` est la clé d'idempotence ;
  # chiffre d'affaires par catégorie, en euros.
  record Submission, reference : String, siren : String, mandate_ref : String, starts_on : Time, ends_on : Time,
    turnover : Hash(String, BigDecimal)

  # Accusé de l'URSSAF : numéro de la déclaration, cotisations dues et date
  # limite de paiement.
  record Acknowledgement, remote_id : String, contributions : Array(Contribution), due_on : Time? do
    def total : BigDecimal
      contributions.sum(BigDecimal.new(0), &.amount)
    end
  end

  # Erreur du transport : `key` est une clé i18n (`urssaf.errors.transport.*`).
  class TransportError < Exception
    getter key : String
    getter params : Hash(String, String)

    def initialize(@key : String, @params : Hash(String, String) = {} of String => String, message : String? = nil)
      super(message || @key)
    end
  end

  # Interface abstraite de l'API Tierce Déclaration auto-entrepreneur
  # (ADR-007 D7) : l'extension est écrite contre elle et testée contre une
  # URSSAF simulée (`spec/support/simulated_urssaf.cr`). L'adaptateur réel
  # se branche par `Urssaf::Transports.current =` après la souscription de
  # l'opérateur (BLOCAGES B-FIN-003).
  abstract class Transport
    abstract def name : String

    # Vérifie les identifiants ; lève `TransportError`
    # (`urssaf.errors.transport.credentials`).
    abstract def check(credentials : Credentials) : Nil

    # Éligibilité et périodicité du compte de l'entreprise (SIREN).
    abstract def eligibility(credentials : Credentials, siren : String) : Eligibility

    # Notifie le mandat ; rend sa référence chez l'URSSAF.
    abstract def notify_mandate(credentials : Credentials, siren : String, signed_on : Time) : String

    # Révoque le mandat.
    abstract def revoke_mandate(credentials : Credentials, mandate_ref : String) : Nil

    # Estime les cotisations d'un chiffre d'affaires, sans rien déclarer.
    abstract def estimate(credentials : Credentials, submission : Submission) : Array(Contribution)

    # Déclare le chiffre d'affaires de la période ; idempotent sur
    # `submission.reference`.
    abstract def declare(credentials : Credentials, submission : Submission) : Acknowledgement
  end

  # Transport actif de l'instance ; `nil` tant que l'adaptateur réel n'est
  # pas écrit : la déclaration se fait alors sur le site de l'URSSAF et se
  # note dans l'écran URSSAF du module `micro`.
  module Transports
    class_property current : Transport? = nil

    def self.available? : Bool
      !current.nil?
    end
  end
end
