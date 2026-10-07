require "json"
require "set"

module Memo
  # Console logging for memo-arcana: colored, timestamped lines on STDERR,
  # with request parameters summarized and secrets redacted.
  module BusLog
    DIM    = "\e[2m"
    BOLD   = "\e[1m"
    RESET  = "\e[0m"
    GREEN  = "\e[32m"
    YELLOW = "\e[33m"
    RED    = "\e[31m"
    CYAN   = "\e[36m"
    GRAY   = "\e[90m"

    # Where log lines go (specs silence it)
    class_property output : IO = STDERR

    def log(msg : String)
      BusLog.output.puts "#{GRAY}#{Time.local.to_s("%H:%M:%S")}#{RESET} #{msg}"
    end

    def truncate(s : String, max : Int32 = 50) : String
      s.size > max ? "#{s[0, max]}…" : s
    end

    SENSITIVE_KEYS = Set{"api_key", "password", "secret", "token", "key"}

    def sensitive?(key : String) : Bool
      k = key.downcase
      SENSITIVE_KEYS.any? { |s| k.includes?(s) }
    end

    def redact_db_url(url : String) : String
      url.gsub(/(:\/\/[^:]+:)[^@]+(@)/, "\\1***\\2")
    end

    def summarize(data : JSON::Any) : String
      return "" unless data.as_h?
      parts = [] of String
      data.as_h.each do |k, v|
        next if k == "action"
        val = if sensitive?(k)
                "***"
              else
                case raw = v.raw
                when String
                  display = k == "db" ? redact_db_url(raw) : raw
                  %("#{truncate(display, 40)}")
                when Array then "[#{raw.size}]"
                when Hash  then "{…}"
                else            raw.to_s
                end
              end
        parts << "#{k}=#{val}"
      end
      parts.join(" ")
    end
  end
end
