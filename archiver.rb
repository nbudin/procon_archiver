require 'active_support'
require 'active_support/core_ext'
require 'action_view'
require 'pry'

module ProconArchiver
  class Archiver
    include ActionView::Helpers::DateHelper
    include ActionView::Helpers::TextHelper

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

        archive_convention(convention_row, convention_domain, dest_dir)
      end
    end

    private

    def convention_domains(event_id)
      conn[:virtual_sites].where(event_id: event_id).map(:domain)
    end

    def archive_convention(convention_row, convention_domain, dest_dir)
      FileUtils.copy(
        File.expand_path('global.css', __dir__),
        File.expand_path('global.css', dest_dir)
      )

      site_template = site_template_for_convention(convention_domain)
      write_page(
        site_template,
        convention_row[:fullname],
        homepage_content(convention_row),
        'index.html',
        dest_dir
      )
      write_page(
        site_template,
        "Schedule - #{convention_row[:fullname]}",
        schedule_page_content(convention_row),
        'schedule/index.html',
        dest_dir
      )
    end

    def write_page(site_template, title, body, path, dest_dir)
      dest_path = File.expand_path(path, dest_dir)
      FileUtils.mkdir_p(File.dirname(dest_path))
      File.open(dest_path, 'w') do |f|
        f.write(templatize_content(site_template, title, body))
      end
    end

    def templatize_content(site_template, title, body)
      <<~HTML
        <!DOCTYPE html>
        <html lang="en">
          <head>
            <title>#{title}</title>
            <link rel="stylesheet" href="/global.css">
            <style type="text/css">
              #{site_template[:css] || site_template[:themeroller_css]}
            </style>
            <script type="text/javascript">
              document.addEventListener("DOMContentLoaded", function(event) {
                document.querySelectorAll('[data-toggle=collapse]').forEach(function (toggler) {
                  toggler.addEventListener('click', function(event) {
                    event.preventDefault();
                    var element = event.target.closest('[data-toggle=collapse]');
                    var target = document.querySelector(element.getAttribute('href'));
                    if (!target) {
                      return;
                    }

                    if (target.style.display === 'none') {
                      target.style.display = 'block';
                    } else {
                      target.style.display = 'none';
                    }
                  });
                });
              });
            </script>
          <body>
            #{site_template[:header]}
            <div id="topbar">
              <ul class="nav_links">
                <li class="ui-default-state">
                  <a href="/">Home</a>
                </li>
                <li class="ui-default-state">
                  <a href="/schedule">Event Schedule</a>
                </li>
              </ul>
            </div>
            <div id="content">
              #{body}
            </div>
            #{site_template[:footer]}
          </body>
        </html>
      HTML
    end

    def homepage_content(row)
      <<~HTML
        <h1 id="pagetitle">#{row[:fullname]}</h1>

        <p id="schedulingdetails">
          <b>Time:</b> #{row[:start].strftime('%B %d, %Y at %I:%M %p')}
          <br>
          <b>Length:</b> #{distance_of_time_in_words(row[:start].beginning_of_day, row[:end].end_of_day)}
          <br>
          <b>Location:</b> #{event_locations(row).join(', ')}
        </p>

        #{staff_list_content(row)}

        <div id="description">
          #{descriptive_content(row, 'h2')}
        </div>
      HTML
    end

    def schedule_page_content(row)
      events = conn[:events].where(parent_id: row[:id])
        .order(:start)
        .to_a
        .select { |event| event[:start] && event[:end] }

      events_by_day = events.slice_when do |a, b|
        a[:start]&.beginning_of_day != b[:start]&.beginning_of_day
      end

      event_sections = events_by_day.map do |day_events|
        event_items = day_events.map do |event|
          staff_attendances = conn[:attendances].where(event_id: event[:id], is_staff: true)
          people = conn[:people].where(id: staff_attendances.map { |att| att[:person_id] })
          staff_names = people.map { |person| person_name(person) }.sort

          <<~HTML
            <li>
              <a href="#event-#{event[:id]}-details" data-toggle="collapse">
                <b>#{event[:fullname]}</b>:
                #{event[:start].strftime('%I:%M %P')}
                -
                #{event[:end].strftime('%I:%M %P')}
              </a>

              <div id="event-#{event[:id]}-details" style="margin-bottom: 6pt; padding-left: 12pt; display: none;">
                <p>
                  <b>Staff:</b>
                  #{staff_names.join(', ')}
                </p>

                #{descriptive_content(event, 'strong', '<br>')}
              <div>
            </li>
          HTML
        end

        <<~HTML
          <h2>#{day_events.first[:start].strftime('%A, %B %d, %Y')}</h2>

          <ul style="list-style-type: none; margin-left: 0; padding-left: 0;">
            #{event_items.join("\n")}
          </ul>
        HTML
      end

      <<~HTML
        <h1 id="pagetitle">Schedule</h1>

        #{event_sections.join("\n")}
      HTML
    end

    def descriptive_content(row, header_tag, separator = '')
      return row[:blurb] if row[:description].blank?
      return row[:description] if row[:blurb].blank?

      <<~HTML
        <#{header_tag}>Blurb</#{header_tag}>

        <div>
          #{row[:blurb]}
        </div>

        #{separator}
        <#{header_tag}>Description</#{header_tag}>

        <div>
          #{row[:description]}
        </div>
      HTML
    end

    def staff_list_content(row)
      staff_attendances = conn[:attendances].where(event_id: row[:id], is_staff: true)
      return nil if staff_attendances.none?

      staff_positions = conn[:staff_positions].where(event_id: row[:id]).order(:position)
      positioned_staff, general_staff = staff_attendances.partition { |att| att[:staff_position_id] }
      positioned_staff_by_position_id = positioned_staff.group_by { |att| att[:staff_position_id] }

      people = conn[:people].where(id: staff_attendances.map { |att| att[:person_id] })
      people_by_id = people.index_by { |person| person[:id] }

      positioned_staff_items = staff_positions.map do |position_row|
        atts = positioned_staff_by_position_id[position_row[:id]]
        next unless atts.present?

        atts.map do |att|
          person = people_by_id[att[:person_id]]
          if position_row[:publish_email]
            <<~HTML
              <li>
                <a href="#{position_row[:email].presence || person[:email]}">#{person_name(person)}</a>
              <li>
            HTML
          else
            "<li>#{person_name(person)}</li>"
          end
        end
      end

      general_staff_items = general_staff.map do |att|
        "<li>#{person_name(people_by_id[att[:person_id]])}</li>"
      end

      <<~HTML
        <div id="stafflist">
          <h2>Event Staff</h2>
          <ul>
            #{positioned_staff_items.compact.join("\n")}
            #{general_staff_items.compact.sort.join("\n")}
          </ul>
        </div>
      HTML
    end

    def person_name(person_row)
      [
        person_row[:firstname],
        person_row[:nickname].present? ? "\"#{person_row[:nickname]}\"" : nil,
        person_row[:lastname]
      ].select(&:present?).join(' ')
    end

    def event_length(e)
      length = e[:end] - e[:start] if e[:end] && e[:start]
      return '(Unscheduled)' if length.nil?

      return distance_of_time_in_words(e.start, e.end) if length / 60 / 60 < 12

      # count midnights, rule of thumb is "x days" where x = midnights + 1

      if e[:start].at_beginning_of_day == e[:end].at_beginning_of_day
        midnights = 0
      else
        midnights = (e[:end].at_beginning_of_day - e[:start].at_beginning_of_day) / 60 / 60 / 24
      end

      days = midnights + 1
      "#{pluralize days.round, 'days'}"
    end

    def event_locations(event_row)
      location_rows = conn[:locations].join(:event_locations, location_id: :id)
        .where(event_id: event_row[:id])
      location_ids = Set.new(location_rows.map { |row| row[:location_id] })
      roots = location_rows.reject do |location_row|
        location_ids.include?(location_row[:parent_id])
      end

      roots.map { |row| row[:name] }.sort
    end

    def site_template_for_convention(convention_domain)
      virtual_site = conn[:virtual_sites].where(domain: convention_domain).first
      return unless virtual_site && virtual_site[:site_template_id]

      site_template = conn[:site_templates].where(id: virtual_site[:site_template_id]).first
      site_template || {}
    end
  end
end
