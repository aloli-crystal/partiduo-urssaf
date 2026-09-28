# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"
require "../../lib/partiduo-ui-bulma/scripts/api_boundary"

private def source_files(pattern : String) : Array(String)
  Dir.glob(File.join(Urssaf::SpecSupport::ROOT, pattern)).reject(&.includes?("/lib/")).sort!
end

private def flatten_keys(value : YAML::Any, prefix : String = "") : Array(String)
  if hash = value.as_h?
    hash.flat_map { |key, child| flatten_keys(child, prefix.empty? ? key.as_s : "#{prefix}.#{key.as_s}") }
  else
    [prefix]
  end
end

describe "Conventions de l'extension URSSAF" do
  it "ouvre chaque fichier source par l'en-tête SPDX" do
    missing = (source_files("{src,ui,spec,config,scripts}/**/*.{cr,sh}") + source_files("*.cr")).reject do |path|
      lines = File.read_lines(path)
      (path.ends_with?(".sh") ? lines[1]? : lines.first?) == "# SPDX-License-Identifier: AGPL-3.0-or-later"
    end
    missing += source_files("ui/**/*.html").reject do |path|
      File.read(path).starts_with?("{# SPDX-License-Identifier: AGPL-3.0-or-later")
    end
    missing.should be_empty
  end

  it "a les mêmes clés de traduction en fr, en et nl" do
    %w[src/urssaf/locales ui/bulma/locales].each do |dir|
      keys = Partiduo::LOCALES.to_h do |locale|
        tree = YAML.parse(File.read(File.join(Urssaf::SpecSupport::ROOT, dir, "#{locale}.yml")))
        {locale, flatten_keys(tree[locale]).sort}
      end
      keys["en"].should eq(keys["fr"])
      keys["nl"].should eq(keys["fr"])
    end
  end

  it "traduit toute clé citée par le code et les gabarits de l'extension" do
    cited = source_files("{src,ui}/**/*.{cr,html}").flat_map do |path|
      File.read(path).scan(/["'](urssaf(?:_ui)?\.[a-z_0-9]+(?:\.[a-z0-9_]+)+)["']/).map(&.[1])
    end.uniq! - Partiduo::Modules[Urssaf::CODE].permissions
    cited.size.should be > 40
    dynamic = [] of String
    Urssaf::Api::STATUSES.each { |code| dynamic << "urssaf.statuses.#{code}" }
    Urssaf::Api::ENVIRONMENTS.each { |code| dynamic << "urssaf.environments.#{code}" }
    Urssaf::Api::MANDATE_STATUSES.each { |code| dynamic << "urssaf.mandate_statuses.#{code}" }
    %w[monthly quarterly].each { |code| dynamic << "urssaf.periodicities.#{code}" }
    Urssaf::Api::EVENT_ACTIONS.each { |code| dynamic << "urssaf.actions.#{code}" }
    Urssaf::Api::PAYMENT_STATUSES.each { |code| dynamic << "urssaf.payment_statuses.#{code}" }
    Urssaf::Api::SEPA_STATUSES.each { |code| dynamic << "urssaf.sepa_statuses.#{code}" }
    Urssaf::Api::ANOMALY_CODES.each { |code| dynamic << "urssaf.anomalies.#{code}" }
    Partiduo::Modules[Urssaf::CODE].permissions.each do |name|
      dynamic << "urssaf.permissions.#{name.lchop("urssaf.")}"
    end
    missing = Partiduo::LOCALES.flat_map do |locale|
      I18n.with_locale(locale) do
        (cited + dynamic).reject(&.ends_with?(".")).select { |key| I18n.t(key).includes?("missing") && I18n.t(key, count: 2).includes?("missing") }
          .map { |key| "#{locale}:#{key}" }
      end
    end
    missing.should be_empty
  end

  it "range ses tables sous le préfixe urssaf_ (ADR-003 D5)" do
    [Urssaf::Settings, Urssaf::Filing, Urssaf::Event, Urssaf::Payment, Urssaf::Anomaly, Urssaf::SepaMandateRow].map(&.db_table)
      .should eq(%w[urssaf_settings urssaf_filing urssaf_event urssaf_payment urssaf_anomaly urssaf_sepa_mandate])
  end

  it "ne parle au cœur, depuis ui/bulma, que par Partiduo::Api (ADR-005 D3)" do
    root = Urssaf::SpecSupport::ROOT
    ApiBoundary.scan([File.join(root, "ui")], base: root).map(&.to_s).should eq([] of String)
  end

  it "ne parle au métier de l'extension, depuis ui/bulma, que par Urssaf::Api (ADR-005 D4)" do
    allowed = %w[Api Ui CODE VERSION]
    leaks = source_files("ui/**/*.cr").flat_map do |path|
      File.read_lines(path).each_with_index(1).flat_map do |line, number|
        ApiBoundary.strip_comment(line).scan(/(?<![\w:])Urssaf::([A-Za-z_]\w*)/).compact_map do |match|
          "#{path.lchop(Urssaf::SpecSupport::ROOT + "/")}:#{number} Urssaf::#{match[1]}" unless allowed.includes?(match[1])
        end
      end
    end
    leaks.should be_empty
  end

  it "ne parle au cœur, depuis src/, que par Partiduo::Api (ADR-006 D3)" do
    leaks = source_files("src/**/*.cr").select do |path|
      File.read(path).matches?(/Partiduo::(Invoicing|Accounting|Cards|Core|Vat|Liberal|Micro|Auth)::/)
    end
    leaks.map(&.lchop(Urssaf::SpecSupport::ROOT + "/")).should be_empty
  end

  it "ne journalise ni n'affiche les secrets ni l'IBAN complet" do
    credentials = Urssaf::Credentials.new("app", "secret-tres-long", "sandbox")
    credentials.to_s.should_not contain("secret-tres-long")
    credentials.inspect.should_not contain("secret-tres-long")
    iban = "FR7630006000011234567890189"
    request = Urssaf::SepaMandateRequest.new("732829320", iban, "", "Jeanne", Time.utc)
    input = Urssaf::Api::SepaMandateInput.new(iban, "", "Jeanne", Time.utc, true)
    [request.to_s, request.inspect, input.to_s, input.inspect].each(&.should_not(contain(iban)))
  end

  it "n'utilise que des icônes de la planche de l'interface (ADR-005 D5)" do
    lucide = File.join(Urssaf::SpecSupport::ROOT, "lib", "partiduo-ui-bulma", "icons", "lucide")
    known = Dir.glob(File.join(lucide, "*.svg")).map { |path| File.basename(path, ".svg") }
    known.should_not be_empty
    used = source_files("ui/bulma/templates/**/*.html").flat_map do |path|
      File.read(path).scan(/_icon\.html" with name="([a-z0-9-]+)"/).map { |match| "#{path.lchop(Urssaf::SpecSupport::ROOT + "/")} #{match[1]}" }
    end
    used.reject { |item| known.includes?(item.split(' ').last) }.should be_empty
  end
end
