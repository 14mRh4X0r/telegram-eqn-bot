#!/usr/bin/env ruby
require 'rubygems'
require 'bundler/setup'
require 'telegram/bot'
require 'hashie'
require 'logger'

require_relative 'config'

def render msg
  f = File.open("tmp/#{msg.id}.tex", 'w') do |file|
    file.write <<EOF
\\documentclass{standalone}
\\usepackage{esint}
\\begin{document}
  $#{msg.query}$
\\end{document}
EOF
  end

  res = system 'pdflatex', '--no-shell-escape', "tmp/#{msg.id}.tex"
  return 'error.webp' if res != 0

  s = StringIO.new `convert -density 300 tmp/#{msg.id}.pdf -quality 90 webp:-`
  File.delete "tmp/#{msg.id}.tex"

  if $? != 0
    'error.webp'
  else
    s
  end
end

Telegram::Bot::Client.run(BOT_TOKEN) do |bot|
  logger = Logger.new STDOUT
  logger.datetime_format = '%Y-%m-%d %H:%M:%S'
  me = Hashie::Mash.new(bot.api.get_me).result

  begin
    bot.listen do |msg|
      logger.debug "Got message: #{msg.id if msg.respond_to? :id}: #{msg} (#{msg.class})"

      case msg
        when Telegram::Bot::Types::Message
          if msg.text and msg.text[0] == '/'
            cmd = msg.text.split[0][1..-1]
            cmd, who = cmd.split '@' if cmd.include? '@'
            next if not cmd.eql? 'render' or not who.nil? and not who.eql? me.username

            fork do
              bot.api.send_sticker chat_id: msg.chat.id,
                                   reply_to_message_id: msg.id,
                                   sticker: Faraday::UploadIO.new(render(msg), 'image/webp')
            end
          end
      end
    end
  rescue Interrupt
    logger.warn 'Caught interrupt -- quitting'
  end
end