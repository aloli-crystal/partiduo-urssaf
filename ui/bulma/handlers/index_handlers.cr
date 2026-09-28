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
        page("urssaf/index.html", {
          "title"        => I18n.t("urssaf_ui.title"),
          "crumbs"       => [crumb("core.menu.reports"), PartiduoUi::Screen::Crumb.new(I18n.t("urssaf_ui.title"))],
          "year"         => year.to_s,
          "previous_url" => "#{Ui.url("index")}?year=#{year - 1}",
          "next_url"     => "#{Ui.url("index")}?year=#{year + 1}",
          "periods"      => listed(periods.map { |view| Present.period(view, fmt) }),
          "mandate"      => I18n.t(settings.mandate_key),
          "mandate_ok"   => settings.mandate_status == "notified" ? "1" : nil,
          "transport"    => settings.transport,
          "can_transmit" => can?(Api::TRANSMIT) ? "1" : nil,
          "can_settings" => can?(Api::SETTINGS) ? "1" : nil,
          "settings_url" => Ui.url("settings"),
          "estimate_url" => Ui.url("estimate"),
          "declare_url"  => Ui.url("declare"),
          "events"       => listed(Api.events(actor).first(20).map { |event| Present.event(event, fmt) }),
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
