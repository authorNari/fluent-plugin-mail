require 'securerandom'

class Fluent::MailOutput < Fluent::Output
  Fluent::Plugin.register_output('mail', self)

  # Define `log` method for v0.10.42 or earlier
  unless method_defined?(:log)
    define_method("log") { $log }
  end

  # For fluentd v0.12.16 or earlier
  class << self
    unless method_defined?(:desc)
      def desc(description)
      end
    end
  end

  desc "Output comma delimited keys"
  config_param :out_keys,             :string,  :default => ""
  desc "Format string to construct message body"
  config_param :message,              :string,  :default => nil
  desc "Specify comma delimited keys output to `message`"
  config_param :message_out_keys,     :string,  :default => ""
  desc "Identify the timestamp of the record"
  config_param :time_key,             :string,  :default => nil
  desc "Identify the tag of the record"
  config_param :tag_key,              :string,  :default => 'tag'
  desc "SMTP server hostname"
  config_param :host,                 :string
  desc "SMTP server port number"
  config_param :port,                 :integer, :default => 25
  desc "HELO domain"
  config_param :domain,               :string,  :default => 'localdomain'
  desc "User for SMTP Auth"
  config_param :user,                 :string,  :default => nil
  desc "Password for SMTP Auth"
  config_param :password,             :string,  :default => nil, :secret => true
  desc "MAIL FROM this value"
  config_param :from,                 :string,  :default => 'localhost@localdomain'
  desc "Mail destination (To)"
  config_param :to,                   :string,  :default => ''
  desc "Mail destination (Cc)"
  config_param :cc,                   :string,  :default => ''
  desc "Mail destination (BCc)"
  config_param :bcc,                  :string,  :default => ''
  desc "Identify mail destination (To) of the record"
  config_param :to_key,               :string,  :default => nil
  desc "Identify mail destination (Cc) of the record"
  config_param :cc_key,               :string,  :default => nil
  desc "Identify mail destination (BCc) of the record"
  config_param :bcc_key,              :string,  :default => nil
  desc "Format string to construct mail subject"
  config_param :subject,              :string,  :default => 'Fluent::MailOutput plugin'
  desc "Specify comma delimited keys output to `subject`"
  config_param :subject_out_keys,     :string,  :default => ""
  desc "If set to true, enable STARTTLS"
  config_param :enable_starttls_auto, :bool,    :default => false
  desc "If set to true, enable TLS"
  config_param :enable_tls,           :bool,    :default => false
  desc "Format string to parse time"
  config_param :time_format,          :string,  :default => "%F %T %z"
  desc "Use local time or not"
  config_param :localtime,            :bool,    :default => true
  desc "Locale of time"
  config_param :time_locale,                    :default => nil
  desc "Specify Content-Type"
  config_param :content_type,         :string,  :default => "text/plain; charset=utf-8"

  def initialize
    super
    require 'net/smtp'
    require 'string/scrub' if RUBY_VERSION.to_f < 2.1
  end

  def configure(conf)
    super

    @out_keys = @out_keys.split(',')
    @message_out_keys = @message_out_keys.split(',')
    @subject_out_keys = @subject_out_keys.split(',')

    if @out_keys.empty? and @message.nil?
      raise Fluent::ConfigError, "Either 'message' or 'out_keys' must be specifed."
    end

    if @message
      begin
        @message % (['1'] * @message_out_keys.length)
      rescue ArgumentError
        raise Fluent::ConfigError, "string specifier '%s' of message and message_out_keys specification mismatch"
      end
      @create_message_proc = Proc.new {|tag, time, record| create_formatted_message(tag, time, record) }
    else
      # The default uses the old `key=value` format for old version compatibility
      @create_message_proc = Proc.new {|tag, time, record| create_key_value_message(tag, time, record) }
    end

    @create_addr_procs = %w(to cc bcc).each_with_object({}) do |type, procs|
      dest_key = instance_variable_get(:"@#{type}_key")
      addr = instance_variable_get(:"@#{type}")
      if dest_key
        procs[type] = Proc.new{|record| record[dest_key] || addr }
      else
        procs[type] = Proc.new{|record| addr }
      end
    end

    begin
      @subject % (['1'] * @subject_out_keys.length)
    rescue ArgumentError
      raise Fluent::ConfigError, "string specifier '%s' of subject and subject_out_keys specification mismatch"
    end
  end

  def start
  end

  def shutdown
  end

  def emit(tag, es, chain)
    messages = []
    subjects = []
    dests = []

    es.each {|time,record|
      messages << @create_message_proc.call(tag, time, record)
      subjects << create_formatted_subject(tag, time, record)
      dests << %w(to cc bcc).each_with_object({}){|t, dest| dest[t] = @create_addr_procs[t].call(record) }
    }

    (0...messages.size).each do |i|
      message = messages[i]
      subject = subjects[i]
      dest = dests[i]
      begin
        sendmail(subject, message, dest)
      rescue => e
        log.warn "out_mail: failed to send notice to #{@host}:#{@port}, subject: #{subject}, message: #{message}, " <<
          "error_class: #{e.class}, error_message: #{e.message}, error_backtrace: #{e.backtrace.first}"
      end
    end

    chain.next
  end

  # The old `key=value` format for old version compatibility
  def create_key_value_message(tag, time, record)
    values = []

    values = @out_keys.map do |key|
      case key
      when @time_key
        format_time(time, @time_format)
      when @tag_key
        tag
      else
        "#{key}: #{record[key].to_s}"
      end
    end

    values.join("\n")
  end

  def create_formatted_message(tag, time, record)
    values = []

    values = @message_out_keys.map do |key|
      case key
      when @time_key
        format_time(time, @time_format)
      when @tag_key
        tag
      else
        record[key].to_s
      end
    end

    message = (@message % values)
    with_scrub(message) {|str| str.gsub(/\\n/, "\n") }
  end

  def create_formatted_subject(tag, time, record)
    values = []

    values = @subject_out_keys.map do |key|
      case key
      when @time_key
        format_time(time, @time_format)
      when @tag_key
        tag
      else
        record[key].to_s
      end
    end

    @subject % values
  end

  def sendmail(subject, msg, dest)
    smtp = Net::SMTP.new(@host, @port)

    if @user and @password
      smtp_auth_option = [@domain, @user, @password, :plain]
      smtp.enable_starttls if @enable_starttls_auto
      smtp.enable_tls if @enable_tls
      smtp.start(@domain,@user,@password,:plain)
    else
      smtp.start
    end

    subject = subject.force_encoding('binary')
    body = msg.force_encoding('binary')

    # Date: header has timezone, so usually it is not necessary to set locale explicitly
    # But, for people who would see mail header text directly, the locale information may help something
    # (for example, they can tell the sender should live in Tokyo if +0900)
    date = format_time(Time.now, "%a, %d %b %Y %X %z")

    mid = sprintf("<%s@%s>", SecureRandom.uuid, SecureRandom.uuid)
    content = <<EOF
