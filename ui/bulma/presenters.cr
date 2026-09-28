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
        error = Partiduo::Api::FieldError.new(Partiduo::Api::FieldError::BASE, control.key, control.params)
        Ui.row({"message" => fmt.message(error), "error" => control.error? ? "1" : nil})
      end

      def self.period(view : Api::PeriodView, fmt : PartiduoUi::Format) : Row
        filing = view.filing
        Ui.row({
          "starts_on"    => view.starts_on.to_s("%Y-%m-%d"),
          "period"       => "#{fmt.date(view.starts_on)} – #{fmt.date(view.ends_on)}",
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
          "controls"     => view.controls.map { |control| fmt.message(Partiduo::Api::FieldError.new("base", control.key, control.params)) }.join(" "),
          "ready"        => view.transmittable? && (filing.nil? || filing.status == "rejected") ? "1" : nil,
        })
      end

      def self.event(event : Api::EventView, fmt : PartiduoUi::Format) : Row
        detail = event.detail
        detail = I18n.t(detail) if detail.starts_with?("urssaf.") || detail.starts_with?("micro.")
        Ui.row({"at" => fmt.datetime(event.created_at), "action" => I18n.t(event.action_key), "detail" => detail.presence})
      end
    end
  end
end
