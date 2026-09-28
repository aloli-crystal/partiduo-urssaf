# SPDX-License-Identifier: AGPL-3.0-or-later

require "base64"
require "http/client"
require "json"
require "uri"

module Urssaf
  # Jeton OAuth 2 _client credentials_ (RFC 6749 § 4.4) de l'application de
  # l'opérateur, tiers déclarant : demandé au point de jeton du portail de
  # l'URSSAF, gardé en mémoire jusqu'à une minute de son échéance, oublié
  # sur un refus 401 (`forget`). Brique de l'adaptateur réel (BLOCAGES
  # B-FIN-003) ; le point de jeton et la portée viennent de la
  # documentation remise à la souscription, jamais écrits en dur.
  #
  # Aucun secret dans les erreurs ni les journaux : les erreurs portent une
  # clé i18n (`urssaf.errors.transport.*`) et le code HTTP.
  class OAuth2
    # Échanges HTTP (POST de formulaire), remplaçables dans les specs.
    abstract class Http
      record Response, status : Int32, body : String

      abstract def post(url : String, headers : HTTP::Headers, body : String) : Response
    end

    # HTTP réel : HTTPS seulement, TLS vérifié, délais de 30 secondes.
    class NetHttp < Http
      TIMEOUT = 30.seconds

      def post(url : String, headers : HTTP::Headers, body : String) : Response
        uri = URI.parse(url)
        raise TransportError.new("urssaf.errors.transport.unavailable", message: "adresse non HTTPS") unless uri.scheme == "https"
        client = HTTP::Client.new(uri)
        client.connect_timeout = TIMEOUT
        client.read_timeout = TIMEOUT
        begin
          response = client.post(uri.request_target, headers: headers, body: body)
          Response.new(response.status_code, response.body)
        ensure
          client.close
        end
      rescue ex : IO::Error | Socket::Error | OpenSSL::Error
        raise TransportError.new("urssaf.errors.transport.unavailable", message: "réseau : #{ex.class}")
      end
    end

    record Token, value : String, expires_at : Time

    MARGIN = 60.seconds

    getter token_url : String
    getter scope : String

    def initialize(@token_url : String, @scope : String = "", @http : Http = NetHttp.new)
      @tokens = {} of String => Token
      @mutex = Mutex.new
    end

    # Jeton valide pour ces identifiants, demandé au besoin.
    def token(credentials : Credentials, now : Time = Time.utc) : String
      key = cache_key(credentials)
      @mutex.synchronize do
        cached = @tokens[key]?
        return cached.value if cached && cached.expires_at - MARGIN > now
        fresh = request(credentials, now)
        @tokens[key] = fresh
        fresh.value
      end
    end

    # Oublie le jeton (refus 401 : identifiants changés ou jeton révoqué).
    def forget(credentials : Credentials) : Nil
      @mutex.synchronize { @tokens.delete(cache_key(credentials)) }
      nil
    end

    private def request(credentials : Credentials, now : Time) : Token
      form = URI::Params.build do |params|
        params.add "grant_type", "client_credentials"
        params.add "scope", scope unless scope.empty?
      end
      headers = HTTP::Headers{
        "Content-Type"  => "application/x-www-form-urlencoded",
        "Accept"        => "application/json",
        "Authorization" => "Basic #{Base64.strict_encode("#{URI.encode_www_form(credentials.client_id)}:#{URI.encode_www_form(credentials.client_secret)}")}",
      }
      response = @http.post(token_url, headers, form)
      if response.status.in?(400, 401, 403)
        raise TransportError.new("urssaf.errors.transport.credentials", message: "jeton refusé (HTTP #{response.status})")
      end
      unless response.status == 200
        raise TransportError.new("urssaf.errors.transport.unavailable", message: "jeton : HTTP #{response.status}")
      end
      body = JSON.parse(response.body)
      value = body["access_token"]?.try(&.as_s?) || ""
      raise TransportError.new("urssaf.errors.transport.unavailable", message: "jeton absent de la réponse") if value.empty?
      lifetime = body["expires_in"]?.try { |item| item.as_i64? || item.as_s?.try(&.to_i64?) } || 300_i64
      Token.new(value, now + lifetime.seconds)
    rescue JSON::ParseException
      raise TransportError.new("urssaf.errors.transport.unavailable", message: "jeton : réponse illisible")
    end

    # Clé du cache : identifiant, environnement et empreinte du secret
    # (le secret lui-même n'est pas gardé en clé).
    private def cache_key(credentials : Credentials) : String
      digest = OpenSSL::Digest.new("SHA256").update(credentials.client_secret).final.hexstring
      "#{credentials.env}:#{credentials.client_id}:#{digest}"
    end
  end
end
