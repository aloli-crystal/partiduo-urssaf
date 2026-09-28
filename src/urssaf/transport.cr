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

  # Document rendu par l'URSSAF (accusé de déclaration) : conservé en pièce
  # jointe du socle.
  record Receipt, filename : String, content_type : String, content : Bytes

  # Accusé de l'URSSAF : numéro de la déclaration, cotisations dues, date
  # limite de paiement et, s'il est fourni, le document de l'accusé.
  record Acknowledgement, remote_id : String, contributions : Array(Contribution), due_on : Time?,
    receipt : Receipt? = nil do
    def total : BigDecimal
      contributions.sum(BigDecimal.new(0), &.amount)
    end
  end

  # Suivi d'une déclaration transmise : cotisations dues selon l'URSSAF
  # (elles peuvent changer après une régularisation), montant déjà payé,
  # anomalies signalées (textes de l'URSSAF).
  record DeclarationState, remote_id : String, contributions : Array(Contribution), due_on : Time?,
    paid : BigDecimal, anomalies : Array(String) do
    def total : BigDecimal
      contributions.sum(BigDecimal.new(0), &.amount)
    end
  end

  # Mandat de prélèvement SEPA connu de l'URSSAF : référence unique (RUM),
  # IBAN masqué (jamais l'IBAN complet), titulaire, `active` ou `revoked`.
  record SepaMandate, rum : String, iban_masked : String, holder : String, status : String, signed_on : Time

  # Demande d'enregistrement d'un mandat SEPA : IBAN complet (transmis, pas
  # conservé), BIC, titulaire, date de signature.
  record SepaMandateRequest, siren : String, iban : String, bic : String, holder : String, signed_on : Time do
    def to_s(io : IO) : Nil
      io << "Urssaf::SepaMandateRequest(" << siren << ", " << Iban.mask(iban) << ", " << holder << ")"
    end

    def inspect(io : IO) : Nil
      to_s(io)
    end
  end

  # Ordre de télépaiement SEPA des cotisations d'une déclaration :
  # `reference` est la clé d'idempotence ; `debit_on` nil = date limite.
  record PaymentOrder, reference : String, siren : String, declaration_id : String, amount : BigDecimal,
    sepa_rum : String, debit_on : Time? = nil

  # État d'un télépaiement : `initiated`, `done` ou `rejected` (motif).
  record PaymentState, remote_id : String, status : String, reason : String = ""

  # Erreur du transport : `key` est une clé i18n (`urssaf.errors.transport.*`).
  class TransportError < Exception
    getter key : String
    getter params : Hash(String, String)

    def initialize(@key : String, @params : Hash(String, String) = {} of String => String, message : String? = nil)
      super(message || @key)
    end
  end

  # Interface abstraite de l'API Tierce Déclaration auto-entrepreneur
  # (ADR-007 D7 ; services « Comptes », « Mandats », « Estimer »,
  # « Déclarer », « Payer », « SEPA Mandats » du catalogue `td-ae`) : l'extension est écrite contre elle et testée contre une
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

    # Le mandat est-il toujours actif ? Le micro-entrepreneur peut le
    # révoquer depuis son espace URSSAF.
    abstract def mandate_active?(credentials : Credentials, mandate_ref : String) : Bool

    # Estime les cotisations d'un chiffre d'affaires, sans rien déclarer.
    abstract def estimate(credentials : Credentials, submission : Submission) : Array(Contribution)

    # Déclare le chiffre d'affaires de la période ; idempotent sur
    # `submission.reference`.
    abstract def declare(credentials : Credentials, submission : Submission) : Acknowledgement

    # Suivi d'une déclaration acceptée : cotisations dues, payé, anomalies.
    abstract def declaration_state(credentials : Credentials, remote_id : String) : DeclarationState

    # Mandats SEPA du compte.
    abstract def sepa_mandates(credentials : Credentials, siren : String) : Array(SepaMandate)

    # Enregistre un mandat SEPA ; rend le mandat (RUM, IBAN masqué).
    abstract def register_sepa_mandate(credentials : Credentials, request : SepaMandateRequest) : SepaMandate

    # Révoque un mandat SEPA.
    abstract def revoke_sepa_mandate(credentials : Credentials, siren : String, rum : String) : Nil

    # Initie le télépaiement SEPA ; idempotent sur `order.reference`.
    abstract def pay(credentials : Credentials, order : PaymentOrder) : PaymentState

    # État d'un télépaiement initié.
    abstract def payment_state(credentials : Credentials, remote_id : String) : PaymentState
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
