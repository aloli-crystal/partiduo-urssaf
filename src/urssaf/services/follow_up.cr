# SPDX-License-Identifier: AGPL-3.0-or-later

module Urssaf
  # Suivi de la tierce déclaration (ADR-007 D7) : télépaiement SEPA des
  # cotisations dues, mandats SEPA, anomalies, relevé auprès de l'URSSAF
  # (mandat révoqué depuis l'espace URSSAF, cotisations régularisées,
  # anomalies signalées, paiements effectués ou rejetés), vue d'ensemble.
  # Interne.
  module FollowUp
    alias ApiT = Urssaf::Api
    alias FieldError = Partiduo::Api::FieldError
    alias Actor = Partiduo::Api::Actor
    alias Micro = Partiduo::Api::Micro

    ZERO = BigDecimal.new(0)

    # --- Anomalies -------------------------------------------------------------------

    # Ouvre une anomalie, sauf si la même est déjà ouverte.
    def self.anomaly(code : String, detail : String, filing : (Int32 | Int64)? = nil) : Nil
      filing_id = filing.try(&.to_i64)
      detail = detail[0, Math.min(detail.size, 2000)]
      open = Anomaly.filter(code: code, detail: detail, resolved_at: nil)
      open = filing_id ? open.filter(filing_id: filing_id) : open.filter(filing_id: nil)
      return if open.exists?
      Anomaly.create!(code: code, detail: detail, filing_id: filing_id)
      nil
    end

    def self.anomalies(open_only : Bool = true) : Array(ApiT::AnomalyView)
      rows = Anomaly.all.order("-id")
      rows = rows.filter(resolved_at: nil) if open_only
      starts = Filing.filter(id__in: rows.compact_map(&.filing_id)).to_h { |row| {row.id, row.starts_on} }
      rows.map do |row|
        ApiT::AnomalyView.new(row.id!.to_i64, row.code.to_s, row.detail.to_s, row.filing_id.try { |id| starts[id]? },
          row.created_at!, row.resolved_at)
      end
    end

    def self.resolve!(id : Int64, actor : Actor) : Partiduo::Api::Result(Nil)
      row = Anomaly.filter(id: id).first
      return Partiduo::Api::Result(Nil).failure(FieldError.base("urssaf.errors.anomaly")) unless row && row.resolved_at.nil?
      row.resolved_at = Time.utc
      row.resolved_by_id = actor.user_id
      row.save!
      Declarations.log("resolved", "#{row.code} #{row.detail}", actor)
      Partiduo::Api::Result(Nil).success(nil)
    end

    # --- Paiements -------------------------------------------------------------------

    def self.payments_of(filing : Filing) : Array(ApiT::PaymentView)
      Payment.filter(filing_id: filing.id).order("id").map { |row| payment_view(row, filing.starts_on!) }
    end

    def self.payment_view(row : Payment, starts_on : Time) : ApiT::PaymentView
      ApiT::PaymentView.new(row.id!.to_i64, starts_on, row.remote_id.to_s, row.amount || ZERO, row.sepa_rum.to_s,
        row.status.to_s, row.reason.to_s, row.created_at!, row.updated_at!)
    end

    def self.payments : Array(ApiT::PaymentView)
      starts = Filing.all.to_h { |row| {row.id, row.starts_on!} }
      Payment.all.order("-id").map { |row| payment_view(row, starts[row.filing_id]) }
    end

    # Télépaiement SEPA du reste dû d'une déclaration acceptée, par le
    # mandat SEPA actif. Refus : déclaration absente ou non acceptée, rien à
    # payer, mandat de tierce déclaration non notifié, aucun mandat SEPA
    # actif, transport ou identifiants absents ; rejet de l'URSSAF gardé
    # (paiement `rejected`, anomalie).
    def self.pay!(starts_on : Time, actor : Actor) : Partiduo::Api::Result(ApiT::PaymentView)
      result = Partiduo::Api::Result(ApiT::PaymentView)
      filing = Filing.filter(starts_on: starts_on, status: "accepted").first
      return result.failure(FieldError.new("starts_on", "urssaf.errors.payment.not_declared")) unless filing
      remaining = Declarations.filing_view(filing).remaining
      return result.failure(FieldError.base("urssaf.errors.payment.nothing_due")) unless remaining > ZERO
      settings = Settings.current!
      return result.failure(FieldError.base("urssaf.controls.mandate_missing")) unless settings.mandate_status == "notified"
      sepa = SepaMandateRow.filter(status: "active").order("-id").first
      return result.failure(FieldError.base("urssaf.errors.payment.no_sepa")) unless sepa
      connection = Declarations.connection
      return result.failure(connection) if connection.is_a?(FieldError)
      transport, credentials = connection
      count = Payment.filter(filing_id: filing.id).count + 1
      reference = "PDUO-PAY-#{Declarations.siren}-#{starts_on.to_s("%Y%m%d")}-#{count}"
      order = PaymentOrder.new(reference: reference, siren: Declarations.siren, declaration_id: filing.remote_id.to_s,
        amount: remaining, sepa_rum: sepa.rum.to_s)
      begin
        state = transport.pay(credentials, order)
      rescue ex : TransportError
        Declarations.log("error", ex.key, actor)
        return result.failure(FieldError.base(ex.key, ex.params))
      end
      row = Payment.create!(filing_id: filing.id, reference: reference, remote_id: state.remote_id, amount: remaining,
        sepa_rum: sepa.rum, status: known_status(state.status), reason: rejection_reason(state),
        initiated_by_id: actor.user_id)
      Declarations.log("paid", "#{filing.remote_id} #{remaining}", actor)
      payment_rejected(row, filing, actor) if row.status == "rejected"
      result.success(payment_view(row, filing.starts_on!))
    end

    private def self.known_status(status : String) : String
      Config::PAYMENT_STATUSES.includes?(status) ? status : "initiated"
    end

    private def self.rejection_reason(state : PaymentState) : String
      state.status == "rejected" ? state.reason.presence || "?" : ""
    end

    private def self.payment_rejected(row : Payment, filing : Filing, actor : Actor) : Nil
      Declarations.log("payment_rejected", "#{row.remote_id} #{row.reason}", actor)
      anomaly("payment_rejected", row.reason.to_s, filing.id)
    end

    # --- Mandats SEPA ------------------------------------------------------------------

    def self.sepa_mandates : Array(ApiT::SepaMandateView)
      SepaMandateRow.all.order("-id").map do |row|
        ApiT::SepaMandateView.new(row.rum.to_s, row.iban_masked.to_s, row.holder.to_s, row.status.to_s, row.signed_on!,
          row.revoked_at)
      end
    end

    def self.register_sepa!(input : ApiT::SepaMandateInput, actor : Actor) : Partiduo::Api::Result(ApiT::SepaMandateView)
      result = Partiduo::Api::Result(ApiT::SepaMandateView)
      errors = [] of FieldError
      iban = Iban.normalize(input.iban)
      holder = input.holder.strip
      errors << FieldError.new("iban", "urssaf.errors.sepa.iban") unless Iban.valid?(iban)
      errors << FieldError.new("bic", "urssaf.errors.sepa.bic") unless Iban.valid_bic?(input.bic)
      errors << FieldError.new("holder", "urssaf.errors.sepa.holder") if holder.empty? || holder.size > 140
      errors << FieldError.new("accepted", "urssaf.errors.sepa.accept") unless input.accepted
      errors << FieldError.new("signed_on", "urssaf.errors.mandate.future") if input.signed_on > Partiduo::Config.today
      if Settings.current!.mandate_status != "notified"
        errors << FieldError.base("urssaf.controls.mandate_missing")
      end
      return result.failure(errors) unless errors.empty?
      connection = Declarations.connection
      return result.failure(connection) if connection.is_a?(FieldError)
      transport, credentials = connection
      request = SepaMandateRequest.new(Declarations.siren, iban, Iban.normalize(input.bic), holder, input.signed_on)
      begin
        mandate = transport.register_sepa_mandate(credentials, request)
      rescue ex : TransportError
        Declarations.log("error", ex.key, actor)
        return result.failure(FieldError.base(ex.key, ex.params))
      end
      row = upsert_sepa(mandate)
      Declarations.log("sepa_registered", "#{row.rum} #{row.iban_masked}", actor)
      result.success(sepa_mandates.find!(&.rum.==(row.rum)))
    end

    def self.revoke_sepa!(rum : String, actor : Actor) : Partiduo::Api::Result(ApiT::SepaMandateView)
      result = Partiduo::Api::Result(ApiT::SepaMandateView)
      row = SepaMandateRow.filter(rum: rum, status: "active").first
      return result.failure(FieldError.new("rum", "urssaf.errors.sepa.unknown")) unless row
      connection = Declarations.connection
      return result.failure(connection) if connection.is_a?(FieldError)
      transport, credentials = connection
      begin
        transport.revoke_sepa_mandate(credentials, Declarations.siren, rum)
      rescue ex : TransportError
        Declarations.log("error", ex.key, actor)
        return result.failure(FieldError.base(ex.key, ex.params))
      end
      row.status = "revoked"
      row.revoked_at = Time.utc
      row.save!
      Declarations.log("sepa_revoked", rum, actor)
      result.success(sepa_mandates.find!(&.rum.==(rum)))
    end

    # Copie locale d'un mandat SEPA de l'URSSAF ; l'IBAN reste masqué même
    # si l'adaptateur le rendait en clair.
    private def self.upsert_sepa(mandate : SepaMandate) : SepaMandateRow
      row = SepaMandateRow.filter(rum: mandate.rum).first || SepaMandateRow.new(rum: mandate.rum)
      row.iban_masked = mandate.iban_masked.matches?(/[0-9A-Z]{9,}/) ? Iban.mask(mandate.iban_masked) : mandate.iban_masked
      row.holder = mandate.holder[0, Math.min(mandate.holder.size, 140)]
      row.signed_on = mandate.signed_on
      if mandate.status == "revoked"
        row.status = "revoked"
        row.revoked_at ||= Time.utc
      else
        row.status = "active"
        row.revoked_at = nil
      end
      row.save!
      row
    end

    # --- Relevé auprès de l'URSSAF ------------------------------------------------------

    # Relève l'état du mandat, des déclarations acceptées, des paiements
    # initiés et des mandats SEPA ; ouvre les anomalies constatées. Rend le
    # nombre d'anomalies ouvertes.
    def self.refresh!(actor : Actor) : Partiduo::Api::Result(Int32)
      result = Partiduo::Api::Result(Int32)
      connection = Declarations.connection
      return result.failure(connection) if connection.is_a?(FieldError)
      transport, credentials = connection
      begin
        refresh_mandate(transport, credentials, actor)
        refresh_filings(transport, credentials)
        refresh_payments(transport, credentials, actor)
        refresh_sepa(transport, credentials)
      rescue ex : TransportError
        Declarations.log("error", ex.key, actor)
        return result.failure(FieldError.base(ex.key, ex.params))
      end
      open = Anomaly.filter(resolved_at: nil).count.to_i
      Declarations.log("refreshed", open.to_s, actor)
      result.success(open)
    end

    # Mandat révoqué par le micro-entrepreneur dans son espace URSSAF :
    # noté révoqué ici aussi, anomalie ouverte.
    private def self.refresh_mandate(transport : Transport, credentials : Credentials, actor : Actor) : Nil
      settings = Settings.current!
      return unless settings.mandate_status == "notified"
      return if transport.mandate_active?(credentials, settings.mandate_ref.to_s)
      settings.mandate_status = "revoked"
      settings.mandate_revoked_at = Time.utc
      settings.save!
      Declarations.log("remote_revoked", settings.mandate_ref.to_s, actor)
      anomaly("mandate_revoked", settings.mandate_ref.to_s)
    end

    private def self.refresh_filings(transport : Transport, credentials : Credentials) : Nil
      Filing.filter(status: "accepted").each do |filing|
        state = transport.declaration_state(credentials, filing.remote_id.to_s)
        known = filing.contributions_total || ZERO
        if state.total != known
          anomaly("contributions_changed", I18n.t("urssaf.anomaly_details.contributions_changed",
            before: known.to_s, after: state.total.to_s), filing.id)
        end
        state.anomalies.each { |text| anomaly("urssaf", text, filing.id) }
      end
    end

    private def self.refresh_payments(transport : Transport, credentials : Credentials, actor : Actor) : Nil
      Payment.filter(status: "initiated").each do |row|
        next if row.remote_id.to_s.empty?
        state = transport.payment_state(credentials, row.remote_id.to_s)
        status = known_status(state.status)
        next if status == row.status
        row.status = status
        row.reason = rejection_reason(state)
        row.save!
        filing = Filing.get!(id: row.filing_id)
        if status == "done"
          Declarations.log("payment_done", "#{row.remote_id} #{row.amount}", actor)
        else
          payment_rejected(row, filing, actor)
        end
      end
    end

    private def self.refresh_sepa(transport : Transport, credentials : Credentials) : Nil
      seen = transport.sepa_mandates(credentials, Declarations.siren).map { |mandate| upsert_sepa(mandate).rum }
      SepaMandateRow.filter(status: "active").each do |row|
        next if seen.includes?(row.rum)
        row.status = "revoked"
        row.revoked_at = Time.utc
        row.save!
      end
    end

    # --- Vue d'ensemble ----------------------------------------------------------------

    def self.overview(today : Time) : ApiT::OverviewView
      filings = Filing.filter(status: "accepted").map { |row| Declarations.filing_view(row) }
      due = filings.sum(ZERO, &.contributions_total)
      paid = filings.sum(ZERO, &.paid_total)
      remaining = filings.sum(ZERO, &.remaining)
      periods = (Declarations.periods(today.year - 1, today) + Declarations.periods(today.year, today))
      start = activity_start(today)
      to_declare = periods.select do |item|
        item.filing.try(&.status) != "accepted" && item.micro_status.in?("due", "late") && item.ends_on >= start
      end
      to_pay = periods.select(&.payable?)
      settings = Settings.current!
      ApiT::OverviewView.new(
        mandate_status: settings.mandate_status.to_s, transport: Transports.current.try(&.name),
        contributions_due: due, paid: paid, remaining: remaining, to_declare: to_declare, to_pay: to_pay,
        anomalies: anomalies, sepa_mandate: sepa_mandates.find(&.status.==("active")),
      )
    end

    # Début du suivi des échéances, comme l'aide URSSAF du module `micro` :
    # début d'activité, à défaut la première recette, à défaut le 1er
    # janvier de l'année en cours (une période à zéro reste à déclarer).
    private def self.activity_start(today : Time) : Time
      system = Partiduo::Api::Actor.system
      Micro.settings(system).activity_started_on ||
        Micro.receipts(system, Micro::RegisterQuery.new(limit: 1)).first?.try(&.date) ||
        Time.utc(today.year, 1, 1)
    end

    # Nombre d'éléments à traiter : périodes à déclarer, cotisations à
    # payer, anomalies ouvertes (compteur du menu).
    def self.pending_count(today : Time) : Int64
      view = overview(today)
      (view.to_declare.size + view.to_pay.size + view.anomalies.size).to_i64
    end
  end
end
