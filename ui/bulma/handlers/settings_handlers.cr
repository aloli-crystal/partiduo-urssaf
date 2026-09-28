# SPDX-License-Identifier: AGPL-3.0-or-later

module Urssaf
  module Ui
    # `/ext/URSSAF/settings` : identifiants de l'opérateur (secret jamais
    # réaffiché) et mandat du micro-entrepreneur (recueil, notification,
    # révocation), éligibilité et périodicité relevées.
    class SettingsHandler < Handler
      def get
        require_settings!
        show({} of String => Array(String))
      end

      def post
        require_settings!
        input = Api::CredentialsInput.new(client_id: field("client_id"), client_secret: field("client_secret"),
          env: field("env"))
        result = Api.save_credentials(current.actor, input)
        if result.success?
          flash["success"] = I18n.t("urssaf_ui.flash.credentials")
          return go(Ui.url("settings"))
        end
        show(errors_of(result), 422)
      end

      def show(errors : Hash(String, Array(String)), status : Int32 = 200) : Marten::HTTP::Response
        view = Api.settings(current.actor)
        page("urssaf/settings.html", {
          "title"        => I18n.t("urssaf_ui.settings.title"),
          "crumbs"       => [crumb("core.menu.settings"), PartiduoUi::Screen::Crumb.new(I18n.t("urssaf_ui.settings.title"))],
          "environments" => Api::ENVIRONMENTS.map { |code| Ui.row({"value" => code, "label" => I18n.t("urssaf.environments.#{code}"), "selected" => code == view.env ? "1" : nil}) },
          "settings"     => Ui.row({
            "client_id"     => view.client_id.presence,
            "secret_stored" => view.secret_stored ? "1" : nil,
            "checked_at"    => view.checked_at.try { |time| fmt.datetime(time) },
            "transport"     => view.transport,
            "env"           => I18n.t("urssaf.environments.#{view.env}"),
            "env_code"      => view.env,
            "siren"         => view.siren.presence,
          }),
          "mandate" => Ui.row({
            "status"      => view.mandate_status,
            "label"       => I18n.t(view.mandate_key),
            "signed_on"   => view.mandate_signed_on.try { |day| fmt.date(day) },
            "ref"         => view.mandate_ref.presence,
            "notified_at" => view.mandate_notified_at.try { |time| fmt.datetime(time) },
            "revoked_at"  => view.mandate_revoked_at.try { |time| fmt.datetime(time) },
            "eligible"    => view.eligible.nil? ? nil : I18n.t(view.eligible ? "ui.forms.answer_yes" : "ui.forms.answer_no"),
            "periodicity" => view.periodicity.presence.try { |code| I18n.t("urssaf.periodicities.#{code}") },
            "reason"      => view.eligibility_reason.presence,
            "can_sign"    => view.mandate_status.in?("none", "revoked") ? "1" : nil,
            "can_notify"  => view.mandate_status == "signed" ? "1" : nil,
            "can_revoke"  => view.mandate_status.in?("signed", "notified") ? "1" : nil,
            "today"       => Partiduo::Api::Core.today.to_s("%Y-%m-%d"),
          }),
          "errors" => Ui.row(errors.transform_values { |list| list.join(" ").as(String?) }),
        }, status: status)
      end

      def require_settings! : Nil
        raise Partiduo::Api::Forbidden.new(Api::SETTINGS) unless can?(Api::SETTINGS)
      end
    end

    # Commandes des paramètres : GET renvoie à l'écran.
    abstract class SettingsCommand < SettingsHandler
      def get
        go(Ui.url("settings"))
      end

      def done(result, success_key : String) : Marten::HTTP::Response
        flash_result(result, success_key)
        go(Ui.url("settings"))
      end
    end

    class ClearCredentialsHandler < SettingsCommand
      def post
        Api.clear_credentials(current.actor)
        flash["success"] = I18n.t("urssaf_ui.flash.cleared")
        go(Ui.url("settings"))
      end
    end

    class SignMandateHandler < SettingsCommand
      def post
        signed_on = begin
          Time.parse_utc(field("signed_on"), "%Y-%m-%d")
        rescue Time::Format::Error
          Partiduo::Api::Core.today
        end
        done(Api.sign_mandate(current.actor, Api::MandateInput.new(signed_on, field("accepted") == "1")),
          "urssaf_ui.flash.signed")
      end
    end

    class NotifyMandateHandler < SettingsCommand
      def post
        done(Api.notify_mandate(current.actor), "urssaf_ui.flash.notified")
      end
    end

    class RevokeMandateHandler < SettingsCommand
      def post
        done(Api.revoke_mandate(current.actor), "urssaf_ui.flash.revoked")
      end
    end

    class EligibilityHandler < SettingsCommand
      def post
        done(Api.check_eligibility(current.actor), "urssaf_ui.flash.eligibility")
      end
    end
  end
end
