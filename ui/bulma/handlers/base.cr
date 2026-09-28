# SPDX-License-Identifier: AGPL-3.0-or-later

module Urssaf
  module Ui
    # Base des écrans de l'extension. L'accès a déjà été contrôlé par
    # `PartiduoUi::ExtensionHandler` à partir du manifeste ; `Urssaf::Api`
    # vérifie encore la permission de chaque commande.
    abstract class Handler < PartiduoUi::ScreenHandler
      alias Api = Urssaf::Api

      def messages(result) : String
        result.errors.map { |error| fmt.message(error) }.join(" ")
      end

      def flash_result(result, success_key : String) : Nil
        if result.success?
          flash["success"] = I18n.t(success_key)
        else
          flash["danger"] = messages(result)
        end
      end

      def starts_on : Time?
        Time.parse_utc(field("starts_on"), "%Y-%m-%d")
      rescue Time::Format::Error
        nil
      end

      def back_to_year(day : Time?) : Marten::HTTP::Response
        go(day ? "#{Ui.url("index")}?year=#{day.year}" : Ui.url("index"))
      end
    end
  end
end
