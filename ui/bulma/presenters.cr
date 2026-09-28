# SPDX-License-Identifier: AGPL-3.0-or-later

module Urssaf
  module Ui
    # Ligne présentée à un gabarit : textes déjà mis en forme, par nom (un
    # grand `Hash` n'est pas lu par les gabarits Marten, BLOCAGES
    # B-EINV-001).
    class Row
      include Marten::Template::Object

      getter values : Hash(String, String?)

      def initialize(@values : Hash(String, String?))
      end

      def resolve_template_attribute(key : String)
        values[key]?
      end
    end

    def self.row(values : Hash(String, String?)) : Row
      Row.new(values)
    end

    def self.row(values : Hash(String, String)) : Row
      Row.new(values.transform_values(&.as(String?)))
    end

    def self.url(name : String, **params) : String
      Marten.routes.reverse("urssaf:#{name}", **params)
    end

    module Present
      alias Api = Urssaf::Api

      def self.control(control : Api::ControlView, fmt : PartiduoUi::Format) : Row
        Ui.row({"message" => control_message(control, fmt), "error" => control.error? ? "1" : nil})
      end

      # Message d'un contrôle, codes (catégories, périodicités) traduits.
      def self.control_message(control : Api::ControlView, fmt : PartiduoUi::Format) : String
        params = control.params.to_h { |name, value| {name, coded(name, value)} }
        fmt.message(Partiduo::Api::FieldError.new(Partiduo::Api::FieldError::BASE, control.key, params))
      end

      def self.period(view : Api::PeriodView, fmt : PartiduoUi::Format) : Row
        filing = view.filing
        Ui.row({
          "starts_on"    => view.starts_on.to_s("%Y-%m-%d"),
          "period"       => I18n.t("urssaf_ui.period_range", from: fmt.date(view.starts_on), to: fmt.date(view.ends_on)),
          "due_on"       => fmt.date(view.due_on),
          "turnover"     => fmt.amount(view.total_turnover, 0),
          "estimated"    => fmt.amount(view.estimated_total),
          "micro_status" => I18n.t("micro.declaration_statuses.#{view.micro_status}"),
          "status"       => filing.try(&.status),
          "status_label" => filing.try { |row| I18n.t(row.status_key) },
          "remote_id"    => filing.try(&.remote_id.presence),
          "due"          => filing.try { |row| fmt.amount(row.contributions_total) },
          "payment_due"  => filing.try(&.payment_due_on).try { |day| fmt.date(day) },
          "reason"       => filing.try(&.reason.presence),
          "controls"     => view.controls.map { |control| control_message(control, fmt) }.join(" "),
          "ready"        => view.transmittable? && (filing.nil? || filing.status == "rejected") ? "1" : nil,
          "payable"      => view.payable? ? "1" : nil,
          "remaining"    => filing.try { |row| row.status == "accepted" ? fmt.amount(row.remaining) : nil },
          "paid"         => filing.try { |row| row.paid_total.zero? ? nil : fmt.amount(row.paid_total) },
          "receipt_url"  => filing.try { |row| row.receipt? ? "#{Ui.url("receipt")}?starts_on=#{view.starts_on.to_s("%Y-%m-%d")}" : nil },
        })
      end

      def self.payment(view : Api::PaymentView, fmt : PartiduoUi::Format) : Row
        Ui.row({
          "at"           => fmt.datetime(view.created_at),
          "period"       => fmt.date(view.starts_on),
          "remote_id"    => view.remote_id.presence,
          "amount"       => fmt.amount(view.amount),
          "rum"          => view.sepa_rum,
          "status"       => view.status,
          "status_label" => I18n.t(view.status_key),
          "reason"       => view.reason.presence,
        })
      end

      def self.anomaly(view : Api::AnomalyView, fmt : PartiduoUi::Format) : Row
        Ui.row({
          "id"     => view.id.to_s,
          "code"   => view.code,
          "label"  => I18n.t(view.code_key),
          "detail" => detail("urssaf.anomaly_details.#{view.code}", view.detail, fmt),
          "period" => view.starts_on.try { |day| fmt.date(day) },
          "at"     => fmt.datetime(view.created_at),
        })
      end

      def self.sepa(view : Api::SepaMandateView, fmt : PartiduoUi::Format) : Row
        Ui.row({
          "rum"          => view.rum,
          "iban"         => view.iban_masked,
          "holder"       => view.holder,
          "status"       => view.status,
          "status_label" => I18n.t(view.status_key),
          "signed_on"    => fmt.date(view.signed_on),
        })
      end

      def self.event(event : Api::EventView, fmt : PartiduoUi::Format) : Row
        detail = event.detail
        detail = if detail.starts_with?("urssaf.") || detail.starts_with?("micro.")
                   I18n.t(detail)
                 else
                   detail("urssaf.event_details.#{event.action}", detail, fmt)
                 end
        Ui.row({"at" => fmt.datetime(event.created_at), "action" => I18n.t(event.action_key), "detail" => detail.presence})
      end

      # Détail neutre enregistré par le métier (DECISIONS D-URS-011) : un
      # objet JSON de chaînes est traduit par `key` dans la langue du
      # lecteur, montants et dates mis en forme, codes traduits ; tout
      # autre texte (motif de l'URSSAF) est rendu tel quel.
      def self.detail(key : String, raw : String, fmt : PartiduoUi::Format) : String?
        return raw.presence unless raw.starts_with?('{')
        params = Hash(String, String).from_json(raw).to_h do |name, value|
          {name, coded(name, value)}
        end
        fmt.message(Partiduo::Api::FieldError.new(Partiduo::Api::FieldError::BASE, key, params))
      rescue JSON::ParseException | TypeCastError
        raw.presence
      end

      private def self.coded(name : String, value : String) : String
        case name
        when "eligible"    then I18n.t("urssaf_ui.eligible.#{value.presence || "unknown"}")
        when "periodicity" then value.empty? ? "—" : I18n.t("urssaf.periodicities.#{value}")
        when "code"        then I18n.t("urssaf.anomalies.#{value}")
        when "categories"  then value.split(", ").map { |category| I18n.t("micro.categories.#{category}") }.join(", ")
        else                    value
        end
      end
    end
  end
end
