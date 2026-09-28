# SPDX-License-Identifier: AGPL-3.0-or-later

module Urssaf
  # Paramètres de l'extension (ligne unique, `key = "default"`) :
  # environnement, identifiants de l'opérateur (secret chiffré), mandat du
  # micro-entrepreneur (état, signataire, dates, référence chez l'URSSAF),
  # éligibilité relevée. Interne.
  class Settings < Marten::Model
    field :id, :big_int, primary_key: true, auto: true
    field :key, :string, max_size: 16, unique: true, default: "default"
    field :env, :string, max_size: 16, default: "sandbox"
    field :client_id, :string, max_size: 255, blank: true, default: ""
    field :client_secret, :text, blank: true, default: ""
    field :checked_at, :date_time, blank: true, null: true
    field :mandate_status, :string, max_size: 16, default: "none"
    field :mandate_signed_on, :date, blank: true, null: true
    field :mandate_signed_by_id, :big_int, blank: true, null: true
    field :mandate_ref, :string, max_size: 128, blank: true, default: ""
    field :mandate_notified_at, :date_time, blank: true, null: true
    field :mandate_revoked_at, :date_time, blank: true, null: true
    field :eligible, :bool, blank: true, null: true
    field :periodicity, :string, max_size: 16, blank: true, default: ""
    field :eligibility_reason, :text, blank: true, default: ""
    field :eligibility_checked_at, :date_time, blank: true, null: true
    field :updated_by_id, :big_int, blank: true, null: true

    with_timestamp_fields

    def self.current : Settings?
      filter(key: "default").first
    end

    def self.current! : Settings
      current || new(key: "default")
    end
  end
end
