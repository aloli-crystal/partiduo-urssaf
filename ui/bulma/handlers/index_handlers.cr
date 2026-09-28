# SPDX-License-Identifier: AGPL-3.0-or-later

module Urssaf
  module Ui
    # `/ext/URSSAF/` : périodes de l'année (périodicité du module `micro`),
    # chiffre d'affaires à déclarer, cotisations estimées par Partiduo et
    # dues selon l'URSSAF, état du mandat, estimation, déclaration.
    class IndexHandler < Handler
      def get
        actor = current.actor
        today = Partiduo::Api::Core.today
        year = query("year").to_i? || today.year
        settings = Api.settings(actor)
        periods = Api.periods(actor, year)
        overview = Api.overview(actor, today)
        sepa = overview.sepa_mandate
        page("urssaf/index.html", {
          "title"        => I18n.t("urssaf_ui.title"),
          "crumbs"       => urssaf_crumbs,
          "year"         => year.to_s,
          "previous_url" => "#{Ui.url("index")}?year=#{year - 1}",
          "next_url"     => "#{Ui.url("index")}?year=#{year + 1}",
          "periods"      => listed(periods.map { |view| Present.period(view, fmt) }),
          "mandate"      => I18n.t(settings.mandate_key),
          "mandate_ok"   => settings.mandate_status == "notified" ? "1" : nil,
          "transport"    => settings.transport,
          "can_transmit" => can?(Api::TRANSMIT) ? "1" : nil,
          "can_pay"      => can?(Api::PAY) ? "1" : nil,
          "can_settings" => can?(Api::SETTINGS) ? "1" : nil,
          "settings_url" => Ui.url("settings"),
          "estimate_url" => Ui.url("estimate"),
          "declare_url"  => Ui.url("declare"),
          "pay_url"      => Ui.url("pay"),
          "refresh_url"  => Ui.url("refresh"),
          "resolve_url"  => Ui.url("resolve_anomaly"),
          "sepa_url"     => Ui.url("register_sepa"),
          "revoke_sepa"  => Ui.url("revoke_sepa"),
          "summary"      => Ui.row({
            "due"        => fmt.amount(overview.contributions_due),
            "paid"       => fmt.amount(overview.paid),
            "remaining"  => fmt.amount(overview.remaining),
            "to_declare" => overview.to_declare.size.to_s,
            "to_pay"     => overview.to_pay.size.to_s,
          }),
          "anomalies"    => listed(overview.anomalies.map { |item| Present.anomaly(item, fmt) }),
          "sepa"         => sepa.try { |item| Present.sepa(item, fmt) },
          "today"        => today.to_s("%Y-%m-%d"),
          "payments"     => listed(Api.payments(actor).first(20).map { |item| Present.payment(item, fmt) }),
          "events"       => listed(Api.events(actor).first(20).map { |event| Present.event(event, fmt) }),
          "micro_urssaf" => can?("micro.register.read") ? reverse("micro:urssaf") : nil,
        })
      end
    end

    class EstimateHandler < Handler
      def get
        go(Ui.url("index"))
      end

      def post
        day = starts_on
        return back_to_year(nil) unless day
        result = Api.estimate(current.actor, day)
        if contributions = result.value?
          lines = contributions.map { |item| "#{I18n.t(item.category_key)} : #{fmt.amount(item.amount)}" }
          total = contributions.sum(BigDecimal.new(0), &.amount)
          flash["info"] = I18n.t("urssaf_ui.flash.estimated", total: fmt.amount(total), detail: lines.join(" · "))
        else
          flash["danger"] = messages(result)
        end
        back_to_year(day)
      end
    end

    class DeclareHandler < Handler
      def get
        go(Ui.url("index"))
      end

      def post
        day = starts_on
        return back_to_year(nil) unless day
        flash_result(Api.declare(current.actor, day), "urssaf_ui.flash.declared")
        back_to_year(day)
      end
    end
  end
end

module Urssaf
  module Ui
    # Télépaiement SEPA du reste dû d'une période déclarée.
    class PayHandler < Handler
      def get
        go(Ui.url("index"))
      end

      def post
        day = starts_on
        return back_to_year(nil) unless day
        result = Api.pay(current.actor, day)
        if payment = result.value?
          flash["success"] = I18n.t("urssaf_ui.flash.paid", amount: fmt.amount(payment.amount))
        else
          flash["danger"] = messages(result)
        end
        back_to_year(day)
      end
    end

    # Relevé auprès de l'URSSAF : mandat, déclarations, paiements, mandats
    # SEPA, anomalies.
    class RefreshHandler < Handler
      def get
        go(Ui.url("index"))
      end

      def post
        result = Api.refresh(current.actor)
        if count = result.value?
          flash["info"] = I18n.t("urssaf_ui.flash.refreshed", count: count)
        else
          flash["danger"] = messages(result)
        end
        go(Ui.url("index"))
      end
    end

    # Accusé de la déclaration d'une période (pièce jointe), en
    # téléchargement.
    class ReceiptHandler < Handler
      def get
        day = begin
          Time.parse_utc(query("starts_on"), "%Y-%m-%d")
        rescue Time::Format::Error
          nil
        end
        return back_to_year(nil) unless day
        receipt = Api.receipt(current.actor, day)
        response = Marten::HTTP::Response.new(content: String.new(receipt.content), content_type: receipt.content_type)
        response["Content-Disposition"] = %(attachment; filename="#{receipt.filename.gsub('"', "")}")
        response["X-Content-Type-Options"] = "nosniff"
        response
      end
    end

    class ResolveAnomalyHandler < Handler
      def get
        go(Ui.url("index"))
      end

      def post
        flash_result(Api.resolve_anomaly(current.actor, field("id").to_i64? || 0_i64), "urssaf_ui.flash.resolved")
        go(Ui.url("index"))
      end
    end

    # Mandat de prélèvement SEPA : IBAN transmis à l'URSSAF, jamais
    # réaffiché (le formulaire refusé est vidé).
    class RegisterSepaHandler < Handler
      def get
        go(Ui.url("index"))
      end

      def post
        signed_on = begin
          Time.parse_utc(field("signed_on"), "%Y-%m-%d")
        rescue Time::Format::Error
          Partiduo::Api::Core.today
        end
        input = Api::SepaMandateInput.new(iban: field("iban"), bic: field("bic"), holder: field("holder"),
          signed_on: signed_on, accepted: field("accepted") == "1")
        flash_result(Api.register_sepa_mandate(current.actor, input), "urssaf_ui.flash.sepa_registered")
        go(Ui.url("index"))
      end
    end

    class RevokeSepaHandler < Handler
      def get
        go(Ui.url("index"))
      end

      def post
        flash_result(Api.revoke_sepa_mandate(current.actor, field("rum")), "urssaf_ui.flash.sepa_revoked")
        go(Ui.url("index"))
      end
    end
  end
end
