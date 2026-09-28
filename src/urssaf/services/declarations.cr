# SPDX-License-Identifier: AGPL-3.0-or-later

module Urssaf
  # Mandat, éligibilité, estimation et déclaration du chiffre d'affaires
  # d'un micro-entrepreneur (ADR-007 D7). Le chiffre d'affaires vient du
  # module `micro` (`Partiduo::Api::Micro.declarations`), jamais ressaisi ;
  # la déclaration acceptée est notée dans le module (`mark_declared`). Ne
  # parle au cœur que par `Partiduo::Api` (ADR-006 D3). Interne.
  module Declarations
    alias Micro = Partiduo::Api::Micro
    alias ApiT = Urssaf::Api
    alias FieldError = Partiduo::Api::FieldError

    SYSTEM = Partiduo::Api::Actor.system

    def self.control(key : String, severity : String = "error", params = {} of String => String) : ApiT::ControlView
      ApiT::ControlView.new("urssaf.controls.#{key}", params, severity)
    end

    def self.error(field : String, key : String, params = {} of String => String) : FieldError
      FieldError.new(field, key, params)
    end

    # --- Identifiants et entreprise ------------------------------------------------

    def self.credentials : Credentials?
      settings = Settings.current
      return unless settings
      return if settings.client_id.to_s.empty? || settings.client_secret.to_s.empty?
      Credentials.new(settings.client_id.to_s, Secrets.decrypt(settings.client_secret.to_s), settings.env.to_s)
    rescue Secrets::Error
      nil
    end

    def self.siren : String
      Partiduo::Api::Core.settings(SYSTEM).siren
    end

    # Transport et identifiants, ou l'erreur qui empêche l'appel.
    def self.connection : {Transport, Credentials} | FieldError
      transport = Transports.current
      return error(FieldError::BASE, "urssaf.controls.no_transport") unless transport
      credentials = self.credentials
      return error(FieldError::BASE, "urssaf.controls.no_credentials") unless credentials
      {transport, credentials}
    end

    # --- Périodes ------------------------------------------------------------------

    # Chiffre d'affaires à déclarer, par catégorie, arrondi à l'euro (au
    # plus proche, moitié vers le haut) comme sur le formulaire de
    # l'URSSAF (DECISIONS D-FIN-006).
    def self.turnover(declaration : Micro::DeclarationView) : Hash(String, BigDecimal)
      Config::CATEGORIES.to_h do |category|
        {category, declaration.turnover_of(category).round(0, mode: :ties_away)}
      end
    end

    # Périodes de l'année, lues dans le module `micro` avec l'acteur réel
    # (`micro.register.read` exigé par le module, DECISIONS D-URS-010) ;
    # déclarations et paiements chargés en deux requêtes.
    def self.periods(actor : Partiduo::Api::Actor, year : Int32,
                     today : Time = Partiduo::Config.today) : Array(ApiT::PeriodView)
      settings = Settings.current!
      periodicity = Micro.settings(actor).periodicity
      declarations = Micro.declarations(actor, year, today)
      filings = Filing.filter(starts_on__in: declarations.map(&.starts_on)).to_a
      views = filing_views(filings)
      by_start = filings.index_by(&.starts_on!)
      declarations.map do |declaration|
        filing = by_start[declaration.starts_on]?
        ApiT::PeriodView.new(
          starts_on: declaration.starts_on, ends_on: declaration.ends_on, due_on: declaration.due_on,
          micro_status: declaration.status, turnover: turnover(declaration), estimated_total: declaration.total,
          filing: filing.try { |row| views[row.id!.to_i64]? },
          controls: controls(declaration, filing, settings, periodicity),
        )
      end
    end

    def self.controls(declaration : Micro::DeclarationView, filing : Filing?, settings : Settings,
                      periodicity : String) : Array(ApiT::ControlView)
      list = [] of ApiT::ControlView
      if filing && filing.status == "accepted"
        return [control("already_transmitted", "info", {"reference" => filing.remote_id.to_s})]
      end
      list << control("already_declared") if declaration.status == "declared"
      list << control("period_open") if declaration.status.in?("open", "upcoming")
      list << control("mandate_missing") unless settings.mandate_status == "notified"
      list << control("not_eligible", params: {"reason" => settings.eligibility_reason.to_s}) if settings.eligible == false
      remote_periodicity = settings.periodicity.to_s
      if !remote_periodicity.empty? && remote_periodicity != periodicity
        list << control("periodicity_mismatch", params: {"urssaf" => remote_periodicity, "micro" => periodicity})
      end
      negative = turnover(declaration).select { |_, amount| amount < 0 }.keys
      unless negative.empty?
        list << control("negative_turnover", params: {"categories" => negative.join(", ")})
      end
      unless declaration.missing_rates.empty?
        list << control("missing_rates", "warning", {"rates" => declaration.missing_rates.join(", ")})
      end
      list << control("no_transport", "warning") unless Transports.available?
      list
    end

    def self.period(actor : Partiduo::Api::Actor, starts_on : Time) : Micro::DeclarationView?
      Micro.declarations(actor, starts_on.year).find(&.starts_on.==(starts_on))
    end

    def self.submission(declaration : Micro::DeclarationView, reference : String, mandate_ref : String) : Submission
      Submission.new(reference: reference, siren: siren, mandate_ref: mandate_ref, starts_on: declaration.starts_on,
        ends_on: declaration.ends_on, turnover: turnover(declaration))
    end

    # --- Mandat --------------------------------------------------------------------

    def self.sign!(input : ApiT::MandateInput, actor : Partiduo::Api::Actor) : Partiduo::Api::Result(ApiT::SettingsView)
      result = Partiduo::Api::Result(ApiT::SettingsView)
      settings = Settings.current!
      errors = [] of FieldError
      errors << error("accepted", "urssaf.errors.mandate.accept") unless input.accepted
      errors << error("signed_on", "urssaf.errors.mandate.future") if input.signed_on > Partiduo::Config.today
      errors << error(FieldError::BASE, "urssaf.errors.mandate.active") if settings.mandate_status == "notified"
      errors << error(FieldError::BASE, "urssaf.errors.mandate.siren") if siren.empty?
      return result.failure(errors) unless errors.empty?
      settings.mandate_status = "signed"
      settings.mandate_signed_on = input.signed_on
      settings.mandate_signed_by_id = actor.user_id
      settings.mandate_ref = ""
      settings.mandate_notified_at = nil
      settings.mandate_revoked_at = nil
      settings.updated_by_id = actor.user_id
      settings.save!
      log("signed", input.signed_on.to_s("%Y-%m-%d"), actor)
      result.success(Api.settings_view(settings, true))
    end

    # Notifie le mandat recueilli, puis relève l'éligibilité du compte.
    def self.notify!(actor : Partiduo::Api::Actor) : Partiduo::Api::Result(ApiT::SettingsView)
      result = Partiduo::Api::Result(ApiT::SettingsView)
      settings = Settings.current!
      signed_on = settings.mandate_signed_on
      unless settings.mandate_status == "signed" && signed_on
        return result.failure(error(FieldError::BASE, "urssaf.errors.mandate.not_signed"))
      end
      connection = self.connection
      return result.failure(connection) if connection.is_a?(FieldError)
      transport, credentials = connection
      begin
        settings.mandate_ref = transport.notify_mandate(credentials, siren, signed_on)
        apply_eligibility(settings, transport.eligibility(credentials, siren))
      rescue ex : TransportError
        log("error", ex.key, actor)
        return result.failure(error(FieldError::BASE, ex.key, ex.params))
      end
      settings.mandate_status = "notified"
      settings.mandate_notified_at = Time.utc
      settings.updated_by_id = actor.user_id
      settings.save!
      log("notified", settings.mandate_ref.to_s, actor)
      result.success(Api.settings_view(settings, true))
    end

    def self.revoke!(actor : Partiduo::Api::Actor) : Partiduo::Api::Result(ApiT::SettingsView)
      result = Partiduo::Api::Result(ApiT::SettingsView)
      settings = Settings.current!
      unless settings.mandate_status.in?("signed", "notified")
        return result.failure(error(FieldError::BASE, "urssaf.errors.mandate.none"))
      end
      if settings.mandate_status == "notified"
        connection = self.connection
        return result.failure(connection) if connection.is_a?(FieldError)
        transport, credentials = connection
        begin
          transport.revoke_mandate(credentials, settings.mandate_ref.to_s)
        rescue ex : TransportError
          log("error", ex.key, actor)
          return result.failure(error(FieldError::BASE, ex.key, ex.params))
        end
      end
      settings.mandate_status = "revoked"
      settings.mandate_revoked_at = Time.utc
      settings.updated_by_id = actor.user_id
      settings.save!
      log("revoked", settings.mandate_ref.to_s, actor)
      result.success(Api.settings_view(settings, true))
    end

    def self.check_eligibility!(actor : Partiduo::Api::Actor) : Partiduo::Api::Result(ApiT::SettingsView)
      result = Partiduo::Api::Result(ApiT::SettingsView)
      settings = Settings.current!
      connection = self.connection
      return result.failure(connection) if connection.is_a?(FieldError)
      transport, credentials = connection
      begin
        apply_eligibility(settings, transport.eligibility(credentials, siren))
      rescue ex : TransportError
        log("error", ex.key, actor)
        return result.failure(error(FieldError::BASE, ex.key, ex.params))
      end
      settings.save!
      log("eligibility", {"eligible" => settings.eligible.to_s, "periodicity" => settings.periodicity.to_s}.to_json, actor)
      result.success(Api.settings_view(settings, true))
    end

    private def self.apply_eligibility(settings : Settings, eligibility : Eligibility) : Nil
      settings.eligible = eligibility.eligible
      settings.periodicity = eligibility.periodicity
      settings.eligibility_reason = eligibility.reason
      settings.eligibility_checked_at = Time.utc
    end

    # --- Estimation et déclaration ---------------------------------------------------

    def self.estimate!(starts_on : Time, actor : Partiduo::Api::Actor) : Partiduo::Api::Result(Array(ApiT::ContributionView))
      result = Partiduo::Api::Result(Array(ApiT::ContributionView))
      declaration = period(actor, starts_on)
      return result.failure(error("starts_on", "urssaf.errors.period")) unless declaration
      connection = self.connection
      return result.failure(connection) if connection.is_a?(FieldError)
      transport, credentials = connection
      begin
        contributions = transport.estimate(credentials, submission(declaration, "estimate", Settings.current!.mandate_ref.to_s))
      rescue ex : TransportError
        log("error", ex.key, actor)
        return result.failure(error(FieldError::BASE, ex.key, ex.params))
      end
      log("estimated", starts_on.to_s("%Y-%m-%d"), actor)
      result.success(contributions.map { |item| ApiT::ContributionView.new(item.category, item.turnover, item.amount) })
    end

    # Déclare la période à l'URSSAF, garde l'accusé et les cotisations
    # dues, puis note la déclaration dans le module `micro`. Un rejet de
    # l'URSSAF est conservé avec son motif (nouvelle tentative possible).
    #
    # Idempotente (DECISIONS D-URS-008) : la référence remise à l'URSSAF
    # ne dépend que de la période et du nombre de rejets déjà reçus ; une
    # tentative interrompue (panne après acceptation, échec de
    # l'enregistrement) renvoie la même référence, et l'URSSAF rend le même
    # accusé. Les déclarations d'une même période sont sérialisées (verrou
    # consultatif dans une transaction qui couvre contrôle, appel et
    # enregistrement).
    def self.declare!(starts_on : Time, actor : Partiduo::Api::Actor) : Partiduo::Api::Result(ApiT::PeriodView)
      result = Partiduo::Api::Result(ApiT::PeriodView)
      declaration = period(actor, starts_on)
      return result.failure(error("starts_on", "urssaf.errors.period")) unless declaration
      outcome = serialized("declare:#{declaration.starts_on.to_s("%Y-%m-%d")}") do
        transmit(declaration, actor)
      end
      return result.failure(outcome.errors) if outcome.failure?
      view = periods(actor, starts_on.year).find(&.starts_on.==(declaration.starts_on))
      view ? result.success(view) : result.failure(error("starts_on", "urssaf.errors.period"))
    end

    # Référence de la tentative : `PDUO-URSSAF-<SIREN>-<AAAAMMJJ>-<n>`, `n`
    # = rejets déjà reçus + 1 ; jamais d'horodatage.
    def self.reference(declaration : Micro::DeclarationView, filing : Filing?) : String
      attempt = (filing.try(&.attempts) || 0) + 1
      "PDUO-URSSAF-#{siren}-#{declaration.starts_on.to_s("%Y%m%d")}-#{attempt}"
    end

    private def self.transmit(declaration : Micro::DeclarationView, actor : Partiduo::Api::Actor) : Partiduo::Api::Result(Nil)
      result = Partiduo::Api::Result(Nil)
      settings = Settings.current!
      filing = Filing.filter(starts_on: declaration.starts_on).first
      blocking = controls(declaration, filing, settings, Micro.settings(actor).periodicity).select(&.error?)
      if (existing = filing) && existing.status == "accepted"
        blocking << control("already_transmitted", params: {"reference" => existing.remote_id.to_s})
      end
      unless blocking.empty?
        return result.failure(blocking.map { |item| error(FieldError::BASE, item.key, item.params) })
      end
      connection = self.connection
      return result.failure(connection) if connection.is_a?(FieldError)
      transport, credentials = connection
      sent = submission(declaration, reference(declaration, filing), settings.mandate_ref.to_s)
      begin
        ack = transport.declare(credentials, sent)
      rescue ex : TransportError
        log("error", ex.key, actor)
        if ex.key == "urssaf.errors.transport.rejected"
          save_filing(filing, declaration, sent, nil, ex.params["reason"]? || ex.key, actor)
        end
        return result.failure(error(FieldError::BASE, ex.key, ex.params))
      end
      # L'accusé est gardé d'abord : l'URSSAF a accepté, même si la note
      # dans le module `micro` échoue ensuite (déjà notée à la main).
      receipt_id = store_receipt(ack, sent, actor)
      save_filing(filing, declaration, sent, ack, "", actor, receipt_id)
      log("declared", ack.remote_id, actor)
      marked = Micro.mark_declared(actor, Micro::DeclarationInput.new(declaration.starts_on, Partiduo::Config.today,
        ack.remote_id[0, Math.min(ack.remote_id.size, 100)]))
      log("error", marked.errors.map(&.key).join(", "), actor) if marked.failure?
      result.success(nil)
    end

    # Exécute le bloc dans une transaction, sous un verrou consultatif de
    # PostgreSQL propre à la clé (`urssaf:<clé>`), libéré à la fin de la
    # transaction. Une exception annule tout ; un résultat en échec est
    # gardé (rejet, historique).
    def self.serialized(key : String, & : -> T) : T forall T
      connection = Marten::DB::Connection.default
      value = nil
      connection.transaction do
        connection.open { |db| db.exec("SELECT pg_advisory_xact_lock(hashtext($1))", "urssaf:#{key}") }
        value = yield
      end
      value.as(T)
    end

    # Accusé conservé en pièce jointe du socle : le document rendu par
    # l'URSSAF, sinon un accusé texte établi d'après sa réponse. Un refus
    # du socle n'empêche pas de garder la déclaration (journalisé).
    def self.store_receipt(ack : Acknowledgement, sent : Submission, actor : Partiduo::Api::Actor) : Int64?
      receipt = ack.receipt || text_receipt(ack, sent)
      input = Partiduo::Api::Core::AttachmentInput.new(receipt.filename, receipt.content_type, IO::Memory.new(receipt.content))
      stored = Partiduo::Api::Core.store_attachment(SYSTEM, input)
      if stored.failure?
        log("error", stored.errors.map(&.key).join(", "), actor)
        return
      end
      stored.value!.id
    end

    def self.text_receipt(ack : Acknowledgement, sent : Submission) : Receipt
      lines = [
        I18n.t("urssaf.receipt.title"),
        I18n.t("urssaf.receipt.number", number: ack.remote_id),
        I18n.t("urssaf.receipt.siren", siren: sent.siren),
        I18n.t("urssaf.receipt.period", starts_on: sent.starts_on.to_s("%Y-%m-%d"), ends_on: sent.ends_on.to_s("%Y-%m-%d")),
      ]
      sent.turnover.each do |category, amount|
        lines << I18n.t("urssaf.receipt.turnover", category: I18n.t("micro.categories.#{category}"), amount: amount.to_s)
      end
      ack.contributions.each do |item|
        lines << I18n.t("urssaf.receipt.contribution", category: I18n.t("micro.categories.#{item.category}"), amount: item.amount.to_s)
      end
      lines << I18n.t("urssaf.receipt.total", amount: ack.total.to_s)
      ack.due_on.try { |day| lines << I18n.t("urssaf.receipt.due_on", date: day.to_s("%Y-%m-%d")) }
      lines << I18n.t("urssaf.receipt.transmitted_at", at: Time.utc.to_s("%Y-%m-%dT%H:%M:%SZ"))
      Receipt.new("accuse-urssaf-#{ack.remote_id.gsub(/[^A-Za-z0-9_-]/, "_")}.txt", "text/plain", (lines.join("\n") + "\n").to_slice)
    end

    private def self.save_filing(filing : Filing?, declaration : Micro::DeclarationView, sent : Submission,
                                 ack : Acknowledgement?, reason : String, actor : Partiduo::Api::Actor,
                                 receipt_id : Int64? = nil) : Nil
      row = filing || Filing.new(starts_on: declaration.starts_on)
      row.ends_on = declaration.ends_on
      row.turnover = sent.turnover.transform_values(&.to_s).to_json
      row.status = ack ? "accepted" : "rejected"
      row.remote_id = ack.try(&.remote_id) || ""
      row.contributions = (ack.try(&.contributions) || [] of Contribution).map do |item|
        {"category" => item.category, "turnover" => item.turnover.to_s, "amount" => item.amount.to_s}
      end.to_json
      row.contributions_total = ack.try(&.total) || BigDecimal.new(0)
      row.payment_due_on = ack.try(&.due_on)
      row.reason = reason
      row.transmitted_at = Time.utc
      row.transmitted_by_id = actor.user_id
      row.receipt_attachment_id = receipt_id
      row.attempts = (row.attempts || 0) + 1 unless ack
      row.save!
      return if ack
      log("rejected", reason, actor)
      FollowUp.anomaly("rejected", reason, row.id)
    end

    # --- Vues et historique ------------------------------------------------------------

    def self.filing_view(row : Filing) : ApiT::FilingView
      filing_views([row])[row.id!.to_i64]
    end

    # Vues des déclarations, paiements chargés en une requête.
    def self.filing_views(rows : Array(Filing)) : Hash(Int64, ApiT::FilingView)
      payments = FollowUp.payments_by_filing(rows)
      rows.to_h do |row|
        id = row.id!.to_i64
        turnover = Hash(String, String).from_json(row.turnover.to_s).transform_values { |value| BigDecimal.new(value) }
        contributions = Array(Hash(String, String)).from_json(row.contributions.to_s).map do |item|
          ApiT::ContributionView.new(item["category"], BigDecimal.new(item["turnover"]), BigDecimal.new(item["amount"]))
        end
        {id, ApiT::FilingView.new(status: row.status.to_s, remote_id: row.remote_id.to_s, turnover: turnover,
          contributions: contributions, contributions_total: row.contributions_total || BigDecimal.new(0),
          payment_due_on: row.payment_due_on, reason: row.reason.to_s, transmitted_at: row.transmitted_at!,
          receipt_attachment_id: row.receipt_attachment_id.try(&.to_i64), payments: payments[id]? || [] of ApiT::PaymentView)}
      end
    end

    def self.log(action : String, detail : String, actor : Partiduo::Api::Actor) : Nil
      Event.create!(action: action, detail: detail[0, Math.min(detail.size, 2000)], user_id: actor.user_id,
        created_at: Time.utc)
    end

    # Historique, du plus récent au plus ancien ; `limit` appliqué en SQL.
    def self.events(limit : Int32? = nil) : Array(ApiT::EventView)
      rows = Event.all.order("-id")
      rows = rows.limit(limit) if limit
      rows.map do |event|
        ApiT::EventView.new(event.action.to_s, event.detail.to_s, event.user_id.try(&.as(Int).to_i64), event.created_at!)
      end
    end
  end
end
