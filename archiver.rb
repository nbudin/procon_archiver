module ProconArchiver
  class Archiver
    attr_reader :conn, :convention_domain_regex
    def initialize(conn, convention_domain_regex)
      @conn = conn
      @convention_domain_regex = Regexp.new(convention_domain_regex)
    end

    def archive
      conn[:events].where(parent_id: nil).each do |convention_row|
        domains = convention_domains(convention_row[:id])
        next unless domains.any? { |domain| convention_domain_regex.match?(domain) }

        convention_domain = domains.sort_by { |domain| [domain.length, domain] }.last
        dest_dir = File.expand_path("out/#{convention_domain}", __dir__)
        FileUtils.mkdir_p(dest_dir)
      end
    end

    private

    def convention_domains(event_id)
      conn[:virtual_sites].where(event_id: event_id).map(:domain)
    end
  end
end
