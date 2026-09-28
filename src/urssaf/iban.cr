# SPDX-License-Identifier: AGPL-3.0-or-later

module Urssaf
  # IBAN d'un mandat SEPA : forme normalisée, contrôle (longueur, clé
  # modulo 97, ISO 13616) et forme masquée, la seule conservée ou affichée.
  module Iban
    def self.normalize(value : String) : String
      value.gsub(/\s+/, "").upcase
    end

    def self.valid?(value : String) : Bool
      iban = normalize(value)
      return false unless iban.matches?(/\A[A-Z]{2}[0-9]{2}[A-Z0-9]{11,30}\z/)
      digits = (iban[4..] + iban[0, 4]).each_char.map { |char| char.ascii_letter? ? (char.ord - 55).to_s : char.to_s }.join
      digits.each_char.reduce(0) { |rest, char| (rest * 10 + char.to_i) % 97 } == 1
    end

    # `FR76 **** **** 1234` : pays, clé et quatre derniers caractères.
    def self.mask(value : String) : String
      iban = normalize(value)
      return "****" if iban.size < 8
      "#{iban[0, 4]} **** **** #{iban[-4..]}"
    end

    # BIC (ISO 9362) : vide ou 8 / 11 caractères.
    def self.valid_bic?(value : String) : Bool
      bic = normalize(value)
      bic.empty? || bic.matches?(/\A[A-Z]{4}[A-Z]{2}[A-Z0-9]{2}([A-Z0-9]{3})?\z/)
    end
  end
end