Date: #{date}
From: #{@from}
To: #{dest['to']}
Cc: #{dest['cc']}
Bcc: #{dest['bcc']}
Subject: #{subject}
Message-Id: #{mid}
Mime-Version: 1.0
Content-Type: #{@content_type}

#{body}
EOF
    response = smtp.send_mail(content, @from, dest['to'].split(/,/), dest['cc'].split(/,/), dest['bcc'].split(/,/))
    log.debug "out_mail: content: #{content.gsub("\n", "\\n")}"
    log.debug "out_mail: email send response: #{response.string.chomp}"
    smtp.finish
  end

  def format_time(time, time_format)
    # Fluentd >= v0.12's TimeFormatter supports timezone, but v0.10 does not
    if @time_locale
      with_timezone(@time_locale) { Fluent::TimeFormatter.new(time_format, @localtime).format(time) }
    else
      Fluent::TimeFormatter.new(time_format, @localtime).format(time)
    end
  end

  def with_timezone(tz)
    oldtz, ENV['TZ'] = ENV['TZ'], tz
    yield
  ensure
    ENV['TZ'] = oldtz
  end

  def with_scrub(string)
    begin
      return yield(string)
    rescue ArgumentError => e
      raise e unless e.message.index("invalid byte sequence in") == 0
      log.info "out_mail: invalid byte sequence is replaced in #{string}"
      string.scrub!('?')
      retry
    end
  end
end
