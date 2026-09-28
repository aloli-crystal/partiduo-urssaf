# SPDX-License-Identifier: AGPL-3.0-or-later

module Urssaf
  # Contrat public de l'extension, sur le modèle de `Partiduo::Api`
  # (DECISIONS C2) : acteur en premier argument, contrôle d'accès en
  # première ligne, objets de vue immuables ; `ModuleDisabled` si
  # l'extension est inactive. L'interface (`ui/bulma/`) ne voit que ce
  # module. Documentation : `doc/api/urssaf.adoc`.
  module Api
    alias Actor = Partiduo::Api::Actor
    alias Guard = Partiduo::Api::Guard
    alias FieldError = Partiduo::Api::FieldError
    alias Result = Partiduo::Api::Result

    MODULE_CODE = Urssaf::CODE
    READ        = "urssaf.declaration.read"
    TRANSMIT    = "urssaf.declaration.transmit"
    SETTINGS    = "urssaf.settings.manage"

    STATUSES         = Config::STATUSES
    ENVIRONMENTS     = Config::ENVIRONMENTS
    MANDATE_STATUSES = Config::MANDATE_STATUSES
    CATEGORIES       = Config::CATEGORIES

    # --- Paramètres et mandat ------------------------------------------------------

    def self.settings(actor : Actor) : SettingsView
      Guard.authorize!(actor, READ, module_code: MODULE_CODE)
      settings_view(Settings.current!, actor.can?(SETTINGS))
    end

    def self.settings_view(settings : Settings, manager : Bool) : SettingsView
      SettingsView.new(
        env: settings.env.to_s, client_id: manager ? settings.client_id.to_s : "",
        secret_stored: !settings.client_secret.to_s.empty?, checked_at: settings.checked_at,
        transport: Transports.current.try(&.name), siren: Declarations.siren,
        mandate_status: settings.mandate_status.to_s, mandate_signed_on: settings.mandate_signed_on,
        mandate_ref: settings.mandate_ref.to_s, mandate_notified_at: settings.mandate_notified_at,
        mandate_revoked_at: settings.mandate_revoked_at, eligible: settings.eligible,
        periodicity: settings.periodicity.to_s, eligibility_reason: settings.eligibility_reason.to_s,
        eligibility_checked_at: settings.eligibility_checked_at,
      )
    end

    # Identifiants de l'opérateur, secret chiffré ; vérifiés auprès de
    # l'URSSAF si le transport est branché. Un secret vide garde celui
    # enregistré.
    def self.save_credentials(actor : Actor, input : CredentialsInput) : Result(SettingsView)
      Guard.authorize!(actor, SETTINGS, module_code: MODULE_CODE)
      settings = Settings.current!
      errors = [] of FieldError
      client_id = input.client_id.strip
      errors << FieldError.new("client_id", "urssaf.errors.credentials.client_id") if client_id.empty? || client_id.size > 255
      errors << FieldError.new("env", "urssaf.errors.credentials.env") unless ENVIRONMENTS.includes?(input.env)
      secret = input.client_secret.strip
      if secret.empty? && !settings.client_secret.to_s.empty?
        begin
          secret = Secrets.decrypt(settings.client_secret.to_s)
        rescue Secrets::Error
          errors << FieldError.new("client_secret", "urssaf.errors.credentials.unreadable")
        end
      end
      if secret.empty? && errors.none?(&.field.==("client_secret"))
        errors << FieldError.new("client_secret", "urssaf.errors.credentials.client_secret")
      end
      return Result(SettingsView).failure(errors) unless errors.empty?

      checked = nil
      if transport = Transports.current
        begin
          transport.check(Credentials.new(client_id, secret, input.env))
          checked = Time.utc
        rescue ex : TransportError
          return Result(SettingsView).failure(FieldError.new("client_secret", ex.key, ex.params))
        end
      end
      settings.client_id = client_id
      settings.client_secret = Secrets.encrypt(secret)
      settings.env = input.env
      settings.checked_at = checked
      settings.updated_by_id = actor.user_id
      settings.save!
      Result(SettingsView).success(settings_view(settings, true))
    end

    def self.clear_credentials(actor : Actor) : SettingsView
      Guard.authorize!(actor, SETTINGS, module_code: MODULE_CODE)
      settings = Settings.current!
      settings.client_id = ""
      settings.client_secret = ""
      settings.checked_at = nil
      settings.updated_by_id = actor.user_id
      settings.save!
      settings_view(settings, true)
    end

    # Mandat recueilli dans Partiduo : date de signature, termes acceptés.
    def self.sign_mandate(actor : Actor, input : MandateInput) : Result(SettingsView)
      Guard.authorize!(actor, SETTINGS, module_code: MODULE_CODE)
      Declarations.sign!(input, actor)
    end

    # Notifie le mandat à l'URSSAF, puis relève l'éligibilité et la
    # périodicité du compte.
    def self.notify_mandate(actor : Actor) : Result(SettingsView)
      Guard.authorize!(actor, SETTINGS, module_code: MODULE_CODE)
      Declarations.notify!(actor)
    end

    # Révoque le mandat (notifié : auprès de l'URSSAF aussi).
    def self.revoke_mandate(actor : Actor) : Result(SettingsView)
      Guard.authorize!(actor, SETTINGS, module_code: MODULE_CODE)
      Declarations.revoke!(actor)
    end

    def self.check_eligibility(actor : Actor) : Result(SettingsView)
      Guard.authorize!(actor, SETTINGS, module_code: MODULE_CODE)
      Declarations.check_eligibility!(actor)
    end

    # --- Périodes et déclarations ----------------------------------------------------

    # Périodes de l'année (périodicité du module `micro`), chiffre
    # d'affaires à déclarer, déclaration transmise, contrôles.
    def self.periods(actor : Actor, year : Int32, today : Time = Partiduo::Config.today) : Array(PeriodView)
      Guard.authorize!(actor, READ, module_code: MODULE_CODE)
      Declarations.periods(year, today)
    end

    # Cotisations calculées par l'URSSAF pour la période, sans rien déclarer.
    def self.estimate(actor : Actor, starts_on : Time) : Result(Array(ContributionView))
      Guard.authorize!(actor, TRANSMIT, module_code: MODULE_CODE)
      Declarations.estimate!(starts_on, actor)
    end

    # Déclare la période à l'URSSAF. Refus : période en cours, déjà
    # déclarée (ici ou à la main), mandat non notifié, compte non éligible,
    # périodicité différente de celle du module, transport ou identifiants
    # absents ; rejet de l'URSSAF (motif conservé).
    def self.declare(actor : Actor, starts_on : Time) : Result(PeriodView)
      Guard.authorize!(actor, TRANSMIT, module_code: MODULE_CODE)
      Declarations.declare!(starts_on, actor)
    end

    def self.events(actor : Actor) : Array(EventView)
      Guard.authorize!(actor, READ, module_code: MODULE_CODE)
      Declarations.events
    end
  end
end
